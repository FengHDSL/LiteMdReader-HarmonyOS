/**
 * 澄笺 · PlantUML → Mermaid 语法桥
 * ================================
 *
 * PlantUML 核心是 Java，无法离线内嵌；但其**时序图**语法与 mermaid sequenceDiagram
 * 高度同构。这里把最常用的 PlantUML 片段翻译成 mermaid，交给既有 mermaid 引擎渲染：
 *   · actor/participant/database  → participant
 *   · autonumber / title          → 原样保留
 *   · A -> B : 文本               → A->>B: 文本
 *   · A --> B : 文本              → A-->>B: 文本
 *   · == 分隔 ==                  → == 分隔 ==
 *   · note over/right of/left of  → Note over / Note right of / Note left of
 *   · alt/else/end、loop/end      → alt/else/end、loop/end
 * 其余（类图 / 用例图 / 活动图）语法差异过大，不转换 —— 由调用侧决定是否回落源码显示。
 */

export class PlantumlBridge {
  /** 是否为可桥接的 PlantUML（时序图为主） */
  static bridgeable(src: string): boolean {
    const head: string = src.trim().toLowerCase();
    if (head.startsWith('@startuml')) {
      return /@(startuml)|participant |actor |->|-->|note /.test(src);
    }
    return false;
  }

  /** PlantUML → mermaid sequenceDiagram */
  static toMermaid(src: string): string {
    const out: string[] = ['sequenceDiagram'];
    const lines: string[] = src.replace(/\r\n?/g, '\n').split('\n');
    for (let k = 0; k < lines.length; k++) {
      let l: string = lines[k].replace(/\t/g, '  ').trim();
      if (l.length === 0 || l.toLowerCase() === '@startuml' || l.toLowerCase() === '@enduml') {
        continue;
      }
      // 声明：actor Xxx as 别名 / participant "显示名" as ID / database X as Y
      const decl: RegExpMatchArray | null = l.match(/^(actor|participant|database|boundary|entity|collections)\s+(.+)$/i);
      if (decl !== null) {
        const kind: string = decl[1];
        const rest: string = decl[2];
        const asAt: number = rest.toLowerCase().indexOf(' as ');
        let show: string = rest;
        let id: string = rest;
        if (asAt >= 0) {
          show = rest.substring(0, asAt).trim();
          id = rest.substring(asAt + 4).trim();
        } else {
          id = rest;
        }
        // 参与者统一用 participant + as 显示名（mermaid 不区分 actor 图形，够用）
        out.push('    participant ' + id + ' as ' + show);
        continue;
      }
      // autonumber / title 原样
      if (/^autonumber\b/i.test(l) || /^title\s/.test(l)) {
        out.push('    ' + l);
        continue;
      }
      // == 分隔 ==
      if (l.startsWith('==') && l.endsWith('==')) {
        out.push('    ' + l);
        continue;
      }
      // note over/right of/left of X : 文本
      const note: RegExpMatchArray | null = l.match(/^note\s+(over|right of|left of)\s+([^\s:]+)\s*(?::\s*(.*))?$/i);
      if (note !== null) {
        const pos: string = note[1].toLowerCase();
        const who: string = note[2];
        const txt: string = note[3] === undefined || note[3] === null ? '' : note[3];
        if (pos === 'over') {
          out.push('    Note over ' + who + ': ' + txt);
        } else if (pos === 'right of') {
          out.push('    Note right of ' + who + ': ' + txt);
        } else {
          out.push('    Note left of ' + who + ': ' + txt);
        }
        continue;
      }
      // 箭头：A -> B : t / A --> B : t / A ->> B / A -->> B
      const arrow: RegExpMatchArray | null = l.match(/^([^\s]+)\s+(-{1,2}>{1,2})\s+([^\s:]+)\s*(?::\s*(.*))?$/);
      if (arrow !== null) {
        const from: string = arrow[1];
        const ar: string = arrow[2];
        const to: string = arrow[3];
        const txt: string = arrow[4] === undefined || arrow[4] === null ? '' : arrow[4];
        // -> / --> / ->> / -->> 统一映射：双横线为虚线，单横线为实线
        const mAr: string = ar.indexOf('--') >= 0 ? '-->>' : '->>';
        out.push('    ' + from + ' ' + mAr + ' ' + to + (txt.length > 0 ? ': ' + txt : ''));
        continue;
      }
      // alt/else/end/loop/opt/par 原样（mermaid 同名关键字）
      if (/^(alt|else|end|loop|opt|par|and)\b/i.test(l)) {
        out.push('    ' + l);
        continue;
      }
      // 其余行原样带过（容错）
      out.push('    ' + l);
    }
    return out.join('\n');
  }
}
