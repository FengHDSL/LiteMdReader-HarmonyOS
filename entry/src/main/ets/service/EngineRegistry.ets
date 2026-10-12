import { L10n } from './L10n';
/**
 * 澄笺 · 渲染引擎注册表（引擎管理数据源 + 开关判定）
 * ======================================================
 *
 * 「设置 → 引擎管理」的展示数据来源，同时是应用内各渲染点"引擎是否已关闭"
 * 的**唯一判定入口**（阅读页 / AI 气泡 / 编辑器预览的图表与公式、导出、
 * 预渲染任务收集、编辑器 WYSIWYG 入口）。
 *
 * 开关状态存 AppStorage：`disabledEngines`（逗号分隔的引擎 id，空串 = 全部开启）。
 *   · UI 路径用 `@StorageProp('disabledEngines')` 订阅（响应式重渲染）；
 *   · 非 UI 路径（导出 / 任务收集）用 `EngineRegistry.current()` 静态读取；
 *   · 判定统一走纯函数 `isOff(id, list)`，避免多处各自解析。
 *
 * 版本 / 发布日期 / 仓库地址对应 2026-10-10 的全量引擎升级基线（见 MEMORY.md），
 * 升级引擎时三处同步：此处元数据 + 模板库文件 + 版本号。
 */

/** 单个渲染引擎的展示信息 */
export interface EngineInfo {
  /** 稳定 id：参与 disabledEngines 串与各渲染点判定 */
  id: string;
  /** 引擎名 */
  name: string;
  /** 当前使用版本 */
  version: string;
  /** 该版本发布日期（yyyy-mm-dd，取自 npm registry） */
  date: string;
  /** 开源仓库地址 */
  repo: string;
  /** 作用介绍（一句话） */
  desc: string;
}

/** 引擎清单（顺序即设置页展示顺序：公式 → 图表 → 编辑器） */
export const ENGINE_LIST: EngineInfo[] = [
  {
    id: 'katex', name: 'KaTeX', version: '0.19.0', date: '2026-10-01',
    repo: 'https://github.com/KaTeX/KaTeX',
    desc: '块级数学公式渲染（阅读 / 导出 HTML / 打印）'
  },
  {
    id: 'mathjax', name: 'MathJax', version: '3.2.2', date: '2022-06-08',
    repo: 'https://github.com/mathjax/MathJax',
    desc: L10n.t('行内公式排版为矢量图（正文内联显示；v4 需专项离线适配，暂缓升级）')
  },
  {
    id: 'mermaid', name: 'Mermaid', version: '10.9.3', date: '2024-10-22',
    repo: 'https://github.com/mermaid-js/mermaid',
    desc: '流程图 / 时序图 / 甘特图 / 类图 / 状态图 / 饼图（12.x 应用内渲染异常，已回退 10.x 终版）'
  },
  {
    id: 'markmap', name: 'markmap', version: '0.18.12', date: '2025-06-12',
    repo: 'https://github.com/markmap/markmap',
    desc: L10n.t('Markdown 思维导图（脑图，可缩放可折叠）')
  },
  {
    id: 'echarts', name: 'Apache ECharts', version: '6.1.0', date: '2026-05-19',
    repo: 'https://github.com/apache/echarts',
    desc: '数据图表（柱状 / 折线 / 饼图等，JSON 配置）'
  },
  {
    id: 'abc', name: 'abcjs', version: '6.7.1', date: '2026-09-21',
    repo: 'https://github.com/paulrosen/abcjs',
    desc: L10n.t('ABC 记谱法乐谱（五线谱，可播放）')
  },
  {
    id: 'graphviz', name: 'Viz.js (Graphviz)', version: '3.31.0', date: '2026-09-28',
    repo: 'https://github.com/mdaines/viz-js',
    desc: L10n.t('Graphviz DOT 关系图（内嵌 Graphviz 16.1.0）')
  },
  {
    id: 'flowchart', name: 'flowchart.js', version: '1.17.1', date: '2022-02-02',
    repo: 'https://github.com/adrai/flowchart.js',
    desc: L10n.t('经典 flowchart 语法流程图（基于 Raphael）')
  },
  {
    id: 'wavedrom', name: 'WaveDrom', version: '3.7.0', date: '2026-08-31',
    repo: 'https://github.com/wavedrom/wavedrom',
    desc: '数字波形图（WaveJSON 时序 / 逻辑门 / 寄存器位段），深浅主题统一浅色波形面板'
  },
  {
    id: 'marked', name: 'marked', version: '18.1.0', date: '2026-10-05',
    repo: 'https://github.com/markedjs/marked',
    desc: '编辑器「所见即所得 / 即时渲染」的 Markdown 解析'
  },
  {
    id: 'turndown', name: 'turndown', version: '7.2.4', date: '2026-04-03',
    repo: 'https://github.com/mixmark-io/turndown',
    desc: L10n.t('编辑器 HTML → Markdown 序列化（保存实时同步）')
  }
];

export class EngineRegistry {
  /** AppStorage 键 */
  static readonly KEY: string = 'disabledEngines';
  /** 默认值（空串 = 全部开启） */
  static readonly DEFAULT: string = '';

  /** 静态读取当前关闭列表（导出 / 任务收集等非 UI 路径用） */
  static current(): string {
    const v: string | undefined = AppStorage.get<string>(EngineRegistry.KEY);
    return v === undefined ? '' : v;
  }

  /** 某引擎是否已关闭（list 传订阅值或 current()；空串恒 false）。 */
  static isOff(id: string, list: string): boolean {
    if (list.length === 0) {
      return false;
    }
    return (',' + list + ',').indexOf(',' + id + ',') >= 0;
  }

  /** 计算切换后的新值（纯函数，便于动画包裹与测试）。 */
  static withToggled(list: string, id: string, off: boolean): string {
    const ids: string[] = list.length === 0 ? [] : list.split(',');
    const out: string[] = [];
    for (let k: number = 0; k < ids.length; k++) {
      const it: string = ids[k].trim();
      if (it.length > 0 && it !== id) {
        out.push(it);
      }
    }
    if (off) {
      out.push(id);
    }
    return out.join(',');
  }

  /**
   * 图表块语言 → 引擎 id（渲染点统一用它查开关；语义见 ENGINE_LIST.desc）。
   * `html` / 未登记语言返回空串（不依赖任何第三方引擎，`html` 是原生 WebView 预览）。
   *
   * ⚠️ `katex` 语言的分支在导出侧是**块级公式**容器；在阅读侧 `katex` 从不出现在
   * Chart 块（公式块是 MdBlockKind.Math），这里仍映射到 katex 以便调用方统一处理。
   */
  static langId(lang: string): string {
    const l: string = lang.trim().toLowerCase();
    if (l === 'katex') {
      return 'katex';
    }
    if (l === 'mermaid') {
      return 'mermaid';
    }
    if (l === 'markmap') {
      return 'markmap';
    }
    if (l === 'echarts') {
      return 'echarts';
    }
    if (l === 'abc') {
      return 'abc';
    }
    if (l === 'graphviz') {
      return 'graphviz';
    }
    if (l === 'flowchart') {
      return 'flowchart';
    }
    if (l === 'wavedrom') {
      return 'wavedrom';
    }
    return '';
  }

  /** 语言是否已关闭（非 UI 路径用；空 id 恒 false）。 */
  static isLangOff(lang: string): boolean {
    return EngineRegistry.isOff(EngineRegistry.langId(lang), EngineRegistry.current());
  }

  /** 引擎 id → 展示名（引擎页 / 源码兜底卡提示用；未登记返回 id 本身）。 */
  static nameOf(id: string): string {
    for (let k: number = 0; k < ENGINE_LIST.length; k++) {
      if (ENGINE_LIST[k].id === id) {
        return ENGINE_LIST[k].name;
      }
    }
    return id;
  }

  /** 关闭列表里的引擎个数（引擎页「全部启用」按钮的显隐与文案）。 */
  static countOff(list: string): number {
    if (list.length === 0) {
      return 0;
    }
    const ids: string[] = list.split(',');
    let n: number = 0;
    for (let k: number = 0; k < ids.length; k++) {
      if (ids[k].trim().length > 0) {
        n++;
      }
    }
    return n;
  }
}
