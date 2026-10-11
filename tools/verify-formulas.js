// Verify every formula destined for the demo doc renders with the app's own
// KaTeX build and the same options katex.html uses (output:'html').
const katex = require('../entry/src/main/resources/rawfile/runtimes/katex.min.js');

const inline = [
  'E = mc^2',
  'a^2 + b^2 = c^2',
  'S = \\pi r^2',
  '\\sigma = \\sqrt{\\frac{1}{N}\\sum_{i=1}^{N}(x_i-\\mu)^2}',
  '\\alpha,\\ \\beta,\\ \\gamma,\\ \\theta,\\ \\lambda,\\ \\mu,\\ \\pi,\\ \\sigma,\\ \\phi,\\ \\omega',
  '\\Gamma,\\ \\Delta,\\ \\Theta,\\ \\Lambda,\\ \\Sigma,\\ \\Phi,\\ \\Omega',
  'x^2,\\ e^{i\\pi},\\ a^{b^c}',
  'x_1,\\ a_{ij},\\ H_2O',
  'x_1^2,\\ A_{ij}^{k}',
  '\\frac{a}{b},\\ \\frac{n!}{k!},\\ \\tfrac{1}{2},\\ \\dfrac{x+1}{x-1}',
  '\\sqrt{x},\\ \\sqrt{x^2 + y^2},\\ \\sqrt[3]{8},\\ \\sqrt[n]{x^2}',
  '+,\\ - ,\\ \\times,\\ \\div,\\ \\pm,\\ \\mp,\\ \\cdot,\\ \\ast,\\ \\star,\\ \\circ',
  '\\oplus,\\ \\otimes,\\ \\odot,\\ \\bullet',
  '=,\\ \\neq,\\ \\ne,\\ <,\\ >,\\ \\leq,\\ \\geq,\\ \\ll,\\ \\gg,\\ \\approx,\\ \\equiv,\\ \\propto,\\ \\sim',
  '\\forall,\\ \\exists,\\nexists,\\ \\neg,\\ \\lnot,\\ \\wedge,\\ \\vee,\\ \\land,\\ \\lor',
  '\\Rightarrow,\\ \\Leftarrow,\\ \\Leftrightarrow,\\ \\implies,\\ \\impliedby,\\ \\iff',
  '\\to,\\ \\rightarrow,\\ \\leftarrow,\\ \\uparrow,\\ \\downarrow,\\ \\mapsto,\\ \\longmapsto',
  '\\longrightarrow,\\ \\longleftarrow,\\ \\Longrightarrow',
  '\\cup,\\ \\cap,\\ \\setminus,\\ \\subset,\\ \\subseteq,\\ \\supset,\\ \\sqsubset',
  '\\in,\\ \\notin,\\ \\ni,\\ \\emptyset,\\ \\varnothing',
  '\\mathbb{N},\\ \\mathbb{Z},\\ \\mathbb{Q},\\ \\mathbb{R},\\ \\mathbb{C}',
  '\\{x \\in \\mathbb{R} \\mid x^2 < 2\\}',
  '\\binom{n}{k},\\ \\dbinom{2n}{n}',
  '\\lvert a\\rvert,\\ \\lVert v\\rVert',
];

const display = [
  '\\frac{d}{dx}\\left( \\int_{a}^{x} f(t)\\,dt \\right) = f(x)',
  '\\frac{1}{1 + \\frac{1}{1 + \\frac{1}{x}}}',
  '\\left( \\frac{a}{b} \\right),\\quad \\left[ \\frac{a}{b} \\right],\\quad \\left\\{ \\frac{a}{b} \\right\\},\\quad \\left| \\frac{a}{b} \\right|,\\quad \\left\\| \\frac{a}{b} \\right\\|',
  '\\big( x \\big),\\ \\Big( x \\Big),\\ \\bigg( x \\bigg),\\ \\Bigg( x \\Bigg)',
  '\\left( \\left[ \\left\\{ \\frac{a}{b} \\right\\} \\right] \\right)',
  '\\left\\{ \\begin{array}{ll} 1 & \\text{if } x > 0 \\\\ 0 & \\text{if } x \\le 0 \\end{array} \\right.',
  '\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}',
  '\\begin{bmatrix} a & b \\\\ c & d \\end{bmatrix}',
  '\\begin{Bmatrix} p & q \\\\ r & s \\end{Bmatrix}',
  '\\begin{vmatrix} x & y \\\\ z & w \\end{vmatrix} = xw - yz',
  '\\begin{Vmatrix} a & b \\\\ c & d \\end{Vmatrix}',
  '\\begin{matrix} 1 & 0 \\\\ 0 & 1 \\end{matrix}',
  '\\begin{array}{c|c} a & b \\\\ \\hline c & d \\end{array}',
  '\\begin{pmatrix} \\begin{matrix} 1 & 0 \\\\ 0 & 1 \\end{matrix} & 0 \\\\ 0 & \\begin{matrix} 1 & 0 \\\\ 0 & 1 \\end{matrix} \\end{pmatrix}',
  '\\begin{cases} x^2, & x \\ge 0 \\\\ -x, & x < 0 \\end{cases}',
  'f(x) = \\begin{cases} 1, & x = 0 \\\\ \\dfrac{\\sin x}{x}, & x \\neq 0 \\end{cases}',
  '\\begin{aligned} (a + b)^2 &= a^2 + 2ab + b^2 \\\\ (a - b)^2 &= a^2 - 2ab + b^2 \\end{aligned}',
  '\\begin{aligned} \\sin x &= x - \\frac{x^3}{3!} + \\frac{x^5}{5!} - \\cdots \\\\ &= \\sum_{n=0}^{\\infty} \\frac{(-1)^n}{(2n+1)!}\\,x^{2n+1} \\end{aligned}',
  '\\begin{gathered} a^2 + b^2 = c^2 \\\\ e^{i\\pi} + 1 = 0 \\end{gathered}',
  '\\begin{align} x + y &= 7 \\\\ x - y &= 1 \\end{align}',
  '\\lim_{x \\to 0} \\frac{\\sin x}{x} = 1',
  '\\lim_{n \\to \\infty} \\left(1 + \\frac{1}{n}\\right)^n = e',
  '\\underset{x \\to 0}{\\lim} f(x)',
  "\\frac{dy}{dx},\\quad f'(x),\\quad y''",
  '\\frac{\\partial f}{\\partial x},\\quad \\frac{\\partial^2 f}{\\partial x \\partial y}',
  '\\nabla f = \\left( \\frac{\\partial f}{\\partial x}, \\frac{\\partial f}{\\partial y} \\right)',
  '\\int_{a}^{b} f(x)\\,dx',
  '\\iint_{D} f(x,y)\\,dx\\,dy',
  '\\iiint_{V} f(x,y,z)\\,dV',
  '\\oint_{\\gamma} f\\,ds',
  '\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}',
  '\\prod_{k=1}^{n} k = n!',
  '\\sum_{i=0}^{n} \\binom{n}{i} = 2^n',
  '\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}',
  '\\overline{z},\\ \\overline{AB},\\ \\underline{x},\\ \\underline{ABC}',
  '\\hat{a},\\ \\hat{\\beta},\\ \\widehat{ABC}',
  '\\tilde{x},\\ \\tilde{\\alpha},\\ \\widetilde{ABC}',
  '\\vec{v},\\ \\overrightarrow{AB},\\ \\overrightarrow{AB}+\\overrightarrow{BC}',
  '\\dot{x},\\ \\ddot{x},\\ \\dddot{x}',
  '\\mathbb{R},\\ \\mathbb{N},\\ \\mathbb{Z},\\ \\mathbb{Q},\\ \\mathbb{C}',
  '\\mathcal{F},\\ \\mathcal{L},\\ \\mathcal{O},\\ \\mathcal{P}',
  '\\mathbf{A},\\ \\mathbf{v},\\ \\mathbf{x}_1',
  '\\mathrm{d}x,\\ \\mathrm{e},\\ \\mathrm{i}',
  '\\boldsymbol{\\alpha},\\ \\boldsymbol{\\beta},\\ \\boldsymbol{\\theta}',
  '\\text{如果 } a = b \\text{，则 } c = d',
  '\\text{当 } x > 0 \\text{ 时，} f(x) = x^2',
  '\\boxed{E = mc^2}',
  'f(x) = x^2 \\tag{1}',
  '\\overset{\\text{def}}{=}',
  '\\color{red}{\\text{红色}}\\quad \\color{blue}{\\text{蓝色}}\\quad \\color{#2F63E8}{\\text{自定义}}',
  '\\underbrace{1 + 1 + \\cdots + 1}_{n\\ \\text{个}} = n',
  '\\overbrace{a + b + c}^{\\text{三项}}',
  '\\newcommand{\\vctr}[1]{\\mathbf{#1}} \\lvert \\vctr{a} \\rvert^2 = \\vctr{a} \\cdot \\vctr{a}',
  'e^{i\\pi} + 1 = 0 \\qquad \\zeta(s) = \\sum_{n=1}^{\\infty} \\frac{1}{n^s}',
  '\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix} \\begin{pmatrix} x \\\\ y \\end{pmatrix} = \\begin{pmatrix} ax + by \\\\ cx + dy \\end{pmatrix}',
  '\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}, \\qquad \\lim_{n \\to \\infty} \\left(1 + \\frac{1}{n}\\right)^n = e',
  '\\gcd(a, b)\\bmod m,\\quad \\log_2 n,\\quad \\ln x,\\quad \\arctan t',
  'A \\uplus B,\\quad A \\setminus B,\\quad A \\triangle B,\\quad A \\preceq B',
  '\\therefore\\; a \\parallel b,\\qquad \\because\\; \\angle 1 = \\angle 2',
  '\\left[ 0, \\frac{\\pi}{2} \\right),\\quad \\langle u, v \\rangle,\\quad \\lceil x \\rceil,\\quad \\lfloor x \\rfloor',
];

let bad = 0;
function run(list, mode) {
  for (const src of list) {
    try {
      katex.renderToString(src, {
        displayMode: mode === 'display', throwOnError: true, output: 'html', strict: 'error',
      });
    } catch (e) {
      bad++;
      console.log('FAIL [' + mode + '] ' + src + '\n      -> ' + e.message);
    }
  }
}
run(inline, 'inline');
run(display, 'display');
console.log('\n' + (bad === 0 ? 'ALL ' + (inline.length + display.length) + ' FORMULAS OK' : bad + ' FAILED'));
