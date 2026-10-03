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
import { util } from '@kit.ArkTS';

/** 内嵌 CSS。浅色纸面配色，与阅读器浅色主题同一气质。 */
const HTML_CSS: string = `
  body { margin: 0 auto; max-width: 820px; padding: 48px 28px 80px;
         font-family: "HarmonyOS Sans", "PingFang SC", "Microsoft YaHei", sans-serif;
         font-size: 16px; line-height: 1.75; color: #1b1f27; background: #f3f6fb; }
  /* rich 导出的图表容器：markmap-autoloader 要求容器有确定高度 */
  .markmap { width: 100%; height: 420px; }
  .mermaid, .ktx, .gv, .abc { width: 100%; overflow-x: auto; text-align: center; }
  .gv svg, .abc svg { max-width: 100%; height: auto; }
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

/** rich 模式导出：head 里的渲染库 CDN 脚本与页尾 runner 脚本两个产物。 */
export interface ChartAssets {
  head: string;
  runner: string;
}

/** 内联进 HTML 的渲染库（name = 文件名，code = 全文，isCss = 样式表）。 */
export interface InlineRuntime {
  name: string;
  code: string;
  isCss: boolean;
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

  /** 图表类代码块语言集合（rich 导出时转为对应渲染容器 + 预装渲染库）。 */
  static readonly CHART_LANGS: string[] =
    ['markmap', 'mermaid', 'echarts', 'graphviz', 'abc', 'katex', 'flowchart'];

  private static isChartLang(lang: string): boolean {
    const l: string = lang.trim().toLowerCase();
    for (let k = 0; k < MdToHtml.CHART_LANGS.length; k++) {
      if (MdToHtml.CHART_LANGS[k] === l) {
        return true;
      }
    }
    return false;
  }

  /** 扫描文档包含的图表块数（Chart 块 + Math 公式块；导出面板据此决定内联哪些库）。 */
  static countCharts(blocks: MdBlock[]): number {
    let n: number = 0;
    for (let k = 0; k < blocks.length; k++) {
      const b: MdBlock = blocks[k];
      if (b.kind === MdBlockKind.Chart && MdToHtml.isChartLang(b.lang)) {
        n++;
      } else if (b.kind === MdBlockKind.Math) {
        n++;
      }
    }
    return n;
  }

  /** 文本 → Base64（UTF-8）。容器统一存 Base64，runner 解码后渲染，
   * 彻底规避 HTML 转义（script 原文容器不解码实体，转义文本会原样进渲染器）。 */
  private static b64(text: string): string {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(text);
    return new util.Base64Helper().encodeToStringSync(bytes);
  }

  /** rich 模式：图表/公式内容 → data-b64 渲染容器（runner 解码后调对应渲染库绘制）。 */
  private static chartContainer(lang: string, lines: string[]): string {
    const b64: string = MdToHtml.b64(lines.join('\n'));
    if (lang === 'markmap') {
      return '<div class="markmap" data-b64="' + b64 + '"></div>';
    }
    if (lang === 'mermaid') {
      return '<div class="mermaid" data-b64="' + b64 + '"></div>';
    }
    if (lang === 'katex') {
      return '<div class="ktx" data-b64="' + b64 + '"></div>';
    }
    if (lang === 'echarts') {
      return '<div class="ech" data-b64="' + b64 + '" style="width:100%;height:420px"></div>';
    }
    if (lang === 'graphviz') {
      return '<div class="gv" data-b64="' + b64 + '" style="width:100%;min-height:200px;overflow-x:auto"></div>';
    }
    if (lang === 'abc') {
      return '<div class="abc" data-b64="' + b64 + '"></div>';
    }
    return '';
  }

  /**
   * rich 模式的 head 注入与底部 runner：
   * · `inline` 非空 = **内联模式**（用户要求）：渲染库全文直接嵌进 HTML，
   *   导出文件自包含、离线打开也能渲染；`</script>` 做安全转义。
   * · `inline` 为空 = CDN 引用模式（回退）：打开时联网加载。
   * 两种模式都只注入文档实际用到的库。
   */
  private static chartAssets(blocks: MdBlock[], rich: boolean,
                             inline: InlineRuntime[] | null): ChartAssets {
    if (!rich) {
      const empty: ChartAssets = { head: '', runner: '' };
      return empty;
    }
    // ── 内联模式 ──
    if (inline !== null && inline.length > 0) {
      let head: string = '';
      for (let k = 0; k < inline.length; k++) {
        const code: string =
          inline[k].code.split('</script>').join('<\\/script>');
        if (inline[k].isCss) {
          head += '<style>\n' + inline[k].code + '\n</style>\n';
        } else {
          head += '<script>\n' + code + '\n</script>\n';
        }
      }
      const done: ChartAssets = { head: head, runner: MdToHtml.chartRunner(blocks) };
      return done;
    }
    // ── CDN 引用模式（回退）──
    const has = (lang: string): boolean => {
      for (let k = 0; k < blocks.length; k++) {
        const b: MdBlock = blocks[k];
        const l: string = b.lang.trim().toLowerCase();
        if (b.kind === MdBlockKind.Chart && l === lang) {
          return true;
        }
        if (lang === 'mermaid' && b.kind === MdBlockKind.Chart && l === 'flowchart') {
          return true;
        }
        if (lang === 'katex' && b.kind === MdBlockKind.Math) {
          return true;
        }
      }
      return false;
    };
    let scripts: string = '';
    if (has('markmap')) {
      scripts += '<script src="https://cdn.jsdelivr.net/npm/d3@7.9.0/dist/d3.min.js"></script>\n'
        + '<script src="https://cdn.jsdelivr.net/npm/markmap-lib@0.18.12/dist/browser/index.iife.min.js"></script>\n'
        + '<script src="https://cdn.jsdelivr.net/npm/markmap-view@0.18.12/dist/browser/index.min.js"></script>\n';
    }
    if (has('mermaid')) {
      scripts += '<script src="https://cdn.jsdelivr.net/npm/mermaid@10.9.3/dist/mermaid.min.js"></script>\n';
    }
    if (has('echarts')) {
      scripts += '<script src="https://cdn.jsdelivr.net/npm/echarts@5.5.1/dist/echarts.min.js"></script>\n';
    }
    if (has('abc')) {
      scripts += '<script src="https://cdn.jsdelivr.net/npm/abcjs@6.4.4/dist/abcjs-basic-min.js"></script>\n';
    }
    if (has('katex')) {
      scripts += '<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css" />\n'
        + '<script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>\n';
    }
    if (scripts.length === 0) {
      const none: ChartAssets = { head: '', runner: '' };
      return none;
    }
    const done2: ChartAssets = { head: scripts, runner: MdToHtml.chartRunner(blocks) };
    return done2;
  }

  /** 页尾 runner：解码各容器的 Base64 内容并调对应渲染库绘制（内联 / CDN 共用）。 */
  private static chartRunner(blocks: MdBlock[]): string {
    const has = (lang: string): boolean => {
      for (let k = 0; k < blocks.length; k++) {
        const b: MdBlock = blocks[k];
        const l: string = b.lang.trim().toLowerCase();
        if (b.kind === MdBlockKind.Chart && l === lang) {
          return true;
        }
        if (lang === 'mermaid' && b.kind === MdBlockKind.Chart && l === 'flowchart') {
          return true;
        }
        if (lang === 'katex' && b.kind === MdBlockKind.Math) {
          return true;
        }
      }
      return false;
    };
    const runnerCode: string = '\n<script>\n(function() {\n'
      + '  function b64u(b64) { var bin = atob(b64); var u = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) { u[i] = bin.charCodeAt(i); } return new TextDecoder().decode(u); }\n'
      + '  function tryRun(fn) { try { fn(); } catch (e) { console.error("chart render failed", e); } }\n'
      + '  window.addEventListener("load", function() {\n'
      + (has('markmap') ? '    if (window.markmap && markmap.Transformer && markmap.Markmap) {\n'
        + '      document.querySelectorAll(".markmap").forEach(async function(el) {\n'
        + '        try {\n'
        + '          var r = await new markmap.Transformer().transform(b64u(el.dataset.b64));\n'
        + '          el.innerHTML = "";\n'
        + '          var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");\n'
        + '          el.appendChild(svg);\n'
        + '          markmap.Markmap.create(svg, null, r.root || r);\n'
        + '        } catch (e) { console.error("markmap render failed", e); }\n'
        + '      });\n'
        + '    }\n' : '')
      + (has('mermaid') ? '    if (window.mermaid) {\n'
        + '      tryRun(function() { mermaid.initialize({ startOnLoad: false }); });\n'
        + '      document.querySelectorAll(".mermaid").forEach(async function(el, i) {\n'
        + '        try {\n'
        + '          var r = await mermaid.render("mmd" + i, b64u(el.dataset.b64));\n'
        + '          el.innerHTML = r.svg;\n'
        + '        } catch (e) { console.error("mermaid render failed", e); }\n'
        + '      });\n'
        + '    }\n' : '')
      + (has('katex') ? '    if (window.katex) {\n'
        + '      document.querySelectorAll(".ktx").forEach(function(el) {\n'
        + '        tryRun(function() { katex.render(b64u(el.dataset.b64), el, { displayMode: true, throwOnError: false }); });\n'
        + '      });\n'
        + '    }\n' : '')
      + (has('echarts') ? '    if (window.echarts) {\n'
        + '      document.querySelectorAll(".ech").forEach(function(el) {\n'
        + '        tryRun(function() { var opt = (new Function("return (" + b64u(el.dataset.b64) + ")"))(); echarts.init(el).setOption(opt); });\n'
        + '      });\n'
        + '    }\n' : '')
      + (has('graphviz') ? '    if (window.Viz) {\n'
        + '      document.querySelectorAll(".gv").forEach(async function(el) {\n'
        + '        try {\n'
        + '          var svg = await new Viz().renderString(b64u(el.dataset.b64), { format: "svg" });\n'
        + '          el.innerHTML = svg;\n'
        + '        } catch (e) { console.error("graphviz render failed", e); }\n'
        + '      });\n'
        + '    }\n' : '')
      + (has('abc') ? '    if (window.ABCJS) {\n'
        + '      document.querySelectorAll(".abc").forEach(function(el) {\n'
        + '        tryRun(function() { ABCJS.renderAbc(el, b64u(el.dataset.b64)); });\n'
        + '      });\n'
        + '    }\n' : '')
      + '  });\n'
      + '})();\n</script>\n';
    return runnerCode;
  }

  /**
   * flowchart 语法 → mermaid flowchart 语法（用户要求：flowchart 借 mermaid 渲染）。
   * 支持：id=>type: 文本（start/end/operation/condition/subroutine/inputoutput）、
   * a->b、a->b: 标签、cond(yes)->b 条件分支、a->b->c 链式。
   */
  static flowchartToMermaid(code: string): string {
    const lines: string[] = code.split('\n');
    const types: Record<string, string> = {};
    const texts: Record<string, string> = {};
    const edges: string[] = [];
    const used: string[] = [];
    // 第一遍：收集节点定义
    for (let k = 0; k < lines.length; k++) {
      const t: string = lines[k].trim();
      const arrow: number = t.indexOf('=>');
      if (arrow <= 0) {
        continue;
      }
      const id: string = t.substring(0, arrow).trim();
      const rest: string = t.substring(arrow + 2).trim();
      const colon: number = rest.indexOf(':');
      const type: string = (colon >= 0 ? rest.substring(0, colon) : rest).trim().toLowerCase();
      const text: string = (colon >= 0 ? rest.substring(colon + 1).trim() : '').replace(/"/g, '');
      types[id] = type;
      texts[id] = text;
    }
    const fcNode = (id: string): string => {
      const type: string = types[id] !== undefined ? types[id] : 'operation';
      const text: string = texts[id] !== undefined && texts[id].length > 0 ? texts[id] : id;
      const clean: string = text.replace(/\|/g, '/');
      if (type === 'start' || type === 'end') {
        return id + '(["' + clean + '"])';
      }
      if (type === 'condition') {
        return id + '{"' + clean + '"}';
      }
      if (type === 'subroutine') {
        return id + '[["' + clean + '"]]';
      }
      if (type === 'inputoutput') {
        return id + '[/"' + clean + '"/]';
      }
      return id + '["' + clean + '"]';
    };
    // 第二遍：连线
    for (let k = 0; k < lines.length; k++) {
      const t: string = lines[k].trim();
      if (t.length === 0 || t.indexOf('->') <= 0) {
        continue;
      }
      const parts: string[] = t.split('->');
      for (let i = 0; i + 1 < parts.length; i++) {
        let from: string = parts[i].trim();
        let to: string = parts[i + 1].trim();
        let label: string = '';
        const pm: RegExpMatchArray | null = from.match(/^([A-Za-z0-9_]+)\(([^)]*)\)$/);
        if (pm !== null) {
          from = pm[1];
          label = pm[2].trim();
        }
        const tc: number = to.indexOf(':');
        if (tc > 0) {
          label = to.substring(tc + 1).trim();
          to = to.substring(0, tc).trim();
        }
        const tm: RegExpMatchArray | null = to.match(/^([A-Za-z0-9_]+)\(([^)]*)\)$/);
        if (tm !== null) {
          to = tm[1];
          if (label.length === 0) {
            label = tm[2].trim();
          }
        }
        if (from.length === 0 || to.length === 0) {
          continue;
        }
        if (types[from] === undefined) {
          types[from] = 'operation';
          texts[from] = from;
        }
        if (types[to] === undefined) {
          types[to] = 'operation';
          texts[to] = to;
        }
        if (used.indexOf(from) < 0) {
          used.push(from);
        }
        if (used.indexOf(to) < 0) {
          used.push(to);
        }
        if (label.length > 0) {
          edges.push(fcNode(from) + ' -->|' + label.replace(/\|/g, '/') + '| ' + fcNode(to));
        } else {
          edges.push(fcNode(from) + ' --> ' + fcNode(to));
        }
      }
    }
    let out: string = 'flowchart TD';
    for (let k = 0; k < used.length; k++) {
      out += '\n  ' + fcNode(used[k]);
    }
    for (let k = 0; k < edges.length; k++) {
      out += '\n  ' + edges[k];
    }
    return out;
  }

  /** 整份文档导出。rich = true 时图表块转渲染容器并预装 CDN（导出面板询问用户后传入）。 */
  static export(docName: string, meta: MdMetaItem[], blocks: MdBlock[], rich: boolean = false,
    inline: InlineRuntime[] | null = null): string {
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

    let chartIndex: number = 0;
    for (let k = 0; k < blocks.length; k++) {
      const block: MdBlock = blocks[k];
      if (block.kind !== MdBlockKind.ListItem) {
        closeTo(0);
        if (block.kind === MdBlockKind.Heading) {
          body += '<h' + block.level + '>' + MdToHtml.inline(block.inlines) + '</h' + block.level + '>';
        } else if (block.kind === MdBlockKind.Paragraph) {
          body += '<p>' + MdToHtml.inline(block.inlines) + '</p>';
        } else if (block.kind === MdBlockKind.Chart) {
          // 图表块：rich 且语言受支持 → 渲染容器（渲染库内联）；
          // flowchart 语法 → 转换为 mermaid 渲染；graphviz 等无方案 → 保持代码块
          const langLower: string = block.lang.trim().toLowerCase();
          if (rich && langLower === 'flowchart') {
            body += MdToHtml.chartContainer('mermaid',
              [MdToHtml.flowchartToMermaid(block.code)]);
            chartIndex++;
          } else if (rich && MdToHtml.isChartLang(langLower)) {
            body += MdToHtml.chartContainer(langLower, block.codeLines);
            chartIndex++;
          } else {
            body += MdToHtml.codeBlock(block.lang, block.codeLines);
          }
        } else if (block.kind === MdBlockKind.Math && rich) {
          // rich 模式：公式块转 katex 容器
          body += MdToHtml.chartContainer('katex', [block.code]);
          chartIndex++;
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

    const assets: ChartAssets = MdToHtml.chartAssets(blocks, rich, inline);
    const html: string = '<!DOCTYPE html>\n<html lang="zh-CN">\n<head>\n<meta charset="utf-8" />'
      + '<meta name="viewport" content="width=device-width, initial-scale=1" />'
      + '<title>' + MdToHtml.esc(docName) + '</title>\n<style>' + HTML_CSS + '</style>\n'
      + assets.head + '</head>\n<body>\n'
      + '<h1>' + MdToHtml.esc(docName) + '</h1>\n'
      + metaHtml + '\n' + body
      + '\n<p class="foot">由 澄笺·ChéngJiān 导出</p>\n' + assets.runner + '</body>\n</html>\n';
    return html;
  }
}
