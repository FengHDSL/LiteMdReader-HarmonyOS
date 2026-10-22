/**
 * 澄笺 · 设置 · 意见反馈
 * ======================
 *
 * 从探索中心的「意见反馈」进入。一页把**反馈渠道、跳转方式与写法建议**讲清楚：
 *   · GitHub Issues —— 缺陷与需求的正式去处（可贴长文、可跟踪进度）；
 *   · 华为应用市场 —— 搜索「澄笺」→「添加心愿」（想让功能被排期就点这个）；
 *   · AppTest —— 测试分发里的「澄笺」→ 发送反馈；
 *   · MeoW —— 打开 MeoW → 搜索「澄笺」→ 私信（作者会直接收到）；
 *   · 邮件 —— pandasoos@petalmail.com（附截图最方便）。
 *
 * 视觉与其它设置子页完全同源：SettingsShell 的悬浮胶囊顶栏 + ImmersiveCard 卡片 +
 * ImmersiveChip 按钮（沉浸光感开＝系统材质，关＝实色 + 恒定包边）。
 */
import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError, deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { L10n } from '../service/L10n';
import { NavLifecycle } from '../service/NavLifecycle';
import { ImmersiveCard, ImmersiveChip, ImmersiveIconButton } from '../material/ImmersiveCard';
import { MeoWLink } from '../service/MeoWLink';
import { SettingsShell } from './SettingsShell';
import {
  HwFont,
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  paletteFor,
  isDarkTheme,
  withAlpha
} from '../theme/DesignTokens';

/** 反馈邮箱（用户提供） */
const FEEDBACK_MAIL: string = 'pandasoos@petalmail.com';
/** GitHub 新建 issue（仓库主页 /issues/new 直接进编辑态） */
const GITHUB_ISSUE: string = 'https://github.com/FengHDSL/LiteMdReader-HarmonyOS/issues/new';
/** 渠道配色（各渠道一眼区分，且都与卡片底色有足够对比） */
const C_GITHUB: string = '#FF37474F';
const C_STORE: string = '#FF2E7D32';
const C_APPTEST: string = '#FF1565C0';
const C_MEOW: string = '#FFF57C00';
const C_MAIL: string = '#FF00838F';

@Component
export struct SettingsFeedback {
  /** 导航栈：返回探索中心 */
  stack: NavPathStack | null = null;
  /** 平板分栏嵌入模式：返回改为回探索中心板块（不退设置页） */
  @Prop embedded: boolean = false;
  /** 生命周期转发 */
  life: NavLifecycle = new NavLifecycle();
  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 外观刷新计数：主题色 / 灰字 / 沾色改动后由它触发重算 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  /** 界面字体 / 字号 / 字重（外观设置） */
  @StorageProp('appFontFamily') uiFontKey: string = '';
  @StorageProp('appFontScale') uiFontScale: number = 1;
  @StorageProp('appFontWeightDelta') uiFontWeightDelta: number = 0;
  /** 当前版本号（拼进反馈模板，作者一眼知道是哪一版） */
  @State versionName: string = '';

  aboutToAppear(): void {
    try {
      this.versionName = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
    } catch (err) {
      this.versionName = '';
    }
  }

  private palette(): ReaderPalette {
    const tick: number = this.appearanceTick;
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  private hostCtx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1600 });
    } catch (err) {
      // 提示失败无副作用
    }
  }

  /** 打开一个网页链接（系统挑应用 / 浏览器） */
  private openUrl(url: string): void {
    const ctx = this.hostCtx();
    if (ctx === null) {
      this.toast(L10n.t('打不开链接'));
      return;
    }
    try {
      ctx.openLink(url).catch(() => {
        this.openUrlByWant(ctx, url);
      });
    } catch (err) {
      this.openUrlByWant(ctx, url);
    }
  }

  /** 兜底：隐式 viewData 交给系统浏览器 */
  private openUrlByWant(ctx: common.UIAbilityContext, url: string): void {
    try {
      ctx.startAbility({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      }).catch(() => {
        this.toast(L10n.t('打不开链接'));
      });
    } catch (err) {
      this.toast(L10n.t('打不开链接'));
    }
  }

  /** 打开华为应用市场里澄笺的详情页（「添加心愿」就在那一页） */
  private openStore(): void {
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
    try {
      ctx.startAbility({
        action: 'ohos.want.action.appdetail',
        uri: 'store://appgallery.huawei.com/app/detail?id=' + bundleName
      }).catch(() => {
        this.openUrl('https://appgallery.huawei.com/app/detail?id=' + bundleName);
      });
    } catch (err) {
      this.openUrl('https://appgallery.huawei.com/app/detail?id=' + bundleName);
    }
  }

  /** 打开邮件应用写邮件（mailto），失败就复制地址 */
  private mailTo(): void {
    const ctx = this.hostCtx();
    const url: string = 'mailto:' + FEEDBACK_MAIL;
    if (ctx === null) {
      this.copyText(FEEDBACK_MAIL, L10n.t('已复制邮箱地址'));
      return;
    }
    try {
      ctx.openLink(url).catch(() => {
        this.copyText(FEEDBACK_MAIL, L10n.t('没有可用的邮件应用，已复制邮箱'));
      });
    } catch (err) {
      this.copyText(FEEDBACK_MAIL, L10n.t('没有可用的邮件应用，已复制邮箱'));
    }
  }

  /** 打开 MeoW（装了直接进应用；没装则开落地页） */
  private openMeoW(): void {
    const ctx = this.hostCtx();
    if (ctx === null) {
      this.toast(L10n.t('打不开 MeoW 订阅页'));
      return;
    }
    MeoWLink.open(ctx, () => {
      this.toast(L10n.t('打不开 MeoW 订阅页'));
    });
  }

  /** 复制一段文本到剪贴板 */
  private copyText(text: string, hint: string): void {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(
        pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.toast(hint);
      }).catch((err: BusinessError) => {
        this.toast(L10n.t('复制失败'));
      });
    } catch (err) {
      this.toast(L10n.t('复制失败'));
    }
  }

  /** 复制反馈模板（版本 + 设备 + 结构），用户填完直接贴到任意渠道 */
  private copyTemplate(): void {
    let model: string = '';
    let os: string = '';
    try {
      model = deviceInfo.marketName;
    } catch (err) {
      model = '';
    }
    try {
      os = deviceInfo.osFullName;
    } catch (err) {
      os = '';
    }
    const text: string = L10n.t('【问题或建议】') + '\n\n'
      + L10n.t('【复现步骤】') + '\n1. \n2. \n\n'
      + L10n.t('【期望结果】') + '\n\n'
      + L10n.t('【实际情况】') + '\n\n'
      + L10n.t('【补充】截图 / 录屏可附在附件里') + '\n'
      + '——\n' + L10n.t('澄笺 ') + 'v' + this.versionName
      + (os.length > 0 ? ' · ' + os : '')
      + (model.length > 0 ? ' · ' + model : '');
    this.copyText(text, L10n.t('已复制反馈模板，填完贴到下面任一渠道'));
  }

  /** 一个渠道行：图标 + 名称 + 说明 + 右侧箭头 */
  @Builder
  channelRow(idKey: string, logo: Resource, title: string, desc: string, tint: string, onTap: () => void) {
    Row({ space: HwSpace.sm }) {
      // 品牌图标（128px 压缩图，圆角裁切后与系统图标同观感）
      Image(logo)
        .width(30)
        .height(30)
        .borderRadius(9)
        .clip(true)
        .objectFit(ImageFit.Cover)
        .draggable(false)

      // 文字区：说明**常驻全文**（用户要求：不折叠）
      Column({ space: 3 }) {
        Text(title)
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
          .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
          .fontColor(this.palette().textPrimary)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(desc)
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
          .width('100%')
          .lineHeight(HwFont.sx(HwType.caption * 1.55, this.uiFontScale))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 跳转：**圆形沉浸光感按钮**（材质底盘 + 主题色箭头），一眼看出是"去那边"
      ImmersiveIconButton({
        buttonSize: 32,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          onTap();
        }
      }) {
        SymbolGlyph($r('sys.symbol.arrow_up_right'))
          .fontSize(16)
          .fontColor([tint])
      }
    }
    .width('100%')
    .padding({ left: HwSpace.sm, right: HwSpace.xs, top: 10, bottom: 10 })
    .borderRadius(HwRadius.inner)
    .border({ width: 1, color: this.palette().divider })
    .alignItems(VerticalAlign.Center)
  }

  /** 深浅判定走全仓唯一入口（isDarkTheme），别在这里另写一套口径 */
  private isDark(): boolean {
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return isDarkTheme(mode, dark);
  }

  build() {
    SettingsShell({
      shellTitle: L10n.t('意见反馈'),
      shellSubtitle: L10n.t('GitHub · 应用市场 · AppTest · MeoW · 邮件'),
      stack: this.stack,
      life: this.life,
      onBack: (): boolean => {
        // 分栏嵌入：返回到探索中心（而不是退出设置页）
        if (this.embedded) {
          AppStorage.setOrCreate('settingsInlineSection', 'pages/SettingsExplore');
          return true;
        }
        return false;
      }
    }) {
      // ── 顶部说明 ──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Row({ space: HwSpace.sm }) {
            SymbolGlyph($r('sys.symbol.info_circle'))
              .fontSize(20)
              .fontColor([this.palette().accent])
            Text(L10n.t('遇到问题，或想要某个功能？'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.label + 3, this.uiFontScale))
              .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
              .fontColor(this.palette().textPrimary)
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(L10n.t('下面五个渠道都能找到作者。带**复现步骤 + 截图**的反馈最有用，') +
            L10n.t('描述清楚「做了什么、期望怎样、实际怎样」就足够了。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontColor(this.palette().textSecondary)
            .lineHeight(HwFont.sx(HwType.label * 1.7, this.uiFontScale))
            .width('100%')

          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipActive: true,
              chipLabel: L10n.t('复制反馈模板'),
              chipOnTap: () => {
                this.copyTemplate();
              }
            }) {
              SymbolGlyph($r('sys.symbol.doc_text'))
                .fontSize(13)
                .fontColor([this.palette().accent])
            }
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── 反馈渠道 ──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Text(L10n.t('选一个渠道'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
            .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
            .fontColor(this.palette().textSecondary)
            .width('100%')

          this.channelRow('github', $r('app.media.brand_github'), L10n.t('GitHub Issues'),
            L10n.t('最正式的去处：可贴长文与代码块、能跟踪进度、也方便别人搜到同样问题'),
            C_GITHUB, () => {
              this.openUrl(GITHUB_ISSUE);
            })

          this.channelRow('store', $r('app.media.brand_appgallery'), L10n.t('华为应用市场'),
            L10n.t('应用市场搜索「澄笺」→ 进入详情页点「添加心愿」；心愿数会直接影响排期优先级'),
            C_STORE, () => {
              this.openStore();
            })

          this.channelRow('apptest', $r('app.media.brand_apptest'), L10n.t('AppTest'),
            L10n.t('打开 AppTest → 选择「澄笺」→ 发送反馈（内测版本的问题走这条最快）'),
            C_APPTEST, () => {
              this.copyText('澄笺', L10n.t('已复制「澄笺」，去 AppTest 里搜索它'));
            })

          this.channelRow('meow', $r('app.media.brand_meow'), L10n.t('MeoW'),
            L10n.t('打开 MeoW → 搜索「澄笺」并点进频道 → 私信按钮 → 编辑发送（作者会直接收到）'),
            C_MEOW, () => {
              this.openMeoW();
            })

          this.channelRow('mail', $r('app.media.brand_mail'), L10n.t('邮件'),
            FEEDBACK_MAIL + L10n.t('（附截图最方便；点这一行直接唤起邮件应用）'),
            C_MAIL, () => {
              this.mailTo();
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── 写法建议 ──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.xs }) {
          Row({ space: HwSpace.sm }) {
            SymbolGlyph($r('sys.symbol.lightbulb'))
              .fontSize(18)
              .fontColor([this.palette().accent])
            Text(L10n.t('这样写更快被处理'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
              .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
              .fontColor(this.palette().textPrimary)
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(L10n.t('① 先说环境：版本号、设备型号、是否开了沉浸光感 / 过渡动画；') + '\n' +
            L10n.t('② 再说步骤：1、2、3，一步一行，能照着重现最好；') + '\n' +
            L10n.t('③ 最后说差异：期望看到什么，实际看到什么；') + '\n' +
            L10n.t('④ 有截图 / 录屏就附上——渲染、排版类问题一张图胜过三行字。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontColor(this.palette().textSecondary)
            .lineHeight(HwFont.sx(HwType.label * 1.8, this.uiFontScale))
            .width('100%')

          Text(L10n.t('版本 ') + 'v' + this.versionName + L10n.t(' 已自动写进「复制反馈模板」。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
  }
}
