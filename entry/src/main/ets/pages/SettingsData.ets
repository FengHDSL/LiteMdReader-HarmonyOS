/**
 * 澄笺 · 设置 · 数据管理
 * ====================
 *
 * 从设置中心拆出来的独立页。按「先结构、后搬运」逐块迁入：
 *   ① zip 备份导出 / 导入 / 清除缓存   ← 已迁入
 *   ② WebDAV 备份（连接配置 + 一键备份）
 *   ③ 书架数据（内置文档清单 + 删除）
 *   ④ 清空全部自建文档
 */
import { NavLifecycle } from '../service/NavLifecycle';
import { LengthMetrics } from '@kit.ArkUI';
import { ImmersiveCard, ImmersiveChip, ImmersiveIconButton } from '../material/ImmersiveCard';
import { ImmersiveInput } from '../material/ImmersiveInput';
import { SettingsShell } from './SettingsShell';
import { BackupStore } from '../service/BackupStore';
import { WebDavConfig, WebDavResult, WebDavStore } from '../service/WebDavStore';
import { UpdateService } from '../service/UpdateService';
import { DocMeta, DocStore } from '../service/DocStore';
import { ExportService } from '../service/ExportService';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  paletteFor
} from '../theme/DesignTokens';

@Component
export struct SettingsData {
  stack: NavPathStack | null = null;
  life: NavLifecycle = new NavLifecycle();

  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 外观刷新计数：主题色 / 灰字 / 沾色改动后由它触发重算 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  /** zip 备份/恢复的进行中标记与结果文案 */
  @State zipBusy: boolean = false;
  @State zipStatus: string = '';
  /** 书架数据：内置文档清单 + 待确认删除的那一篇 */
  @State builtinList: DocMeta[] = [];
  /** 已被移除（隐藏）的内置教程名：书架上看不到，但正文一直都在 */
  @State hiddenBuiltins: string[] = [];
  /** **我的文档**（自建）：书架数据里也要能看到（用户要求：新建的文档要有显示） */
  @State myDocs: DocMeta[] = [];
  /** 图片管理：本地图片（手写笔记 / 插入的图都在 docs/images 下） */
  @State localImages: string[] = [];
  /** 图片管理：正文引用的网络图片 URL */
  @State netImages: string[] = [];
  /** 已被用户"删除"（隐藏）的图片：**不删除本地文件**，只是不再在此列表显示 */
  @State hiddenImages: string[] = [];
  @State pendingDeleteDoc: string = '';
  /** WebDAV 备份配置与状态 */
  @State webdavServer: string = '';
  @State webdavUser: string = '';
  @State webdavPassword: string = '';
  @State webdavDir: string = 'litemdreader';
  @State backupStatus: string = '';
  @State backing: boolean = false;
  @State confirmClearAll: boolean = false;
  /** 全屏放大预览（展开区右上角放大按钮触发）：本地图=file:// URI、网络图=URL */
  @State previewImage: string = '';
  @State previewScale: number = 1;
  private previewPinchBase: number = 1;
  /** 图片管理：**原位下拉展开**的那一项（本地图=文件名；网络图=URL）；空 = 全部收起 */
  @State expandedImg: string = '';

  private palette(): ReaderPalette {
    // 三个来源都要显式读一遍落成局部常量：主题色 / 灰字 / 沾色改完**当帧**就能重算；
    // 不登记 themeMode / systemDark 的话主题切换会被 ArkUI 跳过重算（文字变黑）
    const tick: number = this.appearanceTick;
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1600 });
    } catch (err) {
      // 提示失败无副作用
    }
  }

  /** 取应用上下文（新页面里用 getHostContext，不能引设置中心的私有 ctx()） */
  private ctx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  // ══════════════════════ ② WebDAV 备份 ══════════════════════

  private loadWebDavConfig(): void {
    const c = this.ctx();
    if (c === null) {
      return;
    }
    const cfg: WebDavConfig = WebDavStore.loadConfig(c);
    this.webdavServer = cfg.server;
    this.webdavUser = cfg.user;
    this.webdavPassword = cfg.password;
    this.webdavDir = cfg.dir.length > 0 ? cfg.dir : 'litemdreader';
  }

  private saveWebDavConfig(): void {
    const c = this.ctx();
    if (c === null) {
      this.toast('拿不到应用上下文');
      return;
    }
    const cfg: WebDavConfig = {
      server: this.webdavServer.trim(),
      user: this.webdavUser.trim(),
      password: this.webdavPassword,
      dir: this.webdavDir.trim().length > 0 ? this.webdavDir.trim() : 'litemdreader'
    };
    WebDavStore.saveConfig(c, cfg);
    this.toast('WebDAV 配置已保存');
  }

  /** 一键备份：全部文档 + 书架索引 + 批注 + 阅读设置。 */
  private runBackup(): void {
    if (this.backing) {
      return;
    }
    // 基础模式（纯离线）：网络备份不可用（用户要求）
    if (UpdateService.isOffline()) {
      this.toast('当前是基础模式（纯离线），网络备份不可用');
      return;
    }
    const c = this.ctx();
    if (c === null) {
      this.toast('拿不到应用上下文');
      return;
    }
    // 先落一次配置，避免「改了没保存就备份」用了旧值
    this.saveWebDavConfig();
    const cfg: WebDavConfig = WebDavStore.loadConfig(c);
    if (!WebDavStore.isConfigured(cfg)) {
      this.toast('请先填写服务器地址与账号');
      return;
    }
    this.backing = true;
    this.backupStatus = '开始备份…';
    WebDavStore.backupAll(c, cfg, (done: number, total: number, label: string) => {
      this.backupStatus = '备份中 ' + done + ' / ' + total + ' · ' + label;
    }).then((result: WebDavResult) => {
      this.backing = false;
      if (result.error.length === 0) {
        this.backupStatus = '备份完成：' + result.uploaded + ' 个文件';
        this.toast('备份完成');
      } else {
        this.backupStatus = '备份中断：' + result.error;
        this.toast('备份中断');
      }
    }).catch((e: BusinessError) => {
      this.backing = false;
      this.backupStatus = '备份失败：' + e.message;
    });
  }

  // ══════════════════════ ④ 清空自建文档 ══════════════════════
  // ══════════════════════ ③ 书架数据（内置文档） ══════════════════════

  /** 只列内置文档：用户自建的不在这里删，避免误删 */
  aboutToAppear(): void {
    this.loadBuiltins();
    this.loadWebDavConfig();
    this.life.onShow = () => {
      this.loadBuiltins();
    };
  }

  private loadBuiltins(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      DocStore.init(ctx);
      const list: DocMeta[] = DocStore.list(ctx);
      const builtins: DocMeta[] = [];
      const mine: DocMeta[] = [];
      for (let k = 0; k < list.length; k++) {
        if (DocStore.isBuiltinName(list[k].name)) {
          builtins.push(list[k]);
        } else {
          mine.push(list[k]);
        }
      }
      this.builtinList = builtins;
      this.myDocs = mine;
      // 已被用户从书架移除（隐藏）的内置教程名单——在这里可以一键恢复
      this.hiddenBuiltins = DocStore.hiddenBuiltinList();
      this.loadImageItems();
    } catch (err) {
      // 统计失败不阻断
    }
  }

  // ══════════════════════ ⑤ 图片管理 ══════════════════════

  private imgHiddenPath(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/image_hidden.json';
  }

  private loadHiddenImages(ctx: common.UIAbilityContext): void {
    try {
      const path: string = this.imgHiddenPath(ctx);
      if (fs.accessSync(path)) {
        const text: string = fs.readTextSync(path, { encoding: 'utf-8' });
        const parsed: string[] = JSON.parse(text) as string[];
        this.hiddenImages = parsed !== null && parsed !== undefined ? parsed : [];
      }
    } catch (err) {
      this.hiddenImages = [];
    }
  }

  private saveHiddenImages(ctx: common.UIAbilityContext): void {
    try {
      const hf: fs.File = fs.openSync(this.imgHiddenPath(ctx),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(hf.fd, JSON.stringify(this.hiddenImages));
      } finally {
        try {
          fs.closeSync(hf.fd);
        } catch (closeErr) {
          // 忽略
        }
      }
    } catch (err) {
      // 忽略
    }
  }

  /** 收集本地图片（docs/images）与网络图片（正文引用的 http 图）→ 过滤已隐藏。 */
  private loadImageItems(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    this.loadHiddenImages(ctx);
    // ① 本地图片（手写笔记与插入的图片都在这里）
    try {
      const dir: string = DocStore.imagesDirPath();
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const names: string[] = fs.listFileSync(dir);
      const kept: string[] = [];
      for (let k = 0; k < names.length; k++) {
        const n: string = names[k];
        if (n.startsWith('.')) {
          continue;
        }
        if (this.hiddenImages.indexOf('local:' + n) < 0) {
          kept.push(n);
        }
      }
      kept.sort();
      this.localImages = kept;
    } catch (err) {
      this.localImages = [];
    }
    // ② 网络图片：扫描全部文档正文里的 http 图片引用
    const found: string[] = [];
    try {
      for (let k = 0; k < this.myDocs.length; k++) {
        const path: string = DocStore.docsRoot() + '/' + this.myDocs[k].fileName;
        try {
          if (!fs.accessSync(path)) {
            continue;
          }
          const text: string = fs.readTextSync(path, { encoding: 'utf-8' });
          const re: RegExp = /!\[[^\]]*\]\((https?:\/\/[^)\s]+)\)|<img[^>]+src="(https?:\/\/[^"\s]+)"/g;
          let m: RegExpExecArray | null = re.exec(text);
          while (m !== null) {
            const url: string = m[1] !== undefined ? m[1] : m[2];
            if (url !== undefined && found.indexOf(url) < 0) {
              found.push(url);
            }
            m = re.exec(text);
          }
        } catch (readErr) {
          // 单篇失败继续
        }
      }
      const net: string[] = [];
      for (let k = 0; k < found.length; k++) {
        if (this.hiddenImages.indexOf('net:' + found[k]) < 0) {
          net.push(found[k]);
        }
      }
      this.netImages = net;
    } catch (err) {
      this.netImages = [];
    }
  }

  /** 删除（隐藏）：**不删除本地文件**（用户要求），只是不再在此列表显示。 */
  private hideImage(kind: string, key: string): void {
    const tag: string = kind + ':' + key;
    if (this.hiddenImages.indexOf(tag) < 0) {
      this.hiddenImages.push(tag);
    }
    const ctx = this.ctx();
    if (ctx !== null) {
      this.saveHiddenImages(ctx);
    }
    this.loadImageItems();
    this.toast('已从列表移除（本地文件保留）');
  }

  /** 导出本地图片：系统另存为。 */
  private exportImage(name: string): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      const path: string = DocStore.imagesDirPath() + '/' + name;
      const size: number = fs.statSync(path).size;
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buf: ArrayBuffer = new ArrayBuffer(size);
      try {
        fs.readSync(file.fd, buf);
      } finally {
        try {
          fs.closeSync(file.fd);
        } catch (closeErr) {
          // 忽略
        }
      }
      ExportService.saveBytes(ctx, name, buf, (m: string) => {
        this.toast(m);
      });
    } catch (err) {
      this.toast('导出失败：' + (err as BusinessError).message);
    }
  }

  /** 恢复全部被移除的内置教程（正文一直都在，只是被隐藏了）。 */
  private restoreBuiltins(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      const n: number = DocStore.restoreBuiltins(ctx);
      this.loadBuiltins();
      this.toast(n > 0 ? '已恢复 ' + n + ' 篇内置教程' : '没有需要恢复的内置教程');
    } catch (err) {
      this.toast('恢复失败');
    }
  }

  /** 删除内置文档：确认后连本地文件一起删（DocStore.remove 的语义） */
  private deleteBuiltin(name: string): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      if (DocStore.remove(ctx, name)) {
        this.pendingDeleteDoc = '';
        this.loadBuiltins();
        this.toast('已删除「' + name + '」及其本地文件');
      } else {
        this.toast('删除失败');
      }
    } catch (err) {
      this.toast('删除失败：' + DocStore.describeError(err as BusinessError));
    }
  }

  /** 删除自建文档（确认后连本地文件一起删）。 */
  private confirmDeleteMyDoc(name: string): void {
    try {
      this.getUIContext().showAlertDialog({
        title: '删除「' + name + '」？',
        message: '本地 md 文件会一并删除，删除后不可恢复。',
        primaryButton: {
          value: '取消',
          action: () => {
            // 什么都不做
          }
        },
        secondaryButton: {
          value: '删除',
          action: () => {
            this.deleteBuiltin(name);
          }
        }
      });
    } catch (err) {
      this.deleteBuiltin(name);
    }
  }

  /**
   * 「全部移除」的**确认弹窗**（用户要求）：说明内置文档不支持删除、
   * 全部移除后重启会自动重新生成。
   */
  private confirmResetBuiltins(): void {
    try {
      this.getUIContext().showAlertDialog({
        title: '全部移除内置文档？',
        message: '内置文档**不支持单独删除**（只能整体移除）。'
          + '移除后书架上看不到，但正文仍在应用内，重启应用会自动重新生成，' +
          '也可以在本页「已移除的内置教程」里一键恢复。',
        primaryButton: {
          value: '取消',
          action: () => {
            // 什么都不做
          }
        },
        secondaryButton: {
          value: '全部移除',
          action: () => {
            this.resetBuiltins();
          }
        }
      });
    } catch (err) {
      this.resetBuiltins();
    }
  }

  /** 全部移除：内置教程会在下次启动时重新写入沙箱 */
  private resetBuiltins(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    let n: number = 0;
    for (let k = 0; k < this.builtinList.length; k++) {
      try {
        if (DocStore.remove(ctx, this.builtinList[k].name)) {
          n++;
        }
      } catch (err) {
        // 单个失败继续
      }
    }
    this.pendingDeleteDoc = '';
    this.loadBuiltins();
    this.toast('已移除 ' + n + ' 篇内置文档，重启应用会重新生成');
  }

  // ══════════════════════ ① zip 备份 / 恢复 / 清缓存 ══════════════════════

  private exportZipBackup(): void {
    const ctx = this.ctx();
    if (ctx === null || this.zipBusy) {
      return;
    }
    this.zipBusy = true;
    this.zipStatus = '正在打包…';
    BackupStore.exportZip(ctx).then((msg: string) => {
      this.zipBusy = false;
      this.zipStatus = msg;
      if (msg.length > 0) {
        this.toast(msg);
      }
    }).catch((err: BusinessError) => {
      this.zipBusy = false;
      this.zipStatus = '导出失败：' + err.message;
    });
  }

  private importZipBackup(): void {
    const ctx = this.ctx();
    if (ctx === null || this.zipBusy) {
      return;
    }
    this.zipBusy = true;
    this.zipStatus = '正在导入…';
    BackupStore.importZip(ctx).then((msg: string) => {
      this.zipBusy = false;
      this.zipStatus = msg;
      if (msg.length > 0) {
        this.toast(msg);
        // 数据变了，重载书架索引
        DocStore.init(ctx);
      }
    }).catch((err: BusinessError) => {
      this.zipBusy = false;
      this.zipStatus = '导入失败：' + err.message;
    });
  }

  private clearAppCache(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    BackupStore.clearCache(ctx).then((msg: string) => {
      this.zipStatus = msg;
      this.toast(msg);
    }).catch((err: BusinessError) => {
      this.zipStatus = '清除失败：' + err.message;
    });
  }

  /** WebDAV 配置输入行（kind 决定写回哪个字段）；输入框走沉浸光感外壳 */
  @Builder
  fieldRow(label: string, hint: string, value: string, kind: string) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
      ImmersiveInput({
        palette: this.palette(),
        text: value,
        placeholder: hint,
        onInput: (v: string) => {
          this.applyWebDavField(kind, v);
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 按 kind 把输入写回对应的 WebDAV 字段。 */
  private applyWebDavField(kind: string, v: string): void {
    if (kind === 'server') {
      this.webdavServer = v;
    } else if (kind === 'user') {
      this.webdavUser = v;
    } else if (kind === 'pass') {
      this.webdavPassword = v;
    } else if (kind === 'dir') {
      this.webdavDir = v;
    }
  }

  /** 图片全屏预览（bindContentCover 的内容）：黑底 + 图片 + 捏合缩放 + 点击关闭 */
  @Builder
  previewOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Image(this.previewImage)
        .objectFit(ImageFit.Contain)
        .width('100%')
        .height('100%')
        .scale({ x: this.previewScale, y: this.previewScale })
        .gesture(
          PinchGesture({ fingers: 2 })
            .onActionStart(() => {
              this.previewPinchBase = this.previewScale;
            })
            .onActionUpdate((event: GestureEvent) => {
              const sc: number = event.scale !== undefined ? event.scale : 1;
              this.previewScale = Math.min(8, Math.max(0.5, this.previewPinchBase * sc));
            })
        )

      Text('点此关闭')
        .fontSize(HwType.caption)
        .fontColor('#FFFFFFFF')
        .padding({ left: HwSpace.md, right: HwSpace.md, top: 6, bottom: 6 })
        .borderRadius(HwRadius.pill)
        .backgroundColor('#66000000')
        .position({ x: '50%', y: '92%' })
        .markAnchor({ x: '50%', y: '50%' })
        .onClick(() => {
          this.previewImage = '';
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2000000')
    .onClick(() => {
      this.previewImage = '';
    })
  }

  build() {
    SettingsShell({
      shellTitle: '数据管理',
      shellSubtitle: '备份与恢复 · 书架数据 · 缓存',
      stack: this.stack,
      life: this.life
    }) {
      // ── ① 备份与恢复 ──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Text('把文档、书架索引、批注、手写笔迹打包成一个 zip 导出到你自己选的位置；' +
            '导入会覆盖同名数据，请先确认当前数据已备份。')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwType.caption * 1.7)
            .width('100%')

          // 换行布局：三颗芯片在窄屏上放不下时折到下一行，不再被右边缘截断
          Flex({
            wrap: FlexWrap.Wrap,
            space: { main: LengthMetrics.vp(HwSpace.xs), cross: LengthMetrics.vp(HwSpace.xs) }
          }) {
            ImmersiveChip({
              palette: this.palette(),
              chipActive: true,
              chipLabel: this.zipBusy ? '处理中…' : '导出备份',
              chipOnTap: () => {
                this.exportZipBackup();
              }
            }) {
              SymbolGlyph($r('sys.symbol.arrow_up_to_line'))
                .fontSize(13)
                .fontColor([this.palette().accent])
            }
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '导入备份',
              chipOnTap: () => {
                this.importZipBackup();
              }
            }) {
              SymbolGlyph($r('sys.symbol.arrow_down_to_line'))
                .fontSize(13)
                .fontColor([this.palette().accent])
            }
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '清除缓存',
              chipOnTap: () => {
                this.clearAppCache();
              }
            }) {
              SymbolGlyph($r('sys.symbol.trash'))
                .fontSize(13)
                .fontColor([this.palette().textSecondary])
            }
          }
          .width('100%')

          if (this.zipStatus.length > 0) {
            Text(this.zipStatus)
              .fontSize(HwType.caption)
              .fontColor(this.palette().accent)
              .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── ③ 书架数据（内置文档） ──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Text('书架数据')
            .fontSize(HwType.label + 1)
            .fontColor(this.palette().textPrimary)
          Text('内置文档共 ' + this.builtinList.length + ' 篇 —— **内置文档不支持删除**'
            + '（可整体移除，重启后自动重新生成）。下方「我的文档」是你的自建内容。')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwType.caption * 1.7)
            .width('100%')

          ForEach(this.builtinList, (meta: DocMeta) => {
            Column({ space: HwSpace.xs }) {
              Row({ space: HwSpace.sm }) {
                Column({ space: 2 }) {
                  Text(meta.name)
                    .fontSize(HwType.label)
                    .fontColor(this.palette().textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(meta.wordCount + ' 字 · ' + DocStore.formatTime(meta.mtime))
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textTertiary)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                // 内置文档**不提供删除按钮**（用户要求：不支持删除）
                Text('内置')
                  .fontSize(HwType.caption)
                  .fontColor(this.palette().textTertiary)
                  .padding({ left: HwSpace.xs, right: HwSpace.xs, top: 3, bottom: 3 })
                  .borderRadius(8)
                  .backgroundColor(this.palette().divider)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }, (meta: DocMeta) => 'bd_' + meta.name)

          if (this.builtinList.length > 1) {
            ImmersiveChip({
              palette: this.palette(),
              chipTint: '#FFD32F2F',
              chipActive: true,
              chipLabel: '全部移除（重启后重新生成）',
              chipOnTap: () => {
                this.confirmResetBuiltins();
              }
            })
          }

          // ── 我的文档（自建）──
          Divider().strokeWidth(1).color(this.palette().divider)

          Text('我的文档（' + this.myDocs.length + ' 篇）')
            .fontSize(HwType.label)
            .fontColor(this.palette().textPrimary)
            .width('100%')

          if (this.myDocs.length === 0) {
            Text('还没有自建文档，去书架新建一篇试试')
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
              .width('100%')
          } else {
            ForEach(this.myDocs, (meta: DocMeta) => {
              Row({ space: HwSpace.sm }) {
                Column({ space: 2 }) {
                  Text(meta.name)
                    .fontSize(HwType.label)
                    .fontColor(this.palette().textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(meta.wordCount + ' 字 · ' + DocStore.formatTime(meta.mtime))
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textTertiary)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                // 自建文档**可以删除**（与内置不同）：删除连本地文件一起
                ImmersiveChip({
                  palette: this.palette(),
                  chipTint: '#FFD32F2F',
                  chipActive: true,
                  chipLabel: '删除',
                  chipOnTap: () => {
                    this.confirmDeleteMyDoc(meta.name);
                  }
                })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }, (meta: DocMeta) => 'my_' + meta.name)
          }

          // ── 图片管理（用户要求）：展示手写笔记 / 插入的本地图片 / 网络图片，
          // 支持导出与移除（移除**不删除本地文件**）──
          Divider().strokeWidth(1).color(this.palette().divider)

          Text('图片管理')
            .fontSize(HwType.label + 1)
            .fontColor(this.palette().textPrimary)
            .width('100%')
          Text('本地图片 ' + this.localImages.length + ' 张 · 网络图片 ' + this.netImages
            + ' 张。删除只从列表移除，**不会删除本地文件**。')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')

          ForEach(this.localImages, (name: string) => {
            Row({ space: HwSpace.sm }) {
              // **缩略图**（用户要求：放左侧）—— file:// 前缀否则 Image 读沙箱路径失败（全黑）
              Image('file://' + DocStore.imagesDirPath() + '/' + name)
                .width(40)
                .height(40)
                .borderRadius(6)
                .objectFit(ImageFit.Cover)
                .onClick(() => {
                  this.expandedImg = this.expandedImg === name ? '' : name;
                })
              Column({ space: 2 }) {
                Text(name)
                  .fontSize(HwType.label)
                  .fontColor(this.palette().textPrimary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text('本地图片（手写笔记 / 插图）· 点击可查看')
                  .fontSize(HwType.caption)
                  .fontColor(this.palette().textTertiary)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .onClick(() => {
                this.getUIContext().animateTo(
                  { duration: 260, curve: Curve.FastOutSlowIn }, () => {
                    this.expandedImg = this.expandedImg === name ? '' : name;
                  });
              })

              ImmersiveChip({
                palette: this.palette(),
                chipTint: '#FF2E7D32',
                chipActive: true,
                chipLabel: '导出',
                chipOnTap: () => {
                  this.exportImage(name);
                }
              })
              ImmersiveChip({
                palette: this.palette(),
                chipTint: '#FFD32F2F',
                chipActive: true,
                chipLabel: '删除',
                chipOnTap: () => {
                  this.hideImage('local', name);
                }
              })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            // **原位下拉展示**（用户要求：点击就在列表位置展开图片，不用滚到别处）
            // 大卡片延伸带高度动画（animateTo 驱动），右上角放大进全屏预览
            if (this.expandedImg === name) {
              Stack({ alignContent: Alignment.TopEnd }) {
                Image('file://' + DocStore.imagesDirPath() + '/' + name)
                  .objectFit(ImageFit.Contain)
                  .width('100%')
                  .constraintSize({ maxHeight: 320 })
                  .borderRadius(HwRadius.inline)
                  .transition(TransitionEffect.OPACITY
                    .animation({ duration: 240, curve: Curve.FastOutSlowIn }))
                  .onClick(() => {
                    this.getUIContext().animateTo(
                      { duration: 240, curve: Curve.FastOutSlowIn }, () => {
                        this.expandedImg = '';
                      });
                  })

                // 尾随闭包组件不能再链属性 → 外层 Column 承载 margin
                Column() {
                  ImmersiveIconButton({
                    buttonSize: 28,
                    buttonMaterialShadow: false,
                    palette: this.palette(),
                    buttonOnTap: () => {
                      this.previewImage = 'file://' + DocStore.imagesDirPath() + '/' + name;
                      this.previewScale = 1;
                    }
                  }) {
                    SymbolGlyph($r('sys.symbol.arrow_up_left_and_arrow_down_right'))
                      .fontSize(13)
                      .fontColor([this.palette().textPrimary])
                  }
                }
                .margin({ top: 6, right: 6 })
              }
              .width('100%')
            }
          }, (name: string) => 'li_' + name)

          ForEach(this.netImages, (url: string) => {
            Row({ space: HwSpace.sm }) {
              Column({ space: 2 }) {
                Text(url)
                  .fontSize(HwType.label)
                  .fontColor(this.palette().textPrimary)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text('网络图片 · 点击可查看')
                  .fontSize(HwType.caption)
                  .fontColor(this.palette().textTertiary)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .onClick(() => {
                this.getUIContext().animateTo(
                  { duration: 260, curve: Curve.FastOutSlowIn }, () => {
                    this.expandedImg = this.expandedImg === url ? '' : url;
                  });
              })

              ImmersiveChip({
                palette: this.palette(),
                chipTint: '#FFD32F2F',
                chipActive: true,
                chipLabel: '删除',
                chipOnTap: () => {
                  this.hideImage('net', url);
                }
              })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            if (this.expandedImg === url) {
              Stack({ alignContent: Alignment.TopEnd }) {
                Image(url)
                  .objectFit(ImageFit.Contain)
                  .width('100%')
                  .constraintSize({ maxHeight: 320 })
                  .borderRadius(HwRadius.inline)
                  .transition(TransitionEffect.OPACITY
                    .animation({ duration: 240, curve: Curve.FastOutSlowIn }))
                  .onClick(() => {
                    this.getUIContext().animateTo(
                      { duration: 240, curve: Curve.FastOutSlowIn }, () => {
                        this.expandedImg = '';
                      });
                  })

                // 尾随闭包组件不能再链属性 → 外层 Column 承载 margin
                Column() {
                  ImmersiveIconButton({
                    buttonSize: 28,
                    buttonMaterialShadow: false,
                    palette: this.palette(),
                    buttonOnTap: () => {
                      this.previewImage = url;
                      this.previewScale = 1;
                    }
                  }) {
                    SymbolGlyph($r('sys.symbol.arrow_up_left_and_arrow_down_right'))
                      .fontSize(13)
                      .fontColor([this.palette().textPrimary])
                  }
                }
                .margin({ top: 6, right: 6 })
              }
              .width('100%')
            }
          }, (url: string) => 'ni_' + url)

          // ── 被移除的内置教程：一键恢复（在书架格子上「移除教程」的会落到这里）──
          Divider().strokeWidth(1).color(this.palette().divider)

          Row({ space: HwSpace.sm }) {
            Column({ space: 2 }) {
              Text('已移除的内置教程')
                .fontSize(HwType.label)
                .fontColor(this.palette().textPrimary)
              Text(this.hiddenBuiltins.length > 0
                ? '书架上看不到：' + this.hiddenBuiltins.join('、')
                : '没有移除过内置教程')
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
                .maxLines(2)
                .lineHeight(HwType.caption * 1.6)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            if (this.hiddenBuiltins.length > 0) {
              ImmersiveChip({
                palette: this.palette(),
                chipActive: true,
                chipLabel: '恢复',
                chipOnTap: () => {
                  this.restoreBuiltins();
                }
              })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── ② WebDAV 备份 ──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Text('WebDAV 备份')
            .fontSize(HwType.label + 1)
            .fontColor(this.palette().textPrimary)
          Text('把文档、书架索引、批注与阅读设置上传到你自己的 WebDAV 服务器；凭据只存在本机')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwType.caption * 1.7)
            .width('100%')

          this.fieldRow('服务器地址', 'https://dav.example.com/dav', this.webdavServer, 'server')
          this.fieldRow('账号', '用户名', this.webdavUser, 'user')
          this.fieldRow('密码 / 应用密码', '密码', this.webdavPassword, 'pass')
          this.fieldRow('远端目录', 'litemdreader', this.webdavDir, 'dir')

          Row({ space: HwSpace.sm }) {
            ImmersiveChip({
              palette: this.palette(),
              chipActive: true,
              chipLabel: '保存配置',
              chipOnTap: () => {
                this.saveWebDavConfig();
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipTint: '#FF2E7D32',
              chipActive: !this.backing,
              chipLabel: this.backing ? '备份中…' : '立即备份',
              chipOnTap: () => {
                this.runBackup();
              }
            })
          }
          .width('100%')

          if (this.backupStatus.length > 0) {
            Text(this.backupStatus)
              .fontSize(HwType.caption)
              .fontColor(this.palette().accent)
              .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // **图片全屏预览的挂载点**：bindContentCover 覆盖整个页面（零尺寸不影响布局）
      Column()
        .width(0)
        .height(0)
        .bindContentCover(this.previewImage.length > 0, this.previewOverlay(), {
          modalTransition: ModalTransition.DEFAULT,
          onDisappear: () => {
            this.previewImage = '';
          }
        })


    }
  }
}
