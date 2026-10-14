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
    // 已经写进产物的容器层数（决定 `end` 该不该写）
    let openCtl: number = 0;
    // 上一条消息的双方：平铺 `return` 要知道回给谁
    let lastFrom: string = '';
    let lastTo: string = '';
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
      // 注释 / 元信息行
      if (l.startsWith('//') || l.startsWith('#')) {
        continue;
      }
      // `@Actor 读者` / `@Starter(App)` 这类注解形式的参与者声明：ZenUML 用 @Actor 标角色，
      // 直接当"注解行"丢掉的话参与者就只能等消息行隐式登记（而中文参与者以前根本匹配不上）。
      if (l.charAt(0) === '@') {
        const ann: RegExpMatchArray | null = l.match(/^@(Actor|actor|Starter|Participant|participant)\s*\(?\s*([^)]+?)\s*\)?\s*$/u);
        if (ann !== null) {
          const who: string = ZenumlBridge.unq(ann[2]);
          if (who.length > 0 && ZenumlBridge.reg(who, ids, shows)) {
            // @Actor 才用 mermaid 的 actor（小人），其余（@Starter / @Application…）画普通框
            const isActor: boolean = ann[1].toLowerCase() === 'actor';
            out.push('    ' + (isActor ? 'actor ' : 'participant ') + who);
          }
        }
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
      // ⚠️ 带箭头的那种以前**匹配不上**（模式里没有 `->` 的位置），于是整行被忽略：
      //    发起者不入栈、后续 `return` 全部归错人（实测 `Alice->Bob.check() {` 后
      //    两条 return 都写给了 Bob，Alice 干脆消失）。
      const openBlk: RegExpMatchArray | null = l.match(
        /^([\p{L}\p{N}_$][\p{L}\p{N}_$\-]*?)(?:\s*-+>\s*([\p{L}\p{N}_$][\p{L}\p{N}_$\-]*?))?\s*\.\s*([\p{L}\p{N}_$\-]+)\s*\((.*?)\)\s*\{?$/u);
      if (openBlk !== null) {
        const g1: string = openBlk[1];
        const explicit: string = openBlk[2] === undefined ? '' : openBlk[2];
        const owner: string = explicit.length > 0 ? explicit : g1;
        const method: string = openBlk[3];
        const caller: string = ZenumlBridge.topOwner(stack);
        const from: string = explicit.length > 0 ? g1 : (caller.length > 0 ? caller : owner);
        if (owner.length === 0 || from.length === 0) {
          continue;
        }
        ZenumlBridge.ensure(from, ids, shows, out);
        ZenumlBridge.ensure(owner, ids, shows, out);
        out.push('    ' + ZenumlBridge.unq(from) + '->>'
          + ZenumlBridge.unq(owner) + ': ' + method + '()');
        lastFrom = ZenumlBridge.unq(from);
        lastTo = ZenumlBridge.unq(owner);
        sawMessage = true;
        if (l.endsWith('{')) {
          // 一帧同时记「被调者 + 发起者」：return 要回给发起者。
          // 只压被调者的话，callerOf() 找不到第二层，`return rows` 会写成 Bob-->>Bob
          stack.push(owner + ZenumlBridge.FRAME_SEP + from);
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
          const popped: string = String(stack.pop());
          // 花括号形式的控制块：mermaid 的 alt / loop **必须有 end**，所以 `}` 要替它收尾
          // （以前 `}` 只是弹栈、不写 end → 产物里 `alt 有公式` 永久不闭合，
          //  mermaid 报 "Syntax error in text"，比退回源码更糟）
          if (popped === ZenumlBridge.CTRL_MARK) {
            if (openCtl > 0) {
              openCtl--;
            }
            out.push('    end');
          }
          // 块结束后，外层平铺的 `return` 应该回到这一帧的调用关系上
          // （实测：`Alice->Bob.check() { … } return ok` 的 ok 写给谁，取决于这里）
          if (!ZenumlBridge.isMark(popped) && ZenumlBridge.frameCaller(popped).length > 0) {
            lastTo = ZenumlBridge.unq(ZenumlBridge.frameOwner(popped));
            lastFrom = ZenumlBridge.unq(ZenumlBridge.frameCaller(popped));
          }
        }
        continue;
      }
      // 条件 / 循环：ZenUML 的 if 在 mermaid sequenceDiagram 里没有同名词，
      // 语法上对应 alt（条件分支容器）；while/for 对应 loop。
      // ⚠️ mermaid 不认的容器（group / ref / try / catch / finally）必须**连同它的 end
      //    一起丢**：只丢开头不丢收尾，产物里就多出一个孤儿 `end` → mermaid 直接
      //    `Syntax error in text`（比退回源码更糟）。
      const ctrl: RegExpMatchArray | null =
        l.match(/^(if|else|loop|par|opt|alt|critical|break|and|group|ref|try|catch|finally|while|for)\b\s*(\(?.*?\)?)\s*\{?$/i);
      if (ctrl !== null) {
        const kwIn: string = ctrl[1].toLowerCase();
        const arg: string = (ctrl[2] === undefined || ctrl[2] === null) ? '' : ctrl[2];
        const inner: string = arg.replace(/^\(/, '').replace(/\)$/, '').trim();
        const dropped: boolean = kwIn === 'group' || kwIn === 'ref' || kwIn === 'try'
          || kwIn === 'catch' || kwIn === 'finally';
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
        if (!dropped && kwIn !== 'else' && kwIn !== 'and') {
          openCtl++;
        }
        if (!dropped) {
          out.push('    ' + kw + tail);
        }
        // 容器一律占一层栈（花括号形式由 `}` 弹、end 形式由 `end` 弹），
        // 被丢弃的容器用 SKIP_MARK 占位，这样它的 end 也会跟着被丢掉
        stack.push(dropped ? ZenumlBridge.SKIP_MARK : ZenumlBridge.CTRL_MARK);
        continue;
      }
      if (/^end\b/i.test(l)) {
        // 就近找一个容器标记收尾：CTRL_MARK 才写 end，SKIP_MARK 静默配对
        for (let s: number = stack.length - 1; s >= 0; s--) {
          const top: string = stack[s];
          if (top === ZenumlBridge.CTRL_MARK || top === ZenumlBridge.SKIP_MARK) {
            stack.splice(s, 1);
            if (top === ZenumlBridge.CTRL_MARK && openCtl > 0) {
              openCtl--;
              out.push('    end');
            }
            break;
          }
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
        } else if (lastTo.length > 0 && lastFrom.length > 0) {
          // 没有调用块也能回：ZenUML 允许平铺 `A->B: x` 后直接 `return y`，
          // 语义就是"上一条消息的接收方回给发起方"（此前这条被整行丢掉，用户样本里的
          // `return html` 就这样消失了）
          out.push('    ' + lastTo + '-->>' + lastFrom + ': ' + (val.length > 0 ? val : 'return'));
        }
        continue;
      }
      // 消息：A -> B: text  /  A -> B  /  A -> B.method()  /  A.method() -> B
      // ⚠️ 两个坑都在这条正则上，都是实测踩出来的：
      //  ① 参与者标识符**必须按 Unicode 认**（`\p{L}\p{N}` + u 标志）。写成 [A-Za-z_$][\w$]*
      //     时 `读者->App.open()` 整条不匹配，toMermaid() 因为"一条消息都没有"返回空串，
      //     中文写法的 zenuml 块就整个退回代码块（用户报的那条）。
      //  ② 两端必须**懒惰**且箭头写 `-+>`。贪心的 `[\-$]*` 会把虚线箭头的横线吞进名字里
      //     （`App-->读者` 量出来参与者叫 `App-`），而 `->+` 只认 `->`/`->>`，认不了 `-->`。
      const msg: RegExpMatchArray | null =
        l.match(/^([\p{L}\p{N}_$][\p{L}\p{N}_$\-]*?)\s*(?:\.\s*[\p{L}\p{N}_$\-]+\s*\([^)]*\))?\s*-+>\s*([\p{L}\p{N}_$][\p{L}\p{N}_$\-]*?)\s*(?:\.\s*([\p{L}\p{N}_$\-]+)\s*\([^)]*\))?\s*(?::\s*(.*))?$/u);
      if (msg !== null) {
        const from: string = msg[1];
        const to: string = msg[2];
        const method: string = (msg[3] === undefined || msg[3] === null) ? '' : msg[3];
        const text: string = (msg[4] === undefined || msg[4] === null) ? '' : msg[4].trim();
        if (from.length === 0 || to.length === 0) {
          continue;                        // 懒惰量词在畸形行上可能退成空，别写出 `->>` 空名字
        }
        ZenumlBridge.ensure(from, ids, shows, out);
        ZenumlBridge.ensure(to, ids, shows, out);
        const label: string = text.length > 0 ? text : (method.length > 0 ? method + '()' : '');
        // ZenUML 的 `-->` 是"返回/异步"，mermaid 的 `-->>` 才是虚线 —— 按原箭头的横线数决定
        const dashed: boolean = /-{2,}>/.test(l);
        out.push('    ' + ZenumlBridge.unq(from) + (dashed ? '-->>' : '->>')
          + ZenumlBridge.unq(to) + (label.length > 0 ? ': ' + label : ''));
        lastFrom = ZenumlBridge.unq(from);
        lastTo = ZenumlBridge.unq(to);
        sawMessage = true;
        continue;
      }
      // 裸调用：`method()` / `method(args)` → 归给栈顶发起者（无栈则忽略）
      const bare: RegExpMatchArray | null = l.match(/^([\p{L}\p{N}_$][\p{L}\p{N}_$\-]*)\s*\((.*?)\)\s*;?$/u);
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
  /** 被丢弃容器的占位哨兵：mermaid 没有 `group` / `ref` / `try`，开头丢了，`end` 也要跟着丢 */
  private static readonly SKIP_MARK: string = '\u0000skip';
  /** 栈帧里「被调者 与 发起者」的分隔符（不可能出现在标识符里） */
  private static readonly FRAME_SEP: string = '\u0001';

  /** 栈里是不是一个"容器占位"（不是参与者）——两种哨兵都要跳过，否则 `return` 会回给哨兵 */
  private static isMark(v: string): boolean {
    return v === ZenumlBridge.CTRL_MARK || v === ZenumlBridge.SKIP_MARK;
  }

  /** 栈帧里的被调者（`owner\u0001caller` 的前半） */
  private static frameOwner(v: string): string {
    const at: number = v.indexOf(ZenumlBridge.FRAME_SEP);
    return at < 0 ? v : v.substring(0, at);
  }

  /** 栈帧里的发起者（没有就返回空串） */
  private static frameCaller(v: string): string {
    const at: number = v.indexOf(ZenumlBridge.FRAME_SEP);
    return at < 0 ? '' : v.substring(at + 1);
  }

  /** 栈顶真正的发起者（跳过控制块哨兵） */
  private static topOwner(stack: string[]): string {
    for (let k = stack.length - 1; k >= 0; k--) {
      if (!ZenumlBridge.isMark(stack[k])) {
        return ZenumlBridge.frameOwner(stack[k]);
      }
    }
    return '';
  }

  /** 栈顶那一帧的调用方（return 的接收方） */
  private static callerOf(stack: string[]): string {
    for (let k = stack.length - 1; k >= 0; k--) {
      if (!ZenumlBridge.isMark(stack[k])) {
        return ZenumlBridge.frameCaller(stack[k]);
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
