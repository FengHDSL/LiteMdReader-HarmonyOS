/**
 * 澄笺 · PlantUML → Mermaid 语法桥
 * ================================
 *
 * PlantUML 核心是 Java（渲染要 plantuml.jar 或官方服务器），离线内嵌不现实；
 * 但它的**时序图**语法与 mermaid sequenceDiagram 高度同构。这里把常见片段翻译成
 * mermaid，交给既有 mermaid 引擎渲染：
 *   · actor / participant / database / boundary / entity / collections / queue
 *       → participant（mermaid 不区分参与者图形，够用）
 *   · A -> B : 文本 / A --> B : 文本 / 紧凑写法 A->B: 文本
 *       → A->>B: / A-->>B:（单横线实线、双横线虚线）
 *   · note over A / note right of A / note over A, B → Note ...
 *   · activate A / deactivate A / autonumber / title / == 分隔 == / alt-else-end
 *     / loop / opt / par-and / break / critical → 同名关键字直接透传
 *   · skinparam、!theme、!$变量、hide/show/style 这些**纯外观与预处理指令直接丢弃**
 *     （透传给 mermaid 会让整张图报解析错，一颗老鼠屎坏一锅汤）
 *   · 认不出来的行降格成 mermaid 注释（`%% …`），信息留着但不参与语法
 *
 * ⚠️ **只覆盖时序图**。类图 / 用例图 / 活动图 / 组件图语法差异过大，`bridgeable()`
 * 会判 false，调用侧据此**回落成普通代码块显示源码**（以前 bridgeable 没被任何地方调用，
 * 类图也被硬转成 sequenceDiagram，用户看到的是一张 mermaid 报错卡 —— 比看源码更没用）。
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
    + '|package|frame|salt|json|yaml|mindmap|gantt|wire|board)\\b';

  static bridgeable(src: string): boolean {
    const head: string = src.trim().toLowerCase();
    if (!head.startsWith('@startuml') && !head.startsWith('@startsequence')) {
      return false;
    }
    if (/@startmindmap|@startsalt|@startgantt|@startjson|@startyaml/i.test(src)) {
      return false;
    }
    const seqRe: RegExp = new RegExp(PlantumlBridge.SEQ_LINE, 'i');
    const notRe: RegExp = new RegExp(PlantumlBridge.NOT_SEQ, 'i');
    let sawMessage: boolean = false;
    const lines: string[] = src.replace(/\r\n?/g, '\n').split('\n');
    for (let k = 0; k < lines.length; k++) {
      const l: string = lines[k].trim();
      if (l.length === 0 || l.toLowerCase() === '@startuml' || l.toLowerCase() === '@enduml'
        || isPlantumlCosmetic(l) || l.startsWith("'") || l.startsWith("/'")) {
        continue;                          // 空行、围栏、外观指令、注释：不参与判定
      }
      if (notRe.test(l)) {
        return false;
      }
      if (!seqRe.test(l)) {
        return false;                      // 有一行不像时序图构造 → 整体不桥
      }
      if (new RegExp('^\\S+\\s*-{1,2}>+').test(l)) {
        sawMessage = true;
      }
    }
    return sawMessage;
  }

  /** PlantUML → mermaid sequenceDiagram */
  static toMermaid(src: string): string {
    const out: string[] = ['sequenceDiagram'];
    const lines: string[] = src.replace(/\r\n?/g, '\n').split('\n');
    // 显示名 → id（参与者名字里有空格/引号时，箭头里写的是名字，得能换回 id）
    const aliasFrom: string[] = [];
    const aliasTo: string[] = [];
    let autoId: number = 0;
    for (let k = 0; k < lines.length; k++) {
      const raw: string = lines[k].replace(/\t/g, '  ').trim();
      if (raw.length === 0 || raw.toLowerCase() === '@startuml'
        || raw.toLowerCase() === '@enduml' || raw.startsWith("/'")
        || (raw.startsWith("'") && !raw.startsWith("''"))) {
        continue;                          // 空行、围栏标记、PlantUML 单行注释
      }
      if (isPlantumlCosmetic(raw)) {
        continue;                          // 纯外观 / 预处理指令：丢掉
      }
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
        out.push('    participant ' + id + ' as ' + bare);
        continue;
      }
      if (/^autonumber\b/i.test(raw) || /^title\s/i.test(raw)) {
        out.push('    ' + raw);
        continue;
      }
      if (raw.startsWith('==') && raw.endsWith('==')) {
        out.push('    ' + raw);
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
}
