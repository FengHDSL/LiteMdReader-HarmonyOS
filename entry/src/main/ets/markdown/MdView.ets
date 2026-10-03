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
  tableColumnWidth
} from '../theme/DesignTokens';
import { ImmersiveCard, ImmersiveCardLayer, ImmersiveChip, ImmersiveIconButton } from '../material/ImmersiveCard';
import { getImmersiveMaterial } from '../material/SystemMaterial';
import { DocStore } from '../service/DocStore';
import { MathLite, MathSeg } from './MathLite';
import { FlowChartView } from './FlowChart';
import { DiagramWeb } from '../components/DiagramWeb';
import { ChartCache } from '../service/ChartCache';
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
      + (piece.dblLine ? '_d' : '') + (piece.searchHit ? '_s' : '');
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
          bold: item.bold,
          italic: item.italic,
          strike: item.strike,
          code: item.code,
          highlight: highlight,
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
  @State copied: boolean = false;
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

  /** 任务列表勾选切换（点勾选框）：页面负责改写原文并保存/重载。 */
  taskToggleHandler: (blockId: string) => void = () => {
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
    .margin({ top: 4, right: 4 })
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
   * 正文的主力行内渲染：**可长按选择、可复制、可加荧光笔与文字批注**。
   *
   * 三个属性缺一不可，否则长按完全没有反应：
   *   · `copyOption(LocalDevice)` —— 不开的话 Text 根本不进入选择态；
   *   · `onTextSelectionChange`   —— 拿到选区偏移，批注要用它定位；
   *   · `bindSelectionMenu`       —— 用自定义菜单替换系统菜单，把「荧光笔」放进去。
   */
  @Builder
  richTextSel(size: number, baseColor: string, lineMul: number, align: TextAlign, firstIndent: boolean) {
    if (this.systemSelectId === this.block.id) {
      // ── **系统选择模式**（用户要求）：不用自定义批注菜单，恢复系统原生长按菜单 ——
      // 复制 / 全选 / 翻译 / 唤起小艺等系统能力直接可用。点一下正文退出（见 Span onClick）。
      Text(this.block.plain) {
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
      ForEach(this.pieces(), (piece: MdPiece) => {
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
            } else {
              // 外部链接不做跳转（需要 want + 浏览器能力），点击复制地址并提示
              this.copyText(piece.href, '链接已复制');
            }
          })
      }, (piece: MdPiece, index: number) => MdViewUtil.pieceKey(piece, index))
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
        Span(piece.text)
          .fontSize(MdViewUtil.pieceSize(piece, size))
          .fontColor(MdViewUtil.pieceColor(piece, baseColor, this.palette))
          .fontWeight(piece.bold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(piece.italic ? FontStyle.Italic : FontStyle.Normal)
          .decoration(MdViewUtil.pieceDecoration(piece, this.palette, this.waveThickness))
          .textBackgroundStyle(MdViewUtil.pieceBackground(piece, this.palette, this.hlOpacity))
          .baselineOffset(MdViewUtil.pieceBaseline(piece, size))
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
          Text(this.block.lang.length > 0 ? this.block.lang : 'text')
            .fontSize(HwType.caption)
            .fontColor(this.palette.textTertiary)
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
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .padding({ left: HwSpace.md, right: HwSpace.xs, top: HwSpace.xs, bottom: 0 })

        Scroll() {
          Column() {
            ForEach(this.tokensForCode(), (tokens: CodeToken[], lineIndex: number) => {
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
              .width('100%')
            }, (tokens: CodeToken[], lineIndex: number) => 'c' + lineIndex + '_' + tokens.length)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: HwSpace.md, right: HwSpace.md, top: HwSpace.xs, bottom: HwSpace.md })
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Auto)
        .width('100%')
        .height(codeBlockHeight(this.block.codeLines.length, this.bodySize))
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
  private chartImagePath(mode: string): string {
    const key: string = ChartCache.keyFor(mode, this.block.code, this.dark);
    if (this.brokenCharts.indexOf(key) >= 0) {
      return '';
    }
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return '';
    }
    return ChartCache.path(c as common.UIAbilityContext, key);
  }

  /** Image 加载失败：把该缓存 key 标记为坏，触发回落 DiagramWeb。 */
  private markChartBroken(mode: string): void {
    const key: string = ChartCache.keyFor(mode, this.block.code, this.dark);
    if (this.brokenCharts.indexOf(key) < 0) {
      this.brokenCharts = this.brokenCharts.concat([key]);
    }
  }

  @Builder
  mathView() {
    // 块级公式：**优先用后台预渲染的缓存图**（打开文件时后台池已转成图片，
    // 无需滑到位置再等 Web 加载——用户要求）；无缓存才回落 DiagramWeb 实时渲染。
    // 包 ImmersiveCard 让卡片本体走沉浸光感承载层；
    // **外边距必须挂在外面这层 Column 上**——自定义组件 + 尾随闭包之后不能再链式调属性。
    Column() {
    if (this.chartImagePath('katex').length > 0) {
      Column() {
        Image(this.chartImagePath('katex'))
          .width('100%')
          .objectFit(ImageFit.Contain)
          .borderRadius(HwRadius.inner)
          .onError(() => {
            this.markChartBroken('katex');
          })
      }
      .width('100%')
    } else {
    ImmersiveCard({
      cardRadius: HwRadius.inner,
      cardPadding: 0,
      cardMaterialShadow: false,
      cardBackground: this.palette.codeBlockBg,
      palette: this.palette
    }) {
      // alignContent: TopEnd —— 放大按钮钉在**右上角**。
      // 默认 Stack 是居中对齐，按钮会飘在卡片垂直中线上。
      Stack({ alignContent: Alignment.TopEnd }) {
        Column() {
          DiagramWeb({ mode: 'katex', payload: this.block.code, dark: this.dark, onWebTouch: (down: boolean) => { this.webTouchHandler(down); } })
        }
        .width('100%')

        Row() {
          Blank()
          this.enlargeButton('katex', this.block.code, 'mdchart_' + this.block.id, '')
        }
        .width('100%')
      }
      .width('100%')
    }
    }
    }
    .width('100%')
    // **一镜到底**：与放大浮层的大画布共享同一 id，点放大 / 关闭时卡片 ⇄ 全屏互相形变
    .geometryTransition('mdchart_' + this.block.id, { follow: true })
    .margin({ top: HwSpace.sm, bottom: HwSpace.sm })
  }

  @Builder
  chartView() {
    // 图表卡片同样包 ImmersiveCard，按钮钉右上角（外边距挂外层 Column）
    // **优先用后台预渲染的缓存图**（同公式块）；无缓存才回落 DiagramWeb。
    Column() {
    if (this.chartImagePath(this.block.lang.toLowerCase()).length > 0) {
      Column() {
        Image(this.chartImagePath(this.block.lang.toLowerCase()))
          .width('100%')
          .objectFit(ImageFit.Contain)
          .borderRadius(HwRadius.inner)
          .onError(() => {
            this.markChartBroken(this.block.lang.toLowerCase());
          })
      }
      .width('100%')
    } else {
    ImmersiveCard({
      cardRadius: HwRadius.inner,
      cardPadding: 0,
      cardMaterialShadow: false,
      cardBackground: this.palette.codeBlockBg,
      palette: this.palette
    }) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        if (this.block.lang.toLowerCase() === 'markmap') {
          DiagramWeb({ mode: 'markmap', payload: this.block.code, dark: this.dark, onWebTouch: (down: boolean) => { this.webTouchHandler(down); } })
        } else if (this.block.lang.toLowerCase() === 'mermaid') {
          DiagramWeb({ mode: 'mermaid', payload: this.block.code, dark: this.dark, onWebTouch: (down: boolean) => { this.webTouchHandler(down); } })
        } else if (this.block.lang.toLowerCase() === 'echarts') {
          DiagramWeb({ mode: 'echarts', payload: this.block.code, dark: this.dark, onWebTouch: (down: boolean) => { this.webTouchHandler(down); } })
        } else if (this.block.lang.toLowerCase() === 'abc') {
          DiagramWeb({ mode: 'abc', payload: this.block.code, dark: this.dark, onWebTouch: (down: boolean) => { this.webTouchHandler(down); } })
        } else if (this.block.lang.toLowerCase() === 'graphviz') {
          DiagramWeb({ mode: 'graphviz', payload: this.block.code, dark: this.dark, onWebTouch: (down: boolean) => { this.webTouchHandler(down); } })
        } else if (this.block.lang.toLowerCase() === 'flowchart') {
          DiagramWeb({ mode: 'flowchart', payload: this.block.code, dark: this.dark, onWebTouch: (down: boolean) => { this.webTouchHandler(down); } })
        } else {
          // 未登记的图表语言：按代码块原样呈现
          this.codeView()
        }
      }
      .width('100%')

      Row() {
        Blank()
        this.enlargeButton(this.block.lang.toLowerCase(), this.block.code, 'mdchart_' + this.block.id, this.chartTitle())
      }
      .width('100%')
    }
    .width('100%')
    }
    }
    }
    .width('100%')
    // **一镜到底**：与放大浮层的大画布共享同一 id（同公式卡片）
    .geometryTransition('mdchart_' + this.block.id, { follow: true })
    .margin({ top: HwSpace.sm, bottom: HwSpace.sm })
  }

  // ── 折叠细节块（<details><summary>）──
  @State detailsOpen: boolean = false;

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
        this.mathView()
      } else if (this.block.kind === MdBlockKind.Chart) {
        this.chartView()
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
        this.menuMaxW = w + 48;
      }
    })
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
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.toast(hint);
      }).catch((err: BusinessError) => {
        this.toast('复制失败：' + err.message);
      });
    } catch (err) {
      this.toast('复制失败');
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
