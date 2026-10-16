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

import { ChartCache } from '../service/ChartCache';
import { CodeFamily, CodeHighlighter, CodeState, CodeToken, CodeTokenKind, newCodeState, resolveFamily } from './CodeHighlight';
import { MdBlock, MdBlockKind, MdBadge, MdInline, MdInlineKind, MdMetaItem, MdTableRow, MdTaskState, MdCalloutKind, GroupCode } from './MdTypes';
import { MdParser } from './MdParser';
import { Badge } from './Badge';
import { EngineRegistry } from '../service/EngineRegistry';
import { PlantumlBridge } from './PlantumlBridge';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';

/** 内嵌 CSS。浅色纸面配色，与阅读器浅色主题同一气质。 */
const HTML_CSS: string = `
  body { margin: 0 auto; max-width: 820px; padding: 48px 28px 80px;
         font-family: "HarmonyOS Sans", "PingFang SC", "Microsoft YaHei", sans-serif;
         font-size: 16px; line-height: 1.75; color: #1b1f27; background: #f3f6fb; }
  /* rich 导出的图表容器：markmap-autoloader 要求容器有确定高度 */
  .markmap { width: 100%; height: 420px; }
  .mermaid, .ktx, .gv, .abc, .wfx, .vgl, .puml, .nml, .cjs { width: 100%; overflow-x: auto; text-align: center; }
  .gv svg, .abc svg, .wfx svg, .vgl svg, .puml svg, .nml svg { max-width: 100%; height: auto; }
  .mermaid svg { max-width: 100%; height: auto; }
  /* 快照图是整页截图，圆角卡片外的四个角会被合成成黑色（webPageSnapshot 不带 alpha），
     嵌进导出页就是一圈黑角 —— 图片自身裁圆角把它盖掉，与卡片观感一致 */
  img.chartimg { border-radius: 10px; max-width: 100%; height: auto; }
  /* 打印：屏幕上"能左右滑动"的东西到了纸上就是"少一段"（用户实测超宽公式打印不全）。
     公式由页尾 runner 缩字号等比适配、SVG 由上面的 max-width 等比缩放，容器一律不裁切。 */
  @media print {
    body { max-width: none; padding: 10mm 12mm; background: #fff; }
    .mermaid, .ktx, .gv, .abc, .wfx, .vgl, .puml, .nml, .cjs { overflow: visible; }
    img.chartimg { max-width: 100%; height: auto; }
  }
  /* 行内公式容器（块级 .ktx 的样式会破坏行内流，必须独立）；容器内预填源码，
     JS 未加载 / 渲染失败时以源码兜底显示 */
  .kxi { display: inline-block; vertical-align: middle; max-width: 100%; }
  h1, h2, h3, h4, h5, h6 { line-height: 1.35; margin: 1.6em 0 0.6em; }
  h1 { font-size: 1.75em; } h2 { font-size: 1.42em; border-bottom: 1px solid #e2e6ee; padding-bottom: 0.3em; }
  h3 { font-size: 1.21em; } h4 { font-size: 1.09em; } h5 { font-size: 1em; } h6 { font-size: 0.94em; color: #525a68; }
  p { margin: 0.75em 0; }
  a { color: #2f63e8; text-decoration: none; }
  a:hover { text-decoration: underline; }
  code { font-family: "HarmonyOS Sans SC Mono", Consolas, Menlo, monospace; font-size: 0.88em;
         background: rgba(47,99,232,0.08); color: #2350c4; border-radius: 4px; padding: 0.1em 0.35em; }
  pre { background: #f6f8fb; border: 1px solid #e2e6ee; border-radius: 10px; padding: 14px 16px; white-space: pre-wrap; word-break: break-word; overflow-x: hidden; }
  pre code { background: transparent; color: #1b1f27; padding: 0; }
  .kw { color: #cf222e; } .str { color: #0a3069; } .cmt { color: #6e7781; font-style: italic; }
  .num { color: #0550ae; } .fn { color: #8250df; } .tag { color: #116329; } .attr { color: #0550ae; }
  .add { color: #116329; background: #e6ffec; } .rem { color: #cf222e; background: #ffebe9; }
  .hunk { color: #8250df; background: #fff5e5; }
  .hl { display: block; background: rgba(245,158,11,0.15); } /* 围栏元数据指定的高亮行，与阅读页同色 */
  blockquote { margin: 1em 0; padding: 10px 16px; border-left: 3px solid #2f63e8;
               background: rgba(47,99,232,0.06); border-radius: 6px; color: #3a4150; }
  .callout { margin: 1em 0; padding: 12px 16px; border-left: 3px solid #888; border-radius: 6px; background: rgba(0,0,0,0.04); }
  details { margin: 1em 0; padding: 8px 12px; border: 1px solid #e2e6ee; border-radius: 8px; }
  summary { cursor: pointer; font-weight: 600; }
  .dbody { white-space: pre-line; margin-top: 6px; color: #3a4150; }
  .grouplabel { margin: 0.6em 0 0.2em; font-size: 0.86em; color: #6e7781; }
  .callout .t { font-weight: 600; font-size: 0.85em; letter-spacing: 0.06em; display: block; margin-bottom: 4px; }
  table { border-collapse: collapse; margin: 1em 0; width: 100%; font-size: 0.94em; }
  th, td { border: 1px solid #e2e6ee; padding: 7px 12px; text-align: left; }
  th { background: rgba(27,31,39,0.06); font-weight: 600; }
  tr:nth-child(even) td { background: rgba(27,31,39,0.03); }
  img { max-width: 100%; border-radius: 8px; }
  hr { border: none; border-top: 1px solid #dde2ea; margin: 2em 0; }
  mark { background: #e8f0a0; padding: 0.05em 0.2em; border-radius: 3px; }
  kbd { background: #eef1f7; border: 1px solid #ccd3e0; border-bottom-width: 2px; border-radius: 4px;
        padding: 0.05em 0.4em; font-family: inherit; font-size: 0.86em; color: #1b1f27; }
  ruby rt { font-size: 0.55em; color: #6e7781; }
  .rt { font-size: 0.62em; color: #6e7781; vertical-align: super; margin-left: 0.1em; }
  u { text-decoration: underline; }
  .htmlblk { margin: 1.2em 0; }
  .htmlblk table { border-collapse: collapse; width: 100%; }
  .htmlblk th, .htmlblk td { border: 1px solid #dde2ea; padding: 6px 10px; }
  .htmlblk svg, .htmlblk video, .htmlblk iframe { max-width: 100%; }
  .dldef { margin: 0.15em 0 0.5em 1.6em; }
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

  /**
   * 铭牌组 → HTML（导出用；`<a>` 包住本地绘制的徽标标记）。
   *
   * 与阅读页同一份数据（`MdBlock.badges`，解析期已把 shields 地址解析完），
   * 所以导出网页 / 打印里看到的铭牌与正文里一致，且**不联网**。
   */
  static badgeRow(items: MdBadge[]): string {
    let out: string = '';
    for (let k: number = 0; k < items.length; k++) {
      const b: MdBadge = items[k];
      let one: string = Badge.toHtml(b);
      if (b.href.length > 0) {
        one = '<a href="' + MdToHtml.esc(b.href) + '" style="text-decoration:none">' + one + '</a>';
      }
      if (k > 0) {
        out += '&nbsp;';
      }
      out += one;
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
        // **离线铭牌**：shields 徽章地址在导出里也不能退化成远程 `<img>`
        // （打印/离线打开都是空框）。解析期已能识别的地址在这里直接出本地绘制标记。
        const badgeSpec: MdBadge | null = Badge.parse(item.href);
        if (badgeSpec !== null) {
          badgeSpec.alt = item.text;
          body = Badge.toHtml(badgeSpec);
          continue;
        }
        const alt: string = item.text.length > 0 ? item.text : 'image';
        // imsize（`![alt](a.png =120x60)`）：写成 max-width/max-height，
        // 与阅读页同口径 —— 视口更窄时仍然等比缩，不会把图拉变形
        const capW: number = item.w === undefined ? 0 : item.w;
        const capH: number = item.h === undefined ? 0 : item.h;
        let style: string = '';
        if (capW > 0 || capH > 0) {
          style = ' style="' + (capW > 0 ? 'max-width:' + capW + 'px;' : '')
            + (capH > 0 ? 'max-height:' + capH + 'px;height:auto;' : '') + '"';
        }
        body = '<img alt="' + MdToHtml.esc(alt) + '" src="' + MdToHtml.esc(item.href) + '"' + style + ' />';
      } else if (item.kind === MdInlineKind.Mark) {
        body = '<mark>' + body + '</mark>';
      } else if (item.kind === MdInlineKind.FootnoteRef) {
        const label: string = item.num > 0 ? '' + item.num : MdToHtml.esc(item.text);
        body = '<sup class="fnref">[' + label + ']</sup>';
      } else if (item.kind === MdInlineKind.Code) {
        // 上面已经包过 code
      } else if (item.kind === MdInlineKind.MathInline) {
        // **行内公式**（`$…$` / `\(…\)`）：独立行内容器 + data-b64 携带源码，
        // runner 用 KaTeX 以 displayMode:false 渲染。此前这里没有任何分支——
        // 行内公式以 **LaTeX 源码原文**出现在导出网页里（用户实测
        // "转网页把 latex 没有完全支持"）。容器内预填 esc 后的源码作占位：
        // JS 未加载 / 渲染失败时以源码兜底（可读），渲染成功会被替换。
        body = '<span class="kxi" data-b64="' + MdToHtml.b64(item.text) + '">'
          + MdToHtml.esc(item.text) + '</span>';
      } else if (item.kind === MdInlineKind.Sup) {
        // **上标/下标此前没有分支**：`x^2^` 导出成纯文本 "x2"（阅读页有样式、导出没有）
        body = '<sup>' + body + '</sup>';
      } else if (item.kind === MdInlineKind.Sub) {
        body = '<sub>' + body + '</sub>';
      } else if (item.kind === MdInlineKind.Key) {
        body = '<kbd>' + body + '</kbd>';
      } else if (item.kind === MdInlineKind.Ruby) {
        // 读音单独出现（前面没有基准字可配）时的兜底：仍写成上标，不丢字
        body = '<span class="rt">' + body + '</span>';
      } else if (item.kind === MdInlineKind.Under) {
        body = '<u>' + body + '</u>';
      } else if (item.kind === MdInlineKind.Color || (item.bg !== undefined && item.bg.length > 0)
        || (item.size !== undefined && item.size > 0)) {
        // 字色 / 底色 / 相对字号三条各管各的：徽章是"浅底 + 深字"，`<small>` 只带字号
        const hexColor: string = item.kind === MdInlineKind.Color
          ? MdToHtml.safeHexColor(item.color === undefined ? '' : item.color) : '';
        const hexBg: string = MdToHtml.safeHexColor(item.bg === undefined ? '' : item.bg);
        let decl: string = '';
        if (item.size !== undefined && item.size > 0) {
          decl += 'font-size:' + item.size + 'em;';
        }
        if (hexColor.length > 0) {
          decl += 'color:' + hexColor + ';';
        }
        if (hexBg.length > 0) {
          decl += 'background:' + hexBg + ';';
        }
        if (decl.length > 0) {
          body = '<span style="' + decl + '">' + body + '</span>';
        }
      }
      // 注音配对：解析器把 `<ruby>汉<rt>hàn</rt></ruby>` 拍平成「基准片段 + Ruby 片段」两段。
      // 以前导出只把读音包成 `<span class="rt">`（上标排在**右边**），阅读页已经改成
      // 压在字正上方，两边观感不一致（用户实测"拼音怎么在字符右上角"）。
      // 这里拼成**原生 `<ruby><rt>`**，浏览器自己把读音放到字正上方，与阅读页同形。
      if (item.kind === MdInlineKind.Ruby) {
        // 配上前一个基准片段时，读音已经由那边一起包进 <ruby>；孤立读音留上面的 .rt 上标兜底
        if (k > 0 && items[k - 1].kind !== MdInlineKind.Ruby) {
          continue;
        }
        out += body;
        continue;
      }
      if (k + 1 < items.length && items[k + 1].kind === MdInlineKind.Ruby) {
        out += '<ruby>' + body + '<rt>' + MdToHtml.esc(items[k + 1].text) + '</rt></ruby>';
        continue;
      }
      out += body;
    }
    return out;
  }

  /**
   * 折叠面板正文 → HTML：逐行解析，`- [x]` 收成**真 checkbox**（浏览器原生可点），
   * 其余行按行内语法渲染。与阅读页同口径，导出网页不再显示字面 `- [ ]`。
   */
  static detailsBody(block: MdBlock): string {
    const out: string[] = [];
    const lines: string[] = block.codeLines;
    for (let k = 0; k < lines.length; k++) {
      const line: string = lines[k].trim();
      if (line.length === 0) {
        continue;
      }
      const m: RegExpMatchArray | null = line.match(/^[-*+]\s+\[( |x|X)\]\s*(.*)$/);
      if (m !== null) {
        out.push('<p class="task"><label><input type="checkbox"' + (m[1] === ' ' ? '' : ' checked')
          + ' disabled /> ' + MdToHtml.inline(MdParser.parseInline(m[2])) + '</label></p>');
      } else {
        const bullet: boolean = /^[-*+]\s+\S/.test(line);
        out.push('<p>' + (bullet ? '• ' : '')
          + MdToHtml.inline(MdParser.parseInline(bullet ? line.substring(2).trim() : line)) + '</p>');
      }
    }
    return out.join('');
  }

  /**
   * 只放行十六进制色值（`#RGB` / `#RRGGBB` / `#AARRGGBB`），其余返回空串。
   * 解析器已经过滤过一遍，这里是**写进 style 属性前**的第二道闸：颜色值会被拼进
   * HTML 属性，绝不能让任何带引号、分号或函数调用的串混进来。
   */
  static safeHexColor(raw: string): string {
    if (raw.length === 0 || raw.charAt(0) !== '#') {
      return '';
    }
    const digits: string = raw.substring(1);
    if (digits.length !== 3 && digits.length !== 6 && digits.length !== 8) {
      return '';
    }
    const hex: string = '0123456789abcdefABCDEF';
    for (let k = 0; k < digits.length; k++) {
      if (hex.indexOf(digits.charAt(k)) < 0) {
        return '';
      }
    }
    return raw;
  }

  /** 代码块 → 带语言族高亮的 pre/code。`hl` 是指定高亮行（围栏元数据，1 起）。 */
  static codeBlock(lang: string, lines: string[], hl: number[]): string {
    const family: CodeFamily = resolveFamily(lang);
    const state: CodeState = newCodeState();
    let out: string = '<pre><code>';
    for (let k = 0; k < lines.length; k++) {
      const tokens: CodeToken[] = CodeHighlighter.highlightLine(lines[k], family, state, lang);
      let lineOut: string = '';
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
        } else if (kind === CodeTokenKind.Added) {
          cls = 'add';
        } else if (kind === CodeTokenKind.Removed) {
          cls = 'rem';
        } else if (kind === CodeTokenKind.Hunk) {
          cls = 'hunk';
        }
        lineOut += cls.length > 0 ? '<span class="' + cls + '">' + text + '</span>' : text;
      }
      // 指定行高亮：整行铺琥珀底（与阅读页 #26F59E0B 同一色），空行也要有底所以补一个空格
      out += hl.indexOf(k + 1) >= 0
        ? '<span class="hl">' + (lineOut.length > 0 ? lineOut : ' ') + '</span>'
        : lineOut;
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
    [// zenuml 已在解析层转译成 mermaid，不再作为独立 lang 出现在块里
    // salt / ditaa / nwdiag：澄笺自绘的三个图种，导出时内联同源纯函数渲染库
    'markmap', 'mermaid', 'salt', 'ditaa', 'nwdiag', 'echarts', 'graphviz', 'abc', 'katex', 'flowchart', 'wavedrom',
      'nomnoml', 'chart', 'vega', 'plantuml'];

  private static isChartLang(lang: string): boolean {
    const l: string = lang.trim().toLowerCase();
    for (let k = 0; k < MdToHtml.CHART_LANGS.length; k++) {
      if (MdToHtml.CHART_LANGS[k] === l) {
        return true;
      }
    }
    return false;
  }

  /**
   * 导出视角：该语言依赖的渲染引擎是否已在「设置 → 引擎管理」里关闭。
   *
   * ⚠️ flowchart 在导出侧**借 mermaid 渲染**（阅读侧才用 flowchart.js），
   * 两者任一被关闭都算关——导出统一降级为代码块（关闭后无法渲染，
   * 导出的网页也不能假装能渲染）。`html` 块与未登记语言 → 空引擎 → 恒 false。
   */
  static engineOffForLang(lang: string): boolean {
    const l: string = lang.trim().toLowerCase();
    if (l === 'flowchart') {
      return EngineRegistry.isOff('flowchart', EngineRegistry.current())
        || EngineRegistry.isOff('mermaid', EngineRegistry.current());
    }
    // zenuml 模板 = mermaid 引擎 + zenuml 插件（zenuml.html 由 mermaid.html 派生），
    // 两者任一关闭都画不出 → 同 flowchart 的双闸口径
    if (l === 'zenuml') {
      return EngineRegistry.isOff('zenuml', EngineRegistry.current())
        || EngineRegistry.isOff('mermaid', EngineRegistry.current());
    }
    return EngineRegistry.isOff(EngineRegistry.langId(l), EngineRegistry.current());
  }

  /**
   * 导出侧的 PlantUML → mermaid 源码（时序 / 状态 / 类三类桥得动）。
   * 空串 = 不桥（阅读页有真内核，导出侧退回代码块）；mermaid 引擎被关闭时同样不桥。
   */
  static plantumlForExport(src: string): string {
    if (EngineRegistry.isOff('mermaid', EngineRegistry.current())) {
      return '';
    }
    return PlantumlBridge.toMermaid(src);
  }

  /**
   * 内联模式是否真的带上了某个运行时库。
   * 导出有两条路：`inline != null` 是自包含（库文本已在 head 里），
   * `null` 是 CDN 回退（只有联网才渲染）。"这页能不能画某类图"必须问这个，
   * 不能只看块的语言 —— 容器发出去而库里没带，读者拿到的就是一个洞。
   */
  static hasRuntime(inline: InlineRuntime[] | null, name: string): boolean {
    if (inline === null) {
      return false;
    }
    for (let k = 0; k < inline.length; k++) {
      if (inline[k].name === name) {
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
        // 已关闭引擎的图表不计入：导出会降级为代码块，不需要预装渲染库
        if (!MdToHtml.engineOffForLang(b.lang)) {
          n++;
        }
      } else if (b.kind === MdBlockKind.Math) {
        if (!EngineRegistry.isOff('katex', EngineRegistry.current())) {
          n++;
        }
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

  /** ChartCache.pngEmbed 的返回拆成两半：`\x01` 之前是 data URL，之后是逻辑尺寸 'w|h'。 */
  private static embedPng(embed: string): string {
    const sep: number = embed.indexOf(String.fromCharCode(1));
    return sep > 0 ? embed.substring(0, sep) : embed;
  }

  /**
   * **按逻辑尺寸定宽**（用户实测部分图片过小或被拉伸）：快照的物理像素
   * 尺寸≠该显示的尺寸，`.dim`（或 ChartCache 按像素 ÷ 密度反推的值）才是 vp 口径。
   * **完整画布**（用户要求）：按逻辑尺寸原宽显示，不设 max-width 钳制
   *（宽于页面的图由页面横向滚动承载），保证整张图完整出现在导出/打印里。
   * 量不到尺寸才退回自适应。
   */
  private static embedStyle(embed: string): string {
    const sep: number = embed.indexOf(String.fromCharCode(1));
    if (sep <= 0) {
      return 'max-width:100%;height:auto';
    }
    const wh: string[] = embed.substring(sep + 1).split('|');
    const w: number = wh.length === 2 ? (parseInt(wh[0], 10) || 0) : 0;
    return w > 40 ? 'width:' + w + 'px;height:auto' : 'max-width:100%;height:auto';
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
    if (lang === 'zenuml') {
      // **复用 .mermaid 容器**：导出页的 runner 是同一段 mermaid.render，
      // zenuml 是 mermaid 的**外部图种**（首行 zenuml 由插件的 detector 认），
      // 所以只要插件注册过，这个容器不需要第二条渲染分支
      return '<div class="mermaid" data-b64="' + b64 + '"></div>';
    }
    if (lang === 'salt') {
      return '<div class="cj-salt" data-b64="' + b64 + '"></div>';
    }
    if (lang === 'ditaa') {
      return '<div class="cj-ditaa" data-b64="' + b64 + '"></div>';
    }
    if (lang === 'nwdiag') {
      return '<div class="cj-nwdiag" data-b64="' + b64 + '"></div>';
    }
    if (lang === 'plantuml') {
      // 内核在场时的容器：runner 解码后交给 window.plantumlRenderToString 现场出图
      return '<div class="puml" data-b64="' + b64 + '"></div>';
    }
    if (lang === 'nomnoml') {
      return '<div class="nml" data-b64="' + b64 + '"></div>';
    }
    if (lang === 'chart') {
      // Chart.js 要 canvas（不是 SVG）：源码放外层 div（与其它容器同一读法），
      // canvas 由 runner 塞进容器并按卡片宽定尺寸（responsive:false，避免导出页里无限 resize）
      return '<div class="cjs" data-b64="' + b64 + '"><canvas></canvas></div>';
    }
    if (lang === 'katex') {
      return '<div class="ktx" data-b64="' + b64 + '"></div>';
    }
    if (lang === 'echarts') {
      return '<div class="ech" data-b64="' + b64 + '"" style="width:100%;height:420px"></div>';
    }
    if (lang === 'graphviz') {
      return '<div class="gv" data-b64="' + b64 + '"" style="width:100%;min-height:200px;overflow-x:auto"></div>';
    }
    if (lang === 'abc') {
      return '<div class="abc" data-b64="' + b64 + '"></div>';
    }
    if (lang === 'wavedrom') {
      return '<div class="wfx" data-b64="' + b64 + '"></div>';
    }
    if (lang === 'vega') {
      // Vega-Lite：容器给一个最小高度，SVG 出图后由自身尺寸撑开
      return '<div class="vgl" data-b64="' + b64 + '"" style="width:100%;min-height:200px;overflow-x:auto"></div>';
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
    // ⚠️ 条件是 **inline !== null**（含空数组）：空数组 = "所有图都已有快照、一个渲染库
    // 都不需要"——这是导出全图化的目标形态，绝不能掉进下面的 CDN 回退（那会给导出页
    // 挂上联网脚本，离线打开就残）。null 才是"库读不出来"的回退信号。
    if (inline !== null) {
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
      // 已关闭引擎不注入任何脚本（正文里也不会有它的容器——见 export 的降级逻辑）
      if (MdToHtml.engineOffForLang(lang)) {
        return false;
      }
      for (let k = 0; k < blocks.length; k++) {
        const b: MdBlock = blocks[k];
        const l: string = b.lang.trim().toLowerCase();
        if (b.kind === MdBlockKind.Chart && l === lang) {
          return true;
        }
        if (lang === 'mermaid' && b.kind === MdBlockKind.Chart && l === 'flowchart') {
          return !MdToHtml.engineOffForLang('flowchart');
        }
        // plantuml 块导出走 PlantumlBridge 桥成 mermaid 容器 → 需要 mermaid 的脚本与 runner
        if (lang === 'mermaid' && b.kind === MdBlockKind.Chart && l === 'plantuml'
          && MdToHtml.plantumlForExport(b.code).length > 0) {
          return true;
        }
        if (lang === 'katex' && b.kind === MdBlockKind.Math) {
          return true;
        }
        // 行内公式在导出侧没有图片路径（只有 .kxi 容器现场渲染）——有它同样要 katex
        if (lang === 'katex' && MdToHtml.blockHasInlineMath(b)) {
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
    if (has('mermaid') || has('zenuml')) {
      // CDN 兜底版本跟随包引擎对齐（原来钉在 10.9.3：内联失败时导出页会换一个
      // 更老的 mermaid 渲染，与阅读页观感不一致）。
      // zenuml **不需要插件**：解析层已由 ZenumlBridge 把它转成 mermaid 时序图源码
      // （外部插件那条路在真机上报 Syntax error，资产已随 b7370ba 从包里删除）。
      scripts += '<script src="https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js"></script>\n';
    }
    if (has('nomnoml')) {
      // 顺序不能反：nomnoml 的 UMD 按全局 graphre 取布局引擎
      scripts += '<script src="https://cdn.jsdelivr.net/npm/graphre@0.4.2/index.js"></script>\n'
        + '<script src="https://cdn.jsdelivr.net/npm/nomnoml@1.7.0/dist/nomnoml.js"></script>\n';
    }
    if (has('chart')) {
      scripts += '<script src="https://cdn.jsdelivr.net/npm/chart.js@4.5.1/dist/chart.umd.js"></script>\n';
    }
    if (has('echarts')) {
      scripts += '<script src="https://cdn.jsdelivr.net/npm/echarts@5.5.1/dist/echarts.min.js"></script>\n';
    }
    if (has('vega')) {
      // 顺序不能反：vega-lite 的 UMD 按全局 vega 取依赖
      scripts += '<script src="https://cdn.jsdelivr.net/npm/vega@6.4.0/build/vega.min.js"></script>\n'
        + '<script src="https://cdn.jsdelivr.net/npm/vega-lite@6.5.0/build/vega-lite.min.js"></script>\n';
    }
    if (has('abc')) {
      // 版本跟包里那份对齐（原来钉 6.4.4，实际随包是 6.7.1）
      scripts += '<script src="https://cdn.jsdelivr.net/npm/abcjs@6.7.1/dist/abcjs-basic-min.js"></script>\n';
    }
    if (has('wavedrom')) {
      // 皮肤必须先于主库：wavedrom 读全局 WaveSkin，缺皮肤直接抛 "no skins found"
      scripts += '<script src="https://cdn.jsdelivr.net/npm/wavedrom@3.7.0/skins/default.js"></script>\n'
        + '<script src="https://cdn.jsdelivr.net/npm/wavedrom@3.7.0/wavedrom.min.js"></script>\n';
    }
    if (has('katex')) {
      // 版本与仓库里打包的 KaTeX 对齐（0.19.0）：内联模式用的是本地打包件，
      // CDN 模式若停在别的版本，同一份文档两种导出会有不同渲染结果。
      // mhchem 必须在 katex 之后：它把自己的 \ce / \pu 注册到当时已存在的 katex 上。
      scripts += '<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/katex.min.css" />\n'
        + '<script src="https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/katex.min.js"></script>\n'
        + '<script src="https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/contrib/mhchem.min.js"></script>\n';
    }
    if (scripts.length === 0) {
      const none: ChartAssets = { head: '', runner: '' };
      return none;
    }
    const done2: ChartAssets = { head: scripts, runner: MdToHtml.chartRunner(blocks) };
    return done2;
  }

  /** 页尾 runner：解码各容器的 Base64 内容并调对应渲染库绘制（内联 / CDN 共用）。 */
  /**
   * **这个块里有没有行内公式**（`$…$` / `\(…\)` → `MdInlineKind.MathInline`）。
   *
   * 用途（2026-10-16 用户实测修复）：行内公式在导出侧**没有图片路径**——只有
   * `<span class="kxi">` 容器 + KaTeX 现场渲染（见 inline() 的 MathInline 分支）。
   * 所以"文档里存在行内公式" = **katex 渲染库必须带**。此前 needed 收集与
   * chartRunner 的 has('katex') 都只查 `MdBlockKind.Math`（块级）——"块级公式
   * 全有快照 → 零库导出"时，行内公式整片显示成 LaTeX 源码（用户报"行内公式
   * 没有正常渲染"）。这条判定补上那个缺口。
   */
  static blockHasInlineMath(b: MdBlock): boolean {
    const items: MdInline[] = b.inlines;
    if (items === undefined || items.length === 0) {
      return false;
    }
    for (let k = 0; k < items.length; k++) {
      if (items[k].kind === MdInlineKind.MathInline) {
        return true;
      }
    }
    return false;
  }

  /** 整篇文档有没有行内公式（供"要不要带 katex 库"的统一判定，见 blockHasInlineMath）。 */
  static hasInlineMath(blocks: MdBlock[]): boolean {
    for (let k = 0; k < blocks.length; k++) {
      if (MdToHtml.blockHasInlineMath(blocks[k])) {
        return true;
      }
    }
    return false;
  }

  private static chartRunner(blocks: MdBlock[]): string {
    const has = (lang: string): boolean => {
      // 与 chartAssets 同一套门控：已关闭引擎既没有容器也没有渲染库，runner 不出它的代码
      if (MdToHtml.engineOffForLang(lang)) {
        return false;
      }
      for (let k = 0; k < blocks.length; k++) {
        const b: MdBlock = blocks[k];
        const l: string = b.lang.trim().toLowerCase();
        if (b.kind === MdBlockKind.Chart && l === lang) {
          return true;
        }
        if (lang === 'mermaid' && b.kind === MdBlockKind.Chart && l === 'flowchart') {
          return !MdToHtml.engineOffForLang('flowchart');
        }
        // plantuml 块导出走 PlantumlBridge 桥成 mermaid 容器 → 需要 mermaid 的脚本与 runner
        if (lang === 'mermaid' && b.kind === MdBlockKind.Chart && l === 'plantuml'
          && MdToHtml.plantumlForExport(b.code).length > 0) {
          return true;
        }
        if (lang === 'katex' && b.kind === MdBlockKind.Math) {
          return true;
        }
        // 行内公式在导出侧没有图片路径（只有 .kxi 容器现场渲染）——有它同样要 katex
        if (lang === 'katex' && MdToHtml.blockHasInlineMath(b)) {
          return true;
        }
      }
      return false;
    };
    const runnerCode: string = '\n<script>\n(function() {\n'
      + '  function b64u(b64) { var bin = atob(b64); var u = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) { u[i] = bin.charCodeAt(i); } return new TextDecoder().decode(u); }\n'
      + '  function tryRun(fn) { try { fn(); } catch (e) { console.error("chart render failed", e); } }\n'
      + '  // 渲染失败时的源码兜底（各图种共用）：源码要能安全塞进 <pre>\n'
      + '  function escPre(s) {\n'
      + '    return String(s).replace(/&/g, "\\u0026amp;").replace(/</g, "\\u0026lt;").replace(/>/g, "\\u0026gt;");\n'
      + '  }\n'
      + (has('katex') ? '  // 宏定义宽容化（与 render/katex.html 的 __normalizeMacros 保持一致）：\n'
        + '  // \\newcommand / \\renewcommand / \\providecommand → \\def —— KaTeX 内置 texvc 宏\n'
        + '  // （\\R=\\mathbb{R} 等）与用户宏同名时会报 "attempting to redefine"，\\def 可静默覆盖。\n'
        + '  function normalizeMacros(s) {\n'
        + '    try {\n'
        + '      var out = ""; var last = 0; var n = s.length; var changed = false;\n'
        + '      var re = /\\\\(newcommand|renewcommand|providecommand)\\b/g;\n'
        + '      var m;\n'
        + '      while ((m = re.exec(s)) !== null) {\n'
        + '        var start = m.index;\n'
        + '        if (start < last) { continue; }\n'
        + '        var j = start + m[0].length;\n'
        + '        while (j < n && /\\s/.test(s.charAt(j))) { j++; }\n'
        + '        if (s.charAt(j) === "*") { j++; }\n'
        + '        while (j < n && /\\s/.test(s.charAt(j))) { j++; }\n'
        + '        var name = "";\n'
        + '        if (s.charAt(j) === "{") {\n'
        + '          var k = j + 1; var inner = "";\n'
        + '          while (k < n && s.charAt(k) !== "}") { inner += s.charAt(k); k++; }\n'
        + '          if (k < n && inner.charAt(0) === "\\\\") { name = inner.substring(1).trim(); j = k + 1; }\n'
        + '        } else if (s.charAt(j) === "\\\\") {\n'
        + '          var k2 = j + 1;\n'
        + '          while (k2 < n && /[a-zA-Z]/.test(s.charAt(k2))) { k2++; }\n'
        + '          if (k2 > j + 1) { name = s.substring(j + 1, k2); j = k2; }\n'
        + '        }\n'
        + '        if (name.length === 0) { continue; }\n'
        + '        while (j < n && /\\s/.test(s.charAt(j))) { j++; }\n'
        + '        var argc = 0;\n'
        + '        if (s.charAt(j) === "[") {\n'
        + '          var k3 = j + 1; var num = "";\n'
        + '          while (k3 < n && s.charAt(k3) !== "]") { num += s.charAt(k3); k3++; }\n'
        + '          var p = parseInt(num, 10);\n'
        + '          if (k3 < n && !isNaN(p) && p >= 0 && p <= 9) { argc = p; j = k3 + 1; }\n'
        + '        }\n'
        + '        while (j < n && /\\s/.test(s.charAt(j))) { j++; }\n'
        + '        if (s.charAt(j) !== "{") { continue; }\n'
        + '        var depth = 0; var k4 = j; var end = -1;\n'
        + '        while (k4 < n) {\n'
        + '          var c = s.charAt(k4);\n'
        + '          if (c === "\\\\") { k4 += 2; continue; }\n'
        + '          if (c === "{") { depth++; }\n'
        + '          else if (c === "}") { depth--; if (depth === 0) { end = k4; break; } }\n'
        + '          k4++;\n'
        + '        }\n'
        + '        if (end < 0) { continue; }\n'
        + '        var body = s.substring(j, end + 1);\n'
        + '        var params = "";\n'
        + '        for (var q = 1; q <= argc; q++) { params += "#" + q; }\n'
        + '        out += s.substring(last, start) + "\\\\def\\\\" + name + params + body;\n'
        + '        last = end + 1;\n'
        + '        re.lastIndex = last;\n'
        + '        changed = true;\n'
        + '      }\n'
        + '      if (!changed) { return s; }\n'
        + '      return out + s.substring(last);\n'
        + '    } catch (e) { return s; }\n'
        + '  }\n'
        + '  // 公式渲染（块级 display / 行内）：常规失败且是宏重定义类问题时用宽容化源码重试一次\n'
        + '  function fitKx(el) {\n'
        + '    var k = el.querySelector(".katex");\n'
        + '    if (!k) { return; }\n'
        + '    var avail = el.clientWidth || (el.parentNode ? el.parentNode.clientWidth : 0);\n'
        + '    if (!(avail > 0)) { return; }\n'
        + '    for (var pass = 0; pass < 10; pass++) {\n'
        + '      var rg = document.createRange();\n'
        + '      rg.selectNodeContents(k);\n'
        + '      var rr = rg.getClientRects();\n'
        + '      var lf = 1e9, rt = -1e9;\n'
        + '      for (var j = 0; j < rr.length; j++) {\n'
        + '        if (rr[j].left < lf) { lf = rr[j].left; }\n'
        + '        if (rr[j].right > rt) { rt = rr[j].right; }\n'
        + '      }\n'
        + '      var w = rt - lf;\n'
        + '      if (w <= avail + 1) { return; }\n'
        + '      // 装不下就先**左对齐**：居中排版时溢出会分在两侧，左边那一截既看不见也滑不到\n'
        + '      el.style.textAlign = "left";\n'
        + '      var cur = parseFloat(el.style.fontSize);\n'
        + '      if (!(cur > 0)) { cur = 100; }\n'
        + '      var next = Math.floor(cur * (avail - 10) / w);\n'
        + '      if (next >= cur) { next = cur - 4; }\n'
        + '      // **下限 55%**：再小矩阵 / cases 就糊成一排点（用户实测"公式块过小"，\n'
        + '      // 5 个 pmatrix 并排那一格被压到 30% 时字高只有 7px）。\n'
        + '      // 装不下就靠容器横向滚动看全，而不是把字压到不可读。\n'
        + '      if (next < 55) { next = 55; }\n'
        + '      el.style.fontSize = next + "%";\n'
        + '      if (next <= 55) { el.style.overflowX = "auto"; return; }\n'
        + '    }\n'
        + '  }\n'
        + '  function renderKx(el, display) {\n'
        + '    var s = b64u(el.dataset.b64);\n'
        + '    var opt = { displayMode: display, throwOnError: false };\n'
        + '    el.innerHTML = "";\n'
        + '    el.style.fontSize = "";\n'
        + '    katex.render(s, el, opt);\n'
        + '    if (el.querySelector(".katex-error")) {\n'
        + '      var s2 = normalizeMacros(s);\n'
        + '      if (s2 !== s) { el.innerHTML = ""; katex.render(s2, el, opt); }\n'
        + '    }\n'
        + '    if (display) { fitKx(el); }\n'
        + '  }\n' : '')
      + '  window.addEventListener("load", function() {\n'
      + (has('salt') || has('ditaa') || has('nwdiag')
        ? '    if (window.__chengjianRender) {\n'
        + '      var cjMap = { "cj-salt": "salt", "cj-ditaa": "ditaa", "cj-nwdiag": "nwdiag" };\n'
        + '      Object.keys(cjMap).forEach(function(cls) {\n'
        + '        var fn = window.__chengjianRender[cjMap[cls]];\n'
        + '        if (!fn) { return; }\n'
        + '        document.querySelectorAll("." + cls).forEach(function(el) {\n'
        + '          try {\n'
        + '            el.innerHTML = fn(b64u(el.dataset.b64));\n'
        + '            el.style.overflowX = "auto";\n'
        + '          } catch (e) { console.error("selfdraw render failed", e); }\n'
        + '        });\n'
        + '      });\n'
        + '    }\n'
        : '')
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
      + (has('mermaid') || has('zenuml') ? '    // 内联模式带的打包件与阅读页模板同一份（esbuild IIFE，只挂 '
        + '__esbuild_esm_mermaid）；\n'
        + '    // CDN 模式的 UMD 直接挂 window.mermaid。这里补齐前者，两种模式共用下面这段。\n'
        + '    // zenuml 不需要注册：解析层 ZenumlBridge 已把它翻成 mermaid 时序图源码，\n'
        + '    // 容器也是 .mermaid（外部插件那条路真机报 Syntax error，资产已从包里删除）。\n'
        + '    if (!window.mermaid && window.__esbuild_esm_mermaid) {\n'
        + '      window.mermaid = window.__esbuild_esm_mermaid.default;\n'
        + '    }\n'
        + '    if (window.mermaid) {\n'
        + '      tryRun(function() { mermaid.initialize({ startOnLoad: false }); });\n'
        + '      document.querySelectorAll(".mermaid").forEach(async function(el, i) {\n'
        + '        try {\n'
        + '          var r = await mermaid.render("mmd" + i, b64u(el.dataset.b64));\n'
        + '          el.innerHTML = r.svg;\n'
        + '        } catch (e) { console.error("mermaid render failed", e); }\n'
        + '      });\n'
        + '    }\n' : '')
      + (has('nomnoml') ? '    // nomnoml 极简 UML：与阅读页同一份 graphre + nomnoml（UMD，\n'
        + '    // 导出侧此前**既没容器也没库，整块直接消失** —— 待办 #51 的正身）。\n'
        + '    if (window.nomnoml) {\n'
        + '      document.querySelectorAll(".nml").forEach(function(el) {\n'
        + '        var src = b64u(el.dataset.b64);\n'
        + '        try {\n'
        + '          var out = nomnoml.renderSvg(src, document);\n'
        + '          if (out && typeof out.then === "function") {\n'
        + '            out.then(function (t) { el.innerHTML = t; })\n'
        + '              .catch(function () { el.innerHTML = "<pre>" + escPre(src) + "</pre>"; });\n'
        + '          } else if (out && out.nodeType) { el.appendChild(out); }\n'
        + '          else if (typeof out === "string") { el.innerHTML = out; }\n'
        + '          else { el.innerHTML = "<pre>" + escPre(src) + "</pre>"; }\n'
        + '        } catch (e) {\n'
        + '          el.innerHTML = "<pre>" + escPre(src) + "</pre>";\n'
        + '          console.error("nomnoml render failed", e);\n'
        + '        }\n'
        + '      });\n'
        + '    }\n' : '')
      + (has('chart') ? '    // Chart.js 统计图（canvas）：配置就是容器里那份 JSON。\n'
        + '    // 浅色常量与 render/chart.html 成对写死的那套保持一致（深色导出不做，\n'
        + '    // 导出页本身是浅色文档）；数据集没给色时按类型补默认色，否则浅色底上看不见。\n'
        + '    if (window.Chart) {\n'
        + '      Chart.defaults.color = "#2A2F3A";\n'
        + '      Chart.defaults.borderColor = "rgba(0,0,0,0.14)";\n'
        + '      var PAL = ["#2F63E8", "#E8603B", "#1F9E66", "#8A5AF0", "#E08000", "#0E8FA8"];\n'
        + '      document.querySelectorAll(".cjs").forEach(function(el, i) {\n'
        + '        var cv = el.querySelector("canvas");\n'
        + '        if (!cv) { return; }\n'
        + '        var src = b64u(el.dataset.b64);\n'
        + '        try {\n'
        + '          var cfg = JSON.parse(src);\n'
        + '          cfg.options = cfg.options || {};\n'
        + '          cfg.options.responsive = false; cfg.options.animation = false;\n'
        + '          cfg.options.maintainAspectRatio = false;\n'
        + '          var w = Math.max(320, Math.min(el.parentNode ? el.parentNode.clientWidth || 900 : 900, 1200));\n'
        + '          cv.width = w; cv.height = 420;\n'
        + '          cv.style.maxWidth = "100%";\n'
        + '          var t = (cfg.type || "").toLowerCase();\n'
        + '          var ds = (cfg.data && cfg.data.datasets) || [];\n'
        + '          for (var k = 0; k < ds.length; k++) {\n'
        + '            var d = ds[k] || {}; var c = PAL[k % PAL.length];\n'
        + '            if (t === "line" || t === "radar") {\n'
        + '              if (!d.borderColor) { d.borderColor = c; }\n'
        + '              if (!d.backgroundColor) { d.backgroundColor = "rgba(0,0,0,0)"; }\n'
        + '              if (!d.pointBackgroundColor) { d.pointBackgroundColor = c; }\n'
        + '            } else if (!d.backgroundColor) {\n'
        + '              d.backgroundColor = c;\n'
        + '              d.borderColor = c;\n'
        + '            }\n'
        + '          }\n'
        + '          new Chart(cv, cfg);\n'
        + '        } catch (e) {\n'
        + '          el.innerHTML = "<pre>" + escPre(src) + "</pre>";\n'
        + '          console.error("chart.js render failed", e);\n'
        + '        }\n'
        + '      });\n'
        + '    }\n' : '')
      + (has('katex') ? '    if (window.katex) {\n'
        + '      document.querySelectorAll(".ktx").forEach(function(el) {\n'
        + '        tryRun(function() { renderKx(el, true); });\n'
        + '      });\n'
        + '      document.querySelectorAll(".kxi").forEach(function(el) {\n'
        + '        tryRun(function() { renderKx(el, false); });\n'
        + '      });\n'
        + '    }\n' : '')
      + (has('echarts') ? '    if (window.echarts) {\n'
        + '      document.querySelectorAll(".ech").forEach(function(el) {\n'
        + '        tryRun(function() { var opt = (new Function("return (" + b64u(el.dataset.b64) + ")"))(); echarts.init(el).setOption(opt); });\n'
        + '      });\n'
        + '    }\n' : '')
      + (has('graphviz') ? '    if (window.Viz) {\n'
        + '      Viz.instance().then(function(viz) {\n'
        + '        document.querySelectorAll(".gv").forEach(function(el) {\n'
        + '          try { el.innerHTML = viz.renderString(b64u(el.dataset.b64), { format: "svg" }); }\n'
        + '          catch (e) { console.error("graphviz render failed", e); }\n'
        + '        });\n'
        + '      }, function(e) { console.error("viz init failed", e); });\n'
        + '    }\n' : '')
      + (has('abc') ? '    if (window.ABCJS) {\n'
        + '      document.querySelectorAll(".abc").forEach(function(el) {\n'
        + '        // 与 render/abc.html 同参：responsive resize（乐谱随容器宽自适应），\n'
        + '        // 缺了这组参数渲染尺寸会塌（用户实测只画出碎片）\n'
        + '        tryRun(function() { ABCJS.renderAbc(el, b64u(el.dataset.b64), { responsive: \'resize\', foreground: \'#1B1F27\' }); });\n'
        + '      });\n'
        + '    }\n' : '')
      + (has('wavedrom') ? '    if (window.WaveDrom) {\n'
        + '      // 与 render/wavedrom.html 的 fix() 同源：WaveJSON 常写成宽松 JS（键名不带引号），\n'
        + '      // 直接 JSON.parse 会抛错（用户实测导出后波形显示成源码）\n'
        + '      var wdFix = function (x) { return x.replace(/([{,]\\s*)([A-Za-z_][A-Za-z0-9_]*)\\s*:/g, \'$1"$2":\'); };\n'
        + '      document.querySelectorAll(".wfx").forEach(function(el, i) {\n'
        + '        var raw = b64u(el.dataset.b64);\n'
        + '        var src = null;\n'
        + '        try { src = JSON.parse(wdFix(raw)); } catch (e1) { try { src = JSON.parse(raw); } catch (e2) {} }\n'
        + '        if (src === null) { el.textContent = raw; return; }\n'
        + '        try {\n'
        + '          el.innerHTML = \'<div id="WaveDrom_Display_\' + i + \'"></div>\';\n'
        + '          window.WaveDrom.RenderWaveForm(i, src, "WaveDrom_Display_");\n'
        + '        } catch (e) { console.error("wavedrom render failed", e); el.textContent = raw; }\n'
        + '      });\n'
        + '    }\n' : '')
      + (has('vega') ? '    if (window.vega && window.vegaLite) {\n'
        + '      document.querySelectorAll(".vgl").forEach(function(el) {\n'
        + '        try {\n'
        + '          var sp = JSON.parse(b64u(el.dataset.b64));\n'
        + '          if (sp.width === undefined) { sp.width = Math.max(240, el.clientWidth - 8); }\n'
        + '          if (sp.height === undefined) { sp.height = 240; }\n'
        + '          var v = new vega.View(vega.parse(vegaLite.compile(sp).spec),\n'
        + '            { renderer: "svg", logLevel: vega.Warn, header: null, footer: null });\n'
        + '          v.toSVG().then(function(svg) { el.innerHTML = svg; },\n'
        + '            function(e) { console.error("vega render failed", e); el.textContent = b64u(el.dataset.b64); });\n'
        + '        } catch (e) { console.error("vega render failed", e); el.textContent = b64u(el.dataset.b64); }\n'
        + '      });\n'
        + '    }\n' : '')
      + (has('plantuml') ? '    // PlantUML 内核（runtimes/plantuml-kernel.js：viz-global + themes +\n'
        + '    // openiconic + 引擎，全普通脚本，挂 window.plantumlRenderToString）。\n'
        + '    // 与阅读页模板同源，所以导出与阅读页画的是**同一套官方渲染**，不再是桥出来的简化图。\n'
        + '    // ⚠️ 必须**一张一张串行**渲染：内核是 TeaVM 编译的，renderToString 共用一组模块级\n'
        + '    // 全局状态，并发调用会互相覆盖（实测 11 张一起发只有第一张出图，其余容器永久空着）。\n'
        + '    // 单张超时或失败 → 退回显示源码，绝不留空洞。深色不在导出里做（导出页是浅色文档）。\n'
        + '    if (window.plantumlRenderToString) {\n'
        + '      var pEsc = function (s) {\n'
        + '        return String(s).replace(/&/g, "\\u0026amp;").replace(/</g, "\\u0026lt;").replace(/>/g, "\\u0026gt;");\n'
        + '      };\n'
        + '      var pNodes = Array.prototype.slice.call(document.querySelectorAll(".puml"));\n'
        + '      var pIdx = 0;\n'
        + '      var pRun = function () {\n'
        + '        if (pIdx >= pNodes.length) { return; }\n'
        + '        var el = pNodes[pIdx++];\n'
        + '        var src = b64u(el.dataset.b64);\n'
        + '        var done = false;\n'
        + '        var pFail = function () {\n'
        + '          if (el.querySelector("svg") === null) { el.innerHTML = "<pre>" + pEsc(src) + "</pre>"; }\n'
        + '          pRun();\n'
        + '        };\n'
        + '        var timer = setTimeout(function () { if (done) { return; } done = true; pFail(); }, 20000);\n'
        + '        try {\n'
        + '          window.plantumlRenderToString(src.split("\\n"), function (out) {\n'
        + '            if (done) { return; } done = true; clearTimeout(timer);\n'
        + '            var svg = typeof out === "string" ? out : String(out);\n'
        + '            if (/<svg/i.test(svg)) { el.innerHTML = svg; pRun(); } else { pFail(); }\n'
        + '          }, function () { if (done) { return; } done = true; clearTimeout(timer); pFail(); }, undefined);\n'
        + '        } catch (e) {\n'
        + '          if (!done) { done = true; clearTimeout(timer); } pFail();\n'
        + '          console.error("plantuml render failed", e);\n'
        + '        }\n'
        + '      };\n'
        + '      pRun();\n'
        + '    }\n' : '')
      + '  });\n'
      + '    // 图表/公式点击 → 上报宿主打开裁切（用户要求：打印页点击卡片图进入编辑）；\n'
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
    inline: InlineRuntime[] | null = null, ctx: common.UIAbilityContext | null = null,
    dark: boolean = false, chartBg: string = ''): string {
    let body: string = '';
    // **快照图去重清单**（用户实测：一张图同时出现在好多个图表里）：缓存索引/键
    // 万一命中同一份 PNG（键碰撞或索引异常），后续图不能跟着错——同一张 dataURL
    // 只许内嵌一次，后面的图退回各自的渲染容器（mermaid / 内核 / 自绘库）自己画。
    const usedPngs: string[] = [];
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
          // 显式锚点 `## 标题 {#intro}` → <h* id="intro">（解析器已把 {#…} 从标题文本里取走）
          const anc: string = block.anchor === undefined ? '' : block.anchor;
          body += '<h' + block.level + (anc.length > 0 ? ' id="' + MdToHtml.esc(anc) + '"' : '')
            + '>' + MdToHtml.inline(block.inlines) + '</h' + block.level + '>';
        } else if (block.kind === MdBlockKind.Paragraph) {
          // **铭牌段**（解析期识别出的 shields 徽章组）走本地绘制标记，
          // 否则导出网页里的徽章会因远程图片拉不到而变成空框。
          const badges: MdBadge[] | undefined = block.badges;
          if (badges !== undefined && badges.length > 0) {
            body += '<p>' + MdToHtml.badgeRow(badges) + '</p>';
          } else {
            body += '<p>' + MdToHtml.inline(block.inlines) + '</p>';
          }
        } else if (block.kind === MdBlockKind.Chart) {
          // 图表块：rich 且语言受支持 → 渲染容器（渲染库内联）；
          // flowchart 语法 → 转换为 mermaid 渲染；graphviz 等无方案 → 保持代码块。
          // 「设置 → 引擎管理」里关闭了对应引擎 → 一律保持代码块（关闭后无法渲染，
          // 导出的网页也不能假装能渲染；与阅读页源码兜底卡同一语义）。
          const langLower: string = block.lang.trim().toLowerCase();
          // **缓存图优先**（用户要求：导出 / 打印直接展示完整图）：
          // 阅读页预渲染池已把每张图（PlantUML 全家族 / mermaid / 自绘图种…）
          // 烘成 PNG，导出直接内嵌 base64 —— 离线打开、打印都是所见即所得。
          let pngEmbed: string = '';
          // **wavedrom / abc 回归"快照优先"**（2026-10-16）：这两类曾因"快照图内容错误"
          // 被排除走渲染库。根因已取证实锤为**"跨页面串图"**——切模板页的窗口里旧页面的
          // 尺寸残报骗过池子、把别的图存进了它的键（用户机上 wavedrom 的键下存的是
          // 另一篇文档的流程图，内容含 Pandoc）。现由 DiagramWeb 的页面切换窗口
          // （pageLoading）治本 + v25 升键作废旧图，这两类回到与其它图种同一口径。
          // html 块保持排除：它的产物是**可交互网页**，截图不适用（要能点能跑）。
          const pngSkip: boolean = langLower === 'html';
          if (ctx !== null && !pngSkip && !MdToHtml.engineOffForLang(langLower)) {
            // pngEmbed = 快照图 + .dim 逻辑尺寸（导出页据此按原始宽显示，不拉伸不过小）
            pngEmbed = ChartCache.pngEmbed(ctx, langLower, block.code, dark, chartBg);
          }
          const pngFound: string = MdToHtml.embedPng(pngEmbed);
          if (pngFound.length > 0 && usedPngs.indexOf(pngFound) < 0) {
            body += '<img class="chartimg" src="' + pngFound
              + '" style="' + MdToHtml.embedStyle(pngEmbed) + '">';
            usedPngs.push(pngFound);
            chartIndex++;
          } else if (langLower === 'html') {
            // **HTML 块原样输出**：它本身就是渲染结果（表格 colspan/rowspan、内嵌 SVG、
            // 进度条这类排版没有"渲染库"可言，也不该退化成代码块）。
            // 解析器对**自动识别**的块级 HTML 已经过安全闸（摘 script/iframe/on*/javascript:），
            // 用户主动写的 ```html 围栏保持原样——导出与阅读页看到的是同一段。
            body += '<div class="htmlblk">' + block.code + '</div>';
          } else if (MdToHtml.engineOffForLang(langLower)) {
            body += MdToHtml.codeBlock(block.lang, block.codeLines, []);
          } else if (rich && langLower === 'flowchart') {
            body += MdToHtml.chartContainer('mermaid',
              [MdToHtml.flowchartToMermaid(block.code)]);
            chartIndex++;
          } else if (rich && langLower === 'plantuml') {
            // 用户拍板"导出必带 PlantUML 内核"：阅读页那 11 类（用例 / 活动 / 组件 / 部署 /
            // mindmap / WBS / 甘特 / JSON / YAML / Archimate / ER）只有内核画得出来，
            // 光靠"桥成 mermaid"它们就只能退成代码块。
            // 优先级：**快照 > 内核 > 桥 > 源码**。
            //  · 快照在上面已经试过（上面 pngFound 分支），有就直接用——它连深色都对得上；
            //  · 没快照则内联 runtimes/plantuml-kernel.js（5.5MB 普通脚本），离线打开现场出图；
            //  · 内核没在手（CDN 回退模式：@plantuml/core 没有可用的浏览器全局版 CDN 产物）
            //    → 才回到 PlantumlBridge 的三张图，桥不动的留源码。
            if (MdToHtml.hasRuntime(inline, 'plantuml-kernel.js')) {
              body += MdToHtml.chartContainer('plantuml', block.codeLines);
              chartIndex++;
            } else {
              const bridged: string = MdToHtml.plantumlForExport(block.code);
              if (bridged.length > 0) {
                body += MdToHtml.chartContainer('mermaid', [bridged]);
                chartIndex++;
              } else {
                body += MdToHtml.codeBlock(block.lang, block.codeLines, []);
              }
            }
          } else if (rich && MdToHtml.isChartLang(langLower)) {
            body += MdToHtml.chartContainer(langLower, block.codeLines);
            chartIndex++;
          } else {
            body += MdToHtml.codeBlock(block.lang, block.codeLines, []);
          }
        } else if (block.kind === MdBlockKind.Math && ctx !== null
          && !EngineRegistry.isOff('katex', EngineRegistry.current())) {
          // **与图表同一条路**：pngEmbed 同时带回快照图与逻辑尺寸。
          // 上一版这里用 pngBase64（只有图、没有尺寸），只能写 max-width:100% →
          // 浏览器按物理像素显示 = 放大 density 倍（用户实测导出的公式块比正文大
          // 两三倍，而旁边没有快照的公式走 KaTeX 现场渲染又很小 —— 同一种东西两种尺寸）。
          const mathEmbed: string = ChartCache.pngEmbed(ctx, 'katex', block.code, dark, chartBg);
          const mathPng: string = MdToHtml.embedPng(mathEmbed);
          if (mathPng.length > 0 && usedPngs.indexOf(mathPng) < 0) {
            body += '<img class="chartimg" src="' + mathPng
              + '" style="' + MdToHtml.embedStyle(mathEmbed) + '">';
            usedPngs.push(mathPng);
            chartIndex++;
          } else {
            body += MdToHtml.chartContainer('katex', [block.code]);
            chartIndex++;
          }
        } else if (block.kind === MdBlockKind.Math && rich) {
          // rich 模式：公式块转 katex 容器；KaTeX 关闭 → 保持源码代码块
          if (EngineRegistry.isOff('katex', EngineRegistry.current())) {
            body += MdToHtml.codeBlock('latex', [block.code], []);
          } else {
            body += MdToHtml.chartContainer('katex', [block.code]);
            chartIndex++;
          }
        } else if (block.kind === MdBlockKind.Code) {
          body += MdToHtml.codeBlock(block.lang, block.codeLines,
            block.hlLines === undefined ? [] : block.hlLines);
        } else if (block.kind === MdBlockKind.Quote) {
          // 嵌套引用：按层级套对应层数的 <blockquote>（indent 0 = 一层）
          let quote: string = '<blockquote>' + MdToHtml.inline(block.inlines) + '</blockquote>';
          for (let d = 0; d < block.indent; d++) {
            quote = '<blockquote>' + quote + '</blockquote>';
          }
          body += quote;
        } else if (block.kind === MdBlockKind.Callout) {
          body += '<div class="callout" style="border-left-color:' + calloutColor(block.callout) + '">'
            + '<span class="t" style="color:' + calloutColor(block.callout) + '">'
            + calloutTitle(block.callout) + '</span>'
            + MdToHtml.inline(block.inlines) + '</div>';
        } else if (block.kind === MdBlockKind.Table) {
          body += MdToHtml.table(block);
        } else if (block.kind === MdBlockKind.Divider) {
          body += '<hr />';
        } else if (block.kind === MdBlockKind.Details) {
          // 折叠面板：浏览器原生 <details> 就能开合，导出网页里保持"能折叠"这件事。
          // ⚠️ 正文**逐行走行内解析**，不是 esc(原文)：以前面板里的 `- [x] 事项` 在导出
          // 网页里是字面 `- [x]`，与阅读页（真勾选框）两套结果。
          body += '<details' + (block.open === true ? ' open' : '') + '>'
            + '<summary>' + MdToHtml.inline(block.inlines) + '</summary>'
            + '<div class="dbody">' + MdToHtml.detailsBody(block) + '</div>'
            + '</details>';
        } else if (block.kind === MdBlockKind.CodeGroup) {
          // 代码组：导出的静态网页没有页签脚本，退成"每段一个带标题的代码块"。
          // 内容一段不丢，只是不切换——阅读页那边是真 tab。
          const gs: GroupCode[] = block.groupCodes === undefined ? [] : block.groupCodes;
          for (let g = 0; g < gs.length; g++) {
            body += '<p class="grouplabel">' + MdToHtml.esc(gs[g].label) + '</p>'
              + MdToHtml.codeBlock(gs[g].lang, gs[g].code.split('\n'), []);
          }
        } else if (block.footnoteNo > 0) {
          body += '<p class="foot">' + MdToHtml.esc(block.marker) + ' '
            + MdToHtml.inline(block.inlines) + '</p>';
        }
        continue;
      }

      // 列表项
      const depth: number = block.indent + 1;
      const ordered: boolean = block.ordered;
      // **定义列表的定义行**（marker 空串且非任务项）不进 <ul>：
      // 它在源码里不是一条并列条目，而是上一条术语的解释，导出成缩进段更贴近原意，
      // 也不会让"术语 + 定义"被读成一堆无关节点。
      if (!ordered && block.marker.length === 0
        && block.task !== MdTaskState.Todo && block.task !== MdTaskState.Done) {
        closeTo(0);
        body += '<p class="dldef">' + MdToHtml.inline(block.inlines) + '</p>';
        continue;
      }
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
