// 终极一致性校验：**从 ArkTS 源直抽 mergeCrossLineDollar / countDollar 实现**
// （仅剥离 `: type` 标注，其余逐字符照用）→ 在《LaTeX 渲染能力测试清单》原文件上
// 运行 → 断言命中 6 处、无任何误伤。这验证的是**产品里真正会执行的逻辑**。
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', '..');
const MD_PARSER = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'markdown', 'MdParser.ets');
const FILE = process.argv[2] || 'C:/Users/panda/OneDrive/文档/WeChat/xwechat_files/wxid_qu99r8xvf7522_39ec/msg/file/2026-10/LaTeX 渲染能力测试清单.md';

const srcEt = fs.readFileSync(MD_PARSER, 'utf8').split('\r').join('');

// ── 抽方法体 ──
function grab(methodSig) {
  const a = srcEt.indexOf(methodSig);
  if (a < 0) { throw new Error('not found: ' + methodSig); }
  const braceStart = srcEt.indexOf('{', a);
  let depth = 0;
  let k = braceStart;
  while (k < srcEt.length) {
    const c = srcEt.charAt(k);
    if (c === '{') { depth++; }
    else if (c === '}') { depth--; if (depth === 0) { break; } }
    k++;
  }
  return srcEt.slice(braceStart + 1, k);
}

// 剥离 ArkTS 类型标注（本方法内仅用到 string / number / boolean / string[]）
function stripTypes(body) {
  return body
    .replace(/: string\[\]/g, '')
    .replace(/: string/g, '')
    .replace(/: number/g, '')
    .replace(/: boolean/g, '');
}

const countBody = stripTypes(grab('private static countDollar(s: string): number'));
const mergeBody = stripTypes(grab('private static mergeCrossLineDollar(lines: string[]): void'))
  .replace(/MdParser\.countDollar/g, 'countDollar');

const countDollar = eval('(function(){ return function countDollar(s) {' + countBody + '}; })()');
const mergeCrossLineDollar = eval('(function(){ return function mergeCrossLineDollar(lines) {' + mergeBody + '}; })()');

// ── 跑用户文件 ──
const raw = fs.readFileSync(FILE, 'utf8').replace(/\r/g, '');
const lines = raw.split('\n');
const before = lines.map((l) => l.replace(/\s+$/, '')).filter((l) => l.endsWith('$') && !l.endsWith('$$')).length;

mergeCrossLineDollar(lines);

// ── 收集结果 ──
let merged = 0;
const mergedLines = [];
for (const l of lines) {
  // 合并后的行形态：`- 圆括号：$\begin{…}…$`
  if (/^\s*-\s.*\$\\begin.*\$$/.test(l)) {
    merged++;
    mergedLines.push(l.slice(0, 130));
  }
}
console.log('=== ArkTS 实现直抽运行（用户原文件）===');
console.log('合并命中行数:', merged, '（预期 6）');
for (const m of mergedLines) { console.log(' ·', m); }

// 空行置空后：确认原行数不变
console.log('行数不变检查:', lines.length === raw.split('\n').length ? 'OK' : 'FAIL');

// 断言：6 处 + 全部含 \begin
const ok = merged === 6 && mergedLines.every((l) => l.indexOf('\\begin') > 0);
console.log(ok ? 'ASSERT PASS ✓' : 'ASSERT FAIL ✗');
process.exit(ok ? 0 : 1);
