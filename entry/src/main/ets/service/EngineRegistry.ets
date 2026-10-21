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
  /**
   * 离线库体积：**这一引擎在安装包里的实际总占用**（阅读侧内联模板 + 导出侧 runtimes 拷贝
   * 与依赖，全部相加）。⚠️ 以前这一格只量了模板那份，导出用的第二份拷贝没算进去，
   * 于是"引擎管理"里看着 3.42MB 的 mermaid 实际占 6.82MB——用户按这一格判断体积会被误导。
   * 数值由 `node tools/audit-engines.js` 从 rawfile 真实字节算出，改库要同步跑它。
   */
  size: string;
}

/** 引擎清单（顺序即设置页展示顺序：公式 → 图表 → 编辑器） */
export const ENGINE_LIST: EngineInfo[] = [
  {
    id: 'katex', name: 'KaTeX', version: '0.19.0', date: '2026-10-01',
    repo: 'https://github.com/KaTeX/KaTeX',
    desc: '块级数学公式渲染（阅读 / 导出 HTML / 打印）',
    size: '0.64 MB',
  },
  {
    id: 'mathjax', name: 'MathJax', version: '3.2.2', date: '2022-06-08',
    repo: 'https://github.com/mathjax/MathJax',
    desc: L10n.t('行内公式排版为矢量图（正文内联显示；v4 需专项离线适配，暂缓升级）'),
    size: '2.17 MB'
  },
  {
    id: 'mermaid', name: 'Mermaid', version: '11.17.2', date: '2026-10-13',
    repo: 'https://github.com/mermaid-js/mermaid',
    desc: '流程图 / 时序图 / 甘特图 / 类图 / 状态图 / 饼图（12.x 应用内渲染异常，已回退 10.x 终版）',
    size: '6.82 MB',
  },
  {
    // **已弃用的插件**：@mermaid-js/mermaid-zenuml 与随包 mermaid 11.17.2 内部约定错位，
    // 真机 parse 必抛错（画成 Syntax error）。现改为 ZenumlBridge 纯文本转译成 mermaid
    // 时序图；6.56MB 的 zenuml.html 与 3.14MB 插件已从包内删除，故体积记 0。
    id: 'zenuml', name: 'ZenUML（已弃用，改纯文本转译）', version: '—', date: '2026-10-14',
    repo: 'https://github.com/mermaid-js/mermaid/tree/main/packages/mermaid-zenuml',
    desc: L10n.t('不再随包：真机改用纯文本转译（见 ZenumlBridge），输出 mermaid 时序图'),
    size: '0 MB',
  },
  {
    id: 'markmap', name: 'markmap', version: '0.18.12', date: '2025-06-12',
    repo: 'https://github.com/markmap/markmap',
    desc: L10n.t('Markdown 思维导图（脑图，可缩放可折叠）'),
    size: '1.28 MB',
  },
  {
    id: 'echarts', name: 'Apache ECharts', version: '6.1.0', date: '2026-05-19',
    repo: 'https://github.com/apache/echarts',
    desc: '数据图表（柱状 / 折线 / 饼图等，JSON 配置）',
    size: '2.15 MB',
  },
  {
    id: 'abc', name: 'abcjs', version: '6.7.1', date: '2026-09-21',
    repo: 'https://github.com/paulrosen/abcjs',
    desc: L10n.t('ABC 记谱法乐谱（五线谱，可播放）'),
    size: '0.98 MB',
  },
  {
    id: 'graphviz', name: 'Viz.js (Graphviz)', version: '3.31.0', date: '2026-09-28',
    repo: 'https://github.com/mdaines/viz-js',
    desc: L10n.t('Graphviz DOT 关系图（内嵌 Graphviz 16.1.0）'),
    size: '2.54 MB',
  },
  {
    id: 'flowchart', name: 'flowchart.js', version: '1.17.1', date: '2022-02-02',
    repo: 'https://github.com/adrai/flowchart.js',
    desc: L10n.t('经典 flowchart 语法流程图（基于 Raphael）'),
    size: '0.13 MB',
  },
  {
    id: 'wavedrom', name: 'WaveDrom', version: '3.7.0', date: '2026-08-31',
    repo: 'https://github.com/wavedrom/wavedrom',
    desc: '数字波形图（WaveJSON 时序 / 逻辑门 / 寄存器位段），深浅主题统一浅色波形面板',
    size: '0.16 MB',
  },
  {
    id: 'nomnoml', name: 'nomnoml', version: '1.7.0', date: '2026-10-13',
    repo: 'https://github.com/skanaar/nomnoml',
    desc: L10n.t('nomnoml 极简 UML 类图（[框|字段|方法] 语法）'),
    size: '0.22 MB',
  },
  {
    id: 'plantuml', name: 'PlantUML（官方内核）', version: '1.2026.8', date: '2026-09-06',
    repo: 'https://github.com/plantuml/plantuml',
    desc: L10n.t('PlantUML 原生语法（@plantuml/core，TeaVM 编译，无服务端）：时序 / 用例 / 类 / 活动 / 组件 / 部署 / 状态 / 脑图 / WBS / 甘特 / JSON / YAML / Archimate / ER；内核没有渲染器的六个图种由澄笺自己出图：盐图→HTML 线框、nwdiag→mermaid 网络图、ditaa→SVG 方框、数学公式→KaTeX、时间线→mermaid、文件树→制表符树'),
    size: '11.03 MB',
  },
  {
    id: 'chartjs', name: 'Chart.js', version: '4.5.1', date: '2026-10-14',
    repo: 'https://github.com/chartjs/Chart.js',
    desc: 'Chart.js 数据可视化（JSON 配置：柱状 / 折线 / 饼图 / 雷达等）',
    size: '0.40 MB',
  },
  {
    id: 'vega', name: 'Vega / Vega-Lite', version: '6.4.0 / 6.5.0', date: '2026-10-14',
    repo: 'https://github.com/vega/vega-lite',
    desc: L10n.t('Vega-Lite 声明式统计图（JSON spec：柱状 / 折线 / 散点 / 面积 / 分面等），出 SVG'),
    size: '1.49 MB',
  },
  {
    id: 'marked', name: 'marked', version: '18.1.1', date: '2026-10-14',
    repo: 'https://github.com/markedjs/marked',
    desc: '编辑器「所见即所得 / 即时渲染」的 Markdown 解析',
    size: '0.05 MB'
  },
  {
    id: 'turndown', name: 'turndown', version: '7.2.4', date: '2026-04-03',
    repo: 'https://github.com/mixmark-io/turndown',
    desc: L10n.t('编辑器 HTML → Markdown 序列化（保存实时同步）'),
    size: '0.03 MB'
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
    if (l === 'zenuml') {
      // 插件已弃用，zenuml 在解析层转译成 mermaid 时序图 → 归 mermaid 引擎管辖
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
    if (l === 'nomnoml') {
      return 'nomnoml';
    }
    if (l === 'plantuml') {
      return 'plantuml';
    }
    // nwdiag / salt / ditaa：PlantUML 家族的独立图种，内核没有渲染器，
    // 由澄笺自己出图（nwdiag 桥 mermaid、salt 译 HTML 线框、ditaa 解析成 SVG）。
    // 统一归到 plantuml 引擎开关下，用户在「引擎管理」关一次就全关。
    if (l === 'nwdiag' || l === 'salt' || l === 'ditaa') {
      return 'plantuml';
    }
    if (l === 'chart') {
      return 'chartjs';
    }
    if (l === 'vega' || l === 'vega-lite' || l === 'vega-lite-json' || l === 'vl') {
      return 'vega';
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
