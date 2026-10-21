/**
 * 澄笺 · 朗读磁贴（更多面板内）
 * ==============================
 *
 * 用系统文本转语音（Core Speech Kit 的 textToSpeech）把正文一段一段读出来：
 * 通勤、做家务时"听着看"，比盯着屏幕省眼睛。
 *
 * 为什么和自动滚屏一样做成**自持状态的子组件**：bindSheet 的内容不跟宿主状态
 * 重渲染（本工程固定坑）。组件自己与 AppStorage 双向绑定，
 * 宿主只负责"真正驱动朗读"，两边状态永远不会打架。
 *
 * 与宿主的契约：
 *  · `@StorageLink('ttsOn')`：会话是否活跃（暂停也算活跃）；
 *  · `@StorageLink('ttsSpeaking')`：当前是否正在发声；
 *  · 回调把用户意图转给宿主（引擎只有宿主拿得到）。
 */
import { HwFont, HwRadius, HwSpace, HwType, LIGHT_PALETTE, ReaderPalette } from '../theme/DesignTokens';
import { ImmersiveChip } from '../material/ImmersiveCard';
import { L10n } from '../service/L10n';

@Component
export struct ReadAloudTile {
  /** 朗读会话是否活跃（含暂停态） */
  @StorageLink('ttsOn') on: boolean = false;
  /** 是否正在发声（暂停时为 false） */
  @StorageLink('ttsSpeaking') speaking: boolean = false;
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /** **界面字体**（外观设置 → 界面字体）：组件内文字都从这里取 */
  @StorageProp('appFontFamily') uiFontKey: string = '';
  /** 开始 / 继续 */
  onPlay: () => void = () => {
  };
  /** 暂停 */
  onPause: () => void = () => {
  };
  /** 结束并收起 */
  onStop: () => void = () => {
  };

  private statusText(): string {
    if (!this.on) {
      return '从当前阅读位置开始，一段一段读下去';
    }
    return this.speaking ? L10n.t('正在朗读 · 点浮钮可暂停') : L10n.t('已暂停 · 点「继续」接着读');
  }

  build() {
    Column({ space: HwSpace.xs }) {
      Row({ space: HwSpace.xs }) {
        SymbolGlyph($r('sys.symbol.hitouch_read_aloud'))
          .fontSize(18)
          .fontColor([this.palette.accent])

        Column({ space: 2 }) {
          Text(L10n.t('朗读全文'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.label + 1)
            .fontColor(this.palette.textPrimary)
          Text(this.statusText())
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.caption)
            .fontColor(this.palette.textTertiary)
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (!this.on) {
          ImmersiveChip({
            palette: this.palette,
            chipLabel: L10n.t('开始'),
            chipOnTap: () => {
              this.onPlay();
            }
          })
        } else if (this.speaking) {
          ImmersiveChip({
            palette: this.palette,
            chipActive: true,
            chipLabel: L10n.t('暂停'),
            chipOnTap: () => {
              this.onPause();
            }
          })
        } else {
          ImmersiveChip({
            palette: this.palette,
            chipActive: true,
            chipLabel: L10n.t('继续'),
            chipOnTap: () => {
              this.onPlay();
            }
          })
        }

        if (this.on) {
          ImmersiveChip({
            palette: this.palette,
            chipTint: '#FFD32F2F',
            chipActive: true,
            chipLabel: L10n.t('结束'),
            chipOnTap: () => {
              this.onStop();
            }
          })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(L10n.t('代码块、表格与图表会跳过不读；读到哪一段，屏幕会自动跟到那一段。') + '朗读用系统语音，离线或设备不支持时会有提示。')
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwType.caption)
        .fontColor(this.palette.textTertiary)
        .lineHeight(HwType.caption * 1.6)
        .width('100%')
    }
    .width('100%')
    .padding(HwSpace.md)
    .borderRadius(HwRadius.inner)
    .backgroundColor(this.palette.quoteBg)
    .alignItems(HorizontalAlign.Start)
  }
}
