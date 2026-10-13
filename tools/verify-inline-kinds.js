#!/usr/bin/env node
/**
 * 行内片段种类的**渲染覆盖率**检查（只读代码，不改代码）
 * ==================================================
 *
 * 起因：`MdInlineKind` 里加了新种类、或旧种类改了语义，只要**两个渲染器**之一没跟上，
 * 表现就是"阅读页正常、导出到网页却丢样式"，或者反过来——**当场不报错，静默降级成纯文本**。
 * 真材实料的一例：`Sup` / `Sub`（`x^2^`、`H~2~O`）在 MdView 里有字号与基线，
 * `MdToHtml.inline()` 里**一个分支都没有**，导出网页里就变成了 "x2"、"H2O"，
 * 用户只看得到"公式没渲染"，谁也想不到是导出侧漏了分支。
 *
 * 所以这里钉三条：
 *  ① 每个 `MdInlineKind` 都必须在**导出**路径（MdToHtml.inline）里出现，
 *     或本来就靠标志位（bold/italic/strike/code）渲染——白名单写死在这里，
 *     新增种类想走"标志位就够"这条路，必须显式加进 FLAG_ONLY 并说明理由。
 *  ② 每个种类都必须在阅读页（MdView）被提到（字号/颜色/底纹/装饰线/基线/标签任一映射）——
 *     完全没提到的种类会无声降级成普通文字。
 *  ③ 原生 HTML 行内标签的分派表必须覆盖用户文档里出现的那些标签，
 *     且**块级标签必须在行内名单里被排除**（否则 `<table>` 会被当成行内标签，
 *     把整张表格吞成一行文本）。
 *
 * 用法：node tools/verify-inline-kinds.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets');
let fails = 0;
function check(label, ok, extra) {
  if (!ok) { fails++; console.log('  FAIL  ' + label + (extra ? '  ' + extra : '')); }
  else { console.log('  ok    ' + label); }
}
function read(rel) {
  return fs.readFileSync(path.join(SRC, rel), 'utf8').replace(/\r\n/g, '\n');
}

const types = read('markdown/MdTypes.ets');
const mdView = read('markdown/MdView.ets');
const mdHtml = read('markdown/MdToHtml.ets');
const parser = read('markdown/MdParser.ets');

// ── 枚举成员 ──
const enumBody = (() => {
  const at = types.indexOf('export enum MdInlineKind');
  if (at < 0) { return null; }
  const open = types.indexOf('{', at);
  return types.slice(open + 1, types.indexOf('}', open));
})();
check('① MdInlineKind 枚举能解析', enumBody !== null);
if (enumBody === null) {
  console.log('INLINE KINDS FAILED: 枚举解析不出来');
  process.exit(1);
}
const kinds = [...enumBody.matchAll(/^\s*([A-Z][A-Za-z]*)\s*=\s*(\d+)/gm)]
  .map((m) => ({ name: m[1], value: Number(m[2]) }));
check('① 枚举成员都能解析（漏一个就等于漏检查一个种类的渲染）',
  kinds.length >= 12, '只解析到 ' + kinds.length + ' 个');
const dup = kinds.map((k) => k.value).filter((v, i, a) => a.indexOf(v) !== i);
check('① 枚举取值不重复（重复会让渲染分支互相顶掉）', dup.length === 0, dup.join(', '));
console.log('        行内种类 ' + kinds.length + ' 个：' + kinds.map((k) => k.name).join(' '));

// ── ① 导出侧 ──
/** 这些种类不需要 HTML 分支：样式完全由 bold/italic/strike/code 标志位表达 */
const FLAG_ONLY = {
  'Plain': '普通文字，无样式',
  'Strong': 'bold 标志位 → <strong>',
  'Em': 'italic 标志位 → <em>',
  'Strike': 'strike 标志位 → <del>',
  'Code': 'code 标志位 → <code>'
};
const htmlInlineFn = (() => {
  const at = mdHtml.indexOf('static inline(items: MdInline[])');
  if (at < 0) { return ''; }
  const open = mdHtml.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < mdHtml.length; i++) {
    if (mdHtml[i] === '{') { depth++; }
    else if (mdHtml[i] === '}') { depth--; if (depth === 0) { return mdHtml.slice(open, i + 1); } }
  }
  return '';
})();
check('① MdToHtml.inline() 能定位（导出侧的行内总闸）', htmlInlineFn.length > 200);
const missingInHtml = kinds.filter((k) => FLAG_ONLY[k.name] === undefined
  && htmlInlineFn.indexOf('MdInlineKind.' + k.name) < 0);
check('① 每个行内种类都在**导出**里有分支（漏一个就是"导出网页丢样式"）',
  missingInHtml.length === 0,
  '漏：' + missingInHtml.map((k) => k.name).join(', '));
const badFlagOnly = Object.keys(FLAG_ONLY).filter((n) => !kinds.some((k) => k.name === n));
check('① FLAG_ONLY 名单里的种类都还在枚举里（防名单变垃圾场）',
  badFlagOnly.length === 0, badFlagOnly.join(', '));

// ── ② 阅读页侧 ──
// Strong/Em/Strike 在阅读页**同样**不靠种类分支：它们由 piece.bold / italic / strike
// 三个标志位驱动（inlinePieces 里 .fontWeight(piece.bold) 那一套），
// 所以种类没被提到是设计如此，不是漏。
const VIEW_FLAG_ONLY = {
  'Plain': '普通文字',
  'Strong': 'piece.bold → .fontWeight(FontWeight.Bold)',
  'Em': 'piece.italic → .fontStyle(FontStyle.Italic)',
  'Strike': 'piece.strike → pieceDecoration 里画删除线'
};
const missingInView = kinds.filter((k) => VIEW_FLAG_ONLY[k.name] === undefined
  && mdView.indexOf('MdInlineKind.' + k.name) < 0);
check('② 每个行内种类都在阅读页被提到（没提到 = 无声降级成普通文字）',
  missingInView.length === 0, '没提到：' + missingInView.map((k) => k.name).join(', '));

// MdPiece 必须把颜色带过去，否则 <span style="color"> 在阅读页永远是正文色
const pieceIface = (() => {
  const at = types.indexOf('export interface MdPiece');
  const open = types.indexOf('{', at);
  return types.slice(open, types.indexOf('\n}', open));
})();
check('② MdPiece 有 color 字段（HTML 指定颜色的落地通道）', /color\?\s*:\s*string/.test(pieceIface));
const pieceBuilders = [...mdView.matchAll(/const piece: MdPiece = \{([\s\S]*?)\};/g)]
  .map((m) => m[1]);
check('② 每一处 MdPiece 构造都搬了 color（漏一处就是那条路径上颜色丢失）',
  pieceBuilders.length >= 2 && pieceBuilders.every((b) => /color:\s*item\.color/.test(b)),
  '构造点 ' + pieceBuilders.length + ' 处，搬了 color 的 '
  + pieceBuilders.filter((b) => /color:\s*item\.color/.test(b)).length + ' 处');

// ── ③ 原生 HTML 行内标签的分派 ──
const htmlAt = (() => {
  const at = parser.indexOf('private static htmlAt(');
  if (at < 0) { return ''; }
  const open = parser.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < parser.length; i++) {
    if (parser[i] === '{') { depth++; }
    else if (parser[i] === '}') { depth--; if (depth === 0) { return parser.slice(open, i + 1); } }
  }
  return '';
})();
check('③ MdParser 有 htmlAt()：行内原生 HTML 的总入口', htmlAt.length > 500);
const WANT_TAGS = ['kbd', 'samp', 'var', 'ruby', 'rt', 'rp', 'mark', 'sub', 'sup',
  'strong', 'b', 'em', 'i', 's', 'del', 'strike', 'code', 'u', 'ins', 'a', 'img',
  'br', 'wbr', 'span', 'font', 'script', 'style'];
// `rt` / `rp` 不在 htmlAt 的分派里——它们是 `<ruby>` 的内部构件，由 rubyBase/rubyReading 处理，
// 所以这两个标签查**整个解析器**，其余查 htmlAt 的分派表
const wantInsideHtmlAt = WANT_TAGS.filter((t) => t !== 'rt' && t !== 'rp');
const missingTags = wantInsideHtmlAt.filter((t) => htmlAt.indexOf("'" + t + "'") < 0)
  .concat(WANT_TAGS.filter((t) => t === 'rt' || t === 'rp')
    .filter((t) => parser.indexOf("'" + t + "'") < 0));
check('③ 用户文档里出现的行内标签都在分派表里（漏一个就原样显示标签）',
  missingTags.length === 0, '漏：' + missingTags.join(', '));

// 块级标签必须被行内排除，否则 `<table>` 会被当行内标签、把整张表吞成一行文本
const blockList = (() => {
  const at = parser.indexOf('private static htmlBlockTag(');
  if (at < 0) { return ''; }
  const open = parser.indexOf('{', at);
  return parser.slice(open, parser.indexOf('\n  }', open));
})();
check('③ 存在块级标签排除名单（行内不碰块级结构）', blockList.length > 100);
const BLOCK_TAGS = ['table', 'tr', 'td', 'th', 'div', 'details', 'summary', 'figure',
  'pre', 'blockquote', 'ul', 'ol', 'li', 'svg', 'iframe', 'video', 'audio'];
const missingBlock = BLOCK_TAGS.filter((t) => blockList.indexOf("'" + t + "'") < 0);
check('③ 常见块级标签都在排除名单里', missingBlock.length === 0, '缺：' + missingBlock.join(', '));
const overlap = BLOCK_TAGS.filter((t) => htmlAt.indexOf("name === '" + t + "'") >= 0);
check('③ 块级标签没有同时出现在行内分派里（互斥，否则两边抢同一段文本）',
  overlap.length === 0, overlap.join(', '));

// ── ④ 安全闸：颜色只放行十六进制，script/style 整段丢弃 ──
check('④ 导出前二次校验色值（色值会被拼进 style 属性，等于半个注入面）',
  /static safeHexColor/.test(mdHtml) && /MdToHtml\.safeHexColor\(item\.color/.test(mdHtml));
check('④ 只放行 #RGB / #RRGGBB / #AARRGGBB，长度不对或含非十六进制字符就丢弃',
  /digits\.length !== 3 && digits\.length !== 6 && digits\.length !== 8/.test(mdHtml));
check('④ <script> / <style> 整段丢弃（渲染层没有 CSS/JS 执行环境，也不显示源码）',
  /name === 'script' \|\| name === 'style'/.test(htmlAt)
  && /items: \[\] \} as HtmlHit/.test(htmlAt));
check('④ 认不出来的 HTML 一律 consumed=0 留作正文（绝不吞掉一段文本）',
  /function missHtml\(\)/.test(parser) && (htmlAt.match(/return missHtml\(\);/g) || []).length >= 5,
  'missHtml 出口 ' + (htmlAt.match(/return missHtml\(\);/g) || []).length + ' 处');

// ── ⑤ 导出侧 CSS 与标签配套 ──
const css = (() => {
  const at = mdHtml.indexOf('const BASE_CSS');
  const at2 = at >= 0 ? at : mdHtml.indexOf('kbd {');
  return at2 < 0 ? '' : mdHtml.slice(at2, at2 + 6000);
})();
check('⑤ 导出 CSS 里有 kbd 键帽样式（<kbd> 标签没有 CSS 就退化成正文字）', /kbd\s*\{/.test(css));
check('⑤ 导出 CSS 里有注音样式（ruby/rt 与 .rt 两条：阅读页与导出用的不是同一套标记）',
  /ruby rt\s*\{/.test(css) && /\.rt\s*\{/.test(css));

console.log(fails === 0 ? 'INLINE KINDS OK' : 'INLINE KINDS FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
