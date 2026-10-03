/**
 * 澄笺 · 设置 · 阅读调整
 * ====================
 *
 * 从设置中心拆出来的独立页：排版 / 主题 / 批注 / 阅读背景 / 显示 等
 * 全部交给既有的 `ReadingSettingsPanel`（它本来就是为面板形态写的，
 * 放进独立页同样成立——一处复用，避免把 800 行设置逻辑抄第二遍）。
 *
 * ⚠️ **外壳必须自己给**：ReadingSettingsPanel 的 build() 只输出内容，
 * 材质面板原本由调用方的 `ImmersiveOverlay` 提供。独立页如果直接把它塞进
 * SettingsShell 的普通 Column 里，整页就没有材质了——「卡片沉浸光感丢失」
 * 就是这个原因。这里统一用 ImmersiveCard 兜一层，与外观设置页的节卡片同款。
 */
import { NavLifecycle } from '../service/NavLifecycle';
import { ImmersiveCard, ImmersiveCardLayer } from '../material/ImmersiveCard';
import { ReadingSettingsPanel, restoreReadingDefaults } from '../settings/ReadingSettings';
import { common } from '@kit.AbilityKit';
import { HwRadius, HwSpace, HwType, ReaderPalette, ReaderThemeMode, paletteFor } from '../theme/DesignTokens';
import { SettingsShell } from './SettingsShell';

@Component
export struct SettingsReading {
  /** 导航栈：返回设置中心 */
  stack: NavPathStack | null = null;
  /** 生命周期转发 */
  life: NavLifecycle = new NavLifecycle();
  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 外观刷新计数（见 SettingsMirror）：主题色 / 灰字 / 沾色改完靠它重算 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;

  private palette(): ReaderPalette {
    // 三个来源都要显式读一遍落成局部常量：paletteFor 是纯函数读 AppStorage、不登记依赖，
    // 这里不登记 themeMode / systemDark 的话，主题切换会被 ArkUI 跳过重算 →
    // 深色主题下浅色纸上出现黑色文字、壁纸选项按钮变黑（用户反馈"完全看不清"），
    // 且退出重进才恢复。
    const tick: number = this.appearanceTick;
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  build() {
    SettingsShell({
      shellTitle: '阅读调整',
      shellSubtitle: '排版 · 主题 · 显示',
      stack: this.stack,
      life: this.life
    }) {
      // ── 三个功能区各自成卡（用户要求：排版 / 主题 / 显示 分开）──
      // showHeader=false：面板自带的「阅读设置」标题不要（外壳有标题）；
      // panelGroup 让同一份面板按组渲染，避免把 700 行设置逻辑抄三遍。
      ImmersiveCard({
        cardRadius: HwRadius.sheet,
        cardPadding: HwSpace.lg,
        cardMaterialShadow: false,
        palette: this.palette()
      }) {
        ReadingSettingsPanel({ showReadingHints: false, showHeader: false, panelGroup: 'layout' })
      }

      ImmersiveCard({
        cardRadius: HwRadius.sheet,
        cardPadding: HwSpace.lg,
        cardMaterialShadow: false,
        palette: this.palette()
      }) {
        ReadingSettingsPanel({ showReadingHints: false, showHeader: false, panelGroup: 'theme' })
      }

      ImmersiveCard({
        cardRadius: HwRadius.sheet,
        cardPadding: HwSpace.lg,
        cardMaterialShadow: false,
        palette: this.palette()
      }) {
        ReadingSettingsPanel({ showReadingHints: false, showHeader: false, panelGroup: 'display' })
      }

      // ── 恢复默认（红色按钮，用户要求：可修改处都要提供恢复默认）──
      // **带沉浸光感**（用户要求）：Stack = 红色底 + 材质承载层 + 文字，
      // 承载层只做材质、不占布局（与卡片同一条承载路径）。
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height(40)
          .borderRadius(HwRadius.pill)
          .backgroundColor('#D93025')
          .hitTestBehavior(HitTestMode.None)

        ImmersiveCardLayer({ layerRadius: HwRadius.pill, layerShadow: true })

        Text('恢复默认阅读设置')
          .fontSize(HwType.label + 1)
          .fontColor('#FFFFFFFF')
      }
      .width('100%')
      .height(40)
      .borderRadius(HwRadius.pill)
      .clip(true)
      .margin({ top: HwSpace.md })
      .onClick(() => {
        this.restoreReading();
      })
    }
  }

  /** 调用一键恢复默认（模块级函数，见 settings/ReadingSettings.ets）。 */
  private restoreReading(): void {
    const c = this.getUIContext().getHostContext();
    restoreReadingDefaults(c as common.UIAbilityContext);
    this.getUIContext().getPromptAction().showToast({ message: '阅读设置已恢复默认', duration: 1600 });
  }
}
