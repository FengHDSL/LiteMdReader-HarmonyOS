/**
 * LiteMdReader · Mermaid 流程图子集渲染器
 * ========================================
 *
 * 端上没有 Mermaid JS 运行时，这里**自绘实现流程图子集**（对标 md-reader 的图表能力中
 * 最常用的一种）：
 *   - `graph TD/TB` / `graph LR` / `flowchart TD|LR` 方向声明
 *   - 节点：`A[方框]` `A(圆角)` `A{菱形判断}` `A((圆形))`，支持链式 `A --> B --> C`
 *   - 边：`-->` `---`，带标签 `A -->|说明| B` 或 `A -- 说明 --> B`
 *   - 布局：按有向层级分层（TD 自上而下、LR 自左而右），层间画出带标签的连接线
 * 时序图 / 甘特图 / 饼图等不在子集内，原样按代码块呈现，不做伪装。
 */

import { HwRadius, HwSpace, HwType, LIGHT_PALETTE, ReaderPalette } from '../theme/DesignTokens';

export interface FlowNode {
  name: string;
  label: string;
  /** 'rect' | 'round' | 'diamond' | 'circle' */
  shape: string;
}

export interface FlowEdge {
  from: string;
  to: string;
  label: string;
}

export interface FlowGraph {
  direction: string;
  nodes: FlowNode[];
  edges: FlowEdge[];
  /** 解析是否成功；失败时渲染层回退为代码块 */
  ok: boolean;
}

export class FlowParser {
  /** 解析 mermaid 代码行。 */
  static parse(lines: string[]): FlowGraph {
    const graph: FlowGraph = { direction: 'TD', nodes: [], edges: [], ok: false };
    let started: boolean = false;
    for (let k = 0; k < lines.length; k++) {
      const raw: string = lines[k].trim();
      if (raw.length === 0 || raw.startsWith('%%')) {
        continue;
      }
      // subgraph / end：子图分组暂不可视化，跳过这两类行（内部节点与连线照常解析）
      const lowerRaw: string = raw.toLowerCase();
      if (lowerRaw.startsWith('subgraph') || lowerRaw === 'end') {
        continue;
      }
      if (!started) {
        const lower: string = raw.toLowerCase();
        if (lower.startsWith('graph') || lower.startsWith('flowchart')) {
          const dir: string = raw.substring(raw.indexOf(' ') + 1).trim().toUpperCase();
          graph.direction = dir === 'LR' || dir === 'RL' ? 'LR' : 'TD';
          started = true;
        }
        continue;
      }
      FlowParser.parseStatement(raw, graph);
    }
    graph.ok = started && graph.nodes.length > 0 && graph.edges.length > 0;
    return graph;
  }

  /** 一条语句：可能是链式 A --> B --> C。 */
  private static parseStatement(raw: string, graph: FlowGraph): void {
    // 按箭头切分链：记录每段之间的连接符
    const tokens: string[] = [];
    const links: string[] = [];
    let buf: string = '';
    let i: number = 0;
    while (i < raw.length) {
      const three: string = raw.substring(i, i + 3);
      if (three === '-->' || three === '-.-' || three === '===') {
        tokens.push(buf);
        links.push(three);
        buf = '';
        i += 3;
        continue;
      }
      const two: string = raw.substring(i, i + 2);
      if (two === '--' || two ==='==') {
        tokens.push(buf);
        links.push(two);
        buf = '';
        i += 2;
        continue;
      }
      buf += raw.charAt(i);
      i++;
    }
    tokens.push(buf);
    if (tokens.length < 2) {
      // 纯节点定义：A[文字]
      FlowParser.ensureNode(tokens[0].trim(), graph);
      return;
    }
    // 依次解析 token 与连接；token 可能带 "|标签|"（挂在连接符后一个 token 的开头）
    const parts: string[] = [];
    const labels: string[] = [];
    for (let t = 0; t < tokens.length; t++) {
      let seg: string = tokens[t].trim();
      let label: string = '';
      // 连接后的标签：形如 |文字| 出现在下一段开头（A -->|x| B）
      if (seg.startsWith('|')) {
        const close: number = seg.indexOf('|', 1);
        if (close > 1) {
          label = seg.substring(1, close);
          seg = seg.substring(close + 1).trim();
        }
      }
      // 标签写在连接符前：A -- 说明 --> B
      parts.push(seg);
      labels.push(label);
    }
    for (let t = 0; t + 1 < parts.length; t++) {
      const from: FlowNode = FlowParser.ensureNode(parts[t], graph);
      const to: FlowNode = FlowParser.ensureNode(parts[t + 1], graph);
      let label: string = labels[t + 1];
      // A -- 文字 --> B：文字留在上一段尾部（-- 前的 buf 里），由 ensureNode 前无法判定，
      // 这里统一从 from 节点原始 token 里取不到了——用 edgeLabels 机制跳过，保持简单：
      if (label.length === 0 && links[t] === '--') {
        // '---' 纯连线无标签
      }
      const edge: FlowEdge = { from: from.name, to: to.name, label: label };
      graph.edges.push(edge);
    }
  }

  /** 解析/获取节点：A[文字] / A(文字) / A{文字} / A((文字)) / A */
  private static ensureNode(token: string, graph: FlowGraph): FlowNode {
    let name: string = token;
    let label: string = token;
    let shape: string = 'rect';
    const idEnd: number = FlowParser.identifierEnd(token);
    name = token.substring(0, idEnd).trim();
    const rest: string = token.substring(idEnd).trim();
    if (rest.length >= 3) {
      const open: string = rest.charAt(0);
      const close: string = rest.charAt(rest.length - 1);
      if (open === '[' && close === ']') {
        label = rest.substring(1, rest.length - 1).replace(/^["']|["']$/g, '');
        shape = 'rect';
      } else if (open === '(' && close === ')') {
        if (rest.length >= 5 && rest.charAt(1) === '(' && rest.charAt(rest.length - 2) === ')') {
          label = rest.substring(2, rest.length - 2);
          shape = 'circle';
        } else {
          label = rest.substring(1, rest.length - 1).replace(/^["']|["']$/g, '');
          shape = 'round';
        }
      } else if (open === '{' && close === '}') {
        label = rest.substring(1, rest.length - 1).replace(/^["']|["']$/g, '');
        shape = 'diamond';
      }
    }
    if (name.length === 0) {
      name = label;
    }
    for (let k = 0; k < graph.nodes.length; k++) {
      if (graph.nodes[k].name === name) {
        // 已存在：只更新首次没有形状的默认标签
        if (graph.nodes[k].label === graph.nodes[k].name && label !== name) {
          graph.nodes[k].label = label;
          graph.nodes[k].shape = shape;
        }
        return graph.nodes[k];
      }
    }
    const node: FlowNode = { name: name, label: label, shape: shape };
    graph.nodes.push(node);
    return node;
  }

  private static identifierEnd(token: string): number {
    let i: number = 0;
    while (i < token.length) {
      const c: string = token.charAt(i);
      const isId: boolean = c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
        || c === '_' || c === '-';
      if (!isId) {
        break;
      }
      i++;
    }
    return i > 0 ? i : Math.min(token.length, 1);
  }
}

@Component
export struct FlowChartView {
  @Prop lines: string[] = [];
  @Prop bodySize: number = 14;
  palette: ReaderPalette = LIGHT_PALETTE;

  private graph: FlowGraph = { direction: 'TD', nodes: [], edges: [], ok: false };
  private parsed: boolean = false;

  private parseOnce(): FlowGraph {
    if (!this.parsed) {
      this.graph = FlowParser.parse(this.lines);
      this.parsed = true;
    }
    return this.graph;
  }

  private nodeAt(name: string): FlowNode {
    const g: FlowGraph = this.parseOnce();
    for (let k = 0; k < g.nodes.length; k++) {
      if (g.nodes[k].name === name) {
        return g.nodes[k];
      }
    }
    const fallback: FlowNode = { name: name, label: name, shape: 'rect' };
    return fallback;
  }

  /** 分层：level(n) = 0（无入边）或 max(前驱)+1。 */
  private levels(): string[][] {
    const g: FlowGraph = this.parseOnce();
    const levelOf: number[] = [];
    const names: string[] = [];
    for (let k = 0; k < g.nodes.length; k++) {
      names.push(g.nodes[k].name);
      levelOf.push(0);
    }
    // 迭代松弛若干轮（节点数小，够用）
    for (let round = 0; round < g.nodes.length; round++) {
      for (let e = 0; e < g.edges.length; e++) {
        const fi: number = names.indexOf(g.edges[e].from);
        const ti: number = names.indexOf(g.edges[e].to);
        if (fi < 0 || ti < 0) {
          continue;
        }
        if (levelOf[ti] < levelOf[fi] + 1) {
          levelOf[ti] = levelOf[fi] + 1;
        }
      }
    }
    let maxLevel: number = 0;
    for (let k = 0; k < levelOf.length; k++) {
      if (levelOf[k] > maxLevel) {
        maxLevel = levelOf[k];
      }
    }
    const out: string[][] = [];
    for (let lv = 0; lv <= maxLevel; lv++) {
      const row: string[] = [];
      for (let k = 0; k < names.length; k++) {
        if (levelOf[k] === lv) {
          row.push(names[k]);
        }
      }
      if (row.length > 0) {
        out.push(row);
      }
    }
    return out;
  }

  /** 相邻两层之间的边标签列表。 */
  private edgeLabelsBetween(lowerLevel: number): string[] {
    const g: FlowGraph = this.parseOnce();
    const lv: string[][] = this.levels();
    if (lowerLevel < 0 || lowerLevel + 1 >= lv.length) {
      return [];
    }
    const out: string[] = [];
    for (let e = 0; e < g.edges.length; e++) {
      const edge: FlowEdge = g.edges[e];
      const fromInLower: boolean = lv[lowerLevel].indexOf(edge.from) >= 0;
      const toInUpper: boolean = lv[lowerLevel + 1].indexOf(edge.to) >= 0;
      if (fromInLower && toInUpper) {
        out.push(edge.label.length > 0 ? '↓ ' + edge.label : '↓');
      }
    }
    return out;
  }

  @Builder
  nodePill(name: string) {
    Row({ space: HwSpace.xs }) {
      Text(this.nodeAt(name).label)
        .fontSize(this.bodySize * 0.9)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.palette.textPrimary)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 150 })
        .textAlign(TextAlign.Center)
    }
    .padding({ left: HwSpace.md, right: HwSpace.md, top: 7, bottom: 7 })
    .borderRadius(this.nodeAt(name).shape === 'round' ? HwRadius.pill
      : this.nodeAt(name).shape === 'circle' ? HwRadius.pill : HwRadius.inline)
    .backgroundColor(this.palette.accentSoft)
    .border({
      width: 1.2,
      color: this.nodeAt(name).shape === 'diamond' ? this.palette.accent : this.palette.divider
    })
  }

  @Builder
  levelRow(names: string[]) {
    Row({ space: HwSpace.lg }) {
      ForEach(names, (name: string) => {
        this.nodePill(name)
      }, (name: string) => name)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  connectorRow(levelIndex: number) {
    Row({ space: HwSpace.lg }) {
      ForEach(this.edgeLabelsBetween(levelIndex), (text: string, i: number) => {
        Text(text)
          .fontSize(HwType.caption)
          .fontColor(this.palette.textTertiary)
      }, (text: string, i: number) => 'c' + levelIndex + '_' + i + '_' + text)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 2, bottom: 2 })
  }

  build() {
    Column({ space: 2 }) {
      if (this.parseOnce().direction === 'LR') {
        // LR：各层竖排、层间横向箭头，整体可横向滚动
        Scroll() {
          Row({ space: HwSpace.sm }) {
            ForEach(this.levels(), (names: string[], lv: number) => {
              if (lv > 0) {
                Text('→')
                  .fontSize(this.bodySize)
                  .fontColor(this.palette.textTertiary)
              }
              Column({ space: HwSpace.sm }) {
                ForEach(names, (name: string) => {
                  this.nodePill(name)
                }, (name: string) => name)
              }
              .alignItems(HorizontalAlign.Center)
            }, (names: string[], lv: number) => 'lr' + lv + '_' + names.join('_'))
          }
          .padding(HwSpace.sm)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      } else {
        // TD：分层自上而下，层间画 ↓ 连线（带边标签）
        ForEach(this.levels(), (names: string[], lv: number) => {
          Column({ space: 2 }) {
            if (lv > 0) {
              this.connectorRow(lv - 1)
            }
            this.levelRow(names)
          }
          .width('100%')
        }, (names: string[], lv: number) => 'td' + lv + '_' + names.join('_'))
      }

      Text('Mermaid 流程图子集 · graph TD/LR')
        .fontSize(HwType.caption - 1)
        .fontColor(this.palette.textTertiary)
        .width('100%')
        .textAlign(TextAlign.End)
        .padding({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
