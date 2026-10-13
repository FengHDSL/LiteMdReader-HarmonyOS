#!/usr/bin/env node
/**
 * 代码 token 的**三处落地**一致性检查（只读代码）
 * ============================================
 *
 * CodeTokenKind 加一种颜色，要在三个地方同时生效：
 *   ① CodeHighlight.ets 里真的会产出这种 token（resolveFamily + 分派）
 *   ② 阅读页 MdView.tokenColor 给它颜色
 *   ③ 导出侧 MdToHtml.codeBlock 给它 class，且 base CSS 里真的有这条 class
 * 少任何一处都是**静默降级**：不报错、不崩溃，只是那一行永远是正文色。
 * 同一类缺陷已经在行内样式上真发生过（MdInlineKind.Sup/Sub 在导出侧没有分支，
 * `x^2^` 导出成 "x2"），所以这里给代码 token 也钉一条。
 *
 * 用法：node tools/verify-code-tokens.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ETS = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets', 'markdown');
const hl = fs.readFileSync(path.join(ETS, 'CodeHighlight.ets'), 'utf8').replace(/\r\n/g, '\n');
const mdView = fs.readFileSync(path.join(ETS, 'MdView.ets'), 'utf8').replace(/\r\n/g, '\n');
const mdHtml = fs.readFileSync(path.join(ETS, 'MdToHtml.ets'), 'utf8').replace(/\r\n/g, '\n');

let fails = 0;
function check(label, ok, extra) {
  if (!ok) { fails++; console.log('  FAIL  ' + label + (extra ? '  ' + extra : '')); }
  else { console.log('  ok    ' + label); }
}

function enumMembers(src, name) {
  const at = src.indexOf('export enum ' + name);
  if (at < 0) { return null; }
  const open = src.indexOf('{', at);
  const body = src.slice(open + 1, src.indexOf('}', open));
  const out = [...body.matchAll(/^\s*([A-Z][A-Za-z]*)\s*=\s*(\d+)/gm)].map((m) => m[1]);
  return out.length > 0 ? out : null;
}

const kinds = enumMembers(hl, 'CodeTokenKind');
const families = enumMembers(hl, 'CodeFamily');
check('① CodeTokenKind / CodeFamily 枚举能解析', kinds !== null && families !== null);
if (kinds === null || families === null) {
  console.log('CODE TOKENS FAILED: 枚举解析不出来');
  process.exit(1);
}
console.log('        token 种类 ' + kinds.length + ' 个：' + kinds.join(' ')
  + '；语言族 ' + families.length + ' 个');

// 每种语言族都要在 resolveFamily 里有映射（否则族是死的，永远命中不到）
const deadFamilies = families.filter((f) => f !== 'None'
  && !new RegExp('return CodeFamily\\.' + f + ';').test(hl));
check('① 每个 CodeFamily 都能被 resolveFamily 命中（有族没映射就是死代码）',
  deadFamilies.length === 0, deadFamilies.join(', '));

// ② 阅读页颜色
const colorBody = (() => {
  const at = mdView.indexOf('static tokenColor(');
  const open = mdView.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < mdView.length; i++) {
    if (mdView[i] === '{') { depth++; }
    else if (mdView[i] === '}') { depth--; if (depth === 0) { return mdView.slice(open, i + 1); } }
  }
  return '';
})();
check('② MdView.tokenColor 能定位（阅读页代码着色的总闸）', colorBody.length > 200);
const noColor = kinds.filter((k) => k !== 'Plain'
  && colorBody.indexOf('CodeTokenKind.' + k) < 0);
check('② 每种 token 都在阅读页有颜色（漏一种就是那一类文字永远是正文色）',
  noColor.length === 0, '漏：' + noColor.join(', '));

// ③ 导出侧 class + CSS
const cb = (() => {
  const at = mdHtml.indexOf('static codeBlock(');
  const open = mdHtml.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < mdHtml.length; i++) {
    if (mdHtml[i] === '{') { depth++; }
    else if (mdHtml[i] === '}') { depth--; if (depth === 0) { return mdHtml.slice(open, i + 1); } }
  }
  return '';
})();
check('③ MdToHtml.codeBlock 能定位（导出代码着色的总闸）', cb.length > 200);
const noClass = kinds.filter((k) => k !== 'Plain' && cb.indexOf('CodeTokenKind.' + k) < 0);
check('③ 每种 token 在导出侧都有 class 分支（Sup/Sub 那次就是这里漏了分支）',
  noClass.length === 0, '漏：' + noClass.join(', '));

// 发出去的 class 必须在 CSS 里有定义，否则导出的网页里那一类文字没颜色
const emitted = [...new Set([...cb.matchAll(/cls = '([a-z]+)'/g)].map((m) => m[1]))];
const missingCss = emitted.filter((c) => !new RegExp('\\.' + c + '\\s*\\{').test(mdHtml));
check('③ 导出用到的每一个 class 都在 CSS 里有定义（有 class 没样式 = 白忙一场）',
  missingCss.length === 0, '缺 CSS：' + missingCss.join(', ') + '（已发出 class：'
  + emitted.join(' ') + '）');

// ④ diff 是"整行语义"，必须在 None 判断**之前**分派，否则空行与纯文本行会被吃掉
const hlLine = (() => {
  const at = hl.indexOf('static highlightLine(');
  const open = hl.indexOf('{', at);
  return hl.slice(open, open + 1400);
})();
check('④ diff 走整行分派，且排在 family===None 的兜底之前',
  hlLine.indexOf('CodeFamily.Diff') < (hlLine.indexOf('CodeFamily.None') < 0
    ? 1e9 : hlLine.indexOf('CodeFamily.None'))
  && hlLine.indexOf('CodeFamily.Diff') >= 0);
check('④ diff 的四种行都有归属（@@ 段头 / +++---与文件头 / + 增 / - 删）',
  /startsWith\('@@'\)/.test(hl) && /'\+\+\+ '/.test(hl)
  && /CodeTokenKind\.Added/.test(hl) && /CodeTokenKind\.Removed/.test(hl));
check('④ 语言别名覆盖 diff / udiff / patch（```\ndiff``` 之外的常见写法）',
  /'diff' \|\| l === 'udiff' \|\| l === 'patch'/.test(hl));

console.log(fails === 0 ? 'CODE TOKENS OK' : 'CODE TOKENS FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
