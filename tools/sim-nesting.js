#!/usr/bin/env node
/**
 * 嵌套列表层级 + 缩进代码块的**行为仿真**（在临时内存里跑，不动仓库代码）
 * ====================================================================
 *
 * 起因（用户清单第 3、4、11 项）：文档里的五级嵌套列表渲染出来是平的、
 * 4 空格缩进的老式代码块整段失去格式。
 *
 * 旧算法把层级写成 `floor(行首空格 / 2)` 再截到 3：
 *   · 4 空格缩进（CommonMark 最常见的嵌套写法）被判成**第 2 层**；
 *   · 每级 +3 空格的五级列表在第 3 层被**截平**；
 *   · 缩进代码块则根本没有分支，段落分支把行首空白 trim 掉。
 *
 * 现在换成"内容列栈"（每一层第一次出现时的行首空格数）：更深=新开一层、
 * 更浅=弹回、相等=同层兄弟；缩进代码只在上一块既不是段落也不是列表项时成立。
 *
 * 这里把 MdParser 的两段判定**逐行端口**过来，喂真实样例（含反例）跑一遍。
 * ⚠️ 端口不是被测代码本身：改了 ArkTS 版记得同步这里，并看 ① 的源码同步检查。
 *
 * 用法：node tools/sim-nesting.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets', 'markdown', 'MdParser.ets');
const src = fs.readFileSync(SRC, 'utf8').replace(/\r\n/g, '\n');
// ⑥ 的两条同步检查要看导出与阅读页，一并读进来（只读，不改）
const mdHtmlSrc = fs.readFileSync(path.join(__dirname, '..', 'entry', 'src', 'main', 'ets',
  'markdown', 'MdToHtml.ets'), 'utf8').replace(/\r\n/g, '\n');
const mdViewSrc = fs.readFileSync(path.join(__dirname, '..', 'entry', 'src', 'main', 'ets',
  'markdown', 'MdView.ets'), 'utf8').replace(/\r\n/g, '\n');

let fails = 0;
function check(label, ok, extra) {
  if (!ok) { fails++; console.log('  FAIL  ' + label + (extra ? '  ' + extra : '')); }
  else { console.log('  ok    ' + label); }
}

// ── ① 源码同步：端口所依据的两条规则还在原地 ──
check('① 列表层级仍由内容列栈算（不再是 floor(空格/2) 一刀切）',
  /const levels: number\[\] = \[\]/.test(src) && !/Math\.floor\(indentSpaces \/ 2\)/.test(src));
const listHitIface = (() => {
  const at = src.indexOf('interface ListHit');
  const open = src.indexOf('{', at);
  return src.slice(open, src.indexOf('}', open));
})();
const listInfoBody = (() => {
  const at = src.indexOf('private static listInfo(');
  const open = src.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') { depth++; }
    else if (src[i] === '}') { depth--; if (depth === 0) { return src.slice(open, i + 1); } }
  }
  return '';
})();
check('① ListHit 交出的是原始空格数 spaces（层级留给主循环算，匹配器不猜）',
  /spaces:\s*number/.test(listHitIface) && !/indent/.test(listHitIface)
  && /spaces:\s*indentSpaces/.test(listInfoBody) && !/Math\.floor/.test(listInfoBody));
check('① 缩进代码 / 块级 HTML 共用同一个"块边界"判定（段落与列表项之后都不起块）',
  /atBlockBoundary/.test(src) && !/canStartIndentedCode/.test(src)
  && /kind !== MdBlockKind\.Paragraph && last\.kind !== MdBlockKind\.ListItem/.test(src));

// ── ⑤ 嵌套引用：每一行自己的 `>` 个数才是它的深度 ──
// 旧实现只取第一行的深度、整段合并成一块，`> > 二级` 会被剥平成同级文字。
function quoteDepth(line) {
  let n = 0; let k = 0;
  while (k < line.length) {
    const c = line.charAt(k);
    if (c === '>') { n++; k++; }
    else if (c === ' ') { k++; }
    else { break; }
  }
  return n > 0 ? n - 1 : 0;
}
/** 端口：主循环的引用分支（按深度切段） */
function parseQuote(lines) {
  const out = [];
  let run = []; let runDepth = 0;
  for (const line of lines) {
    const cur = line.trim();
    if (!cur.startsWith('>')) { continue; }
    const d = quoteDepth(cur);
    let s = cur;
    while (s.startsWith('>')) {
      s = s.substring(1);
      if (s.startsWith(' ')) { s = s.substring(1); }
    }
    if (run.length > 0 && d !== runDepth) {
      out.push({ depth: runDepth, text: run.join(' ') });
      run = [];
    }
    if (run.length === 0) { runDepth = d; }
    run.push(s);
  }
  if (run.length > 0) { out.push({ depth: runDepth, text: run.join(' ') }); }
  return out;
}
const doc21 = parseQuote([
  '> 一级引用：Markdown 的设计哲学是"易读易写"。',
  '> > 二级嵌套引用',
  '> > > 三级嵌套引用，内部仍可写 **粗体** 与 `代码`'
]);
check('⑤ 文档 2.1：三行三种深度 = 三块引用（旧实现合成一块、层级全丢）',
  doc21.length === 3 && doc21[0].depth === 0 && doc21[1].depth === 1 && doc21[2].depth === 2,
  doc21.map((q) => q.depth).join(','));
const sameQuote = parseQuote(['> 甲', '> 乙', '> 丙']);
check('⑤ 同层连续引用仍然合成一块（没被切得过碎）',
  sameQuote.length === 1 && sameQuote[0].text === '甲 乙 丙', JSON.stringify(sameQuote));
const backQuote = parseQuote(['> 一层', '> > 二层', '> 回到一层']);
check('⑤ 嵌套写完回到上一层，深度要跟着回落',
  backQuote.map((q) => q.depth).join(',') === '0,1,0', backQuote.map((q) => q.depth).join(','));

// ── 端口：listInfo（与 ArkTS 版同一条口径）──
function leadingSpaces(line) {
  let n = 0;
  while (n < line.length && line.charAt(n) === ' ') { n++; }
  return n;
}
function listInfo(line) {
  const spaces = leadingSpaces(line);
  const t = line.trim();
  if (t.length === 0) { return { hit: false }; }
  const c0 = t.charAt(0);
  let ordered = false; let marker = ''; let rest = '';
  if (c0 === '-' || c0 === '*' || c0 === '+') {
    if (t.length > 1 && t.charAt(1) !== ' ' && t.charAt(1) !== '\t') { return { hit: false }; }
    marker = c0; rest = t.substring(1).trim();
  } else {
    let k = 0;
    while (k < t.length && t.charAt(k) >= '0' && t.charAt(k) <= '9') { k++; }
    if (k === 0 || k > 9 || k >= t.length) { return { hit: false }; }
    const sep = t.charAt(k);
    if (sep !== '.' && sep !== ')') { return { hit: false }; }
    if (k + 1 < t.length && t.charAt(k + 1) !== ' ' && t.charAt(k + 1) !== '\t') { return { hit: false }; }
    marker = t.substring(0, k + 1); rest = t.substring(k + 1).trim(); ordered = true;
  }
  return { hit: true, text: rest, marker: marker, ordered: ordered, spaces: spaces };
}

/** 端口：主循环的列表分支（内容列栈） */
function parseList(lines) {
  const out = [];
  const levels = [];
  for (const line of lines) {
    const cur = listInfo(line);
    if (!cur.hit) { continue; }
    const baseIndent = leadingSpaces(line);
    if (levels.length === 0) {
      levels.push(baseIndent);
    } else {
      while (levels.length > 1 && baseIndent < levels[levels.length - 1]) { levels.pop(); }
      if (baseIndent > levels[levels.length - 1]) { levels.push(baseIndent); }
    }
    out.push({ depth: levels.length - 1, text: cur.text });
  }
  return out;
}

/**
 * 端口：段落分支里的定义列表识别（术语行 + 连续 ": 定义" 行）。
 * 产出：{ kind: 'para'|'def', text } 列表；不识别时整段按普通段落出一条。
 */
function parsePara(lines2) {
  const para = [];
  for (const l of lines2) {
    const t = l.trim();
    if (t.length === 0) { break; }
    para.push(t);
  }
  const allDefs = para.length >= 2 && para.slice(1).every((d) => d.startsWith(':'));
  if (!allDefs) { return [{ kind: 'para', text: para.join(' ') }]; }
  const out = [{ kind: 'para', text: para[0], boldTerm: true }];
  for (let d = 1; d < para.length; d++) {
    out.push({ kind: 'def', text: para[d].replace(/^:+\s*/, ''), indent: 1 });
  }
  return out;
}
const defDoc = [
  'Markdown',
  ':   轻量级标记语言，John Gruber 2004 年发布。',
  '',
  'CommonMark',
  ':   2014 年启动的标准化规范，用于统一各家方言。'
];
const d1 = parsePara(defDoc.slice(0, 2));
check('⑥ 文档 2.4：术语成一段、定义单独成一块（不再被分号并成一行）',
  d1.length === 2 && d1[0].kind === 'para' && d1[0].text === 'Markdown'
  && d1[1].kind === 'def' && d1[1].indent === 1
  && d1[1].text === '轻量级标记语言，John Gruber 2004 年发布。',
  JSON.stringify(d1));
const dMulti = parsePara(['GFM', ':   GitHub flavored Markdown。', ':   CommonMark 的超集。']);
check('⑥ 一个术语带多条定义时，每条各成一块',
  dMulti.length === 3 && dMulti[1].kind === 'def' && dMulti[2].kind === 'def',
  JSON.stringify(dMulti));
const dColon = parsePara(['术语', ':定义紧贴冒号']);
check('⑥ ":定义"（冒号后没有空格）也认，且冒号被剥干净',
  dColon.length === 2 && dColon[1].text === '定义紧贴冒号', JSON.stringify(dColon));
const dPlain = parsePara(['这只是一段', '继续的换行']);
check('⑥ 普通段落不会被误判成定义列表（第二行不以冒号开头）',
  dPlain.length === 1 && dPlain[0].kind === 'para'
  && dPlain[0].text === '这只是一段 继续的换行', JSON.stringify(dPlain));
// 旧写法会把术语塞进 '**…**' 字符串再解析：术语里带反引号或星号时就解析错
const dTermWithCode = parsePara(['`shelf.json`', ':   书架索引文件。']);
check('⑥ 术语含反引号时不再被字符串拼接破坏（旧写法造出 **`shelf.json`** 再解析）',
  dTermWithCode[0].text === '`shelf.json`' && dTermWithCode[0].boldTerm === true
  && dTermWithCode[0].text.indexOf('**') < 0, JSON.stringify(dTermWithCode[0]));
check('⑥ 端口与 ArkTS 版同步：定义块仍走"空 marker 的列表项"这一表示法',
  /MdBlockFactory\.listItem\(def, false, '', MdTaskState\.None, 1,/.test(src));
check('⑥ 导出侧认得空 marker（定义不进 <ul>，出缩进段），阅读页不画圆点',
  /block\.marker\.length === 0/.test(mdHtmlSrc) && /this\.block\.marker\.length === 0/.test(mdViewSrc));

/**
 * 端口：headingInfo + takeAnchor（显式锚点 `{#id}`）。
 * 不取走的话它会以字面文本显示在标题后面，取走后导出网页给 <h*> 加真 id。
 */
function headingOf(line) {
  let n = 0;
  while (n < line.length && line.charAt(n) === '#') { n++; }
  if (n === 0 || n > 6) { return null; }
  if (n < line.length && line.charAt(n) !== ' ') { return null; }
  // 先取锚点、再剥结尾闭合 # —— 顺序与 ArkTS 版一致（见 headingInfo 注释）
  let hit = takeAnchorPorted(line.substring(n).trim(), n);
  let text = hit.text;
  let end = text.length;
  while (end > 0 && text.charAt(end - 1) === '#') { end--; }
  if (end < text.length && (end === 0 || text.charAt(end - 1) === ' ')) {
    text = text.substring(0, end).trim();
  }
  hit.text = text;
  return hit;
}
function takeAnchorPorted(text, level) {
  const tail = text.trim();
  if (tail.length > 3 && tail.endsWith('}')) {
    const open = tail.lastIndexOf('{#');
    if (open > 0 && tail.charAt(open - 1) === ' ') {
      const id = tail.substring(open + 2, tail.length - 1).trim();
      const bad = ' \t{}"\'<>&\\';
      let usable = id.length > 0;
      for (let k = 0; k < id.length && usable; k++) {
        if (bad.indexOf(id.charAt(k)) >= 0) { usable = false; }
      }
      if (usable) { return { level: level, text: tail.substring(0, open).trim(), id: id }; }
    }
  }
  return { level: level, text: text, id: '' };
}
const a1 = headingOf('## 扩展链路一图流 {#flow}');
check('⑦ 显式锚点被取走：标题只剩文字，id 单独带出',
  a1.text === '扩展链路一图流' && a1.id === 'flow' && a1.level === 2, JSON.stringify(a1));
const a2 = headingOf('### 行内语法 {#语法}');
check('⑦ 中文锚点照收（HTML5 的 id 允许非 ASCII；按 ASCII 白名单拒收会退回字面文本）',
  a2.id === '语法' && a2.text === '行内语法', JSON.stringify(a2));
const a3 = headingOf('## 没有锚点的标题');
check('⑦ 没有 {#…} 的标题不受影响', a3.id === '' && a3.text === '没有锚点的标题');
const a4 = headingOf('## 中段有 {#x} 但后面还有字');
check('⑦ 锚点必须在行尾，否则当普通文字留着', a4.id === '' && a4.text.indexOf('{#x}') >= 0, JSON.stringify(a4));
const a5 = headingOf('# 尾闭合序列 ## {#tail}');
check('⑦ 与"结尾闭合 # 序列"能共存（先去尾 # 再取锚点）',
  a5.id === 'tail' && a5.text === '尾闭合序列', JSON.stringify(a5));
const a6 = headingOf('## 坏锚点 {#有 空格}');
check('⑦ 含空格的畸形锚点不吞（宁可留字面，也不静默改掉用户文字）',
  a6.id === '' && a6.text.indexOf('{#有 空格}') >= 0, JSON.stringify(a6));
check('⑦ 端口与 ArkTS 版同步：解析器落到 block.anchor、导出真的写进 id 属性',
  /hb\.anchor = head\.id/.test(src) && /block\.anchor === undefined \? '' : block\.anchor/.test(mdHtmlSrc)
  && /id="' \+ MdToHtml\.esc\(anc\)/.test(mdHtmlSrc));
check('⑦ 顺序同步：先取锚点、再剥结尾闭合 #（反了 `# T ## {#x}` 就剥不干净）',
  src.indexOf('takeAnchor(text, n)') < src.indexOf("while (end > 0 && text.charAt(end - 1) === '#')"));

/** 端口：主循环的缩进代码分支（只看"能不能起块 + 收哪些行"） */
function parseIndentedCode(lines, lastKind) {
  const canStart = lastKind === undefined
    || (lastKind !== 'Paragraph' && lastKind !== 'ListItem');
  const first = lines.length > 0 ? lines[0] : '';
  if (!(first.startsWith('    ') || first.startsWith('\t')) || !canStart) {
    return null;
  }
  const body = [];
  for (const ln of lines) {
    if (ln.trim().length === 0) { body.push(''); continue; }
    if (!(ln.startsWith('    ') || ln.startsWith('\t'))) { break; }
    body.push(ln.startsWith('\t') ? ln.substring(1) : ln.substring(4));
  }
  while (body.length > 0 && body[body.length - 1].length === 0) { body.pop(); }
  return body.length > 0 ? { kind: 'Code', lang: '', lines: body } : null;
}

// ── ② 真实样例：用户文档 2.2 的五级嵌套列表（每级 +3 空格）──
const doc22 = [
  '1. 一级有序项',
  '   1. 二级有序项',
  '      - 三级无序项',
  '        - 四级无序项',
  '          - 五级',
  '2. 另一个一级项',
  '   - 混排无序'
];
const r22 = parseList(doc22).map((x) => x.depth);
check('② 文档 2.2：五级嵌套就是五级，回到一级项要弹回 0（旧算法这里被截成 0,1,2,3,3,0,1）',
  JSON.stringify(r22) === JSON.stringify([0, 1, 2, 3, 4, 0, 1]), r22.join(','));

// ── ③ 另外两种缩进惯例 ──
const r4 = parseList(['- a', '    - b', '    - c', '- d', '    - e']);
check('③ 4 空格缩进 = 第 1 层（旧算法会判成第 2 层，凭空多一级）',
  r4.map((x) => x.depth).join(',') === '0,1,1,0,1', r4.map((x) => x.depth).join(','));
// 层级是**相对当前打开的那一项**算的，不是空格的绝对刻度：
// 已经回到顶层之后，下一项再深缩进只算"当前项的一层孩子"（第 1 层），不会跳到第 2 层。
// 这是 CommonMark 的语义——想真到第 2 层，必须先有一层第 1 层把上下文撑开。
const rDeep = parseList(['- a', '    - b', '        - c', '- d', '        - e']);
check('③ 回到顶层后再深缩进，只算当前项的一层孩子（层级相对，不认绝对空格刻度）',
  rDeep.map((x) => x.depth).join(',') === '0,1,2,0,1', rDeep.map((x) => x.depth).join(','));
const r2 = parseList(['- a', '  - b', '    - c', '- d']);
check('③ 2 空格缩进同样正确，回到顶层要弹回 0',
  r2.map((x) => x.depth).join(',') === '0,1,2,0', r2.map((x) => x.depth).join(','));
const rMix = parseList(['1. 甲', '   - 子项', '2. 乙', '   - 子项', '     - 孙项']);
check('③ 有序/无序混排的层级互不串（列表标记宽度不同也按空格归层）',
  rMix.map((x) => x.depth).join(',') === '0,1,0,1,2', rMix.map((x) => x.depth).join(','));

// ── ④ 缩进代码块 ──
const code = parseIndentedCode(
  ['    这是用 4 空格缩进的代码块', '    属于 CommonMark 原生语法', '    无法指定语言'], 'Heading');
check('④ 文档 4.5：4 空格缩进收成代码块，且**保留行间格式**、去掉每行 4 空格',
  code !== null && code.lines.length === 3 && code.lines[0] === '这是用 4 空格缩进的代码块',
  code === null ? '收成 null' : JSON.stringify(code.lines));
check('④ 段落之后不算代码（CommonMark 的惰性续行）',
  parseIndentedCode(['    接着上一段说', '    还是上一段'], 'Paragraph') === null);
check('④ 列表项之后的缩进是"这一项的后续段落"，不算代码',
  parseIndentedCode(['      列表项里的第二个段落'], 'ListItem') === null);
const tabCode = parseIndentedCode(['\tTab 缩进的代码', '\t第二行'], 'Divider');
check('④ Tab 缩进也算，且只去掉一个 Tab',
  tabCode !== null && tabCode.lines[0] === 'Tab 缩进的代码', tabCode && tabCode.lines[0]);
const blankTail = parseIndentedCode(['    代码一行', '', '    中间空行保留', '', ''], 'Heading');
check('④ 代码块内部空行保留、结尾空行不吸进代码',
  blankTail !== null && blankTail.lines.length === 3
  && blankTail.lines[1] === '' && blankTail.lines[2] === '中间空行保留',
  blankTail && JSON.stringify(blankTail.lines));

console.log(fails === 0 ? 'NESTING OK' : 'NESTING FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
