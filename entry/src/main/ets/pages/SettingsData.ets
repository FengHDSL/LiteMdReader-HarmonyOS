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
import { RecycleItem, RecycleStore } from '../service/RecycleStore';
import { ExportService } from '../service/ExportService';
import { SettingsMirror } from '../service/SettingsMirror';
import { AppResetDialog } from '../components/AppResetDialog';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { AnnotationStore } from '../service/AnnotationStore';
import { MdAnnotation } from '../markdown/MdTypes';
import { AppearanceFx } from '../service/AppearanceFx';
import {
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  paletteFor,
  HwFont
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
  /** **界面字体**（外观设置 → 界面字体）：本页界面文字都从这里取 */
  @StorageProp('appFontFamily') uiFontKey: string = '';
  /** 界面字号缩放系数 / 界面字重相对加粗量（外观设置） */
  @StorageProp('appFontScale') uiFontScale: number = 1;
  @StorageProp('appFontWeightDelta') uiFontWeightDelta: number = 0;
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
  /** **回收站**：条目列表（按删除时间倒序，读的时候服务层已惰性清掉过期项） */
  @State recycleItems: RecycleItem[] = [];
  /** 回收站自动清空档位（天）：0 = 不自动清空 */
  @State recycleDays: number = 0;

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

  // ══════════════════════ ⑤ 回收站 ══════════════════════

  /** 时间戳 → 'YYYY-MM-DD HH:MM'（ArkTS 里 toLocaleString 行为不稳，手工拼）。 */
  private recycleStamp(ms: number): string {
    const d: Date = new Date(ms);
    const pad = (v: number): string => {
      return v < 10 ? '0' + v : '' + v;
    };
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
      + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  /** 进页面时读回收站（档位 + 条目；list 内部已按档位惰性清掉过期项）。 */
  private reloadRecycle(): void {
    const c = this.ctx();
    if (c === null) {
      return;
    }
    // 注意：服务层 getPurgeDays 把 0 归一成 7（RecycleStore.ets:139），
    // 所以进页面时「不自动清空」这一档读回来是 7——只能靠下面 setRecycleDays 记住用户刚点的。
    this.recycleDays = RecycleStore.getPurgeDays(c);
    this.recycleItems = RecycleStore.list(c);
  }

  /** 只重取条目、不动档位：恢复 / 彻底删除 / 清空后用，避免把用户刚选的档位刷回归一值。 */
  private refreshRecycleItems(): void {
    const c = this.ctx();
    if (c === null) {
      return;
    }
    this.recycleItems = RecycleStore.list(c);
  }

  /** 自动清空档位（2 / 5 / 7 / 30 天，0 = 不自动清空）。 */
  private setRecycleDays(days: number): void {
    const c = this.ctx();
    if (c === null) {
      return;
    }
    RecycleStore.setPurgeDays(c, days);
    // 档位直接按刚点的回填，不再回读一次（省一次 IO；0 = 不自动清空已是合法档位）
    this.recycleDays = days;
    this.recycleItems = RecycleStore.list(c);
    if (days <= 0) {
      this.toast(L10n.t('回收站不再自动清空'));
    } else {
      this.toast('自动清空：删除后保留 ' + days + ' 天（当前 ' + this.recycleItems.length + ' 项）');
    }
  }

  /** 回收条目的类型名（副标题为空时兜底用它）。 */
  private recycleKindName(kind: string): string {
    if (kind === 'doc') {
      return L10n.t('文档');
    }
    if (kind === 'image') {
      return L10n.t('图片');
    }
    return L10n.t('批注');
  }

  /** **恢复**：restore 只负责把文件移回原位，文档重建 / 批注写回在这里分流。 */
  /** 从当前列表里按 id 找条目（恢复前判类型与同名用；找不到返回 null） */
  private recyclePending(id: string): RecycleItem | null {
    for (let k = 0; k < this.recycleItems.length; k++) {
      if (this.recycleItems[k].id === id) {
        return this.recycleItems[k];
      }
    }
    return null;
  }

  private restoreRecycleItem(id: string): void {
    const c = this.ctx();
    if (c === null) {
      return;
    }
    // **恢复前先探同名**：RecycleStore.restore 第一步就把条目从列表里摘掉，
    // 若随后 DocStore.create 因同名失败，正文就两头落空（回收站没了、书架也没回来）。
    const pending: RecycleItem | null = this.recyclePending(id);
    if (pending !== null && pending.kind === 'doc' && DocStore.find(c, pending.docName) !== undefined) {
      this.toast(L10n.t('已有一篇同名文档，先改个名或删掉它再恢复'));
      return;
    }
    const it: RecycleItem | null = RecycleStore.restore(c, id);
    if (it === null) {
      this.toast(L10n.t('这条已经不在了'));
      this.refreshRecycleItems();
      return;
    }
    if (it.kind === 'doc') {
      const meta: DocMeta | null = DocStore.create(c, it.docName, it.content);
      if (meta === null) {
        this.toast(L10n.t('恢复失败：同名文档已存在'));
      } else {
        this.toast(L10n.t('已恢复到书架'));
      }
    } else if (it.kind === 'anno') {
      if (RecycleStore.restoreAnno(c, it)) {
        this.toast(L10n.t('批注已恢复'));
      } else {
        this.toast(L10n.t('原文档不在了，批注无法恢复'));
      }
    } else {
      this.toast(L10n.t('图片已移回'));
    }
    this.refreshRecycleItems();
    // 恢复的东西要立刻出现在书架 / 图片列表里（loadBuiltins 是本页的书架刷新入口）
    this.loadBuiltins();
  }

  /** **彻底删除单个**：不可恢复，必须弹窗二次确认。 */
  private askPurgeRecycleItem(item: RecycleItem): void {
    const c = this.ctx();
    if (c === null) {
      return;
    }
    this.getUIContext().getPromptAction().showDialog({
      title: L10n.t('彻底删除'),
      message: L10n.t('将永久删除「') + item.title + L10n.t('」，删掉之后**不可恢复**，回收站里的沙箱副本会一并删除。'),
      buttons: [
        { text: L10n.t('取消'), color: this.palette().textSecondary },
        { text: L10n.t('彻底删除'), color: '#FFD93B3B' }
      ]
    }).then((result) => {
      if (result.index !== 1) {
        return;
      }
      RecycleStore.purgeOne(c, item.id);
      // 彻底删除只动回收站，书架 / 图片列表不受影响 → 只需重取条目
      this.refreshRecycleItems();
      this.toast(L10n.t('已彻底删除'));
    }).catch((err: BusinessError) => {
      this.toast('操作失败：' + err.message);
    });
  }

  /** **一键清空**：同样弹窗确认，文案里带上要删掉多少项。 */
  private askPurgeRecycleAll(): void {
    const c = this.ctx();
    if (c === null) {
      return;
    }
    const count: number = this.recycleItems.length;
    this.getUIContext().getPromptAction().showDialog({
      title: L10n.t('清空回收站'),
      message: L10n.t('将彻底删除回收站里的 ') + count + L10n.t(' 项内容（文档、图片、批注与手写笔记），不可恢复。'),
      buttons: [
        { text: L10n.t('取消'), color: this.palette().textSecondary },
        { text: L10n.t('清空'), color: '#FFD93B3B' }
      ]
    }).then((result) => {
      if (result.index !== 1) {
        return;
      }
      RecycleStore.purgeAll(c);
      // 清空同样不动书架；档位保持用户刚选的，不回读归一值
      this.refreshRecycleItems();
      this.toast(L10n.t('已清空回收站'));
    }).catch((err: BusinessError) => {
      this.toast('操作失败：' + err.message);
    });
  }

  /** 自动清空档位芯片（选中高亮）。 */
  @Builder
  recycleDaysChip(label: string, days: number) {
    ImmersiveChip({
      palette: this.palette(),
      chipActive: this.recycleDays === days,
      chipLabel: label,
      chipOnTap: () => {
        this.setRecycleDays(days);
      }
    })
  }

  /** 类型图标：$r() 的参数必须是字面量，所以按 kind 三个分支各写一份。 */
  @Builder
  recycleKindIcon(kind: string) {
    if (kind === 'doc') {
      SymbolGlyph($r('sys.symbol.doc_text'))
        .fontSize(16)
        .fontColor([this.palette().accent])
    } else if (kind === 'image') {
      SymbolGlyph($r('sys.symbol.picture'))
        .fontSize(16)
        .fontColor([this.palette().accent])
    } else {
      SymbolGlyph($r('sys.symbol.highlighter_line'))
        .fontSize(16)
        .fontColor([this.palette().accent])
    }
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
    this.reloadRecycle();
    this.life.onShow = () => {
      // 第一次 onShown 紧跟 aboutToAppear（四项刚算过），跳过；之后回到本页
      // 才重算，而且**等转场落定**：loadBuiltins 逐内置文档探测文件系统，
      // 压在进场那一帧就是审核报告里的转场卡顿。
      if (!this.shownOnce) {
        this.shownOnce = true;
        return;
      }
      setTimeout((): void => {
        this.loadBuiltins();
        this.refreshCacheSize();
        this.refreshAnnoData();
        this.reloadRecycle();
      }, 300);
    };
  }

  /** 第一次 onShown 是否已经消费过（见上面 onShow 的跳过分支）。 */
  private shownOnce: boolean = false;

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

  /**
   * **导出网络图片**（用户要求）：先按 URL 下载（超时 15/20 秒），再走系统另存为。
   * 文件名取 URL 末段（去掉查询参数），没有扩展名时补 .png。
   */
  private exportNetImage(url: string): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    this.toast('正在下载网络图片…');
    const req = http.createHttp();
    req.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 15000,
      readTimeout: 20000
    }).then((resp: http.HttpResponse) => {
      req.destroy();
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        let name: string = url.split('?')[0].split('/').pop() ?? '';
        if (name.length === 0 || name.indexOf('.') < 0) {
          name = (name.length > 0 ? name : 'image') + '.png';
        }
        ExportService.saveBytes(ctx, name, resp.result as ArrayBuffer, (m: string) => {
          this.toast(m);
        });
      } else {
        this.toast('下载失败：HTTP ' + resp.responseCode);
      }
    }).catch((err: BusinessError) => {
      req.destroy();
      this.toast('下载失败：' + err.message);
    });
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

  /**
   * **找回未登记的文档**：把 docs 目录里躺着、书架索引里却没有的文档重新登记回书架。
   * 索引与目录脱节时（旧版备份导入没把 shelf.json 写回来、用文件管理器往 docs 里塞了
   * 文件、索引被写坏），那些文档在应用里**永久隐身**，却会被备份的整目录扫描捞进包里
   * —— 用户看到的就是"压缩包里一堆我根本没有的文件"。
   */
  private adoptOrphanDocs(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      this.toast(L10n.t('拿不到应用上下文'));
      return;
    }
    try {
      const names: string[] = DocStore.adoptOrphans(ctx);
      this.loadBuiltins();
      if (names.length === 0) {
        this.toast(L10n.t('没有需要找回的文档：目录里的文件都已在书架上'));
        return;
      }
      this.toast('找回 ' + names.length + ' 篇：' + names.slice(0, 3).join('、')
        + (names.length > 3 ? '…' : ''));
    } catch (err) {
      this.toast('找回失败：' + DocStore.describeError(err as BusinessError));
    }
  }

  /** 删除内置文档：确认后连本地文件一起删（DocStore.remove 的语义） */
  private deleteBuiltin(name: string): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    // **入回收站**（用户要求：删除可找回；外部导入的用户目录源文件从未被触碰）
    try {
      const meta: DocMeta | undefined = DocStore.find(ctx, name);
      const content: string = meta !== undefined ? DocStore.readText(ctx, meta) : '';
      RecycleStore.addDoc(ctx, name, content, name,
        JSON.stringify({ lastOpen: meta !== undefined ? meta.lastOpen : 0 }));
    } catch (err) {
      // 快照失败不阻塞删除
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
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
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
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
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
          Text(L10n.t('把全部数据按类别打包成一个 zip：文档、图片、批注、设置等十几类，包内附 manifest 清单。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwFont.sx(HwType.caption * 1.7, this.uiFontScale))
            .width('100%')
          Text(L10n.t('导入时按清单逐类写回原位置。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwFont.sx(HwType.caption * 1.7, this.uiFontScale))
            .width('100%')
          Text(L10n.t('导入会覆盖同名文件，但不会删除本机多出来的数据；回到书架即刻生效，不必重启应用。导入前请先退出正在编辑的文档，否则编辑器里的旧内容可能盖回恢复结果。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwFont.sx(HwType.caption * 1.7, this.uiFontScale))
            .width('100%')
          Text(L10n.t('三篇内置演示文档的正文始终从应用包内读取，沙箱里那几份副本应用永远不读、也能随安装复原，所以不进包——包里只会是你自己产生的数据。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwFont.sx(HwType.caption * 1.7, this.uiFontScale))
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
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().accent)
              .width('100%')
          }

          // **当前缓存大小**（用户要求：清除缓存要能看到大小）
          Text(L10n.f1('当前缓存大小：%1（缓存也进备份包，可随时清除，不影响文档 / 批注等用户数据）', this.cacheSizeText))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
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
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
            .fontColor(this.palette().textPrimary)
          Text(L10n.t('全部批注共 ') + this.annoTotal + ' 条，覆盖 ' + this.annoDocs + ' 篇文档。'
            + '批注随「导出备份」一并打包（annotations 目录），预览最多列出 100 条。')
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwFont.sx(HwType.caption * 1.7, this.uiFontScale))
            .width('100%')

          ImmersiveChip({
            palette: this.palette(),
            chipActive: this.annoOpen,
            chipLabel: this.annoOpen ? L10n.t('收起预览') : L10n.t('预览全部批注'),
            chipOnTap: () => {
              this.getUIContext().animateTo(AppearanceFx.anim(240, Curve.FastOutSlowIn), () => {
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
                        .fontFamily(HwFont.resolve(this.uiFontKey))
                        .fontSize(HwFont.sx(HwType.caption - 1, this.uiFontScale))
                        .fontColor(this.palette().accent)
                        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                        .borderRadius(HwRadius.pill)
                        .backgroundColor(this.palette().quoteBg)
                      Text(it.docName)
                        .fontFamily(HwFont.resolve(this.uiFontKey))
                        .fontSize(HwFont.sx(HwType.caption - 1, this.uiFontScale))
                        .fontColor(this.palette().textTertiary)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center)

                    Text(it.text)
                      .fontFamily(HwFont.resolve(this.uiFontKey))
                      .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
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
              .animation(AppearanceFx.anim(240, Curve.FastOutSlowIn)))
          }

          if (this.annoTotal > 100 && this.annoOpen) {
            Text(L10n.t('共 ') + this.annoTotal + ' 条，仅显示前 100 条 —— 全部内容以备份文件为准。')
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption - 1, this.uiFontScale))
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
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
            .fontColor(this.palette().textPrimary)
          Text(L10n.t('内置文档共 ') + this.builtinList.length + ' 篇 —— **内置文档不能删除**，'
            + '只能从书架上移除显示（移除后可在本页恢复）。下方「我的文档」是你的自建内容。')
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwFont.sx(HwType.caption * 1.7, this.uiFontScale))
            .width('100%')

          ForEach(this.builtinList, (meta: DocMeta) => {
            Column({ space: HwSpace.xs }) {
              Row({ space: HwSpace.sm }) {
                Column({ space: 2 }) {
                  Text(meta.name)
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
                    .fontColor(this.palette().textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(meta.wordCount + ' 字 · ' + DocStore.formatTime(meta.mtime))
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                    .fontColor(this.palette().textTertiary)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                // 内置文档**不提供删除按钮**（用户要求：不支持删除）
                Text(L10n.t('内置'))
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
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
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontColor(this.palette().textPrimary)
            .width('100%')

          if (this.myDocs.length === 0) {
            Text(L10n.t('还没有自建文档，去书架新建一篇试试'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
              .width('100%')
          } else {
            ForEach(this.myDocs, (meta: DocMeta) => {
              Row({ space: HwSpace.sm }) {
                Column({ space: 2 }) {
                  Text(meta.name)
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
                    .fontColor(this.palette().textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(meta.wordCount + ' 字 · ' + DocStore.formatTime(meta.mtime))
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
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

          // ── 找回未登记的文档（索引与 docs 目录脱节时的自救入口）──
          Divider().strokeWidth(1).color(this.palette().divider)

          Text(L10n.t('书架按索引显示、不扫描目录：索引里没登记的文档，即使文件还在 docs 目录里也看不见（却会被备份打包，看起来就像"包里多出一堆没有的文件"）。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwFont.sx(HwType.caption * 1.7, this.uiFontScale))
            .width('100%')
          ImmersiveChip({
            palette: this.palette(),
            chipActive: true,
            chipLabel: L10n.t('找回未登记的文档'),
            chipOnTap: () => {
              this.adoptOrphanDocs();
            }
          }) {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(13)
              .fontColor([this.palette().accent])
          }
          Text(L10n.t('按目录重新登记一遍：只加不删、不改文件名，内置演示文档的残留副本不会被登记。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwFont.sx(HwType.caption * 1.7, this.uiFontScale))
            .width('100%')

          // ── 图片管理（用户要求）：展示手写笔记 / 插入的本地图片 / 网络图片，
          // 支持导出与移除（移除**不删除本地文件**）──
          Divider().strokeWidth(1).color(this.palette().divider)

          Text(L10n.t('图片管理'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
            .fontColor(this.palette().textPrimary)
            .width('100%')
          Text(L10n.t('本地图片 ') + this.localImages.length + ' 张 · 网络图片 ' + this.netImages
            + ' 张。删除只从列表移除，**不会删除本地文件**。')
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
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
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
                  .fontColor(this.palette().textPrimary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(L10n.t('本地图片（手写笔记 / 插图）· 点击可查看'))
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
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
                  // **删除入回收站**（用户要求：可找回）——文件移入回收站，不再只是隐藏
                  const rctx = this.ctx();
                  if (rctx !== null && RecycleStore.addImage(rctx, name)) {
                    this.loadImageItems();
                    this.toast(L10n.t('已移入回收站'));
                  } else {
                    this.hideImage('local', name);
                  }
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
                    .animation(AppearanceFx.anim(240, Curve.FastOutSlowIn)))
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
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
                  .fontColor(this.palette().textPrimary)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(L10n.t('网络图片 · 点击可查看'))
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
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
                chipTint: '#FF2E7D32',
                chipActive: true,
                chipLabel: L10n.t('导出'),
                chipOnTap: () => {
                  this.exportNetImage(url);
                }
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
                    .animation(AppearanceFx.anim(240, Curve.FastOutSlowIn)))
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
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
                .fontColor(this.palette().textPrimary)
              Text(this.hiddenBuiltins.length > 0
                ? L10n.t('书架上看不到：') + this.hiddenBuiltins.join('、')
                : L10n.t('没有移除过内置教程'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                .fontColor(this.palette().textTertiary)
                .maxLines(2)
                .lineHeight(HwFont.sx(HwType.caption * 1.6, this.uiFontScale))
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

      // ── ⑤ 回收站（删除的文档 / 图片 / 批注 / 手写笔记先进这里，可找回）──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Text(L10n.t('回收站'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
            .fontColor(this.palette().textPrimary)
          Text(L10n.t('删除的文档、图片、批注与手写笔记会先进这里，可找回；外部导入的文档应用从不触碰你目录里的源文件，只有应用内新建的文档，彻底删除时才会真的删掉沙箱副本。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwFont.sx(HwType.caption * 1.7, this.uiFontScale))
            .width('100%')

          // ── 自动清空档位 ──
          Text(L10n.t('自动清空'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontColor(this.palette().textPrimary)
            .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
            .width('100%')
          Flex({
            wrap: FlexWrap.Wrap,
            space: { main: LengthMetrics.vp(HwSpace.xs), cross: LengthMetrics.vp(HwSpace.xs) }
          }) {
            this.recycleDaysChip('2 天', 2)
            this.recycleDaysChip('5 天', 5)
            this.recycleDaysChip('7 天', 7)
            this.recycleDaysChip('30 天', 30)
            this.recycleDaysChip('不自动清空', 0)
          }
          .width('100%')
          // 档位切换的提示出现 / 消失带过渡（凡事带动画）
          .animation(AppearanceFx.anim(200, Curve.FastOutSlowIn))

          Divider().strokeWidth(1).color(this.palette().divider)

          // ── 条目列表 ──
          if (this.recycleItems.length === 0) {
            Text(L10n.t('回收站是空的'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
              .width('100%')
          } else {
            ForEach(this.recycleItems, (item: RecycleItem) => {
              Row({ space: HwSpace.sm }) {
                this.recycleKindIcon(item.kind)
                Column({ space: 2 }) {
                  Text(item.title)
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
                    .fontColor(this.palette().textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (item.sub.length > 0) {
                    Text(item.sub)
                      .fontFamily(HwFont.resolve(this.uiFontKey))
                      .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                      .fontColor(this.palette().textTertiary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  } else {
                    Text(this.recycleKindName(item.kind))
                      .fontFamily(HwFont.resolve(this.uiFontKey))
                      .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                      .fontColor(this.palette().textTertiary)
                  }
                  Text(L10n.t('删除于 ') + this.recycleStamp(item.deletedAt))
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(HwType.caption - 1, this.uiFontScale))
                    .fontColor(this.palette().textTertiary)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                ImmersiveChip({
                  palette: this.palette(),
                  chipActive: true,
                  chipLabel: L10n.t('恢复'),
                  chipOnTap: () => {
                    this.restoreRecycleItem(item.id);
                  }
                })
                ImmersiveChip({
                  palette: this.palette(),
                  chipTint: '#FFD32F2F',
                  chipActive: true,
                  chipLabel: L10n.t('彻底删除'),
                  chipOnTap: () => {
                    this.askPurgeRecycleItem(item);
                  }
                })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }, (item: RecycleItem) => item.id + '_' + this.recycleItems.length)
          }

          // ── 底部：总数 + 一键清空（空列表不出现清空入口）──
          Row({ space: HwSpace.sm }) {
            Text(L10n.t('共 ') + this.recycleItems.length + L10n.t(' 项'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
              .layoutWeight(1)
            if (this.recycleItems.length > 0) {
              ImmersiveChip({
                palette: this.palette(),
                chipTint: '#FFD32F2F',
                chipActive: true,
                chipLabel: L10n.t('清空回收站'),
                chipOnTap: () => {
                  this.askPurgeRecycleAll();
                }
              }) {
                SymbolGlyph($r('sys.symbol.trash'))
                  .fontSize(13)
                  .fontColor(['#FFD32F2F'])
              }
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
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
            .fontColor(this.palette().textPrimary)
          Text(L10n.t('上传全部文档与完整备份包（含 AI 对话记录、批注、手写、设置）到你的 WebDAV 服务器；凭据只存在本机。恢复时下载完整备份包整包还原'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwFont.sx(HwType.caption * 1.7, this.uiFontScale))
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
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
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
          .animation(AppearanceFx.anim(200, Curve.FastOutSlowIn))

          if (this.webdavAutoStatus.length > 0) {
            Text(L10n.t('上次自动任务：') + this.webdavAutoStatus)
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
              .width('100%')
          }

          if (this.backupStatus.length > 0) {
            Text(this.backupStatus)
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
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
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
            .fontColor('#FFD93B3B')
            .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
          Text(L10n.t('清空应用的全部数据：文档与文件夹、批注与手写、AI 配置与对话记录、') + '阅读设置与外观、版本历史与备份记录。效果等同于卸载后重装，且无法恢复。')
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwFont.sx(HwType.caption * 1.7, this.uiFontScale))
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
