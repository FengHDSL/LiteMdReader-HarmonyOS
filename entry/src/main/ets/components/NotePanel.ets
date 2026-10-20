/**
 * 澄笺 · 批注输入面板（自持状态的子组件）
 * ========================================
 *
 * **为什么单独成组件、而不是写在 Reader 的 @Builder 里**：
 * bindSheet 的 builder 不跟宿主 @State 重渲染（本工程反复踩到的固定坑 ——
 * AutoScrollTile / ReadAloudTile / ReaderFlagTile 三个组件的注释、以及
 * sheetEpoch「换 .id 强制重建」那套约定，说的都是同一件事）。而批注面板现在
 * 必须在**面板开着的时候**响应三类变化：
 *   ① 在公式源码框里选中一段 → 渲染预览与「批注范围」标题跟着变；
 *   ② 切换「普通批注 / 学习卡」；
 *   ③ 「保存公式」写回后，预览换成新源码。
 * 这些状态放在 Reader 里全都不会刷新，所以状态住进本组件，宿主只在**打开面板
 * 那一刻**传初值（init* 一组普通成员，不参与刷新），之后靠回调把结果交回去。
 *
 * 键盘避让不在这里做：平台对 BindSheet 不做键盘避让，抬高由外层
 * `material/SheetKeyboardLift` 统一负责（所有半模态共用）。
 */
import { HwRadius, HwSpace, HwType, LIGHT_PALETTE, ReaderPalette } from '../theme/DesignTokens';
import { ImmersiveChip } from '../material/ImmersiveCard';
import { MathFormulaText } from './MathFormulaText';
import { L10n } from '../service/L10n';
import { AppearanceFx } from '../service/AppearanceFx';

@Component
export struct NotePanel {
  // ── 初值（打开面板那一刻读一次；**刻意不加 @Prop**，见文件头注释）──
  /** 文字批注的引用原文 */
  initQuote: string = '';
  /** 公式批注的文档现存源码；空串 = 非公式批注 */
  initMathQuote: string = '';
  /** 未过期的草稿 */
  initDraft: string = '';
  /** 进来的形态：'' 普通批注 / 'card' 学习卡 */
  initStyle: string = '';
  // ── 外部注入（这些变化都伴随面板重建，用 @Prop 即可）──
  @Prop dark: boolean = false;
  @Prop bodySize: number = 16;
  /** 调色板：**必须 @Prop**（同 ImmersiveCard 的说明），否则换主题不更新 */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /** 草稿边输边存（宿主写 AppStorage，误退出 3 分钟内可恢复） */
  onDraft: (value: string) => void = () => {
  };
  /** 「保存公式」：宿主写回文档，返回是否成功（成功后本组件把预览换成新源码） */
  onSaveMath: (latex: string) => boolean = () => {
    return false;
  };
  /** 提交：draft + 形态（'' / 'card'）+ 选中的公式子串（'' = 整条） */
  onSubmit: (draft: string, style: string, sub: string) => void = () => {
  };
  onCancel: () => void = () => {
  };

  @State draft: string = '';
  /** 文档里现存的公式源码（收窄定位的基准，**不随编辑变动**，写完回才更新） */
  @State mathQuote: string = '';
  /** 编辑框里的副本（可能已改、尚未写回） */
  @State mathSrc: string = '';
  @State selStart: number = 0;
  @State selEnd: number = 0;
  @State style: string = '';

  /**
   * 窗口高与键盘占高（都是 AppWindow 全局广播的 px）：输入框"随内容继续长高"
   * 要有上限，上限就得跟着**键盘之外的可视高度**走——键盘弹起时可视带变窄，
   * 框跟着收；键盘收起（或面板拖到大档）时框可以继续长。
   * 垫高本身由外层 SheetKeyboardLift 负责，这里只用来算尺寸，不重复抬面板。
   */
  @StorageProp('windowHpx') windowHpx: number = 0;
  @StorageProp('keyboardPx') keyboardPx: number = 0;

  /** 键盘之外的可视高度（vp）。取不到窗口高就按常见手机竖屏兜底。 */
  private visibleBand(): number {
    const screenVp: number = this.windowHpx > 0
      ? this.getUIContext().px2vp(this.windowHpx) : 800;
    const kbVp: number = this.keyboardPx > 0 ? this.getUIContext().px2vp(this.keyboardPx) : 0;
    return Math.max(240, screenVp - kbVp);
  }

  /** 批注输入框的上限：约占可视带 45%，最低 160（再小就不能好好打字）、最高 420。 */
  private draftMax(): number {
    return Math.max(160, Math.min(420, Math.round(this.visibleBand() * 0.45)));
  }

  /** LaTeX 源码框的上限：它只是辅助编辑，给到可视带 20%，夹在 64~220。 */
  private mathBoxMax(): number {
    return Math.max(64, Math.min(220, Math.round(this.visibleBand() * 0.2)));
  }

  aboutToAppear(): void {
    this.mathQuote = this.initMathQuote;
    this.mathSrc = this.initMathQuote;
    this.draft = this.initDraft;
    this.style = this.initStyle;
  }

  private isMath(): boolean {
    return this.mathQuote.length > 0;
  }

  /** 编辑框当前选中的片段（去空白）；没选返回空串。 */
  private selected(): string {
    if (this.selStart < 0 || this.selEnd <= this.selStart || this.selEnd > this.mathSrc.length) {
      return '';
    }
    return this.mathSrc.substring(this.selStart, this.selEnd).trim();
  }

  /** 选中片段能否在文档现存源码里对上（对不上就无法按它定位批注区间）。 */
  private selMaps(): boolean {
    const sel: string = this.selected();
    return sel.length > 0 && this.mathQuote.indexOf(sel) >= 0;
  }

  /**
   * 预览要渲染的内容：**选中段在原文里对得上就渲染那段，否则渲染整条**。
   * ⚠️ 基准是 mathQuote 而不是编辑框草稿：逐字符喂草稿会让公式池每敲一个字生成
   * 一张 PNG（缓存塞满中间态、每帧重排），而"将要被批注的内容"本来也以原文为准。
   */
  private preview(): string {
    return this.selMaps() ? this.selected() : this.mathQuote;
  }

  /** 范围标题：与提交时实际用的区间一致，别写成「选中」却按整条存。 */
  private rangeLabel(): string {
    if (this.selMaps()) {
      return '批注范围：选中片段';
    }
    if (this.selected().length > 0) {
      return '批注范围：整条公式（选中的是新写的内容，先「保存公式」才能只批它）';
    }
    return '批注范围：整条公式';
  }

  /**
   * 形态芯片。**刻意不用带参数的 @Builder**：ArkUI V1 里按值传参的 @Builder
   * 不随状态变量刷新，选中态会"点了不变亮"（本工程同类坑）。两处各写一份，
   * 样式由 this.style 直接决定。
   */
  private kindForeground(value: string): string {
    return this.style === value ? this.palette.accent : this.palette.textSecondary;
  }

  private kindBackground(value: string): string {
    return this.style === value ? this.palette.accentSoft : this.palette.quoteBg;
  }

  private kindWeight(value: string): FontWeight {
    return this.style === value ? FontWeight.Medium : FontWeight.Normal;
  }

  /** 源码框选中一段 → 只批那一段；提交时把选中段交给宿主去定位。 */
  private submitNow(): void {
    this.onSubmit(this.draft, this.style, this.selMaps() ? this.selected() : '');
  }

  build() {
    Column({ space: HwSpace.md }) {
      if (!this.isMath()) {
        // 「原文引用」条（公式路径不显示这行：裸 LaTeX 当文字读没有意义，
        // 下面那块渲染 + 源码框就是它的替代品）
        Column() {
          Text('「' + this.initQuote + '」')
            .fontSize(HwType.label)
            .fontColor(this.palette.textSecondary)
            .lineHeight(HwType.label * 1.7)
            .width('100%')
            // 引用过长时收进 4 行（fitContent 面板高度跟内容走，不收会顶爆面板）
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding(HwSpace.sm)
        .borderRadius(HwRadius.inline)
        .backgroundColor(this.palette.quoteBg)
        .border({ width: { left: 3 }, color: { left: this.palette.accent } })
      } else {
        Column({ space: HwSpace.xs }) {
          Text(this.rangeLabel())
            .fontSize(HwType.caption)
            .fontColor(this.palette.textTertiary)
            .width('100%')
          // 公式渲染预览（用户要求：面板要先渲染）
          MathFormulaText({
            src: this.preview(),
            dark: this.dark,
            fontSize: this.bodySize,
            color: this.palette.textPrimary,
            generate: true,
            lineMul: 1.5
          })
          TextArea({ text: this.mathSrc, placeholder: L10n.t('公式源码（LaTeX，可编辑）') })
            .width('100%')
            // 随源码行数长高，上限跟着可视带走（见 mathBoxMax / draftMax）
            .constraintSize({ minHeight: 64, maxHeight: this.mathBoxMax() })
            .fontSize(HwType.label)
            .fontColor(this.palette.textPrimary)
            .backgroundColor(this.palette.quoteBg)
            .borderRadius(HwRadius.inner)
            // 长高/回落都走过渡；.animation 只管它之前声明的属性，必须排在后头
            .animation(AppearanceFx.anim(200, Curve.FastOutSlowIn))
            .onChange((value: string) => {
              this.mathSrc = value;
            })
            .onTextSelectionChange((start: number, end: number) => {
              this.selStart = start;
              this.selEnd = end;
            })
          Row({ space: HwSpace.sm }) {
            ImmersiveChip({
              palette: this.palette,
              chipActive: true,
              chipLabel: L10n.t('保存公式'),
              chipOnTap: () => {
                // 宿主写回成功才把本地基准换成新源码：预览与"只批选中段"的定位
                // 都跟着走，避免面板停留在草稿态、区间却按旧源码算
                if (this.onSaveMath(this.mathSrc.trim())) {
                  this.mathQuote = this.mathSrc.trim();
                  this.selStart = 0;
                  this.selEnd = 0;
                }
              }
            })
          }
          .width('100%')
          Text(L10n.t('长按选中一段就只批注那一段；改过源码点「保存公式」写回文档。'))
            .fontSize(HwType.caption)
            .fontColor(this.palette.textTertiary)
            .lineHeight(HwType.caption * 1.6)
            .width('100%')

          // 公式既可以标成普通批注，也可以进背诵系统（用户要求：卡片上能选）
          Row({ space: HwSpace.xs }) {
            Text(L10n.t('普通批注'))
              .fontSize(HwType.caption + 1)
              .fontWeight(this.kindWeight(''))
              .fontColor(this.kindForeground(''))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(HwRadius.pill)
              .backgroundColor(this.kindBackground(''))
              .onClick(() => {
                this.style = '';
              })
            Text(L10n.t('学习卡'))
              .fontSize(HwType.caption + 1)
              .fontWeight(this.kindWeight('card'))
              .fontColor(this.kindForeground('card'))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(HwRadius.pill)
              .backgroundColor(this.kindBackground('card'))
              .onClick(() => {
                this.style = 'card';
              })
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      TextArea({ text: this.draft, placeholder: this.style === 'card'
        ? L10n.t('要记的内容（学习卡必填题干）……') : L10n.t('写下你的批注……') })
        .width('100%')
        // **随文本内容继续长高**（用户要求）：不写死 height，内容多行时输入框自己
        // 长，长到 draftMax 就内部滚动；draftMax 跟着"键盘之外的可视高度"走，
        // 所以键盘弹起时不会把面板顶出屏幕，键盘收起后还能继续长。
        .constraintSize({ minHeight: 120, maxHeight: this.draftMax() })
        // 长高/回落都走过渡（.animation 只管它之前声明的属性，位置别挪）
        .animation(AppearanceFx.anim(200, Curve.FastOutSlowIn))
        .fontSize(HwType.label)
        .fontColor(this.palette.textPrimary)
        .placeholderColor(this.palette.textTertiary)
        .backgroundColor(this.palette.quoteBg)
        .borderRadius(HwRadius.inner)
        .onChange((value: string) => {
          this.draft = value;
          this.onDraft(value);
        })

      Row({ space: HwSpace.sm }) {
        ImmersiveChip({
          palette: this.palette,
          chipTint: '#FFD32F2F',
          chipActive: true,
          chipLabel: L10n.t('取消'),
          chipOnTap: () => {
            this.onCancel();
          }
        })
        ImmersiveChip({
          palette: this.palette,
          chipActive: true,
          chipLabel: this.style === 'card' ? L10n.t('存为学习卡') : L10n.t('保存批注'),
          chipOnTap: () => {
            this.submitNow();
          }
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
