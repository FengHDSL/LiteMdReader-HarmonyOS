import { L10n } from '../service/L10n';
/**
 * 澄笺 · 设置 · 探索中心
 * ====================
 *
 * 从设置中心拆出来的独立页：关于应用、法务文本（隐私政策 / 用户协议）、
 * 参考项目致谢。把「介绍与法务」从设置主线里分离出来，
 * 让设置中心只剩实用项。
 *
 * 法务文本直接从 Settings.ets 导入（那两份常量已 export），避免维护两份。
 */
import { NavLifecycle } from '../service/NavLifecycle';
import { ImmersiveCard, ImmersiveChip, ImmersiveIconButton } from '../material/ImmersiveCard';
import { SettingsShell } from './SettingsShell';
import { webview } from '@kit.ArkWeb';
import { LegalDoc } from './LegalDoc';
import { UpdateService, UpdateCheckAllResult, APP_MODE_OFFLINE } from '../service/UpdateService';
import { AppModeDialog } from '../components/AppModeDialog';
import { SettingsMirror } from '../service/SettingsMirror';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { updateManager } from '@kit.AppGalleryKit';
import { promptAction } from '@kit.ArkUI';
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

/**
 * 澄笺在 HAP 资源站上的详情页（用户指定）= **测试版渠道**：
 * 检查更新时解析它的版本徽标（fa-code-branch 后的 vX.Y.Z），结果弹窗里「前往更新」也跳这里。
 * 正式版走应用市场（`updateManager`），不占网址。
 */
const UPDATE_SITE: string = 'https://www.sydxky.cn/detail.php?id=956';

/** 平板分栏内嵌法务文档的 Web 高度（vp）：420 在横屏下太矮，正文只剩几行 */
const EMBEDDED_LEGAL_HEIGHT: number = 560;

/** 参考项目（名称 + 地址 + 一句话说明） */
interface CreditItem {
  name: string;
  url: string;
  note: string;
}

const CREDITS: CreditItem[] = [
  {
    name: 'MrCashmere / miha_hm',
    url: 'https://github.com/MrCashmere/miha_hm',
    note: L10n.t('沉浸光感承载层（Toggle + attributeModifier）方案参考')
  },
  {
    name: 'skadjhljhas / zhumo-reader',
    url: 'https://github.com/skadjhljhas/zhumo-reader',
    note: L10n.t('注释卡片式阅读形态参考')
  },
  {
    name: 'Vanessa219 / vditor',
    url: 'https://github.com/Vanessa219/vditor',
    note: L10n.t('Markdown 编辑器三种模式（所见即所得 / 即时渲染 / 分屏预览）与编辑功能设计参考')
  },
  {
    name: 'luvi / lv-markdown-in',
    url: 'https://gitee.com/luvi/lv-markdown-in',
    note: L10n.t('Markdown 渲染能力参考：代码块行号 / 折叠 / 操作区、HTML 常用标签与 font 快速样式、懒渲染与预渲染块数思路')
  }
];

@Component
export struct SettingsExplore {
  stack: NavPathStack | null = null;
  life: NavLifecycle = new NavLifecycle();

  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 外观刷新计数：主题色 / 灰字 / 沾色改动后由它触发重算 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  @State versionName: string = '1.0.0';
  /** **界面字体**（外观设置 → 界面字体）：本页界面文字都从这里取 */
  @StorageProp('appFontFamily') uiFontKey: string = '';
  /** 界面字号缩放系数 / 界面字重相对加粗量（外观设置） */
  @StorageProp('appFontScale') uiFontScale: number = 1;
  @StorageProp('appFontWeightDelta') uiFontWeightDelta: number = 0;
  /** 语言切换计数：变更时整页重建（key 拼接），文案随词典刷新 */
  @StorageProp('languageTick') languageTick: number = 0;
  /** 「检查更新」进行中（按钮转圈 + 文案变「检查中…」，期间重复点击直接忽略） */
  @State checkingUpdate: boolean = false;
  /** 平板分栏嵌入模式：true = 由设置分栏的右栏承载，法务在卡片内展开 */
  @Prop embedded: boolean = false;
  /** 嵌入模式下正在展示的法务文档：'' / 'privacy' / 'terms' */
  @State legalDoc: string = '';
  /**
   * 嵌入式法务 Web 的控制器：**两份文档各一个**。
   * 之前共用一个 controller 给两个 if/else 分支的 Web 组件——同一个起始终结的
   * WebviewController 被两个组件抢绑，横屏分栏下切到另一份文档时新组件拿不到控制权，
   * 表现就是「点了没反应，要连点好几次」。一文档一控制器后即点即换。
   */
  private legalCtrlPrivacy: webview.WebviewController = new webview.WebviewController();
  private legalCtrlTerms: webview.WebviewController = new webview.WebviewController();

  /** 全屏覆盖层（从下往上滑出，用户要求）：是否展示法务文档 */
  @State coverShow: boolean = false;
  /** 覆盖层正在展示的法务文档：'privacy' / 'terms' */
  @State coverDoc: string = 'privacy';
  /** 使用模式（'' 未选择 / 'full' 全量 / 'offline' 基础离线）
   *  用 @StorageLink：弹窗选择后按钮文案与颜色**当帧**更新（@StorageProp 不保证回刷） */
  @StorageLink('appMode') appMode: string = '';
  /** 使用模式弹窗（可重新选择） */
  @State modeTitle: string = L10n.t('重新选择使用模式');
  @State modeCurrent: string = '';
  modeDialog: CustomDialogController = new CustomDialogController({
    builder: AppModeDialog({
      titleText: $modeTitle,
      currentMode: $modeCurrent,
      onPick: (mode: string) => {
        AppStorage.setOrCreate('appMode', mode);
        // 第二腿落盘（PersistentStorage 在部分设备不真正落盘）
        SettingsMirror.save(this.hostCtx());
        this.toast(mode === APP_MODE_OFFLINE ? L10n.t('已切换为基础模式（纯离线）') : L10n.t('已切换为全量模式'));
      }
    }),
    autoCancel: false,
    customStyle: true
  });

  /**
   * 打开法务文档：
   *  · **默认：全屏覆盖层，从下往上滑出**（bindContentCover + DEFAULT 转场，用户要求）；
   *  · 平板分栏嵌入模式（embedded）：在当前卡片内展开 Web，不全屏弹出。
   */
  /** 取应用上下文（写设置镜像用）。 */
  private hostCtx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  private openLegal(doc: string): void {    if (this.embedded) {
      if (this.legalDoc !== doc) {
        this.getUIContext().animateTo(AppearanceFx.anim(240, Curve.FastOutSlowIn), () => {
          this.legalDoc = doc;
        });
      } else {
        this.legalDoc = '';
      }
      return;
    }
    this.coverDoc = doc;
    this.coverShow = true;
  }

  /** 覆盖层承载的法务文档页（LegalDoc 的返回回调收起覆盖层）。 */
  @Builder
  legalCover() {
    LegalDoc({
      doc: this.coverDoc,
      onBack: () => {
        this.coverShow = false;
      }
    })
  }

  aboutToAppear(): void {
    this.loadVersion();
    this.life.onShow = () => {
      this.loadVersion();
    };
  }

  private loadVersion(): void {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName !== undefined && info.versionName.length > 0) {
        this.versionName = info.versionName;
      }
    } catch (err) {
      // 读不到就沿用默认值
    }
  }

  /**
   * 好评鼓励的手动入口：跳应用市场的「写评论」页（华为官方给评分弹窗超限时的兜底办法）——
   * 隐式 Want，`action=ohos.want.action.appdetail` +
   * `uri=store://appgallery.huawei.com/app/detail?id=包名&action=write-review`。
   * 不用 `commentManager.showCommentDialog` 那颗应用内评分框：实测在 DevEco 直装的包上
   * 点了不画框（连错误码都不回），而且被市场限成同一用户一年内最多 3 次；
   * 那条只留给安装满 24 小时的自动弹（见 service/Rating.ets，失败全程静默）。
   */
  private openStoreReview(): void {
    const ctx = this.hostCtx();
    if (ctx === null) {
      this.toast(L10n.t('打不开应用市场'));
      return;
    }
    let bundleName: string = '';
    try {
      bundleName = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).name;
    } catch (err) {
      bundleName = '';
    }
    if (bundleName.length === 0) {
      this.toast(L10n.t('打不开应用市场'));
      return;
    }
    const want: Want = {
      action: 'ohos.want.action.appdetail',
      uri: 'store://appgallery.huawei.com/app/detail?id=' + bundleName + '&action=write-review'
    };
    try {
      ctx.startAbility(want).catch(() => {
        this.toast(L10n.t('打不开应用市场'));
      });
    } catch (err) {
      this.toast(L10n.t('打不开应用市场'));
    }
  }

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
      // 忽略
    }
  }

  /** 打开外部链接：失败时提示，别让点击毫无反馈 */
  /**
   * 打开「功能帮助」。
   * 平板分栏嵌入时**不进新页**，回设置中心右栏展示（与「更新日志」同一套做法）。
   */
  private openHelp(): void {
    if (this.embedded) {
      AppStorage.setOrCreate('settingsInlineSection', 'pages/SettingsHelp');
      return;
    }
    if (this.stack === null) {
      return;
    }
    this.stack.pushPath({ name: 'pages/SettingsHelp' }, AppearanceFx.navAnimated());
  }

  private openLink(url: string): void {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      this.toast(L10n.t('打不开浏览器：') + url);
      return;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: url
    };
    try {
      (c as common.UIAbilityContext).startAbility(want).catch(() => {
        this.toast(L10n.t('打不开浏览器：') + url);
      });
    } catch (err) {
      this.toast(L10n.t('打不开浏览器：') + url);
    }
  }

  // ══════════════════════ 检查更新 ══════════════════════
  //
  // **两个渠道一起查、结果一起展示**（用户要求）：
  //   · 测试版 = HAP 资源站详情页的版本徽标（`fa-code-branch` 后紧跟 `<span>vX.Y.Z</span>`，
  //     侧载 / 邀测走这条，通常领先几个版本）；
  //   · 正式版 = 华为应用市场（AppGallery Kit 的 `updateManager.checkAppUpdate()`，
  //     由市场自己比对在架版本）。
  // 两条文案逐行显示在同一个结果弹窗里；网络与解析细节都在 UpdateService 里。

  /** 检查更新：两个渠道并发跑完，重复点击直接忽略（超时保护在 UpdateService 内部）。 */
  private checkUpdate(): void {
    if (this.checkingUpdate) {
      return;
    }
    // 基础模式（纯离线）：一切联网能力关停
    if (UpdateService.isOffline()) {
      this.toast(L10n.t('当前是基础模式（纯离线），检查更新不可用'));
      return;
    }
    this.checkingUpdate = true;
    UpdateService.checkAll(this.hostCtx()).then((res: UpdateCheckAllResult) => {
      this.checkingUpdate = false;
      this.showCheckResult(res);
    }).catch(() => {
      this.checkingUpdate = false;
      this.toast(L10n.t('检查更新失败，请检查网络后重试'));
    });
  }

  /**
   * 结果弹窗：标题随「有没有更新」变，正文每个渠道一行（用户要求两条都展示）。
   * 第一个按钮的动作也跟着变：只有正式版有更新 → 调应用市场官方更新框
   * （`updateManager.showUpdateDialog`）；测试版有更新（或两个都有）→ 去资源站。
   */
  private showCheckResult(res: UpdateCheckAllResult): void {
    const goStore: boolean = res.store.hasUpdate && !res.beta.hasUpdate;
    // 按钮显式写成 promptAction.Button[]：ArkTS 对对象字面量要求能从上下文推出类型，
    // 用三元返回两个不同长度的数组字面量最容易在构建时炸
    const btns: promptAction.Button[] = [];
    if (res.hasUpdate) {
      btns.push({
        text: goStore ? L10n.t('在市场更新') : L10n.t('前往更新'),
        color: this.palette().accent
      });
    }
    btns.push({
      text: res.hasUpdate ? L10n.t('稍后再说') : L10n.t('知道了'),
      color: this.palette().textSecondary
    });
    this.getUIContext().getPromptAction().showDialog({
      title: res.hasUpdate ? L10n.t('发现新版本') : L10n.t('检查更新'),
      message: res.lines.join('\n'),
      buttons: btns
    }).then((dr: promptAction.ShowDialogSuccessResponse) => {
      if (!res.hasUpdate || dr.index !== 0) {
        return;
      }
      if (!goStore) {
        this.openLink(UPDATE_SITE);
        return;
      }
      const ctx = this.hostCtx();
      if (ctx === null) {
        this.toast(L10n.t('请前往应用市场更新'));
        return;
      }
      // showUpdateDialog 同样可能**同步抛**（缺 syscap / 不在前台），只挂 promise 的 catch 接不到
      try {
        updateManager.showUpdateDialog(ctx).then((code: updateManager.ShowUpdateResultCode) => {
          if (code === updateManager.ShowUpdateResultCode.SHOW_DIALOG_FAILURE) {
            this.toast(L10n.t('打不开应用市场的更新框，请前往应用市场更新'));
          }
        }).catch(() => {
          this.toast(L10n.t('打不开应用市场的更新框，请前往应用市场更新'));
        });
      } catch (err) {
        this.toast(L10n.t('打不开应用市场的更新框，请前往应用市场更新'));
      }
    }).catch(() => {
      // 用户手势取消对话框，无需提示
    });
  }

  build() {
    Column() {
      SettingsShell({
        shellTitle: L10n.t('探索中心'),
        shellSubtitle: L10n.t('功能帮助 · 关于应用 · 参考与致谢'),
        stack: this.stack,
        life: this.life
      }) {
      // ── 关于应用（用户要求：与功能帮助交换位置，介绍放最前）──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.md }) {
          Row({ space: HwSpace.md }) {
            Stack() {
              Image($r('app.media.background'))
                .width(60)
                .height(60)
              Image($r('app.media.foreground'))
                .width(60)
                .height(60)
            }
            .width(60)
            .height(60)
            .borderRadius(15)
            .clip(true)
            .border({ width: 0.8, color: this.palette().divider })

            Column({ space: 2 }) {
              Text(L10n.t('澄笺·ChéngJiān'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.label + 6, this.uiFontScale))
                .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
                .fontColor(this.palette().textPrimary)
              Text(L10n.t('版本 ') + this.versionName + L10n.t(' · HarmonyOS 原生'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(L10n.t('一款沉浸光感 Markdown 阅读器：卡片化排版、荧光笔批注、多标签阅读、') +
            L10n.t('函数绘制壁纸，数据留在本机。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontColor(this.palette().textSecondary)
            .lineHeight(HwFont.sx(HwType.label * 1.7, this.uiFontScale))
            .width('100%')

          Text(L10n.t('「澄」是澄澈透光——磨砂与光感玻璃；「笺」是文人读写的纸笺。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontColor(this.palette().textSecondary)
            .lineHeight(HwFont.sx(HwType.label * 1.7, this.uiFontScale))
            .width('100%')

          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipActive: true,
              chipLabel: L10n.t('项目主页'),
              chipOnTap: () => {
                this.openLink('https://github.com/FengHDSL/LiteMdReader-HarmonyOS');
              }
            })
            // 检查更新：拉资源站详情页解析最新版本（见 checkUpdate）。
            // 进行中芯片变成高亮态 + 文案「检查中…」，重复点击在方法内部直接忽略。
            ImmersiveChip({
              palette: this.palette(),
              chipTint: '#FF2E7D32',
              chipActive: true,
              chipLabel: this.checkingUpdate ? L10n.t('检查中…') : L10n.t('检查更新'),
              chipOnTap: () => {
                this.checkUpdate();
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: L10n.t('更新日志'),
              chipOnTap: () => {
                // **平板分栏嵌入模式**：不进新页，回设置中心右栏展示
                //（与其它设置板块一致 —— 用户要求）
                if (this.embedded) {
                  AppStorage.setOrCreate('settingsInlineSection', 'pages/Changelog');
                  return;
                }
                if (this.stack === null) {
                  return;
                }
                this.stack.pushPath({ name: 'pages/Changelog' }, AppearanceFx.navAnimated());
              }
            })
          }
          .width('100%')

          // ── 好评鼓励（用户要求）：单独一行，不与上面三枚芯片挤在一起 ──
          // 点它**直达应用市场的「写评论」页**（隐式 Want）。应用内那个官方评分框
          // （commentManager.showCommentDialog）真机实测在 DevEco 直装的包上点了不画框，
          // 应用市场又把它限成同一用户一年内最多 3 次——所以手动入口改走市场页，
          // 应用内评分框只留给「安装满 24 小时」那一次自动弹（静默，出现就赚到）。
          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              // **粉色**（用户要求）
              chipTint: '#FFE91E63',
              chipActive: true,
              chipLabel: L10n.t('好评鼓励'),
              chipOnTap: () => {
                this.openStoreReview();
              }
            }) {
              SymbolGlyph($r('sys.symbol.heart_fill'))
                .fontSize(14)
                .fontColor(['#FFB26A00'])
            }
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── 功能帮助（用户要求：放在应用介绍之后）──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Row({ space: HwSpace.sm }) {
            SymbolGlyph($r('sys.symbol.info_circle'))
              .fontSize(20)
              .fontColor([this.palette().accent])
            Column({ space: 2 }) {
              Text(L10n.t('功能帮助'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.label + 3, this.uiFontScale))
                .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
                .fontColor(this.palette().textPrimary)
              Text(L10n.t('全部功能 · 使用方法 · 常见问题'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(L10n.t('按板块列出每一个功能怎么用，并汇总常见问题 —— 例如「自动滚屏的悬浮按钮怎么关」、') +
            L10n.t('「点了段落为什么改不了」这类。支持关键词搜索。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontColor(this.palette().textSecondary)
            .lineHeight(HwFont.sx(HwType.label * 1.7, this.uiFontScale))
            .width('100%')

          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipActive: true,
              chipLabel: L10n.t('打开功能帮助'),
              chipOnTap: () => {
                this.openHelp();
              }
            })
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── 参考与致谢 ──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Text(L10n.t('设计与实现参考'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
            .fontColor(this.palette().textPrimary)
            .width('100%')

          // **致谢**（用户要求）：标题下方一句，向参考项目致意
          Text(L10n.t('感谢下列开源项目的作者与贡献者。本项目在渲染形态、动效与交互细节上参考了它们的实现思路，') +
            L10n.t('在此向这些付出致意。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwFont.sx(HwType.caption * 1.7, this.uiFontScale))
            .width('100%')

          // 只写参考项目的名称（用户要求）
          ForEach(CREDITS, (item: CreditItem) => {
            Row({ space: HwSpace.sm }) {
              Text(item.name)
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
                // 用户要求：参考链接文字用**蓝色**（可点击的观感）
                .fontColor('#FF2F63E8')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .onClick(() => {
                  this.openLink(item.url);
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }, (item: CreditItem) => item.url)

          Text(L10n.t('澄心执笔，笺上生光'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: HwSpace.sm })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── 法务（页面底部，按钮居中）：点击跳转**新页面**查看（跟随系统深浅色）──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: L10n.t('隐私政策'),
              chipOnTap: () => {
                this.openLegal('privacy');
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: L10n.t('用户协议'),
              chipOnTap: () => {
                this.openLegal('terms');
              }
            })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)

          // ── 使用模式（用户要求：放在隐私政策 / 用户协议**下方**，可重新选择）──
          // **@StorageLink**：弹窗里写完 appMode 立刻回刷按钮文案与配色
          //（@StorageProp 在本工程真机上存在不回刷的情况——见 memory）
          // **使用模式：沉浸光感胶囊**（颜色不变 —— 通过 chipTint 保持原色）
          Row() {
            ImmersiveChip({
              palette: this.palette(),
              chipTint: this.appMode === APP_MODE_OFFLINE ? '#FF2F63E8' : '#FF2E7D53',
              chipActive: true,
              chipLabel: L10n.t('使用模式：') + (this.appMode === APP_MODE_OFFLINE ? L10n.t('基础（纯离线）') : L10n.t('全量')),
              chipOnTap: () => {
                this.modeTitle = L10n.t('重新选择使用模式');
                this.modeCurrent = this.appMode;
                this.modeDialog.open();
              }
            }) {
              SymbolGlyph(this.appMode === APP_MODE_OFFLINE
                ? $r('sys.symbol.wifi_slash') : $r('sys.symbol.checkmark_circle'))
                .fontSize(14)
                .fontColor([this.appMode === APP_MODE_OFFLINE ? '#FF2F63E8' : '#FF2E7D53'])
            }
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)

          // 嵌入模式（平板分栏）：法务 Web 直接在卡片内展开，不全屏跳转。
          // **一份文档一个 Web + 一个 controller**：换成同一个 controller 服务两个分支时，
          // 横屏分栏里切换文档会出现「点了没反应、要连点几次」。
          // 高度给到 560（原来 420）：横屏下 420 太矮，正文只剩几行、得一直滚。
          if (this.embedded && this.legalDoc === 'privacy') {
            Web({ src: $rawfile('legal_privacy.html'), controller: this.legalCtrlPrivacy })
              .width('100%')
              .height(EMBEDDED_LEGAL_HEIGHT)
              .borderRadius(HwRadius.inner)
              .backgroundColor(this.palette().pageTop)
          } else if (this.embedded && this.legalDoc === 'terms') {
            Web({ src: $rawfile('legal_terms.html'), controller: this.legalCtrlTerms })
              .width('100%')
              .height(EMBEDDED_LEGAL_HEIGHT)
              .borderRadius(HwRadius.inner)
              .backgroundColor(this.palette().pageTop)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    }
    .width('100%')
    .height('100%')
    // **法务文档：全屏覆盖层，从下往上滑出**（ModalTransition.DEFAULT =
    // 进场向上 / 退场向下，用户要求）。挂在包裹 Column 上（SettingsShell 是
    // 尾随闭包组件，不能再链属性）。
    .bindContentCover(this.coverShow, this.legalCover(), {
      modalTransition: ModalTransition.DEFAULT,
      onDisappear: () => {
        this.coverShow = false;
      }
    })
  }
}
