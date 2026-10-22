import { L10n } from '../service/L10n';
import {
  HwFont,
  HwRadius,
  ReaderPalette,
  ReaderThemeMode,
  paletteFor,
  withAlpha
} from '../theme/DesignTokens';

/**
 * 澄笺 · 字体加载提示弹窗（FontLoadHint）
 * ====================================
 *
 * 用户要求（2026-10-22）：「点击字体选择按钮时必须弹窗提醒真正在加载，**不要加载图标**；
 * 加载完再展开列表」。
 *
 * 所以这里只做一件事：屏幕居中一块实底小卡片 + 一行文案。
 * 出现 / 消失的过渡由宿主的 `CustomDialogController` 的 openAnimation / closeAnimation 给，
 * 弹窗自身不做多余动效（避免"弹窗自己在飘"的廉价感）。
 *
 * 取色同项目其它自绘弹窗（AppResetDialog / UnsavedConfirmDialog）：弹窗内直接读
 * 「主题 + 系统深浅」两键，各自登记渲染依赖，切主题时弹窗也跟着变。
 */
@CustomDialog
export struct FontLoadHint {
  controller?: CustomDialogController;
  /** 文案（宿主可换成"正在加载英数字体…"之类；默认通用文案） */
  message: string = L10n.t('正在加载字体…');

  @StorageProp('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 界面字体 / 字号 / 字重（弹窗文字跟随外观设置，与其它弹窗一致） */
  @StorageProp('appFontFamily') uiFontKey: string = '';
  @StorageProp('appFontScale') uiFontScale: number = 1;
  @StorageProp('appFontWeightDelta') uiFontWeightDelta: number = 0;

  private pal(): ReaderPalette {
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  build() {
    Row() {
      Text(this.message)
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(14, this.uiFontScale))
        .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
        .fontColor(this.pal().textPrimary)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
    }
    .padding({ left: 26, right: 26, top: 18, bottom: 18 })
    .borderRadius(HwRadius.card)
    // surface 自带透明度 → 顶满 alpha 才是实底卡片（与其它弹窗同款处理）
    .backgroundColor(withAlpha(this.pal().surface, 'FF'))
    // 包边恒定 1.5vp：沉浸光感关掉时也看得见边界
    .border({ width: 1.5, color: this.pal().divider })
    .constraintSize({ maxWidth: '76%' })
    .shadow({ radius: 24, color: '#33000000', offsetX: 0, offsetY: 8 })
  }
}
