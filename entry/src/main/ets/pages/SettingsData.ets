import { L10n } from '../service/L10n';
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
import { SettingsMirror } from '../service/SettingsMirror';
import { AppResetDialog } from '../components/AppResetDialog';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { AnnotationStore } from '../service/AnnotationStore';
import { MdAnnotation } from '../markdown/MdTypes';
import {
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  paletteFor
} from '../theme/DesignTokens';

/** 批注数据管理：跨文档批注预览条目 */
interface AnnoPreviewItem {
  docName: string;
  kind: string;
  text: string;
}

@Component
export struct SettingsData {
  stack: NavPathStack | null = null;
  life: NavLifecycle = new NavLifecycle();

  /** **应用初始化**确认弹窗（确认键倒计时 5 秒，见 AppResetDialog） */
  resetDialog: CustomDialogController = new CustomDialogController({
    builder: AppResetDialog({
      onCancel: (): void => {
        this.resetDialog.close();
      },
      onConfirm: (): void => {
        this.resetDialog.close();
        this.wipeAllData();
      }
    }),
    autoCancel: true,
    customStyle: true
  });

  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 外观刷新计数：主题色 / 灰字 / 沾色改动后由它触发重算 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  /** zip 备份/恢复的进行中标记与结果文案 */
  @State zipBusy: boolean = false;
  /** 语言切换计数：变更时整页重建（key 拼接），文案随词典刷新 */
  @StorageProp('languageTick') languageTick: number = 0;
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
  /** 自动备份间隔（天）：0 = 关闭；1 / 3 / 7 = 每 N 天自动上传一次 */
  @State webdavAutoDays: number = 0;
  /** 上次成功备份的时间戳（0 = 从未） */
  @State webdavLastAt: number = 0;
  /** 自动备份运行状态（AppStorage 由 WebDavStore.maybeAutoBackup 写入） */
  @StorageProp('webdavAutoStatus') webdavAutoStatus: string = '';
  @State backupStatus: string = '';
  @State backing: boolean = false;
  @State restoring: boolean = false;
  @State confirmClearAll: boolean = false;
  /** 全屏放大预览（展开区右上角放大按钮触发）：本地图=file:// URI、网络图=URL */
  @State previewImage: string = '';
  @State previewScale: number = 1;
  private previewPinchBase: number = 1;
  /** 缓存大小文案（storageStatistics 统计，清除后延迟重算） */
  @State cacheSizeText: string = '计算中…';
  /** 批注数据管理：预览展开态 + 跨文档批注聚合 */
  @State annoOpen: boolean = false;
  @State annoPreview: AnnoPreviewItem[] = [];
  @State annoTotal: number = 0;
  @State annoDocs: number = 0;
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
    this.webdavAutoDays = cfg.autoDays;
    this.webdavLastAt = cfg.lastAutoAt;
  }

  private saveWebDavConfig(): void {
    const c = this.ctx();
    if (c === null) {
      this.toast(L10n.t('拿不到应用上下文'));
      return;
    }
    const cfg: WebDavConfig = {
      server: this.webdavServer.trim(),
      user: this.webdavUser.trim(),
      password: this.webdavPassword,
      dir: this.webdavDir.trim().length > 0 ? this.webdavDir.trim() : 'litemdreader',
      autoDays: this.webdavAutoDays,
      lastAutoAt: this.webdavLastAt
    };
    WebDavStore.saveConfig(c, cfg);
    this.toast(L10n.t('WebDAV 配置已保存'));
  }

  /** 设定自动备份间隔（用户要求：可设定多久上传一次）。 */
  private setAutoDays(days: number): void {
    const c = this.ctx();
    if (c === null) {
      return;
    }
    this.webdavAutoDays = days;
    WebDavStore.setAutoDays(c, days);
    if (days <= 0) {
      this.toast(L10n.t('已关闭自动备份'));
    } else {
      this.toast('自动备份：每 ' + days + ' 天（应用启动时检查，到点自动上传）');
    }
  }

  /** 自动备份状态行（间隔 / 上次 / 下次）。 */
  private webdavAutoLine(): string {
    if (this.webdavAutoDays <= 0) {
      return '自动备份：关闭（选择间隔后，应用启动时到点自动上传）';
    }
    const c = this.ctx();
    const line: string = '自动备份：每 ' + this.webdavAutoDays + ' 天'
      + (this.webdavLastAt > 0 ? L10n.t(' · 上次 ') + this.stampOf(this.webdavLastAt) : L10n.t(' · 尚未备份'));
    if (c === null) {
      return line;
    }
    const left: number = WebDavStore.msToNextAuto(c);
    if (left === 0) {
      return line + ' · 已到期（下次启动应用时自动上传）';
    }
    if (left > 0) {
      const hours: number = Math.ceil(left / 3600000);
      return line + ' · 约 ' + (hours >= 24 ? Math.round(hours / 24) + ' 天后' : hours + ' 小时后');
    }
    return line;
  }

  /** 时间戳 → 'MM-DD HH:mm'。 */
  private stampOf(ms: number): string {
    const d: Date = new Date(ms);
    const pad = (v: number): string => {
      return v < 10 ? '0' + v : '' + v;
    };
    return pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  /** WebDAV 间隔选择芯片（选中高亮）。 */
  @Builder
  intervalChip(label: string, days: number) {
    ImmersiveChip({
      palette: this.palette(),
      chipActive: this.webdavAutoDays === days,
      chipLabel: label,
      chipOnTap: () => {
        this.setAutoDays(days);
      }
    })
  }

  /** **应用初始化**：清空全部数据（等同卸载重装），确认弹窗带 5 秒倒计时。 */
  private wipeAllData(): void {
    const c = this.ctx();
    if (c === null) {
      return;
    }
    // ① 持久化设置键逐个删（PersistentStorage 的持久层与 AppStorage 一起清）
    const keys: string[] = SettingsMirror.KEYS;
    for (let i = 0; i < keys.length; i++) {
      try {
        PersistentStorage.deleteProp(keys[i]);
      } catch (err) {
        // 单个键失败不阻断
      }
    }
    // ② 沙箱数据（文档 / 批注 / AI / 备份 / 壁纸 / 草稿 …）与缓存、各类 Preferences
    BackupStore.wipeAll(c).then((msg: string) => {
      this.toast(msg + '，应用即将退出');
      // ③ 退出应用：下次启动就是全新安装的初始状态
      setTimeout(() => {
        c.terminateSelf();
      }, 900);
    }).catch((_err: BusinessError) => {
      this.toast(L10n.t('清空失败，请重试'));
    });
  }

  /** 一键备份：全部文档 + 书架索引 + 阅读设置 + 完整备份包（含 AI 对话记录）。 */
  private runBackup(): void {
    if (this.backing || this.restoring) {
      return;
    }
    // 基础模式（纯离线）：网络备份不可用（用户要求）
    if (UpdateService.isOffline()) {
      this.toast(L10n.t('当前是基础模式（纯离线），网络备份不可用'));
      return;
    }
    const c = this.ctx();
    if (c === null) {
      this.toast(L10n.t('拿不到应用上下文'));
      return;
    }
    // 先落一次配置，避免「改了没保存就备份」用了旧值
    this.saveWebDavConfig();
    const cfg: WebDavConfig = WebDavStore.loadConfig(c);
    if (!WebDavStore.isConfigured(cfg)) {
      this.toast(L10n.t('请先填写服务器地址与账号'));
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
        this.toast(L10n.t('备份完成'));
        // 记一次成功时间（自动备份的到期判定以它为基准）
        this.webdavLastAt = Date.now();
        WebDavStore.markBackedUp(c);
      } else {
        this.backupStatus = '备份中断：' + result.error;
        this.toast(L10n.t('备份中断'));
      }
    }).catch((e: BusinessError) => {
      this.backing = false;
      this.backupStatus = '备份失败：' + e.message;
    });
  }

  /** 从 WebDAV 恢复（确认后执行：整包下载解压，**覆盖**本机同名数据）。 */
  private confirmRestoreWebDav(): void {
    if (this.backing || this.restoring) {
      return;
    }
    if (UpdateService.isOffline()) {
      this.toast(L10n.t('当前是基础模式（纯离线），网络恢复不可用'));
      return;
    }
    const c = this.ctx();
    if (c === null) {
      this.toast(L10n.t('拿不到应用上下文'));
      return;
    }
    const cfg: WebDavConfig = WebDavStore.loadConfig(c);
    if (!WebDavStore.isConfigured(cfg)) {
      this.toast(L10n.t('请先填写服务器地址与账号'));
      return;
    }
    try {
      this.getUIContext().showAlertDialog({
        title: L10n.t('从 WebDAV 恢复备份？'),
        message: L10n.t('会用服务器上的完整备份包覆盖本机同名数据')
          + '（文档、书架、AI 对话记录、批注、设置）。',
        primaryButton: {
          value: L10n.t('取消'),
          action: () => {
            // 什么都不做
          }
        },
        secondaryButton: {
          value: L10n.t('恢复'),
          action: () => {
            this.runRestoreWebDav();
          }
        }
      });
    } catch (err) {
      this.runRestoreWebDav();
    }
  }

  /** 恢复的实际执行体：下载完整备份包 → 整包解压覆盖。 */
  private runRestoreWebDav(): void {
    const c = this.ctx();
    if (c === null) {
      this.toast(L10n.t('拿不到应用上下文'));
      return;
    }
    const cfg: WebDavConfig = WebDavStore.loadConfig(c);
    if (!WebDavStore.isConfigured(cfg)) {
      this.toast(L10n.t('请先填写服务器地址与账号'));
      return;
    }
    this.restoring = true;
    this.backupStatus = '开始恢复…';
    WebDavStore.restoreFull(c, cfg, (label: string) => {
      this.backupStatus = label;
    }).then((msg: string) => {
      this.restoring = false;
      this.backupStatus = msg;
      this.toast(msg.indexOf('失败') >= 0 || msg.indexOf('没有') >= 0 ? L10n.t('恢复未完成') : L10n.t('恢复完成'));
    }).catch((e: BusinessError) => {
      this.restoring = false;
      this.backupStatus = '恢复失败：' + e.message;
    });
  }

  // ══════════════════════ ④ 清空自建文档 ══════════════════════
  // ══════════════════════ ③ 书架数据（内置文档） ══════════════════════

  /** 只列内置文档：用户自建的不在这里删，避免误删 */
  aboutToAppear(): void {
    this.loadBuiltins();
    this.loadWebDavConfig();
    this.refreshCacheSize();
    this.refreshAnnoData();
    this.life.onShow = () => {
      this.loadBuiltins();
      this.refreshCacheSize();
      this.refreshAnnoData();
    };
  }

  /** 缓存大小刷新（清除后延迟 500ms 再读，等系统回收磁盘空间 —— xjau 同款经验）。 */
  private refreshCacheSize(delayMs: number = 0): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    if (delayMs > 0) {
      this.cacheSizeText = '计算中…';
      setTimeout(() => this.refreshCacheSize(0), delayMs);
      return;
    }
    BackupStore.cacheSizeText(ctx).then((s: string) => {
      this.cacheSizeText = s;
    });
  }

  /** 批注形态分类文字（与注释抽屉同一套口径）。 */
  private annoKindLabel(a: MdAnnotation): string {
    if (a.style === 'card') {
      return '学习卡';
    }
    if (a.style === 'wavy') {
      return '波浪线';
    }
    if (a.style === 'dbl') {
      return '手写批注';
    }
    return a.note.length > 0 ? L10n.t('文字批注') : L10n.t('荧光笔');
  }

  /** 跨文档收集全部批注做预览（上限 100 条，超出提示总数）。 */
  private refreshAnnoData(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    DocStore.init(ctx);
    const list: DocMeta[] = DocStore.list(ctx);
    const out: AnnoPreviewItem[] = [];
    let total: number = 0;
    let docs: number = 0;
    for (let k = 0; k < list.length; k++) {
      const arr: MdAnnotation[] = AnnotationStore.load(ctx, list[k].name);
      if (arr.length === 0) {
        continue;
      }
      docs++;
      total += arr.length;
      for (let j = 0; j < arr.length && out.length < 100; j++) {
        const a: MdAnnotation = arr[j];
        out.push({
          docName: list[k].name,
          kind: this.annoKindLabel(a),
          text: a.text.length > 0 ? a.text : L10n.t('（无划选文字）')
        } as AnnoPreviewItem);
      }
    }
    this.annoTotal = total;
    this.annoDocs = docs;
    this.annoPreview = out;
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
    this.toast(L10n.t('已从列表移除（本地文件保留）'));
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
      this.toast(n > 0 ? L10n.t('已恢复 ') + n + ' 篇内置教程' : L10n.t('没有需要恢复的内置教程'));
    } catch (err) {
      this.toast(L10n.t('恢复失败'));
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
        this.toast(L10n.t('删除失败'));
      }
    } catch (err) {
      this.toast('删除失败：' + DocStore.describeError(err as BusinessError));
    }
  }

  /**
   * **导出文档为原格式**（用户要求）：拉系统「另存为」面板，把正文按
   * 原样写到用户选的位置（预填磁盘文件名，md 就是 .md、txt 就是 .txt）。
   */
  private exportMyDoc(meta: DocMeta): void {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      this.toast(L10n.t('拿不到应用上下文'));
      return;
    }
    const ctx = c as common.UIAbilityContext;
    let content: string = '';
    try {
      content = DocStore.readText(ctx, meta);
    } catch (err) {
      this.toast('读取失败：' + DocStore.describeError(err as BusinessError));
      return;
    }
    const docPicker = new picker.DocumentViewPicker(ctx);
    const opts = new picker.DocumentSaveOptions();
    // 预填磁盘文件名（含原扩展名 .md / .txt）——"导出为原格式"就落在这里
    opts.newFileNames = [meta.fileName];
    docPicker.save(opts).then((uris: string[]) => {
      if (uris === null || uris === undefined || uris.length === 0) {
        return;
      }
      try {
        const file: fs.File = fs.openSync(uris[0],
          fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, content);
        fs.closeSync(file);
        this.toast('已导出「' + meta.fileName + '」');
      } catch (writeErr) {
        this.toast('写入失败：' + DocStore.describeError(writeErr as BusinessError));
      }
    }).catch((e: BusinessError) => {
      this.toast('导出失败：' + e.message);
    });
  }

  /** 删除自建文档（确认后连本地文件一起删）。 */
  private confirmDeleteMyDoc(name: string): void {
    try {
      this.getUIContext().showAlertDialog({
        title: L10n.t('删除「') + name + '」？',
        message: L10n.t('本地 md 文件会一并删除，删除后不可恢复。'),
        primaryButton: {
          value: L10n.t('取消'),
          action: () => {
            // 什么都不做
          }
        },
        secondaryButton: {
          value: L10n.t('删除'),
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
   * 「从书架中移除」的**确认弹窗**。
   *
   * 语义（用户要求）：只是**不在书架上显示**，正文仍在应用内，
   * 随时可以在本页「已移除的内置教程」里恢复回书架 —— 所以按钮文案与说明
   * 都按"移除显示"来说，不再说"删除"。
   */
  private confirmResetBuiltins(): void {
    try {
      this.getUIContext().showAlertDialog({
        title: L10n.t('从书架中移除内置文档？'),
        message: L10n.t('内置文档**不能删除**，只能从书架上移除显示。')
          + '移除后书架上看不到它们，但正文仍在应用内，'
          + '随时可以在本页「已移除的内置教程」里恢复回书架。',
        primaryButton: {
          value: L10n.t('取消'),
          action: () => {
            // 什么都不做
          }
        },
        secondaryButton: {
          value: L10n.t('从书架中移除'),
          action: () => {
            this.resetBuiltins();
          }
        }
      });
    } catch (err) {
      this.resetBuiltins();
    }
  }

  /**
   * 把内置文档从书架移除（登记进隐藏名单）。
   *
   * ⚠️ 上一版走的是 `DocStore.remove()` —— 它对内置文档**直接返回 false**
   * （内置不落盘、不该删），于是按钮点了等于没反应。正确入口是 `hideBuiltin()`：
   * 只登记"不在书架显示"，正文与记录都留着，恢复回书架时不丢封面与进度。
   */
  private resetBuiltins(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    let n: number = 0;
    for (let k: number = 0; k < this.builtinList.length; k++) {
      try {
        if (DocStore.hideBuiltin(ctx, this.builtinList[k].name)) {
          n++;
        }
      } catch (err) {
        // 单个失败继续
      }
    }
    this.pendingDeleteDoc = '';
    this.loadBuiltins();
    this.toast(n > 0
      ? L10n.t('已从书架移除 ') + n + ' 篇内置文档，可在本页恢复'
      : L10n.t('内置文档本来就已全部移除'));
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
      // 打包用的临时 zip 落在 cacheDir，导出完刷新缓存大小
      this.refreshCacheSize(500);
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
        // 恢复流程内部已经把 DocStore / 两份日志 / 标签页的内存缓存按磁盘重建过，
        // 这里不能再调 DocStore.init()（有 ready 门闩，等于什么都不做），
        // 回到书架时 Index 的延迟 refresh 会读到恢复后的索引。
        this.refreshCacheSize(600);
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
      // 清完延迟重算缓存大小（等系统回收磁盘空间）
      this.refreshCacheSize(500);
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

      Text(L10n.t('点此关闭'))
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
      shellTitle: L10n.t('数据管理'),
      shellSubtitle: L10n.t('备份与恢复 · 书架数据 · 缓存'),
      stack: this.stack,
      life: this.life
    }) {
      // ── ① 备份与恢复 ──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Text(L10n.t('把**整个应用的全部数据**打包成一个 zip 导出到你选的位置：文档正文与图片、') + '书架索引与文件夹、批注与学习卡、手写笔迹、复习数据、阅读与写作日志、'
            + 'AI 对话与配置、草稿、字体、壁纸与阅读背景、全部设置，以及 WebDAV 账号配置。'
            + '导入会覆盖同名数据，回到书架即刻生效（不必重启应用）；'
            + '导入前请先退出正在编辑的文档，否则编辑器里的旧内容可能盖回恢复结果。')
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
              chipLabel: this.zipBusy ? L10n.t('处理中…') : L10n.t('导出备份'),
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
              chipLabel: L10n.t('导入备份'),
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
              chipLabel: L10n.t('清除缓存'),
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

          // **当前缓存大小**（用户要求：清除缓存要能看到大小）
          Text(L10n.t('当前缓存大小：') + this.cacheSizeText
            + '（缓存可随时清除，不影响文档 / 批注等用户数据）')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── ② 批注数据管理（用户要求：预览全部批注；批注随全量备份打包）──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Text(L10n.t('批注数据管理'))
            .fontSize(HwType.label + 1)
            .fontColor(this.palette().textPrimary)
          Text(L10n.t('全部批注共 ') + this.annoTotal + ' 条，覆盖 ' + this.annoDocs + ' 篇文档。'
            + '批注随「导出备份」一并打包（annotations 目录），预览最多列出 100 条。')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwType.caption * 1.7)
            .width('100%')

          ImmersiveChip({
            palette: this.palette(),
            chipActive: this.annoOpen,
            chipLabel: this.annoOpen ? L10n.t('收起预览') : L10n.t('预览全部批注'),
            chipOnTap: () => {
              this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
                this.annoOpen = !this.annoOpen;
              });
            }
          }) {
            SymbolGlyph($r('sys.symbol.doc_text'))
              .fontSize(13)
              .fontColor([this.palette().accent])
          }

          if (this.annoOpen) {
            Scroll() {
              Column({ space: HwSpace.xs }) {
                ForEach(this.annoPreview, (it: AnnoPreviewItem, idx: number) => {
                  Column({ space: 2 }) {
                    Row({ space: HwSpace.xs }) {
                      Text(it.kind)
                        .fontSize(HwType.caption - 1)
                        .fontColor(this.palette().accent)
                        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                        .borderRadius(HwRadius.pill)
                        .backgroundColor(this.palette().quoteBg)
                      Text(it.docName)
                        .fontSize(HwType.caption - 1)
                        .fontColor(this.palette().textTertiary)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center)

                    Text(it.text)
                      .fontSize(HwType.label)
                      .fontColor(this.palette().textPrimary)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                  .padding(HwSpace.sm)
                  .borderRadius(HwRadius.inline)
                  .backgroundColor(this.palette().quoteBg)
                }, (it: AnnoPreviewItem, idx: number) => 'ap_' + idx + '_' + it.docName + '_' + it.kind)
              }
              .width('100%')
            }
            .width('100%')
            .constraintSize({ maxHeight: 320 })
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .align(Alignment.Top)
            .transition(TransitionEffect.OPACITY
              .animation({ duration: 240, curve: Curve.FastOutSlowIn }))
          }

          if (this.annoTotal > 100 && this.annoOpen) {
            Text(L10n.t('共 ') + this.annoTotal + ' 条，仅显示前 100 条 —— 全部内容以备份文件为准。')
              .fontSize(HwType.caption - 1)
              .fontColor(this.palette().textTertiary)
              .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── ③ 书架数据（内置文档） ──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Text(L10n.t('书架数据'))
            .fontSize(HwType.label + 1)
            .fontColor(this.palette().textPrimary)
          Text(L10n.t('内置文档共 ') + this.builtinList.length + ' 篇 —— **内置文档不能删除**，'
            + '只能从书架上移除显示（移除后可在本页恢复）。下方「我的文档」是你的自建内容。')
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
                Text(L10n.t('内置'))
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
              chipLabel: L10n.t('从书架中移除'),
              chipOnTap: () => {
                this.confirmResetBuiltins();
              }
            })
          }

          // ── 我的文档（自建）──
          Divider().strokeWidth(1).color(this.palette().divider)

          Text(L10n.t('我的文档（') + this.myDocs.length + ' 篇）')
            .fontSize(HwType.label)
            .fontColor(this.palette().textPrimary)
            .width('100%')

          if (this.myDocs.length === 0) {
            Text(L10n.t('还没有自建文档，去书架新建一篇试试'))
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

                // **导出（原格式）**：拉系统"另存为"，写回一份 .md / .txt 原文
                //（用户要求：删除按钮左边加一个绿色导出按钮）
                ImmersiveChip({
                  palette: this.palette(),
                  chipTint: '#FF2E9E4F',
                  chipActive: true,
                  chipLabel: L10n.t('导出'),
                  chipOnTap: () => {
                    this.exportMyDoc(meta);
                  }
                })
                // 自建文档**可以删除**（与内置不同）：删除连本地文件一起
                ImmersiveChip({
                  palette: this.palette(),
                  chipTint: '#FFD32F2F',
                  chipActive: true,
                  chipLabel: L10n.t('删除'),
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

          Text(L10n.t('图片管理'))
            .fontSize(HwType.label + 1)
            .fontColor(this.palette().textPrimary)
            .width('100%')
          Text(L10n.t('本地图片 ') + this.localImages.length + ' 张 · 网络图片 ' + this.netImages
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
                Text(L10n.t('本地图片（手写笔记 / 插图）· 点击可查看'))
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
                chipLabel: L10n.t('导出'),
                chipOnTap: () => {
                  this.exportImage(name);
                }
              })
              ImmersiveChip({
                palette: this.palette(),
                chipTint: '#FFD32F2F',
                chipActive: true,
                chipLabel: L10n.t('删除'),
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
                Text(L10n.t('网络图片 · 点击可查看'))
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
                chipLabel: L10n.t('删除'),
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
              Text(L10n.t('已移除的内置教程'))
                .fontSize(HwType.label)
                .fontColor(this.palette().textPrimary)
              Text(this.hiddenBuiltins.length > 0
                ? L10n.t('书架上看不到：') + this.hiddenBuiltins.join('、')
                : L10n.t('没有移除过内置教程'))
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
                chipLabel: L10n.t('恢复'),
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
          Text(L10n.t('WebDAV 备份'))
            .fontSize(HwType.label + 1)
            .fontColor(this.palette().textPrimary)
          Text(L10n.t('上传全部文档与完整备份包（含 AI 对话记录、批注、手写、设置）到你的 WebDAV 服务器；凭据只存在本机。恢复时下载完整备份包整包还原'))
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
              chipLabel: L10n.t('保存配置'),
              chipOnTap: () => {
                this.saveWebDavConfig();
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipTint: '#FF2E7D32',
              chipActive: !this.backing && !this.restoring,
              chipLabel: this.backing ? L10n.t('备份中…') : L10n.t('立即备份'),
              chipOnTap: () => {
                this.runBackup();
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipTint: '#FF1565C0',
              chipActive: !this.backing && !this.restoring,
              chipLabel: this.restoring ? L10n.t('恢复中…') : L10n.t('恢复备份'),
              chipOnTap: () => {
                this.confirmRestoreWebDav();
              }
            })
          }
          .width('100%')

          // ── 自动备份间隔（用户要求：支持设定多久上传一次）──
          Text(this.webdavAutoLine())
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')
          Flex({
            wrap: FlexWrap.Wrap,
            space: { main: LengthMetrics.vp(HwSpace.xs), cross: LengthMetrics.vp(HwSpace.xs) }
          }) {
            this.intervalChip('关闭', 0)
            this.intervalChip('每天', 1)
            this.intervalChip('每 3 天', 3)
            this.intervalChip('每周', 7)
          }
          .width('100%')
          // 间隔切换的提示行出现 / 消失带过渡（凡事带动画）
          .animation({ duration: 200, curve: Curve.FastOutSlowIn })

          if (this.webdavAutoStatus.length > 0) {
            Text(L10n.t('上次自动任务：') + this.webdavAutoStatus)
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
              .width('100%')
          }

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

      // ── **应用初始化**（用户要求：清空全部数据，等同卸载重装；确认键倒计时 5 秒）──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Text(L10n.t('应用初始化'))
            .fontSize(HwType.label + 1)
            .fontColor('#FFD93B3B')
            .fontWeight(FontWeight.Medium)
          Text(L10n.t('清空应用的全部数据：文档与文件夹、批注与手写、AI 配置与对话记录、') + '阅读设置与外观、版本历史与备份记录。效果等同于卸载后重装，且无法恢复。')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwType.caption * 1.7)
            .width('100%')
          ImmersiveChip({
            palette: this.palette(),
            chipTint: '#FFD93B3B',
            chipActive: true,
            chipLabel: L10n.t('应用初始化…'),
            chipOnTap: () => {
              this.resetDialog.open();
            }
          }) {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(13)
              .fontColor(['#FFD93B3B'])
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
