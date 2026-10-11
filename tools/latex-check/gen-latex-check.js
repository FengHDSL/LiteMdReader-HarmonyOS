// 生成 LaTeX 渲染验证页：从产品 rawfile/render/katex.html 抽取**同一份** CSS 与
// katex.min.js，保证测试与真机渲染完全同源（版本、字体引用方式一字不差）。
// 输出 check.html：逐条渲染《LaTeX 渲染能力测试清单》的公式，收集错误。
const fs = require('fs');
const path = require('path');

const KATEX_HTML = path.join(__dirname, '..', '..', 'entry', 'src', 'main',
  'resources', 'rawfile', 'render', 'katex.html');
const OUT = path.join(__dirname, 'check.html');

const src = fs.readFileSync(KATEX_HTML, 'utf8');

// ── 抽取 <head> 全部内容（两段 <style>：页面样式 + KaTeX 完整 CSS）──
const headStart = src.indexOf('<head>') + '<head>'.length;
const headEnd = src.indexOf('</head>');
const head = src.slice(headStart, headEnd);

// ── 抽取 katex.min.js 的 <script> 块（第一个 script 即压缩版 KaTeX）──
const sTag = '<script>';
const sBegin = src.indexOf(sTag);
const sEnd = src.indexOf('</script>', sBegin);
if (sBegin < 0 || sEnd < 0) {
  throw new Error('katex.min.js script block not found');
}
const katexJs = src.slice(sBegin + sTag.length, sEnd);

// ── 抽取包含 __normalizeMacros 的 script 块（产品同源的宏容错逻辑）──
const normAnchor = src.indexOf('__normalizeMacros');
const nBegin = src.lastIndexOf('<script>', normAnchor);
const nEnd = src.indexOf('</script>', normAnchor);
if (normAnchor < 0 || nBegin < 0 || nEnd < 0) {
  throw new Error('__normalizeMacros script block not found');
}
const normalizeJs = src.slice(nBegin + sTag.length, nEnd);

// ── 测试清单（对照用户提供的《LaTeX 渲染能力测试清单》逐条收录）──
// d: true = displayMode（独立公式）；false = 行内公式
const CASES = [
  { g: '1 基础符号与运算' },
  { n: '希腊字母', s: '\\alpha, \\beta, \\gamma, \\theta, \\lambda, \\mu, \\pi, \\sigma, \\phi, \\omega, \\Gamma, \\Delta, \\Theta, \\Lambda, \\Sigma, \\Phi, \\Omega', d: false },
  { n: '普通上标', s: 'x^2, e^{i\\pi}, a^{b^c}', d: false },
  { n: '普通下标', s: 'x_1, a_{ij}, H_2O', d: false },
  { n: '同时上下标', s: 'x_1^2, A_{ij}^{k}', d: false },
  { n: '普通分式', s: '\\frac{a}{b}, \\frac{n!}{k!}', d: false },
  { n: '嵌套分式', s: '\\frac{1}{1 + \\frac{1}{1 + \\frac{1}{x}}}', d: false },
  { n: '平方根', s: '\\sqrt{x}, \\sqrt{x^2 + y^2}', d: false },
  { n: '多次根式', s: '\\sqrt[3]{8}, \\sqrt[n]{x^2}', d: false },
  { n: '运算符', s: '+, -, \\times, \\div, \\pm, \\mp, \\cdot, \\ast, \\oplus, \\otimes', d: false },
  { g: '2 关系符号与逻辑' },
  { n: '比较关系符', s: '=, \\neq, <, >, \\leq, \\geq, \\ll, \\gg, \\approx, \\equiv, \\propto, \\sim', d: false },
  { n: '逻辑符号', s: '\\forall, \\exists, \\neg, \\wedge, \\vee, \\implies, \\iff', d: false },
  { n: '普通箭头', s: '\\to, \\rightarrow, \\leftarrow, \\uparrow, \\downarrow', d: false },
  { n: '蕴含箭头', s: '\\Rightarrow, \\Leftarrow, \\Leftrightarrow', d: false },
  { n: '映射箭头', s: '\\mapsto, \\longrightarrow, \\longmapsto', d: false },
  { n: '手写箭头', s: '\\to, \\gets', d: false },
  { g: '3 集合论' },
  { n: '集合运算', s: '\\cup, \\cap, \\setminus, \\subset, \\subseteq, \\supset, \\in, \\notin, \\emptyset, \\mathbb{N}, \\mathbb{Z}, \\mathbb{Q}, \\mathbb{R}, \\mathbb{C}', d: false },
  { g: '4 矩阵与数组' },
  { n: '圆括号矩阵', s: '\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}', d: true },
  { n: '方括号矩阵', s: '\\begin{bmatrix} a & b \\\\ c & d \\end{bmatrix}', d: true },
  { n: '竖线行列式', s: '\\begin{vmatrix} x & y \\\\ z & w \\end{vmatrix}', d: true },
  { n: '双竖线范数', s: '\\begin{Vmatrix} a & b \\\\ c & d \\end{Vmatrix}', d: true },
  { n: '无括号矩阵', s: '\\begin{matrix} 1 & 0 \\\\ 0 & 1 \\end{matrix}', d: true },
  { n: 'array 自定义', s: '\\begin{array}{c|c} a & b \\\\ \\hline c & d \\end{array}', d: true },
  { n: '嵌套矩阵', s: '\\begin{pmatrix} \\begin{matrix} 1 & 0 \\\\ 0 & 1 \\end{matrix} & 0 \\\\ 0 & \\begin{matrix} 1 & 0 \\\\ 0 & 1 \\end{matrix} \\end{pmatrix}', d: true },
  { g: '5 分段函数与多行公式' },
  { n: 'cases 分段', s: 'f(x) = \\begin{cases} x^2, & x \\ge 0 \\\\ -x, & x < 0 \\end{cases}', d: true },
  { n: 'aligned 对齐', s: '\\begin{aligned} (a + b)^2 &= a^2 + 2ab + b^2 \\\\ (a - b)^2 &= a^2 - 2ab + b^2 \\end{aligned}', d: true },
  { n: '多行等式', s: '\\begin{aligned} \\sin x &= x - \\frac{x^3}{3!} + \\frac{x^5}{5!} - \\cdots \\\\ &= \\sum_{n=0}^{\\infty} \\frac{(-1)^n}{(2n+1)!} x^{2n+1} \\end{aligned}', d: true },
  { g: '6 微积分与求和' },
  { n: '极限', s: '\\lim_{x \\to 0} \\frac{\\sin x}{x} = 1', d: true },
  { n: '导数', s: "\\frac{dy}{dx}, f'(x), y''", d: false },
  { n: '偏导', s: '\\frac{\\partial f}{\\partial x}, \\frac{\\partial^2 f}{\\partial x \\partial y}', d: false },
  { n: '梯度', s: '\\nabla f', d: false },
  { n: '定积分', s: '\\int_{a}^{b} f(x) \\, dx', d: false },
  { n: '双重积分', s: '\\iint_{D} f(x,y) \\, dx \\, dy', d: false },
  { n: '三重积分', s: '\\iiint_{V} f(x,y,z) \\, dV', d: false },
  { n: '曲线积分', s: '\\oint_{\\gamma} f \\, ds', d: false },
  { n: '求和', s: '\\sum_{n=1}^{\\infty} \\frac{1}{n^2}', d: true },
  { n: '乘积', s: '\\prod_{k=1}^{n} k = n!', d: true },
  { n: '有限求和', s: '\\sum_{i=0}^{n} \\binom{n}{i} = 2^n', d: true },
  { g: '7 特殊字体与文本' },
  { n: '数学空心体', s: '\\mathbb{R}, \\mathbb{N}, \\mathbb{Z}, \\mathbb{Q}, \\mathbb{C}', d: false },
  { n: '花体', s: '\\mathcal{F}, \\mathcal{L}, \\mathcal{O}, \\mathcal{P}', d: false },
  { n: '粗体', s: '\\mathbf{A}, \\mathbf{v}, \\mathbf{x}_1', d: false },
  { n: '斜体', s: 'A, B, C, x, y, z', d: false },
  { n: '正体', s: '\\mathrm{d}x, \\mathrm{e}, \\mathrm{i}', d: false },
  { n: '行内文本', s: '\\text{如果 } a = b \\text{，则 } c = d', d: false },
  { n: '文本混排', s: '\\text{当 } x > 0 \\text{ 时，} f(x) = x^2', d: false },
  { g: '8 装饰与变体' },
  { n: '上划线', s: '\\overline{z}, \\overline{AB}', d: false },
  { n: '下划线', s: '\\underline{x}, \\underline{ABC}', d: false },
  { n: '帽子宽帽', s: '\\hat{a}, \\hat{\\beta}, \\widehat{ABC}', d: false },
  { n: '波浪线', s: '\\tilde{x}, \\tilde{\\alpha}, \\widetilde{ABC}', d: false },
  { n: '向量箭头', s: '\\vec{v}, \\vec{F}, \\overrightarrow{AB}', d: false },
  { n: '导数点号', s: '\\dot{x}, \\ddot{x}', d: false },
  { n: '粗体希腊', s: '\\boldsymbol{\\alpha}, \\boldsymbol{\\beta}, \\boldsymbol{\\theta}', d: false },
  { g: '9 括号与定界符' },
  { n: '自动缩放括号', s: '\\left( \\frac{a}{b} \\right), \\left[ \\frac{a}{b} \\right], \\left\\{ \\frac{a}{b} \\right\\}, \\left| \\frac{a}{b} \\right|, \\left\\| \\frac{a}{b} \\right\\|', d: true },
  { n: '手动大小括号', s: '\\big( x \\big), \\Big( x \\Big), \\bigg( x \\bigg), \\Bigg( x \\Bigg)', d: true },
  { n: '嵌套括号', s: '\\left( \\left[ \\left\\{ a \\right\\} \\right] \\right)', d: true },
  { g: '10 高级排版与环境' },
  { n: 'boxed 框注', s: '\\boxed{E = mc^2}', d: true },
  { n: 'tag 编号', s: 'f(x) = x^2 \\tag{1}', d: true },
  { n: '颜色', s: '\\color{red}{红色文字}, \\color{blue}{蓝色数学}', d: false },
  { n: 'overset 上方文字', s: '\\overset{\\text{def}}{=}', d: true },
  { n: 'underset 下方文字', s: '\\underset{x \\to 0}{\\lim} f(x)', d: true },
  { n: '组合数', s: '\\binom{n}{k} = \\frac{n!}{k!(n-k)!}', d: true },
  { g: '11 宏定义' },
  { n: 'newcommand', s: '\\newcommand{\\R}{\\mathbb{R}}\\forall x \\in \\R, \\; x^2 \\ge 0', d: true },
];

const casesJs = JSON.stringify(CASES.filter(c => c.n).map(c => ({ n: c.n, s: c.s, d: c.d })), null, 0);
const groupsJs = JSON.stringify(CASES, null, 0);

const html = `<!DOCTYPE html>
<html>
<head>
${head}
<style>
  body{background:#fff;font-family:system-ui,sans-serif;padding:16px;}
  h2{font-size:15px;margin:18px 0 6px;color:#333;border-bottom:1px solid #ddd;padding-bottom:4px;}
  .item{margin:6px 0 10px;}
  .label{font-size:11px;color:#888;margin-bottom:2px;}
  .box{display:inline-block;min-height:20px;}
  .box.display{display:block;width:420px;border:1px dashed #eee;text-align:center;}
  .katex-error{color:#cc0000;}
  #summary{position:fixed;top:0;left:0;right:0;background:#111;color:#fff;font:12px monospace;padding:6px 10px;z-index:99;}
</style>
</head>
<body>
<div id="summary">running…</div>
<div id="list"></div>
<script>${katexJs}</script>
<script>${normalizeJs}</script>
<script>
const GROUPS = ${groupsJs};
const listEl = document.getElementById('list');
const errors = [];
let idx = 0;
// 与产品 __renderCore 一致的"失败→宽容化重试"路径
function renderOne(box, src, d) {
  const opt = { displayMode: d, throwOnError: false, output: 'html' };
  box.innerHTML = '';
  katex.render(src, box, opt);
  if (box.querySelector('.katex-error')) {
    const s2 = window.__normalizeMacros(src);
    if (s2 !== src) {
      box.innerHTML = '';
      katex.render(s2, box, opt);
    }
  }
}
for (const g of GROUPS) {
  if (g.g) {
    const h = document.createElement('h2');
    h.textContent = g.g;
    listEl.appendChild(h);
    continue;
  }
  idx++;
  const item = document.createElement('div');
  item.className = 'item';
  const label = document.createElement('div');
  label.className = 'label';
  label.textContent = idx + '. [' + (g.d ? 'display' : 'inline') + '] ' + g.n;
  const box = document.createElement('div');
  box.className = 'box' + (g.d ? ' display' : '');
  box.id = 'box-' + idx;
  item.appendChild(label);
  item.appendChild(box);
  listEl.appendChild(item);
  try {
    renderOne(box, g.s, !!g.d);
    const err = box.querySelector('.katex-error');
    if (err) {
      errors.push({ id: idx, name: g.n, mode: g.d ? 'display' : 'inline', msg: (err.getAttribute('title') || err.textContent || '').slice(0, 160) });
      box.dataset.err = '1';
    }
  } catch (e) {
    errors.push({ id: idx, name: g.n, mode: g.d ? 'display' : 'inline', msg: 'THROW: ' + String(e && e.message).slice(0, 160) });
    box.dataset.err = '1';
  }
}
document.getElementById('summary').textContent = 'DONE total=' + idx + ' errors=' + errors.length + (errors.length ? ' → ' + JSON.stringify(errors) : '');
// 每条公式的几何（供截图裁剪定位）
const rects = [];
document.querySelectorAll('.item').forEach(function (it, i) {
  rects.push({ id: i + 1, top: Math.round(it.getBoundingClientRect().top + window.scrollY), h: Math.round(it.getBoundingClientRect().height) });
});
window.__latexResult = { total: idx, errors: errors, rects: rects };
const resEl = document.createElement('div');
resEl.id = 'result';
resEl.setAttribute('data-json', JSON.stringify(window.__latexResult));
document.body.appendChild(resEl);
</script>
</body>
</html>
`;

// ── 字体 dataURI 内联：验证页完全自包含（任意环境打开/预览都能显示完整字形）──
let outHtml = html;
const fontsDir = path.join(__dirname, 'fonts');
for (const f of fs.readdirSync(fontsDir)) {
  if (!f.endsWith('.woff2')) { continue; }
  const b64 = fs.readFileSync(path.join(fontsDir, f)).toString('base64');
  outHtml = outHtml.split('fonts/' + f + ')').join('data:font/woff2;base64,' + b64 + ')');
}

fs.writeFileSync(OUT, outHtml);
console.log('written:', OUT, 'bytes=', outHtml.length);
