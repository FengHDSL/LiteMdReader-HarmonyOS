/**
 * 文档体检（DocLint）—— 扫描一篇 Markdown 的**结构性隐患**并给出可定位的问题列表。
 *
 * 设计原则：
 * 1. **只看源码文本**，不依赖解析结果 —— 解析器会"吞掉"错误（例如未闭合围栏
 *    会被当成一个超长代码块，解析层面看不出问题），只有源文本才能发现。
 * 2. **每条问题都带行号**，便于在编辑页定位。
 * 3. 只报**确定的问题**（不猜），避免误报噪音。
 *
 * 覆盖的检查项：
 * · 围栏代码块数量为奇数（有未闭合的 ``` 或 ~~~）
 * · 图片引用指向的文件在沙箱里不存在
 * · 站内锚点链接（`#标题`）找不到对应标题
 * · 文档链接（`[[名称]]`）指向不存在的文档
 * · 空章节（标题之后直到下一个标题都没有正文）
 * · 连续重复的标题文本
 * · 表格列数不一致（同一张表内 `|` 数量不齐）
 * · 超长行（> 2000 字符，编辑与渲染都会吃力）
 * · 任务清单统计（已完成 / 未完成），作为信息项
 */
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { DocStore } from './DocStore';
import { L10n } from './L10n';

/** 问题的严重级别 */
export type LintLevel = 'error' | 'warn' | 'info';

/** 一条体检结果 */
export interface LintIssue {
  level: LintLevel;
  /** 行号（从 1 开始；0 表示整篇级别的问题） */
  line: number;
  /** 问题分类（用于分组显示） */
  kind: string;
  /** 面向用户的一句话说明 */
  message: string;
}

/** 体检报告 */
export interface LintReport {
  issues: LintIssue[];
  errorCount: number;
  warnCount: number;
  infoCount: number;
  /** 任务清单统计 */
  todoOpen: number;
  todoDone: number;
  /** 行数 / 字符数，作为概览信息 */
  lines: number;
  chars: number;
}

/** 围栏标记（``` 或 ~~~，长度 ≥ 3） */
interface FenceMark {
  char: string;
  len: number;
}

export class DocLint {
  /** 单行的围栏标记；不是围栏行返回 null。 */
  private static fenceOf(line: string): FenceMark | null {
    const t: string = line.trim();
    if (t.length < 3) {
      return null;
    }
    const c: string = t.charAt(0);
    if (c !== '`' && c !== '~') {
      return null;
    }
    let n: number = 0;
    while (n < t.length && t.charAt(n) === c) {
      n++;
    }
    if (n < 3) {
      return null;
    }
    // 反引号围栏的行内不能含反引号（Markdown 规范），波浪线无此限制
    if (c === '`') {
      const rest: string = t.substring(n).trim();
      // 语言标签里若有反引号则该行不是围栏
      if (rest.indexOf('`') >= 0) {
        return null;
      }
    }
    return { char: c, len: n } as FenceMark;
  }

  /** 该行是否"像表格行"（含竖线且剥掉竖线后还有内容）。 */
  private static isTableLine(line: string): boolean {
    const t: string = line.trim();
    return t.length > 1 && t.indexOf('|') >= 0;
  }

  /** 该行是否是表格分隔行（`| --- | :--: |`）。 */
  private static isDelimiterLike(line: string): boolean {
    const t: string = line.trim();
    if (t.indexOf('-') < 0) {
      return false;
    }
    return t.replace(/[|\s:\-]/g, '').length === 0;
  }

  /** ATX 标题：返回 { level, text }；不是标题返回 null。 */
  private static headingOf(line: string): HeadingHit | null {
    const t: string = line.trim();
    if (t.length === 0 || t.charAt(0) !== '#') {
      return null;
    }
    let lv: number = 0;
    while (lv < t.length && t.charAt(lv) === '#') {
      lv++;
    }
    if (lv > 6 || lv >= t.length || t.charAt(lv) !== ' ') {
      return null;
    }
    const text: string = t.substring(lv + 1).trim().replace(/#+\s*$/, '');
    return { level: lv, text: text } as HeadingHit;
  }

  /** Markdown 标题文本 → 锚点（与 Reader 的 normalizeAnchor 口径保持一致）。 */
  private static normalizeAnchor(s: string): string {
    return s.trim().toLowerCase()
      .replace(/[\s\u3000]+/g, '-')
      .replace(/[!-\/:-@\[-`{-~]/g, '');
  }

  /**
   * 扫描一篇文档。
   * @param ctx 上下文（读图片 / 查文档列表都要用）
   * @param docName 文档名
   * @param content 正文（由调用方提供，避免重复读盘）
   */
  static scan(ctx: common.UIAbilityContext, docName: string, content: string): LintReport {
    const issues: LintIssue[] = [];
    const lines: string[] = content.replace(/\r\n?/g, '\n').split('\n');

    // ── 围栏配对（按长度匹配，与解析器同一套规则） ──
    let openFence: FenceMark | null = null;
    let openLine: number = 0;
    for (let i = 0; i < lines.length; i++) {
      const f: FenceMark | null = DocLint.fenceOf(lines[i]);
      if (f === null) {
        continue;
      }
      if (openFence === null) {
        openFence = f;
        openLine = i + 1;
      } else if (f.char === openFence.char && f.len >= openFence.len) {
        openFence = null;
      }
      // 长度不足的同字符围栏属于内容（长围栏包短围栏的写法），忽略
    }
    if (openFence !== null) {
      issues.push({
        level: 'error', line: openLine, kind: '围栏未闭合',
        message: L10n.t('第 ') + openLine + ' 行的围栏代码块没有闭合，后面的内容都会被当成代码'
      } as LintIssue);
    }

    // ── 标题索引（供锚点与空章节检查） ──
    const headings: HeadingHit[] = [];
    const headingLines: number[] = [];
    for (let i = 0; i < lines.length; i++) {
      const h: HeadingHit | null = DocLint.headingOf(lines[i]);
      if (h !== null) {
        headings.push(h);
        headingLines.push(i);
      }
    }
    const anchors: string[] = [];
    for (let k = 0; k < headings.length; k++) {
      anchors.push(DocLint.normalizeAnchor(headings[k].text));
    }

    // ── 空章节 ──
    for (let k = 0; k < headings.length; k++) {
      const start: number = headingLines[k];
      const end: number = (k + 1 < headingLines.length) ? headingLines[k + 1] : lines.length;
      let hasBody: boolean = false;
      for (let i = start + 1; i < end; i++) {
        if (lines[i].trim().length > 0) {
          hasBody = true;
          break;
        }
      }
      if (!hasBody) {
        issues.push({
          level: 'warn', line: start + 1, kind: '空章节',
          message: '「' + headings[k].text + '」标题下没有任何内容'
        } as LintIssue);
      }
    }

    // ── 连续重复标题 ──
    for (let k = 1; k < headings.length; k++) {
      if (headings[k].level === headings[k - 1].level
        && headings[k].text === headings[k - 1].text && headings[k].text.length > 0) {
        issues.push({
          level: 'warn', line: headingLines[k] + 1, kind: '重复标题',
          message: L10n.t('与第 ') + (headingLines[k - 1] + 1) + ' 行标题重复：「' + headings[k].text + '」'
        } as LintIssue);
      }
    }

    // ── 图片 / 链接 / 超长行 / 任务清单（逐行扫） ──
    let todoOpen: number = 0;
    let todoDone: number = 0;
    const imgRe: RegExp = /!\[[^\]]*\]\(([^)\s]+)/g;
    const anchorRe: RegExp = /\[[^\]]*\]\(#([^)\s]+)\)/g;
    const wikiRe: RegExp = /\[\[([^\]|]+)(\|[^\]]*)?\]\]/g;
    const boxRe: RegExp = /^\s*[-*+]\s*\[([ xX])\]/;
    let tableStart: number = -1;
    let tableCols: number = -1;

    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];

      // 任务清单
      const box: RegExpMatchArray | null = line.match(boxRe);
      if (box !== null) {
        if (box[1] === ' ') {
          todoOpen++;
        } else {
          todoDone++;
        }
      }

      // 图片
      imgRe.lastIndex = 0;
      let m: RegExpExecArray | null = imgRe.exec(line);
      while (m !== null) {
        const src: string = m[1];
        if (!src.startsWith('http') && !src.startsWith('data:')) {
          const rel: string = src.startsWith('/') ? src.substring(1) : src;
          if (rel.startsWith('images/')) {
            const full: string = DocStore.docsRoot() + '/' + rel;
            let exists: boolean = false;
            try {
              exists = fs.accessSync(full);
            } catch (err) {
              exists = false;
            }
            if (!exists) {
              issues.push({
                level: 'warn', line: i + 1, kind: '图片缺失',
                message: L10n.t('图片 ') + rel + ' 在本地找不到（可能移动或删除了）'
              } as LintIssue);
            }
          }
        }
        m = imgRe.exec(line);
      }

      // 锚点链接
      anchorRe.lastIndex = 0;
      let a: RegExpExecArray | null = anchorRe.exec(line);
      while (a !== null) {
        const target: string = DocLint.normalizeAnchor(decodeURIComponent(a[1]));
        let hit: boolean = false;
        for (let k = 0; k < anchors.length; k++) {
          if (anchors[k] === target) {
            hit = true;
            break;
          }
        }
        if (!hit && target.length > 0) {
          issues.push({
            level: 'warn', line: i + 1, kind: '锚点失效',
            message: L10n.t('跳转目标「#') + a[1] + '」在本篇里找不到对应标题'
          } as LintIssue);
        }
        a = anchorRe.exec(line);
      }

      // 文档链接
      wikiRe.lastIndex = 0;
      let w: RegExpExecArray | null = wikiRe.exec(line);
      while (w !== null) {
        const name: string = w[1].trim();
        if (name.length > 0 && DocStore.find(ctx, name) === undefined) {
          issues.push({
            level: 'warn', line: i + 1, kind: '文档链接失效',
            message: L10n.t('链接的文档「') + name + '」不存在'
          } as LintIssue);
        }
        w = wikiRe.exec(line);
      }

      // 超长行
      if (line.length > 2000) {
        issues.push({
          level: 'warn', line: i + 1, kind: '超长行',
          message: L10n.t('这一行有 ') + line.length + ' 个字符，编辑与渲染都会吃力，建议手动换行'
        } as LintIssue);
      }

      // **表格缺少分隔行**：表头下面必须紧跟 `| --- |`，否则整张表会被当成普通段落渲染
      // —— 用户看到的是一行带竖线的文字，很难自己想到原因。只报"表头行"：
      // 本行像表格、上一行不是表格行、而下一行虽是表格行却不是分隔行。
      if (DocLint.isTableLine(line)) {
        const nextLine: string = (i + 1 < lines.length) ? lines[i + 1].trim() : '';
        const prevIsTable: boolean = i > 0 && DocLint.isTableLine(lines[i - 1]);
        if (!prevIsTable && DocLint.isTableLine(nextLine)
          && !DocLint.isDelimiterLike(nextLine)) {
          issues.push({
            level: 'warn', line: i + 1, kind: '表格缺少分隔行',
            message: L10n.t('这一行像是表头，但下一行不是 | --- | 分隔行；补一行分隔行才会渲染成表格')
              + '（也可以直接删掉竖线，改成普通文字）'
          } as LintIssue);
        }
      }

      // 表格列数一致性
      const isTable: boolean = line.trim().startsWith('|') && line.trim().endsWith('|');
      if (isTable) {
        const cols: number = line.split('|').length - 2;
        if (tableStart < 0) {
          tableStart = i + 1;
          tableCols = cols;
        } else if (cols !== tableCols) {
          issues.push({
            level: 'warn', line: i + 1, kind: '表格列数不一致',
            message: L10n.t('第 ') + tableStart + ' 行开始的表格是 ' + tableCols + ' 列，这一行是 ' + cols + ' 列'
          } as LintIssue);
        }
      } else {
        tableStart = -1;
        tableCols = -1;
      }
    }

    // 统计
    let errorCount: number = 0;
    let warnCount: number = 0;
    let infoCount: number = 0;
    for (let k = 0; k < issues.length; k++) {
      if (issues[k].level === 'error') {
        errorCount++;
      } else if (issues[k].level === 'warn') {
        warnCount++;
      } else {
        infoCount++;
      }
    }
    if (todoOpen > 0) {
      issues.push({
        level: 'info', line: 0, kind: '任务清单',
        message: L10n.t('还有 ') + todoOpen + ' 项待办未完成（已完成 ' + todoDone + ' 项）'
      } as LintIssue);
      infoCount++;
    }

    return {
      issues: issues, errorCount: errorCount, warnCount: warnCount, infoCount: infoCount,
      todoOpen: todoOpen, todoDone: todoDone, lines: lines.length, chars: content.length
    } as LintReport;
  }

  /** 报告的一句话摘要（用于 toast）。 */
  static summary(r: LintReport): string {
    if (r.errorCount === 0 && r.warnCount === 0) {
      return '体检通过：没有发现结构问题';
    }
    let s: string = '';
    if (r.errorCount > 0) {
      s += r.errorCount + ' 个错误';
    }
    if (r.warnCount > 0) {
      s += (s.length > 0 ? '、' : '') + r.warnCount + ' 个提醒';
    }
    return '发现 ' + s;
  }
}

/** 标题命中 */
interface HeadingHit {
  level: number;
  text: string;
}
