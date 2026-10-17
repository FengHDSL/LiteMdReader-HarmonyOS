/**
 * 澄笺 · 任意文本里的行内公式渲染（小区域通用组件）
 * =================================================
 *
 * 供**非 Markdown 块**的场景渲染含公式的文本：背诵卡卡面（front/back）、
 * 批注内容预览等——输入一段字符串（可含 `$…$`，或整段裸 LaTeX），
 * 公式段用与正文同一条 MathJax → PNG 链路出图（InlineFormulaPool），
 * 未就绪时回落 MathLite 线性化文本（绝不空白）。
 *
 * 用法：
 *   MathFormulaText({ src: card.front, dark: this.isDark(),
 *     size: HwType.label + 8, color: this.palette().textPrimary })
 *
 * ⚠️ 每个实例**内嵌一个** InlineFormulaPool（1×1 隐形 Web）——适合"同屏
 * 一两张卡"的场景（背诵视图恰好一张卡的正反面）；**不要**在大列表里
 * 逐条使用（每实例一个 Web 太重），列表场景保持线性化文本即可。
 * 公式图走全局缓存（ChartCache.inlineKey，含字号深浅）：阅读页生成过的
 * 公式在这里直接命中，无需重复生成。
 */

import { common } from '@kit.AbilityKit';
import { InlineFormulaPool } from './InlineFormulaPool';
import { FormulaTask, FormulaTasks } from '../markdown/FormulaTasks';
import { ChartCache } from '../service/ChartCache';
import { MathLite } from '../markdown/MathLite';

/** 切段（FormulaTasks.splitInline 的产物，组件内部再用一次以便 key 稳定） */
interface Seg {
  text: string;
  math: boolean;
}

@Component
export struct MathFormulaText {
  /** 原文（可含成对 `$…$`；无 $ 时整段"像 LaTeX"即按公式渲染） */
  @Prop @Watch('rebuild') src: string = '';
  /** 深浅（参与缓存键：字形墨色随深浅切换） */
  @Prop @Watch('rebuild') dark: boolean = false;
  /** 字号（vp）：公式图按该字号排版，与文字等高协调（⚠️ 不能叫 size——与组件基类通用属性冲突） */
  @Prop @Watch('rebuild') fontSize: number = 16;
  /** 文字颜色（公式图为透明底 PNG，墨色已按深浅烘焙） */
  @Prop color: string = '';
  /** 对齐（背诵卡卡面用居中；⚠️ 不能叫 align——同上） */
  @Prop textAlign: TextAlign = TextAlign.Start;
  /** 粗体（纯文本段生效；公式段已按字号烘焙，不加粗） */
  @Prop bold: boolean = false;
  /**
   * 是否内嵌生成池（默认 true）。
   * **列表场景置 false**：只吃全局缓存（命中即渲染，未命中回落线性化文本），
   * 避免每个实例各挂一个 1×1 Web；由宿主页挂**一个**共用池统一生成
   * （见 Reader 注释抽屉的 drawerFormulaTasks）。
   */
  @Prop generate: boolean = true;
  /** 最大行数（0 = 不限；列表项用它保持紧凑，超出省略） */
  @Prop maxLines: number = 0;
  /** 行高倍数 */
  @Prop lineMul: number = 1.6;
  /** 就绪信号：每出一张图递增 → 含该公式的 Text 重建换成图 */
  @State tick: number = 0;
  /** 公式图生成任务（无公式 = 空数组 = 不挂池子、不建 Web） */
  @State tasks: FormulaTask[] = [];

  aboutToAppear(): void {
    this.rebuild();
  }

  private rebuild(): void {
    this.tasks = FormulaTasks.collectText(this.src, this.dark, this.fontSize);
  }

  private segs(): Seg[] {
    return FormulaTasks.splitInline(this.src);
  }

  /**
   * 公式段图源。
   * ⚠️ srcPath 的 memo **只记"有"**（导出前要轮询等补烘，不能让"没有"被缓存住），
   * 所以这里先问一次 isReady（两个方向都记内存）—— 抽屉 / 学习卡里一段话可能
   * 有好几枚公式，没烘出来之前每帧探一次盘就是上架自检报的冻屏。
   */
  private imgOf(latex: string): string {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return '';
    }
    const key: string = ChartCache.inlineKey(latex, this.dark, this.fontSize);
    if (!ChartCache.isReady(c as common.UIAbilityContext, key)) {
      return '';
    }
    return ChartCache.srcPath(c as common.UIAbilityContext, key);
  }

  /** 公式段逻辑尺寸（'w|h'；显示端显式定 vp 尺寸，防"放大 density 倍"老坑） */
  private dimOf(latex: string): string {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return '';
    }
    return ChartCache.dimOf(c as common.UIAbilityContext,
      ChartCache.inlineKey(latex, this.dark, this.fontSize));
  }

  build() {
    Column() {
      Text() {
        ForEach(this.segs(), (s: Seg) => {
          if (s.math) {
            if (this.imgOf(s.text).length > 0) {
              ImageSpan(this.imgOf(s.text))
                .verticalAlign(ImageSpanAlignment.CENTER)
                .objectFit(ImageFit.Contain)
                .width(this.imgW(s.text))
                .height(this.imgH(s.text))
            } else {
              // 未就绪兜底：线性化文本（图生成后 tick 变 → 本段重建换成图）
              Span(MathLite.inlineText(s.text))
                .fontSize(this.fontSize)
                .fontColor(this.color)
            }
          } else {
            Span(s.text)
              .fontSize(this.fontSize)
              .fontColor(this.color)
              .fontWeight(this.bold ? FontWeight.Bold : FontWeight.Normal)
          }
        }, (s: Seg) => (s.math ? 'm' : 't') + this.tick + '_' + s.text)
      }
        .fontSize(this.fontSize)
        .fontColor(this.color)
        .lineHeight(this.fontSize * this.lineMul)
        .textAlign(this.textAlign)
        .maxLines(this.maxLines > 0 ? this.maxLines : 9999)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      // 池子：只有"允许自建池且真的存在公式段"才挂（纯文本卡零开销；
      // generate=false 的列表实例不挂，由宿主页的共用池统一出图）
      if (this.generate && this.tasks.length > 0) {
        InlineFormulaPool({
          tasks: this.tasks,
          dark: this.dark,
          onOneDone: () => {
            this.tick++;
          }
        })
      }
    }
    .width('100%')
  }

  private imgW(latex: string): Length {
    const dim: string = this.dimOf(latex);
    const bar: number = dim.indexOf('|');
    if (bar <= 0) {
      return this.fontSize * 4;
    }
    const w: number = Number(dim.substring(0, bar));
    return w > 0 ? w : this.fontSize * 4;
  }

  private imgH(latex: string): Length {
    const dim: string = this.dimOf(latex);
    const bar: number = dim.indexOf('|');
    if (bar <= 0) {
      return this.fontSize * 1.4;
    }
    const h: number = Number(dim.substring(bar + 1));
    return h > 0 ? h : this.fontSize * 1.4;
  }
}
