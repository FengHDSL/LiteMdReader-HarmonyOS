/**
 * LiteMdReader · Markdown 解析器
 * ===============================
 *
 * 纯 ArkTS 实现，不依赖任何三方库（HarmonyOS SDK 26 并未内置 Markdown 组件，
 * 已通过检索 `component/` 目录确认——因此渲染必须自研）。
 *
 * 支持的语法：
 *   块级：ATX 标题（#…######）、Setext 标题（=== / ---）、围栏代码块（``` / ~~~，含语言）、
 *         段落、引用（>，支持层级）、GFM 提示块（[!NOTE] 等五种）、
 *         无序 / 有序列表（缩进层级）、任务列表（- [ ] / - [x]）、
 *         GFM 表格（含列对齐）、分割线、GFM 脚注定义（[^label]: 内容）
 *   行内：粗体、斜体、粗斜体、删除线、行内代码、链接、图片、高亮（==…==）、
 *         脚注引用（[^label]）、反斜杠转义
 *
 * 刻意不支持（v1 范围）：
 *   行内 HTML（按纯文本显示）、数学公式（KaTeX 无法在 ArkTS 侧渲染）、
 *   缩进代码块（4 空格）、多文件文档。
 */

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
  MdTableRow,
  MdTaskState
} from './MdTypes';
import { isEmojiCodeChar, lookupEmoji } from './Emoji';
import { MathLite } from './MathLite';

/** 匹配结果：标题 */
interface HeadingHit {
  hit: boolean;
  level: number;
  text: string;
}

/** 匹配结果：列表项 */
interface ListHit {
  hit: boolean;
  ordered: boolean;
  marker: string;
  text: string;
  indent: number;
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

function missHeading(): HeadingHit {
  const r: HeadingHit = { hit: false, level: 0, text: '' };
  return r;
}

function missList(): ListHit {
  const r: ListHit = { hit: false, ordered: false, marker: '', text: '', indent: 0, task: MdTaskState.None };
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
    const b: MdBlock = {
      id: 'b' + id,
      kind: MdBlockKind.Math,
      level: 0,
      lang: '',
      code: latex,
      codeLines: [],
      inlines: [],
      plain: latex,
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

export class MdParser {
  /** 链接引用表（[标识]: 地址），parse() 预收集、scan() 查询 */
  private static refLabels: string[] = [];
  private static refHrefs: string[] = [];

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

  /** 解析整篇文档。 */
  static parse(source: string): MdParseResult {
    const normalized: string = source.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/\t/g, '    ');
    // ── 预收集链接引用定义：`[标识]: 地址`（从正文剔除，不参与块级解析） ──
    MdParser.refLabels = [];
    MdParser.refHrefs = [];
    const rawLines: string[] = normalized.split('\n');
    const kept: string[] = [];
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
      }
    }
    const lines: string[] = kept;
    const blocks: MdBlock[] = [];

    const noteLabels: string[] = [];
    const noteBodies: string[] = [];

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

    while (i < lines.length) {
      const raw: string = lines[i];
      const t: string = raw.trim();

      if (t.length === 0) {
        i++;
        continue;
      }

      // ── 围栏代码块 ────────────────────────────────────────────────
      if (MdParser.isFence(t)) {
        const lang: string = MdParser.fenceLang(t);
        const fenceLine: number = i;
        const body: string[] = [];
        i++;
        while (i < lines.length && !MdParser.isFence(lines[i].trim())) {
          body.push(lines[i]);
          i++;
        }
        if (i < lines.length) {
          i++;
        }
        const langLower: string = lang.toLowerCase();
        if (langLower === 'mermaid' || langLower === 'markmap' || langLower === 'echarts'
          || langLower === 'abc' || langLower === 'graphviz' || langLower === 'flowchart') {
          blocks.push(MdBlockFactory.chart(lang, body, blocks.length, fenceLine));
        } else {
          blocks.push(MdBlockFactory.code(lang, body, blocks.length));
        }
        continue;
      }

      // ── 折叠细节块 <details><summary>…</summary>…</details> ──
      if (t.startsWith('<details>')) {
        const detailsStart: number = i;
        const bodyLines: string[] = [];
        let summary: string = '';
        let inBody: boolean = false;
        i++;
        while (i < lines.length) {
          const cur: string = lines[i].trim();
          if (cur.startsWith('<summary>') && cur.endsWith('</summary>')) {
            summary = cur.substring(9, cur.length - 10).trim();
          } else if (cur === '</details>') {
            i++;
            break;
          } else {
            if (cur.length > 0) {
              bodyLines.push(cur);
            }
          }
          i++;
        }
        blocks.push(MdBlockFactory.details(summary, bodyLines.join('\n'), blocks.length, detailsStart));
        continue;
      }

      // ── 数学公式块 $$...$$（自绘子集渲染） ────────────────────────
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
          blocks.push(MdBlockFactory.math(latex, blocks.length, mathStart));
        }
        continue;
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
        blocks.push(MdBlockFactory.divider(blocks.length));
        i++;
        continue;
      }

      // ── ATX 标题 ──────────────────────────────────────────────────
      const head: HeadingHit = MdParser.headingInfo(t);
      if (head.hit) {
        headingSeq++;
        blocks.push(MdBlockFactory.heading(head.level, head.text, headingSeq,
          MdParser.parseInline(head.text), blocks.length));
        i++;
        continue;
      }

      // ── 引用 / 提示块 ─────────────────────────────────────────────
      if (t.startsWith('>')) {
        let depth: number = 0;
        const body: string[] = [];
        let first: boolean = true;
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          const cur: string = lines[i].trim();
          const d: number = MdParser.quoteDepth(cur);
          if (first) {
            depth = d;
            first = false;
          }
          let s: string = cur;
          while (s.startsWith('>')) {
            s = s.substring(1);
            if (s.startsWith(' ')) {
              s = s.substring(1);
            }
          }
          body.push(s);
          i++;
        }
        MdParser.pushQuoteOrCallout(blocks, body, depth);
        continue;
      }

      // ── 表格 ──────────────────────────────────────────────────────
      if (t.indexOf('|') >= 0 && i + 1 < lines.length && MdParser.isTableDelimiter(lines[i + 1].trim())) {
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
        blocks.push(MdBlockFactory.table(rows, aligns, blocks.length));
        continue;
      }

      // ── 列表 ──────────────────────────────────────────────────────
      const listHit: ListHit = MdParser.listInfo(raw);
      if (listHit.hit) {
        while (i < lines.length) {
          const cur: ListHit = MdParser.listInfo(lines[i]);
          if (!cur.hit) {
            break;
          }
          // 条目自己的源码行号（任务列表勾选要改写原文这一行）
          const itemLine: number = i;
          let text: string = cur.text;
          const baseIndent: number = MdParser.leadingSpaces(lines[i]);
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
          blocks.push(MdBlockFactory.listItem(text, cur.ordered, cur.marker, cur.task, cur.indent,
            MdParser.parseInline(text), blocks.length, itemLine));
        }
        continue;
      }

      // ── Setext 标题 ───────────────────────────────────────────────
      if (i + 1 < lines.length) {
        const underline: string = lines[i + 1].trim();
        const level: number = MdParser.setextLevel(underline);
        if (level > 0) {
          headingSeq++;
          blocks.push(MdBlockFactory.heading(level, t, headingSeq, MdParser.parseInline(t), blocks.length));
          i += 2;
          continue;
        }
      }

      // ── 段落 ──────────────────────────────────────────────────────
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
      const paraText: string = para.join(' ');
      blocks.push(MdBlockFactory.paragraph(paraText, MdParser.parseInline(paraText), blocks.length));
    }

    // ── 脚注引用回填 + 文末注释区 ──────────────────────────────────
    const noteIndex: Map<string, number> = new Map();
    for (let k = 0; k < noteLabels.length; k++) {
      if (!noteIndex.has(noteLabels[k])) {
        noteIndex.set(noteLabels[k], k + 1);
      }
    }
    MdParser.resolveNoteRefs(blocks, noteIndex);

    const notes: MdNote[] = [];
    if (noteLabels.length > 0) {
      blocks.push(MdBlockFactory.divider(blocks.length));
      headingSeq++;
      blocks.push(MdBlockFactory.heading(2, '注释', headingSeq,
        MdParser.parseInline('注释'), blocks.length));
      for (let k = 0; k < noteLabels.length; k++) {
        const inlines: MdInline[] = MdParser.parseInline(noteBodies[k]);
        const noteBlockIndex: number = blocks.length;
        blocks.push(MdBlockFactory.noteItem(noteBodies[k], k + 1, inlines, noteBlockIndex));
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

    // ── 目录与统计 ────────────────────────────────────────────────
    const outline: MdHeading[] = [];
    for (let k = 0; k < blocks.length; k++) {
      const b: MdBlock = blocks[k];
      if (b.kind === MdBlockKind.Heading) {
        const item: MdHeading = {
          level: b.level,
          text: b.plain,
          blockIndex: k,
          seq: b.headingSeq
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

  // ────────────────────────── 行内解析 ──────────────────────────

  /** 解析行内 Markdown。样式标志位会向下继承，因此无需嵌套节点。 */
  static parseInline(src: string): MdInline[] {
    return MdParser.scan(src, false, false, false, false);
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

      // 行内数学 $...$（$$ 归块级；开 $ 后不能紧跟空格、闭 $ 前不能是空格，避免误伤货币写法）
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
            out.push(inlineOf(MdInlineKind.MathInline, MathLite.inlineText(content), '', 0,
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
          out.push(inlineOf(MdInlineKind.Image, img.label, img.href, 0, bold, italic, strike, code));
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

      // 裸 URL 自动链接（http:// 或 https:// 开头，吃到空白/全角标点为止）
      if (c === 'h' && (src.startsWith('http://', i) || src.startsWith('https://', i))) {
        let k: number = i;
        while (k < n) {
          const ch: string = src.charAt(k);
          if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '）' || ch === '》'
            || ch === '，' || ch === '。' || ch === '；' || ch === '"' || ch === '\'') {
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
        const delim: string = isDouble ? c + c : c;
        const from: number = i + delim.length;
        // 下划线必须位于词边界，否则 snake_case 会被误判成斜体
        const prevOk: boolean = c !== '_' || i === 0 || !MdParser.isWordChar(src.charAt(i - 1));
        const nextOk: boolean = from < n && src.charAt(from) !== ' ' && src.charAt(from) !== c;
        if (prevOk && nextOk) {
          const end: number = src.indexOf(delim, from);
          if (end > from) {
            buf = MdParser.flush(out, buf, bold, italic, strike, code);
            const kids: MdInline[] = MdParser.scan(src.substring(from, end),
              isDouble ? true : bold,
              isDouble ? italic : true,
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

  private static isEscapable(ch: string): boolean {
    const set: string = '\\`*_{}[]()#+-.!~=|>';
    return set.indexOf(ch) >= 0;
  }

  private static isWordChar(ch: string): boolean {
    const code: number = ch.charCodeAt(0);
    const isDigit: boolean = code >= 48 && code <= 57;
    const isUpper: boolean = code >= 65 && code <= 90;
    const isLower: boolean = code >= 97 && code <= 122;
    return isDigit || isUpper || isLower || ch === '_';
  }

  // ────────────────────────── 块级匹配 ──────────────────────────

  private static pushQuoteOrCallout(blocks: MdBlock[], body: string[], depth: number): void {
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
      blocks.push(MdBlockFactory.quote(depth, text, MdParser.parseInline(text), blocks.length));
    } else {
      blocks.push(MdBlockFactory.callout(kind, text, MdParser.parseInline(text), blocks.length));
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

  private static fenceLang(t: string): string {
    const c: string = t.charAt(0);
    let n: number = 0;
    while (n < t.length && t.charAt(n) === c) {
      n++;
    }
    let info: string = t.substring(n).trim();
    if (info.startsWith('{')) {
      info = info.substring(1);
    }
    if (info.endsWith('}')) {
      info = info.substring(0, info.length - 1);
    }
    if (info.startsWith('.')) {
      info = info.substring(1);
    }
    const sp: number = info.indexOf(' ');
    if (sp > 0) {
      info = info.substring(0, sp);
    }
    return info;
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
    // 去掉结尾的闭合 # 序列
    let end: number = text.length;
    while (end > 0 && text.charAt(end - 1) === '#') {
      end--;
    }
    if (end < text.length && (end === 0 || text.charAt(end - 1) === ' ')) {
      text = text.substring(0, end).trim();
    }
    const r: HeadingHit = { hit: true, level: n, text: text };
    return r;
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

  private static splitRow(t: string): string[] {
    let s: string = t.trim();
    if (s.startsWith('|')) {
      s = s.substring(1);
    }
    if (s.endsWith('|')) {
      s = s.substring(0, s.length - 1);
    }
    const parts: string[] = s.split('|');
    const out: string[] = [];
    for (let k = 0; k < parts.length; k++) {
      out.push(parts[k].trim());
    }
    return out;
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

    let indent: number = Math.floor(indentSpaces / 2);
    if (indent > 3) {
      indent = 3;
    }
    const r: ListHit = {
      hit: true,
      ordered: ordered,
      marker: marker,
      text: rest,
      indent: indent,
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
