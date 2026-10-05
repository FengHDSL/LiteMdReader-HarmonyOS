/**
 * 知识图谱（KnowledgeGraph）—— 把散落各篇的 `[[文档链接]]` 汇总成一张关系图。
 *
 * 定位：澄笺的差异化功能。文档之间的引用关系本来只存在于正文里，看不见整体形状；
 * 这里把它抽成**有向图**，并生成 mermaid 源码 —— 直接用工程已有的 mermaid 渲染
 * 通道展示，不引入任何新依赖。
 *
 * 实现约束：
 * 1. 只认 `[[名称]]` 与 `[[名称|别名]]` 两种写法（与阅读页的文档链接一致）；
 * 2. 自引用（`[[自己]]`）不算边，避免图谱上出现自环噪声；
 * 3. 指向不存在文档的链接**单独统计**（"待补文档"），这本身是有用的信息 ——
 *    等于一份"计划要写但还没写"的清单；
 * 4. mermaid 的节点 id 用 `n0/n1/...`（名称可能含空格、括号、中文标点，直接当 id 会
 *    让 mermaid 解析失败），中文名放在 `["标签"]` 里。
 */
import { common } from '@kit.AbilityKit';
import { DocStore, DocMeta } from './DocStore';

/** 一条引用关系（from → to） */
export interface GraphEdge {
  from: string;
  to: string;
}

/** 图谱数据 */
export interface GraphResult {
  /** 节点（文档名），按名称排序 */
  nodes: string[];
  /** 有向边 */
  edges: GraphEdge[];
  /** 被链接但尚不存在的文档名（"待补"清单） */
  missing: string[];
  /** 没有任何连线的孤立文档 */
  isolated: string[];
  /** 扫描过的文档数 */
  scanned: number;
}

/** 文档链接：[[名称]] 或 [[名称|别名]] */
const WIKI_RE: RegExp = /\[\[([^\]|]+)(?:\|[^\]]*)?\]\]/g;
/** 单文件跳过阈值（512KB） */
const MAX_FILE_CHARS: number = 512 * 1024;

export class KnowledgeGraph {
  /** 扫描全部文档，构建引用关系图。 */
  static build(ctx: common.UIAbilityContext): GraphResult {
    DocStore.init(ctx);
    const list: DocMeta[] = DocStore.list(ctx);
    const nameOf: string[] = [];
    const edges: GraphEdge[] = [];
    const missingSet: string[] = [];

    // 先收集全部文档名（用文件名做标识，与阅读页链接的解析口径一致）
    for (let k = 0; k < list.length; k++) {
      nameOf.push(list[k].name);
    }

    for (let k = 0; k < list.length; k++) {
      const meta: DocMeta = list[k];
      let content: string = '';
      try {
        content = DocStore.readText(ctx, meta);
      } catch (err) {
        continue;
      }
      if (content.length > MAX_FILE_CHARS) {
        continue;
      }
      WIKI_RE.lastIndex = 0;
      let m: RegExpExecArray | null = WIKI_RE.exec(content);
      while (m !== null) {
        const target: string = m[1].trim();
        if (target.length > 0 && target !== meta.name) {
          let exists: boolean = false;
          for (let j = 0; j < nameOf.length; j++) {
            if (nameOf[j] === target) {
              exists = true;
              break;
            }
          }
          if (exists) {
            // 去重：同一对关系只记一次
            let dup: boolean = false;
            for (let e = 0; e < edges.length; e++) {
              if (edges[e].from === meta.name && edges[e].to === target) {
                dup = true;
                break;
              }
            }
            if (!dup) {
              edges.push({ from: meta.name, to: target } as GraphEdge);
            }
          } else {
            let has: boolean = false;
            for (let j = 0; j < missingSet.length; j++) {
              if (missingSet[j] === target) {
                has = true;
                break;
              }
            }
            if (!has) {
              missingSet.push(target);
            }
          }
        }
        m = WIKI_RE.exec(content);
      }
    }

    // 参与连线的节点
    const linked: string[] = [];
    for (let e = 0; e < edges.length; e++) {
      if (linked.indexOf(edges[e].from) < 0) {
        linked.push(edges[e].from);
      }
      if (linked.indexOf(edges[e].to) < 0) {
        linked.push(edges[e].to);
      }
    }
    // 孤立文档（在书架里但没有任何连线）
    const isolated: string[] = [];
    for (let k = 0; k < nameOf.length; k++) {
      if (linked.indexOf(nameOf[k]) < 0) {
        isolated.push(nameOf[k]);
      }
    }

    const nodes: string[] = linked.slice();
    nodes.sort();
    isolated.sort();
    missingSet.sort();
    return {
      nodes: nodes, edges: edges, missing: missingSet,
      isolated: isolated, scanned: list.length
    } as GraphResult;
  }

  /**
   * 生成 mermaid `graph LR` 源码（左右布局更适合中文长标题）。
   * @param r 图谱数据
   * @param maxEdges 最多输出的边数（超出的截断，避免大书架生成上千行）
   */
  static toMermaid(r: GraphResult, maxEdges: number = 60): string {
    if (r.nodes.length === 0) {
      return 'graph LR\n  empty["还没有文档之间的 [[链接]]"]';
    }
    // 名称 → 节点 id
    const ids: string[] = [];
    const idOf: string[] = [];
    for (let k = 0; k < r.nodes.length; k++) {
      ids.push('n' + k);
      idOf.push(r.nodes[k]);
    }
    let out: string = 'graph LR\n';
    // 先声明节点（带中文标签），无连线的节点也会被画出来
    for (let k = 0; k < r.nodes.length; k++) {
      out += '  ' + ids[k] + '["' + KnowledgeGraph.escapeLabel(r.nodes[k]) + '"]\n';
    }
    const n: number = Math.min(maxEdges, r.edges.length);
    for (let e = 0; e < n; e++) {
      const from: string = KnowledgeGraph.idOf(r.nodes, r.edges[e].from);
      const to: string = KnowledgeGraph.idOf(r.nodes, r.edges[e].to);
      if (from.length > 0 && to.length > 0) {
        out += '  ' + from + ' --> ' + to + '\n';
      }
    }
    if (r.edges.length > n) {
      // ⚠️ mermaid 的注释是 `%%`，用 `//` 会被当成语法内容而解析失败
      out += '  %% 另有 ' + (r.edges.length - n) + ' 条引用未画出\n';
    }
    return out;
  }

  private static idOf(nodes: string[], name: string): string {
    for (let k = 0; k < nodes.length; k++) {
      if (nodes[k] === name) {
        return 'n' + k;
      }
    }
    return '';
  }

  /** mermaid 标签里的引号与方括号会破坏语法，统一替换为全角。 */
  private static escapeLabel(s: string): string {
    return s.replace(/"/g, '＂').replace(/\[/g, '（').replace(/\]/g, '）')
      .replace(/\n/g, ' ');
  }

  /** 一句话摘要。 */
  static summary(r: GraphResult): string {
    return r.nodes.length + ' 个节点 · ' + r.edges.length + ' 条引用'
      + (r.missing.length > 0 ? ' · ' + r.missing.length + ' 个待补' : '');
  }
}
