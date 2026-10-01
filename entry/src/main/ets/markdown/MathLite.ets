/**
 * LiteMdReader · 数学公式子集渲染器（MathLite）
 * ==============================================
 *
 * 端上没有 KaTeX/Web 运行时，这里**自绘实现常用 LaTeX 数学子集**：
 *   - 希腊字母与常见符号/关系符/箭头（映射为 Unicode）
 *   - \frac 分数（块级真正堆叠排版：分子/横线/分母）
 *   - ^ 上标 / _ 下标（缩小字号 + 基线偏移；行内用 Unicode 上下标字符）
 *   - \sqrt 根号（√ + 上划线）
 *   - \begin{pmatrix|bmatrix|vmatrix|matrix|cases} 矩阵/分段（真实网格 + 定界符）
 *   - \text \mathrm \mathbf \mathbb \hat \bar \vec \tilde \dot 等常用命令
 * 子集之外的原样显示，不做伪装。
 *
 * 两级渲染：
 *   inlineText(latex) —— 线性化为单行 Unicode 文本（行内公式、分数/矩阵的分子分母）
 *   segments(latex)   —— 顶层结构切分（文本段/分数/上下标/根号/矩阵），供块级排版
 */

/** 符号表条目 */
interface SymEntry {
  cmd: string;
  ch: string;
}

/** readGroup / readCommand / readSupTarget 的返回：文本 + 下一位置 */
class StrPos {
  text: string = '';
  next: number = 0;
}

/** \begin{env}...\end{env} 捕获结果 */
class EnvHit {
  env: string = '';
  body: string = '';
  next: number = 0;
}

const GREEK: SymEntry[] = [
  { cmd: 'alpha', ch: 'α' }, { cmd: 'beta', ch: 'β' }, { cmd: 'gamma', ch: 'γ' },
  { cmd: 'delta', ch: 'δ' }, { cmd: 'epsilon', ch: 'ε' }, { cmd: 'varepsilon', ch: 'ε' },
  { cmd: 'zeta', ch: 'ζ' }, { cmd: 'eta', ch: 'η' }, { cmd: 'theta', ch: 'θ' },
  { cmd: 'iota', ch: 'ι' }, { cmd: 'kappa', ch: 'κ' }, { cmd: 'lambda', ch: 'λ' },
  { cmd: 'mu', ch: 'μ' }, { cmd: 'nu', ch: 'ν' }, { cmd: 'xi', ch: 'ξ' },
  { cmd: 'pi', ch: 'π' }, { cmd: 'rho', ch: 'ρ' }, { cmd: 'sigma', ch: 'σ' },
  { cmd: 'tau', ch: 'τ' }, { cmd: 'upsilon', ch: 'υ' }, { cmd: 'phi', ch: 'φ' },
  { cmd: 'varphi', ch: 'φ' }, { cmd: 'chi', ch: 'χ' }, { cmd: 'psi', ch: 'ψ' },
  { cmd: 'omega', ch: 'ω' }, { cmd: 'Gamma', ch: 'Γ' }, { cmd: 'Delta', ch: 'Δ' },
  { cmd: 'Theta', ch: 'Θ' }, { cmd: 'Lambda', ch: 'Λ' }, { cmd: 'Xi', ch: 'Ξ' },
  { cmd: 'Pi', ch: 'Π' }, { cmd: 'Sigma', ch: 'Σ' }, { cmd: 'Phi', ch: 'Φ' },
  { cmd: 'Psi', ch: 'Ψ' }, { cmd: 'Omega', ch: 'Ω' }
];

const OPERATORS: SymEntry[] = [
  { cmd: 'times', ch: '×' }, { cmd: 'cdot', ch: '⋅' }, { cmd: 'div', ch: '÷' },
  { cmd: 'pm', ch: '±' }, { cmd: 'mp', ch: '∓' }, { cmd: 'leq', ch: '≤' },
  { cmd: 'le', ch: '≤' }, { cmd: 'geq', ch: '≥' }, { cmd: 'ge', ch: '≥' },
  { cmd: 'neq', ch: '≠' }, { cmd: 'ne', ch: '≠' }, { cmd: 'approx', ch: '≈' },
  { cmd: 'equiv', ch: '≡' }, { cmd: 'sim', ch: '∼' }, { cmd: 'propto', ch: '∝' },
  { cmd: 'infty', ch: '∞' }, { cmd: 'partial', ch: '∂' }, { cmd: 'nabla', ch: '∇' },
  { cmd: 'int', ch: '∫' }, { cmd: 'iint', ch: '∬' }, { cmd: 'iiint', ch: '∭' },
  { cmd: 'sum', ch: '∑' }, { cmd: 'prod', ch: '∏' }, { cmd: 'in', ch: '∈' },
  { cmd: 'notin', ch: '∉' }, { cmd: 'subset', ch: '⊂' }, { cmd: 'subseteq', ch: '⊆' },
  { cmd: 'cup', ch: '∪' }, { cmd: 'cap', ch: '∩' }, { cmd: 'emptyset', ch: '∅' },
  { cmd: 'forall', ch: '∀' }, { cmd: 'exists', ch: '∃' }, { cmd: 'neg', ch: '¬' },
  { cmd: 'lnot', ch: '¬' }, { cmd: 'land', ch: '∧' }, { cmd: 'lor', ch: '∨' },
  { cmd: 'oplus', ch: '⊕' }, { cmd: 'otimes', ch: '⊗' }, { cmd: 'perp', ch: '⊥' },
  { cmd: 'angle', ch: '∠' }, { cmd: 'degree', ch: '°' }, { cmd: 'prime', ch: '′' },
  { cmd: 'rightarrow', ch: '→' }, { cmd: 'to', ch: '→' }, { cmd: 'leftarrow', ch: '←' },
  { cmd: 'Rightarrow', ch: '⇒' }, { cmd: 'Leftarrow', ch: '⇐' },
  { cmd: 'leftrightarrow', ch: '↔' }, { cmd: 'Leftrightarrow', ch: '⇔' },
  { cmd: 'mapsto', ch: '↦' }, { cmd: 'uparrow', ch: '↑' }, { cmd: 'downarrow', ch: '↓' },
  { cmd: 'circ', ch: '∘' }, { cmd: 'bullet', ch: '•' }, { cmd: 'star', ch: '⋆' },
  { cmd: 'ldots', ch: '…' }, { cmd: 'cdots', ch: '⋯' }, { cmd: 'vdots', ch: '⋮' },
  { cmd: 'ddots', ch: '⋱' }, { cmd: 'lfloor', ch: '⌊' }, { cmd: 'rfloor', ch: '⌋' },
  { cmd: 'lceil', ch: '⌈' }, { cmd: 'rceil', ch: '⌉' }
];

const FUNCTIONS: SymEntry[] = [
  { cmd: 'sin', ch: 'sin' }, { cmd: 'cos', ch: 'cos' }, { cmd: 'tan', ch: 'tan' },
  { cmd: 'cot', ch: 'cot' }, { cmd: 'log', ch: 'log' }, { cmd: 'ln', ch: 'ln' },
  { cmd: 'lg', ch: 'lg' }, { cmd: 'exp', ch: 'exp' }, { cmd: 'min', ch: 'min' },
  { cmd: 'max', ch: 'max' }, { cmd: 'lim', ch: 'lim' }, { cmd: 'det', ch: 'det' },
  { cmd: 'gcd', ch: 'gcd' }, { cmd: 'arcsin', ch: 'arcsin' }, { cmd: 'arccos', ch: 'arccos' },
  { cmd: 'arctan', ch: 'arctan' }
];

const MATHBB: SymEntry[] = [
  { cmd: 'R', ch: 'ℝ' }, { cmd: 'N', ch: 'ℕ' }, { cmd: 'Z', ch: 'ℤ' },
  { cmd: 'Q', ch: 'ℚ' }, { cmd: 'C', ch: 'ℂ' }, { cmd: 'E', ch: '𝔼' }
];

const SUP_MAP: SymEntry[] = [
  { cmd: '0', ch: '⁰' }, { cmd: '1', ch: '¹' }, { cmd: '2', ch: '²' }, { cmd: '3', ch: '³' },
  { cmd: '4', ch: '⁴' }, { cmd: '5', ch: '⁵' }, { cmd: '6', ch: '⁶' }, { cmd: '7', ch: '⁷' },
  { cmd: '8', ch: '⁸' }, { cmd: '9', ch: '⁹' }, { cmd: '+', ch: '⁺' }, { cmd: '-', ch: '⁻' },
  { cmd: '−', ch: '⁻' }, { cmd: '=', ch: '⁼' }, { cmd: '(', ch: '⁽' }, { cmd: ')', ch: '⁾' },
  { cmd: 'n', ch: 'ⁿ' }, { cmd: 'i', ch: 'ⁱ' }
];

const SUB_MAP: SymEntry[] = [
  { cmd: '0', ch: '₀' }, { cmd: '1', ch: '₁' }, { cmd: '2', ch: '₂' }, { cmd: '3', ch: '₃' },
  { cmd: '4', ch: '₄' }, { cmd: '5', ch: '₅' }, { cmd: '6', ch: '₆' }, { cmd: '7', ch: '₇' },
  { cmd: '8', ch: '₈' }, { cmd: '9', ch: '₉' }, { cmd: '+', ch: '₊' }, { cmd: '-', ch: '₋' },
  { cmd: '−', ch: '₋' }, { cmd: '=', ch: '₌' }, { cmd: '(', ch: '₍' }, { cmd: ')', ch: '₎' },
  { cmd: 'a', ch: 'ₐ' }, { cmd: 'e', ch: 'ₑ' }, { cmd: 'h', ch: 'ₕ' }, { cmd: 'i', ch: 'ᵢ' },
  { cmd: 'j', ch: 'ⱼ' }, { cmd: 'k', ch: 'ₖ' }, { cmd: 'l', ch: 'ₗ' }, { cmd: 'm', ch: 'ₘ' },
  { cmd: 'n', ch: 'ₙ' }, { cmd: 'o', ch: 'ₒ' }, { cmd: 'p', ch: 'ₚ' }, { cmd: 'r', ch: 'ᵣ' },
  { cmd: 's', ch: 'ₛ' }, { cmd: 't', ch: 'ₜ' }, { cmd: 'u', ch: 'ᵤ' }, { cmd: 'v', ch: 'ᵥ' },
  { cmd: 'x', ch: 'ₓ' }
];

function lookup(entries: SymEntry[], cmd: string): string {
  for (let k = 0; k < entries.length; k++) {
    if (entries[k].cmd === cmd) {
      return entries[k].ch;
    }
  }
  return '';
}

/** 顶层结构段。kind: 't' 文本 | 'frac' | 'sqrt' | 'sup' | 'sub' | 'matrix' | 'cases' */
export interface MathSeg {
  kind: string;
  /** 't' / 'sup' / 'sub' / 'sqrt' 的文本；矩阵为空 */
  text: string;
  /** frac 分子（已线性化）；矩阵段复用为左定界符 */
  num: string;
  /** frac 分母（已线性化）；矩阵段复用为右定界符 */
  den: string;
  /** 矩阵/分段的行，每行是已线性化的单元格数组 */
  rows: string[][];
}

export class MathLite {
  /** 字母或数字（无花括号参数的单记号判定用）。 */
  private static isWordChar(ch: string): boolean {
    const c: number = ch.charCodeAt(0);
    return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
  }

  /**
   * 读一个参数：`{…}` 组，或 LaTeX 允许的「单记号」参数（`\frac12`、`\sqrt x`、`^2`）。
   *
   * **必须保证 `next > start`**：所有调用方都拿 `next` 当游标，
   * 之前「参数不是 `{` 就返回默认值（next = 0）」的实现会让游标跳回开头原地打转，
   * 奕澄教程里的一行 `\frac25 \pi` 就把整个应用卡死并最终闪退。
   */
  private static readGroup(src: string, start: number): StrPos {
    const r: StrPos = new StrPos();
    if (start >= src.length) {
      r.next = start;
      return r;
    }
    if (src.charAt(start) !== '{') {
      // 无花括号参数：读一个记号——命令、连续字母数字，或单个字符
      const c: string = src.charAt(start);
      if (c === '\\') {
        const cmd: StrPos = MathLite.readCommand(src, start + 1);
        if (cmd.next > start) {
          r.text = src.substring(start, cmd.next);
          r.next = cmd.next;
          return r;
        }
      }
      let i: number = start;
      while (i < src.length && MathLite.isWordChar(src.charAt(i))) {
        i++;
      }
      if (i > start) {
        r.text = src.substring(start, i);
        r.next = i;
        return r;
      }
      r.text = c;
      r.next = start + 1;
      return r;
    }
    let depth: number = 0;
    let i: number = start;
    while (i < src.length) {
      const c: string = src.charAt(i);
      if (c === '\\') {
        i += 2;
        continue;
      }
      if (c === '{') {
        depth++;
      } else if (c === '}') {
        depth--;
        if (depth === 0) {
          r.text = src.substring(start + 1, i);
          r.next = i + 1;
          return r;
        }
      }
      i++;
    }
    r.text = src.substring(start + 1);
    r.next = src.length;
    return r;
  }

  /** 读命令名（字母序列）或单字符命令。 */
  private static readCommand(src: string, start: number): StrPos {
    const r: StrPos = new StrPos();
    r.next = start;
    if (start >= src.length) {
      return r;
    }
    const c: string = src.charAt(start);
    if (c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
      let i: number = start;
      while (i < src.length) {
        const ch: string = src.charAt(i);
        if (ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z') {
          i++;
        } else {
          break;
        }
      }
      r.text = src.substring(start, i);
      r.next = i;
      return r;
    }
    r.text = c;
    r.next = start + 1;
    return r;
  }

  private static symbolText(cmd: string): string {
    const g: string = lookup(GREEK, cmd);
    if (g.length > 0) {
      return g;
    }
    const o: string = lookup(OPERATORS, cmd);
    if (o.length > 0) {
      return o;
    }
    const f: string = lookup(FUNCTIONS, cmd);
    if (f.length > 0) {
      return f + ' ';
    }
    return '';
  }

  private static spaceText(cmd: string): string {
    if (cmd === 'quad') {
      return '  ';
    }
    if (cmd === 'qquad') {
      return '    ';
    }
    if (cmd === ',' || cmd === ';' || cmd === ':') {
      return ' ';
    }
    if (cmd === '!') {
      return '';
    }
    return '';
  }

  /** \begin{env}...\end{env} 捕获。start 指向 begin 后的 '{'。 */
  private static captureEnv(src: string, braceStart: number): EnvHit {
    const r: EnvHit = new EnvHit();
    const nameEnd: number = src.indexOf('}', braceStart + 1);
    if (braceStart >= src.length || src.charAt(braceStart) !== '{' || nameEnd < 0) {
      r.next = braceStart;
      return r;
    }
    r.env = src.substring(braceStart + 1, nameEnd);
    const endTag: string = '\\end{' + r.env + '}';
    const endAt: number = src.indexOf(endTag, nameEnd);
    if (endAt < 0) {
      r.body = src.substring(nameEnd + 1);
      r.next = src.length;
    } else {
      r.body = src.substring(nameEnd + 1, endAt);
      r.next = endAt + endTag.length;
    }
    return r;
  }

  /** 上/下标目标：{组} 或单个字符或命令。 */
  private static readSupTarget(src: string, start: number): StrPos {
    if (start >= src.length) {
      // **next 必须是 start**：调用方拿 next 当游标，返回 0 会原地打转死循环
      const r: StrPos = new StrPos();
      r.next = start;
      return r;
    }
    if (src.charAt(start) === '{') {
      return MathLite.readGroup(src, start);
    }
    if (src.charAt(start) === '\\') {
      const cmd: StrPos = MathLite.readCommand(src, start + 1);
      const r: StrPos = new StrPos();
      r.text = '\\' + cmd.text;
      r.next = cmd.next > start ? cmd.next : start + 1;
      return r;
    }
    const r: StrPos = new StrPos();
    r.text = src.charAt(start);
    r.next = start + 1;
    return r;
  }

  private static skipSpace(src: string, i: number): number {
    while (i < src.length && (src.charAt(i) === ' ' || src.charAt(i) === '\t')) {
      i++;
    }
    return i;
  }

  private static scriptChars(text: string, sup: boolean): string {
    const map: SymEntry[] = sup ? SUP_MAP : SUB_MAP;
    let out: string = '';
    let ok: boolean = text.length > 0;
    for (let k = 0; k < text.length; k++) {
      const m: string = lookup(map, text.charAt(k));
      if (m.length === 0) {
        ok = false;
        break;
      }
      out += m;
    }
    if (ok) {
      return out;
    }
    const linear: string = MathLite.inlineText(text);
    return sup ? '^(' + linear + ')' : '_(' + linear + ')';
  }

  /** 处理一个 \命令（含其参数），把线性化结果追加到 out，返回新的 i。 */
  private static command(src: string, i: number, out: string[]): number {
    const n: number = src.length;
    const cmdInfo: StrPos = MathLite.readCommand(src, i + 1);
    const cmd: string = cmdInfo.text;
    const next: number = cmdInfo.next;
    if (cmd === 'frac') {
      // LaTeX 允许裸参数：rac25 = rac{2}{5}
      let p1: number = MathLite.skipSpace(src, next);
      let numSrc: string = '';
      let denSrc: string = '';
      if (p1 < src.length && src.charAt(p1) === '{') {
        const g1: StrPos = MathLite.readGroup(src, p1);
        numSrc = g1.text;
        p1 = MathLite.skipSpace(src, g1.next);
      } else if (p1 < src.length) {
        numSrc = src.charAt(p1);
        p1++;
      }
      let p2: number = MathLite.skipSpace(src, p1);
      if (p2 < src.length && src.charAt(p2) === '{') {
        const g2: StrPos = MathLite.readGroup(src, p2);
        denSrc = g2.text;
        p2 = g2.next;
      } else if (p2 < src.length) {
        denSrc = src.charAt(p2);
        p2++;
      }
      out.push('(' + MathLite.inlineText(numSrc) + ')/(' + MathLite.inlineText(denSrc) + ')');
      return p2;
    }
    if (cmd === 'color') {
      // color{..} 消费掉（子集不支持局部着色），内容继续按原样式渲染
      const at: number = src.indexOf('{', MathLite.skipSpace(src, next));
      if (at >= 0) {
        const g: StrPos = MathLite.readGroup(src, at);
        return g.next;
      }
      return next;
    }
    if (cmd === 'displaystyle' || cmd === 'textstyle' || cmd === 'scriptstyle'
      || cmd === 'limits' || cmd === 'nolimits' || cmd === 'left.' ) {
      return next;
    }
    if (cmd === 'bigl' || cmd === 'Bigl' || cmd === 'biggl' || cmd === 'Biggl'
      || cmd === 'bigr' || cmd === 'Bigr' || cmd === 'biggr' || cmd === 'Biggr'
      || cmd === 'bigm' || cmd === 'Bigm') {
      // Bigl( 等：消费命令本身，定界符按普通字符输出
      if (next < src.length && src.charAt(next) !== ' ') {
        const d: string = src.charAt(next);
        out.push(d === '.' ? '' : d);
        return next + 1;
      }
      return next;
    }
    if (cmd === 'sqrt') {
      const g1: StrPos = MathLite.readGroup(src, MathLite.skipSpace(src, next));
      out.push('√(' + MathLite.inlineText(g1.text) + ')');
      return g1.next;
    }
    if (cmd === 'begin') {
      const env: EnvHit = MathLite.captureEnv(src, MathLite.skipSpace(src, next));
      out.push(MathLite.envInline(env.body));
      return env.next;
    }
    if (cmd === 'end') {
      const at: number = src.indexOf('}', next);
      return at >= 0 ? at + 1 : next;
    }
    if (cmd === 'text' || cmd === 'mathrm' || cmd === 'mathbf' || cmd === 'mathit'
      || cmd === 'operatorname') {
      const g1: StrPos = MathLite.readGroup(src, MathLite.skipSpace(src, next));
      out.push(g1.text);
      return g1.next;
    }
    if (cmd === 'mathbb') {
      const g1: StrPos = MathLite.readGroup(src, MathLite.skipSpace(src, next));
      let bb: string = '';
      for (let k = 0; k < g1.text.length; k++) {
        const m: string = lookup(MATHBB, g1.text.charAt(k));
        bb += m.length > 0 ? m : g1.text.charAt(k);
      }
      out.push(bb);
      return g1.next;
    }
    if (cmd === 'hat' || cmd === 'bar' || cmd === 'vec' || cmd === 'tilde' || cmd === 'dot') {
      const g1: StrPos = MathLite.readGroup(src, MathLite.skipSpace(src, next));
      const t: string = MathLite.inlineText(g1.text);
      const mark: string = cmd === 'hat' ? '\u0302' : cmd === 'bar' ? '\u0304'
        : cmd === 'vec' ? '\u20D7' : cmd === 'dot' ? '\u0307' : '\u0303';
      out.push(t.length > 0 ? t.charAt(0) + mark + t.substring(1) : '');
      return g1.next;
    }
    if (cmd === 'left' || cmd === 'right') {
      if (next < n && src.charAt(next) !== ' ') {
        const d: string = src.charAt(next);
        out.push(d === '.' ? '' : d);
        return next + 1;
      }
      return next;
    }
    if (cmd === 'big' || cmd === 'Big' || cmd === 'bigg' || cmd === 'Bigg') {
      return next;
    }
    const sp: string = MathLite.spaceText(cmd);
    if (cmd === ',' || cmd === ';' || cmd === ':' || cmd === '!' || cmd === 'quad' || cmd === 'qquad') {
      out.push(sp);
      return next;
    }
    const sym: string = MathLite.symbolText(cmd);
    if (sym.length > 0) {
      out.push(sym);
      return next;
    }
    if (cmd === '\\') {
      out.push(' ; ');
      return next;
    }
    // 未知命令：原样显示，不伪装
    out.push('\\' + cmd);
    return next;
  }

  /** 行内线性化：把 LaTeX 折叠成单行 Unicode 文本。 */
  static inlineText(latex: string): string {
    const out: string[] = [];
    let i: number = 0;
    const n: number = latex.length;
    // 同 segments：迭代上限兜底，一个坏公式不能卡死整个应用
    let guard: number = 0;
    while (i < n && guard < 5000) {
      guard++;
      const c: string = latex.charAt(i);
      if (c === '\\') {
        const next: number = MathLite.command(latex, i, out);
        // 防御：解析必须前进。卡在原地 = 整个应用卡死在这一个公式上
        i = next > i ? next : i + 1;
        continue;
      }
      if (c === '^' || c === '_') {
        const target: StrPos = MathLite.readSupTarget(latex, i + 1);
        out.push(MathLite.scriptChars(MathLite.inlineText(target.text), c === '^'));
        i = target.next > i ? target.next : i + 1;
        continue;
      }
      if (c === '{') {
        const g1: StrPos = MathLite.readGroup(latex, i);
        out.push(MathLite.inlineText(g1.text));
        i = g1.next > i ? g1.next : i + 1;
        continue;
      }
      if (c === '}' || c === '$') {
        i++;
        continue;
      }
      out.push(c);
      i++;
    }
    return out.join('');
  }

  /** 环境体的行内线性化：行间 ' ; '，格间 ' , '。 */
  private static envInline(body: string): string {
    if (body.length === 0) {
      return '';
    }
    const rows: string[] = body.split('\\\\');
    const parts: string[] = [];
    for (let r = 0; r < rows.length; r++) {
      const cells: string[] = rows[r].split('&');
      const line: string[] = [];
      for (let c = 0; c < cells.length; c++) {
        line.push(MathLite.inlineText(cells[c].trim()));
      }
      parts.push(line.join(' , '));
    }
    return parts.join(' ; ');
  }

  /**
   * 顶层结构切分（块级排版用）：
   * 文本段线性化；\frac / ^ / _ / \sqrt / \begin{矩阵} 产出结构段。
   */
  static segments(latex: string): MathSeg[] {
    const out: MathSeg[] = [];
    let buf: string = '';
    let i: number = 0;
    const n: number = latex.length;

    const flush: () => void = (): void => {
      if (buf.trim().length > 0) {
        const seg: MathSeg = { kind: 't', text: buf, num: '', den: '', rows: [] };
        out.push(seg);
      }
      buf = '';
    };

    // 兜底保险：即使某条分支的游标没前进，最多迭代 5000 次就退出，
    // 绝不允许一个公式把整个应用卡死（奕澄教程的 \frac25 教训）
    let guard: number = 0;
    while (i < n && guard < 5000) {
      guard++;
      const c: string = latex.charAt(i);
      if (c === '\\') {
        const cmdInfo: StrPos = MathLite.readCommand(latex, i + 1);
        const cmd: string = cmdInfo.text;
        const next: number = cmdInfo.next;
        if (cmd === 'frac') {
          let p1: number = MathLite.skipSpace(latex, next);
          let numSrc: string = '';
          let denSrc: string = '';
          if (p1 < n && latex.charAt(p1) === '{') {
            const g1: StrPos = MathLite.readGroup(latex, p1);
            numSrc = g1.text;
            p1 = MathLite.skipSpace(latex, g1.next);
          } else if (p1 < n) {
            numSrc = latex.charAt(p1);
            p1++;
          }
          let p2: number = MathLite.skipSpace(latex, p1);
          if (p2 < n && latex.charAt(p2) === '{') {
            const g2: StrPos = MathLite.readGroup(latex, p2);
            denSrc = g2.text;
            p2 = g2.next;
          } else if (p2 < n) {
            denSrc = latex.charAt(p2);
            p2++;
          }
          flush();
          const seg: MathSeg = { kind: 'frac', text: '', num: MathLite.inlineText(numSrc), den: MathLite.inlineText(denSrc), rows: [] };
          out.push(seg);
          i = p2;
          continue;
        }
        if (cmd === 'color') {
          const at: number = latex.indexOf('{', MathLite.skipSpace(latex, next));
          if (at >= 0) {
            const g: StrPos = MathLite.readGroup(latex, at);
            i = g.next;
          } else {
            i = next;
          }
          continue;
        }
        if (cmd === 'displaystyle' || cmd === 'textstyle' || cmd === 'scriptstyle'
          || cmd === 'limits' || cmd === 'nolimits') {
          i = next;
          continue;
        }
        if (cmd === 'bigl' || cmd === 'Bigl' || cmd === 'biggl' || cmd === 'Biggl'
          || cmd === 'bigr' || cmd === 'Bigr' || cmd === 'biggr' || cmd === 'Biggr'
          || cmd === 'bigm' || cmd === 'Bigm') {
          if (next < n && latex.charAt(next) !== ' ') {
            const d: string = latex.charAt(next);
            buf += d === '.' ? '' : d;
            i = next + 1;
          } else {
            i = next;
          }
          continue;
        }
        if (cmd === 'sqrt') {
          const g1: StrPos = MathLite.readGroup(latex, MathLite.skipSpace(latex, next));
          flush();
          const seg: MathSeg = { kind: 'sqrt', text: MathLite.inlineText(g1.text), num: '', den: '', rows: [] };
          out.push(seg);
          i = g1.next;
          continue;
        }
        if (cmd === 'begin') {
          const env: EnvHit = MathLite.captureEnv(latex, MathLite.skipSpace(latex, next));
          if (env.env === 'pmatrix' || env.env === 'bmatrix' || env.env === 'vmatrix'
            || env.env === 'matrix' || env.env === 'Bmatrix' || env.env === 'cases') {
            flush();
            const rows: string[][] = [];
            const rawRows: string[] = env.body.split('\\\\');
            for (let r = 0; r < rawRows.length; r++) {
              const cells: string[] = rawRows[r].split('&');
              const line: string[] = [];
              for (let cc = 0; cc < cells.length; cc++) {
                line.push(MathLite.inlineText(cells[cc].trim()));
              }
              rows.push(line);
            }
            const dl: string = env.env === 'cases' ? '{'
              : env.env === 'bmatrix' ? '[' : env.env === 'vmatrix' ? '|'
                : env.env === 'Bmatrix' ? '{' : '(';
            const dr: string = env.env === 'cases' ? ''
              : env.env === 'bmatrix' ? ']' : env.env === 'vmatrix' ? '|'
                : env.env === 'Bmatrix' ? '}' : ')';
            const seg: MathSeg = { kind: env.env === 'cases' ? 'cases' : 'matrix', text: '', num: dl, den: dr, rows: rows };
            out.push(seg);
            i = env.next;
            continue;
          }
          if (env.env === 'aligned' || env.env === 'array' || env.env === 'split') {
            flush();
            const rawRows: string[] = env.body.split('\\\\');
            for (let r = 0; r < rawRows.length; r++) {
              const line: string = MathLite.inlineText(rawRows[r]).trim();
              if (line.length > 0) {
                const seg: MathSeg = { kind: 't', text: line, num: '', den: '', rows: [] };
                out.push(seg);
              }
            }
            i = env.next;
            continue;
          }
          // 未知环境：线性化原样
          buf += MathLite.inlineText('\\begin{' + env.env + '}' + env.body + '\\end{' + env.env + '}');
          i = env.next;
          continue;
        }
        if (cmd === 'end') {
          const at: number = latex.indexOf('}', next);
          i = at >= 0 ? at + 1 : next;
          continue;
        }
        if (cmd === 'text' || cmd === 'mathrm' || cmd === 'mathbf' || cmd === 'mathit'
          || cmd === 'operatorname' || cmd === 'mathbb' || cmd === 'hat' || cmd === 'bar'
          || cmd === 'vec' || cmd === 'tilde' || cmd === 'dot') {
          const pieces: string[] = [];
          i = MathLite.command(latex, i, pieces);
          buf += pieces.join('');
          continue;
        }
        const sp: string = MathLite.spaceText(cmd);
        if (cmd === ',' || cmd === ';' || cmd === ':' || cmd === '!' || cmd === 'quad' || cmd === 'qquad') {
          buf += sp;
          i = next;
          continue;
        }
        const sym: string = MathLite.symbolText(cmd);
        if (sym.length > 0) {
          buf += sym;
          i = next;
          continue;
        }
        if (cmd === '\\') {
          flush();
          i = next;
          continue;
        }
        if (cmd === 'left' || cmd === 'right') {
          if (next < n) {
            const d: string = latex.charAt(next);
            buf += d === '.' ? '' : d;
            i = next + 1;
          } else {
            i = next;
          }
          continue;
        }
        if (cmd === 'big' || cmd === 'Big' || cmd === 'bigg' || cmd === 'Bigg') {
          i = next;
          continue;
        }
        buf += '\\' + cmd;
        i = next;
        continue;
      }
      if (c === '^' || c === '_') {
        const target: StrPos = MathLite.readSupTarget(latex, i + 1);
        flush();
        const seg: MathSeg = { kind: c === '^' ? 'sup' : 'sub', text: MathLite.scriptChars(MathLite.inlineText(target.text), c === '^'), num: '', den: '', rows: [] };
        out.push(seg);
        i = target.next;
        continue;
      }
      if (c === '{') {
        const g1: StrPos = MathLite.readGroup(latex, i);
        buf += MathLite.inlineText(g1.text);
        i = g1.next;
        continue;
      }
      if (c === '}' || c === '$') {
        i++;
        continue;
      }
      buf += c;
      i++;
    }
    flush();
    return out;
  }
}
