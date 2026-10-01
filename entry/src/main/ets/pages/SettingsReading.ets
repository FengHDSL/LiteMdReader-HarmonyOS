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
import { ImmersiveCard } from '../material/ImmersiveCard';
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

  private palette(): ReaderPalette {
    return paletteFor(this.themeMode, this.systemDark);
  }

  build() {
    SettingsShell({
      shellTitle: '阅读调整',
      shellSubtitle: '排版 · 主题 · 批注 · 阅读背景 · 显示',
      stack: this.stack,
      life: this.life
    }) {
      ImmersiveCard({
        cardRadius: HwRadius.sheet,
        cardPadding: HwSpace.lg,
        cardMaterialShadow: false,
        palette: this.palette()
      }) {
        ReadingSettingsPanel({ showReadingHints: true })
      }

      // ── 恢复默认（红色按钮，用户要求：可修改处都要提供恢复默认）──
      Button('恢复默认阅读设置')
        .width('100%')
        .height(40)
        .fontSize(HwType.label + 1)
        .fontColor('#FFFFFFFF')
        .backgroundColor('#D93025')
        .borderRadius(HwRadius.pill)
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
