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
import { ImmersiveCard, ImmersiveChip } from '../material/ImmersiveCard';
import { ImmersiveInput } from '../material/ImmersiveInput';
import { SettingsShell } from './SettingsShell';
import { BackupStore } from '../service/BackupStore';
import { WebDavConfig, WebDavResult, WebDavStore } from '../service/WebDavStore';
import { DocMeta, DocStore } from '../service/DocStore';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
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
  @State pendingDeleteDoc: string = '';
  /** WebDAV 备份配置与状态 */
  @State webdavServer: string = '';
  @State webdavUser: string = '';
  @State webdavPassword: string = '';
  @State webdavDir: string = 'litemdreader';
  @State backupStatus: string = '';
  @State backing: boolean = false;
  /** 待确认清空自建文档 */
  @State confirmClearAll: boolean = false;

  private palette(): ReaderPalette {
    // 读一下外观刷新计数，主题色 / 灰字 / 沾色改完**当帧**就能重算
    const tick: number = this.appearanceTick;
    return paletteFor(this.themeMode, this.systemDark);
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

  private clearAllMine(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    this.confirmClearAll = false;
    let n: number = 0;
    try {
      const list: DocMeta[] = DocStore.list(ctx);
      for (let k = 0; k < list.length; k++) {
        if (!DocStore.isBuiltinName(list[k].name)) {
          if (DocStore.remove(ctx, list[k].name)) {
            n++;
          }
        }
      }
    } catch (err) {
      this.toast('清空失败：' + DocStore.describeError(err as BusinessError));
      return;
    }
    this.loadBuiltins();
    this.toast('已清空 ' + n + ' 篇自建文档');
  }

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
      for (let k = 0; k < list.length; k++) {
        if (DocStore.isBuiltinName(list[k].name)) {
          builtins.push(list[k]);
        }
      }
      this.builtinList = builtins;
      // 已被用户从书架移除（隐藏）的内置教程名单——在这里可以一键恢复
      this.hiddenBuiltins = DocStore.hiddenBuiltinList();
    } catch (err) {
      // 统计失败不阻断
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
          Text('内置文档共 ' + this.builtinList.length + ' 篇。删除会**连本地文件一起删**，' +
            '重启应用时内置教程会自动重新生成；你自建的文档不在此处，避免误删。')
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

                if (this.pendingDeleteDoc !== meta.name) {
                  ImmersiveChip({
                    palette: this.palette(),
                    chipLabel: '删除',
                    chipOnTap: () => {
                      this.pendingDeleteDoc = meta.name;
                    }
                  })
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              // 二次确认：删之前明确问一句「要不要删本地文件」
              if (this.pendingDeleteDoc === meta.name) {
                Text('确定删除吗？本地 md 文件会一并删除')
                  .fontSize(HwType.caption)
                  .fontColor(this.palette().accent)
                  .width('100%')
                Row({ space: HwSpace.xs }) {
                  ImmersiveChip({
                    palette: this.palette(),
                    chipActive: true,
                    chipLabel: '删除（含本地文件）',
                    chipOnTap: () => {
                      this.deleteBuiltin(meta.name);
                    }
                  })
                  ImmersiveChip({
                    palette: this.palette(),
                    chipLabel: '取消',
                    chipOnTap: () => {
                      this.pendingDeleteDoc = '';
                    }
                  })
                }
                .width('100%')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }, (meta: DocMeta) => 'bd_' + meta.name)

          if (this.builtinList.length > 1) {
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '全部移除（重启后重新生成）',
              chipOnTap: () => {
                this.resetBuiltins();
              }
            })
          }

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

      // ── ④ 清空自建文档 ──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Text('清空自建文档')
            .fontSize(HwType.label + 1)
            .fontColor(this.palette().textPrimary)
          Text('删除全部自建文档及其批注；内置教程不受影响。此操作不可撤销。')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwType.caption * 1.7)
            .width('100%')

          if (!this.confirmClearAll) {
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '清空全部自建文档',
              chipOnTap: () => {
                this.confirmClearAll = true;
              }
            })
          } else {
            Text('确定清空吗？删除后无法恢复')
              .fontSize(HwType.caption)
              .fontColor(this.palette().accent)
              .width('100%')
            Row({ space: HwSpace.xs }) {
              ImmersiveChip({
                palette: this.palette(),
                chipActive: true,
                chipLabel: '确认清空',
                chipOnTap: () => {
                  this.clearAllMine();
                }
              })
              ImmersiveChip({
                palette: this.palette(),
                chipLabel: '取消',
                chipOnTap: () => {
                  this.confirmClearAll = false;
                }
              })
            }
            .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
  }
}
