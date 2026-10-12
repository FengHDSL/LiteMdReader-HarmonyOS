/**
 * 澄笺 · 自动滚屏磁贴（更多面板内）
 * ==================================
 *
 * 自动滚屏是「更多」里的一个小功能，所以它不是一个独立入口，而是面板里的一格。
 *
 * 为什么必须做成**自持状态的子组件**：bindSheet 的内容不跟宿主状态重渲染
 * （本工程的固定坑，ReaderFlagTile 就是为它抽出来的）—— 写在宿主里的开关
 * 点了标签不变、滑杆拖了回弹。这里让组件自己和 AppStorage 双向绑定，
 * 宿主的起停只改 AppStorage，两边永远一致。
 *
 * 与宿主的契约：
 *  · `@StorageLink('autoScrollOn')`：真正的运行时状态，宿主据此开关定时器；
 *  · `onToggle` / `onSpeed`：把用户操作转给宿主（定时器只有宿主拿得到 Scroller）。
 */
import { HwRadius, HwSpace, HwType, LIGHT_PALETTE, ReaderPalette } from '../theme/DesignTokens';
import { ImmersiveChip } from '../material/ImmersiveCard';
import { L10n } from '../service/L10n';

@Component
export struct AutoScrollTile {
  /** 是否正在滚动（与宿主共享同一份 AppStorage 状态） */
  @StorageLink('autoScrollOn') running: boolean = false;
  /** 速度档位 1–10 */
  @StorageLink('autoScrollSpeed') speed: number = 4;
  /** 调色板：必须 @Prop，否则主题切换不更新 */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /** 起停（宿主负责真正驱动滚动） */
  onToggle: (on: boolean) => void = () => {
  };
  /** 调档（宿主正在滚则按新速度重启） */
  onSpeed: (v: number) => void = () => {
  };

  build() {
    Column({ space: HwSpace.xs }) {
      Row({ space: HwSpace.xs }) {
        SymbolGlyph($r('sys.symbol.arrow_down_to_line'))
          .fontSize(18)
          .fontColor([this.palette.accent])

        Column({ space: 2 }) {
          Text(L10n.t('自动滚屏'))
            .fontSize(HwType.label + 1)
            .fontColor(this.palette.textPrimary)
          Text(this.running ? '正在匀速下滚 · 点正文任意处即停' : '免手滑匀速下滚，长文校对用')
            .fontSize(HwType.caption)
            .fontColor(this.palette.textTertiary)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        ImmersiveChip({
          palette: this.palette,
          chipActive: this.running,
          chipLabel: this.running ? '暂停' : '开始',
          chipOnTap: () => {
            this.onToggle(!this.running);
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: HwSpace.xs }) {
        Text(L10n.t('慢'))
          .fontSize(HwType.caption)
          .fontColor(this.palette.textTertiary)
        Slider({ value: this.speed, min: 1, max: 10, step: 1, style: SliderStyle.OutSet })
          .layoutWeight(1)
          .selectedColor(this.palette.accent)
          .blockColor(this.palette.accent)
          .onChange((v: number, mode: SliderChangeMode) => {
            const n: number = Math.round(v);
            this.speed = n < 1 ? 1 : (n > 10 ? 10 : n);
            this.onSpeed(this.speed);
          })
        Text(L10n.t('快'))
          .fontSize(HwType.caption)
          .fontColor(this.palette.textTertiary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(HwSpace.md)
    .borderRadius(HwRadius.inner)
    .backgroundColor(this.palette.quoteBg)
    .alignItems(HorizontalAlign.Start)
  }
}
