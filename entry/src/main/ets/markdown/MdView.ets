/**
 * LiteMdReader · Markdown 渲染视图
 * ==================================
 *
 * 把 MdParser 产出的扁平 AST 渲染成 ArkUI。
 *
 * 正文内嵌的卡片元素都在这里定义：
 *   CodeBlockCard（语言徽标 + 复制）  QuoteCard（引用竖线）
 *   CalloutCard（五种提示）          TableCard（横向滚动 + 对齐）
 *   FootnoteCard（标号 + 缩进）      ImageCard（独立成段的图片，真实加载）
 *
 * 图片：**独立成段**的 `![替代文字](地址)` 渲染成真实图片——
 *   http/https 网络图（需 INTERNET 权限）、data: Base64、file:// 沙箱文件，
 *   以及相对路径（依次在 docs 目录与 docs/images 下解析，见 DocStore.resolveImagePath）。
 * 与文字混排的行内图片仍以「替代文本」呈现：Span 上没法既保留文本坐标又塞进图片，
 * 而批注坐标系依赖渲染文本逐字符对齐，动它就会让荧光笔错位。
 *
 * 行内富文本用 `Text() { ForEach(...) { Span(...) } }`。
 * 编译期核查结论：ets-loader 的 `checkNonspecificParents` 只在父组件名被追踪时生效，
 * 而 `processComponentChild` 处理 ForEach 分支时会把父组件名重置为 undefined，
 * 因此 ForEach 里的 Span **不会**命中「Span 只能嵌在 Text/RichEditor/ContainerSpan 中」
 * 这条限制。（这一点也符合华为开发者论坛的官方示例写法。）
 */

import { webview } from '@kit.ArkWeb';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { LengthMetrics } from '@kit.ArkUI';
import {
  ANNOTATION_COLORS,
  AnnotationColor,
  HwFont,
  HwRadius,
  HwSpace,
  HwType,
  LIGHT_PALETTE,
  ReaderPalette,
  annotationColor,
  barFrostColor,
  codeBlockHeight,
  headingFontSize,
  headingSpaceTop,
  tableColumnWidth,
  withAlpha
} from '../theme/DesignTokens';
import { ImmersiveCard, ImmersiveCardLayer, ImmersiveChip, ImmersiveIconButton } from '../material/ImmersiveCard';
import { getImmersiveMaterial } from '../material/SystemMaterial';
import { modalSheetOptions } from '../material/ModalSheet';
import { DocStore } from '../service/DocStore';
import { MathLite, MathSeg } from './MathLite';
import { FlowChartView } from './FlowChart';
import { DiagramWeb } from '../components/DiagramWeb';
import { ChartCache } from '../service/ChartCache';
import { EngineRegistry } from '../service/EngineRegistry';
import { UpdateService } from '../service/UpdateService';
import { common } from '@kit.AbilityKit';
import {
  CodeFamily,
  CodeHighlighter,
  CodeState,
  CodeToken,
  CodeTokenKind,
  newCodeState,
  resolveFamily
} from './CodeHighlight';
import {
  MdAnnotation,
  MdBlock,
  MdBlockKind,
  MdCalloutKind,
  MdInline,
  MdInlineKind,
  MdPiece,
  MdTableRow,
  MdTaskState,
  emptyBlock
} from './MdTypes';

/** 提示块的标题与强调色。 */
class CalloutSpec {
  title: string = '';
  color: string = '';
  icon: Resource | null = null;
}

export class MdViewUtil {
  /** 提示块视觉规格。颜色刻意在深浅主题下都保持可读。 */
  static calloutSpec(kind: MdCalloutKind): CalloutSpec {
    const spec: CalloutSpec = new CalloutSpec();
    if (kind === MdCalloutKind.Note) {
      spec.title = 'NOTE';
      spec.color = '#FF2F63E8';
      spec.icon = $r('sys.symbol.info_circle');
    } else if (kind === MdCalloutKind.Tip) {
      spec.title = 'TIP';
      spec.color = '#FF1F9E66';
      spec.icon = $r('sys.symbol.lightbulb');
    } else if (kind === MdCalloutKind.Important) {
      spec.title = 'IMPORTANT';
      spec.color = '#FF8A5AF0';
      spec.icon = $r('sys.symbol.exclamationmark_circle');
    } else if (kind === MdCalloutKind.Warning) {
      spec.title = 'WARNING';
      spec.color = '#FFE08000';
      spec.icon = $r('sys.symbol.exclamationmark_triangle');
    } else if (kind === MdCalloutKind.Caution) {
      spec.title = 'CAUTION';
      spec.color = '#FFD93B3B';
      spec.icon = $r('sys.symbol.exclamationmark_triangle_fill');
    } else {
      spec.title = '';
      spec.color = '#FF8B93A1';
      spec.icon = null;
    }
    return spec;
  }

  /** 行内片段在气泡中显示的文本。 */
  static spanLabel(item: MdInline): string {
    if (item.kind === MdInlineKind.FootnoteRef) {
      return item.num > 0 ? '[' + item.num + ']' : '[' + item.text + ']';
    }
    if (item.kind === MdInlineKind.Image) {
      return item.text.length > 0 ? item.text : item.href;
    }
    if (item.kind === MdInlineKind.Code) {
      // 细空格把行内代码与相邻文字撑开，Span 不支持 padding
      return '\u200A' + item.text + '\u200A';
    }
    return item.text;
  }

  /** 把一组的行内片段转成不带批注的 piece（表格单元格用）。 */
  static toPieces(items: MdInline[], dark: boolean): MdPiece[] {
    const out: MdPiece[] = [];
    for (let k = 0; k < items.length; k++) {
      const item: MdInline = items[k];
      const piece: MdPiece = {
        text: MdViewUtil.spanLabel(item),
        kind: item.kind,
        href: item.href,
        num: item.num,
        // 表格单元格不走批注（区间无意义，占位 0）
        start: 0,
        end: 0,
        bold: item.bold,
        italic: item.italic,
        strike: item.strike,
        code: item.code,
        highlight: '',
        wavy: false,
        dblLine: false,
        annotated: false,
        searchHit: false
      };
      out.push(piece);
    }
    return out;
  }

  static pieceKey(piece: MdPiece, index: number): string {
    return piece.kind + '_' + index + '_' + piece.text.length + '_' + piece.num
      + '_' + piece.highlight.length + (piece.wavy ? '_w' : '')
      + (piece.dblLine ? '_d' : '') + (piece.searchHit ? '_s' : '')
      + (piece.solid ? '_c' : '');
  }

  /** 片段字号：脚注引用与行内代码略小。 */
  static pieceSize(piece: MdPiece, size: number): number {
    if (piece.kind === MdInlineKind.Sup || piece.kind === MdInlineKind.Sub) {
      return Math.round(size * 0.74 * 10) / 10;
    }
    if (piece.kind === MdInlineKind.FootnoteRef) {
      return Math.round(size * 0.72 * 10) / 10;
    }
    if (piece.kind === MdInlineKind.Code) {
      return Math.round(size * 0.92 * 10) / 10;
    }
    return size;
  }

  /** 片段颜色。 */
  static pieceColor(piece: MdPiece, base: string, palette: ReaderPalette): string {
    if (piece.solid === true && piece.highlight.length > 0) {
      // **学习卡实色底上的文字**：绿底配白字（用户反馈黄底白字看不清，已改绿底）
      return '#FFFFFFFF';
    }
    if (piece.kind === MdInlineKind.Link) {
      return palette.accent;
    }
    if (piece.kind === MdInlineKind.Code) {
      return palette.inlineCodeText;
    }
    if (piece.kind === MdInlineKind.FootnoteRef) {
      return palette.accent;
    }
    if (piece.kind === MdInlineKind.Image) {
      return palette.textTertiary;
    }
    return base;
  }

  /** 片段装饰线。 */
  static pieceDecoration(piece: MdPiece, palette: ReaderPalette,
                         waveThickness: number = 1): DecorationStyleInterface {
    if (piece.dblLine) {
      // **红色双下划线**（手写批注）：ArkUI 原生支持 DOUBLE 样式，无需自绘
      return {
        type: TextDecorationType.Underline,
        style: TextDecorationStyle.DOUBLE,
        color: '#FFD93B3B',
        thicknessScale: 2
      };
    }
    if (piece.wavy) {
      // 波浪线标注：画在文字下方的波线。它与底纹互斥，且优先于删除线/下划线。
      //
      // 可调项只有 `thicknessScale`（描边粗细）：ArkUI 的波浪线是系统装饰线，
      // **波峰密度与波峰高度没有开放接口**——要改只能自绘波浪，
      // 那需要逐区间测量文本 x/宽度，而当前正文是「一个 Text + Span 子节点」，
      // 拿不到区间几何；改成逐段独立 Text 又会破坏批注坐标系（块 id + 字符区间）。
      // 所以这里提供真实可调的粗细，并在设置界面写清限制。
      return {
        type: TextDecorationType.Underline,
        style: TextDecorationStyle.WAVY,
        color: palette.accent,
        thicknessScale: waveThickness
      };
    }
    if (piece.strike) {
      return { type: TextDecorationType.LineThrough, color: palette.textTertiary };
    }
    if (piece.kind === MdInlineKind.Link) {
      return { type: TextDecorationType.Underline, color: palette.accent };
    }
    return { type: TextDecorationType.None };
  }

  /**
   * 片段底纹。
   * 优先级：**搜索命中 > 荧光笔 > 行内代码 / 高亮**。
   * 搜索时命中位置必须一眼可见，所以让它盖过用户自己标的荧光笔；
   * 而荧光笔是用户有意为之，不该被语法自带的底纹盖掉。
   */
  static pieceBackground(piece: MdPiece, palette: ReaderPalette,
                         hlOpacity: number = 1): TextBackgroundStyle {
    if (piece.searchHit) {
      return { color: palette.searchHitBg, radius: HwRadius.inline };
    }
    if (piece.solid === true && piece.highlight.length > 0) {
      // **学习卡的实色底**：不透明，不吃荧光笔透明度设置
      return { color: piece.highlight, radius: HwRadius.inline };
    }
    if (piece.highlight.length > 0) {
      // 荧光笔透明度：批注里存的颜色是 #AARRGGBB，这里按用户设置缩放 AA 通道。
      // 只在「荧光笔」这一档生效——搜索命中与语法底纹不受影响。
      return { color: MdViewUtil.scaleAlpha(piece.highlight, hlOpacity), radius: HwRadius.inline };
    }
    if (piece.kind === MdInlineKind.Code) {
      return { color: palette.inlineCodeBg, radius: HwRadius.inline };
    }
    if (piece.kind === MdInlineKind.Mark) {
      return { color: palette.markBg, radius: HwRadius.inline };
    }
    return { color: Color.Transparent };
  }

  /**
   * 按比例缩放 #AARRGGBB 的 alpha 通道（0~1）。
   * 非 9 位色值原样返回——拿不准格式时宁可不改，避免把颜色改坏。
   */
  static scaleAlpha(color: string, opacity: number): string {
    if (color.length !== 9 || color.charAt(0) !== '#') {
      return color;
    }
    const k: number = opacity < 0 ? 0 : (opacity > 1 ? 1 : opacity);
    const a: number = parseInt(color.substring(1, 3), 16);
    if (isNaN(a)) {
      return color;
    }
    const na: number = Math.max(0, Math.min(255, Math.round(a * k)));
    const hex: string = na < 16 ? '0' + na.toString(16).toUpperCase() : na.toString(16).toUpperCase();
    return '#' + hex + color.substring(3);
  }

  /** 代码 token 的颜色。 */
  static tokenColor(kind: number, palette: ReaderPalette): string {
    if (kind === CodeTokenKind.Keyword) {
      return palette.codeKeyword;
    }
    if (kind === CodeTokenKind.Str) {
      return palette.codeString;
    }
    if (kind === CodeTokenKind.Comment) {
      return palette.codeComment;
    }
    if (kind === CodeTokenKind.Number) {
      return palette.codeNumber;
    }
    if (kind === CodeTokenKind.Func) {
      return palette.codeFunc;
    }
    if (kind === CodeTokenKind.Tag) {
      return palette.codeTag;
    }
    if (kind === CodeTokenKind.Attr) {
      return palette.codeAttr;
    }
    return palette.textPrimary;
  }

  /** 脚注引用做成上标。 */
  static pieceBaseline(piece: MdPiece, size: number): LengthMetrics {
    if (piece.kind === MdInlineKind.Sup) {
      return LengthMetrics.vp(Math.round(size * 0.26));
    }
    if (piece.kind === MdInlineKind.Sub) {
      return LengthMetrics.vp(-Math.round(size * 0.12));
    }
    if (piece.kind === MdInlineKind.FootnoteRef) {
      return LengthMetrics.vp(4);
    }
    return LengthMetrics.vp(0);
  }

  /** 列表缩进（vp）。 */
  static listIndent(level: number): number {
    return level * 22;
  }

  /**
   * 把块内行内片段切成带底色的 piece。
   *
   * 为什么必须切分：荧光笔底色与搜索命中底色都只能按 Span 整段设置，
   * 没法「只给某段的前半截上色」。所以先按批注与搜索命中的边界把片段切开，
   * 再逐段决定底色。
   *
   * **关键不变式：所有 piece 的 text 拼接后与切分前完全一致。**
   * 着色只在边界处切、不改字符，选区偏移才不会因为加批注或搜索而漂移。
   */
  static buildPieces(block: MdBlock, annotations: MdAnnotation[], dark: boolean,
                     query: string): MdPiece[] {
    const out: MdPiece[] = [];
    const mine: MdAnnotation[] = [];
    for (let k = 0; k < annotations.length; k++) {
      if (annotations[k].blockId === block.id) {
        mine.push(annotations[k]);
      }
    }

    // 先把整块的渲染文本与每段起点算出来：批注与搜索都按「块内字符区间」定位
    const labels: string[] = [];
    const starts: number[] = [];
    let total: number = 0;
    for (let k = 0; k < block.inlines.length; k++) {
      const label: string = MdViewUtil.spanLabel(block.inlines[k]);
      labels.push(label);
      starts.push(total);
      total += label.length;
    }
    const full: string = labels.join('');

    // 搜索命中区间（不区分大小写，按字符位置收集）
    const hitStarts: number[] = [];
    const hitEnds: number[] = [];
    const needle: string = query.trim().toLowerCase();
    if (needle.length > 0 && total > 0) {
      const lower: string = full.toLowerCase();
      let from: number = 0;
      while (from < lower.length) {
        const at: number = lower.indexOf(needle, from);
        if (at < 0) {
          break;
        }
        hitStarts.push(at);
        hitEnds.push(at + needle.length);
        from = at + needle.length;
      }
    }

    for (let k = 0; k < block.inlines.length; k++) {
      const item: MdInline = block.inlines[k];
      const label: string = labels[k];
      const itemStart: number = starts[k];
      const itemEnd: number = itemStart + label.length;
      if (label.length === 0) {
        continue;
      }

      // 切点：片段自身边界 + 相交的批注边界 + 相交的搜索命中边界
      const cuts: number[] = [itemStart, itemEnd];
      for (let a = 0; a < mine.length; a++) {
        const s: number = Math.max(mine[a].start, itemStart);
        const e: number = Math.min(mine[a].end, itemEnd);
        if (s < e) {
          cuts.push(s);
          cuts.push(e);
        }
      }
      for (let h = 0; h < hitStarts.length; h++) {
        const s: number = Math.max(hitStarts[h], itemStart);
        const e: number = Math.min(hitEnds[h], itemEnd);
        if (s < e) {
          cuts.push(s);
          cuts.push(e);
        }
      }
      cuts.sort((x: number, y: number) => x - y);

      for (let c = 0; c + 1 < cuts.length; c++) {
        const s: number = cuts[c];
        const e: number = cuts[c + 1];
        if (e <= s) {
          continue;
        }
        // 命中底色：取第一个完全覆盖本段的批注
        let highlight: string = '';
        let solid: boolean = false;
        let annotated: boolean = false;
        let wavy: boolean = false;
        let dblLine: boolean = false;
        for (let a = 0; a < mine.length; a++) {
          if (mine[a].start <= s && mine[a].end >= e) {
            annotated = true;
            if (mine[a].style === 'wavy') {
              // 波浪线：不铺底纹，改为在字下画波线
              wavy = true;
            } else if (mine[a].style === 'dbl') {
              // **手写批注的红双下划线**：同样不铺底纹，改为在字下画双线
              dblLine = true;
            } else if (mine[a].style === 'card') {
              // **学习卡的实色底**（1.1.1）：黄底白字对比度差（用户反馈看不清），
              // 改为**深绿实色**，配白色文字足够清晰
              highlight = '#FF1F9E63';
              solid = true;
            } else if (mine[a].color >= 0) {
              highlight = annotationColor(mine[a].color, dark);
            }
            break;
          }
        }
        let searchHit: boolean = false;
        for (let h = 0; h < hitStarts.length; h++) {
          if (hitStarts[h] <= s && hitEnds[h] >= e) {
            searchHit = true;
            break;
          }
        }
        const piece: MdPiece = {
          text: label.substring(s - itemStart, e - itemStart),
          kind: item.kind,
          href: item.href,
          num: item.num,
          start: s,
          end: e,
          bold: item.bold,
          italic: item.italic,
          strike: item.strike,
          code: item.code,
          highlight: highlight,
          solid: solid,
          wavy: wavy,
          dblLine: dblLine,
          annotated: annotated,
          searchHit: searchHit
        };
        out.push(piece);
      }
    }
    return out;
  }

  /** 取 [start, end) 区间内的纯文本，用于把选中内容存进批注。 */
  static sliceText(pieces: MdPiece[], start: number, end: number): string {
    let cursor: number = 0;
    let out: string = '';
    for (let k = 0; k < pieces.length; k++) {
      const text: string = pieces[k].text;
      const s: number = cursor;
      const e: number = cursor + text.length;
      cursor = e;
      if (e <= start || s >= end) {
        continue;
      }
      const from: number = Math.max(start, s) - s;
      const to: number = Math.min(end, e) - s;
      out += text.substring(from, to);
    }
    return out;
  }

  /** 表格各列宽度。 */
  static columnWidths(rows: MdTableRow[]): number[] {
    let cols: number = 0;
    for (let r = 0; r < rows.length; r++) {
      if (rows[r].raw.length > cols) {
        cols = rows[r].raw.length;
      }
    }
    const widths: number[] = [];
    for (let c = 0; c < cols; c++) {
      const column: string[] = [];
      for (let r = 0; r < rows.length; r++) {
        const raw: string[] = rows[r].raw;
        column.push(c < raw.length ? raw[c] : '');
      }
      widths.push(tableColumnWidth(column));
    }
    return widths;
  }

  /** 表格单元格对齐方式。 */
  static cellAlign(align: number): TextAlign {
    if (align === 1) {
      return TextAlign.Center;
    }
    if (align === 2) {
      return TextAlign.End;
    }
    return TextAlign.Start;
  }

  /** 列表标记：有序显示序号，无序显示圆点。 */
  static listMarkerText(block: MdBlock): string {
    return block.ordered ? block.marker : '•';
  }

  /**
   * 是否像「指向另一篇文档」的内部链接：
   * 以 .md / .markdown / .txt 结尾（可带 #锚点），或带 # 锚点但不是纯站内锚点。
   * http(s) 与 mailto 一律不算。
   */
  static looksLikeDocLink(href: string): boolean {
    const h: string = href.trim();
    if (h.length === 0 || h.startsWith('http://') || h.startsWith('https://') || h.startsWith('mailto:')) {
      return false;
    }
    const hashAt: number = h.indexOf('#');
    const path: string = hashAt >= 0 ? h.substring(0, hashAt) : h;
    return path.toLowerCase().endsWith('.md') || path.toLowerCase().endsWith('.markdown')
      || path.toLowerCase().endsWith('.txt') || (hashAt >= 0 && path.length > 0);
  }
}

@Component
export struct MdBlockView {
  /**
   * 全部入参都用 @Prop：ArkTS 的**常规变量只能初始化、不能被父组件更新**，
   * 而字号 / 行高 / 主题都需要在设置变化后立即生效，因此必须走 @Prop 的同步通道。
   */
  @Prop block: MdBlock = emptyBlock();
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  @Prop bodySize: number = HwType.bodyDefault;
  @Prop lineMul: number = HwType.lineDefault;
  @Prop dark: boolean = false;
  /** 当前文档的全部批注。按 blockId 过滤后才参与本块渲染。 */
  @Prop annotations: MdAnnotation[] = [];
  /** 处于"系统选择模式"的块 id（该块恢复系统原生长按菜单）；空串 = 无 */
  @Prop systemSelectId: string = '';
  /** **整页系统选择模式**（AI 对话页等只读展示场景）：所有块的长按直接出系统菜单，
   *  不弹应用批注菜单（用户要求：对话页长按就是系统选择）；阅读页不传走双轨。 */
  @Prop alwaysSystemSelect: boolean = false;
  /** **网页开放开关**（阅读页下发）：true 时点击 http(s) 链接走 webLinkHandler
   *  半模态打开；false（默认）维持「点击复制地址」。 */
  @Prop webOpen: boolean = false;
  /** 最近一次点选的批注色索引（色板点击时记录） */
  @State lastAnnoColor: number = 0;
  /** 点正文退出系统选择模式（宿主清掉 systemSelectId） */
  sysSelectExit: (blockId: string) => void = (_id: string) => {};
  /** 进入某块的系统选择模式（宿主记 systemSelectId 并 toast 提示） */
  sysSelectEnter: (blockId: string) => void = (_id: string) => {};
  /** 当前搜索关键词。非空时命中片段会加底色。 */
  @Prop searchQuery: string = '';
  /** 加载失败的图表缓存 key（Image onError 记入 → 回落 DiagramWeb 实时渲染） */
  @State brokenCharts: string[] = [];
  /** 脑图专用实时卡片的 Web 控制器（每个块视图独立；onPageEnd 注入渲染载荷） */
  private mmCardCtrl: webview.WebviewController = new webview.WebviewController();
  /** 行内公式图的坏缓存（加载失败 → 回落线性化文本；与 brokenCharts 同思路） */
  @State inlineBroken: string[] = [];
  @State copied: boolean = false;
  /**
   * 代码块是否已展开。**长代码默认折叠**（阈值 10 行，参考 lv-markdown-in 的
   * 代码块折叠能力），点底部的「展开全部 N 行」按钮切换。
   */
  @State codeExpanded: boolean = false;
  /** 当前选区（相对本块渲染文本的偏移），由 onTextSelectionChange 给出 */
  @State selStart: number = -1;
  /** 批注菜单的宽度上限（= 本块宽度 + 页边距），超出在胶囊内滚动 */
  @State menuMaxW: number = 360;
  @State selEnd: number = -1;
  /** 图片是否加载失败。失败后渲染占位卡而不是留白 */
  @State imgFailed: boolean = false;
  // ── 排版设置（AppStorage 全局键，编辑页预览同样生效） ──
  @StorageProp('readerFontFamily') fontKey: string = '';
  @StorageProp('readerParaSpace') paraSpaceMul: number = 1.0;
  /**
   * 首行缩进（由**宿主以 @Prop 传入**）。
   * 之前这里读的是 `@StorageProp('readerIndent')`——本工程真机上 AppStorage
   * 被别处改写后子组件不保证回刷，缩进开关点了没反应（用户反馈）。
   * 改为宿主（阅读页）把自己的 @StorageLink 值传下来，属性管道是可靠的。
   */
  @Prop indentOn: boolean = false;
  /** 荧光笔透明度 0.2~1：只缩放批注底纹的 alpha，不影响搜索命中与语法底纹 */
  @StorageProp('hlOpacity') hlOpacity: number = 1;
  /** 沉浸光感开关（已强制开启）：批注菜单那层浮窗外壳据此决定让不让出底色 */
  @StorageProp('immersiveLightEnabled') immersiveOn: boolean = true;
  /** 波浪线粗细（thicknessScale）：系统波浪装饰线唯一开放的可调项 */
  @StorageProp('waveThickness') waveThickness: number = 1;
  /**
   * 已关闭的渲染引擎列表（「设置 → 引擎管理」，逗号分隔 id）。
   * 订阅式读取：设置里一关，所有正文块**当帧**重渲染成源码兜底卡（无需整树重建）。
   */
  @StorageProp('disabledEngines') engineOffList: string = '';

  /** 代码块 token 缓存：token 化要跨行传递状态，不能逐行算，且不宜每次渲染重算。 */
  private codeTokens: CodeToken[][] = [];
  private codeCacheKey: string = '';
  /** 图片路径解析缓存：resolveImagePath 要做磁盘检查，按 href 缓存结果 */
  private imgCacheHref: string = '';
  private imgCacheSrc: string = '';
  /** 加载失败发生在哪个 href 上（换图自动视为未失败；普通成员，避免在 build 期间写状态） */
  private imgFailedHref: string = '';

  /**
   * 批注事件回调。
   * 刻意用**普通成员**而不是 @Prop：ArkTS 的 V1 装饰器不能修饰函数类型。
   * 闭包捕获的是页面实例，运行时读到的始终是页面最新状态，所以不需要随渲染更新。
   *
   * action: 'highlight' | 'note' | 'remove'
   */
  annotateHandler: (action: string, blockId: string, start: number, end: number,
    text: string, color: number) => void = () => {
  };

  /** 站内锚点跳转（`[文字](#标题)`）。同样只能用普通成员。 */
  anchorHandler: (href: string) => void = () => {
  };

  /** 文档间链接（`[文字](./other.md#锚点)`）：抛给页面在书架里定位并开标签。 */
  docLinkHandler: (href: string) => void = () => {
  };

  /** 外部网页链接（webOpen 开启时）：抛给页面在半模态面板内打开。 */
  webLinkHandler: (href: string) => void = () => {
  };

  /** 任务列表勾选切换（点勾选框）：页面负责改写原文并保存/重载。 */
  taskToggleHandler: (blockId: string) => void = () => {
  };

  /** 点击表格块：打开可视化表格编辑（页面按 srcLine 写回原文；只读文档由页面拦截）。 */
  tableEditHandler: (blockId: string) => void = () => {
  };

  /** 「发送AI」（1.2.0）：把选中文本（或整段兜底）抛给页面 → 进入 AI 对话。 */
  aiAskHandler: (text: string) => void = () => {
  };

  /** 图表/公式放大查看：mode 对应 DiagramWeb 模板名，geoKey = 一镜到底的共享 id，title = 原内容标题（可空）。 */
  enlargeHandler: (mode: string, payload: string, geoKey: string, title: string) => void = () => {
  };

  /**
   * 点击正文图片：交给页面开「一镜到底」大图。
   * key 用于 geometryTransition 的共享 id（源与目标必须同 id），src 是解析后的图片地址。
   */
  imageTapHandler: (key: string, src: string) => void = () => {
  };

  /** 沉浸光感是否真的会渲染（开关 × 材质构造成功）。批注菜单外壳用它决定让不让底色。 */
  private materialOn(): boolean {
    return this.immersiveOn && getImmersiveMaterial() !== null;
  }

  /** 图表触摸上报（抑制根级捏合改字号） */
  webTouchHandler: (down: boolean) => void = () => {
  };

  /** 卡片右上角的放大按钮（图表/公式通用）。geoKey = 一镜到底的共享 id，title = 原内容标题。 */
  @Builder
  enlargeButton(mode: string, payload: string, geoKey: string, title: string) {
    Row() {
      ImmersiveIconButton({
        buttonSize: 28,
        buttonMaterialShadow: false,
        palette: this.palette,
        buttonOnTap: () => {
          this.enlargeHandler(mode, payload, geoKey, title);
        }
      }) {
        SymbolGlyph($r('sys.symbol.arrow_up_left_and_arrow_down_right'))
          .fontSize(13)
          .fontColor([this.palette.textTertiary])
      }
    }
    // 只留右边距（用户反馈：与旁边的代码按钮高度对不齐 —— top:4 让它在 Row 里
    // 比同尺寸的按钮低 4vp，去掉后靠 Row 的 VerticalAlign.Center 统一对齐）
    .margin({ right: 4 })
  }

  /**
   * 原内容的标题（放大浮层左上角显示；取不到就返回空串，浮层不显示标题）。
   * 目前只有脑图（markmap）有天然标题 = 首个非空行去掉列表 / 标题标记；
   * 其它图表语言首行是语法，不算标题。
   */
  private chartTitle(): string {
    if (this.block.lang.toLowerCase() !== 'markmap') {
      return '';
    }
    for (let k = 0; k < this.block.codeLines.length; k++) {
      const t: string = this.block.codeLines[k].trim().replace(/^[#*-]+\s*/, '');
      if (t.length > 0) {
        return t;
      }
    }
    return '';
  }

  /** 本块的渲染片段（含荧光笔底色与搜索命中）。 */
  private pieces(): MdPiece[] {
    return MdViewUtil.buildPieces(this.block, this.annotations, this.dark, this.searchQuery);
  }

  /**
   * 代码块的语言徽标：**品牌色小方块 + 语言缩写 + 语言名**（自绘，不用 emoji、
   * 不引入图片资源）。盒子里是几何色块与字母，配色按各语言惯用色，
   * 一眼能分辨语言；未登记的语言只显示原名。
   */
  @Builder
  langBadgeView() {
    Row({ space: 6 }) {
      if (this.langAbbr().length > 0) {
        Text(this.langAbbr())
          .fontSize(9)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFFFF')
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .borderRadius(4)
          .backgroundColor(this.langColor())
      }
      Text(this.block.lang.length > 0 ? this.block.lang : 'text')
        .fontSize(HwType.caption)
        .fontColor(this.palette.textTertiary)
    }
    .alignItems(VerticalAlign.Center)
  }

  /** 语言缩写（方块里显示的字）。 */
  private langAbbr(): string {
    const l: string = this.block.lang.toLowerCase();
    if (l === 'js' || l === 'javascript') {
      return 'JS';
    }
    if (l === 'ts' || l === 'typescript') {
      return 'TS';
    }
    if (l === 'ets' || l === 'arkts') {
      return 'ETS';
    }
    if (l === 'python' || l === 'py') {
      return 'PY';
    }
    if (l === 'java') {
      return 'JV';
    }
    if (l === 'c') {
      return 'C';
    }
    if (l === 'cpp' || l === 'c++') {
      return 'C++';
    }
    if (l === 'cs' || l === 'csharp') {
      return 'C#';
    }
    if (l === 'go' || l === 'golang') {
      return 'GO';
    }
    if (l === 'rust' || l === 'rs') {
      return 'RS';
    }
    if (l === 'swift') {
      return 'SW';
    }
    if (l === 'kotlin' || l === 'kt') {
      return 'KT';
    }
    if (l === 'html' || l === 'htm') {
      return 'HTML';
    }
    if (l === 'xml' || l === 'svg') {
      return 'XML';
    }
    if (l === 'vue') {
      return 'VUE';
    }
    if (l === 'css') {
      return 'CSS';
    }
    if (l === 'scss' || l === 'less') {
      return 'SCSS';
    }
    if (l === 'sh' || l === 'bash' || l === 'zsh' || l === 'shell') {
      return 'SH';
    }
    if (l === 'powershell') {
      return 'PS';
    }
    if (l === 'json') {
      return 'JSON';
    }
    if (l === 'yaml' || l === 'yml') {
      return 'YML';
    }
    if (l === 'toml' || l === 'ini') {
      return 'CFG';
    }
    if (l === 'sql' || l === 'mysql' || l === 'postgresql') {
      return 'SQL';
    }
    // ── 文档类：纯文本与 Markdown（用户要求：这两种也要有自己的徽标）──
    if (l === 'markdown' || l === 'md' || l === 'gfm') {
      return 'MD';
    }
    if (l === 'txt' || l === 'text' || l === 'plain' || l === 'plaintext') {
      return 'TXT';
    }
    return '';
  }

  /** 语言方块的品牌色（暗一档的底色，保证白字对比度）。 */
  private langColor(): string {
    const l: string = this.block.lang.toLowerCase();
    if (l === 'js' || l === 'javascript') {
      return '#FFB8860B';
    }
    if (l === 'ts' || l === 'typescript') {
      return '#FF3178C6';
    }
    if (l === 'ets' || l === 'arkts') {
      return '#FF2F63E8';
    }
    if (l === 'python' || l === 'py') {
      return '#FF3776AB';
    }
    if (l === 'java') {
      return '#FFD9600A';
    }
    if (l === 'c') {
      return '#FF5C6BC0';
    }
    if (l === 'cpp' || l === 'c++') {
      return '#FF00599C';
    }
    if (l === 'cs' || l === 'csharp') {
      return '#FF68217A';
    }
    if (l === 'go' || l === 'golang') {
      return '#FF0E8FA8';
    }
    if (l === 'rust' || l === 'rs') {
      return '#FFB7410E';
    }
    if (l === 'swift') {
      return '#FFD9600A';
    }
    if (l === 'kotlin' || l === 'kt') {
      return '#FF7F52FF';
    }
    if (l === 'html' || l === 'htm') {
      return '#FFE34F26';
    }
    if (l === 'xml' || l === 'svg') {
      return '#FF2F6F4F';
    }
    if (l === 'vue') {
      return '#FF3F8F6B';
    }
    if (l === 'css') {
      return '#FF1572B6';
    }
    if (l === 'scss' || l === 'less') {
      return '#FFC6538C';
    }
    if (l === 'sh' || l === 'bash' || l === 'zsh' || l === 'shell') {
      return '#FF3E8E41';
    }
    if (l === 'powershell') {
      return '#FF2C5F8A';
    }
    if (l === 'json') {
      return '#FF8A7A00';
    }
    if (l === 'yaml' || l === 'yml') {
      return '#FF6E5BA8';
    }
    if (l === 'toml' || l === 'ini') {
      return '#FF5A6B7A';
    }
    if (l === 'sql' || l === 'mysql' || l === 'postgresql') {
      return '#FF00758F';
    }
    // 文档类：Markdown 用其品牌蓝，纯文本用中性青灰（与封面格式角标同一套配色）
    if (l === 'markdown' || l === 'md' || l === 'gfm') {
      return '#FF083FA1';
    }
    if (l === 'txt' || l === 'text' || l === 'plain' || l === 'plaintext') {
      return '#FF5B6B7C';
    }
    return '#FF6B7280';
  }

  /** 代码块的 token 化结果，按块缓存。 */
  private tokensForCode(): CodeToken[][] {
    const key: string = this.block.id + '|' + this.block.lang + '|' + this.block.codeLines.length;
    if (key === this.codeCacheKey) {
      return this.codeTokens;
    }
    this.codeCacheKey = key;
    const family: CodeFamily = resolveFamily(this.block.lang);
    const state: CodeState = newCodeState();
    const out: CodeToken[][] = [];
    for (let k = 0; k < this.block.codeLines.length; k++) {
      out.push(CodeHighlighter.highlightLine(this.block.codeLines[k], family, state));
    }
    this.codeTokens = out;
    return out;
  }

  /** 代码块折叠阈值：超过这个行数就默认折叠（用户要求：默认开启、阈值 10）。 */
  private visibleCodeLines(): number {
    const total: number = this.block.codeLines.length;
    // 折叠阈值 = 10 行
    if (this.codeExpanded || total <= 10) {
      return total;
    }
    return 10;
  }

  /** 选区内的纯文本。 */
  private selectedText(start: number, end: number): string {
    return MdViewUtil.sliceText(this.pieces(), start, end);
  }

  // ────────────────────── 独立图片块 ──────────────────────

  /**
   * 本段是否「独立成段的图片」：段落里恰有一张图片，其余片段都是空白。
   * 是则整段渲染成图片卡，否则图片降级为替代文本（保持批注坐标系不变）。
   */
  private standaloneImage(): MdInline | null {
    if (this.block.kind !== MdBlockKind.Paragraph) {
      return null;
    }
    let img: MdInline | null = null;
    for (let k = 0; k < this.block.inlines.length; k++) {
      const item: MdInline = this.block.inlines[k];
      if (item.kind === MdInlineKind.Image) {
        if (img !== null) {
          return null;
        }
        img = item;
      } else if (item.text.trim().length > 0) {
        return null;
      }
    }
    return img;
  }

  /** 图片地址 → Image 可用的源。按 href 缓存，避免每次渲染都查磁盘。 */
  /**
   * 图片地址解析 + **基础模式（纯离线）拦截**：
   * 离线模式下网络图片（http/https）一律不加载，直接显示占位提示
   * （用户要求：基础模式不联网，插入的网络图片会无法加载）。
   */
  private resolvedImageSrc(href: string): string {
    if (href !== this.imgCacheHref) {
      this.imgCacheHref = href;
      const offline: boolean = UpdateService.isOffline();
      const isNet: boolean = href.startsWith('http://') || href.startsWith('https://');
      this.imgCacheSrc = (offline && isNet) ? '' : DocStore.resolveImagePath(href);
    }
    return this.imgCacheSrc;
  }

  /** 当前块的图片是否处于加载失败态（仅对同一地址生效）。 */
  private isImgFailed(href: string): boolean {
    return this.imgFailed && this.imgFailedHref === href;
  }

  /** 基础模式下被拦下的网络图片（用于占位文案）。 */
  private isOfflineNetImage(href: string): boolean {
    if (!UpdateService.isOffline()) {
      return false;
    }
    return href.startsWith('http://') || href.startsWith('https://');
  }

  @Builder
  imageView() {
    Column() {
      ImmersiveCard({
        cardRadius: HwRadius.inner,
        cardPadding: HwSpace.xs,
        cardMaterialShadow: false,
        palette: this.palette
      }) {
        Column({ space: HwSpace.xs }) {
          if (this.resolvedImageSrc(this.blockHref()).length === 0 || this.isImgFailed(this.blockHref())) {
            this.imageFallback(this.isOfflineNetImage(this.blockHref())
              ? '基础模式（纯离线）下不加载网络图片'
              : (this.isImgFailed(this.blockHref()) ? '图片加载失败' : '找不到本地图片文件'))
          } else {
            // **右上角放大按钮**（用户要求：手写笔记等图片与图表一样有放大入口），
            // 复用图表放大浮层（支持缩放 / 旋转 / 双指）
            Stack({ alignContent: Alignment.TopEnd }) {
              Image(this.resolvedImageSrc(this.blockHref()))
                .width('100%')
                .constraintSize({ maxHeight: 460 })
                .objectFit(ImageFit.Contain)
                .borderRadius(HwRadius.inline)
                .draggable(false)
                // 一镜到底（图片）：与大图浮层上的同一张图片共享 geometry id，
                // 系统据此把「这一张小图」无缝放大成「全屏大图」。
                .geometryTransition('mdimg_' + this.block.id, { follow: true })
                // 点击回调：Editor 实时预览用它打开图片放大浮层；
                // 阅读页不传（放大统一走右上角按钮 —— 用户要求）
                .onError(() => {
                  this.imgFailedHref = this.blockHref();
                  this.imgFailed = true;
                })

              // 注：自定义组件带尾随闭包后不能再链属性（ArkTS 限制）→
              // 用外层容器承载外边距
              Column() {
                ImmersiveIconButton({
                  buttonSize: 30,
                  buttonMaterialShadow: false,
                  palette: this.palette,
                  buttonOnTap: () => {
                    this.enlargeHandler('image', this.resolvedImageSrc(this.blockHref()),
                      'mdimg_' + this.block.id,
                      this.blockAlt().length > 0 ? this.blockAlt() : '图片');
                  }
                }) {
                  SymbolGlyph($r('sys.symbol.arrow_up_left_and_arrow_down_right'))
                    .fontSize(14)
                    .fontColor([this.palette.textPrimary])
                }
              }
              .margin({ top: 6, right: 6 })
            }
            .width('100%')

            if (this.blockAlt().length > 0) {
              Text(this.blockAlt())
                .fontSize(HwType.caption)
                .fontColor(this.palette.textTertiary)
                .width('100%')
                .textAlign(TextAlign.Center)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .margin({ top: HwSpace.sm, bottom: HwSpace.sm })
  }

  private blockHref(): string {
    const img: MdInline | null = this.standaloneImage();
    return img !== null ? img.href : '';
  }

  private blockAlt(): string {
    const img: MdInline | null = this.standaloneImage();
    return img !== null ? img.text : '';
  }

  /** 图片不可用时的占位卡：保留替代文字与地址，说明原因。 */
  @Builder
  imageFallback(reason: string) {
    Row({ space: HwSpace.sm }) {
      SymbolGlyph($r('sys.symbol.picture'))
        .fontSize(22)
        .fontColor([this.palette.textTertiary])
      Column({ space: 2 }) {
        Text(this.blockAlt().length > 0 ? this.blockAlt() : '图片')
          .fontSize(HwType.label)
          .fontColor(this.palette.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(reason + '：' + this.blockHref())
          .fontSize(HwType.caption)
          .fontColor(this.palette.textTertiary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(HwSpace.sm)
    .borderRadius(HwRadius.inline)
    .backgroundColor(this.palette.quoteBg)
  }

  // ────────────────────── 行内富文本 ──────────────────────

  /**
   * 行内段内容（richTextSel 两个分支共用）：
   * 公式段 = ImageSpan（未就绪回落线性化文本），其余 = Span（含批注底纹 / 链接）。
   * ⚠️ 系统选择分支也必须走这套——AI 对话气泡恒为 alwaysSystemSelect，
   * 该分支此前只渲染 block.plain 纯文本，**气泡里的公式从来没渲染过**（用户实测）。
   */
  @Builder
  inlinePieces(size: number, baseColor: string) {
    ForEach(this.pieces(), (piece: MdPiece) => {
        if (piece.kind === MdInlineKind.MathInline) {
          if (this.inlineMathImg(piece.text, size).length > 0) {
            // **公式图**（ContainerSpan **恒包**：结构不跨分支——批注底纹画在
            // 图片背后，透明底的 PNG 会透出底纹；无批注时颜色透明、无视觉差异）。
            // 点击 → **公式操作菜单**（批注/发送AI/放大等——图片没有文字选区，
            // 落注走 piece 的字符区间，见 emitMathAnnotation）。
            ContainerSpan() {
              ImageSpan(this.inlineMathImg(piece.text, size))
                .verticalAlign(ImageSpanAlignment.CENTER)
                .objectFit(ImageFit.Contain)
                // **显式逻辑尺寸**（vp）：PNG 是"逻辑尺寸 × 屏幕密度"的高清像素，
                // 不显式定尺寸会被 1:1 当 vp 用、放大 density 倍（用户实测）
                .width(this.inlineMathW(piece.text, size))
                .height(this.inlineMathH(piece.text, size))
                .onError(() => {
                  // 缓存图损坏/加载失败：标记该公式 → 回落线性化文本，
                  // 绝不留一块空白（此前无兜底，坏图就是永久空白）
                  this.markInlineBroken(piece.text, size);
                })
                .onClick(() => {
                  this.openMathMenu(piece);
                })
            }
            .textBackgroundStyle({
              color: piece.highlight.length > 0 ? piece.highlight : '#00000000',
              radius: 6
            })
          } else {
            // 图未就绪（或渲染失败）时的兜底：线性化文本——点开**公式操作菜单**
            //（内含放大查看 / 批注 / 发送AI 等，与图态一致；此前只能点开浮层看大图）
            Span(MathLite.inlineText(piece.text))
              .fontSize(MdViewUtil.pieceSize(piece, size))
              .fontColor(MdViewUtil.pieceColor(piece, baseColor, this.palette))
              .onClick(() => {
                this.openMathMenu(piece);
              })
          }
        } else {
        Span(piece.text)
          .fontSize(MdViewUtil.pieceSize(piece, size))
          .fontColor(MdViewUtil.pieceColor(piece, baseColor, this.palette))
          .fontWeight(piece.bold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(piece.italic ? FontStyle.Italic : FontStyle.Normal)
          .decoration(MdViewUtil.pieceDecoration(piece, this.palette, this.waveThickness))
          .textBackgroundStyle(MdViewUtil.pieceBackground(piece, this.palette, this.hlOpacity))
          .baselineOffset(MdViewUtil.pieceBaseline(piece, size))
          .onClick(() => {
            if (this.systemSelectId === this.block.id) {
              // 系统选择模式下点正文 = 退出该模式，恢复自定义批注菜单
              this.sysSelectExit(this.block.id);
              return;
            }
            if (piece.kind !== MdInlineKind.Link) {
              return;
            }
            if (piece.href.startsWith('#')) {
              // 站内锚点（`[文字](#标题)`）：交给页面在大纲里定位并跳转
              this.anchorHandler(piece.href);
            } else if (MdViewUtil.looksLikeDocLink(piece.href)) {
              // 文档间链接（`[文字](./other.md#锚点)`）：交给页面开标签跳转
              this.docLinkHandler(piece.href);
            } else if (piece.href.startsWith('http://') || piece.href.startsWith('https://')) {
              // 外部链接：网页开放开启 → 页面半模态打开；关闭 → 维持「点击复制地址」
              this.webLinkHandler(piece.href);
            } else {
              // 其他协议（mailto 等）不做跳转（需要 want + 浏览器能力），点击复制地址并提示
              this.copyText(piece.href, '链接已复制');
            }
          })
        }
      }, (piece: MdPiece, index: number) => MdViewUtil.pieceKey(piece, index))
  }

  /**
   * 正文的主力行内渲染：**可长按选择、可复制、可加荧光笔与文字批注**。
   *
   * 三个属性缺一不可，否则长按完全没有反应：
   *   · `copyOption(LocalDevice)` —— 不开的话 Text 根本不进入选择态；
   *   · `onTextSelectionChange`   —— 拿到选区偏移，批注要用它定位；
   *   · `bindSelectionMenu`       —— 用自定义菜单替换系统菜单，把「荧光笔」放进去。
   */
  @Builder
  richTextSel(size: number, baseColor: string, lineMul: number, align: TextAlign, firstIndent: boolean) {
    if (this.systemSelectId === this.block.id || this.alwaysSystemSelect) {
      // ── **系统选择模式**（用户要求）：不用自定义批注菜单，恢复系统原生长按菜单 ——
      // 复制 / 全选 / 翻译 / 唤起小艺等系统能力直接可用。点一下正文退出（见 Span onClick）。
      Text() {
        this.inlinePieces(size, baseColor)
      }
      .fontSize(size)
      .fontColor(baseColor)
      .lineHeight(size * lineMul)
      .textAlign(align)
      .fontFamily(HwFont.resolve(this.fontKey))
      .textIndent(firstIndent ? Math.round(size * 2) : 0)
      .width('100%')
      .copyOption(CopyOptions.LocalDevice)
    } else {
    Text() {
      this.inlinePieces(size, baseColor)
    }
    .fontSize(size)
    .fontColor(baseColor)
    .lineHeight(size * lineMul)
    .textAlign(align)
    .fontFamily(HwFont.resolve(this.fontKey))
    // 首行缩进按正文尺寸取两个字宽；0 表示不缩进
    .textIndent(firstIndent ? Math.round(size * 2) : 0)
    .width('100%')
    .copyOption(CopyOptions.LocalDevice)
    .onTextSelectionChange((start: number, end: number) => {
      this.selStart = start;
      this.selEnd = end;
    })
    .bindSelectionMenu(TextSpanType.TEXT, this.annotateMenu(), TextResponseType.LONG_PRESS)
    }
  }

  /**
   * 表格单元格用的行内渲染：不带选择与批注。
   * 单元格本身处在一个横向滚动的 Scroll 里，长按选择会和横向拖动打架，
   * 所以 v1 明确不支持在表格里做批注。
   */
  @Builder
  richText(pieces: MdPiece[], size: number, baseColor: string, lineMul: number, align: TextAlign) {
    Text() {
      ForEach(pieces, (piece: MdPiece) => {
        if (piece.kind === MdInlineKind.MathInline) {
          if (this.inlineMathImg(piece.text, size).length > 0) {
            ImageSpan(this.inlineMathImg(piece.text, size))
              .verticalAlign(ImageSpanAlignment.CENTER)
              .objectFit(ImageFit.Contain)
              // **显式逻辑尺寸**（vp）：PNG 是"逻辑尺寸 × 屏幕密度"的高清像素，
              // 不显式定尺寸会被 1:1 当 vp 用、放大 density 倍（用户实测）
              .width(this.inlineMathW(piece.text, size))
              .height(this.inlineMathH(piece.text, size))
              .onError(() => {
                // 缓存图损坏/加载失败：标记该公式 → 回落线性化文本，
                // 绝不留一块空白（此前无兜底，坏图就是永久空白）
                this.markInlineBroken(piece.text, size);
              })
          } else {
            Span(MathLite.inlineText(piece.text))
              .fontSize(MdViewUtil.pieceSize(piece, size))
              .fontColor(MdViewUtil.pieceColor(piece, baseColor, this.palette))
          }
        } else {
        Span(piece.text)
          .fontSize(MdViewUtil.pieceSize(piece, size))
          .fontColor(MdViewUtil.pieceColor(piece, baseColor, this.palette))
          .fontWeight(piece.bold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(piece.italic ? FontStyle.Italic : FontStyle.Normal)
          .decoration(MdViewUtil.pieceDecoration(piece, this.palette, this.waveThickness))
          .textBackgroundStyle(MdViewUtil.pieceBackground(piece, this.palette, this.hlOpacity))
          .baselineOffset(MdViewUtil.pieceBaseline(piece, size))
        }
      }, (piece: MdPiece, index: number) => MdViewUtil.pieceKey(piece, index))
    }
    .fontSize(size)
    .fontColor(baseColor)
    .lineHeight(size * lineMul)
    .textAlign(align)
    .fontFamily(HwFont.resolve(this.fontKey))
    .width('100%')
  }

  /** 胶囊菜单里的紧凑动作段：宽度可控，整条菜单不再被屏幕右缘裁切。 */
  @Builder
  menuAction(label: string, onTap: () => void) {
    Text(label)
      .fontSize(HwType.caption + 1)
      .fontColor(this.palette.textPrimary)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .borderRadius(14)
      .backgroundColor(this.palette.quoteBg)
      .onClick(() => {
        onTap();
      })
  }

  /** 批注菜单：替换系统默认选择菜单。**胶囊形态** + 沉浸光感；四个色点是荧光笔，右侧是批注 / 波浪线 / 复制 / 清除。 */
  @Builder
  annotateMenu() {
    // 浮层外壳：**胶囊（pill）+ 沉浸光感承载层（Toggle 方案）**。
    // 三条约束决定了这里的写法：
    //  ① 不能用 ImmersiveCard 包：它根 Stack 的宽度是 `'100%'`，而系统选择菜单是
    //     按内容自适应尺寸的，`'100%'` 会被解析成"可用宽度" → 卡片炸大（踩过）；
    //  ② Stack 里承载层用 `LayoutPolicy.matchParent`：由内容（下面的 Scroll）定尺寸；
    //  ③ 材质可用时降级层必须透明，把采样让给背后的正文，否则看着像普通纯色浮窗。
    // 内容做过压缩（色点 22 + 紧凑文字段），一屏放得下，右侧不再裁切；
    // 横向 Scroll 保留兜底：极窄屏上仍可滑动。
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .borderRadius(24)
        .backgroundColor(this.materialOn() ? '#00000000' : barFrostColor(this.palette.surface))
        .backgroundBlurStyle(this.materialOn() ? BlurStyle.NONE : BlurStyle.Thin)
        .hitTestBehavior(HitTestMode.None)

      ImmersiveCardLayer({ layerRadius: 24, layerShadow: true })

      Scroll() {
        Column({ space: 4 }) {
          Row({ space: HwSpace.xs }) {
            ForEach(ANNOTATION_COLORS, (item: AnnotationColor, index: number) => {
              Column()
                .width(22)
                .height(22)
                .borderRadius(11)
                .backgroundColor(item.light)
                .border({ width: 1, color: '#33000000' })
                .onClick(() => {
                  // 色点 = 荧光笔；同时记下颜色，供「框选」等无色板入口复用
                  this.lastAnnoColor = index;
                  this.emitAnnotation('highlight', index);
                })
            }, (item: AnnotationColor, index: number) => 'sw' + index)

            this.menuAction('批注', () => {
              this.emitAnnotation('note', -1);
            })

            // **学习卡**（1.1.0）：实色黄底 + 必填内容，数据供「复习卡片 / 批注速记」用
            this.menuAction('学习卡', () => {
              this.emitAnnotation('studycard', -1);
            })

            // 波浪线：与荧光笔、文字批注并列的第三种标注形态（画在字下方）
            this.menuAction('波浪线', () => {
              this.emitAnnotation('wavy', 0);
            })

            // **手写批注**（用户要求）：进手写页画一笔，回来落成"红双下划线"批注
            this.menuAction('手写批注', () => {
              this.emitAnnotation('handwrite', -1);
            })

            // 系统选择（用户要求）：恢复系统原生长按菜单，方便复制 / 翻译 / 唤起小艺
            this.menuAction('系统选择', () => {
              this.sysSelectExit('');
              this.sysSelectEnter(this.block.id);
            })

            // **发送AI**（1.2.0）：把选中文本发给 AI 助手（无选区时发整段兜底）
            this.menuAction('发送AI', () => {
              const s: number = this.selStart;
              const e: number = this.selEnd;
              const text: string = (s >= 0 && e > s)
                ? this.selectedText(s, e) : this.block.plain;
              if (text.length === 0) {
                this.toast('没有可发送的文字');
                return;
              }
              this.aiAskHandler(text);
            })

            this.menuAction('复制', () => {
              const start: number = this.selStart;
              const end: number = this.selEnd;
              if (start >= 0 && end > start) {
                this.copyText(this.selectedText(start, end), '已复制所选文字');
              } else {
                this.copyText(this.block.plain, '已复制整段');
              }
            })

            this.menuAction('清除', () => {
              this.emitAnnotation('remove', -1);
            })
          }
          .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 7, bottom: 7 })
          .alignItems(VerticalAlign.Center)
        }
        .alignItems(HorizontalAlign.Start)
      }
      // Scroll 只要滚动能力：**不能给它铺底色**，否则会盖住下面那层材质；
      // 圆形裁切：内容超出胶囊时按胶囊圆角裁掉（而不是直角切过"清除"字样）
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .borderRadius(24)
      .clip(true)
    }
    // **高度自适应**（框选色板展开时两行）：minHeight 保证单行时仍是 48 的胶囊观感
    .constraintSize({ minHeight: 48 })
    .borderRadius(24)
    // **宽度上限 = 本块宽度 + 页边距**：超出就在胶囊内横向滚动，
    // 整条菜单不会被系统摆到屏幕外（右缘裁切问题的根治）
    .constraintSize({ maxWidth: this.menuMaxW })
    // 出现 / 消失动画：淡入 + 轻微上浮（TransitionEffect 自带 animation，
    // 不依赖 animateTo，系统选择菜单挂载 / 卸载时都能播）
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.FastOutSlowIn })
        .combine(TransitionEffect.translate({ y: 8 })
          .animation({ duration: 180, curve: Curve.FastOutSlowIn })),
      TransitionEffect.OPACITY.animation({ duration: 130, curve: Curve.FastOutSlowIn })
    ))
  }

  /** 把选区上的批注操作抛给页面处理（页面负责落盘与刷新）。 */
  private emitAnnotation(action: string, color: number): void {
    const start: number = this.selStart;
    const end: number = this.selEnd;
    if (start < 0 || end <= start) {
      this.toast('请先长按选中一段文字');
      return;
    }
    const text: string = this.selectedText(start, end);
    if (text.length === 0) {
      this.toast('选区为空，请重新选择');
      return;
    }
    this.annotateHandler(action, this.block.id, start, end, text, color);
  }

  // ────────────────────── 各类块 ──────────────────────

  @Builder
  headingView() {
    Column({ space: HwSpace.xs }) {
      this.richTextSel(headingFontSize(this.block.level, this.bodySize),
        this.palette.textPrimary, this.block.level <= 2 ? 1.34 : 1.42, TextAlign.Start, false)
      if (this.block.level <= 2) {
        Divider()
          .strokeWidth(3)
          .color(this.palette.accent)
          .opacity(0.9)
          .width(this.block.level === 1 ? 58 : 38)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: headingSpaceTop(this.block.level), bottom: HwSpace.xs })
  }

  @Builder
  paragraphView() {
    this.richTextSel(this.bodySize, this.palette.textPrimary, this.lineMul, TextAlign.Start,
      this.indentOn)
  }

  @Builder
  codeView() {
    // ArkTS 不允许在「尾随闭包初始化的自定义组件」后面继续链式调用属性，
    // 所以外边距挂在这一层包装容器上，而不是挂在 ImmersiveCard 上。
    Column() {
      // 代码块卡片：语言徽标 + 复制按钮 + 定高滚动代码区
      ImmersiveCard({
        cardRadius: HwRadius.inner,
        cardPadding: 0,
        cardMaterialShadow: false,
        cardBackground: this.palette.codeBlockBg,
        palette: this.palette
      }) {
        Column() {
        Row() {
          this.langBadgeView()
          Blank()
          ImmersiveIconButton({
            buttonSize: 28,
            buttonMaterialShadow: false,
            palette: this.palette,
            buttonOnTap: () => {
              this.copyCode();
            }
          }) {
            if (this.copied) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(14)
                .fontColor([this.palette.accent])
            } else {
              SymbolGlyph($r('sys.symbol.square_on_square_fill'))
                .fontSize(14)
                .fontColor([this.palette.textTertiary])
            }
          }
          // 两个按钮之间的空隙（用户反馈贴在一起）
          Column()
            .width(HwSpace.xs)
          // **放大查看放最右边**（用户要求）：走与图表卡同一套放大浮层
          // （mode='code' 由 render/code.html 渲染带行号的等宽代码）。
          ImmersiveIconButton({
            buttonSize: 28,
            buttonMaterialShadow: false,
            palette: this.palette,
            buttonOnTap: () => {
              this.enlargeHandler('code', this.block.code, 'mdcode_' + this.block.id,
                this.block.lang.length > 0 ? this.block.lang : 'code');
            }
          }) {
            SymbolGlyph($r('sys.symbol.arrow_up_left_and_arrow_down_right'))
              .fontSize(14)
              .fontColor([this.palette.textTertiary])
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .alignItems(VerticalAlign.Center)
        .padding({ left: HwSpace.md, right: HwSpace.xs, top: HwSpace.xs, bottom: 0 })

        Scroll() {
          Column() {
            // **行号 + 代码**（索引默认展示，参考 lv-markdown-in 的 setCodeBlockIdxState）：
            // 行号等宽右对齐，与代码之间一条细竖分割线；折叠时只渲染前 10 行
            // （用 slice 在数据层截断，比在 itemGenerator 里写 if 更稳）。
            ForEach(this.tokensForCode().slice(0, this.visibleCodeLines()),
              (tokens: CodeToken[], lineIndex: number) => {
                Row() {
                  Text((lineIndex + 1).toString())
                    .fontSize(this.bodySize * HwType.codeScale * 0.85)
                    .fontColor(this.palette.textTertiary)
                    .width(22)
                    .textAlign(TextAlign.End)
                    .lineHeight(this.bodySize * HwType.codeScale * 1.6)
                  Divider()
                    .vertical(true)
                    .height(this.bodySize * HwType.codeScale * 1.4)
                    .strokeWidth(0.6)
                    .color(this.palette.divider)
                    .margin({ left: 6, right: 8 })
                  Text() {
                    ForEach(tokens, (token: CodeToken) => {
                      Span(token.text)
                        .fontSize(this.bodySize * HwType.codeScale)
                        .fontColor(MdViewUtil.tokenColor(token.kind, this.palette))
                    }, (token: CodeToken, ti: number) => 't' + ti + '_' + token.kind + '_' + token.text.length)
                  }
                  .fontSize(this.bodySize * HwType.codeScale)
                  .fontColor(this.palette.textPrimary)
                  .lineHeight(this.bodySize * HwType.codeScale * 1.6)
                  .layoutWeight(1)
                  // 长按代码 = 系统选择菜单（用户要求：对话页统一系统选择，不做应用菜单）。
                  // copyOption 是进入选择态的前提；不挂 bindSelectionMenu 即为系统菜单。
                  .copyOption(CopyOptions.LocalDevice)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
              }, (tokens: CodeToken[], lineIndex: number) => 'c' + lineIndex + '_' + tokens.length)

          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: HwSpace.md, right: HwSpace.md, top: HwSpace.xs, bottom: HwSpace.md })
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Auto)
        .width('100%')
        // 展开 / 收起控制条已移到 Scroll 之外（固定在卡片底部），
        // 这里把它的高度一并算进去 —— 否则卡片比内容矮，下边缘会压住正文
        //（用户实测：代码块下方的文字被卡片遮住）。
        .height(codeBlockHeight(this.visibleCodeLines(), this.bodySize)
          + (this.block.codeLines.length > 10 ? 32 : 0))

        // **折叠控制条固定在卡片底部**（用户要求：不随代码一起滚动）——
        // 之前它放在 Scroll 内部，长代码滚下去就看不到入口了；移出来常驻卡片底部。
        if (this.block.codeLines.length > 10) {
          Row() {
            Text(this.codeExpanded
              ? '收起代码'
              : '展开全部 ' + this.block.codeLines.length + ' 行')
              .fontSize(HwType.caption)
              .fontColor(this.palette.accent)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: HwSpace.xs, bottom: HwSpace.sm })
          .onClick(() => {
            this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
              this.codeExpanded = !this.codeExpanded;
            });
          })
        }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .margin({ top: HwSpace.sm, bottom: HwSpace.sm })
  }

  @Builder
  quoteView() {
    Column() {
      this.richTextSel(this.bodySize, this.palette.textSecondary, this.lineMul, TextAlign.Start, false)
    }
    .width('100%')
    .padding({ left: HwSpace.md, right: HwSpace.md, top: HwSpace.sm, bottom: HwSpace.sm })
    .border({ width: { left: 3 }, color: { left: this.palette.quoteBar } })
    .borderRadius(HwRadius.inline)
    .backgroundColor(this.palette.quoteBg)
  }

  @Builder
  calloutView() {
    Column({ space: HwSpace.xs }) {
      Row({ space: HwSpace.xs }) {
        if (MdViewUtil.calloutSpec(this.block.callout).icon !== null) {
          SymbolGlyph(MdViewUtil.calloutSpec(this.block.callout).icon)
            .fontSize(15)
            .fontColor([MdViewUtil.calloutSpec(this.block.callout).color])
        }
        Text(MdViewUtil.calloutSpec(this.block.callout).title)
          .fontSize(HwType.label)
          .fontWeight(FontWeight.Medium)
          .fontColor(MdViewUtil.calloutSpec(this.block.callout).color)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      this.richTextSel(this.bodySize, this.palette.textPrimary, this.lineMul, TextAlign.Start, false)
    }
    .width('100%')
    .padding({ left: HwSpace.md, right: HwSpace.md, top: HwSpace.sm, bottom: HwSpace.sm })
    .border({ width: { left: 3 }, color: { left: MdViewUtil.calloutSpec(this.block.callout).color } })
    .borderRadius(HwRadius.inline)
    .backgroundColor(this.palette.quoteBg)
    .margin({ top: HwSpace.xs, bottom: HwSpace.xs })
  }

  @Builder
  listItemView() {
    Row({ space: HwSpace.sm }) {
      // 任务列表：勾选框可点击切换；其余：圆点 / 序号
      if (this.block.task === MdTaskState.Todo) {
        Column()
          .width(15)
          .height(15)
          .borderRadius(4)
          .border({ width: 1.5, color: this.palette.textTertiary })
          .margin({ top: this.bodySize * 0.32 })
          .onClick(() => {
            this.taskToggleHandler(this.block.id);
          })
      } else if (this.block.task === MdTaskState.Done) {
        SymbolGlyph($r('sys.symbol.checkmark_square_fill'))
          .fontSize(16)
          .fontColor([this.palette.accent])
          .margin({ top: this.bodySize * 0.28 })
          .onClick(() => {
            this.taskToggleHandler(this.block.id);
          })
      } else if (this.block.ordered) {
        Text(MdViewUtil.listMarkerText(this.block))
          .fontSize(this.bodySize * 0.9)
          .fontColor(this.palette.accent)
          .fontWeight(FontWeight.Medium)
          .margin({ top: this.bodySize * 0.1 })
      } else {
        Column()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(this.palette.accent)
          .opacity(this.block.indent > 0 ? 0.6 : 1)
          .margin({ top: this.bodySize * 0.55 })
      }

      Column() {
        this.richTextSel(this.bodySize,
          this.block.task === MdTaskState.Done ? this.palette.textTertiary : this.palette.textPrimary,
          this.lineMul, TextAlign.Start, false)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: MdViewUtil.listIndent(this.block.indent) })
    .margin({ bottom: this.block.footnoteNo > 0 ? HwSpace.sm : HwSpace.xxs })
  }

  @Builder
  footnoteView() {
    Row({ space: HwSpace.sm }) {
      Text(this.block.marker)
        .fontSize(HwType.caption)
        .fontColor(this.palette.accent)
        .fontWeight(FontWeight.Medium)
        .margin({ top: 2 })
      Column() {
        this.richTextSel(this.bodySize * HwType.footnoteScale,
          this.palette.textSecondary, this.lineMul, TextAlign.Start, false)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: HwSpace.sm })
      .border({ width: { left: 2 }, color: { left: this.palette.divider } })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: HwSpace.sm })
  }

  @Builder
  tableRowView(row: MdTableRow) {
    Row() {
      ForEach(row.cells, (cell: MdInline[], col: number) => {
        Column() {
          this.richText(MdViewUtil.toPieces(cell, this.dark),
            this.bodySize * 0.92,
            row.header ? this.palette.textPrimary : this.palette.textSecondary,
            1.45,
            this.cellAlignOf(row, col))
        }
        .width(this.columnWidthOf(row, col))
        .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 7, bottom: 7 })
        .alignItems(HorizontalAlign.Start)
        .border({
          width: { left: this.borderLeftOf(row, col) },
          color: { left: this.palette.divider }
        })
      }, (cell: MdInline[], col: number) => 'cell' + col + '_' + cell.length)
    }
    .backgroundColor(row.header ? this.palette.tableHeadBg : this.palette.tableStripeBg)
  }

  private borderLeftOf(row: MdTableRow, col: number): number {
    return col === 0 ? 0 : 1;
  }

  private cellAlignOf(row: MdTableRow, col: number): TextAlign {
    if (this.block.aligns.length > col) {
      return MdViewUtil.cellAlign(this.block.aligns[col]);
    }
    return TextAlign.Start;
  }

  private columnWidthOf(row: MdTableRow, col: number): number {
    const widths: number[] = MdViewUtil.columnWidths(this.block.rows);
    if (col < widths.length) {
      return widths[col];
    }
    return 120;
  }

  @Builder
  tableView() {
    Column() {
      Scroll() {
        Column() {
          ForEach(this.block.rows, (row: MdTableRow, index: number) => {
            this.tableRowView(row)
          }, (row: MdTableRow, index: number) => 'row' + index + '_' + row.raw.length)
        }
        .alignItems(HorizontalAlign.Start)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Auto)
      .width('100%')
    }
    .width('100%')
    .borderRadius(HwRadius.inner)
    .clip(true)
    .border({ width: 1, color: this.palette.divider })
    .margin({ top: HwSpace.xs, bottom: HwSpace.xs })
    // **点表格打开可视化编辑**（TableEditorDialog，页面按块 srcLine 写回原文）。
    // onClick 不影响表格内部的横向滚动手势（滚动手势由 Scroll 消费，单击才冒泡）。
    .onClick(() => {
      this.tableEditHandler(this.block.id);
    })
  }

  @Builder
  dividerView() {
    Divider()
      .strokeWidth(1)
      .color(this.palette.divider)
      .margin({ top: HwSpace.lg, bottom: HwSpace.lg })
  }

  // ────────────────────── 数学块 / 图表块 ──────────────────────

  private mathSegsCacheKey: string = '';
  private mathSegsCache: MathSeg[] = [];

  /** 公式顶层结构段（按块缓存）。 */
  private mathSegments(): MathSeg[] {
    const key: string = this.block.id + '|' + this.block.code.length;
    if (key !== this.mathSegsCacheKey) {
      this.mathSegsCacheKey = key;
      this.mathSegsCache = MathLite.segments(this.block.code);
    }
    return this.mathSegsCache;
  }

  @Builder
  mathSegView(seg: MathSeg) {
    if (seg.kind === 'frac') {
      Column({ space: 2 }) {
        Text(seg.num)
          .fontSize(this.bodySize * 0.82)
          .fontColor(this.palette.textPrimary)
          .textAlign(TextAlign.Center)
          .constraintSize({ maxWidth: 220 })
        Divider()
          .strokeWidth(1.2)
          .color(this.palette.textPrimary)
        Text(seg.den)
          .fontSize(this.bodySize * 0.82)
          .fontColor(this.palette.textPrimary)
          .textAlign(TextAlign.Center)
          .constraintSize({ maxWidth: 220 })
      }
      .alignItems(HorizontalAlign.Center)
      .margin({ left: 4, right: 4 })
    } else if (seg.kind === 'sup') {
      Text(seg.text)
        .fontSize(this.bodySize * 0.72)
        .fontColor(this.palette.textPrimary)
        .baselineOffset(this.bodySize * 0.5)
        .margin({ left: 1 })
    } else if (seg.kind === 'sub') {
      Text(seg.text)
        .fontSize(this.bodySize * 0.72)
        .fontColor(this.palette.textPrimary)
        .baselineOffset(-this.bodySize * 0.18)
        .margin({ left: 1 })
    } else if (seg.kind === 'sqrt') {
      Row({ space: 0 }) {
        Text('√')
          .fontSize(this.bodySize * 1.15)
          .fontColor(this.palette.textPrimary)
        Text(seg.text)
          .fontSize(this.bodySize * 0.95)
          .fontColor(this.palette.textPrimary)
          .decoration({ type: TextDecorationType.Overline, color: this.palette.textPrimary })
      }
      .alignItems(VerticalAlign.Top)
    } else if (seg.kind === 'matrix' || seg.kind === 'cases') {
      Row({ space: 3 }) {
        Text(seg.num)
          .fontSize(this.matrixParenSize(seg))
          .fontColor(this.palette.textPrimary)
        Column({ space: 3 }) {
          ForEach(seg.rows, (row: string[], r: number) => {
            Row({ space: 10 }) {
              ForEach(row, (cell: string, c: number) => {
                Text(cell.length > 0 ? cell : ' ')
                  .fontSize(this.bodySize * 0.9)
                  .fontColor(this.palette.textPrimary)
              }, (cell: string, c: number) => 'c' + c + '_' + cell)
            }
          }, (row: string[], r: number) => 'r' + r + '_' + row.join('_'))
        }
        .alignItems(HorizontalAlign.Start)
        Text(seg.den)
          .fontSize(this.matrixParenSize(seg))
          .fontColor(this.palette.textPrimary)
      }
      .alignItems(VerticalAlign.Center)
      .margin({ left: 4, right: 4 })
    } else {
      Text(seg.text)
        .fontSize(this.bodySize * 1.04)
        .fontColor(this.palette.textPrimary)
    }
  }

  private matrixParenSize(seg: MathSeg): number {
    const h: number = seg.rows.length * this.bodySize * 1.1;
    return Math.min(72, Math.max(this.bodySize, h));
  }

  /**
   * 图表缓存图路径（无缓存或**已知加载失败**返回空串）。
   * 失败的缓存（写坏 / 半截文件）会让 Image 静默空白且不回落 ——
   * onError 时把 key 记进 brokenCharts，之后走 DiagramWeb 实时渲染兜底，
   * 否则坏缓存会一直"加载不出来"且重启也无效（缓存是持久文件）。
   */
  /**
   * 行内公式预渲染图源（后台池按公式自身尺寸渲染；无则回落线性文本）。
   *
   * ⚠️ 交给 ImageSpan 必须用 `ChartCache.srcPath`（带 `file://` 前缀）——
   * 裸沙箱路径会让 ImageSpan **静默加载失败**（用户实测"全部空白"），
   * 详见 ChartCache.srcPath 的注释。
   */
  private inlineMathImg(latex: string, size: number): string {
    // MathJax 已关闭（设置 → 引擎管理）→ 不再出图：正文回落线性化文本
    //（即使缓存里还有旧图也不显示——"关闭后无法渲染"的语义必须一致）
    if (EngineRegistry.isOff('mathjax', this.engineOffList)) {
      return '';
    }
    const key: string = ChartCache.inlineKey(latex, this.dark, size);
    if (this.brokenCharts.indexOf(key) >= 0 || this.inlineBroken.indexOf(key) >= 0) {
      return '';
    }
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return '';
    }
    return ChartCache.srcPath(c as common.UIAbilityContext, key);
  }

  /**
   * 本块的卡片底色（不透明 codeBlockBg；**参与缓存键 + 回落 Web 页面底色**）。
   *
   * ⚠️ **回落 Web 的页面底色必须不透明**：
   * 透明 Web 表面被系统合成时颜色不可控——卡片回落 Web 不传 cardBg 时页面透明，
   * 「一镜到底」退出时系统对卡片做 geometryTransition 快照，透明区域在真机上
   * 被合成成**垃圾色（用户实测：放大后退出卡片发红）**；与"快照透明合成成黑"
   * 同一 bug 族。显示用 Web 一律烘焙底色（快照/缓存链路早已如此）。
   */
  private cardBgKey(): string {
    return withAlpha(this.palette.codeBlockBg, 'FF');
  }

  /** 块级图的缓存键（v4 起含底色——五档主题深浅孪生款底色不同，必须区分，
   *  否则换深色主题会复用别主题烘焙的图 = "深色下背景发红/发绿"）。 */
  private blockKeyOf(mode: string): string {
    return ChartCache.keyFor(mode, this.block.code, this.dark, this.cardBgKey());
  }

  /** 块级图缓存的**逻辑尺寸**（'w|h'，css px = vp；无记录返回空串）。 */
  private blockDimOf(mode: string): string {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return '';
    }
    return ChartCache.dimOf(c as common.UIAbilityContext, this.blockKeyOf(mode));
  }

  /** 图表/公式块缓存图源（同 inlineMathImg：必须 file:// 前缀给 Image 用）。 */
  private chartImagePath(mode: string): string {
    const key: string = this.blockKeyOf(mode);
    if (this.brokenCharts.indexOf(key) >= 0) {
      return '';
    }
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return '';
    }
    return ChartCache.srcPath(c as common.UIAbilityContext, key);
  }

  /**
   * 块级缓存图展示——**按类型分策略**：
   *   · 公式（katex）：**自然尺寸 + 横向滚动**（文字必须 1:1 可读——用户要求
   *     "不限制大小"；有 .dim 逻辑尺寸时按自然尺寸，无则满宽 Contain）；
   *   · 图表（mermaid/echarts/…）：**缩放适配卡片宽**（旧行为）——类图等大尺寸图
   *     一律缩到完整可见，绝不按自然尺寸放大裁切（用户实测类图"被放的很大、
   *     显示不完整"）。
   */
  @Builder
  blockImage(mode: string) {
    if (mode === 'katex') {
    Scroll() {
      Image(this.chartImagePath(mode))
        .objectFit(ImageFit.Contain)
        .width(this.blockImgW(mode))
        .height(this.blockImgH(mode))
        .onError(() => {
          this.markChartBroken(mode);
        })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    // ⚠️ **Scroll 必须自裁圆角**：自然尺寸的公式图比可视区宽时，图片自身的
    // 圆角在视口外——右缘被 Scroll 的直角边裁出来 = "右边圆角变直角"（用户实测）。
    .borderRadius(HwRadius.inner)
    .clip(true)
    .width('100%')
  } else {
      Image(this.chartImagePath(mode))
        .objectFit(ImageFit.Contain)
        .borderRadius(HwRadius.inner)
        .width('100%')
        .onError(() => {
          this.markChartBroken(mode);
        })
    }
  }

  /** 块级图自然宽（vp；无尺寸记录回退满宽） */
  private blockImgW(mode: string): Length {
    const dim: string = this.blockDimOf(mode);
    const bar: number = dim.indexOf('|');
    if (bar <= 0) {
      return '100%';
    }
    const w: number = Number(dim.substring(0, bar));
    return w > 0 ? w : '100%';
  }

  /** 块级图自然高（vp；无尺寸记录回退自适应） */
  private blockImgH(mode: string): Length {
    const dim: string = this.blockDimOf(mode);
    const bar: number = dim.indexOf('|');
    if (bar <= 0) {
      return 'auto';
    }
    const h: number = Number(dim.substring(bar + 1));
    return h > 0 ? h : 'auto';
  }

  /** 行内公式图加载失败：记入坏缓存 → 回落线性化文本（避免永久空白）。 */
  private markInlineBroken(latex: string, size: number): void {
    const key: string = ChartCache.inlineKey(latex, this.dark, size);
    if (this.inlineBroken.indexOf(key) < 0) {
      this.inlineBroken = this.inlineBroken.concat([key]);
    }
  }

  // ── 公式操作菜单（点击公式图 / 未就绪文本时打开）──
  //
  // 公式图片没有文字选区，批注系统需要「块 id + 渲染文本区间」——直接复用
  // piece 的 start/end（buildPieces 已带）落注；渲染侧由 ContainerSpan 把
  // 荧光笔底纹画在图片背后（透明底 PNG 透出底纹）。

  @State mathMenuOn: boolean = false;
  /** 窗口宽（px，AppStorage 广播）：半模态的平板竖屏收半判断用 */
  @StorageProp('windowWpx') winWpx: number = 0;
  private mathMenuStart: number = -1;
  private mathMenuEnd: number = -1;
  private mathMenuText: string = '';

  private openMathMenu(piece: MdPiece): void {
    this.mathMenuText = piece.text;
    this.mathMenuStart = piece.start;
    this.mathMenuEnd = piece.end;
    this.mathMenuOn = true;
  }

  /** 落注：用公式自身的字符区间，走批注系统统一入口（annotateHandler）。 */
  private emitMathAnnotation(action: string, color: number): void {
    const s: number = this.mathMenuStart;
    const e: number = this.mathMenuEnd;
    const text: string = this.mathMenuText;
    this.mathMenuOn = false;
    if (s < 0 || e <= s || text.length === 0) {
      this.toast('该位置不支持此操作');
      return;
    }
    this.annotateHandler(action, this.block.id, s, e, text, color);
  }

  @Builder
  mathMenuAction(label: string, onTap: () => void) {
    Text(label)
      .fontSize(HwType.caption + 1)
      .fontColor(this.palette.textPrimary)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .borderRadius(15)
      .backgroundColor(this.palette.quoteBg)
      .onClick(() => {
        onTap();
      })
  }

  /** 公式操作菜单（半模态：荧光笔色板 + 批注/波浪线/清除 + 学习卡/放大/发送AI/复制）。 */
  @Builder
  mathMenuSheet() {
    Column({ space: HwSpace.sm }) {
      Text(this.mathMenuText)
        .fontSize(HwType.caption)
        .fontColor(this.palette.textTertiary)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Row({ space: HwSpace.xs }) {
        ForEach(ANNOTATION_COLORS, (item: AnnotationColor, index: number) => {
          Column()
            .width(26)
            .height(26)
            .borderRadius(13)
            .backgroundColor(item.light)
            .border({ width: 1, color: '#33000000' })
            .onClick(() => {
              this.emitMathAnnotation('highlight', index);
            })
        }, (item: AnnotationColor, index: number) => 'ms' + index)
        Text('荧光笔')
          .fontSize(HwType.caption)
          .fontColor(this.palette.textTertiary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: HwSpace.xs }) {
        this.mathMenuAction('批注', (): void => { this.emitMathAnnotation('note', -1); })
        this.mathMenuAction('波浪线', (): void => { this.emitMathAnnotation('wavy', 0); })
        this.mathMenuAction('清除', (): void => { this.emitMathAnnotation('remove', -1); })
      }
      .width('100%')

      Row({ space: HwSpace.xs }) {
        // **学习卡**（用户要求：渲染出来的公式也要能进背诵系统）——走与文字
        // 长按选择同一套 'studycard' 流程（实色底高亮落在公式图片背后 + 必填内容）；
        // 卡面由 MathFormulaText 渲染公式。AI 气泡里该回调未接线（默认空实现，无副作用）。
        this.mathMenuAction('学习卡', (): void => {
          this.emitMathAnnotation('studycard', -1);
        })
        // 「放大查看」走 KaTeX 引擎（render/katex.html）——该引擎关闭时不出现此动作
        if (!EngineRegistry.isOff('katex', this.engineOffList)) {
          this.mathMenuAction('放大查看', (): void => {
            const t: string = this.mathMenuText;
            this.mathMenuOn = false;
            this.enlargeHandler('katex', t, 'inline_math', '');
          })
        }
        this.mathMenuAction('发送AI', (): void => {
          const t: string = this.mathMenuText;
          this.mathMenuOn = false;
          this.aiAskHandler(t);
        })
        this.mathMenuAction('复制源码', (): void => {
          const t: string = this.mathMenuText;
          this.mathMenuOn = false;
          this.copyText(t, '公式源码已复制');
        })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 半模态内容区自带贴边：显式给内边距
    .padding(HwSpace.md)
  }

  /**
   * 行内公式图的**逻辑尺寸**（'w|h'；无记录返回空串）。
   *
   * ⚠️ PNG 像素是"逻辑尺寸 × 屏幕密度"的高清图（保清晰度），而 ImageSpan
   * 对"图片像素"的默认换算不可依赖（实测像素被 1:1 当 vp → 图放大 density
   * 倍——用户实测"公式渲染放大这么大"）。显示端显式把宽高设为逻辑尺寸
   * （vp），尺寸精确、像素仍高清。
   */
  private inlineDimOf(latex: string, size: number): string {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return '';
    }
    return ChartCache.dimOf(c as common.UIAbilityContext,
      ChartCache.inlineKey(latex, this.dark, size));
  }

  /** ImageSpan 显式宽（vp）；无尺寸记录回退 'auto'（自然尺寸）。 */
  private inlineMathW(latex: string, size: number): Length {
    const dim: string = this.inlineDimOf(latex, size);
    const bar: number = dim.indexOf('|');
    if (bar <= 0) {
      return 'auto';
    }
    const w: number = Number(dim.substring(0, bar));
    return w > 0 ? w : 'auto';
  }

  /** ImageSpan 显式高（vp）；无尺寸记录回退 'auto'。 */
  private inlineMathH(latex: string, size: number): Length {
    const dim: string = this.inlineDimOf(latex, size);
    const bar: number = dim.indexOf('|');
    if (bar <= 0) {
      return 'auto';
    }
    const h: number = Number(dim.substring(bar + 1));
    return h > 0 ? h : 'auto';
  }

  /** Image 加载失败：把该缓存 key 标记为坏，触发回落 DiagramWeb。 */
  private markChartBroken(mode: string): void {
    const key: string = this.blockKeyOf(mode);
    if (this.brokenCharts.indexOf(key) < 0) {
      this.brokenCharts = this.brokenCharts.concat([key]);
    }
  }

  // ── 引擎关闭兜底（设置 → 引擎管理）──
  //
  // 关掉某个引擎后，对应的图表 / 公式块**不再渲染**（用户要求：关闭后无法渲染），
  // 统一退化成"源码卡"：保留可读可复制的原文 + 指明去哪里重新开启。
  // 比留一块空白礼貌，也比继续显示旧缓存图诚实（缓存图会让人以为引擎还在工作）。

  /** 本块渲染所依赖的引擎 id（公式块 → katex；图表块 → 语言映射；html → 空串）。 */
  private blockEngineId(): string {
    if (this.block.kind === MdBlockKind.Math) {
      return 'katex';
    }
    return EngineRegistry.langId(this.block.lang);
  }

  /** 本块的引擎是否已在设置里关闭（空 id 恒 false：html 块不依赖第三方引擎）。 */
  private blockEngineOff(): boolean {
    return EngineRegistry.isOff(this.blockEngineId(), this.engineOffList);
  }

  /** 引擎关闭态的源码卡：引擎名 + 状态 + 可复制源码 + 重新开启提示。 */
  @Builder
  engineOffCard() {
    Column() {
      ImmersiveCard({
        cardRadius: HwRadius.inner,
        cardPadding: 0,
        cardMaterialShadow: false,
        cardBackground: this.palette.codeBlockBg,
        palette: this.palette
      }) {
        Column() {
          Row({ space: HwSpace.xs }) {
            Text(EngineRegistry.nameOf(this.blockEngineId()))
              .fontSize(HwType.caption)
              .fontColor(this.palette.textTertiary)
            Text('引擎已关闭 · 仅显示源码')
              .fontSize(HwType.caption)
              .fontColor(this.palette.accent)
            Blank()
            ImmersiveIconButton({
              buttonSize: 28,
              buttonMaterialShadow: false,
              palette: this.palette,
              buttonOnTap: () => {
                this.copyCode();
              }
            }) {
              if (this.copied) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(14)
                  .fontColor([this.palette.accent])
              } else {
                SymbolGlyph($r('sys.symbol.square_on_square_fill'))
                  .fontSize(14)
                  .fontColor([this.palette.textTertiary])
              }
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: HwSpace.md, right: HwSpace.xs, top: HwSpace.xs, bottom: 0 })

          Scroll() {
            Text(this.block.code)
              .fontSize(this.bodySize * HwType.codeScale)
              .fontColor(this.palette.textPrimary)
              .lineHeight(this.bodySize * HwType.codeScale * 1.6)
              .width('100%')
              .textAlign(TextAlign.Start)
              .copyOption(CopyOptions.LocalDevice)
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Auto)
          .width('100%')
          .height(codeBlockHeight(this.block.codeLines.length, this.bodySize))
          .padding({ left: HwSpace.md, right: HwSpace.md, top: HwSpace.xs, bottom: HwSpace.sm })

          Text('可在「设置 → 引擎管理」中重新开启')
            .fontSize(HwType.caption - 1)
            .fontColor(this.palette.textTertiary)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ bottom: HwSpace.sm })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .margin({ top: HwSpace.sm, bottom: HwSpace.sm })
  }

  /**
   * **卡片状态栏**（用户要求：所有卡片用代码块同款——操作按钮放顶部，不遮内容）：
   * 左侧类型徽标 + 右侧（源码切换）+ 放大按钮。
   */
  @Builder
  cardHeader(label: string, mode: string, payload: string, geoKey: string, title: string, showCodeToggle: boolean) {
    Row() {
      Text(label)
        .fontSize(HwType.caption - 1)
        .fontColor(this.palette.textTertiary)
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .borderRadius(HwRadius.pill)
        .backgroundColor(this.palette.quoteBg)
      Blank()
      if (showCodeToggle) {
        ImmersiveIconButton({
          buttonSize: 28,
          buttonMaterialShadow: false,
          palette: this.palette,
          buttonOnTap: () => {
            this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
              this.chartShowCode = !this.chartShowCode;
            });
          }
        }) {
          SymbolGlyph($r('sys.symbol.text_alignleft'))
            .fontSize(13)
            .fontColor([this.chartShowCode ? this.palette.accent : this.palette.textTertiary])
        }
        Column()
          .width(HwSpace.xs)
      }
      ImmersiveIconButton({
        buttonSize: 28,
        buttonMaterialShadow: false,
        palette: this.palette,
        buttonOnTap: () => {
          this.enlargeHandler(mode, payload, geoKey, title);
        }
      }) {
        SymbolGlyph($r('sys.symbol.arrow_up_left_and_arrow_down_right'))
          .fontSize(14)
          .fontColor([this.palette.textTertiary])
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: HwSpace.md, right: HwSpace.xs, top: HwSpace.xs, bottom: 0 })
  }

  @Builder
  mathView() {
    Column() {
      if (this.chartImagePath('katex').length > 0) {
        ImmersiveCard({
          cardRadius: HwRadius.inner,
          cardPadding: 0,
          cardMaterialShadow: false,
          cardBackground: this.palette.codeBlockBg,
          palette: this.palette
        }) {
          Column() {
            this.cardHeader('公式', 'katex', this.block.code, 'mdchart_' + this.block.id, '', false)
            // 超宽公式：按自然尺寸 + 横向滚动展示（用户要求），不再压扁
            this.blockImage('katex')
          }
          .width('100%')
        }
      } else {
        ImmersiveCard({
          cardRadius: HwRadius.inner,
          cardPadding: 0,
          cardMaterialShadow: false,
          cardBackground: this.palette.codeBlockBg,
          palette: this.palette
        }) {
          Column() {
            this.cardHeader('公式', 'katex', this.block.code, 'mdchart_' + this.block.id, '', false)
            DiagramWeb({ mode: 'katex', payload: this.block.code, dark: this.dark, cardBg: this.cardBgKey(), onWebTouch: (down: boolean) => { this.webTouchHandler(down); } })
          }
          .width('100%')
        }
      }
    }
    .width('100%')
    .geometryTransition('mdchart_' + this.block.id, { follow: true })
    .margin({ top: HwSpace.sm, bottom: HwSpace.sm })
  }
  @Builder
  chartView() {
    Column() {
      // **脑图专用实时卡片**（用户拍板）：固定纵横比画布 + 自然尺寸渲染 +
      // markmap 自带拖拽/缩放（卡片内即可浏览整图）；无回传、无截图、无时序问题。
      if (this.block.lang.toLowerCase() === 'markmap' && !this.chartShowCode) {
        ImmersiveCard({
          cardRadius: HwRadius.inner,
          cardPadding: 0,
          cardMaterialShadow: false,
          cardBackground: this.palette.codeBlockBg,
          palette: this.palette
        }) {
          Column() {
            this.cardHeader(this.chartTitle(), 'markmap', this.block.code,
              'mdchart_' + this.block.id, this.chartTitle(), true)
            Web({ src: $rawfile('render/markmap-card.html'), controller: this.mmCardCtrl })
              .width('100%')
              .aspectRatio(0.82)
              .onPageEnd(() => {
                try {
                  this.mmCardCtrl.runJavaScript('window.renderPayload(' + JSON.stringify({
                    src: this.block.code, dark: this.dark, fit: false, bg: this.cardBgKey()
                  }) + ');');
                } catch (err) {
                  // 注入失败：页面保持空白，不影响正文
                }
              })
          }
          .width('100%')
        }
      } else if (this.chartImagePath(this.block.lang.toLowerCase()).length > 0 && !this.chartShowCode) {
        ImmersiveCard({
          cardRadius: HwRadius.inner,
          cardPadding: 0,
          cardMaterialShadow: false,
          cardBackground: this.palette.codeBlockBg,
          palette: this.palette
        }) {
          Column() {
            this.cardHeader(this.chartTitle(), this.block.lang.toLowerCase(), this.block.code,
              'mdchart_' + this.block.id, this.chartTitle(), true)
            this.blockImage(this.block.lang.toLowerCase())
          }
          .width('100%')
        }
      } else {
        ImmersiveCard({
          cardRadius: HwRadius.inner,
          cardPadding: 0,
          cardMaterialShadow: false,
          cardBackground: this.palette.codeBlockBg,
          palette: this.palette
        }) {
          Column() {
            this.cardHeader(this.chartTitle(), this.block.lang.toLowerCase(), this.block.code,
              'mdchart_' + this.block.id, this.chartTitle(), true)
            Stack({ alignContent: Alignment.TopEnd }) {
              Column() {
                if (this.chartShowCode) {
                  Scroll() {
                    Text(this.block.code)
                      .fontSize(this.bodySize * HwType.codeScale)
                      .fontColor(this.palette.textPrimary)
                      .lineHeight(this.bodySize * HwType.codeScale * 1.6)
                      .width('100%')
                      .textAlign(TextAlign.Start)
                  }
                  .scrollable(ScrollDirection.Vertical)
                  .scrollBar(BarState.Auto)
                  .width('100%')
                  .height(codeBlockHeight(this.block.codeLines.length, this.bodySize))
                  .padding({ left: HwSpace.md, right: HwSpace.md, top: HwSpace.sm, bottom: HwSpace.sm })
                } else if (this.block.lang.toLowerCase() === 'markmap') {
                  DiagramWeb({ mode: 'markmap', payload: this.block.code, dark: this.dark, cardBg: this.cardBgKey(), onWebTouch: (down: boolean) => { this.webTouchHandler(down); } })
                } else if (this.block.lang.toLowerCase() === 'mermaid') {
                  DiagramWeb({ mode: 'mermaid', payload: this.block.code, dark: this.dark, cardBg: this.cardBgKey(), onWebTouch: (down: boolean) => { this.webTouchHandler(down); } })
                } else if (this.block.lang.toLowerCase() === 'echarts') {
                  DiagramWeb({ mode: 'echarts', payload: this.block.code, dark: this.dark, cardBg: this.cardBgKey(), onWebTouch: (down: boolean) => { this.webTouchHandler(down); } })
                } else if (this.block.lang.toLowerCase() === 'abc') {
                  DiagramWeb({ mode: 'abc', payload: this.block.code, dark: this.dark, cardBg: this.cardBgKey(), onWebTouch: (down: boolean) => { this.webTouchHandler(down); } })
                } else if (this.block.lang.toLowerCase() === 'graphviz') {
                  DiagramWeb({ mode: 'graphviz', payload: this.block.code, dark: this.dark, cardBg: this.cardBgKey(), onWebTouch: (down: boolean) => { this.webTouchHandler(down); } })
                } else if (this.block.lang.toLowerCase() === 'flowchart') {
                  DiagramWeb({ mode: 'flowchart', payload: this.block.code, dark: this.dark, cardBg: this.cardBgKey(), onWebTouch: (down: boolean) => { this.webTouchHandler(down); } })
                } else if (this.block.lang.toLowerCase() === 'html') {
                  DiagramWeb({ mode: 'html', payload: this.block.code, dark: this.dark, cardBg: this.cardBgKey(), onWebTouch: (down: boolean) => { this.webTouchHandler(down); } })
                } else {
                  this.codeView()
                }
              }
              .width('100%')
            }
            .width('100%')
          }
          .width('100%')
        }
      }
    }
    .width('100%')
    .geometryTransition('mdchart_' + this.block.id, { follow: true })
    .margin({ top: HwSpace.sm, bottom: HwSpace.sm })
  }
  // ── 折叠细节块（<details><summary>）──
  @State detailsOpen: boolean = false;

  /**
   * 图表块（mermaid / echarts / markmap / flowchart / graphviz / abc / html）是否
   * 以「源码」形态展示。**预览 ↔ 查看代码**切换（用户要求）：核对写法时不必离开阅读页。
   */
  @State chartShowCode: boolean = false;

  @Builder
  detailsView() {
    Column({ space: HwSpace.xs }) {
      Row({ space: HwSpace.xs }) {
        SymbolGlyph(this.detailsOpen ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
          .fontSize(13)
          .fontColor([this.palette.textTertiary])
        Text() {
          ForEach(MdViewUtil.toPieces(this.block.inlines, this.dark), (piece: MdPiece) => {
            Span(piece.text)
              .fontSize(this.bodySize)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.palette.textPrimary)
          }, (piece: MdPiece, index: number) => 'd' + index + '_' + piece.text.length)
        }
        .fontSize(this.bodySize)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 8, bottom: 8 })
      .onClick(() => {
        // 展开收起包 animateTo：内容出现 / 消失才有过渡动画
        this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
          this.detailsOpen = !this.detailsOpen;
        });
      })

      if (this.detailsOpen && this.block.code.length > 0) {
        Text(this.block.code)
          .fontSize(this.bodySize)
          .fontColor(this.palette.textSecondary)
          .lineHeight(this.bodySize * this.lineMul)
          .width('100%')
          .padding({ left: HwSpace.sm, right: HwSpace.sm, bottom: HwSpace.sm })
          // 出入场：展开时淡入下落，收起时淡出上移
          .transition({ opacity: 0, translate: { y: -6 } })
      }
    }
    .width('100%')
    .borderRadius(HwRadius.inner)
    .backgroundColor(this.palette.quoteBg)
    .margin({ top: HwSpace.xs, bottom: HwSpace.xs })
  }

  // ────────────────────── 根 ──────────────────────

  build() {
    Column() {
      if (this.block.kind === MdBlockKind.Heading) {
        this.headingView()
      } else if (this.block.kind === MdBlockKind.Code) {
        this.codeView()
      } else if (this.block.kind === MdBlockKind.Quote) {
        this.quoteView()
      } else if (this.block.kind === MdBlockKind.Callout) {
        this.calloutView()
      } else if (this.block.kind === MdBlockKind.Table) {
        this.tableView()
      } else if (this.block.kind === MdBlockKind.Divider) {
        this.dividerView()
      } else if (this.block.kind === MdBlockKind.Math) {
        // 引擎被关闭（设置 → 引擎管理）→ 源码兜底卡；开启时走正常渲染
        if (this.blockEngineOff()) {
          this.engineOffCard()
        } else {
          this.mathView()
        }
      } else if (this.block.kind === MdBlockKind.Chart) {
        if (this.blockEngineOff()) {
          this.engineOffCard()
        } else {
          this.chartView()
        }
      } else if (this.block.kind === MdBlockKind.Details) {
        this.detailsView()
      } else if (this.block.kind === MdBlockKind.Paragraph && this.standaloneImage() !== null) {
        this.imageView()
      } else if (this.block.footnoteNo > 0) {
        this.footnoteView()
      } else if (this.block.kind === MdBlockKind.Paragraph) {
        // 普通段落必须走 paragraphView：
        //   ① 它有独立的首行缩进语义（indentOn），
        //   ② 掉进 listItemView 会在段首多画一个列表圆点、还带上列表内边距。
        // 之前这里漏了这条分支，paragraphView 一直是死代码 → 首行缩进整条链路失效。
        this.paragraphView()
      } else {
        this.listItemView()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: this.blockBottom() })
    // 量出本块宽度：批注菜单的宽度上限以它为基准（+ 阅读页左右边距）。
    // 菜单超过这条线就在内部横向滚动，右侧不会再被屏幕边缘裁切。
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const w: Length = newValue.width;
      if (typeof w === 'number' && w > 0) {
        // **容差 24vp**：侧边栏展开/收起动画期间正文宽度逐帧微变——逐帧写
        // menuMaxW 会让批注菜单约束反复重建（正文抽搐闪烁，用户实测）。
        // 动画中间态全部忽略；动画结束的终值差远超容差、会更新一次。
        const next: number = w + 48;
        if (Math.abs(next - this.menuMaxW) > 24) {
          this.menuMaxW = next;
        }
      }
    })
    // 公式操作菜单（点公式图 / 未就绪文本打开）：半模态走项目唯一实现
    // modalSheetOptions——内容自适应高度（小面板），手机形态
    .bindSheet(this.mathMenuOn, this.mathMenuSheet(), modalSheetOptions({
      title: '公式',
      subtitle: '',
      surface: this.palette.surface,
      phoneLayout: true,
      fitContent: true,
      screenWidth: this.winWpx > 0 ? this.getUIContext().px2vp(this.winWpx) : 361,
      onDismiss: (): void => {
        this.mathMenuOn = false;
      }
    }))
  }

  /** 块与块之间的距离随「段落间距」设置缩放；标题与分割线自带上边距，不再加。 */
  private blockBottom(): number {
    if (this.block.kind === MdBlockKind.Divider) {
      return 0;
    }
    if (this.block.kind === MdBlockKind.Heading) {
      return 0;
    }
    const base: number = HwSpace.sm;
    return Math.round(base * this.paraSpaceMul * 10) / 10;
  }

  /** 复制代码到系统剪贴板，并给出轻提示。 */
  private copyCode(): void {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.block.code);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.copied = true;
        this.toast('代码已复制');
        setTimeout(() => {
          this.copied = false;
        }, 1600);
      }).catch((err: BusinessError) => {
        this.toast('复制失败：' + err.message);
      });
    } catch (err) {
      this.toast('复制失败');
    }
  }

  /** 复制任意文本。 */
  private copyText(text: string, hint: string): void {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      // **改成同步写入**：原来用异步 setData().then() 弹提示，在部分设备上会出现
      // promise 与剪贴板实际写入不同步的观感 ——「提示已复制，粘出来却没有内容」。
      // 同步 API 一次性拿到成败，成功才提示，失败给可读原因（不再有假成功提示）。
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.toast(hint);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      const msg: string = (e.message !== undefined && e.message !== null) ? e.message : '未知错误';
      this.toast('复制失败：' + msg);
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1500 });
    } catch (err) {
      // 提示失败不影响主流程
    }
  }
}
