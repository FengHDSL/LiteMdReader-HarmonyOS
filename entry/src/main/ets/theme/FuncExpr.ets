/**
 * 澄笺 · 自定义函数壁纸的表达式求值器
 * =====================================
 *
 * 用户在设置页手写 `f(x, y)` 表达式（返回 0~1 的亮度），壁纸按表达式逐格着色。
 * 支持：数字、变量 x / y / t、常量 pi / e、四则 + 幂（^）、括号、一元负号、
 * 函数 sin cos tan abs sqrt floor round min max pow（min / max / pow 两参数）。
 *
 * 实现：编译期把表达式解析成 RPN（调度场算法），求值时遍历 RPN——
 * 一次编译、逐格求值，整屏几千个采样点开销可忽略。
 * 任何语法错误 → ok=false（设置页会提示），求值时兜底返回 0.5，永不抛异常。
 */

interface FuncToken {
  /** n=数字 v=变量(x/y/t) o=运算符 f=函数 */
  kind: string;
  num: number;
  s: string;
}

const FUNC_NAMES: string[] = ['sin', 'cos', 'tan', 'abs', 'sqrt', 'floor', 'round', 'min', 'max', 'pow'];

function precOf(op: string): number {
  if (op === '^') {
    return 4;
  }
  if (op === 'neg') {
    return 3;
  }
  if (op === '*' || op === '/') {
    return 2;
  }
  return 1;
}

export class FuncExpr {
  private rpn: FuncToken[] = [];
  /** 表达式是否合法 */
  public ok: boolean = false;
  public error: string = '';

  /** 编译表达式。失败时 ok=false（error 给原因），eval 兜底返回 0.5。 */
  public static compile(src: string): FuncExpr {
    const f: FuncExpr = new FuncExpr();
    try {
      f.compileInner(src);
      f.ok = true;
    } catch (err) {
      f.ok = false;
      f.error = err instanceof Error ? err.message : '表达式错误';
    }
    return f;
  }

  private compileInner(src: string): void {
    const s: string = src.trim();
    if (s.length === 0) {
      throw new Error('表达式为空');
    }
    const out: FuncToken[] = [];
    const ops: string[] = [];
    const popOp = (): void => {
      const op: string | undefined = ops.pop();
      if (op === undefined || op === '(') {
        throw new Error('括号不匹配');
      }
      out.push({ kind: 'o', num: 0, s: op } as FuncToken);
    };

    let i: number = 0;
    while (i < s.length) {
      const ch: string = s.charAt(i);
      if (ch === ' ') {
        i++;
        continue;
      }
      // 数字（支持小数）
      if ((ch >= '0' && ch <= '9') || ch === '.') {
        let num: string = '';
        while (i < s.length && ((s.charAt(i) >= '0' && s.charAt(i) <= '9') || s.charAt(i) === '.')) {
          num += s.charAt(i);
          i++;
        }
        const v: number = parseFloat(num);
        if (isNaN(v)) {
          throw new Error('数字格式错误');
        }
        out.push({ kind: 'n', num: v, s: '' } as FuncToken);
        continue;
      }
      // 名字：变量 / 常量 / 函数
      if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {
        let name: string = '';
        while (i < s.length && ((s.charAt(i) >= 'a' && s.charAt(i) <= 'z')
          || (s.charAt(i) >= 'A' && s.charAt(i) <= 'Z') || (s.charAt(i) >= '0' && s.charAt(i) <= '9'))) {
          name += s.charAt(i);
          i++;
        }
        const lower: string = name.toLowerCase();
        if (lower === 'x' || lower === 'y' || lower === 't') {
          out.push({ kind: lower, num: 0, s: lower } as FuncToken);
        } else if (lower === 'pi') {
          out.push({ kind: 'n', num: 3.141592653589793, s: '' } as FuncToken);
        } else if (lower === 'e') {
          out.push({ kind: 'n', num: 2.718281828459045, s: '' } as FuncToken);
        } else if (FUNC_NAMES.indexOf(lower) >= 0) {
          ops.push('f:' + lower);
        } else {
          throw new Error('未知名称：' + name);
        }
        continue;
      }
      if (ch === '(') {
        ops.push('(');
        i++;
        continue;
      }
      if (ch === ',') {
        // 函数多参数分隔：当 ')' 处理（弹到左括号为止，但不吞括号）
        while (ops.length > 0 && ops[ops.length - 1] !== '(') {
          popOp();
        }
        if (ops.length === 0) {
          throw new Error('逗号位置错误');
        }
        i++;
        continue;
      }
      if (ch === ')') {
        while (ops.length > 0 && ops[ops.length - 1] !== '(') {
          popOp();
        }
        if (ops.length === 0) {
          throw new Error('括号不匹配');
        }
        ops.pop();
        if (ops.length > 0 && ops[ops.length - 1].startsWith('f:')) {
          out.push({ kind: 'o', num: 0, s: ops.pop() } as FuncToken);
        }
        i++;
        continue;
      }
      if ('+-*/^'.indexOf(ch) >= 0) {
        // 一元负号：表达式开头，或紧跟在运算符 / 左括号之后
        if (ch === '-' && (i === 0 || '+-*/^('.indexOf(s.charAt(i - 1)) >= 0)) {
          ops.push('neg');
          i++;
          continue;
        }
        while (ops.length > 0) {
          const top: string = ops[ops.length - 1];
          if (top === '(' || top.startsWith('f:')) {
            break;
          }
          const tp: number = precOf(top);
          const cp: number = precOf(ch);
          if (tp > cp || (tp === cp && ch !== '^')) {
            popOp();
          } else {
            break;
          }
        }
        ops.push(ch);
        i++;
        continue;
      }
      throw new Error('无法识别的字符：' + ch);
    }
    while (ops.length > 0) {
      popOp();
    }
    this.rpn = out;
  }

  /** 弹栈（带兜底）：ArkTS 的 pop() 返回 number | undefined，必须收窄。 */
  private static popOf(st: number[], fallback: number): number {
    const v: number | undefined = st.pop();
    return v !== undefined ? v : fallback;
  }

  /** 求值 f(x, y, t)，结果钳到 0~1。非法表达式/求值异常兜底 0.5。 */
  public eval(x: number, y: number, t: number): number {
    if (!this.ok) {
      return 0.5;
    }
    const st: number[] = [];
    for (let k = 0; k < this.rpn.length; k++) {
      const tk: FuncToken = this.rpn[k];
      if (tk.kind === 'n') {
        st.push(tk.num);
      } else if (tk.kind === 'x') {
        st.push(x);
      } else if (tk.kind === 'y') {
        st.push(y);
      } else if (tk.kind === 't') {
        st.push(t);
      } else if (tk.kind === 'o') {
        const op: string = tk.s;
        if (op === 'neg') {
          if (st.length < 1) {
            return 0.5;
          }
          st.push(-FuncExpr.popOf(st, 0.5));
          continue;
        }
        if (st.length < 2) {
          return 0.5;
        }
        const b: number = FuncExpr.popOf(st, 0.5);
        const a: number = FuncExpr.popOf(st, 0.5);
        if (op === '+') {
          st.push(a + b);
        } else if (op === '-') {
          st.push(a - b);
        } else if (op === '*') {
          st.push(a * b);
        } else if (op === '/') {
          st.push(b === 0 ? 0 : a / b);
        } else if (op === '^') {
          st.push(Math.pow(a, b));
        }
      } else if (tk.kind === 'f') {
        const name: string = tk.s.substring(2);
        if (name === 'min' || name === 'max' || name === 'pow') {
          if (st.length < 2) {
            return 0.5;
          }
          const b: number = FuncExpr.popOf(st, 0.5);
          const a: number = FuncExpr.popOf(st, 0.5);
          if (name === 'min') {
            st.push(Math.min(a, b));
          } else if (name === 'max') {
            st.push(Math.max(a, b));
          } else {
            st.push(Math.pow(a, b));
          }
        } else {
          if (st.length < 1) {
            return 0.5;
          }
          const a: number = FuncExpr.popOf(st, 0.5);
          if (name === 'sin') {
            st.push(Math.sin(a));
          } else if (name === 'cos') {
            st.push(Math.cos(a));
          } else if (name === 'tan') {
            st.push(Math.tan(a));
          } else if (name === 'abs') {
            st.push(Math.abs(a));
          } else if (name === 'sqrt') {
            st.push(a < 0 ? 0 : Math.sqrt(a));
          } else if (name === 'floor') {
            st.push(Math.floor(a));
          } else if (name === 'round') {
            st.push(Math.round(a));
          }
        }
      }
    }
    const v: number = st.length > 0 ? st[st.length - 1] : 0.5;
    if (isNaN(v)) {
      return 0.5;
    }
    return Math.max(0, Math.min(1, v));
  }
}
