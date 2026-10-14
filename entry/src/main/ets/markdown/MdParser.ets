/**
 * LiteMdReader · Markdown 解析器
 * ===============================
 *
 * 纯 ArkTS 实现，不依赖任何三方库（HarmonyOS SDK 26 并未内置 Markdown 组件，
 * 已通过检索 `component/` 目录确认——因此渲染必须自研）。
 *
 * 支持的语法：
 *   块级：ATX 标题（#…######）、Setext 标题（=== / ---）、围栏代码块（``` / ~~~，含语言）、
 *         **缩进代码块（4 空格 / Tab，老式写法）**、
 *         段落、引用（>，支持层级）、GFM 提示块（[!NOTE] 等五种）、
 *         无序 / 有序列表（**嵌套层级按内容列栈算，2/3/4 空格缩进都认**）、
 *         任务列表（- [ ] / - [x]）、
 *         GFM 表格（含列对齐）、分割线、GFM 脚注定义（[^label]: 内容）
 *   行内：粗体、斜体、粗斜体、删除线、行内代码、链接、图片、高亮（==…==）、
 *         脚注引用（[^label]）、反斜杠转义
 *
 * 数学公式：块级（$$…$$ / \[…\]）与行内（$…$ / \(…\)）**源码原样保留**，
 * 交给 KaTeX 完整渲染（块级结构段仅作预渲染完成前的线性化兜底）。
 *
 * 原生 HTML（行内）：`<kbd>` 按键帽、`<ruby>`+`<rt>` 注音、`<span style="color:…">`
 * / `<font color>` 彩色文字、`<u>`/`<ins>` 下划线、`<b>`/`<i>`/`<s>`/`<code>`/`<mark>`/
 * `<sub>`/`<sup>`/`<a href>`/`<img>`/`<br>` 都能渲染；不认识的成对标签**脱标签留内容**。
 * 只放行十六进制色值，`<script>`/`<style>` 整段丢弃——渲染层没有 CSS/JS 执行环境，
 * 放行等于把任意样式注入正文。
 *
 * 刻意不支持（v1 范围）：
 *   **块级原生 HTML**（`<table>` 合并单元格、`<div>`、内嵌 `<svg>` 等，按文本显示）、
 *   多文件文档。
 */

import { PlantumlBridge } from './PlantumlBridge';
import { ZenumlBridge } from './ZenumlBridge';
import {
  MdBlock,
  MdBlockKind,
  MdCalloutKind,
  MdHeading,
  MdInline,
  MdInlineKind,
  MdMetaItem,
  MdNote,
  MdParseResult,
  MdSrcRange,
  MdTableRow,
  MdTaskState,
  GroupCode
} from './MdTypes';
import { isEmojiCodeChar, lookupEmoji } from './Emoji';
import { MathLite } from './MathLite';

/** 匹配结果：尖括号自动链接 */
interface AutolinkHit {
  /** 吃掉的字符数（0 = 不是自动链接，交回行内 HTML 或普通文字） */
  len: number;
  text: string;
  href: string;
}

function missAutolink(): AutolinkHit {
  const r: AutolinkHit = { len: 0, text: '', href: '' };
  return r;
}

/** 匹配结果：HTML 字符实体 */
interface EntityHit {
  /** 吃掉的字符数（0 = 这里不是实体，按普通文字处理） */
  len: number;
  text: string;
}

function missEntity(): EntityHit {
  const r: EntityHit = { len: 0, text: '' };
  return r;
}

/** 匹配结果：标题 */
interface HeadingHit {
  hit: boolean;
  level: number;
  text: string;
  /** 显式锚点 `{#id}`；没有是空串 */
  id: string;
}

/** pandoc 属性块 `{#id .类名 key=value}` 的词法结果（hit=false = 这不是属性块，原文照旧） */
interface AttrTail {
  hit: boolean;
  id: string;
  classes: string[];
  attrs: string[];
}

function missHeading(): HeadingHit {
  const r: HeadingHit = { hit: false, level: 0, text: '', id: '' };
  return r;
}

/** 匹配结果：列表项 */
interface ListHit {
  hit: boolean;
  ordered: boolean;
  marker: string;
  text: string;
  /** 行首空格数（**原文事实**；嵌套层级由 parse 里的内容列栈算，不在这里猜） */
  spaces: number;
  task: number;
}

/** 匹配结果：脚注定义 */
interface NoteDefHit {
  hit: boolean;
  label: string;
  body: string;
}

/** 匹配结果：链接 / 图片 */
interface LinkHit {
  hit: boolean;
  label: string;
  href: string;
  end: number;
}

/** 统计结果 */
interface MdStat {
  charCount: number;
  wordCount: number;
  headingCount: number;
  codeBlockCount: number;
  tableCount: number;
}

function missList(): ListHit {
  const r: ListHit = { hit: false, ordered: false, marker: '', text: '', spaces: 0, task: MdTaskState.None };
  return r;
}

function missNote(): NoteDefHit {
  const r: NoteDefHit = { hit: false, label: '', body: '' };
  return r;
}

function missLink(): LinkHit {
  const r: LinkHit = { hit: false, label: '', href: '', end: 0 };
  return r;
}

/** 构造行内片段 */
export function inlineOf(kind: MdInlineKind, text: string, href: string, num: number,
                         bold: boolean, italic: boolean, strike: boolean, code: boolean): MdInline {
  const item: MdInline = {
    kind: kind,
    text: text,
    href: href,
    num: num,
    bold: bold,
    italic: italic,
    strike: strike,
    code: code
  };
  return item;
}

/** 块级元素工厂。集中在一处，保证每个字段都有明确初值。 */
class MdBlockFactory {
  static heading(level: number, text: string, seq: number, inlines: MdInline[], id: number): MdBlock {
    const b: MdBlock = {
      id: 'b' + id,
      kind: MdBlockKind.Heading,
      level: level,
      lang: '',
      code: '',
      codeLines: [],
      inlines: inlines,
      plain: text,
      indent: 0,
      ordered: false,
      marker: '',
      task: MdTaskState.None,
      rows: [],
      aligns: [],
      callout: MdCalloutKind.None,
      footnoteNo: 0,
      headingSeq: seq,
      srcLine: 0
    };
    return b;
  }

  static paragraph(text: string, inlines: MdInline[], id: number): MdBlock {
    const b: MdBlock = {
      id: 'b' + id,
      kind: MdBlockKind.Paragraph,
      level: 0,
      lang: '',
      code: '',
      codeLines: [],
      inlines: inlines,
      plain: text,
      indent: 0,
      ordered: false,
      marker: '',
      task: MdTaskState.None,
      rows: [],
      aligns: [],
      callout: MdCalloutKind.None,
      footnoteNo: 0,
      headingSeq: 0,
      srcLine: 0
    };
    return b;
  }

  static code(lang: string, lines: string[], id: number): MdBlock {
    const b: MdBlock = {
      id: 'b' + id,
      kind: MdBlockKind.Code,
      level: 0,
      lang: lang,
      code: lines.join('\n'),
      codeLines: lines,
      inlines: [],
      plain: lines.join('\n'),
      indent: 0,
      ordered: false,
      marker: '',
      task: MdTaskState.None,
      rows: [],
      aligns: [],
      callout: MdCalloutKind.None,
      footnoteNo: 0,
      headingSeq: 0,
      srcLine: 0
    };
    return b;
  }

  static quote(depth: number, text: string, inlines: MdInline[], id: number): MdBlock {
    const b: MdBlock = {
      id: 'b' + id,
      kind: MdBlockKind.Quote,
      level: 0,
      lang: '',
      code: '',
      codeLines: [],
      inlines: inlines,
      plain: text,
      indent: depth,
      ordered: false,
      marker: '',
      task: MdTaskState.None,
      rows: [],
      aligns: [],
      callout: MdCalloutKind.None,
      footnoteNo: 0,
      headingSeq: 0,
      srcLine: 0
    };
    return b;
  }

  static callout(kind: MdCalloutKind, text: string, inlines: MdInline[], id: number): MdBlock {
    const b: MdBlock = {
      id: 'b' + id,
      kind: MdBlockKind.Callout,
      level: 0,
      lang: '',
      code: '',
      codeLines: [],
      inlines: inlines,
      plain: text,
      indent: 0,
      ordered: false,
      marker: '',
      task: MdTaskState.None,
      rows: [],
      aligns: [],
      callout: kind,
      footnoteNo: 0,
      headingSeq: 0,
      srcLine: 0
    };
    return b;
  }

  static listItem(text: string, ordered: boolean, marker: string, task: number, indent: number,
                  inlines: MdInline[], id: number, srcLine: number): MdBlock {
    const b: MdBlock = {
      id: 'b' + id,
      kind: MdBlockKind.ListItem,
      level: 0,
      lang: '',
      code: '',
      codeLines: [],
      inlines: inlines,
      plain: text,
      indent: indent,
      ordered: ordered,
      marker: marker,
      task: task,
      rows: [],
      aligns: [],
      callout: MdCalloutKind.None,
      footnoteNo: 0,
      headingSeq: 0,
      srcLine: srcLine
    };
    return b;
  }

  static chart(lang: string, body: string[], id: number, srcLine: number): MdBlock {
    const b: MdBlock = {
      id: 'b' + id,
      kind: MdBlockKind.Chart,
      level: 0,
      lang: lang,
      code: body.join('\n'),
      codeLines: body,
      inlines: [],
      plain: body.join(' '),
      indent: 0,
      ordered: false,
      marker: '',
      task: MdTaskState.None,
      rows: [],
      aligns: [],
      callout: MdCalloutKind.None,
      footnoteNo: 0,
      headingSeq: 0,
      srcLine: srcLine
    };
    return b;
  }

  static math(latex: string, id: number, srcLine: number): MdBlock {
    // \tag{...} **保留原样**（用户要求：对齐与编号需与标准 LaTeX 一致）：
    // KaTeX display 模式原生支持 tag（编号贴容器右缘）——早期实现曾在解析层
    // 剥离 tag（当时窄卡片容器与公式重叠），现在块级容器为满宽，重叠不复存在，
    // 恢复编号显示。MathLite 线性化回退路径自会消费掉 tag 参数不着痕迹。
    const cleaned: string = latex.trim();
    const b: MdBlock = {
      id: 'b' + id,
      kind: MdBlockKind.Math,
      level: 0,
      lang: '',
      code: cleaned,
      codeLines: [],
      inlines: [],
      plain: cleaned,
      indent: 0,
      ordered: false,
      marker: '',
      task: MdTaskState.None,
      rows: [],
      aligns: [],
      callout: MdCalloutKind.None,
      footnoteNo: 0,
      headingSeq: 0,
      srcLine: srcLine
    };
    return b;
  }

  static codeGroup(codes: GroupCode[], id: number): MdBlock {
    const b: MdBlock = {
      id: 'b' + id,
      kind: MdBlockKind.CodeGroup,
      level: 0,
      lang: '',
      code: '',
      codeLines: [],
      inlines: [],
      plain: '',
      indent: 0,
      ordered: false,
      marker: '',
      task: MdTaskState.None,
      rows: [],
      aligns: [],
      footnoteNo: 0,
      headingSeq: 0,
      callout: MdCalloutKind.None,
      groupCodes: codes,
      srcLine: 0
    };
    return b;
  }

  static details(summary: string, body: string, id: number, srcLine: number): MdBlock {
    const b: MdBlock = {
      id: 'b' + id,
      kind: MdBlockKind.Details,
      level: 0,
      lang: '',
      code: body,
      codeLines: [],
      inlines: MdParser.parseInline(summary),
      plain: summary,
      indent: 0,
      ordered: false,
      marker: '',
      task: MdTaskState.None,
      rows: [],
      aligns: [],
      callout: MdCalloutKind.None,
      footnoteNo: 0,
      headingSeq: 0,
      srcLine: srcLine
    };
    return b;
  }

  static noteItem(text: string, no: number, inlines: MdInline[], id: number): MdBlock {
    const b: MdBlock = {
      id: 'b' + id,
      kind: MdBlockKind.ListItem,
      level: 0,
      lang: '',
      code: '',
      codeLines: [],
      inlines: inlines,
      plain: text,
      indent: 0,
      ordered: false,
      marker: '[' + no + ']',
      task: MdTaskState.None,
      rows: [],
      aligns: [],
      callout: MdCalloutKind.None,
      footnoteNo: no,
      headingSeq: 0,
      srcLine: 0
    };
    return b;
  }

  static tableRow(raw: string[], header: boolean): MdTableRow {
    const cells: MdInline[][] = [];
    for (let k = 0; k < raw.length; k++) {
      cells.push(MdParser.parseInline(raw[k]));
    }
    const row: MdTableRow = {
      raw: raw,
      cells: cells,
      header: header
    };
    return row;
  }

  static table(rows: MdTableRow[], aligns: number[], id: number): MdBlock {
    const b: MdBlock = {
      id: 'b' + id,
      kind: MdBlockKind.Table,
      level: 0,
      lang: '',
      code: '',
      codeLines: [],
      inlines: [],
      plain: '',
      indent: 0,
      ordered: false,
      marker: '',
      task: MdTaskState.None,
      rows: rows,
      aligns: aligns,
      callout: MdCalloutKind.None,
      footnoteNo: 0,
      headingSeq: 0,
      srcLine: 0
    };
    return b;
  }

  static divider(id: number): MdBlock {
    const b: MdBlock = {
      id: 'b' + id,
      kind: MdBlockKind.Divider,
      level: 0,
      lang: '',
      code: '',
      codeLines: [],
      inlines: [],
      plain: '',
      indent: 0,
      ordered: false,
      marker: '',
      task: MdTaskState.None,
      rows: [],
      aligns: [],
      callout: MdCalloutKind.None,
      footnoteNo: 0,
      headingSeq: 0,
      srcLine: 0
    };
    return b;
  }
}

function inlineOfPlain(text: string): MdInline {
  return inlineOf(MdInlineKind.Plain, text, '', 0, false, false, false, false);
}

/** 行内 HTML 的一次识别结果 */
interface HtmlHit {
  /** 吃掉的字符数；0 = 不是可识别的行内 HTML（原样留作文本） */
  consumed: number;
  /** 产出的片段（可以为空：注释与 <script> 这类整段丢弃） */
  items: MdInline[];
}

function missHtml(): HtmlHit {
  return { consumed: 0, items: [] } as HtmlHit;
}

export class MdParser {
  /** 链接引用表（[标识]: 地址），parse() 预收集、scan() 查询 */
  private static refLabels: string[] = [];
  private static refHrefs: string[] = [];
  /**
   * 本次 parse 的「kept 下标 → 原文行号」映射（见 parse 里的注释）。
   * 只在 parse 开头整体替换，块级行号一律经 `MdParser.orig()` 翻译后再落到块上。
   */
  private static lineMap: number[] = [];

  /** 把解析用的 kept 下标翻译成**原文行号**（越界时原样返回，不制造负行号）。 */
  private static orig(k: number): number {
    if (k < 0 || k >= MdParser.lineMap.length) {
      return k;
    }
    return MdParser.lineMap[k];
  }

  /** 查引用地址（标识忽略大小写）；未命中返回空串。 */
  private static lookupRef(id: string): string {
    const key: string = id.trim().toLowerCase();
    for (let k = 0; k < MdParser.refLabels.length; k++) {
      if (MdParser.refLabels[k].toLowerCase() === key) {
        return MdParser.refHrefs[k];
      }
    }
    return '';
  }

  /** 数一行里的 $ 个数（跨行公式合并的"未闭合"判定用）。 */
  private static countDollar(s: string): number {
    let n: number = 0;
    for (let k: number = 0; k < s.length; k++) {
      if (s.charAt(k) === '$') {
        n++;
      }
    }
    return n;
  }

  /**
   * 跨行行内公式合并（用户《LaTeX 渲染能力测试清单》第 4 类的矩阵写法）：
   *
   *   `- 圆括号：$` + 空行 + `\begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}$`
   *
   * 这种「行尾单个 $ + 空行 + 公式内容 + 行尾单个 $」的形态，常见渲染引擎
   * （Jupyter / CherryStudio 等）都按**跨行行内公式**处理；本解析器逐行工作，
   * 若不处理则该形态只能按源码文本显示（矩阵块整体判为"不支持"）。
   * 这里在预处理阶段把公式内容并回首行 —— 行内 $…$ 规则要求开 $ 后不能是
   * 空格，所以拼接不留空格：`- 圆括号：$\begin{pmatrix}…\end{pmatrix}$`
   * 随后被行内解析器正常识别为 MathInline。
   *
   * **行号安全**：合并后中间行与闭合行**置空**（而不是删除）——数组长度不变，
   * 原文行号映射（srcIndex / lineMap）与后续所有 srcLine 语义完全不受影响。
   *
   * 保守条件（宁可不合并，绝不误吞正文）：
   *   · 首行 / 闭合行都是「行尾单 $ 且该行 $ 数为**奇数**」——未闭合形态；
   *     完整单行公式 `$…$` 的 $ 数恒为偶数，绝不误并
   *   · 围栏代码块内的行一律跳过（教程里可能出现的 $ 示例不参与）
   *   · 首行到闭合行不超过 62 行
   *   · 公式内容 ≤ 800 字符、不含 $（避免与金额 / 其他公式歧义）、
   *     且含 \ 或 &（公式特征；纯散文直接放弃）
   */
  private static mergeCrossLineDollar(lines: string[]): void {
    let i: number = 0;
    let inFence: boolean = false;
    let fenceCh: string = '';
    while (i < lines.length) {
      const rawTrim: string = lines[i].trim();
      // 围栏代码块整段跳过（与主循环围栏检测同源近似，保守即可）
      if (inFence) {
        if (rawTrim.startsWith(fenceCh)) {
          inFence = false;
          fenceCh = '';
        }
        i++;
        continue;
      }
      if (rawTrim.startsWith('```') || rawTrim.startsWith('~~~')) {
        inFence = true;
        fenceCh = rawTrim.startsWith('~~~') ? '~~~' : '```';
        i++;
        continue;
      }
      const tail: string = lines[i].replace(/\s+$/, '');
      if (tail.length >= 2 && tail.endsWith('$') && !tail.endsWith('$$')
        && MdParser.countDollar(tail) % 2 === 1) {
        const probeEnd: number = Math.min(lines.length, i + 62);
        let j: number = i + 1;
        let found: number = -1;
        while (j < probeEnd) {
          const cj: string = lines[j].replace(/\s+$/, '');
          if (cj.endsWith('$') && !cj.endsWith('$$')
            && MdParser.countDollar(cj) % 2 === 1) {
            found = j;
            break;
          }
          j++;
        }
        if (found > i) {
          const parts: string[] = [];
          let total: number = 0;
          for (let k: number = i + 1; k < found; k++) {
            const t: string = lines[k].trim();
            if (t.length > 0) {
              parts.push(t);
              total += t.length;
            }
          }
          const closeRaw: string = lines[found].replace(/\s+$/, '');
          const closeBody: string = closeRaw.substring(0, closeRaw.length - 1).trim();
          if (closeBody.length > 0) {
            parts.push(closeBody);
            total += closeBody.length;
          }
          const content: string = parts.join(' ');
          const ok: boolean = content.length > 0 && total <= 800
            && content.indexOf('$') < 0
            && (content.indexOf('\\') >= 0 || content.indexOf('&') >= 0);
          if (ok) {
            lines[i] = tail + content + '$';
            for (let k: number = i + 1; k <= found; k++) {
              lines[k] = '';
            }
            i = found + 1;
            continue;
          }
        }
      }
      i++;
    }
  }

  /** 解析整篇文档。 */
  static parse(source: string): MdParseResult {
    const normalized: string = source.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/\t/g, '    ');
    // ── 预收集链接引用定义：`[标识]: 地址`（从正文剔除，不参与块级解析） ──
    MdParser.refLabels = [];
    MdParser.refHrefs = [];
    const rawLines: string[] = normalized.split('\n');
    const kept: string[] = [];
    /**
     * **原文行号映射**：`srcIndex[k]` = kept 的第 k 行在原文中的行号（0 起）。
     *
     * 为什么必须有它：块上记的 `srcLine` 是**解析用的 kept 下标**，而 kept 把
     * `[标识]: 地址` 这类链接引用定义行剔掉并重排了 —— 直接拿它去改原文就会
     * 整体前移错位（表格可视化编辑写回、块级实时编辑、大纲拖拽都依赖这个行号）。
     * 有了映射，块的 srcLine 一律翻译成**原文行号**，行区间才可靠。
     */
    const srcIndex: number[] = [];
    for (let k = 0; k < rawLines.length; k++) {
      const t: string = rawLines[k].trim();
      let consumed: boolean = false;
      if (t.startsWith('[') && !t.startsWith('[^') && t.indexOf(']:') > 0) {
        const close: number = t.indexOf(']');
        const colon: number = t.indexOf(']:');
        if (close > 1 && colon === close + 1) {
          const label: string = t.substring(1, close).trim();
          const href: string = t.substring(colon + 2).trim();
          if (label.length > 0 && href.length > 0) {
            MdParser.refLabels.push(label);
            MdParser.refHrefs.push(href);
            consumed = true;
          }
        }
      }
      if (!consumed) {
        kept.push(rawLines[k]);
        srcIndex.push(k);
      }
    }
    const lines: string[] = kept;
    MdParser.lineMap = srcIndex;
    const blocks: MdBlock[] = [];

    const noteLabels: string[] = [];
    const noteBodies: string[] = [];
    // 缩写表（缩写 → 全称），行内阶段做括号注替换
    const abbrMap: Map<string, string> = new Map<string, string>();

    let i: number = 0;
    let headingSeq: number = 0;

    // ── YAML Front Matter ────────────────────────────────────────
    // 顶部 `---` 之间的 `key: value` 抽出来单独返回，**不进入正文与大纲**。
    // 这与参考项目 MD Reader 的处理一致：元数据渲染成信息卡片，不污染阅读流。
    const meta: MdMetaItem[] = [];
    if (lines.length > 1 && lines[0].trim() === '---') {
      let end: number = -1;
      for (let k = 1; k < lines.length; k++) {
        const t: string = lines[k].trim();
        if (t === '---' || t === '...') {
          end = k;
          break;
        }
      }
      if (end > 0) {
        for (let k = 1; k < end; k++) {
          const t: string = lines[k].trim();
          if (t.length === 0 || t.startsWith('#')) {
            continue;
          }
          // 列表型值：`- xxx` 追加到上一条
          if (t.startsWith('- ') && meta.length > 0) {
            const prev: MdMetaItem = meta[meta.length - 1];
            const piece: string = t.substring(2).trim();
            prev.value = prev.value.length > 0 ? prev.value + '、' + piece : piece;
            continue;
          }
          const colon: number = t.indexOf(':');
          if (colon <= 0) {
            continue;
          }
          const key: string = t.substring(0, colon).trim();
          let value: string = t.substring(colon + 1).trim();
          const quoted: boolean = (value.startsWith('"') && value.endsWith('"') && value.length >= 2)
            || (value.startsWith('\'') && value.endsWith('\'') && value.length >= 2);
          if (quoted) {
            value = value.substring(1, value.length - 1);
          }
          const item: MdMetaItem = { key: key, value: value };
          meta.push(item);
        }
        i = end + 1;
        while (i < lines.length && lines[i].trim().length === 0) {
          i++;
        }
      }
    }

    // ── 跨行行内公式合并（`前缀$` + 空行 + `公式…$`，见方法注释）──
    // 放主循环之前、行号映射建立之后：置空法不改变行数，行号语义安全。
    MdParser.mergeCrossLineDollar(lines);

    while (i < lines.length) {
      const raw: string = lines[i];
      const t: string = raw.trim();

      if (t.length === 0) {
        i++;
        continue;
      }

      // ── 围栏代码块 ────────────────────────────────────────────────
      if (MdParser.isFence(t)) {
        const info: string = MdParser.fenceInfo(t);
        let lang: string = MdParser.fenceLang(info);
        // **围栏长度**：外层围栏可能比内层长（教程里用 4 个反引号包住 3 个反引号的
        // 示例，这是 Markdown 标准写法）—— 只有**同长或更长**的围栏才算结束。
        // 否则内层围栏会被误判为结束标记，外层块内容变成空的（用户实测
        //「语法教程这两块是空的」就是这个问题）。
        const openLen: number = MdParser.fenceLen(t);
        const fenceLine: number = i;
        const body: string[] = [];
        i++;
        while (i < lines.length) {
          const cur: string = lines[i].trim();
          if (MdParser.isFence(cur) && MdParser.fenceLen(cur) >= openLen) {
            break;
          }
          body.push(lines[i]);
          i++;
        }
        if (i < lines.length) {
          i++;
        }
        // 指定行高亮（VitePress / Shiki 的 {1,3-5}、Python-Markdown 的 hl_lines="1 3"，1 起）
        const hlLines: number[] = MdParser.fenceHlLines(info);
        // PlantUML 路由（2026-10-14 起有离线内核 @plantuml/core，不再一律桥成 mermaid）：
        //   · 内核有渲染器的图种 → lang 'plantuml' + **原文**，交给 render/plantuml.html
        //   · 内核没有渲染器的：`@startmath` → 公式块（走 KaTeX）、`@starttimeline` → 桥成
        //     mermaid timeline、`@startfiles` → 制表符文件树代码块；
        //     盐图 / nwdiag / ditaa 没有便宜的等价画法 → 保留源码代码块
        //     （内核遇到它们只会画一张「本构建不支持」的错误卡，那比代码块更没用）。
        // 导出侧不带内核（5.7MB 不能塞进每个导出的 HTML），由 MdToHtml 走 PlantumlBridge。
        let pumlRoute: string = '';
        let pumlOut: string = '';
        if (MdParser.isPumlLang(lang.toLowerCase())) {
          const pumlSrc: string = body.join('\n');
          const fenceLang: string = lang.toLowerCase();
          // 裸围栏名（```nwdiag / ```salt / ```ditaa）：内容里没有 @startXxx，
          // 用围栏名本身当路由头，否则会走到"未知头部 → 留源码"那一支。
          const bareHead: string = (fenceLang === 'nwdiag' || fenceLang === 'salt'
            || fenceLang === 'ditaa') ? fenceLang : '';
          pumlRoute = bareHead.length > 0 && MdParser.pumlHeadOf(pumlSrc).length === 0
            ? MdParser.pumlRouteOf('@start' + bareHead + '\n' + pumlSrc)
            : MdParser.pumlRouteOf(pumlSrc);
          pumlOut = pumlRoute === 'math' ? PlantumlBridge.mathSource(pumlSrc)
            : (pumlRoute === 'timeline' ? PlantumlBridge.toMermaidTimeline(pumlSrc)
              : (pumlRoute === 'tree' ? PlantumlBridge.toTree(pumlSrc)
                : (pumlRoute === 'nwdiag' ? PlantumlBridge.toMermaidNwdiag(pumlSrc) : pumlSrc)));
          if (pumlRoute === 'math' && pumlOut.length > 0) {
            blocks.push(MdBlockFactory.math(pumlOut, blocks.length, MdParser.orig(fenceLine)));
            continue;
          }
          if (pumlRoute === 'tree' && pumlOut.length > 0) {
            const tc: MdBlock = MdBlockFactory.code('filetree', pumlOut.split('\n'), blocks.length);
            tc.srcLine = MdParser.orig(fenceLine);
            blocks.push(tc);
            continue;
          }
          if (pumlRoute === 'math' || pumlRoute === 'tree') {
            // 转不出内容（源码不是预期的那种写法）→ 当普通代码块，别硬塞空块
            pumlRoute = '';
          }
        }
        const isPuml: boolean = pumlRoute === 'timeline';
        const bodyStr: string = (pumlRoute === 'plantuml' || pumlRoute === '') ? body.join('\n') : pumlOut;
        // ZenUML：**不走 mermaid 外部图种插件**。
        // 随包 mermaid 已升到 11.17.2，而 @mermaid-js/mermaid-zenuml 1.0.1（靠 React 渲染）
        // 与新版 mermaid 的内部约定错位，真机 parse 阶段必抛错 → 被 mermaid 画成
        // 「Syntax error in text」错误卡（用户实测）。改走 **纯文本转译**：
        // ZenUML 语句形状与时序图同构，译成 mermaid sequenceDiagram 后由已在用的
        // mermaid 引擎出图 —— 确定性、可离线验证，也不再背 3.3MB 插件 + React。
        const zenumlSrc: string = bodyStr;
        const isZenumlBlock: boolean = lang.toLowerCase() === 'zenuml' || MdParser.isZenumlBody(zenumlSrc);
        const zenumlOut: string = isZenumlBlock ? ZenumlBridge.toMermaid(zenumlSrc) : '';
        // 转译不出内容（不是可识别的 ZenUML）→ 强制留代码块，别喂给 mermaid 报语法错
        const zenumlBad: boolean = isZenumlBlock && zenumlOut.length === 0;
        // nwdiag 桥不出内容（写法不在识别范围内）→ 同样留代码块
        const pumlBad: boolean = pumlRoute === 'nwdiag' && pumlOut.length === 0;
        const baseLang: string = pumlRoute === 'plantuml' ? 'plantuml'
          : (pumlRoute === 'salt' || pumlRoute === 'ditaa' ? pumlRoute
            : (pumlRoute === 'nwdiag' || isPuml || zenumlOut.length > 0
              ? 'mermaid' : MdParser.chartLangOf(lang.toLowerCase())));
        const langLower: string = baseLang;
        const bodyFinal: string = zenumlOut.length > 0 ? zenumlOut
          : (pumlRoute === 'nwdiag' ? pumlOut : bodyStr);
        // `html` 与图表同路：按「渲染结果」展示（HTML 代码块预览，用户要求）——
        // 由此浏览器天然支持 <font color size face> 这类**快速样式**与常见标签。
        // ⚠️ `plantuml` 只有在**路由判定交给内核**时才进图表通道：内核没有渲染器的
        // （盐图 / nwdiag / ditaa）pumlRoute 是空串，必须留代码块，否则会喂给内核
        // 画出一张「Diagram not supported」错误卡（verify-syntax-coverage §6.21 钉住）。
        const chartPlantuml: boolean = (langLower !== 'plantuml' || pumlRoute === 'plantuml')
          && !zenumlBad && !pumlBad && (pumlRoute !== 'nwdiag' || pumlOut.length > 0);
        if (chartPlantuml && (langLower === 'mermaid' || langLower === 'zenuml' || langLower === 'markmap'
          || langLower === 'echarts'
          || langLower === 'abc' || langLower === 'graphviz' || langLower === 'flowchart'
          || langLower === 'wavedrom' || langLower === 'nomnoml' || langLower === 'chart'
          || langLower === 'vega' || langLower === 'plantuml'
          || langLower === 'salt' || langLower === 'ditaa' || langLower === 'html')) {
          blocks.push(MdBlockFactory.chart(langLower, bodyFinal.split('\n'), blocks.length, MdParser.orig(fenceLine)));
        } else {
          // 代码块也要记原文行号：块级实时编辑要按行区间替换源码
          const cb: MdBlock = MdBlockFactory.code(langLower, bodyFinal.split('\n'), blocks.length);
          cb.srcLine = MdParser.orig(fenceLine);
          if (hlLines.length > 0) {
            cb.hlLines = hlLines;
          }
          blocks.push(cb);
        }
        continue;
      }

      // ── 代码组 ::: code-group（VitePress 语法：组内多个 ```lang [页签名]）──
      if (t === '::: code-group' || t.startsWith(':::code-group')) {
        const groupStart: number = i;
        const codes: GroupCode[] = [];
        i++;
        while (i < lines.length) {
          const cur: string = lines[i].trim();
          if (cur === ':::') {
            i++;
            break;
          }
          if (cur.startsWith('```')) {
            const fl: string = cur.substring(3).trim();
            const spAt: number = fl.indexOf(' [');
            const gl: string = spAt >= 0 ? fl.substring(0, spAt).trim() : fl;
            const label: string = spAt >= 0 ? fl.substring(spAt + 2, fl.length - 1).trim() : (gl.length > 0 ? gl : 'text');
            const body: string[] = [];
            i++;
            while (i < lines.length && lines[i].trim() !== '```') {
              body.push(lines[i]);
              i++;
            }
            i++;
            codes.push({ label: label, lang: gl, code: body.join('\n') });
          } else {
            i++;
          }
        }
        if (codes.length > 0) {
          blocks.push(MdBlockFactory.codeGroup(codes, blocks.length));
          blocks[blocks.length - 1].srcLine = MdParser.orig(groupStart);
        }
        continue;
      }

      // ── 冒号容器 :::name [标题] ... :::（映射为对应色提示卡）──
      if (t.startsWith(':::') && t.length > 3) {
        const ctnStart: number = i;
        const head: string = t.substring(3).trim();
        const firstName: string = head.split(' ')[0];
        let ctnName: string = firstName.toLowerCase();
        let ctnTitle: string = head.substring(firstName.length).trim();
        // pandoc 的**围栏 div**：`::: {#id .类名}`（MyST / pandoc 都这么写）。上一版把
        // `{#note1` 当名字、`.callout}` 当标题，渲染出 `【.callout}】` 这种半截字面文本。
        let ctnAt: AttrTail = { hit: false, id: '', classes: [], attrs: [] };
        let ctnRaw: string = '';
        if (firstName.charAt(0) === '{') {
          const close: number = head.indexOf('}');
          if (close > 0) {
            const inner: string = head.substring(1, close);
            if (inner.charAt(0) === '=') {
              ctnRaw = inner.substring(1).toLowerCase();   // `::: {=html}` = 原生块
            } else {
              ctnAt = MdParser.attrTailOf(inner);
            }
            if (ctnAt.hit || ctnRaw.length > 0) {
              ctnTitle = head.substring(close + 1).trim();
              ctnName = ctnRaw.length > 0 ? '=' + ctnRaw : (ctnAt.classes.length > 0 ? ctnAt.classes[0] : '');
            }
          }
        }
        const innerLines: string[] = [];
        i++;
        while (i < lines.length) {
          const cur: string = lines[i].trim();
          if (cur === ':::' || cur.startsWith(':::')) {
            i++;
            break;
          }
          if (cur.length > 0) {
            innerLines.push(cur);
          }
          i++;
        }
        // `::: details` 是**折叠面板**（VitePress / pymdownx.details 都这么用），不是提示卡：
        // 落到下面的 callout 分支会变成一张常驻的蓝卡，"点击展开"的语义整个丢了。
        // pandoc 写法 `::: {#x .details}` 同理（类名驱动的折叠面板）。
        if (ctnName === 'details' || (ctnAt.hit && MdParser.hasClass(ctnAt, 'details'))) {
          const dSum: string = ctnTitle.length > 0 ? ctnTitle : '点击展开';
          // 面板正文**连空行一起按原样收**（索引 ↔ 原文行号一一对应）：
          // 里面的 `- [ ]` 勾选要写回文件，缺行号就写不回（用户实测"展开后没法勾选"）。
          const bodyRaw: string[] = [];
          for (let q = ctnStart + 1; q <= i - 2; q++) {
            bodyRaw.push(lines[q].trim());
          }
          const db: MdBlock = MdBlockFactory.details(dSum, bodyRaw.join('\n'), blocks.length,
            MdParser.orig(ctnStart));
          db.codeLines = bodyRaw;
          db.bodyStart = MdParser.orig(ctnStart + 1);
          if (ctnAt.id.length > 0) {
            db.anchor = ctnAt.id;
          }
          blocks.push(db);
          continue;
        }
        // `::: {=html}`：pandoc 的**原生块**——这段内容本来就是要原样交给 html 输出的，
        // 所以直接走 HTML 卡片（和 ```html 围栏同一条路，脚本能跑）。
        if (ctnRaw === 'html') {
          const hb: MdBlock = MdBlockFactory.chart('html', innerLines, blocks.length,
            MdParser.orig(ctnStart));
          blocks.push(hb);
          continue;
        }
        let kind: MdCalloutKind = MdCalloutKind.Note;
        const knob: string = ctnAt.hit && ctnAt.classes.length > 0 ? ctnAt.classes[0] : ctnName;
        if (knob === 'tip' || knob === 'info' || knob === 'success' || knob === 'question'
          || knob === 'details' || knob === 'abstract' || knob === 'summary') {
          kind = MdCalloutKind.Tip;
        } else if (knob === 'warning' || knob === 'caution' || knob === 'attention'
          || knob === 'todo') {
          kind = MdCalloutKind.Warning;
        } else if (knob === 'important' || knob === 'error' || knob === 'danger'
          || knob === 'failure' || knob === 'quote' || knob === 'cite') {
          kind = MdCalloutKind.Important;
        }
        const innerText: string = (ctnTitle.length > 0 ? '【' + ctnTitle + '】 ' : '')
          + innerLines.join(' ');
        blocks.push(MdBlockFactory.callout(kind, innerText, MdParser.parseInline(innerText), blocks.length));
        blocks[blocks.length - 1].srcLine = MdParser.orig(ctnStart);
        if (ctnAt.id.length > 0) {
          blocks[blocks.length - 1].anchor = ctnAt.id;
        }
        continue;
      }

      // ── 折叠细节块 <details><summary>…</summary>…</details> ──
      // 带属性的写法同样要认：`<details open>`（默认展开）与 `<summary class=…>` 是
      // VitePress / GitHub 的常规用法。原先这里比的是字面 '<details>'，这类面板整块漏给
      // 块级 HTML 路径，而 HTML 路径遇空行收束——正文被拆到面板外面，收尾的 </details>
      // 还会显成一段白字。
      if (MdParser.isDetailsStart(t)) {
        const detailsStart: number = i;
        let summary: string = '';
        const openDefault: boolean = MdParser.tagHasOpen(t);
        // 先扫一遍定位 summary 与 </details> 的行号：正文要**连空行按原样收**，
        // 这样"面板里第 k 行"能直接换算成原文行号（勾选写回要用）。
        let sumIdx: number = -1;
        let closeIdx: number = lines.length;
        let j: number = detailsStart + 1;
        while (j < lines.length) {
          const cur: string = lines[j].trim();
          const sumInner: string | null = MdParser.summaryText(cur);
          if (sumInner !== null) {
            if (sumIdx < 0) {
              sumIdx = j;
            }
            summary = sumInner;
          }
          if (cur.startsWith('</details')) {
            closeIdx = j;
            break;
          }
          j++;
        }
        const bodyFrom: number = sumIdx >= 0 ? sumIdx + 1 : detailsStart + 1;
        const bodyLines: string[] = [];
        for (let q = bodyFrom; q < closeIdx; q++) {
          bodyLines.push(lines[q].trim());
        }
        const db: MdBlock = MdBlockFactory.details(summary, bodyLines.join('\n'), blocks.length,
          MdParser.orig(detailsStart));
        db.open = openDefault;
        db.codeLines = bodyLines;
        db.bodyStart = MdParser.orig(bodyFrom);
        blocks.push(db);
        i = closeIdx >= lines.length ? lines.length : closeIdx + 1;
        continue;
      }

      // ── 数学公式块 \[...\]（CherryStudio / 常见 LaTeX 写法，兼容补强）────
      // 与 $$...$$ 完全同构：同样支持单行与多行，源码原样交给 KaTeX 渲染。
      if (t.startsWith('\\[')) {
        const mathStart: number = i;
        const latexLines: string[] = [];
        if (t.length > 4 && t.endsWith('\\]')) {
          latexLines.push(t.substring(2, t.length - 2).trim());
          i++;
        } else {
          latexLines.push(t.substring(2).trim());
          i++;
          while (i < lines.length) {
            const cur: string = lines[i].trim();
            if (cur.endsWith('\\]')) {
              const seg: string = cur.substring(0, cur.length - 2).trim();
              if (seg.length > 0) {
                latexLines.push(seg);
              }
              i++;
              break;
            }
            latexLines.push(cur);
            i++;
          }
        }
        const latexBracket: string = latexLines.join('\n').trim();
        if (latexBracket.length > 0) {
          blocks.push(MdBlockFactory.math(latexBracket, blocks.length, MdParser.orig(mathStart)));
        }
        continue;
      }

      // ── 数学公式块 $$...$$（源码原样交 KaTeX 渲染） ────────────────
      if (t.startsWith('$$')) {
        const mathStart: number = i;
        const latexLines: string[] = [];
        if (t.length > 4 && t.endsWith('$$')) {
          latexLines.push(t.substring(2, t.length - 2).trim());
          i++;
        } else {
          latexLines.push(t.substring(2).trim());
          i++;
          while (i < lines.length) {
            const cur: string = lines[i].trim();
            if (cur.endsWith('$$')) {
              const seg: string = cur.substring(0, cur.length - 2).trim();
              if (seg.length > 0) {
                latexLines.push(seg);
              }
              i++;
              break;
            }
            latexLines.push(cur);
            i++;
          }
        }
        const latex: string = latexLines.join('\n').trim();
        if (latex.length > 0) {
          blocks.push(MdBlockFactory.math(latex, blocks.length, MdParser.orig(mathStart)));
        }
        continue;
      }

      // ── 缩写定义（PHP Markdown Extra 语法：*[HTML]: HyperText Markup Language）──
      // 收进 abbr 表（本块剔除），正文行内替换成「缩写(全称)」的括号注形式。
      if (t.startsWith('*[') && t.includes(']:')) {
        const abEnd: number = t.indexOf(']:');
        const abKey: string = t.substring(2, abEnd).trim();
        const abFull: string = t.substring(abEnd + 2).trim();
        if (abKey.length > 0 && abFull.length > 0) {
          abbrMap.set(abKey, abFull);
          i++;
          continue;
        }
      }

      // ── 脚注定义（先于表格/段落，避免 [^1]: 被当成正文） ──────────
      const note: NoteDefHit = MdParser.noteDef(t);
      if (note.hit) {
        noteLabels.push(note.label);
        noteBodies.push(note.body);
        i++;
        while (i < lines.length && lines[i].trim().length > 0 && MdParser.leadingSpaces(lines[i]) >= 2) {
          noteBodies[noteBodies.length - 1] = noteBodies[noteBodies.length - 1] + ' ' + lines[i].trim();
          i++;
        }
        continue;
      }

      // ── 分割线 ────────────────────────────────────────────────────
      if (MdParser.isDivider(t)) {
        const dv: MdBlock = MdBlockFactory.divider(blocks.length);
        dv.srcLine = MdParser.orig(i);
        blocks.push(dv);
        i++;
        continue;
      }

      // ── ATX 标题 ──────────────────────────────────────────────────
      const head: HeadingHit = MdParser.headingInfo(t);
      if (head.hit) {
        headingSeq++;
        const hb: MdBlock = MdBlockFactory.heading(head.level, head.text, headingSeq,
          MdParser.parseInline(head.text), blocks.length);
        hb.srcLine = MdParser.orig(i);
        if (head.id.length > 0) {
          hb.anchor = head.id;
        }
        blocks.push(hb);
        i++;
        continue;
      }

      // ── 引用 / 提示块 ─────────────────────────────────────────────
      if (t.startsWith('>')) {
        // **每一行自己的 `>` 个数才是它的深度**。以前整段引用只取第一行的深度并合并成
        // 一块，`> > 二级嵌套引用` 这种写法会被剥成一堆同级文字（用户清单第 3 项）。
        // 现在按深度切段：深度一变就另起一块引用，配合渲染侧按 indent 缩进。
        let run: string[] = [];
        let runDepth: number = 0;
        let runStart: number = i;
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          const cur: string = lines[i].trim();
          const d: number = MdParser.quoteDepth(cur);
          let s: string = cur;
          while (s.startsWith('>')) {
            s = s.substring(1);
            if (s.startsWith(' ')) {
              s = s.substring(1);
            }
          }
          if (run.length > 0 && d !== runDepth) {
            // 深度变了 = 换了一层引用，先把上一段结算出去
            MdParser.pushQuoteOrCallout(blocks, run, runDepth, MdParser.orig(runStart));
            run = [];
          }
          if (run.length === 0) {
            runDepth = d;
            runStart = i;
          }
          run.push(s);
          i++;
        }
        if (run.length > 0) {
          MdParser.pushQuoteOrCallout(blocks, run, runDepth, MdParser.orig(runStart));
        }
        continue;
      }

      // ── 表格 ──────────────────────────────────────────────────────
      if (t.indexOf('|') >= 0 && i + 1 < lines.length && MdParser.isTableDelimiter(lines[i + 1].trim())) {
        // **记录表头行号**（0 起）：表格可视化编辑写回原文按块的 srcLine 定位行段，
        // 之前 MdBlockFactory.table 里 srcLine 恒为 0 → 保存时拿文档第一行校验必失败。
        const tableStart: number = i;
        const headerCells: string[] = MdParser.splitRow(t);
        const aligns: number[] = MdParser.delimiterAligns(lines[i + 1].trim());
        const rows: MdTableRow[] = [];
        rows.push(MdBlockFactory.tableRow(headerCells, true));
        i += 2;
        while (i < lines.length) {
          const cur: string = lines[i].trim();
          if (cur.length === 0 || cur.indexOf('|') < 0) {
            break;
          }
          rows.push(MdBlockFactory.tableRow(MdParser.splitRow(cur), false));
          i++;
        }
        const tb: MdBlock = MdBlockFactory.table(rows, aligns, blocks.length);
        tb.srcLine = MdParser.orig(tableStart);
        blocks.push(tb);
        continue;
      }

      // ── 列表 ──────────────────────────────────────────────────────
      const listHit: ListHit = MdParser.listInfo(raw);
      if (listHit.hit) {
        // **嵌套层级按"内容列栈"算**，不再用旧的 floor(空格数/2) 一刀切：
        // 一刀切会把 4 空格缩进（CommonMark 里最常规的嵌套写法）判成第 2 层，
        // 而每级 +3 空格的五级列表会在第 3 层被截平——用户文档里"嵌套列表全平铺
        // 在同一层"就是这么来的。栈里存的是**每一层第一次出现时的行首空格数**：
        // 比栈顶更深 = 新开一层；比栈顶浅 = 弹回对应层；相等 = 同层兄弟。
        const levels: number[] = [];
        let lastIndent: number = -1;
        while (i < lines.length) {
          // **松散列表的嵌套**：父项与子项之间空了一行（`- 父` 空行 `        - 子`）。
          // 空行会让上面这个 while 直接 break，新一轮列表又从零建 levels 栈，
          // 于是子项的层级被抹平成第 0 层。只要空行后紧跟的是**缩进更深**的列表项，
          // 它就还是这一项的子列表——跨过空行，栈保留。
          if (lines[i].trim().length === 0 && lastIndent >= 0) {
            let j: number = i;
            while (j < lines.length && lines[j].trim().length === 0) {
              j++;
            }
            if (j < lines.length && MdParser.listInfo(lines[j]).hit
              && MdParser.leadingSpaces(lines[j]) > lastIndent) {
              i = j;
            }
          }
          const cur: ListHit = MdParser.listInfo(lines[i]);
          if (!cur.hit) {
            break;
          }
          // 条目自己的源码行号（任务列表勾选要改写原文这一行）
          const itemLine: number = i;
          let text: string = cur.text;
          const baseIndent: number = cur.spaces;
          if (levels.length === 0) {
            levels.push(baseIndent);
          } else {
            while (levels.length > 1 && baseIndent < levels[levels.length - 1]) {
              levels.pop();
            }
            if (baseIndent > levels[levels.length - 1]) {
              levels.push(baseIndent);
            }
          }
          const depth: number = levels.length - 1;
          i++;
          // 续行：缩进比标记更深、且不是新的块起始
          while (i < lines.length) {
            const nx: string = lines[i];
            if (nx.trim().length === 0) {
              break;
            }
            if (MdParser.listInfo(nx).hit || MdParser.isBlockStart(nx)) {
              break;
            }
            if (MdParser.leadingSpaces(nx) > baseIndent) {
              text = text + ' ' + nx.trim();
              i++;
            } else {
              break;
            }
          }
          blocks.push(MdBlockFactory.listItem(text, cur.ordered, cur.marker, cur.task, depth,
            MdParser.parseInline(text), blocks.length, MdParser.orig(itemLine)));
          lastIndent = baseIndent;
        }
        continue;
      }

      // ── 缩进代码块（4 空格 / Tab，老式写法）────────────────────────
      // CommonMark 的两条限制都在这儿落地：
      //  · **不能打断段落**——紧跟段落的缩进行是段落的"惰性续行"，不是代码。
      //    判据是**上一行**有没有空行，而不是"上一个块是什么种类"：`段落 + 空行 + 缩进`
      //    里段落早被那行空行关闭了，缩进块是代码。原来只看块种类，这条被当成续行，
      //    整段代码并进段落、行首空白被 trim，等宽与缩进全丢（覆盖实测第 4 条）。
      //  · 列表项的嵌套与后续内容轮不到这里——列表分支在这条之前，
      //    `listInfo()` 对 8 空格缩进的项同样命中，缩进正文才落到这条来。
      if ((raw.startsWith('    ') || raw.startsWith('\t'))
        && (MdParser.atBlockBoundary(blocks) || MdParser.prevLineBlank(lines, i))) {
        const codeStart: number = i;
        const body: string[] = [];
        while (i < lines.length) {
          const ln: string = lines[i];
          if (ln.trim().length === 0) {
            body.push('');
            i++;
            continue;
          }
          if (!(ln.startsWith('    ') || ln.startsWith('\t'))) {
            break;
          }
          body.push(ln.startsWith('\t') ? ln.substring(1) : ln.substring(4));
          i++;
        }
        // 结尾空行不属于代码（它们只是"这块结束了"的记号）
        while (body.length > 0 && body[body.length - 1].length === 0) {
          body.pop();
        }
        if (body.length > 0) {
          const ib: MdBlock = MdBlockFactory.code('', body, blocks.length);
          ib.srcLine = MdParser.orig(codeStart);
          blocks.push(ib);
        }
        continue;
      }

      // ── 块级原生 HTML（合并单元格表格 / 内嵌 SVG / 音视频 / figure 图注 / div 样式…）──
      // 行内那条路只处理成对的小标签，块级标签被 htmlBlockTag 显式排除（否则 `<table>`
      // 会被当行内标签、把整张表吞成一行文本）。这里补上另一头：整段 HTML 收成一个
      // `html` 图表块，走 render/html.html 的 WebView 卡片——colspan/rowspan、内嵌 SVG、
      // 进度条这类排版，ArkUI 的 Text/Span 根本表达不了。
      const rootTag: string = MdParser.htmlBlockTagAt(raw);
      if (rootTag.length > 0 && MdParser.atBlockBoundary(blocks)) {
        const htmlStart: number = i;
        const picked: string[] = [];
        let balance: number = 0;
        while (i < lines.length) {
          const hl: string = lines[i];
          if (hl.trim().length === 0) {
            break;                        // 空行结束一块 HTML（CommonMark 第六类）
          }
          picked.push(hl);
          balance += MdParser.tagDelta(hl, rootTag);
          i++;
          if (balance <= 0) {
            break;                        // 根标签闭合 = 这块结束
          }
        }
        const htmlText: string = MdParser.sanitizeHtmlBlock(picked.join('\n'));
        if (htmlText.trim().length > 0) {
          blocks.push(MdBlockFactory.chart('html', htmlText.split('\n'), blocks.length,
            MdParser.orig(htmlStart)));
        }
        continue;
      }

      // ── Setext 标题 ───────────────────────────────────────────────
      if (i + 1 < lines.length) {
        const underline: string = lines[i + 1].trim();
        const level: number = MdParser.setextLevel(underline);
        if (level > 0) {
          headingSeq++;
          const sh: MdBlock = MdBlockFactory.heading(level, t, headingSeq,
            MdParser.parseInline(t), blocks.length);
          sh.srcLine = MdParser.orig(i);
          blocks.push(sh);
          i += 2;
          continue;
        }
      }

      // ── 段落 ──────────────────────────────────────────────────────
      const paraStart: number = i;
      const para: string[] = [t];
      i++;
      while (i < lines.length) {
        const nx: string = lines[i];
        if (nx.trim().length === 0 || MdParser.isBlockStart(nx)) {
          break;
        }
        para.push(nx.trim());
        i++;
      }
      // 文献引用（pandoc [@key] → [key] 上标标记；文献列表由文档尾部自理）
      for (let ak = 0; ak < para.length; ak++) {
        if (para[ak].indexOf('[@') >= 0) {
          para[ak] = para[ak].replace(/\[@([^\]]+)\]/g, '[$1]');
        }
      }
      // 缩写括号注替换（命中缩写表的原样词 → 词(全称)，仅首现替换）
      for (let ak = 0; ak < para.length; ak++) {
        for (const akey of abbrMap.keys()) {
          if (para[ak] === akey || para[ak].indexOf(akey) >= 0) {
            const full: string | undefined = abbrMap.get(akey);
            if (full !== undefined && para[ak].indexOf('(' + full + ')') < 0) {
              para[ak] = para[ak].split(akey).join(akey + '(' + full + ')');
            }
          }
        }
      }
      // ── 定义列表（术语行 + 连续 ": 定义" 行，PHP Markdown Extra / Pandoc 语法）──
      // 术语与每条定义**各成一个块**：术语是加粗段落，定义是「无标记的列表项」（indent 1）。
      // 以前把整组压成一段「**术语**：定义；定义。」——定义之间被分号连成一行、
      // 没法单独批注，而且术语里带 `*` 或反引号时这层字符串拼接还会解析错。
      const allDefs: boolean = para.length >= 2
        && para.slice(1).every((dl: string) => dl.startsWith(':'));
      if (allDefs) {
        const term: string = para[0].trim();
        const termInlines: MdInline[] = MdParser.parseInline(term);
        for (let q = 0; q < termInlines.length; q++) {
          termInlines[q].bold = true;
        }
        const tp: MdBlock = MdBlockFactory.paragraph(term, termInlines, blocks.length);
        tp.srcLine = MdParser.orig(paraStart);
        blocks.push(tp);
        for (let d = 1; d < para.length; d++) {
          const def: string = para[d].replace(/^:+\s*/, '');
          const db: MdBlock = MdBlockFactory.listItem(def, false, '', MdTaskState.None, 1,
            MdParser.parseInline(def), blocks.length, MdParser.orig(paraStart + d));
          blocks.push(db);
        }
      } else {
      const paraText: string = para.join(' ');
      const pb: MdBlock = MdBlockFactory.paragraph(paraText, MdParser.parseInline(paraText), blocks.length);
      pb.srcLine = MdParser.orig(paraStart);
      blocks.push(pb);
      }
    }

    // 正文最后一行之后的行号（**原文行号**）：文末合成的「注释区」块没有对应的源文本，
    // srcLine 不能留 0（会让块区间推断出负长度），统一指到正文末尾。
    let bodyEnd: number = rawLines.length;
    for (let k = 0; k < blocks.length; k++) {
      if (blocks[k].srcLine > bodyEnd) {
        bodyEnd = blocks[k].srcLine;
      }
    }

    // ── 脚注引用回填 + 文末注释区 ──────────────────────────────────
    const noteIndex: Map<string, number> = new Map();
    for (let k = 0; k < noteLabels.length; k++) {
      if (!noteIndex.has(noteLabels[k])) {
        noteIndex.set(noteLabels[k], k + 1);
      }
    }
    MdParser.resolveNoteRefs(blocks, noteIndex);
    // pandoc 图表编号 + @fig: 交叉引用（在脚注回填之后做：两者互不干扰）
    MdParser.numberFigures(blocks);

    const notes: MdNote[] = [];
    if (noteLabels.length > 0) {
      const nd: MdBlock = MdBlockFactory.divider(blocks.length);
      nd.srcLine = bodyEnd;
      blocks.push(nd);
      headingSeq++;
      const nh: MdBlock = MdBlockFactory.heading(2, '注释', headingSeq,
        MdParser.parseInline('注释'), blocks.length);
      nh.srcLine = bodyEnd;
      blocks.push(nh);
      for (let k = 0; k < noteLabels.length; k++) {
        const inlines: MdInline[] = MdParser.parseInline(noteBodies[k]);
        const noteBlockIndex: number = blocks.length;
        const nb: MdBlock = MdBlockFactory.noteItem(noteBodies[k], k + 1, inlines, noteBlockIndex);
        nb.srcLine = bodyEnd;
        blocks.push(nb);
        const note: MdNote = {
          no: k + 1,
          label: noteLabels[k],
          text: noteBodies[k],
          inlines: inlines,
          blockIndex: noteBlockIndex
        };
        notes.push(note);
      }
    }

    // ── `[TOC]` 展开成正文目录 ───────────────────────────────────────
    // Python-Markdown `toc` / remark-toc 的同一写法。此前原样显示，矩阵标 ❌。
    // 做法是把那一行换成一份列表条目，每条是 `[标题文字](#标题文字)`——**复用既有的
    // 跳转通道**（阅读页按标题文字归一化匹配跳转；导出网页里锚点 id 本来就按标题生成），
    // 因此不需要任何新的渲染面，条目还能被选中、批注。
    MdParser.expandToc(blocks);

    // ── 目录与统计 ────────────────────────────────────────────────
    const outline: MdHeading[] = [];
    for (let k = 0; k < blocks.length; k++) {
      const b: MdBlock = blocks[k];
      if (b.kind === MdBlockKind.Heading) {
        const item: MdHeading = {
          level: b.level,
          text: b.plain,
          blockIndex: k,
          seq: b.headingSeq,
          anchor: b.anchor === undefined ? '' : b.anchor
        };
        outline.push(item);
      }
    }

    const stat: MdStat = MdParser.collect(blocks);
    const result: MdParseResult = {
      blocks: blocks,
      outline: outline,
      notes: notes,
      meta: meta,
      footnoteCount: noteLabels.length,
      headingCount: stat.headingCount,
      codeBlockCount: stat.codeBlockCount,
      tableCount: stat.tableCount,
      charCount: stat.charCount,
      wordCount: stat.wordCount
    };
    return result;
  }

  /**
   * 取第 `index` 个块在**原文**中的行区间（左闭右开）。
   *
   * 结束行的推断规则：取「下一个起始行大于本块起始行的块」的起始行；
   * 若后面没有更大的（例如文末合成的注释区块统一指向正文末尾），则取全文行数。
   * 这样即使某类块没记 srcLine，区间也不会退化成负长度。
   */
  static blockSrcRange(blocks: MdBlock[], index: number, lineCount: number): MdSrcRange {
    const res: MdSrcRange = { start: 0, end: 0 };
    if (blocks.length === 0 || index < 0 || index >= blocks.length) {
      return res;
    }
    let start: number = blocks[index].srcLine;
    if (start < 0) {
      start = 0;
    }
    let end: number = lineCount;
    for (let k = index + 1; k < blocks.length; k++) {
      const nx: number = blocks[k].srcLine;
      if (nx > start) {
        end = nx;
        break;
      }
    }
    if (end < start) {
      end = start;
    }
    res.start = start;
    res.end = end;
    return res;
  }

  // ────────────────────────── 行内解析 ──────────────────────────

  /** 解析行内 Markdown。样式标志位会向下继承，因此无需嵌套节点。 */
  static parseInline(src: string): MdInline[] {
    return MdParser.applyPandocAttrs(MdParser.scan(src, false, false, false, false));
  }

  /**
   * Pandoc 行内属性：`![图](a.png){#fig:a width=60%}`、`[文字]{.bold color=#2F63E8}`。
   *
   * 上一版这些花括号**原样显示在正文里**（用户实测"pandoc 专属还是不支持"最直观的一条）。
   * 澄笺没有 pandoc 的编号引擎 / CSS 样式层，所以策略是**吃掉花括号、能表达的语义表达**：
   *  · `.bold` / `.strong` / `.italic` / `.em` / `.strikeout` / `.underline`（没有下划线通道，
   *    只吃掉不显示）→ 对应 flag；
   *  · `color=#RRGGBB` / `background-color=#RRGGBB` → 复用原生 HTML 那套色值过滤
   *    （`red` / `rgb()` / `url()` 一律丢弃，避免把任意 CSS 注入渲染层）；
   *  · `#id` 与其它 `key=value` → 静默忽略，**`@fig:x` 交叉引用仍然不解析**（矩阵如实标注）。
   * 认不出是属性块就一个字都不动（`[x] { 三个词 }` 这种正常正文不会被误吞）。
   */
  private static applyPandocAttrs(list: MdInline[]): MdInline[] {
    for (let k = 0; k < list.length; k++) {
      const cur: MdInline = list[k];
      if (cur.kind !== MdInlineKind.Plain) {
        continue;
      }
      // ① 图片 / 链接后面**紧跟着**的花括号属性块（它们在 list 里是独立片段）
      if (k > 0 && cur.text.charAt(0) === '{') {
        const prev: MdInline = list[k - 1];
        if (prev.kind === MdInlineKind.Image || prev.kind === MdInlineKind.Link) {
          const close: number = cur.text.indexOf('}');
          if (close > 0 && MdParser.attrTailOf(cur.text.substring(1, close)).hit) {
            // pandoc 图表锚点 `{#fig:x}`：记到图片片段上，收尾时统一编号（见 numberFigures）
            const atFig: AttrTail = MdParser.attrTailOf(cur.text.substring(1, close));
            if (prev.kind === MdInlineKind.Image && atFig.id.length > 0) {
              prev.figId = atFig.id;
            }
            const left: string = cur.text.substring(close + 1);
            if (left.length === 0) {
              list.splice(k, 1);
              k--;
            } else {
              cur.text = left;
            }
            continue;
          }
        }
      }
      // ② `[文字]{属性}` 形式的行内 span：在原片段里就地拆分
      const m: RegExpMatchArray | null = cur.text.match(/\[([^\[\]]+)\]\{([^{}]*)\}/);
      if (m === null || !MdParser.attrTailOf(m[2]).hit) {
        continue;
      }
      const at: AttrTail = MdParser.attrTailOf(m[2]);
      const col: string = MdParser.attrColor(at, 'color');
      const bgc: string = MdParser.attrColor(at, 'background-color');
      // 走原生 HTML 那两条现成通道（Color / Under），**不要**新造"Plain + color"这种
      // 只有正文认得的组合：导出侧 MdToHtml 是按 kind 分派的，Plain 上的 color 会被丢掉。
      const spanKind: MdInlineKind = (col.length > 0 || bgc.length > 0) ? MdInlineKind.Color
        : (MdParser.hasClass(at, 'underline') ? MdInlineKind.Under : MdInlineKind.Plain);
      const span: MdInline = {
        kind: spanKind, text: m[1], href: '', num: 0,
        bold: MdParser.hasClass(at, 'bold') || MdParser.hasClass(at, 'strong'),
        italic: MdParser.hasClass(at, 'italic') || MdParser.hasClass(at, 'em'),
        strike: MdParser.hasClass(at, 'strikeout') || MdParser.hasClass(at, 'strike'),
        code: false,
        color: col,
        bg: bgc
      };
      const before: string = cur.text.substring(0, m.index);
      const after: string = cur.text.substring((m.index === undefined ? 0 : m.index) + m[0].length);
      const rest: MdInline[] = after.length > 0
        ? [{ kind: MdInlineKind.Plain, text: after, href: '', num: 0, bold: false, italic: false, strike: false, code: false }]
        : [];
      cur.text = before;
      const ins: MdInline[] = [span].concat(rest);
      for (let q = 0; q < ins.length; q++) {
        list.splice(k + 1 + q, 0, ins[q]);
      }
      if (before.length === 0) {
        list.splice(k, 1);
        k--;
      }
    }
    return list;
  }

  /** 属性块里的 `key=#RRGGBB`：交给原生 HTML 同一套色值过滤器（其它写法直接丢） */
  private static attrColor(at: AttrTail, key: string): string {
    for (let k = 0; k < at.attrs.length; k++) {
      const kv: string = at.attrs[k];
      const eq: number = kv.indexOf('=');
      if (eq <= 0 || kv.substring(0, eq).toLowerCase() !== key) {
        continue;
      }
      const v: string = kv.substring(eq + 1).replace(/^["']|["']$/g, '');
      const c: string = MdParser.htmlColor('color="' + v + '"');
      if (c.length > 0) {
        return c;
      }
    }
    return '';
  }

  private static scan(src: string, bold: boolean, italic: boolean, strike: boolean, code: boolean): MdInline[] {
    const out: MdInline[] = [];
    let buf: string = '';
    const n: number = src.length;
    let i: number = 0;

    while (i < n) {
      const c: string = src.charAt(i);

      // 反斜杠转义
      if (c === '\\' && i + 1 < n && MdParser.isEscapable(src.charAt(i + 1))) {
        buf = buf + src.charAt(i + 1);
        i += 2;
        continue;
      }

      // HTML 字符实体：`&amp;` `&lt;` `&nbsp;` `&#124;`（十进制）`&#x2014;`（十六进制）。
      // CommonMark 的基本盘，也是渲染文档 §13 给的"表格里要写竖线"的另一条推荐写法；
      // 此前一个都不解，正文里就明晃晃显示 &amp;。
      if (c === '&') {
        const ent: EntityHit = MdParser.entityAt(src, i);
        if (ent.len > 0) {
          buf = buf + ent.text;
          i += ent.len;
          continue;
        }
      }

      // 尖括号自动链接 `<https://…>` / `<mailto:…>` / `<someone@example.com>`。
      // 此前没有这一条：`<` 被当普通文字落下，紧随其后的裸 URL 扫描一路吃到 `>`，
      // 结果是**链接文本和 href 都带着收尾的 `>`**（点了打不开），而矩阵里写的是
      // "照原样显示 ❌"——比标错更糟的是标错的方向还反了。
      if (c === '<') {
        const al: AutolinkHit = MdParser.autolinkAt(src, i);
        if (al.len > 0) {
          buf = MdParser.flush(out, buf, bold, italic, strike, code);
          out.push(inlineOf(MdInlineKind.Link, al.text, al.href, 0, bold, italic, strike, code));
          i += al.len;
          continue;
        }
      }

      // 行内代码
      if (c === '`') {
        const end: number = src.indexOf('`', i + 1);
        if (end > i) {
          buf = MdParser.flush(out, buf, bold, italic, strike, code);
          out.push(inlineOf(MdInlineKind.Code, src.substring(i + 1, end).trim(), '', 0,
            bold, italic, strike, true));
          i = end + 1;
          continue;
        }
      }

      // 行内数学 \(...\)（CherryStudio / 常见 LaTeX 写法，与 $...$ 等价）
      if (c === '\\' && i + 1 < n && src.charAt(i + 1) === '(') {
        const closeP: number = src.indexOf('\\)', i + 2);
        if (closeP > i + 2) {
          const contentP: string = src.substring(i + 2, closeP);
          if (contentP.trim().length > 0) {
            buf = MdParser.flush(out, buf, bold, italic, strike, code);
            out.push(inlineOf(MdInlineKind.MathInline, contentP, '', 0,
              bold, italic, strike, code));
            i = closeP + 2;
            continue;
          }
        }
      }

      // 行内数学 $$...$$（同一行内成对出现，如列表项「- 求和：$$\sum…$$」——
      // 用户《LaTeX 渲染能力测试清单》第 6 类的写法。顶格的 $$ 已由块级解析
      // 处理（成为 Math 块），不会走到行内解析这里）
      if (c === '$' && i + 1 < n && src.charAt(i + 1) === '$') {
        const closeD: number = src.indexOf('$$', i + 2);
        if (closeD > i + 2) {
          const contentD: string = src.substring(i + 2, closeD);
          if (contentD.trim().length > 0 && contentD.indexOf('$') < 0) {
            buf = MdParser.flush(out, buf, bold, italic, strike, code);
            out.push(inlineOf(MdInlineKind.MathInline, contentD, '', 0,
              bold, italic, strike, code));
            i = closeD + 2;
            continue;
          }
        }
      }

      // 行内数学 $...$（开 $ 后不能紧跟空格、闭 $ 前不能是空格，避免误伤货币写法）
      if (c === '$' && i + 1 < n && src.charAt(i + 1) !== '$' && src.charAt(i + 1) !== ' ') {
        let close: number = -1;
        for (let k = i + 1; k < n; k++) {
          if (src.charAt(k) === '$') {
            if (k > i + 1 && src.charAt(k - 1) !== ' ') {
              close = k;
            }
            break;
          }
        }
        if (close > i + 1) {
          const content: string = src.substring(i + 1, close);
          if (content.trim().length > 0 && content.indexOf('$') < 0) {
            buf = MdParser.flush(out, buf, bold, italic, strike, code);
            out.push(inlineOf(MdInlineKind.MathInline, content, '', 0,
              bold, italic, strike, code));
            i = close + 1;
            continue;
          }
        }
      }

      // 图片
      if (c === '!' && i + 1 < n && src.charAt(i + 1) === '[') {
        const img: LinkHit = MdParser.linkAt(src, i + 1);
        if (img.hit) {
          buf = MdParser.flush(out, buf, bold, italic, strike, code);
          const imgItem: MdInline = inlineOf(MdInlineKind.Image, img.label, img.href, 0,
            bold, italic, strike, code);
          // `markdown-it-imsize` / Typora 的 `![alt](a.png =120x60)`（也收 `=120x` / `=x60`）。
          // linkAt 按 CommonMark 把空格后的部分当 title 丢了，所以这里回看原始括号内容。
          const spec: RegExpMatchArray | null =
            src.substring(i, img.end).match(/=\s*(\d*)\s*[xX]\s*(\d*)\s*(?=[)"])/);
          if (spec !== null) {
            if (spec[1].length > 0) {
              imgItem.w = parseInt(spec[1], 10);
            }
            if (spec[2].length > 0) {
              imgItem.h = parseInt(spec[2], 10);
            }
          }
          out.push(imgItem);
          i = img.end;
          continue;
        }
      }

      // 链接 / 脚注引用
      if (c === '[') {
        if (i + 1 < n && src.charAt(i + 1) === '^') {
          const close: number = src.indexOf(']', i + 2);
          if (close > i + 2) {
            buf = MdParser.flush(out, buf, bold, italic, strike, code);
            out.push(inlineOf(MdInlineKind.FootnoteRef, src.substring(i + 2, close), '', 0,
              bold, italic, strike, code));
            i = close + 1;
            continue;
          }
        }
        const link: LinkHit = MdParser.linkAt(src, i);
        if (link.hit) {
          buf = MdParser.flush(out, buf, bold, italic, strike, code);
          out.push(inlineOf(MdInlineKind.Link, link.label, link.href, 0, bold, italic, strike, code));
          i = link.end;
          continue;
        }
        // 链接引用 [文本][标识] / [标识]（定义由 parse() 预收集到 refLabels/refHrefs）
        const refClose: number = src.indexOf(']', i + 1);
        if (refClose > i + 1) {
          let id: string = '';
          let text: string = src.substring(i + 1, refClose);
          if (refClose + 1 < n && src.charAt(refClose + 1) === '[') {
            const idClose: number = src.indexOf(']', refClose + 2);
            if (idClose > refClose + 2) {
              id = src.substring(refClose + 2, idClose);
              const href: string = MdParser.lookupRef(id);
              if (href.length > 0) {
                buf = MdParser.flush(out, buf, bold, italic, strike, code);
                out.push(inlineOf(MdInlineKind.Link, text, href, 0, bold, italic, strike, code));
                i = idClose + 1;
                continue;
              }
            }
          } else {
            // 单写法 [标识]：仅当标识在引用表里才转链接
            id = text;
            const href2: string = MdParser.lookupRef(id);
            if (href2.length > 0 && src.charAt(refClose + 1) !== '(') {
              buf = MdParser.flush(out, buf, bold, italic, strike, code);
              out.push(inlineOf(MdInlineKind.Link, text, href2, 0, bold, italic, strike, code));
              i = refClose + 1;
              continue;
            }
          }
        }
      }

      // 裸 URL 自动链接（http:// 或 https:// 开头，吃到空白/全角标点/尖括号为止）
      if (c === 'h' && (src.startsWith('http://', i) || src.startsWith('https://', i))) {
        let k: number = i;
        while (k < n) {
          const ch: string = src.charAt(k);
          if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '）' || ch === '》'
            || ch === '，' || ch === '。' || ch === '；' || ch === '"' || ch === '\''
            || ch === '>' || ch === '<') {
            break;
          }
          k++;
        }
        // 去掉尾部配对括号 / 句点
        while (k > i && (src.charAt(k - 1) === ')' || src.charAt(k - 1) === '。'
          || src.charAt(k - 1) === '，' || src.charAt(k - 1) === '.')) {
          k--;
        }
        if (k > i + 8) {
          const url: string = src.substring(i, k);
          buf = MdParser.flush(out, buf, bold, italic, strike, code);
          out.push(inlineOf(MdInlineKind.Link, url, url, 0, bold, italic, strike, code));
          i = k;
          continue;
        }
      }

      // 强调（粗体 / 斜体 / 粗斜体）
      if (c === '*' || c === '_') {
        const isDouble: boolean = i + 1 < n && src.charAt(i + 1) === c;
        // ***三*** 是"又粗又斜"，不是"两层"。以前只认到两连，`***粗斜体***` 走的是
        // **双 delim 分支**：定界符后面紧跟第三个 * 让 nextOk 判假，整条强调分支被跳过，
        // 于是首尾各剩一个字面 *，中间按粗体渲染（用户清单 §1.1 的写法）。
        const isTriple: boolean = isDouble && i + 2 < n && src.charAt(i + 2) === c;
        const delim: string = isTriple ? c + c + c : (isDouble ? c + c : c);
        const from: number = i + delim.length;
        // 下划线必须位于词边界，否则 snake_case 会被误判成斜体
        const prevOk: boolean = c !== '_' || i === 0 || !MdParser.isWordChar(src.charAt(i - 1));
        const nextOk: boolean = from < n && src.charAt(from) !== ' ' && src.charAt(from) !== c;
        if (prevOk && nextOk) {
          const end: number = MdParser.findEmphClose(src, c, delim.length, from);
          // 闭口侧同样要查词边界：CommonMark 对 `_` 的要求是**两侧都贴着词字符就不是定界符**，
          // 只查开口会漏掉 `user_name_` 这种"开头合法、结尾在词内"的写法
          // （charAt 越界给空串，isWordChar('') 为假 → 行尾闭口天然合法）
          const closeOk: boolean = c !== '_' || !MdParser.isWordChar(src.charAt(end + delim.length));
          if (end > from && closeOk) {
            buf = MdParser.flush(out, buf, bold, italic, strike, code);
            const kids: MdInline[] = MdParser.scan(src.substring(from, end),
              isDouble ? true : bold,
              isTriple ? true : (isDouble ? italic : true),
              strike, code);
            for (let k = 0; k < kids.length; k++) {
              out.push(kids[k]);
            }
            i = end + delim.length;
            continue;
          }
        }
      }

      // 删除线
      if (c === '~' && i + 1 < n && src.charAt(i + 1) === '~') {
        const end: number = src.indexOf('~~', i + 2);
        if (end > i + 2) {
          buf = MdParser.flush(out, buf, bold, italic, strike, code);
          out.push(inlineOf(MdInlineKind.Strike, src.substring(i + 2, end), '', 0, bold, italic, true, code));
          i = end + 2;
          continue;
        }
      }

      // 下标 ~text~（单波浪；内容不含空白才算，避免误伤 a ~ b 与 ~~删除线~~）
      if (c === '~' && i + 2 < n && src.charAt(i + 1) !== '~' && src.charAt(i + 1) !== ' ') {
        const end: number = src.indexOf('~', i + 1);
        if (end > i + 1) {
          const content: string = src.substring(i + 1, end);
          if (content.trim().length > 0 && content.indexOf(' ') < 0 && content.indexOf('~') < 0) {
            buf = MdParser.flush(out, buf, bold, italic, strike, code);
            out.push(inlineOf(MdInlineKind.Sub, content, '', 0, bold, italic, strike, code));
            i = end + 1;
            continue;
          }
        }
      }

      // 上标 ^text^（内容不含空白；数学公式里的 ^ 走 MathLite，不经过这里）
      if (c === '^' && i + 2 < n && src.charAt(i + 1) !== ' ' && src.charAt(i + 1) !== '^') {
        const end: number = src.indexOf('^', i + 1);
        if (end > i + 1) {
          const content: string = src.substring(i + 1, end);
          if (content.trim().length > 0 && content.indexOf(' ') < 0 && content.indexOf('^') < 0) {
            buf = MdParser.flush(out, buf, bold, italic, strike, code);
            out.push(inlineOf(MdInlineKind.Sup, content, '', 0, bold, italic, strike, code));
            i = end + 1;
            continue;
          }
        }
      }

      // 高亮
      if (c === '=' && i + 1 < n && src.charAt(i + 1) === '=') {
        const end: number = src.indexOf('==', i + 2);
        if (end > i + 2) {
          buf = MdParser.flush(out, buf, bold, italic, strike, code);
          out.push(inlineOf(MdInlineKind.Mark, src.substring(i + 2, end), '', 0, bold, italic, strike, code));
          i = end + 2;
          continue;
        }
      }

      // 插入线 `++文字++`（markdown-it-ins / Cherry / Typora 同一套写法）：
      // 与 `==高亮==` 同一条通道思路 —— 成对才认，落单的两个加号原样留着。
      // 渲染走 Under（导出的网页里是真 `<ins>`）。
      if (c === '+' && i + 1 < n && src.charAt(i + 1) === '+') {
        const end: number = src.indexOf('++', i + 2);
        if (end > i + 2) {
          buf = MdParser.flush(out, buf, bold, italic, strike, code);
          out.push(inlineOf(MdInlineKind.Under, src.substring(i + 2, end), '', 0, bold, italic, strike, code));
          i = end + 2;
          continue;
        }
      }

      // Emoji 短代码 `:smile:`。
      // 必须查表命中才替换，否则正文里的 `10:30`、URL 里的冒号会被误伤。
      if (c === ':') {
        let k: number = i + 1;
        while (k < n && k - i <= 32 && isEmojiCodeChar(src.charAt(k))) {
          k++;
        }
        if (k > i + 1 && k < n && src.charAt(k) === ':') {
          const emoji: string = lookupEmoji(src.substring(i + 1, k).toLowerCase());
          if (emoji.length > 0) {
            buf = MdParser.flush(out, buf, bold, italic, strike, code);
            out.push(inlineOf(MdInlineKind.Plain, emoji, '', 0, bold, italic, strike, code));
            i = k + 1;
            continue;
          }
        }
      }

      // **原生 HTML 行内标签**（`<kbd>` / `<ruby>` / `<span style="color">` / `<u>` / `<b>` …）
      // 放在所有行内规则之后：`<https://…>` 这类自动链接已经先一步处理过了。
      if (c === '<') {
        const h: HtmlHit = MdParser.htmlAt(src, i, bold, italic, strike, code);
        if (h.consumed > 0) {
          buf = MdParser.flush(out, buf, bold, italic, strike, code);
          for (let q = 0; q < h.items.length; q++) {
            out.push(h.items[q]);
          }
          i += h.consumed;
          continue;
        }
      }

      buf = buf + c;
      i++;
    }

    MdParser.flush(out, buf, bold, italic, strike, code);
    return out;
  }

  /** 把缓冲区内容作为普通片段压入，返回空串。刻意不用闭包，避免 ArkTS 捕获可变变量。 */
  private static flush(out: MdInline[], buf: string, bold: boolean, italic: boolean,
                       strike: boolean, code: boolean): string {
    if (buf.length > 0) {
      out.push(inlineOf(MdInlineKind.Plain, buf, '', 0, bold, italic, strike, code));
    }
    return '';
  }

  /**
   * 这一行是不是**块级 HTML** 的开头（`<table …>` / `<div …>` / `<svg …>`…）。
   * 返回根标签名；不是块级开头返回空串。
   */
  private static htmlBlockTagAt(line: string): string {
    const t: string = line.trim();
    if (t.length < 2 || t.charAt(0) !== '<' || t.charAt(1) === '/') {
      return '';
    }
    const name: string = MdParser.htmlTagName(t, 0);
    if (name.length === 0 || !MdParser.htmlBlockTag(name)) {
      return '';
    }
    return t.indexOf('>') > 0 ? name : '';
  }

  /** 这一行让根标签的开合差额变化多少（`<tr>` 这种嵌套同名词不会被误算） */
  private static tagDelta(line: string, tag: string): number {
    const lower: string = line.toLowerCase();
    const openNeedle: string = '<' + tag;
    const closeNeedle: string = '</' + tag;
    let delta: number = 0;
    let k: number = 0;
    while (k < lower.length) {
      const at: number = lower.indexOf(openNeedle, k);
      if (at < 0) {
        break;
      }
      const next: string = at + openNeedle.length < lower.length
        ? lower.charAt(at + openNeedle.length) : ' ';
      if (next === ' ' || next === '>' || next === '\t' || next === '/') {
        delta++;
      }
      k = at + openNeedle.length;
    }
    k = 0;
    while (k < lower.length) {
      const at: number = lower.indexOf(closeNeedle, k);
      if (at < 0) {
        break;
      }
      delta--;
      k = at + closeNeedle.length;
    }
    return delta;
  }

  /**
   * **自动识别**出来的块级 HTML 先过一道闸：
   *  · `<script>` / `<iframe>` / `<frame>` / `<embed>` / `<object>` 整段摘掉——
   *    前者会执行，后四者会**自己**发网络请求（`<audio>`/`<video>` 留着：要用户主动点播放）；
   *  · 标签里的 `on*=` 事件属性与 `javascript:` 地址一律丢掉。
   * 用户拿 ```html 围栏主动预览时**不**过这道闸——那是"我知道我在跑这段 HTML"；
   * 这条路径是给"别人发来的文档里正好有段 HTML"兜底，风险口径不一样。
   */
  private static sanitizeHtmlBlock(text: string): string {
    let out: string = MdParser.dropTagPair(text, 'script');
    out = MdParser.dropTagPair(out, 'iframe');
    out = MdParser.dropTagPair(out, 'frame');
    out = MdParser.dropTagPair(out, 'embed');
    out = MdParser.dropTagPair(out, 'object');
    return MdParser.scrubHtmlTags(out);
  }

  /**
   * 删掉成对标签连同内容（`<script>…</script>`）。
   * 自闭合标签（`<embed … />`）只删这一个标签；**找不到闭合就删到文末**——
   * 留半截 `<script>` 在页面里比少显示一段更危险。
   */
  private static dropTagPair(text: string, tag: string): string {
    const lower: string = text.toLowerCase();
    const openNeedle: string = '<' + tag;
    let out: string = '';
    let k: number = 0;
    while (k < text.length) {
      const at: number = lower.indexOf(openNeedle, k);
      if (at < 0) {
        out = out + text.substring(k);
        break;
      }
      const next: string = at + openNeedle.length < text.length
        ? text.charAt(at + openNeedle.length) : ' ';
      if (next !== ' ' && next !== '>' && next !== '\t' && next !== '/' && next !== '\n') {
        // <scripting> 之类不是目标标签，原样带到它就结束本轮
        out = out + text.substring(k, at + openNeedle.length);
        k = at + openNeedle.length;
        continue;
      }
      const gt: number = text.indexOf('>', at);
      if (gt < 0) {
        // 标签没写完：保留它前面的正文，只丢这个残片
        return out + text.substring(k, at);
      }
      if (text.charAt(gt - 1) === '/') {
        out = out + text.substring(k, at);          // 自闭合：只摘这一个标签
        k = gt + 1;
        continue;
      }
      const closeAt: number = lower.indexOf('</' + tag, gt);
      if (closeAt < 0) {
        return out + text.substring(k, at);         // 没有闭合：后面整段都不留
      }
      const closeEnd: number = text.indexOf('>', closeAt);
      out = out + text.substring(k, at);            // ⚠️ 先留住标签**前面**那段正文
      k = closeEnd < 0 ? text.length : closeEnd + 1;
    }
    return out;
  }

  /** 逐个标签清洗：丢 `on*=` 事件属性与 `javascript:` 地址（引号里的空格不会被误切） */
  private static scrubHtmlTags(text: string): string {
    let out: string = '';
    let k: number = 0;
    while (k < text.length) {
      const lt: number = text.indexOf('<', k);
      if (lt < 0) {
        out = out + text.substring(k);
        break;
      }
      out = out + text.substring(k, lt);
      const gt: number = text.indexOf('>', lt + 1);
      if (gt < 0) {
        out = out + text.substring(lt);
        break;
      }
      out = out + '<' + MdParser.scrubAttrRun(text.substring(lt + 1, gt)) + '>';
      k = gt + 1;
    }
    return out;
  }

  /** 把一个标签内部切成属性记号（引号感知），滤掉危险属性再拼回去 */
  private static scrubAttrRun(inner: string): string {
    const tokens: string[] = [];
    let cur: string = '';
    let quote: string = '';
    for (let k = 0; k < inner.length; k++) {
      const c: string = inner.charAt(k);
      if (quote.length > 0) {
        cur = cur + c;
        if (c === quote) {
          quote = '';
        }
        continue;
      }
      if (c === '"' || c === '\'') {
        quote = c;
        cur = cur + c;
        continue;
      }
      if (c === ' ' || c === '\t' || c === '\n') {
        if (cur.length > 0) {
          tokens.push(cur);
          cur = '';
        }
        continue;
      }
      cur = cur + c;
    }
    if (cur.length > 0) {
      tokens.push(cur);
    }
    let out: string = tokens.length > 0 ? tokens[0] : '';
    for (let t = 1; t < tokens.length; t++) {
      const tok: string = tokens[t];
      const eq: number = tok.indexOf('=');
      const name: string = (eq < 0 ? tok : tok.substring(0, eq)).toLowerCase();
      const value: string = eq < 0 ? '' : tok.substring(eq + 1).toLowerCase();
      if (name.startsWith('on')) {
        continue;                        // onclick / onerror / onload… 一律不给执行机会
      }
      if (value.indexOf('javascript:') >= 0) {
        continue;
      }
      out = out + ' ' + tok;
    }
    return out;
  }

  /** 块级自由格式内容（缩进代码 / 原生 HTML）能不能从这里起一块 */
  private static atBlockBoundary(blocks: MdBlock[]): boolean {
    if (blocks.length === 0) {
      return true;
    }
    const last: MdBlock = blocks[blocks.length - 1];
    return last.kind !== MdBlockKind.Paragraph && last.kind !== MdBlockKind.ListItem;
  }

  /** 上一行是不是空白行（首行算空白：文档一开头就缩进那是代码） */
  private static prevLineBlank(lines: string[], i: number): boolean {
    return i === 0 || lines[i - 1].trim().length === 0;
  }

  /** 这一行是不是 `<details>` 或 `<details open …>`（标签名必须正好是 details） */
  private static isDetailsStart(t: string): boolean {
    if (!t.startsWith('<details')) {
      return false;
    }
    const gt: number = t.indexOf('>');
    if (gt < 0) {
      return false;
    }
    const head: string = t.substring(1, gt).trim();
    const sp: number = head.indexOf(' ');
    const name: string = sp < 0 ? head : head.substring(0, sp);
    return name.toLowerCase() === 'details';
  }

  /** 开标签里有没有 `open` 属性（默认展开） */
  private static tagHasOpen(t: string): boolean {
    const gt: number = t.indexOf('>');
    const head: string = (gt > 0 ? t.substring(0, gt) : t).toLowerCase();
    return /(^|\s)open(\s|=|$)/.test(head);
  }

  /** `<summary …>…</summary>` 整行取标题文字；不是这一行返回 null */
  private static summaryText(cur: string): string | null {
    const low: string = cur.toLowerCase();
    if (!low.startsWith('<summary') || !low.endsWith('</summary>')) {
      return null;
    }
    const gt: number = cur.indexOf('>');
    if (gt < 0) {
      return '';
    }
    const inner: string = cur.substring(gt + 1, cur.length - 10).trim();
    // <summary><b>要点</b></summary>：标题留文字、脱掉标签，后面仍走行内解析
    return MdParser.scrubHtmlTags(inner);
  }

  /** 这些标签是**块级**的：行内不处理（否则会把整张表格吞成一行文本），留给块级路径或原样显示 */
  private static htmlBlockTag(name: string): boolean {
    const names: string[] = ['table', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th',
      'colgroup', 'col', 'div', 'p', 'section', 'article', 'aside', 'main', 'header',
      'footer', 'nav', 'details', 'summary', 'figure', 'figcaption', 'pre', 'blockquote',
      'ul', 'ol', 'li', 'dl', 'dt', 'dd', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
      'svg', 'canvas', 'iframe', 'video', 'audio', 'source', 'form', 'hr'];
    return names.indexOf(name) >= 0;
  }

  /**
   * 行内原生 HTML：`start` 指向 `<`。返回吃掉的字符数与产出片段。
   *
   * **认不出来就返回 consumed=0**，让 `<` 原样留作正文——宁可显示标签文本，
   * 也不猜一段结构（块级 HTML 的 `<table>` 就是这么留在文本里的）。
   */
  private static htmlAt(src: string, start: number, bold: boolean, italic: boolean,
                        strike: boolean, code: boolean): HtmlHit {
    const n: number = src.length;
    if (start + 2 >= n || src.charAt(start) !== '<') {
      return missHtml();
    }
    // HTML 注释：整段丢弃（写在源码里不是为了给人看）
    if (src.substring(start, start + 4) === '<!--') {
      const cEnd: number = src.indexOf('-->', start + 4);
      if (cEnd < 0) {
        return missHtml();
      }
      return { consumed: cEnd + 3 - start, items: [] } as HtmlHit;
    }
    const name: string = MdParser.htmlTagName(src, start);
    if (name.length === 0 || MdParser.htmlBlockTag(name)) {
      return missHtml();
    }
    const gt: number = src.indexOf('>', start + 1);
    if (gt < 0 || gt - start > 300) {
      return missHtml();
    }
    const attrs: string = src.substring(start + 1 + name.length, gt);
    const selfClosed: boolean = src.charAt(gt - 1) === '/';

    // ── 没有内容的标签 ──
    if (name === 'br') {
      return { consumed: gt + 1 - start, items: [inlineOfPlain('\n')] } as HtmlHit;
    }
    if (name === 'wbr') {
      return { consumed: gt + 1 - start, items: [] } as HtmlHit;
    }
    if (name === 'img') {
      const imgSrc: string = MdParser.htmlAttr(attrs, 'src');
      if (imgSrc.length === 0) {
        return missHtml();
      }
      return {
        consumed: gt + 1 - start,
        items: [inlineOf(MdInlineKind.Image, MdParser.htmlText(MdParser.htmlAttr(attrs, 'alt')),
          imgSrc, 0, bold, italic, strike, code)]
      } as HtmlHit;
    }

    let inner: string = '';
    let after: number = gt + 1;
    if (!selfClosed) {
      const closeAt: number = MdParser.htmlCloseAt(src, gt + 1, name);
      if (closeAt < 0) {
        return missHtml();                 // 找不到配对闭合 → 交给块级路径 / 原样显示
      }
      inner = src.substring(gt + 1, closeAt);
      const closeEnd: number = src.indexOf('>', closeAt);
      after = closeEnd < 0 ? closeAt : closeEnd + 1;
    }
    const consumed: number = after - start;

    // 脚本与样式：**整段丢弃**，不执行也不显示（渲染层没有 CSS/JS 执行环境）
    if (name === 'script' || name === 'style' || name === 'noscript' || name === 'template') {
      return { consumed: consumed, items: [] } as HtmlHit;
    }

    if (name === 'kbd' || name === 'samp' || name === 'var') {
      // 按键帽：等宽 + 底色（Span 不支持 padding，与行内代码一样用细空格撑开）
      return {
        consumed: consumed,
        items: [inlineOf(MdInlineKind.Key, MdParser.htmlText(inner), '', 0,
          bold, italic, strike, false)]
      } as HtmlHit;
    }
    if (name === 'mark') {
      return {
        consumed: consumed,
        items: [inlineOf(MdInlineKind.Mark, MdParser.htmlText(inner), '', 0,
          bold, italic, strike, code)]
      } as HtmlHit;
    }
    if (name === 'sub') {
      return {
        consumed: consumed,
        items: [inlineOf(MdInlineKind.Sub, MdParser.htmlText(inner), '', 0,
          bold, italic, strike, code)]
      } as HtmlHit;
    }
    if (name === 'sup') {
      return {
        consumed: consumed,
        items: [inlineOf(MdInlineKind.Sup, MdParser.htmlText(inner), '', 0,
          bold, italic, strike, code)]
      } as HtmlHit;
    }
    if (name === 'strong' || name === 'b') {
      return { consumed: consumed, items: MdParser.scan(inner, true, italic, strike, code) } as HtmlHit;
    }
    if (name === 'em' || name === 'i') {
      return { consumed: consumed, items: MdParser.scan(inner, bold, true, strike, code) } as HtmlHit;
    }
    if (name === 's' || name === 'del' || name === 'strike') {
      return { consumed: consumed, items: MdParser.scan(inner, bold, italic, true, code) } as HtmlHit;
    }
    if (name === 'code') {
      return { consumed: consumed, items: MdParser.scan(inner, bold, italic, strike, true) } as HtmlHit;
    }
    if (name === 'u' || name === 'ins') {
      const items: MdInline[] = MdParser.scan(inner, bold, italic, strike, code);
      for (let q = 0; q < items.length; q++) {
        items[q].kind = MdInlineKind.Under;
      }
      return { consumed: consumed, items: items } as HtmlHit;
    }
    if (name === 'a') {
      const href: string = MdParser.htmlAttr(attrs, 'href');
      if (href.length === 0) {
        return { consumed: consumed, items: MdParser.scan(inner, bold, italic, strike, code) } as HtmlHit;
      }
      return {
        consumed: consumed,
        items: [inlineOf(MdInlineKind.Link, MdParser.htmlText(inner), href, 0,
          bold, italic, strike, code)]
      } as HtmlHit;
    }
    if (name === 'ruby') {
      // <ruby>汉<rt>hàn</rt><rp>(</rp><rp>)</rp></ruby>
      // 扁平结构里做不了上下两层：基准文字照常产出，读音变成紧随其后的小号上移片段；
      // <rp> 是"不支持注音时显示的括号"，我们有注音，直接丢
      const base: string = MdParser.rubyBase(inner);
      const reading: string = MdParser.rubyReading(inner);
      const items: MdInline[] = MdParser.scan(base, bold, italic, strike, code);
      if (reading.length > 0) {
        items.push(inlineOf(MdInlineKind.Ruby, reading, '', 0, false, false, false, false));
      }
      return { consumed: consumed, items: items } as HtmlHit;
    }
    if (name === 'small') {
      // `<small>` 以前落到"脱标签留内容"，字号信息整个丢了（用户实测 8.1「小号字」
      // 和正文一样大）。这里给内容打上相对字号，正文与导出都按八成字号走。
      return {
        consumed: consumed,
        items: MdParser.setScale(MdParser.scan(inner, bold, italic, strike, code), 0.82)
      } as HtmlHit;
    }
    if (name === 'span' || name === 'font') {
      const boldInner: boolean = bold || MdParser.attrsBold(attrs);
      const items: MdInline[] = MdParser.scan(inner, boldInner, italic, strike, code);
      const color: string = MdParser.htmlColor(attrs);
      const bg: string = MdParser.htmlBgColor(attrs);
      const scale: number = MdParser.styleFontSizeEm(MdParser.htmlAttr(attrs, 'style'));
      if (color.length === 0 && bg.length === 0 && scale === 0) {
        return { consumed: consumed, items: items } as HtmlHit;
      }
      for (let q = 0; q < items.length; q++) {
        if (color.length > 0) {
          items[q].kind = MdInlineKind.Color;
          items[q].color = color;
        }
        // 背景只登记色值，**不改 kind**：彩色底 + 任意字色要能同时成立（徽章就是这型）
        if (bg.length > 0) {
          items[q].bg = bg;
        }
        if (scale > 0) {
          items[q].size = scale;
        }
        if (boldInner && !bold) {
          items[q].bold = true;
        }
      }
      return { consumed: consumed, items: items } as HtmlHit;
    }
    // 其它成对标签（abbr / cite / q / time / small / label / bdi …）：**脱标签留内容**
    return { consumed: consumed, items: MdParser.scan(inner, bold, italic, strike, code) } as HtmlHit;
  }

  /** 取标签名（小写）；不是字母开头（`<3`、`</`、`<!`）返回空串 */
  private static htmlTagName(src: string, start: number): string {
    let k: number = start + 1;
    if (k >= src.length || !MdParser.isAsciiLetter(src.charAt(k))) {
      return '';
    }
    const from: number = k;
    while (k < src.length) {
      const c: string = src.charAt(k);
      const lc: string = c.toLowerCase();
      if (MdParser.isAsciiLetter(lc) || (lc >= '0' && lc <= '9') || lc === '-') {
        k++;
      } else {
        break;
      }
    }
    return src.substring(from, k).toLowerCase();
  }

  private static isAsciiLetter(c: string): boolean {
    const lc: string = c.toLowerCase();
    return lc >= 'a' && lc <= 'z' && lc.length === 1;
  }

  /** 从 from 起找 `</name>` 的 `<` 下标（大小写不敏感）；没有返回 -1 */
  private static htmlCloseAt(src: string, from: number, name: string): number {
    const needle: string = '</' + name;
    // 整串只降一次：在循环里反复 toLowerCase 会把找闭合标签变成 O(n²)（长段落会卡）
    const lower: string = src.toLowerCase();
    let k: number = from;
    while (k + needle.length <= lower.length) {
      const at: number = lower.indexOf(needle, k);
      if (at < 0) {
        return -1;
      }
      const after: string = at + needle.length < src.length ? src.charAt(at + needle.length) : ' ';
      if (after === '>' || after === ' ' || after === '\t' || after === '/') {
        return at;
      }
      k = at + 1;
    }
    return -1;
  }

  /**
   * 读一个属性值（大小写不敏感，支持双引号 / 单引号 / 裸值）；没有返回空串。
   * 逐个候选试：`data-color="x" color="#f00"` 里第一个 `color` 是 `data-color` 的尾巴，
   * 只取第一次命中会把真正的颜色读成"没有"。
   */
  private static htmlAttr(attrs: string, key: string): string {
    const lower: string = attrs.toLowerCase();
    const needle: string = key.toLowerCase();
    let from: number = 0;
    while (from <= lower.length - needle.length) {
      const k: number = lower.indexOf(needle, from);
      if (k < 0) {
        return '';
      }
      from = k + 1;
      // 必须是独立属性名（前面是空白/串头/引号/等号），否则会匹配到 data-href / mycolor
      if (k > 0) {
        const prev: string = attrs.charAt(k - 1);
        if (prev !== ' ' && prev !== '\t' && prev !== '"' && prev !== '\'' && prev !== '=') {
          continue;
        }
      }
      let p: number = k + key.length;
      while (p < attrs.length && (attrs.charAt(p) === ' ' || attrs.charAt(p) === '\t')) {
        p++;
      }
      if (p >= attrs.length || attrs.charAt(p) !== '=') {
        continue;                          // 属性名后面没有 = —— 继续找下一个
      }
      p++;
      while (p < attrs.length && (attrs.charAt(p) === ' ' || attrs.charAt(p) === '\t')) {
        p++;
      }
      if (p >= attrs.length) {
        return '';
      }
      const quote: string = attrs.charAt(p);
      if (quote === '"' || quote === '\'') {
        const close: number = attrs.indexOf(quote, p + 1);
        if (close < 0) {
          return '';
        }
        return attrs.substring(p + 1, close).trim();
      }
      let end: number = p;
      while (end < attrs.length && attrs.charAt(end) !== ' ' && attrs.charAt(end) !== '\t') {
        end++;
      }
      return attrs.substring(p, end).trim();
    }
    return '';
  }

  /**
   * 从属性里取**十六进制**颜色：`color="#f00"` / `style="color:#ff0000; …"`。
   * 只放行 `#RGB` / `#RRGGBB` / `#AARRGGBB`，其余（red、rgb()、url()、含分号的注入串）
   * 一律当没有颜色——渲染层拿到的只能是色值，不可能是任意 CSS。
   */
  /**
   * 从 style 串里取一条声明的值。**两条讲究**：
   *  · 名字前不能是 `-`：否则 `background-color:#eee;color:#f00` 里会从
   *    `background-color:` 的 `color:` 处开始取，把背景色当成文字颜色（实测到的真错）；
   *  · 只认声明起点（行首或 `;` 之后，允许空白），不做子串匹配。
   */
  private static styleDecl(style: string, name: string): string {
    const low: string = style.toLowerCase();
    const key: string = name.toLowerCase() + ':';
    let from: number = 0;
    while (from < low.length) {
      const at: number = low.indexOf(key, from);
      if (at < 0) {
        return '';
      }
      const prev: string = at === 0 ? ';' : low.charAt(at - 1);
      // 声明起点只允许是行首或 `;` / 空白：这一条同时挡掉 `background-color:`
      // （它里面的 `color:` 前面是 `-`）与 `xcolor:` 这类粘连名
      if (prev === ';' || prev === ' ' || prev === '\t') {
        const semi: number = style.indexOf(';', at);
        return (semi < 0 ? style.substring(at + key.length) : style.substring(at + key.length, semi)).trim();
      }
      from = at + 1;
    }
    return '';
  }

  /** style 里的 font-weight：bold / bolder / 600~900 算粗体 */
  private static styleBold(style: string): boolean {
    const v: string = MdParser.styleDecl(style, 'font-weight').toLowerCase();
    if (v === 'bold' || v === 'bolder') {
      return true;
    }
    const n: number = Number(v);
    return !isNaN(n) && n >= 600;
  }

  /** 属性 + style 两路取字重（`<b>` 类标签走的是 bold 参数，这里是 span 上的 style） */
  private static attrsBold(attrs: string): boolean {
    const direct: string = MdParser.htmlAttr(attrs, 'font-weight');
    if (direct.length > 0) {
      const n: number = Number(direct);
      return direct.toLowerCase() === 'bold' || direct.toLowerCase() === 'bolder' || (!isNaN(n) && n >= 600);
    }
    return MdParser.styleBold(MdParser.htmlAttr(attrs, 'style'));
  }

  /**
   * 背景色（徽章、进度条底、彩色标签这类排版的最小可用子集）：
   * 实心十六进制直接放行；`url()` 画不出来不要；**渐变取第一个色标当实心近似底**。
   *
   * ⚠️ 渐变以前是"干脆没有底"，但那类写法几乎总是同时把字色设成白色
   * （`background:linear-gradient(…);color:#fff`）——底一丢就是**白字白底，整块看不见**
   * （用户实测 8.1「渐变标签」在正文里消失）。留个紫色底 chip，形状与可读性都保住。
   */
  private static htmlBgColor(attrs: string): string {
    const style: string = MdParser.htmlAttr(attrs, 'style');
    let raw: string = MdParser.styleDecl(style, 'background-color');
    if (raw.length === 0) {
      raw = MdParser.styleDecl(style, 'background');
    }
    if (raw.indexOf('url(') >= 0) {
      return '';
    }
    if (raw.indexOf('gradient') >= 0) {
      return MdParser.firstHexIn(raw);
    }
    // `background:#eee;padding:2px` 这类简写：取第一段是色值时才用
    const first: string = raw.split(' ')[0].trim();
    return MdParser.normalizeHexColor(first);
  }

  /** 串里第一个十六进制色值（渐变取首个色标用） */
  private static firstHexIn(s: string): string {
    const m: RegExpMatchArray | null = s.match(/#[0-9a-fA-F]{3}(?:[0-9a-fA-F]{3})?/);
    return m === null ? '' : MdParser.normalizeHexColor(m[0]);
  }

  /**
   * `font-size:.8em` / `font-size:80%` → 相对字号（0.8）；认不出或是 px 单位 → 0。
   * px 不接：正文本身要能调字号，写死像素会让这段在放大字号后与其它正文脱节。
   */
  private static styleFontSizeEm(style: string): number {
    const raw: string = MdParser.styleDecl(style, 'font-size');
    if (raw.length === 0) {
      return 0;
    }
    const v: string = raw.trim().toLowerCase();
    if (v.endsWith('em') && v.indexOf('px') < 0) {
      const n: number = parseFloat(v.substring(0, v.length - 2));
      if (!isNaN(n) && n > 0.3 && n <= 3) {
        return n;
      }
      return 0;
    }
    if (v.endsWith('%')) {
      const p: number = parseFloat(v.substring(0, v.length - 1));
      if (!isNaN(p) && p > 30 && p <= 300) {
        return p / 100;
      }
    }
    return 0;
  }

  /** 给一批片段打相对字号（已有字号的按乘法叠加，`<small>` 套 `<small>` 会更小） */
  private static setScale(items: MdInline[], scale: number): MdInline[] {
    for (let k = 0; k < items.length; k++) {
      const prev: number = items[k].size === undefined ? 1 : items[k].size as number;
      items[k].size = Math.round(prev * scale * 100) / 100;
    }
    return items;
  }

  private static htmlColor(attrs: string): string {
    let raw: string = MdParser.htmlAttr(attrs, 'color');
    if (raw.length === 0) {
      raw = MdParser.styleDecl(MdParser.htmlAttr(attrs, 'style'), 'color');
    }
    return MdParser.normalizeHexColor(raw.trim());
  }

  private static normalizeHexColor(raw: string): string {
    if (raw.length === 0 || raw.charAt(0) !== '#') {
      return '';
    }
    const digits: string = raw.substring(1);
    let ok: boolean = true;
    for (let k = 0; k < digits.length; k++) {
      const c: string = digits.charAt(k).toLowerCase();
      const isHex: boolean = (c >= 'a' && c <= 'f') || (c >= '0' && c <= '9');
      if (!isHex) {
        ok = false;
        break;
      }
    }
    if (!ok) {
      return '';
    }
    if (digits.length === 3) {
      // #f00 → #ff0000（ArkUI 的色值解析对三位并不一致，这里统一展开）
      return '#' + digits.charAt(0) + digits.charAt(0) + digits.charAt(1) + digits.charAt(1)
        + digits.charAt(2) + digits.charAt(2);
    }
    if (digits.length === 6 || digits.length === 8) {
      return raw;
    }
    return '';
  }

  /** `<ruby>` 里的读音（第一段 `<rt>…</rt>`）；没有返回空串 */
  private static rubyReading(inner: string): string {
    const open: number = inner.toLowerCase().indexOf('<rt');
    if (open < 0) {
      return '';
    }
    const gt: number = inner.indexOf('>', open);
    const close: number = inner.toLowerCase().indexOf('</rt>', gt + 1);
    if (gt < 0 || close < 0) {
      return '';
    }
    return MdParser.htmlText(inner.substring(gt + 1, close));
  }

  /** `<ruby>` 里的基准文字：去掉 `<rt>` / `<rp>` 两段附属内容，其余原样（仍可带行内标记） */
  private static rubyBase(inner: string): string {
    let out: string = '';
    let k: number = 0;
    while (k < inner.length) {
      if (inner.charAt(k) === '<') {
        const tag: string = MdParser.htmlTagName(inner, k);
        if (tag === 'rt' || tag === 'rp') {
          const closeAt: number = MdParser.htmlCloseAt(inner, k, tag);
          if (closeAt >= 0) {
            const closeEnd: number = inner.indexOf('>', closeAt);
            k = closeEnd < 0 ? closeAt : closeEnd + 1;
            continue;
          }
        }
      }
      out = out + inner.charAt(k);
      k++;
    }
    return out;
  }

  /**
   * HTML → 纯文本：跳过标签、解几个常见实体。
   * 按键帽 / 链接文字这类内容基本是纯文本，用这个把夹在中间的 `<b>` 之类剥掉。
   */
  private static htmlText(s: string): string {
    let out: string = '';
    let k: number = 0;
    while (k < s.length) {
      const c: string = s.charAt(k);
      if (c === '<') {
        const gt: number = s.indexOf('>', k);
        if (gt > k) {
          k = gt + 1;
          continue;
        }
      }
      if (c === '&') {
        const semi: number = s.indexOf(';', k);
        if (semi > k && semi - k <= 8) {
          const ent: string = s.substring(k + 1, semi);
          if (ent === 'amp') {
            out = out + '&';
          } else if (ent === 'lt') {
            out = out + '<';
          } else if (ent === 'gt') {
            out = out + '>';
          } else if (ent === 'quot') {
            out = out + '"';
          } else if (ent === 'apos' || ent === '#39') {
            out = out + '\'';
          } else if (ent === 'nbsp') {
            out = out + ' ';
          } else {
            out = out + s.substring(k, semi + 1);
          }
          k = semi + 1;
          continue;
        }
      }
      out = out + c;
      k++;
    }
    return out.trim();
  }

  /** 解析 `[label](href)`，start 指向 `[`。 */
  private static linkAt(src: string, start: number): LinkHit {
    let depth: number = 0;
    let close: number = -1;
    for (let k = start; k < src.length; k++) {
      const c: string = src.charAt(k);
      if (c === '[') {
        depth++;
      } else if (c === ']') {
        depth--;
        if (depth === 0) {
          close = k;
          break;
        }
      }
    }
    if (close < 0 || close + 1 >= src.length || src.charAt(close + 1) !== '(') {
      return missLink();
    }
    let end: number = -1;
    for (let k = close + 2; k < src.length; k++) {
      if (src.charAt(k) === ')') {
        end = k;
        break;
      }
    }
    if (end < 0) {
      return missLink();
    }
    let href: string = src.substring(close + 2, end).trim();
    const sp: number = href.indexOf(' ');
    if (sp > 0) {
      href = href.substring(0, sp);
    }
    const r: LinkHit = {
      hit: true,
      label: src.substring(start + 1, close),
      href: href,
      end: end + 1
    };
    return r;
  }

  /** 把正文里单独一行的 `[TOC]` 段落换成正文目录条目（见 parse() 里的注释） */
  private static expandToc(blocks: MdBlock[]): void {
    let at: number = -1;
    for (let k = 0; k < blocks.length; k++) {
      const b: MdBlock = blocks[k];
      if (b.kind === MdBlockKind.Paragraph && b.plain.trim().toUpperCase() === '[TOC]') {
        at = k;
        break;
      }
    }
    if (at < 0) {
      return;
    }
    const rebuilt: MdBlock[] = [];
    let n: number = 0;
    for (let k = 0; k < blocks.length; k++) {
      if (k === at) {
        // 条目层级 = 标题层级 - 1（h1 顶格，h2 缩进一级……）
        for (let q = at + 1; q < blocks.length; q++) {
          const h: MdBlock = blocks[q];
          if (h.kind !== MdBlockKind.Heading) {
            continue;
          }
          const title: string = h.plain.trim();
          if (title.length === 0) {
            continue;
          }
          const href: string = '#' + ((h.anchor !== undefined && h.anchor.length > 0) ? h.anchor : title);
          const link: MdInline[] = [inlineOf(MdInlineKind.Link, title, href, 0,
            false, false, false, false)];
          const item: MdBlock = MdBlockFactory.listItem(title, false, '-', MdTaskState.None,
            h.level > 1 ? h.level - 1 : 0, link, blocks.length, h.srcLine);
          // 自己起 id：数字序号会和后面的真块撞，撞了 ForEach 就复用错行
          item.id = 'btoc' + n;
          n++;
          rebuilt.push(item);
        }
        continue;
      }
      rebuilt.push(blocks[k]);
    }
    blocks.length = 0;
    for (let k = 0; k < rebuilt.length; k++) {
      blocks.push(rebuilt[k]);
    }
  }

  private static isEscapable(ch: string): boolean {
    const set: string = '\\`*_{}[]()#+-.!~=|>';
    return set.indexOf(ch) >= 0;
  }

  /** 命名实体表：CommonMark 收了两千多条，这里放日常文档真会遇到的；其余交给数字实体 */
  private static entityMap: Map<string, string> | null = null;

  private static entityName(nm: string): string {
    if (MdParser.entityMap === null) {
      const m: Map<string, string> = new Map<string, string>();
      m.set('amp', '&');
      m.set('lt', '<');
      m.set('gt', '>');
      m.set('quot', '"');
      m.set('apos', '\'');
      m.set('nbsp', String.fromCharCode(160));   // 不换行空格：直接写字面量在源码里看不出差别
      m.set('copy', '©');
      m.set('reg', '®');
      m.set('trade', '™');
      m.set('hellip', '…');
      m.set('mdash', '—');
      m.set('ndash', '–');
      m.set('middot', '·');
      m.set('laquo', '«');
      m.set('raquo', '»');
      m.set('ldquo', '“');
      m.set('rdquo', '”');
      m.set('lsquo', '‘');
      m.set('rsquo', '’');
      m.set('times', '×');
      m.set('divide', '÷');
      m.set('deg', '°');
      m.set('plusmn', '±');
      m.set('euro', '€');
      m.set('pound', '£');
      m.set('yen', '¥');
      m.set('cent', '¢');
      m.set('para', '¶');
      m.set('sect', '§');
      m.set('bull', '•');
      m.set('dagger', '†');
      m.set('larr', '←');
      m.set('rarr', '→');
      m.set('uarr', '↑');
      m.set('darr', '↓');
      m.set('harr', '↔');
      m.set('frac12', '½');
      m.set('frac34', '¾');
      MdParser.entityMap = m;
    }
    const v: string | undefined = MdParser.entityMap.get(nm);
    return v === undefined ? '' : v;
  }

  /** 位置 at（指向 `&`）起是不是一条实体；不是就 len=0，交给普通文字处理 */
  private static entityAt(src: string, at: number): EntityHit {
    const semi: number = src.indexOf(';', at + 1);
    // 半分号都没有、或名字长得离谱，那多半是正文里的 &（AT&T 这类）
    if (semi < 0 || semi - at > 12) {
      return missEntity();
    }
    const body: string = src.substring(at + 1, semi);
    if (body.length === 0) {
      return missEntity();
    }
    let text: string = '';
    if (body.charAt(0) === '#') {
      const rest: string = body.substring(1);
      const hex: boolean = rest.charAt(0) === 'x' || rest.charAt(0) === 'X';
      const digits: string = hex ? rest.substring(1) : rest;
      if (digits.length === 0 || !MdParser.isHexDigits(digits, hex)) {
        return missEntity();
      }
      const code: number = parseInt(digits, hex ? 16 : 10);
      if (isNaN(code) || code <= 0 || code > 0x10FFFF
        || (code >= 0xD800 && code <= 0xDFFF)) {
        return missEntity();
      }
      if (code < 0x10000) {
        text = String.fromCharCode(code);
      } else {
        // 辅助平面（emoji 那一段）自己拼代理对，不依赖 String.fromCodePoint
        const v: number = code - 0x10000;
        text = String.fromCharCode(0xD800 + (v >> 10)) + String.fromCharCode(0xDC00 + (v & 0x3FF));
      }
    } else {
      if (!MdParser.isAlphaOnly(body)) {
        return missEntity();
      }
      text = MdParser.entityName(body.toLowerCase());
      if (text.length === 0) {
        return missEntity();
      }
    }
    const hit: EntityHit = { len: semi - at + 1, text: text };
    return hit;
  }

  /** `<…>` 是不是自动链接：合法 scheme 的 URI，或一个邮箱（补 mailto:） */
  private static autolinkAt(src: string, at: number): AutolinkHit {
    const gt: number = src.indexOf('>', at + 1);
    if (gt < 0 || gt - at > 300) {
      return missAutolink();
    }
    const body: string = src.substring(at + 1, gt);
    if (body.length === 0 || /[\s<>]/.test(body)) {
      return missAutolink();
    }
    const colon: number = body.indexOf(':');
    if (colon > 0 && colon <= 32 && MdParser.isScheme(body.substring(0, colon))) {
      const h: AutolinkHit = { len: gt - at + 1, text: body, href: body };
      return h;
    }
    const dog: number = body.indexOf('@');
    if (dog > 0 && body.indexOf('.', dog) > dog + 1) {
      const h2: AutolinkHit = { len: gt - at + 1, text: body, href: 'mailto:' + body };
      return h2;
    }
    return missAutolink();
  }

  /** 协议名：字母开头，其后允许数字 / + / . / - （CommonMark 同一口径） */
  private static isScheme(s: string): boolean {
    if (s.length === 0) {
      return false;
    }
    const first: number = s.charCodeAt(0);
    if (!((first >= 65 && first <= 90) || (first >= 97 && first <= 122))) {
      return false;
    }
    for (let k = 1; k < s.length; k++) {
      const code: number = s.charCodeAt(k);
      const alpha: boolean = (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
      const digit: boolean = code >= 48 && code <= 57;
      if (!alpha && !digit && code !== 43 && code !== 45 && code !== 46) {
        return false;
      }
    }
    return true;
  }

  private static isHexDigits(s: string, hex: boolean): boolean {
    for (let k = 0; k < s.length; k++) {
      const code: number = s.charCodeAt(k);
      const digit: boolean = code >= 48 && code <= 57;
      const letter: boolean = hex && ((code >= 97 && code <= 102) || (code >= 65 && code <= 70));
      if (!digit && !letter) {
        return false;
      }
    }
    return true;
  }

  private static isAlphaOnly(s: string): boolean {
    for (let k = 0; k < s.length; k++) {
      const code: number = s.charCodeAt(k);
      const upper: boolean = code >= 65 && code <= 90;
      const lower: boolean = code >= 97 && code <= 122;
      if (!upper && !lower) {
        return false;
      }
    }
    return true;
  }

  /**
   * 从 from 起找**长度正好等于 delimLen** 的定界符串，跳过更长或更短的连串。
   * 原来用 `src.indexOf(delim, from)`，于是 `*斜 **粗** 斜*` 的单星外层会在内层双星的
   * 第一个星号处收口（内层被当正文，尾巴的 `* 斜*` 漏成字面星号）。
   */
  private static findEmphClose(src: string, ch: string, delimLen: number, from: number): number {
    const n: number = src.length;
    let k: number = from;
    while (k < n) {
      if (src.charAt(k) !== ch) {
        k++;
        continue;
      }
      let run: number = 0;
      while (k + run < n && src.charAt(k + run) === ch) {
        run++;
      }
      if (run === delimLen) {
        return k;
      }
      k += run;                       // 连串长度不符，整串跨过（里面的 * 不能当闭口）
    }
    return -1;
  }

  /**
   * 是否算"词内字符"（决定 `_` 能不能当强调定界符）。
   *
   * ⚠️ **必须连非 ASCII 字母一起算**：CommonMark 的 flanking 规则按 Unicode 字母/数字判定，
   * 只量 ASCII（a-zA-Z0-9_）会让中文里的下划线全部误变斜体 ——
   * `这是_一_个测试` 曾被排成斜体"一"，用户报的就是这条"下划线异常，没有区分斜体"
   * （GitHub / commonmark.js 都按字面输出）。ASCII 部分保留位运算走快路，其余交给正则。
   */
  private static isWordChar(ch: string): boolean {
    const code: number = ch.charCodeAt(0);
    const isDigit: boolean = code >= 48 && code <= 57;
    const isUpper: boolean = code >= 65 && code <= 90;
    const isLower: boolean = code >= 97 && code <= 122;
    if (isDigit || isUpper || isLower || ch === '_') {
      return true;
    }
    return code > 127 && /[\p{L}\p{N}]/u.test(ch);
  }

  // ────────────────────────── 块级匹配 ──────────────────────────

  private static pushQuoteOrCallout(blocks: MdBlock[], body: string[], depth: number,
    srcLine: number): void {
    let kind: MdCalloutKind = MdCalloutKind.None;
    let texts: string[] = body;
    if (body.length > 0) {
      const first: string = body[0].trim();
      if (first.startsWith('[!')) {
        const close: number = first.indexOf(']');
        if (close > 2) {
          kind = MdParser.calloutOf(first.substring(2, close));
          const rest: string[] = [];
          const tail: string = first.substring(close + 1).trim();
          if (tail.length > 0) {
            rest.push(tail);
          }
          for (let k = 1; k < body.length; k++) {
            rest.push(body[k]);
          }
          texts = rest;
        }
      }
    }
    const text: string = texts.join(' ').trim();
    if (text.length === 0) {
      return;
    }
    if (kind === MdCalloutKind.None) {
      const qb: MdBlock = MdBlockFactory.quote(depth, text, MdParser.parseInline(text), blocks.length);
      qb.srcLine = srcLine;
      blocks.push(qb);
    } else {
      const cb: MdBlock = MdBlockFactory.callout(kind, text, MdParser.parseInline(text), blocks.length);
      cb.srcLine = srcLine;
      blocks.push(cb);
    }
  }

  private static calloutOf(tag: string): MdCalloutKind {
    const t: string = tag.trim().toUpperCase();
    if (t === 'NOTE') {
      return MdCalloutKind.Note;
    }
    if (t === 'TIP') {
      return MdCalloutKind.Tip;
    }
    if (t === 'IMPORTANT') {
      return MdCalloutKind.Important;
    }
    if (t === 'WARNING') {
      return MdCalloutKind.Warning;
    }
    if (t === 'CAUTION') {
      return MdCalloutKind.Caution;
    }
    return MdCalloutKind.None;
  }

  private static quoteDepth(line: string): number {
    let n: number = 0;
    let k: number = 0;
    while (k < line.length) {
      const c: string = line.charAt(k);
      if (c === '>') {
        n++;
        k++;
      } else if (c === ' ') {
        k++;
      } else {
        break;
      }
    }
    return n > 0 ? n - 1 : 0;
  }

  private static isFence(t: string): boolean {
    const c: string = t.charAt(0);
    if (c !== '`' && c !== '~') {
      return false;
    }
    let n: number = 0;
    while (n < t.length && t.charAt(n) === c) {
      n++;
    }
    return n >= 3;
  }

  /** 围栏标记的字符数（``` → 3，```` → 4，~~~ → 3…）。用于匹配"同长或更长"的结束围栏。 */
  private static fenceLen(t: string): number {
    if (t.length === 0) {
      return 0;
    }
    const ch: string = t.charAt(0);
    let n: number = 0;
    while (n < t.length && t.charAt(n) === ch) {
      n++;
    }
    return n;
  }

  /** 围栏 info 串：反引号之后到行尾（VitePress / Shiki / Python-Markdown 的元数据都写在这里） */
  private static fenceInfo(t: string): string {
    const c: string = t.charAt(0);
    let n: number = 0;
    while (n < t.length && t.charAt(n) === c) {
      n++;
    }
    return t.substring(n).trim();
  }

  /**
   * 围栏语言。以前这里顺手把 `{}` 剥掉、只留第一个空格前的词，代价是
   * ` ```js{1,3-5} ` 的 `{1,3-5}` **在到达高亮行解析之前就被吃掉**——指定行高亮整条分支
   * 变成死代码，而 lang 还留下半个 `js{1,3-5` 让语法高亮一起失效。
   * 现在只负责交出语言，元数据交给 fenceHlLines()。
   */
  private static fenceLang(info: string): string {
    let tok: string = info;
    const sp: number = tok.indexOf(' ');
    if (sp > 0) {
      tok = tok.substring(0, sp);                 // 空格之后全是元数据
    }
    const brace: number = tok.indexOf('{');
    if (brace > 0) {
      tok = tok.substring(0, brace);              // js{1,3-5}：{ 之前才是语言
    }
    if (tok.startsWith('{')) {
      tok = tok.substring(1);                     // ```{python} / ```{.python}
      const e: number = tok.indexOf('}');
      if (e >= 0) {
        tok = tok.substring(0, e);
      }
    }
    if (tok.startsWith('.')) {
      tok = tok.substring(1);
    }
    // 光给行号不给语言的写法（```{1,3}）：那串数字不是语言，交空串让高亮走纯文本兜底
    if (/^[0-9,\-\s]*$/.test(tok)) {
      return '';
    }
    return tok;
  }

  /**
   * 图表语言别名归一。
   * 只比字面 id 的代价实测到了：渲染总谱 §6.22 的 graphviz 围栏写的是 ` ```dot `，
   * 于是整张图退化成代码块（用户报"graphviz 依旧是代码块"）；nomnoml 的常见扩展名
   * 是 `.nml`、mermaid 是 `mmd`、chart.js 有人写 `chartjs` / `chart.js`。
   * 不认识的照原样返回，交给代码高亮或纯文本，绝不硬认。
   */
  private static chartLangOf(l: string): string {
    if (l === 'dot' || l === 'gv' || l === 'viz' || l === 'graphviz-dot') {
      return 'graphviz';
    }
    // ZenUML 平时写在 ```mermaid 围栏里（首行 zenuml），也有直接拿语言名当围栏的
    if (l === 'zenuml') {
      return 'zenuml';
    }
    if (l === 'chartjs' || l === 'chart.js' || l === 'chart-js') {
      return 'chart';
    }
    // Vega-Lite 的常见写法：`vega-lite`（官方文档口径）、`vl`（缩写）、
    // 以及只写 `vega` 的（内容是 Lite 语法时同样能出图；纯 Vega 语法走同一条路）
    if (l === 'vega-lite' || l === 'vega_lite' || l === 'vega-lite-json' || l === 'vl' || l === 'vega') {
      return 'vega';
    }
    if (l === 'mmd' || l === 'mermaidjs' || l === 'mermaid-js') {
      return 'mermaid';
    }
    if (l === 'noml' || l === 'nml') {
      return 'nomnoml';
    }
    if (l === 'mindmap' || l === 'mm') {
      return 'markmap';
    }
    if (l === 'abcjs') {
      return 'abc';
    }
    return l;
  }

  /** PlantUML 的几种写法（puml / iuml 是官方文件扩展名） */
  private static isPumlLang(l: string): boolean {
    // 独立图种也允许**裸围栏名**：```nwdiag / ```salt / ```ditaa（不少人这么写，
    // 与 ```plantuml 里写 @startnwdiag 等价）
    return l === 'plantuml' || l === 'puml' || l === 'iuml' || l === 'startuml'
      || l === 'nwdiag' || l === 'salt' || l === 'ditaa';
  }

  /**
   * mermaid 块的首个有效行是不是 `zenuml`（插件的 detector 用的就是这条正则）。
   * 判定与插件保持一致，不做多余发挥：`; zenuml`、注释行开头的都不算。
   */
  private static isZenumlBody(src: string): boolean {
    const lines: string[] = src.split('\n');
    for (let k = 0; k < lines.length; k++) {
      const t: string = lines[k].trim();
      if (t.length === 0 || t.startsWith('%%')) {
        continue;
      }
      return /^zenuml\b/i.test(t);
    }
    return false;
  }

  /**
   * PlantUML 块该走哪条渲染路：'plantuml'（离线内核）| 'math'（KaTeX）| 'timeline'
   * （桥成 mermaid）| 'tree'（制表符文件树）| ''（原样代码块）。
   *
   * 集合是 **2026-10-14 用 @plantuml/core 1.2026.8 逐个实测**出来的（用户文档里的
   * 20 个图种）：内核里有渲染器的才交给它，否则页面上只会是一张
   * 「Diagram not supported by this release of PlantUML」错误卡。
   * 升级内核后要重测这张表（见 tools/upgrade-libs.js 的 plantuml()）。
   */
  private static pumlRouteOf(src: string): string {
    const head: string = MdParser.pumlHeadOf(src);
    if (head === 'math' || head === 'latex') {
      return 'math';
    }
    if (head === 'timeline') {
      return 'timeline';
    }
    if (head === 'files' || head === 'filetree') {
      return 'tree';
    }
    // 内核没有 nwdiag / salt / ditaa 渲染器，但三者都能自给自足地出图：
    //   · nwdiag → 桥成 mermaid flowchart（总线画法，复用已在跑的 mermaid）
    //   · salt   → render/salt.html（把 DSL 译成 HTML 线框，纯 CSS，无需第三方库）
    //   · ditaa  → render/ditaa.html（解析 ASCII 图元画 SVG 方框，纯 JS）
    if (head === 'nwdiag') {
      return 'nwdiag';
    }
    if (head === 'salt') {
      return 'salt';
    }
    if (head === 'ditaa') {
      return 'ditaa';
    }
    if (head.length === 0) {
      return '';
    }
    // startuml（全部 UML 家族：时序 / 用例 / 类 / 活动 / 组件 / 部署 / 状态 / ER / Archimate…）
    // 与这几个独立图种在内核里实测出图；其余未知头部保守留源码
    return head === 'uml' || head === 'mindmap' || head === 'wbs' || head === 'gantt'
      || head === 'json' || head === 'yaml' ? 'plantuml' : '';
  }

  /** 首个非空行里的 `@startXxx` 头部名（小写、去掉 @start 前缀；没有返回空串）。 */
  private static pumlHeadOf(src: string): string {
    const lines: string[] = src.split('\n');
    for (let k = 0; k < lines.length; k++) {
      const t: string = lines[k].trim().toLowerCase();
      if (t.length === 0) {
        continue;
      }
      const at: number = t.indexOf('@start');
      if (at < 0) {
        return '';
      }
      let h: string = t.substring(at + 6);
      const cut: number = h.search(/[^a-z]/);
      if (cut >= 0) {
        h = h.substring(0, cut);
      }
      return h;
    }
    return '';
  }

  /** 从 info 串里抠指定高亮行：`{1,3-5}`（VitePress / Shiki）、`hl_lines="1 3"`（Python-Markdown） */
  private static fenceHlLines(info: string): number[] {
    const out: number[] = [];
    const bAt: number = info.indexOf('{');
    const bEnd: number = info.lastIndexOf('}');
    if (bAt >= 0 && bEnd > bAt) {
      MdParser.collectLineSpec(info.substring(bAt + 1, bEnd), out);
    }
    const hlAt: number = info.indexOf('hl_lines');
    if (hlAt >= 0) {
      const q1: number = info.indexOf('"', hlAt);
      const q2: number = q1 >= 0 ? info.indexOf('"', q1 + 1) : -1;
      if (q1 >= 0 && q2 > q1) {
        MdParser.collectLineSpec(info.substring(q1 + 1, q2), out);
      } else {
        const k1: number = info.indexOf('[', hlAt);
        const k2: number = k1 >= 0 ? info.indexOf(']', k1 + 1) : -1;
        if (k1 >= 0 && k2 > k1) {
          MdParser.collectLineSpec(info.substring(k1 + 1, k2), out);
        }
      }
    }
    return out;
  }

  /** `1,3-5` / `1 3` / `2-4,7` 展开成 1 起的行号数组（去重；区间长度封顶防手滑写 1-99999） */
  private static collectLineSpec(spec: string, out: number[]): void {
    const toks: string[] = spec.replace(/[,;\s]+/g, ' ').trim().split(' ');
    for (let k = 0; k < toks.length; k++) {
      const seg: string = toks[k];
      if (seg.length === 0) {
        continue;
      }
      const dash: number = seg.indexOf('-');
      if (dash > 0) {
        const a: number = Number(seg.substring(0, dash));
        const b: number = Number(seg.substring(dash + 1));
        if (!isNaN(a) && !isNaN(b) && a > 0 && b >= a && b - a < 400) {
          for (let v = a; v <= b; v++) {
            if (out.indexOf(v) < 0) {
              out.push(v);
            }
          }
        }
      } else {
        const v: number = Number(seg);
        if (!isNaN(v) && v > 0 && out.indexOf(v) < 0) {
          out.push(v);
        }
      }
    }
  }

  private static headingInfo(t: string): HeadingHit {
    let n: number = 0;
    while (n < t.length && t.charAt(n) === '#') {
      n++;
    }
    if (n === 0 || n > 6) {
      return missHeading();
    }
    if (n < t.length && t.charAt(n) !== ' ') {
      return missHeading();
    }
    let text: string = t.substring(n).trim();
    // **先取尾部的显式锚点 `{#id}`，再剥结尾的闭合 # 序列**：顺序反了的话
    // `# 标题 ## {#id}` 会因为"# 不在行尾"而剥不掉闭合号，标题里就多出一串 ##
    const hit: HeadingHit = MdParser.takeAnchor(text, n);
    text = hit.text;
    // 去掉结尾的闭合 # 序列
    let end: number = text.length;
    while (end > 0 && text.charAt(end - 1) === '#') {
      end--;
    }
    if (end < text.length && (end === 0 || text.charAt(end - 1) === ' ')) {
      text = text.substring(0, end).trim();
    }
    hit.text = text;
    return hit;
  }

  /**
   * 从标题尾部取走**属性块** `{#intro}` / `{#bg .unnumbered}` / `{width=60%}`
   * （Pandoc header attributes，markdown-it-anchor / VitePress / MyST 同一套写法）。
   *
   * 不取走的话它会以字面文本显示在标题后面（用户清单第 22 项的"没渲染"就是这个）。
   * ⚠️ 上一版只认**光秃秃的 `{#id}`**：`## 背景 {#bg .unnumbered}` 因为多带一个类名就
   * 整块退回正文显示——"支持标题 ID"这句话就变成半真半假。现在按 pandoc 的词法认
   * `#id` / `.类名` / `key=value` 三种 token，**只在整块都像属性时才吃掉**，
   * 所以 `# 集合 { x }` 这种正常正文里的花括号不会被误吞。
   * id 只排除会破坏 HTML id 的字符，**不限制成 ASCII**：中文锚点（`{#语法}`）在 HTML5
   * 里是合法 id。
   */
  private static takeAnchor(text: string, level: number): HeadingHit {
    const tail: string = text.trim();
    if (tail.length > 3 && tail.endsWith('}')) {
      // `{{#sec-a}}` 是 Typora / VS Code 那套 anchor 插件的写法，和 pandoc 的 `{#sec-a}`
      // 同义；以前双花括号里带个 `}` 会被属性词法拒掉、整串留在标题里显示。
      const dbl: number = tail.lastIndexOf('{{');
      if (tail.endsWith('}}') && dbl > 0 && tail.charAt(dbl - 1) === ' '
        && tail.indexOf('}}') > dbl + 1) {
        const inner: string = tail.substring(dbl + 2, tail.length - 2).trim();
        const at2: AttrTail = MdParser.attrTailOf(inner.charAt(0) === '#' ? inner : '#' + inner);
        if (at2.hit) {
          return { hit: true, level: level, text: tail.substring(0, dbl).trim(), id: at2.id };
        }
      }
      const open: number = tail.lastIndexOf('{');
      if (open > 0 && tail.charAt(open - 1) === ' ') {
        const at: AttrTail = MdParser.attrTailOf(tail.substring(open + 1, tail.length - 1));
        if (at.hit) {
          return { hit: true, level: level, text: tail.substring(0, open).trim(), id: at.id };
        }
      }
    }
    return { hit: true, level: level, text: text, id: '' };
  }

  /**
   * pandoc 属性块词法：`#id` / `.class` / `key=value` 三种 token，空白分隔。
   * 只要有一个 token 不属于这三类就判**不是属性块**（hit=false），调用侧原样保留文本。
   */
  private static attrTailOf(inner: string): AttrTail {
    const out: AttrTail = { hit: false, id: '', classes: [], attrs: [] };
    const s: string = inner.trim();
    if (s.length === 0 || s.indexOf('{') >= 0 || s.indexOf('}') >= 0) {
      return out;
    }
    const toks: string[] = s.split(/\s+/);
    let seen: boolean = false;
    for (let k = 0; k < toks.length; k++) {
      const tok: string = toks[k];
      if (tok.length === 0) {
        continue;
      }
      const c: string = tok.charAt(0);
      if (c === '#') {
        const id: string = tok.substring(1);
        if (id.length === 0 || /[<>&"'\s\\]/.test(id)) {
          return out;
        }
        out.id = id;
      } else if (c === '.') {
        const cls: string = tok.substring(1);
        if (cls.length === 0 || /[<>&"'\s\\{}]/.test(cls)) {
          return out;
        }
        out.classes.push(cls);
      } else if (MdParser.ATTR_KV.test(tok)) {
        out.attrs.push(tok);            // key=value：吃掉不显示，渲染层没有对应的能力
      } else {
        return out;
      }
      seen = true;
    }
    out.hit = seen;
    return out;
  }
  private static readonly ATTR_KV: RegExp = /^[A-Za-z_:][A-Za-z0-9_:.-]*=\S+$/;

  /** 属性块里是否带某个类名（`::: {#x .details}` → 折叠面板） */
  private static hasClass(at: AttrTail, name: string): boolean {
    for (let k = 0; k < at.classes.length; k++) {
      if (at.classes[k].toLowerCase() === name) {
        return true;
      }
    }
    return false;
  }

  private static setextLevel(underline: string): number {
    if (underline.length < 2) {
      return 0;
    }
    const c: string = underline.charAt(0);
    if (c !== '=' && c !== '-') {
      return 0;
    }
    for (let k = 0; k < underline.length; k++) {
      if (underline.charAt(k) !== c) {
        return 0;
      }
    }
    return c === '=' ? 1 : 2;
  }

  private static isDivider(t: string): boolean {
    const c: string = t.charAt(0);
    if (c !== '-' && c !== '*' && c !== '_') {
      return false;
    }
    let count: number = 0;
    for (let k = 0; k < t.length; k++) {
      const ch: string = t.charAt(k);
      if (ch === c) {
        count++;
      } else if (ch !== ' ' && ch !== '\t') {
        return false;
      }
    }
    return count >= 3;
  }

  private static noteDef(t: string): NoteDefHit {
    if (!t.startsWith('[^')) {
      return missNote();
    }
    const close: number = t.indexOf(']');
    if (close < 3 || close + 1 >= t.length || t.charAt(close + 1) !== ':') {
      return missNote();
    }
    const label: string = t.substring(2, close).trim();
    if (label.length === 0) {
      return missNote();
    }
    const r: NoteDefHit = { hit: true, label: label, body: t.substring(close + 2).trim() };
    return r;
  }

  private static isTableDelimiter(t: string): boolean {
    if (t.indexOf('-') < 0) {
      return false;
    }
    let dashes: number = 0;
    for (let k = 0; k < t.length; k++) {
      const c: string = t.charAt(k);
      if (c === '-') {
        dashes++;
      } else if (c !== '|' && c !== ':' && c !== ' ' && c !== '\t') {
        return false;
      }
    }
    return dashes > 0;
  }

  /**
   * 按**未转义**的 `|` 切列。
   * 以前直接 `s.split('|')`，于是文档里按 GFM 惯例写的 `\|`（渲染文档 §3.1 和 §13 都把它
   * 当成"单元格要显示竖线"的标准解法）照样断列——`| `a \| b` | 尾 |` 裂成三格，
   * 表头四列的表格被撑歪，反斜杠还留在文字里。
   */
  private static splitRow(t: string): string[] {
    let s: string = t.trim();
    if (s.startsWith('|')) {
      s = s.substring(1);
    }
    if (s.endsWith('|') && !MdParser.pipeEscaped(s, s.length - 1)) {
      s = s.substring(0, s.length - 1);
    }
    const out: string[] = [];
    let cur: string = '';
    for (let k = 0; k < s.length; k++) {
      const c: string = s.charAt(k);
      if (c !== '|') {
        cur += c;
        continue;
      }
      if (!MdParser.pipeEscaped(s, k)) {
        out.push(cur.trim());
        cur = '';
        continue;
      }
      // 转义的竖线：把那层反斜杠退掉，竖线本身留作正文（行内解析会当普通字符处理）
      cur = cur.substring(0, cur.length - 1) + '|';
    }
    out.push(cur.trim());
    return out;
  }

  /** 位置 at 上的竖线是否被反斜杠转义（连续反斜杠要数奇偶：`\\|` 是分隔符，`\|` 是内容） */
  private static pipeEscaped(s: string, at: number): boolean {
    let bs: number = 0;
    let k: number = at - 1;
    while (k >= 0 && s.charAt(k) === '\\') {
      bs++;
      k--;
    }
    return bs % 2 === 1;
  }

  private static delimiterAligns(t: string): number[] {
    const cells: string[] = MdParser.splitRow(t);
    const out: number[] = [];
    for (let k = 0; k < cells.length; k++) {
      const c: string = cells[k].trim();
      const left: boolean = c.startsWith(':');
      const right: boolean = c.endsWith(':');
      if (left && right) {
        out.push(1);
      } else if (right) {
        out.push(2);
      } else {
        out.push(0);
      }
    }
    return out;
  }

  private static listInfo(line: string): ListHit {
    const indentSpaces: number = MdParser.leadingSpaces(line);
    const t: string = line.trim();
    if (t.length === 0) {
      return missList();
    }
    const c0: string = t.charAt(0);
    let ordered: boolean = false;
    let marker: string = '';
    let rest: string = '';

    if (c0 === '-' || c0 === '*' || c0 === '+') {
      // `-abc` / `*abc` 不是列表项，需要标记后跟空白
      if (t.length > 1 && t.charAt(1) !== ' ' && t.charAt(1) !== '\t') {
        return missList();
      }
      marker = c0;
      rest = t.substring(1).trim();
    } else {
      let k: number = 0;
      while (k < t.length && MdParser.isDigit(t.charAt(k))) {
        k++;
      }
      if (k === 0 || k > 9 || k >= t.length) {
        return missList();
      }
      const sep: string = t.charAt(k);
      if (sep !== '.' && sep !== ')') {
        return missList();
      }
      if (k + 1 < t.length && t.charAt(k + 1) !== ' ' && t.charAt(k + 1) !== '\t') {
        return missList();
      }
      marker = t.substring(0, k + 1);
      rest = t.substring(k + 1).trim();
      ordered = true;
    }

    let task: number = MdTaskState.None;
    if (rest.length >= 3 && rest.charAt(0) === '[' && rest.charAt(2) === ']') {
      const mark: string = rest.charAt(1);
      if (mark === ' ') {
        task = MdTaskState.Todo;
        rest = rest.substring(3).trim();
      } else if (mark === 'x' || mark === 'X') {
        task = MdTaskState.Done;
        rest = rest.substring(3).trim();
      }
    }

    const r: ListHit = {
      hit: true,
      ordered: ordered,
      marker: marker,
      text: rest,
      spaces: indentSpaces,
      task: task
    };
    return r;
  }

  private static leadingSpaces(line: string): number {
    let n: number = 0;
    while (n < line.length && line.charAt(n) === ' ') {
      n++;
    }
    return n;
  }

  private static isDigit(ch: string): boolean {
    const code: number = ch.charCodeAt(0);
    return code >= 48 && code <= 57;
  }

  /** 是否是一个新的块起始（用于终止段落与列表续行的收集）。 */
  private static isBlockStart(line: string): boolean {
    const t: string = line.trim();
    if (t.length === 0) {
      return true;
    }
    if (MdParser.isFence(t)) {
      return true;
    }
    if (t.startsWith('>')) {
      return true;
    }
    if (MdParser.headingInfo(t).hit) {
      return true;
    }
    if (MdParser.isDivider(t)) {
      return true;
    }
    if (MdParser.noteDef(t).hit) {
      return true;
    }
    if (MdParser.listInfo(line).hit) {
      return true;
    }
    return false;
  }

  /** 把行内片段里的脚注引用替换成序号。 */
  /**
   * pandoc 图表编号：给带 `{#fig:x}` 锚点的图片按**文档顺序**编号，并把正文里的
   * `@fig:x` 交叉引用替换成「图 N」。
   *
   * 编号写回图片的替代文字（`图 1：原替代文字`）——阅读页的图注与导出 HTML 的图注
   * 都取这段文字，两端口径天然一致。锚点是显式声明的（没写 `{#fig:}` 的图片不编号），
   * 所以不会出现"随手插张图被自动编号"的意外。
   */
  private static numberFigures(blocks: MdBlock[]): void {
    const nums: Map<string, number> = new Map<string, number>();
    let seq: number = 0;
    // 第一遍：按文档顺序编号
    for (let b = 0; b < blocks.length; b++) {
      const inls: MdInline[] = blocks[b].inlines;
      for (let k = 0; k < inls.length; k++) {
        const it: MdInline = inls[k];
        const raw: string | undefined = it.figId;
        if (it.kind !== MdInlineKind.Image || raw === undefined || raw.length === 0) {
          continue;
        }
        const key: string = MdParser.figKeyOf(raw);
        if (key.length === 0 || nums.has(key)) {
          continue;
        }
        seq++;
        nums.set(key, seq);
        it.text = '图 ' + seq + '：' + it.text;
      }
    }
    if (seq === 0) {
      return;
    }
    // 第二遍：正文里的 @fig:x → 图 N（只在 Plain 片段里替换）
    for (let b = 0; b < blocks.length; b++) {
      const inls2: MdInline[] = blocks[b].inlines;
      for (let k = 0; k < inls2.length; k++) {
        const it2: MdInline = inls2[k];
        if (it2.kind !== MdInlineKind.Plain || it2.text.indexOf('@fig:') < 0) {
          continue;
        }
        let out: string = it2.text;
        let guard: number = 0;
        while (guard < 32) {
          guard++;
          const at: number = out.indexOf('@fig:');
          if (at < 0) {
            break;
          }
          let end: number = at + 5;
          while (end < out.length && /[\w.-]/.test(out.charAt(end))) {
            end++;
          }
          const key2: string = out.substring(at + 5, end);
          const n: number | undefined = nums.get(key2);
          if (n === undefined) {
            // 找不到锚点：留原文（宁可显示 @fig:xxx，也别瞎编编号）
            const after: string = out.substring(end);
            const head: string = out.substring(0, at) + '@fig:';
            out = head + '\u0001' + key2 + after;
            continue;
          }
          out = out.substring(0, at) + '图 ' + n + out.substring(end);
        }
        // 还原没找到锚点的占位符
        it2.text = out.split('\u0001').join('');
      }
    }
  }

  /**
   * 锚点键归一：`{#fig:x}` / `{#x}` / `@fig:x` 三种写法都归到同一个键 `x`。
   * ⚠️ 两遍扫描的键必须同源——第一遍从 `{#fig:flow}` 取到 `fig:flow`、
   * 第二遍从 `@fig:flow` 取到 `flow`，不归一就永远匹配不上（实测第一次就是这么漏的）。
   */
  private static figKeyOf(raw: string): string {
    let k: string = raw.trim();
    if (k.startsWith('#')) {
      k = k.substring(1);
    }
    if (k.startsWith('fig:')) {
      k = k.substring(4);
    }
    return k;
  }

  private static resolveNoteRefs(blocks: MdBlock[], index: Map<string, number>): void {
    for (let k = 0; k < blocks.length; k++) {
      const list: MdInline[] = blocks[k].inlines;
      for (let j = 0; j < list.length; j++) {
        if (list[j].kind === MdInlineKind.FootnoteRef) {
          const no: number | undefined = index.get(list[j].text);
          list[j].num = no !== undefined ? no : 0;
        }
      }
      const rows: MdTableRow[] = blocks[k].rows;
      for (let r = 0; r < rows.length; r++) {
        for (let c = 0; c < rows[r].cells.length; c++) {
          const cell: MdInline[] = rows[r].cells[c];
          for (let j = 0; j < cell.length; j++) {
            if (cell[j].kind === MdInlineKind.FootnoteRef) {
              const no: number | undefined = index.get(cell[j].text);
              cell[j].num = no !== undefined ? no : 0;
            }
          }
        }
      }
    }
  }

  /** 字数统计：中日韩按字计，西文按词计；同时统计各类块数量。 */
  private static collect(blocks: MdBlock[]): MdStat {
    let charCount: number = 0;
    let wordCount: number = 0;
    let headingCount: number = 0;
    let codeBlockCount: number = 0;
    let tableCount: number = 0;

    for (let k = 0; k < blocks.length; k++) {
      const b: MdBlock = blocks[k];
      if (b.kind === MdBlockKind.Heading) {
        headingCount++;
      } else if (b.kind === MdBlockKind.Code) {
        codeBlockCount++;
      } else if (b.kind === MdBlockKind.Table) {
        tableCount++;
      }
      const counted: number[] = MdParser.countText(b.plain);
      charCount += counted[0];
      wordCount += counted[1];
    }

    const r: MdStat = {
      charCount: charCount,
      wordCount: wordCount,
      headingCount: headingCount,
      codeBlockCount: codeBlockCount,
      tableCount: tableCount
    };
    return r;
  }

  /** 返回 [字符数(不含空白), 字数] */
  private static countText(text: string): number[] {
    let chars: number = 0;
    let words: number = 0;
    let inWord: boolean = false;
    for (let k = 0; k < text.length; k++) {
      const ch: string = text.charAt(k);
      const code: number = ch.charCodeAt(0);
      const isSpace: boolean = ch === ' ' || ch === '\n' || ch === '\t';
      if (isSpace) {
        inWord = false;
        continue;
      }
      chars++;
      if (MdParser.isCjk(code)) {
        words++;
        inWord = false;
      } else if (MdParser.isWordChar(ch)) {
        if (!inWord) {
          words++;
          inWord = true;
        }
      } else {
        inWord = false;
      }
    }
    const r: number[] = [chars, words];
    return r;
  }

  private static isCjk(code: number): boolean {
    const common: boolean = code >= 0x4E00 && code <= 0x9FFF;
    const ext: boolean = code >= 0x3400 && code <= 0x4DBF;
    const compat: boolean = code >= 0xF900 && code <= 0xFAFF;
    const kana: boolean = code >= 0x3040 && code <= 0x30FF;
    const hangul: boolean = code >= 0xAC00 && code <= 0xD7AF;
    return common || ext || compat || kana || hangul;
  }
}
