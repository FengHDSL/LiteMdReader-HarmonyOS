#!/usr/bin/env node
/**
 * 块级原生 HTML 的**识别 + 安全闸仿真**（在内存里跑，不动仓库代码）
 * ============================================================
 *
 * 用户清单第 7、19、20、21 项都压在"块级 HTML 能不能渲染"上：合并单元格的
 * `<table>`、原生折叠面板、内嵌 SVG、figure 图注、带样式的 div / 徽章 / 进度条。
 * 这些排版 ArkUI 的 Text/Span 表达不了，只能整段交给 render/html.html 的 WebView 卡片。
 *
 * 一旦正文里的 HTML 会被"自动识别"送去渲染，风险口径就变了：以前只有用户自己写的
 * ```html 围栏会执行，现在是"别人发来的文档里正好有段 HTML"也会。所以这条路径上有一道闸
 * （MdParser.sanitizeHtmlBlock）：**摘掉 script / iframe / frame / embed / object，
 * 丢掉 on* 事件属性与 javascript: 地址**；```html 围栏保持原样（那是主动预览）。
 *
 * 安全代码没有测试就等于没写，所以这里把识别与清洗**逐行端口**过来，喂真实样例与攻击样例。
 * ⚠️ 端口不是被测代码本身：改 ArkTS 版要同步这里，① 的源码同步检查会盯住函数名。
 *
 * 用法：node tools/sim-html-block.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets', 'markdown', 'MdParser.ets');
const src = fs.readFileSync(SRC, 'utf8').replace(/\r\n/g, '\n');

let fails = 0;
function check(label, ok, extra) {
  if (!ok) { fails++; console.log('  FAIL  ' + label + (extra ? '  ' + extra : '')); }
  else { console.log('  ok    ' + label); }
}

// ── ① 源码同步：端口依据的函数都还在，且主循环真的接上了 ──
const MUST = ['htmlBlockTagAt', 'tagDelta', 'sanitizeHtmlBlock', 'dropTagPair',
  'scrubHtmlTags', 'scrubAttrRun', 'htmlBlockTag', 'atBlockBoundary'];
const missing = MUST.filter((f) => !new RegExp('private static ' + f + '\\(').test(src));
check('① 端口的八个函数在 ArkTS 版里都还在（改名会让端口与实现漂移）', missing.length === 0,
  missing.join(', '));
check('① 主循环真的会收块级 HTML 并建成 html 图表卡片（走既有 WebView 链路）',
  /MdParser\.htmlBlockTagAt\(raw\)/.test(src) && /MdBlockFactory\.chart\('html'/.test(src)
  && /MdParser\.sanitizeHtmlBlock\(/.test(src));
check('① 行内路径仍然拒绝块级标签（两边不抢同一段文本）',
  /if \(name\.length === 0 \|\| MdParser\.htmlBlockTag\(name\)\)/.test(src));

// ── 端口：标签名 / 块级名单 / 识别 ──
const BLOCK_TAGS = ['table', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th', 'colgroup', 'col',
  'div', 'p', 'section', 'article', 'aside', 'main', 'header', 'footer', 'nav', 'details',
  'summary', 'figure', 'figcaption', 'pre', 'blockquote', 'ul', 'ol', 'li', 'dl', 'dt', 'dd',
  'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'svg', 'canvas', 'iframe', 'video', 'audio', 'source',
  'form', 'hr'];
function htmlTagName(s, start) {
  let k = start + 1;
  if (k >= s.length || !/[a-z]/i.test(s.charAt(k))) { return ''; }
  const from = k;
  while (k < s.length && /[a-z0-9-]/i.test(s.charAt(k))) { k++; }
  return s.substring(from, k).toLowerCase();
}
function htmlBlockTagAt(line) {
  const t = line.trim();
  if (t.length < 2 || t.charAt(0) !== '<' || t.charAt(1) === '/') { return ''; }
  const name = htmlTagName(t, 0);
  if (name.length === 0 || BLOCK_TAGS.indexOf(name) < 0) { return ''; }
  return t.indexOf('>') > 0 ? name : '';
}
function tagDelta(line, tag) {
  const lower = line.toLowerCase();
  const o = '<' + tag; const c = '</' + tag;
  let delta = 0; let k = 0;
  while (k < lower.length) {
    const at = lower.indexOf(o, k);
    if (at < 0) { break; }
    const next = at + o.length < lower.length ? lower.charAt(at + o.length) : ' ';
    if (next === ' ' || next === '>' || next === '\t' || next === '/') { delta++; }
    k = at + o.length;
  }
  k = 0;
  while (k < lower.length) {
    const at = lower.indexOf(c, k);
    if (at < 0) { break; }
    delta--;
    k = at + c.length;
  }
  return delta;
}
function dropTagPair(text, tag) {
  const lower = text.toLowerCase();
  const openNeedle = '<' + tag;
  let out = ''; let k = 0;
  while (k < text.length) {
    const at = lower.indexOf(openNeedle, k);
    if (at < 0) { out = out + text.substring(k); break; }
    const next = at + openNeedle.length < text.length ? text.charAt(at + openNeedle.length) : ' ';
    if (next !== ' ' && next !== '>' && next !== '\t' && next !== '/' && next !== '\n') {
      out = out + text.substring(k, at + openNeedle.length);
      k = at + openNeedle.length;
      continue;
    }
    const gt = text.indexOf('>', at);
    if (gt < 0) { return out + text.substring(k, at); }
    if (text.charAt(gt - 1) === '/') { out = out + text.substring(k, at); k = gt + 1; continue; }
    const closeAt = lower.indexOf('</' + tag, gt);
    if (closeAt < 0) { return out + text.substring(k, at); }
    const closeEnd = text.indexOf('>', closeAt);
    out = out + text.substring(k, at);            // 先留住标签**前面**那段正文
    k = closeEnd < 0 ? text.length : closeEnd + 1;
  }
  return out;
}
function scrubAttrRun(inner) {
  const tokens = []; let cur = ''; let quote = '';
  for (let k = 0; k < inner.length; k++) {
    const c = inner.charAt(k);
    if (quote.length > 0) { cur = cur + c; if (c === quote) { quote = ''; } continue; }
    if (c === '"' || c === '\'') { quote = c; cur = cur + c; continue; }
    if (c === ' ' || c === '\t' || c === '\n') {
      if (cur.length > 0) { tokens.push(cur); cur = ''; }
      continue;
    }
    cur = cur + c;
  }
  if (cur.length > 0) { tokens.push(cur); }
  let out = tokens.length > 0 ? tokens[0] : '';
  for (let t = 1; t < tokens.length; t++) {
    const tok = tokens[t];
    const eq = tok.indexOf('=');
    const name = (eq < 0 ? tok : tok.substring(0, eq)).toLowerCase();
    const value = eq < 0 ? '' : tok.substring(eq + 1).toLowerCase();
    if (name.startsWith('on')) { continue; }
    if (value.indexOf('javascript:') >= 0) { continue; }
    out = out + ' ' + tok;
  }
  return out;
}
function scrubHtmlTags(text) {
  let out = ''; let k = 0;
  while (k < text.length) {
    const lt = text.indexOf('<', k);
    if (lt < 0) { out = out + text.substring(k); break; }
    out = out + text.substring(k, lt);
    const gt = text.indexOf('>', lt + 1);
    if (gt < 0) { out = out + text.substring(lt); break; }
    out = out + '<' + scrubAttrRun(text.substring(lt + 1, gt)) + '>';
    k = gt + 1;
  }
  return out;
}
function sanitizeHtmlBlock(text) {
  let out = dropTagPair(text, 'script');
  out = dropTagPair(out, 'iframe');
  out = dropTagPair(out, 'frame');
  out = dropTagPair(out, 'embed');
  out = dropTagPair(out, 'object');
  return scrubHtmlTags(out);
}
/** 端口：主循环的收集循环（空行或根标签闭合就结束） */
function collectHtml(lines, startIndex) {
  const rootTag = htmlBlockTagAt(lines[startIndex]);
  if (rootTag.length === 0) { return null; }
  const picked = [];
  let i = startIndex;
  let balance = 0;
  while (i < lines.length) {
    const hl = lines[i];
    if (hl.trim().length === 0) { break; }
    picked.push(hl);
    balance += tagDelta(hl, rootTag);
    i++;
    if (balance <= 0) { break; }
  }
  return { tag: rootTag, next: i, text: sanitizeHtmlBlock(picked.join('\n')) };
}

// ── ② 用户文档 3.2：合并单元格的表格（这一项被称作"唯一解"）──
const docTable = [
  '<table>',
  '  <colgroup>',
  '    <col style="width:40%">',
  '    <col style="width:30%">',
  '  </colgroup>',
  '  <thead>',
  '    <tr><th colspan="2">合并表头（colspan=2）</th><th>单列</th></tr>',
  '  </thead>',
  '  <tbody>',
  '    <tr><td rowspan="2">纵向合并<br>（rowspan=2）</td><td>A 方案</td><td align="right">10</td></tr>',
  '    <tr><td colspan="3" align="center"><em>跨整行的脚注行</em></td></tr>',
  '  </tbody>',
  '</table>',
  '',
  '后面是普通段落。'
];
const t2 = collectHtml(docTable, 0);
check('② 文档 3.2 的 <table> 被识别成块，且**正好收到 </table>**（不多吞后面的段落）',
  t2 !== null && t2.tag === 'table' && t2.next === 13 && t2.text.includes('</table>'),
  t2 ? 'tag=' + t2.tag + ' next=' + t2.next : '没识别出来');
check('② colspan / rowspan / align / style 这些排版属性**保留**（那就是这条语法的用途）',
  t2 !== null && t2.text.includes('colspan="2"') && t2.text.includes('rowspan="2"')
  && t2.text.includes('style="width:40%"') && t2.text.includes('align="right"'),
  t2 && t2.text.substring(0, 60));

// ── ③ 其它块级样例 ──
const svg = collectHtml(['<svg width="80" height="20"><rect width="80" height="20"/></svg>', ''], 0);
check('③ 内嵌 <svg> 成块（一行自闭合到底也算平衡）',
  svg !== null && svg.text.includes('<rect') && svg.next === 1, svg && svg.text);
const fig = collectHtml(['<figure>', '  <img src="a.png" alt="图">', '  <figcaption>图 1：说明</figcaption>',
  '</figure>'], 0);
check('③ <figure> + <figcaption> 图注成块', fig !== null && fig.text.includes('<figcaption>'));
const det = collectHtml(['<details open>', '<summary>点我展开</summary>', '藏起来的内容', '</details>'], 0);
check('③ 带属性的折叠面板 <details open> 也能成块（行内那条路只认裸 <details>）',
  det !== null && det.text.includes('<summary>'));
const divBal = collectHtml(['<div style="overflow-x:auto">', '<table><tr><td>1</td></tr></table>',
  '</div>'], 0);
check('③ 嵌套同类标签按开合差额平衡，不会在内层 </table> 提前收口',
  divBal !== null && divBal.text.includes('</div>') && divBal.next === 3, divBal && divBal.next);
const blankEnd = collectHtml(['<div>第一块', '', '第二块内容'], 0);
check('③ 空行结束一块（CommonMark 第六类 HTML 块的边界）',
  blankEnd !== null && blankEnd.next === 1 && !blankEnd.text.includes('第二块'));
check('③ 行内小标签不当块（<kbd>/<b> 走行内那条路）',
  htmlBlockTagAt('<kbd>Ctrl</kbd> + <kbd>C</kbd>') === ''
  && htmlBlockTagAt('<b>粗体</b>') === '');
check('③ 闭合标签开头不当块（</td> 这种残片不起新块）', htmlBlockTagAt('</td>') === '');

// ── ④ 安全闸：自动识别的 HTML 不能带可执行内容 ──
const xssScript = sanitizeHtmlBlock('<p>前面</p><script>alert(1)</script><p>后面</p>');
check('④ <script> 整段摘掉，前后内容都留着',
  !xssScript.includes('alert') && xssScript.includes('前面') && xssScript.includes('后面'),
  xssScript);
const xssOpen = sanitizeHtmlBlock('<p>前</p><script>alert(1)');
check('④ <script> 没有闭合时删到文末（留半截比少显示更危险）',
  xssOpen === '<p>前</p>', JSON.stringify(xssOpen));
const xssOn = sanitizeHtmlBlock('<img src="a.png" onerror="fetch(\'//evil\')">');
check('④ img 的 onerror 事件属性被丢，src 保留',
  !xssOn.includes('onerror') && xssOn.includes('src="a.png"'), xssOn);
const xssJs = sanitizeHtmlBlock('<a href="javascript:alert(1)">点</a>');
check('④ javascript: 地址的属性被丢', !xssJs.includes('javascript:'), xssJs);
const xssFrame = sanitizeHtmlBlock('<div>正文</div><iframe src="https://evil.example/x"></iframe>');
check('④ <iframe> 整段摘掉（它会自己发网络请求；audio/video 留着，要用户点播放）',
  !xssFrame.includes('iframe') && xssFrame.includes('正文'), xssFrame);
const keepMedia = sanitizeHtmlBlock('<video controls src="本地.mp4"></video>');
check('④ <video> 不被误杀（本地文件、需要主动播放）',
  keepMedia.includes('<video'), keepMedia);
const prefixSafe = sanitizeHtmlBlock('<p>&lt;scripting&gt; 不是脚本</p><scripting>x</scripting>');
check('④ 前缀同名标签不误删（<scripting> 不是 <script>）',
  prefixSafe.includes('<scripting>x</scripting>'), prefixSafe);
const quoted = sanitizeHtmlBlock('<td title="a b c" onclick="x()">格</td>');
check('④ 属性值里的空格不被误切，同时该丢的照丢',
  quoted.includes('title="a b c"') && !quoted.includes('onclick'), quoted);
const selfEmbed = sanitizeHtmlBlock('<p>前</p><embed src="a.swf" /><p>后</p>');
check('④ 自闭合的 <embed/> 只摘这一个标签，后面内容不陪葬',
  !selfEmbed.includes('<embed') && selfEmbed.includes('后'), selfEmbed);

console.log(fails === 0 ? 'HTML BLOCK OK' : 'HTML BLOCK FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
