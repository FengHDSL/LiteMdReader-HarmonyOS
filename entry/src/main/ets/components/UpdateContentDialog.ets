/**
 * 澄笺 · 版本更新弹窗
 * ====================
 *
 * 参考本地项目 xjau 的自绘弹窗做法（HomeView 里的 UpdateContentDialog）：
 *   · **宽度用 '82%'**（相对屏幕：既不是铺满，也不会显得又宽又空）；
 *   · 底色用**卡片色**（不透明的卡片底，不是页面渐变蓝灰），跟随深浅主题；
 *   · 文案紧排（标题 17 Bold + 条目 13 次要色），按钮整宽、高 38、圆角 10；
 *   · 内边距 20、圆角 16，整体轻。
 *
 * 应用更新后**首次启动**弹一次，内容直接取更新日志最新一条（无需每版手写文案）。
 *
 * 用法（宿主）：
 *   @State updateTitle: string = '';
 *   @State updateLines: string[] = [];
 *   updateDialog: CustomDialogController = new CustomDialogController({
 *     builder: UpdateContentDialog({ titleText: $updateTitle, lines: $updateLines }),
 *     autoCancel: false, customStyle: true
 *   });
 */
import { display } from '@kit.ArkUI';
import {
  LIGHT_PALETTE, ReaderPalette, ReaderThemeMode, paletteFor, withAlpha
} from '../theme/DesignTokens';

@CustomDialog
export struct UpdateContentDialog {
  controller?: CustomDialogController;
  @Link titleText: string;
  @Link lines: string[];
  /** 调色板：**深浅自适应**（弹窗在深色模式下必须跟着变，否则黑字黑底看不清） */
  @StorageProp('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 调色板：**必须 @Prop**，否则主题切换后不更新（普通成员只在创建时赋值一次） */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /** 条目区的**高度上限**（vp）：进页面时按屏幕算一次，不每帧查 display */
  @State listMax: number = 240;

  aboutToAppear(): void {
    this.listMax = UpdateContentDialog.maxListHeight(this.getUIContext());
  }

  /**
   * 条目区高度上限。
   *
   * **为什么必须有**：更新条数一多（1.0.7 有十几条），原来把条目直接铺在 Column 里，
   * 弹窗高度随内容一路长高、长出屏幕 —— 底部的「知道了」按钮被顶到看不见，
   * 用户点不到也划不动（真机实测的严重可用性问题）。
   * 现在给列表区一个上限（屏高 52%）并让它内部滚动，按钮永远固定在弹窗底部可见。
   */
  private static maxListHeight(ui: UIContext): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const h: number = ui.px2vp(d.height);
      return Math.max(160, Math.round(h * 0.52));
    } catch (err) {
      return 240;
    }
  }

  /** 实际取色：按当前主题现算（不要用固定的浅色调色板）。 */
  private pal(): ReaderPalette {
    // 显式读一遍 themeMode / systemDark 落成局部常量：paletteFor 是纯函数读 AppStorage、
    // 不登记依赖，弹窗构建时若不登记，系统深浅切换后文字会沿用旧配色
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  /** 卡片底：surface 本身带透明度（页面渐变用的），顶满 alpha 才是"实底卡片"。 */
  private cardBg(): string {
    return withAlpha(this.pal().surface, 'FF');
  }

  build() {
    Column({ space: 10 }) {
      Text(this.titleText)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.pal().textPrimary)
        .width('100%')

      // **条目区：限高 + 内部滚动**（用户反馈：日志太长把按钮顶出屏幕、点不到，
      // 现在可以直接上下滑动看完全部内容；按钮不参与滚动，永远在底部可见）
      Scroll() {
        Column({ space: 5 }) {
          ForEach(this.lines, (line: string, idx: number) => {
            Text('· ' + line)
              .fontSize(13)
              .fontColor(this.pal().textSecondary)
              .lineHeight(20)
              .width('100%')
              .textAlign(TextAlign.Start)
          }, (line: string, idx: number) => 'ul_' + idx)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ maxHeight: this.listMax })
      .scrollBar(BarState.Auto)
      // 内容不足一屏时 Scroll 默认居中，显式顶对齐（本工程既有约定）
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)

      Button('知道了')
        .fontSize(14)
        .fontColor('#FFFFFFFF')
        .backgroundColor(this.pal().accent)
        .width('100%')
        .height(38)
        .borderRadius(10)
        .margin({ top: 6 })
        .onClick(() => {
          this.controller?.close();
        })
    }
    .width('82%')
    // 整体高度双保险：任何情况下弹窗都不超过屏高 76%，按钮不会被挤出屏幕
    .constraintSize({ maxHeight: '76%' })
    .padding(20)
    .borderRadius(16)
    .backgroundColor(this.cardBg())
    .alignItems(HorizontalAlign.Start)
  }
}
