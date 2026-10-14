/**
 * 澄笺 · ZenUML → Mermaid 语法桥
 * ==============================
 *
 * 背景：`@mermaid-js/mermaid-zenuml` 是 mermaid 的外部图种插件，靠 React 渲染。
 * 随包 mermaid 升到 11.17.2 后，该插件（1.0.1，官方只验证到较早的 11.x）在 parse
 * 阶段与新版 mermaid 内部约定错位，真机上必然抛错、由 mermaid 画成
 * 「Syntax error in text」错误卡——插件路线不可靠。
 *
 * 因此把 ZenUML 走**纯文本转译**：ZenUML 的语句形状与时序图高度同构，转成 mermaid
 * sequenceDiagram 后交给**已经在用的** mermaid 引擎出图。确定性、可离线验证、
 * 零额外体积（不用再背 3.3MB 插件 + React）。
 *
 * 覆盖的 ZenUML 语法（官方文档里的常用部分）：
 *   · `title 标题`
 *   · `Alice -> Bob: 消息` / `Alice -> Bob.method()` / `Bob -> Alice: 回复`
 *   · 调用块 `A.method() { ... }`（花括号里自动把发起者记为 A）
 *   · `return 值`（回给发起者）
 *   · `if (cond) {}` / `else {}` / `end`（含 `if (...) { }` 单行形态）
 *   · `loop` / `par` / `opt` / `alt` / `else` / `end`
 *   · `// 注释`、`@Annotation`、`@Starter(...)`、`@return` 之类注解行剔除
 *   · `new` / `annotations` 等修饰词忽略
 */

export class ZenumlBridge {
  /** 内容里的首个非空行是不是 `zenuml` 声明 */
  static isZenuml(src: string): boolean {
    const lines: string[] = src.replace(/\r\n?/g, '\n').split('\n');
    for (let k = 0; k < lines.length; k++) {
      const t: string = lines[k].trim();
      if (t.length === 0 || t.startsWith('%%')) {
        continue;
      }
      return /^zenuml\b/i.test(t);
    }
    return false;
  }

  /**
   * ZenUML → mermaid sequenceDiagram。
   * 返回空串 = 这段不是可转译的 ZenUML（调用侧回落源码代码块）。
   */
  static toMermaid(src: string): string {
    const lines: string[] = src.replace(/\r\n?/g, '\n').split('\n');
    const out: string[] = ['sequenceDiagram'];
    // 调用栈：`A.method() {` 压入 A，`}` 弹出；块内的裸调用归给栈顶
    const stack: string[] = [];
    let sawMessage: boolean = false;
    let sawHead: boolean = false;
    let ids: string[] = [];
    let shows: string[] = [];

    for (let k = 0; k < lines.length; k++) {
      let l: string = lines[k].trim();
      if (l.length === 0) {
        continue;
      }
      // 首个 zenuml 声明
      if (!sawHead && /^zenuml\b/i.test(l)) {
        sawHead = true;
        const rest: string = l.substring(6).trim();
        if (rest.length > 0) {
          out.push('    title ' + rest);
        }
        continue;
      }
      // 注释 / 注解 / 元信息行
      if (l.startsWith('//') || l.startsWith('#') || l.startsWith('@')) {
        continue;
      }
      // 声明：`participant X` / `actor X` / `X as "显示名"`
      const decl: RegExpMatchArray | null = l.match(/^(participant|actor|boundary|control|entity|database)\s+(.+)$/i);
      if (decl !== null) {
        const rest: string = decl[2].trim();
        const asAt: number = rest.toLowerCase().indexOf(' as ');
        const show: string = asAt >= 0 ? rest.substring(0, asAt).trim() : rest;
        const id: string = asAt >= 0 ? rest.substring(asAt + 4).trim() : rest;
        ZenumlBridge.reg(id, ids, shows);
        if (show === id) {
          out.push('    participant ' + ZenumlBridge.unq(id));
        } else {
          out.push('    participant ' + ZenumlBridge.unq(id)
            + ' as ' + ZenumlBridge.unq(show));
        }
        continue;
      }
      // title
      if (/^title\s+/i.test(l)) {
        out.push('    title ' + l.substring(6).trim());
        continue;
      }
      // 块开头：`A.method() {` / `A.method(args) {` / `A->B.method() {`
      const openBlk: RegExpMatchArray | null = l.match(/^([A-Za-z_$][\w$]*)\s*\.\s*([\w$]+)\s*\((.*?)\)\s*\{?$/);
      if (openBlk !== null) {
        const owner: string = openBlk[1];
        const method: string = openBlk[2];
        const caller: string = ZenumlBridge.topOwner(stack);
        const from: string = caller.length > 0 ? caller : owner;
        ZenumlBridge.ensure(from, ids, shows, out);
        ZenumlBridge.ensure(owner, ids, shows, out);
        out.push('    ' + ZenumlBridge.unq(from) + '->>'
          + ZenumlBridge.unq(owner) + ': ' + method + '()');
        sawMessage = true;
        if (l.endsWith('{')) {
          stack.push(owner);
        }
        continue;
      }
      // 纯 `{` 续行（紧跟上一行块头）
      if (l === '{') {
        continue;
      }
      // `}`：对称弹出（方法块弹发起者，控制块弹哨兵）
      if (l === '}' || l === '};') {
        if (stack.length > 0) {
          stack.pop();
        }
        continue;
      }
      // 条件 / 循环：ZenUML 的 if 在 mermaid sequenceDiagram 里没有同名词，
      // 语法上对应 alt（条件分支容器）；while/for 对应 loop。
      const ctrl: RegExpMatchArray | null =
        l.match(/^(if|else|loop|par|opt|alt|catch|finally|while|for)\b\s*(\(?.*?\)?)\s*\{?$/i);
      if (ctrl !== null) {
        const kwIn: string = ctrl[1].toLowerCase();
        const arg: string = (ctrl[2] === undefined || ctrl[2] === null) ? '' : ctrl[2];
        const inner: string = arg.replace(/^\(/, '').replace(/\)$/, '').trim();
        let kw: string = kwIn;
        if (kwIn === 'if') {
          kw = 'alt';
        } else if (kwIn === 'while' || kwIn === 'for') {
          kw = 'loop';
        }
        let tail: string = '';
        const label: string = inner.length > 0 ? inner : arg;
        if (label.length > 0) {
          tail = ' ' + ZenumlBridge.sq(label);
        }
        out.push('    ' + kw + tail);
        if (l.indexOf('{') >= 0) {
          stack.push(ZenumlBridge.CTRL_MARK);
        }
        continue;
      }
      if (/^end\b/i.test(l)) {
        out.push('    end');
        if (stack.length > 0 && stack[stack.length - 1] === ZenumlBridge.CTRL_MARK) {
          stack.pop();
        }
        continue;
      }
      // return 值：回给调用者（栈里上一个真正的发起者）
      const ret: RegExpMatchArray | null = l.match(/^return\b\s*(.*)$/i);
      if (ret !== null) {
        const val: string = ret[1].trim();
        const owner: string = ZenumlBridge.topOwner(stack);
        if (owner.length > 0) {
          const target: string = ZenumlBridge.callerOf(stack);
          out.push('    ' + ZenumlBridge.unq(owner) + '-->>'
            + ZenumlBridge.unq(target.length > 0 ? target : owner) + ': '
            + (val.length > 0 ? val : 'return'));
        }
        continue;
      }
      // 消息：A -> B: text  /  A -> B  /  A -> B.method()  /  A.method() -> B
      const msg: RegExpMatchArray | null =
        l.match(/^([A-Za-z_$][\w$]*)\s*(?:\.\s*[\w$]+\s*\([^)]*\))?\s*->+\s*([A-Za-z_$][\w$]*)\s*(?:\.\s*([\w$]+)\s*\([^)]*\))?\s*(?::\s*(.*))?$/);
      if (msg !== null) {
        const from: string = msg[1];
        const to: string = msg[2];
        const method: string = (msg[3] === undefined || msg[3] === null) ? '' : msg[3];
        const text: string = (msg[4] === undefined || msg[4] === null) ? '' : msg[4].trim();
        ZenumlBridge.ensure(from, ids, shows, out);
        ZenumlBridge.ensure(to, ids, shows, out);
        const label: string = text.length > 0 ? text : (method.length > 0 ? method + '()' : '');
        out.push('    ' + ZenumlBridge.unq(from) + '->>'
          + ZenumlBridge.unq(to) + (label.length > 0 ? ': ' + label : ''));
        sawMessage = true;
        continue;
      }
      // 裸调用：`method()` / `method(args)` → 归给栈顶发起者（无栈则忽略）
      const bare: RegExpMatchArray | null = l.match(/^([\w$]+)\s*\((.*?)\)\s*;?$/);
      if (bare !== null) {
        const who: string = ZenumlBridge.topOwner(stack);
        if (who.length > 0) {
          out.push('    ' + ZenumlBridge.unq(who) + '->>'
            + ZenumlBridge.unq(who) + ': ' + bare[1] + '()');
          sawMessage = true;
        }
        continue;
      }
      // 其余行忽略（注解、语言修饰等）
    }

    // 一条消息都没有 → 不是可转译的 ZenUML，交回调用侧
    if (!sawMessage) {
      return '';
    }
    return out.join('\n');
  }

  /** 控制块哨兵：`if/loop` 这类花括号也占一层栈，保证 `}` 对称弹出 */
  private static readonly CTRL_MARK: string = '\u0000ctrl';

  /** 栈顶真正的发起者（跳过控制块哨兵） */
  private static topOwner(stack: string[]): string {
    for (let k = stack.length - 1; k >= 0; k--) {
      if (stack[k] !== ZenumlBridge.CTRL_MARK) {
        return stack[k];
      }
    }
    return '';
  }

  /** 发起者下面一层（return 的接收方） */
  private static callerOf(stack: string[]): string {
    let seen: number = 0;
    for (let k = stack.length - 1; k >= 0; k--) {
      if (stack[k] === ZenumlBridge.CTRL_MARK) {
        continue;
      }
      seen++;
      if (seen === 2) {
        return stack[k];
      }
    }
    return '';
  }

  /** 登记参与者（按出现顺序），返回是否新登记 */
  private static reg(id: string, ids: string[], shows: string[]): boolean {
    for (let k = 0; k < ids.length; k++) {
      if (ids[k] === id) {
        return false;
      }
    }
    ids.push(id);
    shows.push(id);
    return true;
  }

  /** 需要时补一条 participant 声明（首次出现才写，避免刷屏） */
  private static ensure(id: string, ids: string[], shows: string[], out: string[]): void {
    if (ZenumlBridge.reg(id, ids, shows)) {
      out.push('    participant ' + ZenumlBridge.unq(id));
    }
  }

  /** 去掉可能带上的引号，转义 mermaid 里敏感的冒号 */
  private static unq(s: string): string {
    let t: string = s.trim();
    if (t.length >= 2 && ((t.startsWith('"') && t.endsWith('"'))
      || (t.startsWith("'") && t.endsWith("'")))) {
      t = t.substring(1, t.length - 1);
    }
    return t;
  }

  /** 条件 / 标签里的换行与引号收敛成单行 */
  private static sq(s: string): string {
    return s.replace(/\r?\n/g, ' ').replace(/"/g, "'").trim();
  }
}
