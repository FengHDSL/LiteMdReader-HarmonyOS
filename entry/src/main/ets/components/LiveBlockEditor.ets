/**
 * 澄笺 · 实时预览编辑的「块编辑态」（LiveBlockEditor）
 * =====================================================
 *
 * 实时预览模式下，被点中的那一块就地展开成这个组件：**上面改源码、下面看渲染**。
 * 之所以单独抽成组件而不是 @Builder：本工程踩过「ForEach 的 itemGenerator 里
 * 调 @Builder 会白屏」的坑（列表是正文的主体，不能冒这个险），组件在 ForEach 里
 * 是安全写法（MdBlockView 就是这么用的）。
 *
 * 两条边界：
 *  1. 组件**只负责呈现与回调**，不碰原文 —— 写回由宿主按块的行区间完成，
 *     这样「一块编辑错了」不会污染别处；
 *  2. 预览区解析的是**草稿本身**（宿主已解析好传进来），所以代码块 / 图表 /
 *     公式在编辑态里就是「实时预览的模样」，改一个字效果立刻变。
 */
import {
  HwFont,
  HwRadius,
  HwSpace,
  HwType,
  LIGHT_PALETTE,
  ReaderPalette
} from '../theme/DesignTokens';
import { ImmersiveChip } from '../material/ImmersiveCard';
import { MdBlock, MdBlockKind, emptyBlock } from '../markdown/MdTypes';
import { MdBlockView } from '../markdown/MdView';
import { L10n } from '../service/L10n';

@Component
export struct LiveBlockEditor {
  /** 正在编辑的块（渲染态的快照，用于判断类型与展示预览） */
  @Prop block: MdBlock = emptyBlock();
  /** 该块在正文列表中的下标（删除等回调要带回去） */
  @Prop index: number = -1;
  /** 调色板：**必须 @Prop**，否则主题切换后不更新（工程踩过） */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /** 正文字号 */
  @Prop bodySize: number = 16;
  /** 行高倍数 */
  @Prop lineMul: number = 1.6;
  /** 正文预览字体族：宿主（编辑页）以 @Prop 下发，实时预览与正文保持同一款字 */
  @Prop fontKey: string = '';
  /** 渲染纪元（字号 / 主题变化后强制重建，拼进 ForEach key） */
  @Prop renderEpoch: number = 0;
  /** 公式图就绪信号（宿主递增）：迷你预览里输入的 $公式$ 出图后换掉线性化文本 */
  @Prop formulaTick: number = 0;
  /** 迷你预览刷新计数（宿主每次草稿重解析递增）：块 id 是解析序号、打字时不变，
   *  不把它并进 key 的话 ForEach 复用旧节点 = "预览效果不实时刷新"（用户实测） */
  @Prop previewTick: number = 0;
  /** 草稿的解析结果（宿主在草稿变化时解析好传进来；组件内不做重活） */
  @Prop previewBlocks: MdBlock[] = [];
  /** **界面字体**（外观设置 → 界面字体）：本页界面文字都从这里取 */
  @StorageProp('appFontFamily') uiFontKey: string = '';
  /** 界面字号缩放系数 / 界面字重相对加粗量（外观设置） */
  @StorageProp('appFontScale') uiFontScale: number = 1;
  @StorageProp('appFontWeightDelta') uiFontWeightDelta: number = 0;
  /** **正文字重**（阅读设置 → 字体粗细）：就地预览那几块也走同一档 */
  @StorageProp('readerFontWeight') bodyWeightMode: string = 'follow';
  /** 源码草稿：与宿主的 @State 双向绑定（@Link 同一引用） */
  @Link draft: string;
  /** 删除这一块 */
  onDelete: (index: number) => void = () => {
  };
  /** 提交（把草稿写回原文） */
  onCommit: () => void = () => {
  };
  /** 草稿变化：宿主负责解析预览；返回新文本 */
  onDraftChange: (value: string) => void = () => {
  };

  /**
   * 源码输入框的组件 id：**带块下标，每个实例各不相同**。
   *
   * 为什么不共用一个固定 id：从一段切到另一段时，旧实例与新实例会在同一帧里
   * 短暂并存 —— 固定 id 时 `requestFocus` 很可能命中**正在销毁的旧节点**，
   * 于是聚焦落空、系统把输入法收起，等新节点上树才重新弹出（用户反馈的
   * "键盘收起又重新打开"就是这么来的）。带下标后每次都精确指向新实例。
   */
  private focusId(): string {
    return 'liveBlockEditor_' + this.index;
  }

  aboutToAppear(): void {
    // **立刻**要一次焦点，失败再短延迟重试两次。
    //
    // ⚠️ 延迟必须短：从一段切到另一段编辑时，旧的编辑组件被移除、新的才挂载，
    // 若中间空档较长，系统会先把输入法收起、再随新组件弹出 —— 观感就是
    // "输入法跳变"（用户反馈很烦）。把聚焦挤进一帧之内，输入法基本保持不动。
    this.focusNow();
    // 两次重试覆盖"组件刚挂载、还没真正上树"的情况；间隔取得很短，
    // 保证焦点交接在一帧到两帧内完成（间隔一大，输入法就会先收再弹）
    setTimeout(() => {
      this.focusNow();
    }, 8);
    setTimeout(() => {
      this.focusNow();
    }, 32);
    setTimeout(() => {
      this.focusNow();
    }, 90);
  }

  /** 请求焦点（幂等：已聚焦时再请求无副作用）。 */
  private focusNow(): void {
    try {
      this.getUIContext().getFocusController().requestFocus(this.focusId());
    } catch (err) {
      // 聚焦失败不影响输入：用户点一下输入框照样能改
    }
  }

  /**
   * 是否显示下方预览。
   *
   * **所有块都给预览**（用户要求：段落文本也要能看到渲染效果）——
   * 段落 / 标题 / 列表 / 引用这些"看起来只是纯文本"的块同样需要即时反馈：
   * 加 `#` 有没有变成标题、`**` 有没有变粗、列表符号对不对，改完立刻能看到。
   */
  private wantPreview(): boolean {
    return this.previewBlocks.length > 0;
  }

  /** 块类型名（让用户知道自己在改什么） */
  private kindLabel(): string {
    if (this.block.kind === MdBlockKind.Heading) {
      return '标题';
    }
    if (this.block.kind === MdBlockKind.Code || this.block.kind === MdBlockKind.Chart) {
      return '代码 / 图表';
    }
    if (this.block.kind === MdBlockKind.Table) {
      return '表格';
    }
    if (this.block.kind === MdBlockKind.Quote || this.block.kind === MdBlockKind.Callout) {
      return '引用';
    }
    if (this.block.kind === MdBlockKind.ListItem) {
      return '列表项';
    }
    if (this.block.kind === MdBlockKind.Math) {
      return '公式';
    }
    if (this.block.kind === MdBlockKind.Divider) {
      return '分割线';
    }
    if (this.block.kind === MdBlockKind.Details) {
      return '折叠块';
    }
    return '段落';
  }

  build() {
    Column({ space: HwSpace.xs }) {
      // 顶部：块类型 + 操作。**「完成」用高亮实心**，让"改完点哪儿"一目了然
      Row({ space: HwSpace.xs }) {
        Row({ space: 5 }) {
          Column()
            .width(3)
            .height(13)
            .borderRadius(2)
            .backgroundColor(this.palette.accent)
          Text(L10n.t('正在编辑 · ') + this.kindLabel())
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette.accent)
        }
        .alignItems(VerticalAlign.Center)

        Blank()

        ImmersiveChip({
          palette: this.palette,
          chipLabel: L10n.t('删除'),
          chipOnTap: () => {
            this.onDelete(this.index);
          }
        })

        ImmersiveChip({
          palette: this.palette,
          chipActive: true,
          chipLabel: L10n.t('完成'),
          chipOnTap: () => {
            this.onCommit();
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 输入区：**给足底色与描边**，一眼看出"这里可以打字"
      // （之前是无底色无边框的一行字，与正文长得差不多，用户根本不知道点进来了）
      TextArea({ text: this.draft, placeholder: L10n.t('在这里改这一块……') })
        .id(this.focusId())
        .width('100%')
        // **不设高度**：由内容自适应撑开（与编辑区同一套做法，避免出现第二个滚动条）
        .constraintSize({ minHeight: 56 })
        .fontSize(this.bodySize * 0.92)
        .fontColor(this.palette.textPrimary)
        .placeholderColor(this.palette.textTertiary)
        .backgroundColor(this.palette.quoteBg)
        .borderRadius(HwRadius.inner)
        .border({ width: 1, color: this.palette.accentSoft })
        .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 6, bottom: 6 })
        .onChange((value: string) => {
          this.draft = value;
          this.onDraftChange(value);
        })

      if (this.wantPreview()) {
        Column() {
          Row({ space: 5 }) {
            Text(L10n.t('预览效果'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette.textTertiary)
            Blank()
            Text(L10n.t('以正文样式渲染'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption - 1, this.uiFontScale))
              .fontColor(this.palette.textTertiary)
              .opacity(0.7)
          }
          .width('100%')
          .padding({ bottom: 4 })

          ForEach(this.previewBlocks, (pb: MdBlock) => {
            MdBlockView({
              block: pb,
              palette: this.palette,
              bodySize: this.bodySize,
              lineMul: this.lineMul,
              fontKey: this.fontKey,
              uiFontKey: this.uiFontKey,
              uiFontScale: this.uiFontScale,
              uiFontWeightDelta: this.uiFontWeightDelta,
              bodyWeightMode: this.bodyWeightMode
            })
          }, (pb: MdBlock) => 'lp_' + pb.id + '_' + this.renderEpoch + '_ft' + this.formulaTick
            + '_r' + this.previewTick)
        }
        .width('100%')
        .padding({ top: HwSpace.xs })
        // 预览与输入框之间给一条虚线：明确"上面是源码、下面是效果"
        .border({ width: { top: 1 }, color: this.palette.divider, style: BorderStyle.Dashed })
      }
    }
    .width('100%')
    .padding({ top: HwSpace.xs, bottom: HwSpace.sm })
  }
}
