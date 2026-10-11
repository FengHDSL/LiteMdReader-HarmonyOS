// 验证导出版 runner：从 ArkTS 源文件 MdToHtml.ets 直抽 chartRunner 的字符串拼接
// 表达式 → 用 JS eval 重建实际生成的 JS（同时校验 ArkTS 转义是否合法）→
// 生成带真实 katex 内联库的导出样例页 → Edge headless 渲染验证。
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', '..');
const MDTOHTML = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'markdown', 'MdToHtml.ets');
const RUNTIMES = path.join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'runtimes');
const OUT = path.join(__dirname, 'check-export.html');

// ── 1. 抽取 runnerCode 拼接表达式（剥 \r：Windows checkout 的 CRLF 不影响语义）──
const srcEt = fs.readFileSync(MDTOHTML, 'utf8').split('\r').join('');
const anchor = 'const runnerCode: string =';
const aIdx = srcEt.indexOf(anchor);
if (aIdx < 0) { throw new Error('runnerCode anchor not found'); }
const endAnchor = ';\n    return runnerCode;';
const bIdx = srcEt.indexOf(endAnchor, aIdx);
if (bIdx < 0) { throw new Error('runnerCode end anchor not found'); }
const expr = srcEt.slice(aIdx + anchor.length, bIdx).trim();
console.log('expression length:', expr.length);

// ── 2. eval 重建（has 只开 katex）──
const runnerJs = eval('(function(has){ return ' + expr + '; })')((l) => l === 'katex');
if (typeof runnerJs !== 'string' || runnerJs.length < 500) {
  throw new Error('rebuilt runner looks wrong, length=' + runnerJs.length);
}
console.log('runner rebuilt, length:', runnerJs.length);
// 关键片段检查
for (const piece of ['function normalizeMacros(s)', 'function renderKx(el, display)', 'renderKx(el, true)', 'renderKx(el, false)', 'normalizeMacros(s)']) {
  if (runnerJs.indexOf(piece) < 0) { throw new Error('missing piece in runner: ' + piece); }
}
console.log('runner pieces OK');

// ── 3. 内联 katex 库 + 20 字体 CSS（与 ExportService 内联逻辑一致）──
const b64 = (p) => fs.readFileSync(p).toString('base64');
let katexCss = fs.readFileSync(path.join(RUNTIMES, 'katex.min.css'), 'utf8');
const fontNames = ['KaTeX_AMS-Regular.woff2', 'KaTeX_Caligraphic-Bold.woff2', 'KaTeX_Caligraphic-Regular.woff2',
  'KaTeX_Fraktur-Bold.woff2', 'KaTeX_Fraktur-Regular.woff2', 'KaTeX_Main-Bold.woff2',
  'KaTeX_Main-BoldItalic.woff2', 'KaTeX_Main-Italic.woff2', 'KaTeX_Main-Regular.woff2',
  'KaTeX_Math-BoldItalic.woff2', 'KaTeX_Math-Italic.woff2', 'KaTeX_SansSerif-Bold.woff2',
  'KaTeX_SansSerif-Italic.woff2', 'KaTeX_SansSerif-Regular.woff2', 'KaTeX_Script-Regular.woff2',
  'KaTeX_Size1-Regular.woff2', 'KaTeX_Size2-Regular.woff2', 'KaTeX_Size3-Regular.woff2',
  'KaTeX_Size4-Regular.woff2', 'KaTeX_Typewriter-Regular.woff2'];
for (const f of fontNames) {
  const b = b64(path.join(RUNTIMES, 'fonts', f));
  katexCss = katexCss.split('fonts/' + f + ')').join('data:font/woff2;base64,' + b + ')');
}
let katexJs = fs.readFileSync(path.join(RUNTIMES, 'katex.min.js'), 'utf8')
  .split('</script>').join('<\\/script');

// ── 4. 测试用例（.ktx 容器，与导出产物同构）──
const CASES = [
  { n: 'newcommand 重定义内置宏', s: '\\newcommand{\\R}{\\mathbb{R}}\\forall x \\in \\R, \\; x^2 \\ge 0' },
  { n: 'newcommand 带参数', s: '\\newcommand{\\myvec}[1]{\\mathbf{#1}}\\myvec{v} = \\begin{pmatrix} 1 \\\\ 2 \\end{pmatrix}' },
  { n: '伸缩括号', s: '\\left( \\frac{a}{b} \\right), \\left\\| \\frac{a}{b} \\right\\|' },
  { n: 'tag 编号', s: 'f(x) = x^2 \\tag{1}' },
  { n: '矩阵 + 求和', s: '\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}, \\quad \\begin{pmatrix} 1 & 0 \\\\ 0 & 1 \\end{pmatrix}' },
];
const B64 = (t) => Buffer.from(t, 'utf-8').toString('base64');
let bodyHtml = '';
for (const c of CASES) {
  bodyHtml += '<div class="case"><div class="cap">' + c.n + '</div>'
    + '<div class="ktx" data-b64="' + B64(c.s) + '"></div></div>\n';
}
// ── 行内公式（模拟 inline() 的 .kxi 容器：容器内预填源码作占位）──
bodyHtml += '<div class="case"><div class="cap">行内公式（段落流）</div><p>'
  + '设 <span class="kxi" data-b64="' + B64('\\alpha, \\beta') + '">\\alpha, \\beta</span>'
  + ' 为系数，且 <span class="kxi" data-b64="' + B64('x^2 + y^2 = z^2') + '">x^2 + y^2 = z^2</span>'
  + ' 恒成立时，由 <span class="kxi" data-b64="' + B64('\\frac{a}{b}') + '">\\frac{a}{b}</span>'
  + ' 可得结论。</p></div>\n';
bodyHtml += '<div class="case"><div class="cap">行内公式（宏 + 中文）</div><p>'
  + '定义 <span class="kxi" data-b64="' + B64('\\newcommand{\\R}{\\mathbb{R}}\\forall x \\in \\R') + '"></span>'
  + '，而 <span class="kxi" data-b64="' + B64('\\text{如果 } a = b') + '">\\text{如果 } a = b</span>'
  + ' 成立。</p></div>\n';

const html = `<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"/>
<style>
body { margin: 0 auto; max-width: 820px; padding: 24px; font-family: sans-serif; background: #fff; }
.case { margin: 10px 0; border: 1px dashed #ddd; padding: 8px; }
.cap { font-size: 12px; color: #888; }
.ktx { width: 100%; overflow-x: auto; text-align: center; }
.katex-error { color: #cc0000; }
</style>
<style>${katexCss}</style>
<script>${katexJs}</script>
</head>
<body>
${bodyHtml}
${runnerJs}
<script>
// 验收：等渲染完成后收集结果
window.addEventListener('load', function () {
  setTimeout(function () {
    var out = [];
    document.querySelectorAll('.ktx').forEach(function (el, i) {
      var err = el.querySelector('.katex-error');
      var has = el.querySelector('.katex') !== null;
      out.push({ i: i, type: 'ktx', rendered: has, err: err ? (err.getAttribute('title') || el.textContent || '').slice(0, 120) : '' });
    });
    document.querySelectorAll('.kxi').forEach(function (el, i) {
      var err = el.querySelector('.katex-error');
      var has = el.querySelector('.katex') !== null;
      out.push({ i: i, type: 'kxi', rendered: has, err: err ? (err.getAttribute('title') || el.textContent || '').slice(0, 120) : '' });
    });
    var res = document.createElement('div');
    res.id = 'export-result';
    res.setAttribute('data-json', JSON.stringify(out));
    document.body.appendChild(res);
  }, 300);
});
</script>
</body></html>
`;

fs.writeFileSync(OUT, html);
console.log('written:', OUT, 'bytes=', html.length);
