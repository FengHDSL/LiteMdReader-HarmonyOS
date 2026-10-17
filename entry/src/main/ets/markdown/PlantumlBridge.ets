/**
 * 澄笺 · PlantUML 降级桥（PlantumlBridge）
 * ========================================
 *
 * 阅读页的 PlantUML **首选离线内核** `@plantuml/core`（rawfile/render/plantuml.html，
 * 官方 PlantUML 用 TeaVM 编译成 JS，无 Java 无服务端）。本文件是它的**补位**，用在两处：
 *   1. 内核里没有渲染器的图种（`@startmath` / `@starttimeline` / `@startfiles`），
 *      在这里翻成应用已有的渲染路径：KaTeX 公式、mermaid timeline、制表符文件树；
 *   2. **导出 HTML / 打印**不带内核（一份 5.7MB，不能塞进每个导出产物），
 *      所以导出侧由 `toMermaid()` 把能桥的图种（时序 / 状态 / 类）翻译成 mermaid，
 *      桥不动的保持代码块。
 *
 * ⚠️ **只覆盖三种图**：时序图（→ sequenceDiagram）、状态图（→ stateDiagram-v2）、
 * 类图（→ classDiagram）。用例图 / 活动图 / 组件图语法差异过大，`kindOf()` 返回空串，
 * 调用侧据此**回落成普通代码块显示源码**。
 *
 * ⚠️ **判定必须逐行白名单，不能"看到箭头就转"**：曾经状态图（`[*] --> 草稿`）被当成
 * 时序图硬塞进 sequenceDiagram，mermaid 直接 `Parse error … Expecting 'TXT',
 * got 'NEWLINE'`（用户实测"plantuml / uml 全家桶显示不正常"）——一张报错卡比看源码更没用。
 */

/** 一行是否只影响外观 / 属于预处理，翻译时应直接丢掉 */
function isPlantumlCosmetic(l: string): boolean {
  const lower: string = l.toLowerCase();
  if (lower.startsWith('skinparam') || lower.startsWith('style')
    || lower.startsWith('hide') || lower.startsWith('show')
    || lower.startsWith('remove') || lower.startsWith('legend')
    || lower.startsWith('endlegend') || lower.startsWith('caption')) {
    return true;
  }
  // !theme / !include / !$var = … / !startditaa 之类预处理指令
  return lower.startsWith('!');
}

export class PlantumlBridge {
  /** 参与者声明行的关键字 */
  private static readonly DECL_KEYS: string =
    'actor|participant|database|boundary|entity|collections|queue|control|agent|artifact';

  /**
   * 能不能桥（=是不是**纯时序图**）。判定方式是白名单 + 黑名单，而不是"看到箭头就转"：
   *  · 每一行内容都必须长得像时序图构造（声明 / 消息 / note / 激活 / 分组关键字 / 分隔线），
   *    有一行不像就整体不桥 —— 半桥的图既丢结构又丢源码，最没用；
   *  · 类图 / 用例图 / 状态图 / 组件图的块声明行（class、interface、state、component…）
   *    直接否掉，它们就算带 `-->` 也不是消息。
   * 判 false 时调用侧原样显示源码。
   */
  private static readonly SEQ_LINE: string =
    '^(' + PlantumlBridge.DECL_KEYS + '\\s+\\S'
    + '|\\S+\\s*-{1,2}>+\\S*'
    + '|\\S+\\s*\\.{1,2}>+\\S*'
    + '|note\\s+(over|left of|right of)\\b'
    + '|(activate|deactivate)\\s+\\S'
    + '|autonumber\\b|title\\s+\\S'
    + '|==.*=='
    + '|(alt|else|end|loop|opt|par|and|break|critical|group)\\b)';
  private static readonly NOT_SEQ: string =
    '^\\s*(class|interface|enum|abstract|annotation|object|usecase|actor\\s+\\w+\\s*[\\[{]'
    + '|state|component|node|artifact|database\\s+\\w+\\s*[\\[{]|folder|rectangle|queue\\s+\\w+\\s*[\\[{]'
    + '|package|frame|salt|json|yaml|mindmap|gantt|wire|board|\\[)'
    + '|\\S*\\[[^\\]]*\\]\\s*-{1,2}>';

  /**
   * 能不能桥 + 桥成哪种图：`'sequence' | 'state' | 'class' | ''`（'' = 不桥，原样显示源码）。
   *
   * 分类靠**决定性标记**，验收靠各图种自己的翻译器：**翻译失败即不桥**（每个 to*() 认不出
   * 一行就整体返回空串）。这样"判定"和"翻译"永远是同一套规则，不会出现"判能桥、翻出来是废的"
   * ——那正是上一轮状态图被塞进 sequenceDiagram 报 Parse error 的原因。
   */
  static kindOf(src: string): string {
    const head: string = src.trim().toLowerCase();
    if (!head.startsWith('@startuml') && !head.startsWith('@startsequence')) {
      return '';
    }
    if (/@startmindmap|@startsalt|@startgantt|@startjson|@startyaml/i.test(src)) {
      return '';
    }
    const lines: string[] = PlantumlBridge.contentLines(src);
    if (lines.length === 0) {
      return '';
    }
    let cls: boolean = false;
    let st: boolean = false;
    for (let k = 0; k < lines.length; k++) {
      if (PlantumlBridge.CLASS_MARK.test(lines[k])) {
        cls = true;
      }
      if (PlantumlBridge.STATE_MARK.test(lines[k])) {
        st = true;
      }
    }
    if (cls) {
      return PlantumlBridge.toClass(lines).length > 0 ? 'class' : '';
    }
    if (st) {
      return PlantumlBridge.toState(lines).length > 0 ? 'state' : '';
    }
    return PlantumlBridge.toSequence(lines).length > 0 ? 'sequence' : '';
  }

  /** 兼容旧调用：能不能桥（=kindOf 非空） */
  static bridgeable(src: string): boolean {
    return PlantumlBridge.kindOf(src).length > 0;
  }

  /** 去掉围栏标记、空行、注释与纯外观/预处理指令后的内容行 */
  private static contentLines(src: string): string[] {
    const out: string[] = [];
    const lines: string[] = src.replace(/\r\n?/g, '\n').split('\n');
    for (let k = 0; k < lines.length; k++) {
      const l: string = lines[k].replace(/\t/g, '  ').trim();
      if (l.length === 0 || l.toLowerCase() === '@startuml' || l.toLowerCase() === '@enduml'
        || l.toLowerCase() === '@startsequence' || isPlantumlCosmetic(l)
        || l.startsWith("'") || l.startsWith("/'")) {
        continue;
      }
      out.push(l);
    }
    return out;
  }

  /** 决定性标记：出现即认定是类图 / 状态图（两者都出现按类图走） */
  private static readonly CLASS_MARK: RegExp =
    /^(abstract\s+class|class|interface|enum)\s+\S|\s(<\|--|--\|>|<\|\.\.|\.\.\|>)\s/;
  private static readonly STATE_MARK: RegExp =
    /\[\*\]|^state\s+"[^"]*"\s+as\s+\S|^state\s+\S+\s*<<\w+>>|^hide\s+empty/i;

  /** PlantUML 状态图 → mermaid stateDiagram-v2；认不出一行就返回空串（整体不桥） */
  private static toState(lines: string[]): string {
    const out: string[] = ['stateDiagram-v2'];
    let sawArrow: boolean = false;
    let inNote: boolean = false;
    for (let k = 0; k < lines.length; k++) {
      const raw: string = lines[k];
      if (/^title\s/i.test(raw)) {
        continue;                          // mermaid 状态图不吃 title 语句：只丢标题，不丢整张图
      }
      if (inNote) {
        // note 块内的自由文本原样透传（mermaid 状态图支持多行 note）
        if (/^end\s*note$/i.test(raw)) {
          inNote = false;
        }
        out.push('    ' + raw);
        continue;
      }
      const noteOne: RegExpMatchArray | null =
        raw.match(/^note\s+(left|right|top|bottom)\s+of\s+(\S+)\s*:\s*(.+)$/i);
      if (noteOne !== null) {
        out.push('    note ' + noteOne[1].toLowerCase() + ' of ' + noteOne[2]);
        out.push('    ' + noteOne[3]);
        out.push('    end note');
        continue;
      }
      if (/^note\s+(left|right|top|bottom)\s+of\s+\S+$/i.test(raw)) {
        out.push('    ' + raw);
        inNote = true;
        continue;
      }
      if (/^end\s*note$/i.test(raw)) {
        out.push('    ' + raw);
        continue;
      }
      const ar: RegExpMatchArray | null =
        raw.match(/^(\S+)\s*(-->|->|\.\.>|\.>)\s*(\S+)(\s*:\s*(.+))?$/);
      if (ar !== null) {
        sawArrow = true;
        out.push('    ' + ar[1] + ' --> ' + ar[3] + (ar[5] === undefined ? '' : ' : ' + ar[5]));
        continue;
      }
      if (/^state\s+\S+\s*\{$/.test(raw) || raw === '}') {
        out.push('    ' + raw);            // 复合状态：mermaid stateDiagram-v2 同形
        continue;
      }
      if (/^state\s+".*"\s+as\s+\S+$/.test(raw) || /^state\s+\S+\s*<<\w+>>$/.test(raw)) {
        out.push('    ' + raw);            // 带描述的别名、<<choice>> / <<fork>> / <<join>>
        continue;
      }
      if (/^(\S+)\s*:\s*\S/.test(raw) && raw.indexOf('>') < 0) {
        out.push('    ' + raw);            // `状态 : 描述`
        continue;
      }
      return '';                           // 有一行不认识 → 整体不桥
    }
    if (inNote || !sawArrow) {
      return '';
    }
    return out.join('\n');
  }

  /** PlantUML 类图 → mermaid classDiagram；认不出一行就返回空串（整体不桥） */
  private static toClass(lines: string[]): string {
    const out: string[] = ['classDiagram'];
    let sawClass: boolean = false;
    let inBody: boolean = false;
    let inNote: boolean = false;
    for (let k = 0; k < lines.length; k++) {
      const raw: string = lines[k];
      if (/^title\s/i.test(raw)) {
        continue;
      }
      if (inNote) {
        if (/^end\s*note$/i.test(raw)) {
          inNote = false;
          out.push('    """');              // mermaid classDiagram 的多行注释用三引号收尾
          continue;
        }
        out.push('    ' + raw);
        continue;
      }
      if (inBody) {
        if (raw === '}') {
          inBody = false;
          out.push('    }');
          continue;
        }
        out.push('      ' + raw);          // 成员行原样透传（mermaid 按字面显示）
        continue;
      }
      // ⚠️ **`interface X { 成员 }` 与 `abstract class X { 成员 }` 在这个 mermaid 构建里是
      // 词法/语法错误**（实测：`interface I {` → "Lexical error … Unrecognized text"，
      // `abstract class B {` → "Expecting 'NEWLINE'"）。mermaid 认的是**构造型**写法，
      // 所以带体的 interface / abstract 一律降级成 `class X { <<interface>> / <<abstract>> … }`
      //（实测可渲染），成员不丢；不带体的 `interface X` 原样交给 mermaid（它画得出）。
      const hd: RegExpMatchArray | null =
        raw.match(/^(abstract\s+class|class|interface)\s+(\S+)(\s*\{)?$/i);
      if (hd !== null) {
        sawClass = true;
        const kw: string = hd[1].toLowerCase();
        const brace: boolean = hd[3] !== undefined;
        if (kw === 'class') {
          out.push('    class ' + hd[2] + (brace ? ' {' : ''));
        } else if (!brace) {
          out.push('    ' + (kw === 'interface' ? 'interface ' + hd[2]
            : 'class ' + hd[2] + ' {\n      <<abstract>>\n    }'));
          continue;
        } else {
          out.push('    class ' + hd[2] + ' {');
          out.push('      <<' + (kw === 'interface' ? 'interface' : 'abstract') + '>>');
        }
        inBody = brace;
        continue;
      }
      const en: RegExpMatchArray | null = raw.match(/^enum\s+(\S+)(\s*\{)?$/i);
      if (en !== null) {
        sawClass = true;
        out.push('    class ' + en[1] + ' {');
        out.push('      <<enumeration>>');  // mermaid 用构造型标枚举，没有 enum 关键字
        inBody = en[2] !== undefined;
        continue;
      }
      // PlantUML 的行内继承/实现（`class 子 extends 父`）→ mermaid 的关系行
      const ext: RegExpMatchArray | null =
        raw.match(/^(?:class|interface)\s+(\S+)\s+(extends|implements)\s+(\S+)$/i);
      if (ext !== null) {
        out.push('    ' + ext[3] + ' ' + (ext[2].toLowerCase() === 'implements' ? '<|..' : '<|--') + ' ' + ext[1]);
        continue;
      }
      const rel: string = PlantumlBridge.classRelOf(raw);
      if (rel.length > 0) {
        out.push('    ' + rel);
        continue;
      }
      const noteOne: RegExpMatchArray | null =
        raw.match(/^note\s+(?:left|right|top|bottom)\s+of\s+(\S+)\s*:\s*(.+)$/i);
      if (noteOne !== null) {
        out.push('    note for ' + noteOne[1] + ' "' + noteOne[2].replace(/"/g, '') + '"');
        continue;
      }
      if (/^note\s+(?:left|right|top|bottom)\s+of\s+\S+$/i.test(raw)) {
        const who: string = raw.substring(raw.lastIndexOf(' ') + 1);
        out.push('    note for ' + who + ' """');
        inNote = true;
        continue;
      }
      if (/^hide\s+circle$/i.test(raw) || /^show\s+members$/i.test(raw)) {
        continue;
      }
      return '';
    }
    if (inNote || inBody || !sawClass) {
      return '';
    }
    return out.join('\n');
  }

  /**
   * 类图关系行：mermaid 的关系符号与 PlantUML **基本同形**（`<|--`、`*--`、`o--`、`-->`、
   * `..>`、`..|>`、`<-->`、`--`、`..`），多重性写法也是同一形状
   * （`Teacher "1" --> "*" Student : 教授`），所以**原样透传**；
   * 命名框 `[A] --> [B]`、彩色箭头 `-[#red]->` 这些 PlantUML 独有的写法返回空串（宁可不桥）。
   */
  private static classRelOf(l: string): string {
    const m: RegExpMatchArray | null = l.match(
      /^(\S+)(\s+"[^"]*")?\s*(<\|--|--\|>|\*--|--\*|o--|--o|<-->|-->|<\|\.\.|\.\.\|>|\.\.>|--|\.\.)\s*("[^"]*"\s*)?(\S+)(\s*:\s*(.+))?$/);
    if (m === null) {
      return '';
    }
    const left: string = m[1];
    const right: string = m[5];
    if (left.indexOf('[') >= 0 || right.indexOf('[') >= 0
      || left.indexOf('#') >= 0 || right.indexOf('#') >= 0
      || left === 'class' || right === 'class') {
      return '';
    }
    const cardL: string = m[2] === undefined ? '' : m[2];
    const cardR: string = m[4] === undefined ? '' : m[4];
    const label: string = m[7] === undefined ? '' : ' : ' + m[7];
    return left + cardL + ' ' + m[3] + ' ' + cardR + right + label;
  }

  /** PlantUML → mermaid（按 kindOf 分流；判不桥时返回空串，调用侧原样显示源码） */
  static toMermaid(src: string): string {
    const kind: string = PlantumlBridge.kindOf(src);
    if (kind.length === 0) {
      return '';
    }
    const lines: string[] = PlantumlBridge.contentLines(src);
    if (kind === 'class') {
      return PlantumlBridge.toClass(lines);
    }
    if (kind === 'state') {
      return PlantumlBridge.toState(lines);
    }
    return PlantumlBridge.toSequence(lines);
  }

  /**
   * PlantUML 时序图 → mermaid sequenceDiagram。
   *
   * ⚠️ 先做**整体验收**再翻译：有一行不像时序图构造（或一张消息都没有）就返回空串。
   * 半桥的图既丢结构又丢源码，比不桥更糟。
   */
  private static toSequence(lines: string[]): string {
    const seqRe: RegExp = new RegExp(PlantumlBridge.SEQ_LINE, 'i');
    const notRe: RegExp = new RegExp(PlantumlBridge.NOT_SEQ, 'i');
    let sawMessage: boolean = false;
    for (let k = 0; k < lines.length; k++) {
      if (notRe.test(lines[k]) || !seqRe.test(lines[k])) {
        return '';
      }
      if (/^\S+\s*-{1,2}>+/.test(lines[k])) {
        sawMessage = true;
      }
    }
    if (!sawMessage) {
      return '';
    }
    const out: string[] = ['sequenceDiagram'];
    const aliasFrom: string[] = [];
    const aliasTo: string[] = [];
    let autoId: number = 0;
    for (let k = 0; k < lines.length; k++) {
      const raw: string = lines[k];
      const decl: RegExpMatchArray | null =
        raw.match(new RegExp('^(' + PlantumlBridge.DECL_KEYS + ')\\s+(.+)$', 'i'));
      if (decl !== null) {
        const rest: string = decl[2].trim();
        const asAt: number = rest.toLowerCase().indexOf(' as ');
        let show: string = rest;
        let id: string = rest;
        if (asAt >= 0) {
          show = rest.substring(0, asAt).trim();
          id = rest.substring(asAt + 4).trim();
        }
        const bare: string = PlantumlBridge.unquote(show);
        if (id.indexOf(' ') >= 0) {
          // id 位置写了带空格的名字：给它编一个 ASCII id，原名留作显示名
          autoId++;
          aliasFrom.push(PlantumlBridge.unquote(id));
          aliasTo.push('p' + autoId);
          id = 'p' + autoId;
        }
        if (bare !== id) {
          aliasFrom.push(bare);
          aliasTo.push(id);
        }
        // ⚠️ **参与者类型只留得住 `actor`**：实测这个 mermaid 构建（11.17.2）的时序图语法
        // 只认 `actor` 与 `participant` 两种声明，`database` / `boundary` / `control` /
        // `entity` / `collections` / `queue` 带不带 `as`、裸写、引号写法**全部 Parse error**
        // （30 个组合逐个渲染核对过）。所以 actor 翻成 actor（小人 + 淡紫底，用户要的
        // "有颜色"就在这里），其余一律退回 participant —— 以前那种"三种类型都支持"的说法
        // 是想当然，画出来是圆柱的期望会直接变成一张报错卡。
        const mk: string = decl[1].toLowerCase();
        const mermaidKw: string = mk === 'actor' ? 'actor' : 'participant';
        out.push('    ' + mermaidKw + ' ' + id + ' as ' + bare);
        continue;
      }
      if (/^autonumber\b/i.test(raw) || /^title\s/i.test(raw)) {
        out.push('    ' + raw);
        continue;
      }
      if (raw.startsWith('==') && raw.endsWith('==')) {
        // ⚠️ mermaid 时序图**没有分隔线语法**（实测 `== 登录 ==` → Parse error），
        // 降级成注释：图照画，阶段名留在源码里（能力矩阵按"⚠️ 分隔线丢弃"标注）
        out.push('    %% 分隔：' + raw.replace(/^=+|=+$/g, '').trim());
        continue;
      }
      const note: RegExpMatchArray | null =
        raw.match(/^note\s+(over|right of|left of)\s+(.+?)(?::\s*(.*))?$/i);
      if (note !== null) {
        const pos: string = note[1].toLowerCase();
        const who: string = PlantumlBridge.mapList(note[2], aliasFrom, aliasTo);
        const txt: string = note[3] === undefined ? '' : note[3];
        const key: string = pos === 'over' ? 'Note over' : (pos === 'right of' ? 'Note right of' : 'Note left of');
        out.push('    ' + key + ' ' + who + (txt.length > 0 ? ': ' + txt : ''));
        continue;
      }
      const arrow: RegExpMatchArray | null = PlantumlBridge.arrowOf(raw);
      if (arrow !== null) {
        // PlantUML 的激活简写挂在**目标**上（`A -> B++` 激活 B、`B --> A--` 停用 A），
        // 也有写法挂在箭头上（`A ->+ B`）——两种都剥出来
        let to: string = arrow[3];
        let act: string = '';
        if (to.endsWith('++')) {
          act = '\n    activate @TO@';
          to = to.substring(0, to.length - 2);
        } else if (to.endsWith('--') && to.length > 2) {
          act = '\n    deactivate @TO@';
          to = to.substring(0, to.length - 2);
        }
        const from: string = PlantumlBridge.mapName(arrow[1], aliasFrom, aliasTo);
        const mappedTo: string = PlantumlBridge.mapName(to, aliasFrom, aliasTo);
        const ar: string = arrow[2];
        const txt: string = arrow[4] === undefined ? '' : arrow[4];
        // 箭头自带的 +/-（A ->+ B）同样算激活/停用
        const body: string = ar.replace(/[+-]$/, '');
        if (act.length === 0 && ar.endsWith('+')) {
          act = '\n    activate @TO@';
        } else if (act.length === 0 && body !== ar && ar.endsWith('-')) {
          act = '\n    deactivate @TO@';
        }
        // 单横线=实线 ->>、双横线或点线=虚线 -->>（mermaid 只有这两种消息箭头）
        const mAr: string = (body.indexOf('--') >= 0 || body.charAt(0) === '.') ? '-->>' : '->>';
        if (act.length > 0) {
          act = act.replace('@TO@', mappedTo);
        }
        out.push('    ' + from + ' ' + mAr + ' ' + mappedTo
          + (txt.length > 0 ? ': ' + txt : '') + act);
        continue;
      }
      if (/^(activate|deactivate)\b/i.test(raw)) {
        const verb: string = raw.substring(0, raw.indexOf(' ')).toLowerCase();
        const who: string = raw.substring(verb.length).trim();
        out.push('    ' + verb + ' ' + PlantumlBridge.mapName(who, aliasFrom, aliasTo));
        continue;
      }
      if (/^(alt|else|end|loop|opt|par|and|break|critical|repeat)\b/i.test(raw)) {
        // PlantUML 的 `alt 条件` 与 mermaid 同形；`loop 条件` 同理
        out.push('    ' + raw);
        continue;
      }
      // 认不出来的行**降格成注释**：mermaid 会忽略 `%%` 开头的行，
      // 一行看不懂的 PlantUML 不再让整张时序图报解析错
      out.push('    %% ' + raw);
    }
    return out.join('\n');
  }

  /** 抽掉首尾成对引号 */
  private static unquote(s: string): string {
    if (s.length >= 2 && s.charAt(0) === '"' && s.charAt(s.length - 1) === '"') {
      return s.substring(1, s.length - 1);
    }
    return s;
  }

  /** `A, B` 形式的参与者列表逐个映射回 id */
  private static mapList(s: string, from: string[], to: string[]): string {
    const parts: string[] = s.split(',');
    const out: string[] = [];
    for (let k = 0; k < parts.length; k++) {
      out.push(PlantumlBridge.mapName(parts[k].trim(), from, to));
    }
    return out.join(', ');
  }

  /** 名字 → id（没登记过就原样返回） */
  private static mapName(s: string, from: string[], to: string[]): string {
    const bare: string = PlantumlBridge.unquote(s.trim());
    for (let k = 0; k < from.length; k++) {
      if (from[k] === bare) {
        return to[k];
      }
    }
    return bare;
  }

  /**
   * 箭头行：带空格（`A -> B: t`）与不带空格（`A->B: t`）两种都收；
   * 顺带识别 PlantUML 的激活简写 `A -> B++` / `A --> B--`。
   */
  private static arrowOf(line: string): RegExpMatchArray | null {
    const spaced: RegExpMatchArray | null =
      line.match(/^(\S+)\s+(-{1,2}>{1,2}[+-]?|\.{1,2}>{1,2})\s+([^:\s]+)\s*(?::\s*(.*))?$/);
    if (spaced !== null) {
      return spaced;
    }
    // 紧凑写法：两侧不留空格，冒号后消息文本可含空格
    const tight: RegExpMatchArray | null =
      line.match(/^([^\s:>-]+)(-{1,2}>{1,2}[+-]?|\.>{1,2})([^\s:>-]+)\s*(?::\s*(.*))?$/);
    return tight;
  }

  // ── 内核不支持的图种补位（2026-10-14 实测：@startmath / @starttimeline / @startfiles
  //    在 @plantuml/core 1.2026.8 里没有渲染器，只会画一张「不支持」错误卡）──

  /**
   * 取 `@startXxx … @endXxx` 之间的内容行（去掉围栏行与空行）。
   * `dropCosmetic=false` 时连 skinparam / !theme 这类外观指令一起丢掉（翻译用），
   * `true` 保留原文（公式、文件树的正文就是内容本身）。
   */
  private static blockBody(src: string, keepCosmetic: boolean): string[] {
    const out: string[] = [];
    const lines: string[] = src.replace(/\r\n?/g, '\n').split('\n');
    for (let k = 0; k < lines.length; k++) {
      const l: string = lines[k].trim();
      const low: string = l.toLowerCase();
      if (l.length === 0 || low.indexOf('@start') === 0 || low.indexOf('@end') === 0) {
        continue;
      }
      if (!keepCosmetic && isPlantumlCosmetic(l)) {
        continue;
      }
      out.push(l);
    }
    return out;
  }

  /** `@startmath` → LaTeX 源码（交给应用已有的 KaTeX 块级公式链路）；空则返回空串 */
  static mathSource(src: string): string {
    const body: string[] = PlantumlBridge.blockBody(src, true);
    if (body.length === 0) {
      return '';
    }
    // PlantUML 的 math 是「整块即一条公式」，行间拼接不会改变语义
    return body.join(' ').trim();
  }

  /**
   * PlantUML 时间线 → mermaid `timeline`。两者形状几乎一致（`时期 : 事件 : 事件…`），
   * 所以只做逐行校验 + 缩进补全；有一行不像就返回空串（整体不桥，退回代码块）。
   */
  static toMermaidTimeline(src: string): string {
    const body: string[] = PlantumlBridge.blockBody(src, false);
    if (body.length === 0) {
      return '';
    }
    const out: string[] = ['timeline'];
    let sawPeriod: boolean = false;
    for (let k = 0; k < body.length; k++) {
      const l: string = body[k];
      if (/^title\s+\S/i.test(l) || /^section\s+\S/i.test(l) || /^accolade/i.test(l)) {
        out.push('    ' + l);
        continue;
      }
      const colon: number = l.indexOf(':');
      if (colon <= 0) {
        return '';
      }
      const period: string = l.substring(0, colon).trim();
      const events: string[] = [];
      const rest: string[] = l.substring(colon + 1).split(':');
      for (let e = 0; e < rest.length; e++) {
        const e0: string = rest[e].trim();
        if (e0.length > 0) {
          events.push(e0);
        }
      }
      if (period.length === 0 || events.length === 0) {
        return '';
      }
      sawPeriod = true;
      out.push('    ' + period + ' : ' + events.join(' : '));
    }
    return sawPeriod ? out.join('\n') : '';
  }

  /**
   * PlantUML 文件树（`@startfiles`）→ **制表符树**（纯文本）。
   * 内核没有 files 渲染器，而这类内容真正的信息就是层级本身，
   * 转成 `└── / ├── / │` 后阅读与导出都是一张正常的树（代码卡片，无需 Web）。
   *
   * ⚠️ 层级两种写法都要收：`** 子节点`（星号个数 = 层级，PlantUML 脑图/WBS 风格）与
   * `* 子节点` 靠前导空格缩进（用户文档里就是这种）。所以这里读**保留空白的原始行**，
   * 不能用 blockBody（它 trim 过，缩进一丢整棵树就拍平成同级）。
   */
  static toTree(src: string): string {
    const lines: string[] = src.replace(/\r\n?/g, '\n').split('\n');
    const indents: number[] = [];
    const starLevels: number[] = [];
    const names: string[] = [];
    for (let k = 0; k < lines.length; k++) {
      const l: string = lines[k].replace(/\t/g, '  ');
      const low: string = l.trim().toLowerCase();
      if (low.length === 0 || low.indexOf('@start') === 0 || low.indexOf('@end') === 0) {
        continue;
      }
      let p: number = 0;
      while (p < l.length && l.charAt(p) === ' ') {
        p++;
      }
      let nStars: number = 0;
      while (p + nStars < l.length && l.charAt(p + nStars) === '*') {
        nStars++;
      }
      // 官方 `@startfiles` 的写法是**纯缩进**（不带 `*`）。以前这里 nStars===0 就
      // `return ''` → 按官方示例写的文件树全部退回内核，页面上是一句
      // "Unsupported diagram type"（用户实测"文件树没有渲染"）。现在两种写法都收：
      // 带 `*` 的行按星号个数定层，纯缩进的行走下面的缩进阶梯。
      let nm: string = l.substring(p + nStars).trim();
      if (nm.length === 0) {
        return '';
      }
      if (nm.length >= 2 && nm.charAt(0) === '"' && nm.charAt(nm.length - 1) === '"') {
        nm = nm.substring(1, nm.length - 1);
      }
      indents.push(p);
      starLevels.push(nStars > 0 ? nStars - 1 : -1);
      names.push(nm);
    }
    if (names.length === 0) {
      return '';
    }
    // 深度：带 `*` 的行按星号个数；纯缩进的行用"递增缩进阶梯"（任意步宽都对，退格会回退层级）
    const depths: number[] = [];
    const ladder: number[] = [];
    for (let k = 0; k < names.length; k++) {
      if (starLevels[k] >= 0) {
        depths.push(starLevels[k]);
        continue;
      }
      const r: number = indents[k];
      while (ladder.length > 0 && ladder[ladder.length - 1] > r) {
        ladder.pop();
      }
      if (ladder.length === 0 || ladder[ladder.length - 1] < r) {
        ladder.push(r);
      }
      depths.push(ladder.length - 1);
    }
    if (depths[0] !== 0) {
      return '';                           // 没有单一根节点 → 不猜
    }
    const lastAt: boolean[] = [];
    const out: string[] = [];
    for (let k = 0; k < names.length; k++) {
      const d: number = depths[k];
      if (d < 0) {
        return '';
      }
      // 本节点是不是父级的最后一个孩子 = 往后第一个「深度 ≤ 自己」的行深度是否更小
      let last: boolean = true;
      for (let j = k + 1; j < depths.length; j++) {
        if (depths[j] <= d) {
          last = depths[j] < d;
          break;
        }
      }
      if (d === 0) {
        out.push(names[k]);
      } else {
        let prefix: string = '';
        for (let lv = 1; lv < d; lv++) {
          prefix += (lv < lastAt.length && lastAt[lv]) ? '    ' : '│   ';
        }
        out.push(prefix + (last ? '└── ' : '├── ') + names[k]);
      }
      while (lastAt.length < d + 1) {
        lastAt.push(true);
      }
      lastAt[d] = last;
    }
    return out.join('\n');
  }

  /**
   * nwdiag（网络图）→ mermaid flowchart。
   *
   * PlantUML 离线内核**没有 nwdiag 渲染器**（只会画「Diagram not supported」错误卡），
   * ditaa 与 salt 同理。nwdiag 的语义其实很简单：一组「网络」各自挂若干设备
   * （设备可带 address）。用 mermaid 的**总线画法**表达最贴切也最好读：
   * 每个 network 画一个方节点（标题 + 网段），成员设备连到它；同一设备属于多个网络
   * 就连到多个网络节点 —— 结构一目了然，且完全复用已在跑的 mermaid 引擎。
   *
   * 输入形态：
   *   network dmz {
   *     address = "210.x.x.x/24"
   *     web01 [address = "210.x.x.1"];
   *     web02 [address = "210.x.x.2"];
   *   }
   * 返回空串 = 不是可识别的 nwdiag（调用侧回落代码块）。
   */
  static toMermaidNwdiag(src: string): string {
    const body: string[] = PlantumlBridge.blockBody(src, false);
    if (body.length === 0) {
      return '';
    }
    const out: string[] = ['flowchart LR'];
    // 网络节点：id → 显示标签
    const netId: string[] = [];
    const netLabel: string[] = [];
    // 设备：id → 显示名；地址按「网络序号」记录（同一设备在多个网络可有不同地址）
    const devId: string[] = [];
    const devName: string[] = [];
    const edges: string[] = [];
    let curNet: string = '';
    let curNetIdx: number = -1;
    let netAddr: string = '';

    const netIndex = (name: string): number => {
      for (let k = 0; k < netId.length; k++) {
        if (netId[k] === name) {
          return k;
        }
      }
      netId.push(name);
      netLabel.push(name);
      return netId.length - 1;
    };
    const devIndex = (name: string): number => {
      for (let k = 0; k < devId.length; k++) {
        if (devId[k] === name) {
          return k;
        }
      }
      devId.push(name);
      devName.push(name);
      return devId.length - 1;
    };

    for (let k = 0; k < body.length; k++) {
      let l: string = body[k];
      if (l.length === 0) {
        continue;
      }
      // 网络开始：`network 名字 {`（也容忍 `network {`）
      const netOpen: RegExpMatchArray | null = l.match(/^network\s*([^\s{]*)\s*\{?$/i);
      if (netOpen !== null) {
        const rawName: string = netOpen[1].length > 0 ? netOpen[1] : ('net' + (netId.length + 1));
        curNetIdx = netIndex(rawName);
        curNet = rawName;
        netAddr = '';
        continue;
      }
      // 网段地址：`address = "x.x.x.x/24"` / `description = "..."`（补进网络节点标签）
      const addrLine: RegExpMatchArray | null = l.match(/^(?:address|description)\s*=\s*"?([^"]*)"?$/i);
      if (addrLine !== null && curNetIdx >= 0) {
        const v: string = addrLine[1].trim();
        if (v.length > 0) {
          netAddr = netAddr.length === 0 ? v : (netAddr + ' / ' + v);
          netLabel[curNetIdx] = (netId[curNetIdx] + '<br/>' + netAddr);
        }
        continue;
      }
      // 闭合大括号
      if (l === '}' || l === '};') {
        curNet = '';
        curNetIdx = -1;
        continue;
      }
      // 其它 `key = value` 属性行（group / color / visible 之类）忽略
      if (/^[A-Za-z_]+\s*=/.test(l)) {
        continue;
      }
      // 设备行：`web01 [address = "…", description = "…"];` / `web01;` / `web01`
      const dev: RegExpMatchArray | null = l.match(/^([A-Za-z_][\w.-]*)\s*(?:\[(.*?)\])?\s*;?$/);
      if (dev !== null && curNetIdx >= 0) {
        const name: string = dev[1];
        const attrs: string = (dev[2] === undefined || dev[2] === null) ? '' : dev[2];
        const am: RegExpMatchArray | null = attrs.match(/address\s*=\s*"?([^",]*)"?/i);
        const addr: string = am !== null ? am[1].trim() : '';
        const di: number = devIndex(name);
        const label: string = addr.length > 0 ? (name + '<br/>' + addr) : name;
        // 同一设备在不同网络里的地址可能不同：以「网络下标」建独立节点，用同一显示名
        const nodeId: string = name + '__n' + curNetIdx;
        devName[di] = devName[di].length > 0 ? devName[di] : name;
        edges.push('    ' + nodeId + '["' + label + '"] --- ' + curNet + 'nw');
        continue;
      }
      // `group { ... }` 之类容器：跳过关键字行
      if (/^(group|network)\b/i.test(l)) {
        continue;
      }
      // 认得形状却认不出的行：保守返回空串（半桥比不桥更糟）
      return '';
    }

    if (netId.length === 0 || edges.length === 0) {
      return '';
    }
    for (let k = 0; k < netId.length; k++) {
      out.push('    ' + netId[k] + 'nw(["' + netLabel[k] + '"])');
    }
    for (let k = 0; k < edges.length; k++) {
      out.push(edges[k]);
    }
    return out.join('\n');
  }
}
