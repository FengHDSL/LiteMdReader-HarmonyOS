import { ImmersiveCard } from '../material/ImmersiveCard';
import {
  HwFont,
  HwRadius,
  ReaderPalette,
  ReaderThemeMode,
  paletteFor
} from '../theme/DesignTokens';

/**
 * 澄笺 · 自绘 toast 卡片（ToastCard）
 * =================================
 *
 * 系统的 `promptAction.showToast` 只吃纯文本，**无法加材质 / 描边 / 圆角自定义**
 * （用户要求：即时反馈 toast 也要有沉浸光感）。所以这里自绘一块小卡片，
 * 由 `service/ToastFx` 用 ComponentContent 弹出来，走的是与其它卡片同一条材质路径：
 * ImmersiveCard（沉浸光感开 → 系统材质；关 → 实色 + 恒定包边）。
 */
@Component
export struct ToastCard {
  /** 提示文案（宿主传入，单行会省略，多行最多 4 行） */
  @Prop message: string = '';

  @StorageProp('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  @StorageProp('appFontFamily') uiFontKey: string = '';
  @StorageProp('appFontScale') uiFontScale: number = 1;
  @StorageProp('appFontWeightDelta') uiFontWeightDelta: number = 0;

  private pal(): ReaderPalette {
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  build() {
    // 胶囊形态（cardRadius = pill）：toast 是短提示，圆角越大越像"浮起来的一条"
    ImmersiveCard({
      cardRadius: HwRadius.pill,
      cardPadding: 0,
      cardMaterialShadow: true,
      palette: this.pal()
    }) {
      Row() {
        Text(this.message)
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(13, this.uiFontScale))
          .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
          .fontColor(this.pal().textPrimary)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
      }
      .padding({ left: 18, right: 18, top: 11, bottom: 11 })
      .constraintSize({ maxWidth: '78%' })
      // 包边恒定 1.5vp：光感关掉时也能看清这条提示的边界
      .border({ width: 1.5, color: this.pal().divider })
      .borderRadius(HwRadius.pill)
    }
  }
}
