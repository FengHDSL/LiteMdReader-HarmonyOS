import { L10n } from '../service/L10n';
/**
 * 澄笺 · 未保存修改确认弹窗（UnsavedConfirmDialog）
 * ==================================================
 *
 * 自绘而不是 `showDialog`：系统弹窗的按钮只能**横排一行**，四个按钮挤一行
 * 手机上放不下；用户要求 2×2 网格 ——
 *
 *   ┌──────────┬──────────────┐
 *   │  取消    │  直接离开    │   ← 去 / 留 的决断
 *   ├──────────┼──────────────┤
 *   │  不保存  │  保存        │   ← 内容怎么处理
 *   └──────────┴──────────────┘
 *
 * 四个动作各有语义、互不重复：
 *   · 取消     —— 留在编辑页，什么都不做；
 *   · 直接离开 —— 不写文档正文，但**自动存草稿**，下次打开自动恢复（不丢内容）；
 *   · 不保存   —— 丢弃修改（连草稿一起清掉），返回书架；
 *   · 保存     —— 写入文档后返回书架。
 *
 * 视觉沿用 UpdateContentDialog 的自绘规范：宽 '82%'、实底卡片色、
 * 深浅自适应（paletteFor 现算，弹窗内直接读 AppStorage 的主题两键登记依赖）。
 */
import {
  HwFont, LIGHT_PALETTE, ReaderPalette, ReaderThemeMode, paletteFor, withAlpha
} from '../theme/DesignTokens';

@CustomDialog
export struct UnsavedConfirmDialog {
  controller?: CustomDialogController;
  /** 留在编辑页 */
  onCancel: () => void = () => {
  };
  /** 直接离开（自动存草稿） */
  onLeaveWithDraft: () => void = () => {
  };
  /** 丢弃修改并离开 */
  onDiscard: () => void = () => {
  };
  /** 保存并离开 */
  onSave: () => void = () => {
  };
  @StorageProp('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 调色板：**必须 @Prop**，否则主题切换后不更新（普通成员只在创建时赋值一次） */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /** **界面字体**（外观设置 → 界面字体）：组件内文字都从这里取 */
  @StorageProp('appFontFamily') uiFontKey: string = '';
  /** 界面字号缩放系数 / 界面字重相对加粗量（外观设置） */
  @StorageProp('appFontScale') uiFontScale: number = 1;
  @StorageProp('appFontWeightDelta') uiFontWeightDelta: number = 0;

  /** 实际取色：按当前主题现算（显式读两键落局部常量，登记渲染依赖）。 */
  private pal(): ReaderPalette {
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  /** 卡片底：surface 本身带透明度（页面渐变用的），顶满 alpha 才是"实底卡片"。 */
  private cardBg(): string {
    return withAlpha(this.pal().surface, 'FF');
  }

  build() {
    Column({ space: 12 }) {
      Text(L10n.t('还有未保存的修改'))
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(17, this.uiFontScale))
        .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
        .fontColor(this.pal().textPrimary)
        .width('100%')

      Text(L10n.t('「直接离开」会自动存一份草稿，下次打开这篇文档时自动恢复。'))
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(13, this.uiFontScale))
        .fontColor(this.pal().textSecondary)
        .width('100%')

      // ── 第一行：取消 | 直接离开 ──
      Row({ space: 10 }) {
        Text(L10n.t('取消'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(14, this.uiFontScale))
          .fontColor(this.pal().textPrimary)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .border({ width: 1, color: this.pal().divider })
          .onClick(() => {
            this.onCancel();
          })

        Text(L10n.t('直接离开'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(14, this.uiFontScale))
          .fontColor(this.pal().accent)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .border({ width: 1, color: this.pal().accent })
          .onClick(() => {
            this.onLeaveWithDraft();
          })
      }
      .width('100%')

      // ── 第二行：不保存 | 保存 ──
      Row({ space: 10 }) {
        Text(L10n.t('不保存'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(14, this.uiFontScale))
          .fontColor('#FFD93B3B')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .border({ width: 1, color: '#FFD93B3B' })
          .onClick(() => {
            this.onDiscard();
          })

        Text(L10n.t('保存'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(14, this.uiFontScale))
          .fontColor('#FFFFFFFF')
          .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .backgroundColor(this.pal().accent)
          .onClick(() => {
            this.onSave();
          })
      }
      .width('100%')
    }
    .padding(20)
    .borderRadius(16)
    .backgroundColor(this.cardBg())
    .width('82%')
  }
}
