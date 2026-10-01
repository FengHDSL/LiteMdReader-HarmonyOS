/**
 * LiteMdReader · Markdown → HTML 导出
 * ====================================
 *
 * 移植自参考项目 MD Reader 的「导出自包含 HTML」：单个 HTML 文件内嵌全部样式，
 * 用浏览器或任何编辑器都能打开。图片走原地址（网络图原样引用，本地图片导出原路径）。
 *
 * 代码高亮复用阅读器自己的 CodeHighlighter（按语言族扫描），
 * token 种类映射成 class，由内嵌 CSS 着色——导出与阅读看到的是同一套配色逻辑。
 *
 * 刻意不做：行内 HTML 的解析透传（解析器本来就把它们当纯文本）、
 * 数学公式、Mermaid——与阅读页范围保持一致，不做假实现。
 */

import { CodeFamily, CodeHighlighter, CodeState, CodeToken, CodeTokenKind, newCodeState, resolveFamily } from './CodeHighlight';
import { MdBlock, MdBlockKind, MdInline, MdInlineKind, MdMetaItem, MdTableRow, MdTaskState, MdCalloutKind } from './MdTypes';

/** 内嵌 CSS。浅色纸面配色，与阅读器浅色主题同一气质。 */
const HTML_CSS: string = `
  body { margin: 0 auto; max-width: 820px; padding: 48px 28px 80px;
         font-family: "HarmonyOS Sans", "PingFang SC", "Microsoft YaHei", sans-serif;
         font-size: 16px; line-height: 1.75; color: #1b1f27; background: #f3f6fb; }
  h1, h2, h3, h4, h5, h6 { line-height: 1.35; margin: 1.6em 0 0.6em; }
  h1 { font-size: 1.75em; } h2 { font-size: 1.42em; border-bottom: 1px solid #e2e6ee; padding-bottom: 0.3em; }
  h3 { font-size: 1.21em; } h4 { font-size: 1.09em; } h5 { font-size: 1em; } h6 { font-size: 0.94em; color: #525a68; }
  p { margin: 0.75em 0; }
  a { color: #2f63e8; text-decoration: none; }
  a:hover { text-decoration: underline; }
  code { font-family: "HarmonyOS Sans SC Mono", Consolas, Menlo, monospace; font-size: 0.88em;
         background: rgba(47,99,232,0.08); color: #2350c4; border-radius: 4px; padding: 0.1em 0.35em; }
  pre { background: #f6f8fb; border: 1px solid #e2e6ee; border-radius: 10px; padding: 14px 16px; overflow: auto; }
  pre code { background: transparent; color: #1b1f27; padding: 0; }
  .kw { color: #cf222e; } .str { color: #0a3069; } .cmt { color: #6e7781; font-style: italic; }
  .num { color: #0550ae; } .fn { color: #8250df; } .tag { color: #116329; } .attr { color: #0550ae; }
  blockquote { margin: 1em 0; padding: 10px 16px; border-left: 3px solid #2f63e8;
               background: rgba(47,99,232,0.06); border-radius: 6px; color: #3a4150; }
  .callout { margin: 1em 0; padding: 12px 16px; border-left: 3px solid #888; border-radius: 6px; background: rgba(0,0,0,0.04); }
  .callout .t { font-weight: 600; font-size: 0.85em; letter-spacing: 0.06em; display: block; margin-bottom: 4px; }
  table { border-collapse: collapse; margin: 1em 0; width: 100%; font-size: 0.94em; }
  th, td { border: 1px solid #e2e6ee; padding: 7px 12px; text-align: left; }
  th { background: rgba(27,31,39,0.06); font-weight: 600; }
  tr:nth-child(even) td { background: rgba(27,31,39,0.03); }
  img { max-width: 100%; border-radius: 8px; }
  hr { border: none; border-top: 1px solid #dde2ea; margin: 2em 0; }
  mark { background: #e8f0a0; padding: 0.05em 0.2em; border-radius: 3px; }
  .meta { background: #eef1f7; border-radius: 10px; padding: 14px 18px; margin-bottom: 2em; font-size: 0.9em; }
  .meta dt { font-weight: 600; color: #525a68; margin-top: 6px; }
  .meta dd { margin: 0 0 0 0; color: #1b1f27; }
  .task { list-style: none; }
  .foot { color: #6e7781; font-size: 0.88em; border-top: 1px dashed #dde2ea; margin-top: 2.5em; padding-top: 1em; }
  sup.fnref a { font-size: 0.75em; }
`;

/** 呼叫块标题色。与阅读页 calloutSpec 保持一致。 */
function calloutColor(kind: MdCalloutKind): string {
  if (kind === MdCalloutKind.Note) {
    return '#2f63e8';
  }
  if (kind === MdCalloutKind.Tip) {
    return '#1f9e66';
  }
  if (kind === MdCalloutKind.Important) {
    return '#8a5af0';
  }
  if (kind === MdCalloutKind.Warning) {
    return '#e08000';
  }
  if (kind === MdCalloutKind.Caution) {
    return '#d93b3b';
  }
  return '#888888';
}

function calloutTitle(kind: MdCalloutKind): string {
  if (kind === MdCalloutKind.Note) {
    return 'NOTE';
  }
  if (kind === MdCalloutKind.Tip) {
    return 'TIP';
  }
  if (kind === MdCalloutKind.Important) {
    return 'IMPORTANT';
  }
  if (kind === MdCalloutKind.Warning) {
    return 'WARNING';
  }
  if (kind === MdCalloutKind.Caution) {
    return 'CAUTION';
  }
  return '';
}

export class MdToHtml {
  // 说明：原先的 pageShell() 只服务于已移除的 Lute 导出链路（拿现成片段拼页面），
  // 现在导出统一走本类的 export()，从零拼完整 HTML，故 pageShell 已删除。

  /** HTML 转义：正文里的 < > & 与属性里的引号。 */
  static esc(text: string): string {
    let out: string = '';
    for (let k = 0; k < text.length; k++) {
      const c: string = text.charAt(k);
      if (c === '<') {
        out += '&lt;';
      } else if (c === '>') {
        out += '&gt;';
      } else if (c === '&') {
        out += '&amp;';
      } else if (c === '"') {
        out += '&quot;';
      } else {
        out += c;
      }
    }
    return out;
  }

  /** 行内片段 → HTML。样式标志位已由解析器继承到每个片段。 */
  static inline(items: MdInline[]): string {
    let out: string = '';
    for (let k = 0; k < items.length; k++) {
      const item: MdInline = items[k];
      let body: string = MdToHtml.esc(item.text);
      if (item.code) {
        body = '<code>' + body + '</code>';
      }
      if (item.bold) {
        body = '<strong>' + body + '</strong>';
      }
      if (item.italic) {
        body = '<em>' + body + '</em>';
      }
      if (item.strike) {
        body = '<del>' + body + '</del>';
      }
      if (item.kind === MdInlineKind.Link) {
        body = '<a href="' + MdToHtml.esc(item.href) + '">' + body + '</a>';
      } else if (item.kind === MdInlineKind.Image) {
        const alt: string = item.text.length > 0 ? item.text : 'image';
        body = '<img alt="' + MdToHtml.esc(alt) + '" src="' + MdToHtml.esc(item.href) + '" />';
      } else if (item.kind === MdInlineKind.Mark) {
        body = '<mark>' + body + '</mark>';
      } else if (item.kind === MdInlineKind.FootnoteRef) {
        const label: string = item.num > 0 ? '' + item.num : MdToHtml.esc(item.text);
        body = '<sup class="fnref">[' + label + ']</sup>';
      } else if (item.kind === MdInlineKind.Code) {
        // 上面已经包过 code
      }
      out += body;
    }
    return out;
  }

  /** 代码块 → 带语言族高亮的 pre/code。 */
  static codeBlock(lang: string, lines: string[]): string {
    const family: CodeFamily = resolveFamily(lang);
    const state: CodeState = newCodeState();
    let out: string = '<pre><code>';
    for (let k = 0; k < lines.length; k++) {
      const tokens: CodeToken[] = CodeHighlighter.highlightLine(lines[k], family, state);
      for (let t = 0; t < tokens.length; t++) {
        const text: string = MdToHtml.esc(tokens[t].text);
        const kind: number = tokens[t].kind;
        let cls: string = '';
        if (kind === CodeTokenKind.Keyword) {
          cls = 'kw';
        } else if (kind === CodeTokenKind.Str) {
          cls = 'str';
        } else if (kind === CodeTokenKind.Comment) {
          cls = 'cmt';
        } else if (kind === CodeTokenKind.Number) {
          cls = 'num';
        } else if (kind === CodeTokenKind.Func) {
          cls = 'fn';
        } else if (kind === CodeTokenKind.Tag) {
          cls = 'tag';
        } else if (kind === CodeTokenKind.Attr) {
          cls = 'attr';
        }
        out += cls.length > 0 ? '<span class="' + cls + '">' + text + '</span>' : text;
      }
      out += '\n';
    }
    out += '</code></pre>';
    return out;
  }

  /** 表格 → HTML table，含列对齐。 */
  static table(block: MdBlock): string {
    let out: string = '<table>';
    for (let r = 0; r < block.rows.length; r++) {
      const row: MdTableRow = block.rows[r];
      out += row.header ? '<thead><tr>' : '<tr>';
      for (let c = 0; c < row.cells.length; c++) {
        const tag: string = row.header ? 'th' : 'td';
        let style: string = '';
        if (c < block.aligns.length) {
          if (block.aligns[c] === 1) {
            style = ' style="text-align:center"';
          } else if (block.aligns[c] === 2) {
            style = ' style="text-align:right"';
          }
        }
        out += '<' + tag + style + '>' + MdToHtml.inline(row.cells[c]) + '</' + tag + '>';
      }
      out += row.header ? '</tr></thead>' : '</tr>';
    }
    out += '</table>';
    return out;
  }

  /** 整份文档导出。 */
  static export(docName: string, meta: MdMetaItem[], blocks: MdBlock[]): string {
    let body: string = '';
    // 列表嵌套：用已打开的列表层缩进栈表达，遇到 indent 变化就闭合 / 打开列表
    let openLists: number[] = [];
    let listOrdered: boolean = false;
    let itemOpen: boolean = false;

    const closeItem: () => void = (): void => {
      if (itemOpen) {
        body += '</li>';
        itemOpen = false;
      }
    };
    const closeTo: (depth: number) => void = (depth: number): void => {
      while (openLists.length > depth) {
        closeItem();
        body += listOrdered ? '</ol>' : '</ul>';
        openLists.pop();
      }
    };

    for (let k = 0; k < blocks.length; k++) {
      const block: MdBlock = blocks[k];
      if (block.kind !== MdBlockKind.ListItem) {
        closeTo(0);
        if (block.kind === MdBlockKind.Heading) {
          body += '<h' + block.level + '>' + MdToHtml.inline(block.inlines) + '</h' + block.level + '>';
        } else if (block.kind === MdBlockKind.Paragraph) {
          body += '<p>' + MdToHtml.inline(block.inlines) + '</p>';
        } else if (block.kind === MdBlockKind.Code) {
          body += MdToHtml.codeBlock(block.lang, block.codeLines);
        } else if (block.kind === MdBlockKind.Quote) {
          body += '<blockquote>' + MdToHtml.inline(block.inlines) + '</blockquote>';
        } else if (block.kind === MdBlockKind.Callout) {
          body += '<div class="callout" style="border-left-color:' + calloutColor(block.callout) + '">'
            + '<span class="t" style="color:' + calloutColor(block.callout) + '">'
            + calloutTitle(block.callout) + '</span>'
            + MdToHtml.inline(block.inlines) + '</div>';
        } else if (block.kind === MdBlockKind.Table) {
          body += MdToHtml.table(block);
        } else if (block.kind === MdBlockKind.Divider) {
          body += '<hr />';
        } else if (block.footnoteNo > 0) {
          body += '<p class="foot">' + MdToHtml.esc(block.marker) + ' '
            + MdToHtml.inline(block.inlines) + '</p>';
        }
        continue;
      }

      // 列表项
      const depth: number = block.indent + 1;
      const ordered: boolean = block.ordered;
      if (openLists.length === 0 || depth > openLists.length) {
        closeItem();
        if (openLists.length > 0 && listOrdered !== ordered && depth === openLists.length + 1) {
          // 同层切换列表类型（罕见），先闭合再开
        }
        body += ordered ? '<ol>' : '<ul>';
        listOrdered = ordered;
        openLists.push(depth);
      } else if (depth < openLists.length) {
        closeTo(depth - 1);
      } else {
        closeItem();
        listOrdered = ordered;
      }
      const task: number = block.task;
      if (task === MdTaskState.Todo || task === MdTaskState.Done) {
        const checked: boolean = task === MdTaskState.Done;
        body += '<li class="task"><input type="checkbox" disabled'
          + (checked ? ' checked' : '') + ' /> '
          + MdToHtml.inline(block.inlines) + '</li>';
      } else {
        body += '<li>' + MdToHtml.inline(block.inlines);
        itemOpen = true;
      }
    }
    closeTo(0);

    let metaHtml: string = '';
    if (meta.length > 0) {
      metaHtml += '<dl class="meta">';
      for (let k = 0; k < meta.length; k++) {
        metaHtml += '<dt>' + MdToHtml.esc(meta[k].key) + '</dt><dd>'
          + MdToHtml.esc(meta[k].value) + '</dd>';
      }
      metaHtml += '</dl>';
    }

    const html: string = '<!DOCTYPE html>\n<html lang="zh-CN">\n<head>\n<meta charset="utf-8" />'
      + '<meta name="viewport" content="width=device-width, initial-scale=1" />'
      + '<title>' + MdToHtml.esc(docName) + '</title>\n<style>' + HTML_CSS + '</style>\n</head>\n<body>\n'
      + '<h1>' + MdToHtml.esc(docName) + '</h1>\n'
      + metaHtml + '\n' + body
      + '\n<p class="foot">由 LiteMdReader 导出</p>\n</body>\n</html>\n';
    return html;
  }
}
