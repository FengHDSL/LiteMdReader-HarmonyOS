/**
 * LiteMdReader · 编辑 / 新建文档
 * ================================
 *
 * 两种入口复用同一页：
 *   · 从书架点「+」→ 无路由参数 → 新建（正文预填一份小模板）
 *   · 从书架/阅读页点「编辑」→ 带 name 参数 → 载入已有文档
 *
 * 三个要点：
 *  1. **片段插入走光标位置**，而不是简单追加到末尾——写作时才有用。
 *     `TextAreaController.getCaretOffset()` 拿位置，插入后把光标选中占位文字，
 *     用户可以直接改写而不必再拖光标。
 *  2. **改名即重命名**：顶栏那个输入框在保存时统一处理，新建走 create、
 *     已有文档走 rename + update，用户不用区分「另存为」和「重命名」。
 *  3. **预览**用与阅读页同一套渲染器，所见即所得。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { GenWallpaper } from '../theme/GenWallpaper';
import { modalSheetOptions, SheetKeyboardLift } from '../material/ModalSheet';
import { VersionSnapshot, VersionStore } from '../service/VersionStore';
import { EditorDraft } from '../service/EditorDraft';
import { UpdateService } from '../service/UpdateService';
import { UnsavedConfirmDialog } from '../components/UnsavedConfirmDialog';
import { WallpaperStore } from '../service/WallpaperStore';
import { WallpaperImage } from '../components/WallpaperImage';
import { withAlpha } from '../theme/DesignTokens';
import { InlineFormulaPool } from '../components/InlineFormulaPool';
import { FormulaTask, FormulaTasks } from '../markdown/FormulaTasks';
import {
  HwBar,
  HwFont,
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  isDarkTheme,
  paletteFor,
  READER_BG_DEFAULT_DARK,
  READER_BG_DEFAULT_LIGHT
} from '../theme/DesignTokens';
import { applySystemBarTheme, applyAppColorMode } from '../service/AppWindow';
import {
  ImmersiveBar,
  ImmersiveCard,
  ImmersiveCardLayer,
  ImmersiveChip,
  ImmersiveIconButton
} from '../material/ImmersiveCard';
import { DocMeta, DocStore, ReaderRoute } from '../service/DocStore';
import { AiChatStore } from '../service/AiChatStore';
import { NavLifecycle } from '../service/NavLifecycle';
import { MdBlock, MdBlockKind, MdHeading, MdParseResult, MdSrcRange, MdTaskState, emptyBlock } from '../markdown/MdTypes';
import { MdParser } from '../markdown/MdParser';
import { EngineRegistry } from '../service/EngineRegistry';
import { MdBlockView } from '../markdown/MdView';
import { MdTable, TableAlign, TableTool } from '../service/TableTool';
import { TableEditorDialog } from '../components/TableEditorDialog';
import { LiveBlockEditor } from '../components/LiveBlockEditor';
import { L10n } from '../service/L10n';
import { AppearanceFx } from '../service/AppearanceFx';

/** 可一键插入的 Markdown 片段 */
interface MdSnippet {
  key: string;
  label: string;
  before: string;
  after: string;
  holder: string;
  /**
   * 工具栏图标。
   * ⚠️ 存的是 **Resource 而不是文件名字符串**：`$r()` 的参数必须是编译期字面量，
   *    `$r('app.media.' + item.icon)` 这种拼接取不到资源（上一版工具栏就栽在这里）。
   *    所以字面量写在数据定义处，用的时候直接 `Image(item.icon)`。
   * 图标是**纯直线填充路径**（不用 stroke、不写 fill），这样 `Image.fillColor()`
   * 才能染色、跟随深浅主题；带 stroke 的 SVG 在 ArkUI 里换不了色。
   * 可省略：符号组（`~ @ ; : — …`）与破折号**用字符本身当图**——给一个画出来的
   * 图标反而不如直接看到要点的是哪个字符。
   */
  icon?: Resource;
  /** 分组：fmt=格式 chart=图表 sym=符号（展开面板按组分节展示） */
  group: string;
  /** 收起状态下也常驻胶囊条（常用那几颗） */
  core: boolean;
  /**
   * 长按气泡说明（可选）。不写时由 tipFor() 从 before/after/holder 自动生成，
   * 所以每个按钮都一定有说明，不会漏。
   */
  tip?: string;
}

/** 版本对比的一行：tag = same（两边都有）/ del（旧版独有）/ add（当前独有） */
interface DiffRow {
  tag: string;
  text: string;
}

/** 语法速查表的一行 */
interface SyntaxRow {
  syntax: string;
  desc: string;
}

/**
 * 展开面板一组的排版结果（一次算好，避免每个格子都重算一遍最长标签）。
 * cellVp = 组内**最长标签**所需的统一宽度；cols = 当前可用宽放得下的列数；
 * rows = 按 cols 切好的行（放不下自动换到下一行）。
 */
interface GroupLayout {
  cellVp: number;
  cols: number;
  rows: MdSnippet[][];
}

/**
 * 工具条滚动内容的左内缩（vp）：首颗芯片离展开钮的距离。
 * ⚠️ 这个值同时被 rememberChipGeo 的淡出坐标换算使用（chipLefts = position.x + 该值），
 *    两处必须同源，改一处不改另一处，边缘淡出就会整体错位。
 */
const BAR_PAD_LEFT: number = 6;
/** 右内缩：滚动时给最后一颗留出淡出/弧边空间，不参与左缘淡出判据。 */
const BAR_PAD_RIGHT: number = 16;

const SNIPPETS: MdSnippet[] = [
  { key: 'h1', label: 'H1', before: '# ', after: '', holder: L10n.t('一级标题'), icon: $r('app.media.tb_h1'), group: 'fmt', core: false },
  { key: 'h2', label: 'H2', before: '## ', after: '', holder: L10n.t('二级标题'), icon: $r('app.media.tb_h2'), group: 'fmt', core: true },
  { key: 'h3', label: 'H3', before: '### ', after: '', holder: L10n.t('三级标题'), icon: $r('app.media.tb_h3'), group: 'fmt', core: false },
  { key: 'bold', label: L10n.t('粗体'), before: '**', after: '**', holder: L10n.t('粗体文本'), icon: $r('app.media.tb_bold'), group: 'fmt', core: true },
  { key: 'italic', label: L10n.t('斜体'), before: '*', after: '*', holder: L10n.t('斜体文本'), icon: $r('app.media.tb_italic'), group: 'fmt', core: true },
  { key: 'strike', label: L10n.t('删除线'), before: '~~', after: '~~', holder: L10n.t('删除线'), icon: $r('app.media.tb_strike'), group: 'fmt', core: false },
  { key: 'mark', label: L10n.t('高亮'), before: '==', after: '==', holder: L10n.t('高亮标记'), icon: $r('app.media.tb_mark'), group: 'fmt', core: false },
  { key: 'code', label: L10n.t('行内代码'), before: '`', after: '`', holder: 'code', icon: $r('app.media.tb_code'), group: 'fmt', core: true },
  { key: 'codeblock', label: L10n.t('代码块'), before: '\n```text\n', after: '\n```\n', holder: L10n.t('代码内容'), icon: $r('app.media.tb_codeblock'), group: 'fmt', core: false },
  { key: 'quote', label: L10n.t('引用'), before: '\n> ', after: '', holder: L10n.t('引用内容'), icon: $r('app.media.tb_quote'), group: 'fmt', core: true },
  { key: 'callout', label: L10n.t('提示块'), before: '\n> [!NOTE]\n> ', after: '', holder: L10n.t('提示内容'), icon: $r('app.media.tb_callout'), group: 'fmt', core: false, tip: L10n.t('插入提示块（> [!NOTE]），渲染成带色提示卡') },
  { key: 'ul', label: L10n.t('无序列表'), before: '\n- ', after: '', holder: L10n.t('列表项'), icon: $r('app.media.tb_ul'), group: 'fmt', core: true },
  { key: 'ol', label: L10n.t('有序列表'), before: '\n1. ', after: '', holder: L10n.t('列表项'), icon: $r('app.media.tb_ol'), group: 'fmt', core: false },
  { key: 'task', label: L10n.t('任务'), before: '\n- [ ] ', after: '', holder: L10n.t('待办事项'), icon: $r('app.media.tb_task'), group: 'fmt', core: false, tip: L10n.t('插入未勾选的任务项 - [ ]') },
  { key: 'table', label: L10n.t('表格'), before: '\n| 列 A | 列 B |\n| --- | --- |\n| ', after: ' | 内容 |\n', holder: L10n.t('内容'), icon: $r('app.media.tb_table'), group: 'fmt', core: false, tip: L10n.t('插入「列 A | 列 B」两列表格模板') },
  { key: 'link', label: L10n.t('链接'), before: '[', after: '](https://)', holder: L10n.t('链接文字'), icon: $r('app.media.tb_link'), group: 'fmt', core: true },
  { key: 'image', label: L10n.t('图片'), before: '![', after: L10n.t('](路径)'), holder: L10n.t('替代文字'), icon: $r('app.media.tb_image'), group: 'fmt', core: true },
  { key: 'divider', label: L10n.t('分割线'), before: '\n---\n', after: '', holder: '', icon: $r('app.media.tb_divider'), group: 'fmt', core: false, tip: L10n.t('插入分割线 ---（单独占一行）') },
  { key: 'note', label: L10n.t('脚注'), before: '[^', after: ']', holder: '1', icon: $r('app.media.tb_note'), group: 'fmt', core: false, tip: L10n.t('插入脚注引用 [^1]，正文末尾再写 [^1]: 说明') },
  // ── 图表快捷插入（用户要求：一键插模板、占位直接改） ──
  // 模板都取"引擎能认的最小可用写法"，且经 tools/verify-chart-templates.js 用
  // **真实渲染模板**在浏览器里跑过 —— 插进去渲染不出来的模板比没有更糟。
  { key: 'chart-mermaid', label: L10n.t('流程图'), before: '\n```mermaid\n', after: '\n```\n', holder: 'graph TD\n  A[开始] --> B{判断}\n  B -->|是| C[执行]\n  B -->|否| D[结束]', icon: $r('app.media.tb_chart_mermaid'), group: 'chart', core: false, tip: L10n.t('插入 mermaid 流程图代码块') },
  { key: 'chart-echarts', label: L10n.t('数据图'), before: '\n```echarts\n', after: '\n```\n', holder: '{"xAxis":{"type":"category","data":["一","二","三"]},"yAxis":{"type":"value"},"series":[{"type":"bar","data":[3,6,9]}]}', icon: $r('app.media.tb_chart_echarts'), group: 'chart', core: false, tip: '插入 ECharts 配置（JSON），可画柱状/折线/饼图' },
  { key: 'chart-markmap', label: L10n.t('脑图'), before: '\n```markmap\n', after: '\n```\n', holder: '# 中心主题\n## 分支一\n### 细节\n## 分支二', icon: $r('app.media.tb_chart_markmap'), group: 'chart', core: false, tip: L10n.t('插入 markmap 大纲，标题层级即脑图分支') },
  { key: 'chart-graphviz', label: L10n.t('关系图'), before: '\n```graphviz\n', after: '\n```\n', holder: 'digraph G {\n  A -> B\n  B -> C\n  A -> C\n}', icon: $r('app.media.tb_chart_graphviz'), group: 'chart', core: false, tip: L10n.t('插入 Graphviz DOT 有向图') },
  { key: 'chart-flowchart', label: L10n.t('旧式流程'), before: '\n```flowchart\n', after: '\n```\n', holder: 'st=>start: 开始\nop=>operation: 处理\ncond=>condition: 通过?\ne=>end: 结束\nst->op->cond\ncond(yes)->e\ncond(no)->op', icon: $r('app.media.tb_chart_flowchart'), group: 'chart', core: false, tip: L10n.t('插入 flowchart.js 语法（老式流程图，新图建议用「流程图」）') },
  { key: 'chart-wavedrom', label: L10n.t('波形'), before: '\n```wavedrom\n', after: '\n```\n', holder: '{"signal":[{"name":"clk","wave":"p...."},{"name":"dat","wave":"x345x","data":["A","B","C"]}]}', icon: $r('app.media.tb_chart_wavedrom'), group: 'chart', core: false, tip: L10n.t('插入 WaveDrom JSON，画数字时序波形') },
  { key: 'chart-abc', label: L10n.t('五线谱'), before: '\n```abc\n', after: '\n```\n', holder: 'X:1\nT:示例曲调\nM:4/4\nL:1/4\nK:C\nC D E F | G A B c |', icon: $r('app.media.tb_chart_abc'), group: 'chart', core: false, tip: L10n.t('插入 ABC 记谱，渲染成五线谱') },
  { key: 'chart-html', label: L10n.t('HTML 预览'), before: '\n```html\n', after: '\n```\n', holder: '<button onclick="this.textContent=(+this.textContent+1)+\'\'">0</button>', icon: $r('app.media.tb_chart_html'), group: 'chart', core: false, tip: L10n.t('插入 HTML 代码块，渲染成可交互网页卡片') },
  // ── 近期新增的图种（2026-10-14）：网络图 / 盐图 / ditaa / Vega-Lite / 极简UML / Chart.js / ZenUML ──
  { key: 'chart-nwdiag', label: L10n.t('网络图'), before: '\n```nwdiag\n', after: '\n```\n', holder: '@startnwdiag\nnetwork Lan {\n  address = "10.0.0.0/24"\n  device "Phone"\n  device "Tablet"\n}\n@endnwdiag', icon: $r('app.media.tb_chart_nwdiag'), group: 'chart', core: false, tip: L10n.t('插入 nwdiag 网络图（网络分组 + 设备 + 网段地址）') },
  { key: 'chart-salt', label: L10n.t('盐图'), before: '\n```salt\n', after: '\n```\n', holder: '@startsalt\n{+\n  名称 | "文本"\n  [ ] 勾选 | (o) 单选\n  [确定]   [取消]\n}\n@endsalt', icon: $r('app.media.tb_chart_salt'), group: 'chart', core: false, tip: L10n.t('插入 salt 界面线框（按钮 / 勾选 / 输入框）') },
  { key: 'chart-ditaa', label: L10n.t('Ditaa'), before: '\n```ditaa\n', after: '\n```\n', holder: '@startditaa\n+---------+\n| 文字 cBLU |\n+---------+\n@endditaa', icon: $r('app.media.tb_chart_ditaa'), group: 'chart', core: false, tip: L10n.t('插入 ditaa ASCII 图元，转成彩色方框（cBLU 等颜色码着色）') },
  { key: 'chart-vega', label: L10n.t('统计图'), before: '\n```vega-lite\n', after: '\n```\n', holder: '{"data":{"values":[{"a":"A","b":28},{"a":"B","b":55}]},"mark":"bar","encoding":{"x":{"field":"a","type":"nominal"},"y":{"field":"b","type":"quantitative"}}}', icon: $r('app.media.tb_chart_vega'), group: 'chart', core: false, tip: L10n.t('插入 Vega-Lite JSON 统计图') },
  { key: 'chart-nomnoml', label: L10n.t('极简UML'), before: '\n```nomnoml\n', after: '\n```\n', holder: '[框A] -> [框B]\n[框B] -> [框C]', icon: $r('app.media.tb_chart_nomnoml'), group: 'chart', core: false, tip: L10n.t('插入 nomnoml 极简 UML') },
  { key: 'chart-chart', label: L10n.t('Chart.js'), before: '\n```chart\n', after: '\n```\n', holder: '{"type":"line","data":{"labels":["一","二","三"],"datasets":[{"label":"示例","data":[1,3,2],"borderColor":"#2F63E8"}]}}', icon: $r('app.media.tb_chart_chart'), group: 'chart', core: false, tip: L10n.t('插入 Chart.js JSON（折线 / 饼图 / 柱状等）') },
  { key: 'chart-zenuml', label: L10n.t('ZenUML'), before: '\n```zenuml\n', after: '\n```\n', holder: 'zenuml\n  Alice -> Bob: 请求\n  Bob -> Alice: 响应', icon: $r('app.media.tb_chart_zenuml'), group: 'chart', core: false, tip: L10n.t('插入 ZenUML 时序（首行 zenuml）') },
  // ── 新增格式按钮（参考常见编辑器补齐） ──
  { key: 'taskdone', label: L10n.t('已完成任务'), before: '\n- [x] ', after: '', holder: L10n.t('已完成事项'), icon: $r('app.media.tb_taskdone'), group: 'fmt', core: false, tip: L10n.t('插入已勾选的任务项 - [x]') },
  { key: 'latex', label: L10n.t('公式块'), before: '\n$$\n', after: '\n$$\n', holder: '\\frac{a}{b}', icon: $r('app.media.tb_latex'), group: 'fmt', core: false, tip: L10n.t('插入块级公式 $$…$$，渲染成公式卡片') },
  { key: 'latexinline', label: L10n.t('行内公式'), before: '$', after: '$', holder: 'E=mc^2', icon: $r('app.media.tb_latexinline'), group: 'fmt', core: false, tip: L10n.t('插入行内公式 $…$，随正文排版') },
  // ⚠️ **下划线 <u>、居中 <div align>、颜色 <font> 三类按钮都不做**：它们只能靠行内
  //    / 块级 HTML 表达，而解析器只认 `<details>` 一种 HTML，其余按纯文本显示
  //    （见 MdParser 头注释）——插进去就是一串显示出来的标签，比没有按钮更糟。
  //    要给就得先在解析器 + 渲染 + 导出三处真正支持，不能只摆个按钮。
  // ── 符号组：字符本身就是图标，不另配 SVG（icon 省略） ──
  // ── 中文符号组（字符本身就是图标，icon 省略）──
  { key: 'sym-mdash', label: '—', before: '—', after: '', holder: '', group: 'symcn', core: false },
  { key: 'sym-endash', label: '–', before: '–', after: '', holder: '', group: 'symcn', core: false },
  { key: 'sym-ellipsis', label: '…', before: '…', after: '', holder: '', group: 'symcn', core: false },
  { key: 'sym-dun', label: '、', before: '、', after: '', holder: '', group: 'symcn', core: false },
  { key: 'sym-dq', label: '“”', before: '“', after: '”', holder: L10n.t('引用'), group: 'symcn', core: false },
  { key: 'sym-sq', label: '‘’', before: '‘', after: '’', holder: L10n.t('引用'), group: 'symcn', core: false },
  { key: 'sym-lpar', label: '（）', before: '（', after: '）', holder: '', group: 'symcn', core: false },
  { key: 'sym-book', label: '《》', before: '《', after: '》', holder: L10n.t('书名'), group: 'symcn', core: false },
  { key: 'sym-tort', label: '【】', before: '【', after: '】', holder: '', group: 'symcn', core: false },
  // ── 英文符号组 ──
  { key: 'sym-pipe', label: '|', before: '|', after: '', holder: '', group: 'symben', core: false },
  { key: 'sym-tilde', label: '~', before: '~', after: '', holder: '', group: 'symben', core: false },
  { key: 'sym-at', label: '@', before: '@', after: '', holder: '', group: 'symben', core: false },
  { key: 'sym-hash', label: '#', before: '#', after: '', holder: '', group: 'symben', core: false },
  { key: 'sym-pct', label: '%', before: '%', after: '', holder: '', group: 'symben', core: false },
  { key: 'sym-amp', label: '&', before: '&', after: '', holder: '', group: 'symben', core: false },
  { key: 'sym-bslash', label: '\\', before: '\\', after: '', holder: '', group: 'symben', core: false },
  { key: 'sym-semi', label: ';', before: ';', after: '', holder: '', group: 'symben', core: false },
  { key: 'sym-colon', label: ':', before: ':', after: '', holder: '', group: 'symben', core: false },
  { key: 'sym-comma', label: ',', before: ',', after: '', holder: '', group: 'symben', core: false },
  { key: 'sym-quest', label: '?', before: '?', after: '', holder: '', group: 'symben', core: false },
  { key: 'sym-bang', label: '!', before: '!', after: '', holder: '', group: 'symben', core: false }
];

/** 收起状态下常驻胶囊条的片段（常用集）。 */
const CORE_SNIPPETS: MdSnippet[] = SNIPPETS.filter((it: MdSnippet) => it.core);

/**
 * 语法速查的行定义。
 *
 * 每一行的 `syntax` 会被**应用自己的解析器 + 渲染器真实渲染**成效果预览，
 * 所以这里只放"能正确渲染"的写法（旧版把「无序 + 有序」「表格缺分隔行」
 * 「```lang 代码块 ```」「![](路径)」这类无效示例塞进一行，预览自然不正常）。
 *
 * 语法口径与说明参考来源：younghz/Markdown（https://github.com/younghz/Markdown）
 * —— 那是流传最广的中文 Markdown 入门教程，本表按它的分类逐项对照，
 * 并按澄笺支持的范围（含 callout / 脚注 / 公式 / 图表等扩展）做了补充。
 */
const SYNTAX_ROWS: SyntaxRow[] = [
  { syntax: '# 一级标题\n## 二级标题\n### 三级标题', desc: L10n.t('标题：一到六个 # 表示一到六级；# 后要有空格') },
  { syntax: L10n.t('**粗体** 与 *斜体* 与 ***粗斜体***'), desc: L10n.t('强调：两侧各一个 * 是斜体、两个是粗体（_ 写法等价）') },
  { syntax: L10n.t('~~删除线~~  与  ==高亮=='), desc: '删除线与高亮标记（扩展语法，两个波浪线 / 两个等号）' },
  { syntax: L10n.t('`行内代码`'), desc: L10n.t('行内代码：一个反引号包裹，底纹带圆角') },
  { syntax: '> 区块引用\n>> 嵌套引用', desc: L10n.t('引用：行首写 > ；连续 >> 表示嵌套一层') },
  { syntax: '> [!NOTE]\n> 提示块的正文写在这里', desc: '提示块：NOTE / TIP / IMPORTANT / WARNING / CAUTION 五种' },
  { syntax: '- 第一项\n- 第二项\n  - 缩进两格表示嵌套', desc: L10n.t('无序列表：- + * 均可，标记后至少一个空格') },
  { syntax: '1. 第一项\n2. 第二项', desc: L10n.t('有序列表：数字 + . + 空格') },
  { syntax: '- [ ] 待办事项\n- [x] 已完成事项', desc: L10n.t('任务列表：渲染成勾选框，阅读页可直接点选') },
  { syntax: '| 语法 | 说明 |\n| --- | --- |\n| 表格 | 第二行用 --- 分隔 |', desc: L10n.t('表格：用 | 分隔单元格，第二行用 --- 分隔表头；用 :-: 控制列对齐') },
  { syntax: '---', desc: L10n.t('分割线：三个及以上的 - * _ 均可') },
  { syntax: '[链接文字](https://www.harmonyos.com)', desc: L10n.t('链接：行内式 [文字](地址)；点击链接会复制地址') },
  { syntax: L10n.t('`![替代文字](图片地址)`'), desc: L10n.t('图片：与链接同理、前面多加一个 !；网络图与本地图（工具条「插图片」）都会真实加载') },
  { syntax: L10n.t('`[^1]` 与 `[^1]: 脚注内容`'), desc: L10n.t('脚注：引用呈上标，定义在文末成注释卡，阅读页左滑可查看') },
  { syntax: '\\*转义\\*', desc: '反斜杠转义：让 * / # / ` 等符号按普通文字显示' },
  // 公式：**用行内写法做预览**——它走 MathLite 同步自绘，一定能显示；
  // 块级 $$ 在面板里要挂 Web 渲染（体积大、首帧空白），只放在说明里讲写法
  { syntax: L10n.t('行内公式：$a^2 + b^2 = c^2$ 直接写在句子里'), desc: '数学公式：行内用一对 $ 包住（开 $ 后不能紧跟空格）；块级单独起一行、用 $$ 包起来。分数 / 上下标 / 根号 / 矩阵 / 希腊字母等常用子集真实渲染' },
  { syntax: '```mermaid\ngraph TD\n  A[打开澄笺] --> B[开始阅读]\n```', desc: '流程图：graph TD / LR 真实布局渲染，其余图表语言按代码块显示' }
];

/** 速查行语法 → 解析后的块缓存（key = syntax 原文） */
const syntaxBlockCache: Map<string, MdBlock[]> = new Map();

interface PreviewModeItem {
  m: number;
  label: string;
  desc: string;
}

const PREVIEW_MODE_ITEMS: PreviewModeItem[] = [
  // ⚠️ 实时预览只保留**分段预览编辑**（用户决定：WYSIWYG / IR 的 Web 表面路线
  // 罢试，编辑页回到 1.1.1 的稳定形态）。两种 Web 模式的分支保留为死代码，
  // previewMode 在进页时强制归 0。
  { m: 0, label: L10n.t('分段预览编辑'), desc: L10n.t('点哪块改哪块（原比例内联编辑）') }
];

/** Web 编辑器（WYSIWYG / IR）与 ArkTS 的桥：Web 调 mdChanged 推送内容。 */
class EditorWebBridge {
  onMd: ((md: string) => void) | null = null;
  onNeedContent: (() => void) | null = null;

  mdChanged(md: string): void {
    if (this.onMd !== null) {
      this.onMd(md);
    }
  }

  requestContent(): void {
    if (this.onNeedContent !== null) {
      this.onNeedContent();
    }
  }
}

@Component
export struct Editor {
  /** 分屏模式：0 纯编辑/预览切换 1 上下分屏 2 左右分屏 */
  @State splitMode: number = 0;
  /** 语言切换计数：变更时整页重建（key 拼接），文案随词典刷新 */
  @StorageProp('languageTick') languageTick: number = 0;
  /** 背景链（与阅读页/书架一致）：手选壁纸 / 函数壁纸 / 模糊 */
  /** 阅读背景图（阅读页设置的"阅读背景"，编辑页同用，优先于壁纸） */
  @StorageProp('readerBgPath') readerBgPath: string = '';
  /** 阅读背景样式（阅读调整里选的程序化背景），编辑页同用 */
  @StorageProp('readerBgId') readerBgId: string = '';
  @StorageProp('wallpaperPath') wallpaperPath: string = '';
  /** 浅色 / 深色模式各自的壁纸（深浅模式自动切换） */
  @StorageProp('wallpaperPathLight') wallpaperPathLight: string = '';
  @StorageProp('wallpaperPathDark') wallpaperPathDark: string = '';

  /** 当前模式生效的壁纸：浅色用浅色壁纸，深色用深色壁纸；未设置则回退旧全局壁纸 */
  private wallpaperPathEffective(): string {
    if (this.isDark()) {
      return this.wallpaperPathDark.length > 0 ? this.wallpaperPathDark : this.wallpaperPath;
    }
    return this.wallpaperPathLight.length > 0 ? this.wallpaperPathLight : this.wallpaperPath;
  }
  @StorageProp('wallpaperGenId') genWallId: string = '';
  @StorageProp('wallpaperBlur') wallpaperBlur: number = 4;
  /** 可读性遮罩浓度（与阅读页同一键，观感一致） */
  @StorageProp('wallpaperScrim') wallpaperScrim: number = 42;
  /** 外观刷新计数（见 SettingsMirror）：主题色 / 灰字 / 沾色改完后靠它重算派生色 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  /** 键盘是否弹出（AppWindow 的 TYPE_KEYBOARD 避让区广播）；
   *  RESIZE 模式下页面底 = 键盘顶，此时底部只留 6vp，别再叠 padBottom */
  @StorageProp('keyboardPx') @Watch('onKeyboardTick') keyboardPx: number = 0;
  /** 背景光斑缓慢漂移 */
  @State blobAX: number = 0;
  @State blobAY: number = 0;
  @State blobBX: number = 0;
  @State blobBY: number = 0;
  /**
   * 路由参数（Navigation 迁移后由 navPageBuilder 注入）：
   * name 有值 = 编辑既有文档；为空 = 新建。
   */
  route: ReaderRoute = { name: '' };
  /** 导航栈：用于返回 */
  stack: NavPathStack | null = null;
  @StorageLink('readerFontSize') @Watch('onVisualChanged') fontSize: number = HwType.bodyDefault;
  @StorageLink('readerLineHeight') lineMul: number = HwType.lineDefault;
  /** 正文预览用的字体族（MdBlockView 现在靠 @Prop 收下发的值，子组件自读 AppStorage 不回刷） */
  @StorageLink('readerFontFamily') @Watch('onVisualChanged') bodyFontKey: string = '';
  /** **英数字体**（阅读设置）：与正文字体同一套刷新链路 */
  @StorageLink('readerFontFamilyEn') @Watch('onVisualChanged') bodyFontEnKey: string = '';
  /** 界面字体与同步开关：值由 HwFont.bodyFamily 现读，这里挂上只为改动能触发重建 */
  @StorageLink('appFontFamily') @Watch('onVisualChanged') appFontKey: string = '';
  @StorageLink('appFontSyncReader') @Watch('onVisualChanged') appFontSync: boolean = false;
  /** **界面字体**（外观设置 → 界面字体）：本页界面文字都从这里取 */
  @StorageProp('appFontFamily') uiFontKey: string = '';
  /** 界面字号缩放系数 / 界面字重相对加粗量（外观设置） */
  @StorageProp('appFontScale') uiFontScale: number = 1;
  @StorageProp('appFontWeightDelta') uiFontWeightDelta: number = 0;
  /** **正文字重**（阅读设置 → 字体粗细）：预览与就地编辑都用它，0 = 不覆盖 */
  @StorageProp('readerFontWeight') bodyWeightMode: number = 0;
  @StorageLink('readerThemeMode') @Watch('onThemeChanged') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') @Watch('onThemeChanged') systemDark: boolean = false;
  /** 沉浸布局下的状态栏 / 手势条避让高度（px） */
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  @StorageProp('safeBottomPx') safeBottomPx: number = 0;

  @State docName: string = '';
  @State @Watch('onContentChanged') content: string = '';
  @State isNew: boolean = true;
  /** 已打开的文档是否为「只读」（标记见 DocStore.isReadOnly）：只读时不允许保存回写 */
  @State docReadOnly: boolean = false;
  @State originalName: string = '';
  /**
   * 未保存标记。**用 @StorageLink 而非 @State**：Index 的 NavDestination 需要在
   * 系统返回手势（onBackPressed）里读到它来拦截"误触退出丢内容"——
   * AppStorage 是两个组件共享脏状态的通道。写入点与 @State 完全一致，无需改动。
   */
  @StorageLink('editorDirty') dirty: boolean = false;
  /** Index 的返回拦截发来的信号：系统返回手势触发 → 弹"保存/不保存"窗（与顶栏返回同逻辑） */
  @StorageProp('editorGoBackTick') @Watch('onGoBackTick') goBackTick: number = 0;
  /**
   * 未保存确认弹窗（自绘 2×2：取消 | 直接离开 / 不保存 | 保存）。
   * 系统 showDialog 的按钮只能横排一行，四个按钮手机上放不下 —— 用户要求 2×2。
   * 回调用箭头函数绑定 this（成员初始化时创建，捕获的是当前组件实例）。
   */
  unsavedDialog: CustomDialogController = new CustomDialogController({
    builder: UnsavedConfirmDialog({
      onCancel: (): void => {
        this.unsavedDialog.close();
      },
      onLeaveWithDraft: (): void => {
        this.leaveWithDraft();
      },
      onDiscard: (): void => {
        this.leaveDiscarding();
      },
      onSave: (): void => {
        this.leaveAfterSave();
      }
    }),
    autoCancel: true,
    customStyle: true
  });
  @State preview: boolean = false;
  /**
   * **实时预览编辑**（块级所见即所得，用户要求）。
   *
   * 与 `preview`（只读预览）的区别：这里显示的是**渲染结果**，但点任意一块
   * 就展开该块的 Markdown 源码直接改，改完原地变回渲染态 —— 不用来回切
   * 「源码 / 预览」，也不用左右分屏挤占版面。
   *
   * 实现要点：**一切改动都落在原文行区间上**。块的 srcLine 由 MdParser 给出
   * （已是原文行号，见 MdParser.lineMap），结束行用「下一个块的起始行」推断
   * （`MdParser.blockSrcRange`）。所以编辑一个块不会动到别的块，
   * 工具条插入的元素也能立刻以渲染态出现在正确位置。
   */
  /** 实时预览模式：0=分段预览编辑 1=所见即所得（WYSIWYG） 2=即时渲染（IR） */
  @StorageLink('editorPreviewMode') @Watch('onPreviewModeChange') previewMode: number = 0;
  /** 已关闭的渲染引擎（设置 → 引擎管理）：marked / turndown 任一关闭 = WYSIWYG 与 IR 停用 */
  @StorageProp('disabledEngines') @Watch('onEnginesChanged') disabledEngineList: string = '';
  /** 模式下拉菜单开关 */
  @State previewModeMenu: boolean = false;
  /** 模式变更：切走时同步 IR 草稿；Web 表面按新模式重渲染。 */
  onPreviewModeChange(): void {
    this.flushIrDraft();
    if (this.liveMode && this.previewMode >= 1) {
      this.pushContentToWeb();
    }
  }

  selectPreviewMode(mode: number): void {
    // WYSIWYG / IR 依赖 marked（MD→HTML）与 turndown（HTML→MD）——
    // 「设置 → 引擎管理」里任一被关闭就停用这两个模式（关闭后无法渲染）
    if (mode >= 1 && this.webModeBlocked()) {
      this.toast(L10n.t('该模式依赖 marked / turndown，已在「设置 → 引擎管理」中关闭'));
      this.previewModeMenu = false;
      return;
    }
    // 切走 IR 前先同步未落盘草稿
    if (this.previewMode === 2) {
      this.flushIrDraft();
    }
    this.previewMode = mode;
    if (!this.liveMode) {
      this.toggleLive();
    }
    this.previewModeMenu = false;
    const labels: string[] = ['分段预览编辑', '所见即所得（WYSIWYG）', '即时渲染（IR）'];
    this.toast('已切换：' + labels[mode] + (this.previewMode === 2 ? L10n.t(' · 在上方源码区直接修改') : ''));
  }

  /** WYSIWYG / IR 的序列化引擎（marked 解析 + turndown 反序列化）是否已被关闭。 */
  private webModeBlocked(): boolean {
    const off: string = this.disabledEngineList;
    return EngineRegistry.isOff('marked', off) || EngineRegistry.isOff('turndown', off);
  }

  /**
   * 「设置 → 引擎管理」开关变化：
   *   · 重收预览区行内公式任务（MathJax 开关，重新开启后补生成图）；
   *   · marked / turndown 被关闭且当前正处在 WYSIWYG / IR → 强制回落「分段预览编辑」
   *    （预览区图表 / 公式块的显隐由 MdBlockView 订阅同一键即时重渲染）。
   */
  onEnginesChanged(): void {
    // 换 renderEpoch 强制预览列表重建：真机上子组件的 @StorageProp 不保证回刷
    // （readerIndent 先例），key 驱动的整列表重建是项目铁律的兜底手段
    this.renderEpoch++;
    this.syncFormulaTasks();
    if (this.previewMode >= 1 && this.webModeBlocked()) {
      this.previewMode = 0;
      this.toast(L10n.t('marked / turndown 已关闭，实时预览回落为分段预览编辑'));
    }
  }

  @Builder
  previewModeMenuBuilder() {
    Column() {
      ForEach(PREVIEW_MODE_ITEMS, (item: PreviewModeItem) => {
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(15)
            .fontColor([this.previewMode === item.m ? '#D4BA86' : '#00000000'])
          Column({ space: 2 }) {
            Text(item.label)
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(15, this.uiFontScale))
              .fontWeight(HwFont.bump(this.previewMode === item.m ? FontWeight.Bold : FontWeight.Normal,
                this.uiFontWeightDelta))
              .fontColor(this.palette().textPrimary)
            Text(item.desc)
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(12, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .borderRadius(10)
        // 引擎管理里关闭了 marked / turndown → WYSIWYG / IR 两项淡显（点了会提示）
        .opacity(this.webModeBlocked() && item.m >= 1 ? 0.4 : 1)
        .onClick(() => {
          this.selectPreviewMode(item.m);
        })
      }, (item: PreviewModeItem) => '' + item.m + '_' + this.previewMode)
      Divider()
        .strokeWidth(1)
        .color(this.palette().divider)
        .margin({ top: 6, bottom: 6 })
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(15)
          .fontColor([this.palette().textSecondary])
        Text(L10n.t('关闭实时预览'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(15, this.uiFontScale))
          .fontColor(this.palette().textSecondary)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .borderRadius(10)
      .onClick(() => {
        this.previewModeMenu = false;
        if (this.liveMode) {
          this.toggleLive();
        }
      })
    }
    .width(260)
    .padding(8)
  }
  /** 实时预览编辑默认关闭（用户拍板：不要默认进入；从眼睛图标进，仅本会话）；
   *  想要纯文本编辑可从模式菜单「关闭实时预览」，仅本次会话生效。 */
  @State liveMode: boolean = false;
  /** 正在编辑的块下标（-1 = 没有块处于编辑态） */
  @State liveEditing: number = -1;
  /** 编辑态里那块的源码草稿（提交时整段替换回原文） */
  @State liveDraft: string = '';
  /** 实时预览的滚动条：提交 / 插入后把相关块滚回视野 */
  private liveScroller: Scroller = new Scroller();
  /** 用法提示只说一次（本次进页面内） */
  private liveTipShown: boolean = false;
  // ── 双链补全（`[[` 候选）──
  /** 候选浮窗是否显示 */
  @State linkPickOpen: boolean = false;
  /** 候选文档名（最多 8 条） */
  @State linkItems: string[] = [];
  /** 最近一次"从一段切到另一段"的时刻（见 onKeyboardTick 的抑制逻辑） */
  private lastEditSwitchAt: number = 0;
  /** 实时预览里正在网格编辑的表格块下标（-1 = 没有） */
  @State liveTableIndex: number = -1;
  /** 所见即所得：弹出面板编辑态（-1 = 关闭）；草稿为该块源码 */
  @State wysOpen: boolean = false;
  @State wysIndex: number = -1;
  @State wysDraft: string = '';
  /** 即时渲染（IR）：整页源码草稿与防抖句柄 */
  @State irDraft: string = '';
  private irDebounce: number = -1;
  /** Web 编辑器（WYSIWYG / IR 表面） */
  private editWebCtrl: webview.WebviewController = new webview.WebviewController();
  private webBridge: EditorWebBridge = new EditorWebBridge();
  /**
   * **保存正在等 Web 侧内容回灌**的标记（事件驱动，取代以前"死等 200ms 重试"）。
   * WYSIWYG / IR 模式下正文在 Web 那边，必须先 exportToHost 把最新内容要回来再落盘：
   * 旧写法固定等 200ms 就重试，桥回调晚于 200ms 时重试存的是**旧内容**，
   * 用户看到的就是"要点两次才真保存"（用户实测）。现在改成
   * mdChanged 一到就续存，另设一个兜底定时器 —— Web 侧没有改动时它不会回调，
   * 只干等就永远存不下去。
   */
  private saveAwaitingWeb: boolean = false;
  /** 续存时要沿用的 quiet 标志（自动保存静默 / 手动保存要提示） */
  private saveAwaitingQuiet: boolean = false;
  /** 兜底定时器句柄（-1 = 无） */
  private saveWatchdog: number = -1;
  /**
   * 「块内部刚消费过这次点击」的标记。
   * ArkUI 的 ClickEvent 没有 stopPropagation，父子 onClick 都会跑（子先父后），
   * 靠它避免点图片 / 表格 / 放大按钮时又顺带进了整块的编辑态。
   */
  private liveChildTap: boolean = false;
  /** 子交互标记的时刻：超过 700ms 视为陈旧、不再吞下一次块点击
   *  （打开网格/放大图等不冒泡的路径会留下 true，把下一次点块吞掉——
   *   用户实测"点一下就进去就行，为什么要点两次"） */
  private liveChildTapAt: number = 0;

  private markChildTap(): void {
    this.liveChildTap = true;
    this.liveChildTapAt = Date.now();
  }
  /** 插入锚点：最近点过 / 编辑过的块下标，工具条插入的元素落在它后面 */
  @State liveAnchor: number = -1;
  /** 编辑态下方「这块渲染出来什么样」的预览块（只解析草稿，块很小，开销可忽略） */
  @State livePreviewBlocks: MdBlock[] = [];
  /** 编辑页的表格网格编辑器（与阅读页同组件，保存时写回 content 而非直接落盘） */
  @State editTable: MdTable = { header: [''], rows: [['']], align: ['none'] } as MdTable;
  tableDialog: CustomDialogController = new CustomDialogController({
    builder: TableEditorDialog({
      tbl: $editTable,
      onSave: (): void => {
        this.saveLiveTable();
      }
    }),
    autoCancel: true,
    customStyle: true
  });
  /**
   * 焦点写作（批 5 之一）：隐藏顶栏与底部工具层，只留正文与右上角退出钮。
   * 正文区随隐藏自动扩大，排版设置照常生效；再点退出钮（或保存/返回）恢复。
   */
  @State focusMode: boolean = false;
  /** 预览图片放大浮层：非空 = 显示（点击预览里的图片触发） */
  @State previewImage: string = '';
  @State previewImgScale: number = 1;
  private previewImgPinchBase: number = 1;
  /** 图片浮层的**单指拖动**平移与基准（与阅读页放大浮层同款） */
  @State previewImgDx: number = 0;
  @State previewImgDy: number = 0;
  private previewImgDxBase: number = 0;
  private previewImgDyBase: number = 0;
  @State showSyntax: boolean = false;
  /** 画板浮层 */
  @State previewBlocks: MdBlock[] = [];
  /** 实时自动保存防抖定时器（-1 = 无待发；1.2s 无新改动即落盘） */
  private autoSaveTimer: number = -1;
  /** 自动保存基线：加载 / 草稿恢复 / 模板灌入 / 上次保存成功时的内容快照 */
  private autoSaveBase: string = '';
  /** 迷你预览刷新计数：每次草稿重解析递增（块 id 是解析序号，打字时不变，
   *  不加它 ForEach 复用旧节点 = "预览效果不实时刷新"——用户实测） */
  @State livePreviewTick: number = 0;
  /** 块提交/删除计数：提交后块内容变了但 id（解析序号）与 renderEpoch 都没变，
   *  key 不变会让 ForEach 复用旧节点 = "完成后不刷新"与"点两次才进编辑"
   * （用户实测）。进 key 强制整列表按新内容重建。 */
  @State liveCommitTick: number = 0;
  /** 行内公式图任务（编辑器预览里的 $公式$ 与阅读页同款出图） */
  @State formulaTasks: FormulaTask[] = [];
  /** 公式图就绪信号（递增 → 预览块 key 重算 → 换成图） */
  @State formulaTick: number = 0;
  @State rootWidth: number = 360;
  /** 窗口实测高度（全屏画板的尺寸依据） */
  @State rootHeight: number = 800;
  /** 渲染纪元：字号变化时自增，拼进预览 ForEach 的 key 强制重建（否则 @Prop 不同步） */
  @State renderEpoch: number = 0;

  onVisualChanged(): void {
    this.renderEpoch++;
    // 公式图缓存键含字号——预览区的图任务重收（否则新字号永远无图）
    this.syncFormulaTasks();
  }
  // ── 编辑器查找 / 替换 / 跳转行（移植自参考项目 CodeMirror 的查找替换与跳转行） ──
  @State showFind: boolean = false;
  @State findQuery: string = '';
  @State replaceText: string = '';
  @State findMatches: number[] = [];
  @State findCursor: number = -1;
  @State gotoLineText: string = '';
  // ── 阅读背景自定义色（编辑页与阅读页同一套背景） ──
  @StorageLink('readerCustomBgLight') customBgLight: string = '';
  @StorageLink('readerCustomBgDark') customBgDark: string = '';

  /**
   * 光标位置。
   *
   * 刻意用 `onTextSelectionChange` 记录，而**不用** `TextAreaController.getCaretOffset()`：
   * 该方法的返回类型在不同 SDK 修订版里不一致（有的是 number，有的是 CaretOffset），
   * 用它会出现在某个 SDK 上编不过的问题。onTextSelectionChange 的回调签名则长期稳定。
   */
  @State caret: number = -1;
  /** 选区末端（与 caret 一起由 onTextSelectionChange 给出）：快捷键加粗 / 斜体要用 */
  @State caretEnd: number = -1;

  private controller: TextAreaController = new TextAreaController();

  // ── 版本历史（用户要求）──
  @StorageLink('versionAutoSave') versionAutoSave: boolean = true;
  @StorageLink('versionAutoSaveInterval') versionInterval: number = 5;
  @State showVersions: boolean = false;
  @State versionList: VersionSnapshot[] = [];
  /** 对比视图：-1 = 快照列表；否则 = 正在对比的快照时间戳 */
  @State diffFor: number = -1;
  @State diffRows: DiffRow[] = [];
  private verTimer: number = -1;
  private lastAutoAt: number = 0;
  private lastAutoContent: string = '';

  /** AI 预设菜单显隐：已配置接口才出现「摘要 / 续写 / 润色」（进入对话始终可用） */
  @State aiReady: boolean = false;
  /** 配置纪元：设置页保存后重新判定 AI 是否已配置（否则编辑页入口停在旧状态） */
  @StorageProp('aiCfgTick') @Watch('onAiCfgTick') aiCfgTick: number = 0;

  aboutToAppear(): void {
    // **键盘避让改 RESIZE**：默认 OFFSET 是「整页上移」，会把悬浮工具层顶到
    // 键盘上方一大截（页面没缩、只是平移）。RESIZE 让页面布局高度直接收缩，
    // 钉底的悬浮层自然贴在键盘上沿，正文区也同步缩小——平台级方案，自己不算高度。
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    // 背景光斑的两条无限动画**推到转场之后**再开（与阅读页同一口径）：
    // 在进场那一帧起动画，等于让整页在转场期间每帧都重算一次光斑变换
    setTimeout((): void => {
      this.startBlobDrift();
    }, 600);
    const aiCtx: common.UIAbilityContext | null = this.ctx();
    this.aiReady = aiCtx !== null && AiChatStore.isConfigured(AiChatStore.loadConfig(aiCtx));
    const params: ReaderRoute = this.route;
    if (params !== undefined && params !== null && params.name !== undefined && params.name.length > 0) {
      this.loadExisting(params.name);
    } else {
      this.isNew = true;
      this.docName = '';
      // 从模板新建：模板正文经路由传入（**不提前落盘**）—— 这样编辑页里点
      // 「直接离开 / 不保存」才是真的不创建文档（用户反馈修复）。
      const seed: string | undefined = params !== undefined && params !== null
        ? params.seed : undefined;
      this.content = seed !== undefined && seed !== null && seed.length > 0
        ? seed
        : DocStore.NEW_DOC_TEMPLATE;
      this.dirty = false;
    }
    applySystemBarTheme(this.isDark());
    // 恢复的预览模式可能落在已关闭的引擎上（上次用着 WYSIWYG，之后在
    // 「设置 → 引擎管理」里关了 marked/turndown）→ 进页先回落，别等渲染失败
    // ⚠️ 实时预览只保留分段预览编辑（WYSIWYG / IR 已罢试）——持久化的 1/2 归 0
    if (this.previewMode !== 0) {
      this.previewMode = 0;
    }
    // 版本历史自动保存：30s 一次节拍，到间隔且内容有变化才真正落快照
    this.verTimer = setInterval(() => {
      this.autoSnapshotTick();
    }, 30000);
    // **实时自动保存的基线**（用户要求"实时保存修改的内容"）：加载 / 草稿恢复 /
    // 模板灌入完成后，把当前内容定为基线——此后内容偏离基线（用户真的改了）才
    // 防抖落盘，避免"打开文档就被自动保存"的误写。
    this.autoSaveBase = this.content;
  }

  aboutToDisappear(): void {
    if (this.verTimer >= 0) {
      clearInterval(this.verTimer);
      this.verTimer = -1;
    }
    // 编辑中的块先提交，再有未落盘内容就立即静默保存（最后一次敲击不丢）
    this.flushLiveEdit();
    if (this.content !== this.autoSaveBase && this.dirty) {
      if (this.autoSaveTimer >= 0) {
        clearTimeout(this.autoSaveTimer);
        this.autoSaveTimer = -1;
      }
      this.save(true);
    } else if (this.autoSaveTimer >= 0) {
      clearTimeout(this.autoSaveTimer);
      this.autoSaveTimer = -1;
    }
  }

  /** 自动保存节拍：开关开 + 到达间隔 + 内容相对上次快照有变化才落盘。 */
  private autoSnapshotTick(): void {
    if (!this.versionAutoSave || this.docName.length === 0) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastAutoAt < this.versionInterval * 60000) {
      return;
    }
    if (this.content === this.lastAutoContent) {
      return;
    }
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    if (VersionStore.snapshot(ctx, this.docName, this.content)) {
      this.lastAutoAt = now;
      this.lastAutoContent = this.content;
      if (this.showVersions) {
        this.versionList = VersionStore.list(ctx, this.docName);
      }
    }
  }

  /** 手动保存成功后也记一份快照（保存历史 = 版本历史）。 */
  private snapshotAfterSave(ctx: common.UIAbilityContext): void {
    if (VersionStore.snapshot(ctx, this.docName, this.content)) {
      this.lastAutoAt = Date.now();
      this.lastAutoContent = this.content;
    }
  }

  /** 打开版本历史面板。 */
  private openVersions(): void {
    if (this.docName.length === 0) {
      this.toast(L10n.t('先保存文档才有版本历史'));
      return;
    }
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    this.versionList = VersionStore.list(ctx, this.docName);
    this.diffFor = -1;
    this.getUIContext().animateTo(AppearanceFx.anim(260, Curve.FastOutSlowIn), () => {
      this.showVersions = true;
    });
  }

  /** 生成对比行：掐掉公共前后缀后，旧版中段 = 删除、当前中段 = 新增（轻量线性对比）。 */
  private buildDiff(oldContent: string): void {
    const oldLines: string[] = oldContent.split('\n');
    const newLines: string[] = this.content.split('\n');
    let head: number = 0;
    while (head < oldLines.length && head < newLines.length && oldLines[head] === newLines[head]) {
      head++;
    }
    let tailOld: number = oldLines.length - 1;
    let tailNew: number = newLines.length - 1;
    while (tailOld >= head && tailNew >= head && oldLines[tailOld] === newLines[tailNew]) {
      tailOld--;
      tailNew--;
    }
    const rows: DiffRow[] = [];
    for (let k = 0; k < head; k++) {
      rows.push({ tag: 'same', text: oldLines[k] } as DiffRow);
    }
    for (let k = head; k <= tailOld; k++) {
      rows.push({ tag: 'del', text: oldLines[k] } as DiffRow);
    }
    for (let k = head; k <= tailNew; k++) {
      rows.push({ tag: 'add', text: newLines[k] } as DiffRow);
    }
    for (let k = tailOld + 1; k < oldLines.length; k++) {
      rows.push({ tag: 'same', text: oldLines[k] } as DiffRow);
    }
    this.diffRows = rows;
  }

  /** 进入对比视图：选中快照 vs 当前编辑内容。 */
  private startDiff(ts: number): void {
    for (let k = 0; k < this.versionList.length; k++) {
      if (this.versionList[k].ts === ts) {
        this.buildDiff(this.versionList[k].content);
        this.diffFor = ts;
        return;
      }
    }
  }

  /** 把选中的快照恢复为当前内容（恢复前先记一份当前内容快照，恢复错了还能找回）。 */
  private restoreVersion(ts: number): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    for (let k = 0; k < this.versionList.length; k++) {
      if (this.versionList[k].ts === ts) {
        VersionStore.snapshot(ctx, this.docName, this.content);
        this.content = this.versionList[k].content;
        this.dirty = true;
        this.showVersions = false;
        if (this.splitMode > 0) {
          this.refreshPreviewBlocks();
        }
        this.toast('已恢复到 ' + this.versionTime(ts));
        return;
      }
    }
  }

  private versionTime(ts: number): string {
    const d: Date = new Date(ts);
    const pad = (v: number): string => {
      return v < 10 ? '0' + v : '' + v;
    };
    return (d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  /** 主题变化时同步系统栏图标颜色与应用级颜色模式。 */
  onThemeChanged(): void {
    applyAppColorMode(this.themeMode);
    applySystemBarTheme(this.isDark());
    // Web 编辑表面（WYSIWYG/IR）配色跟主题走（浅色主题不再是一整块深色网页）
    this.pushThemeToWeb();
    // 公式图缓存键含深浅——预览区图任务重收
    this.syncFormulaTasks();
  }

  /** 沉浸布局下顶部要避开状态栏（px → vp，用 UIContext 的 px2vp，全局那个已废弃）。 */
  private padTop(): number {
    return this.getUIContext().px2vp(this.safeTopPx) + HwSpace.xs;
  }

  private padBottom(): number {
    return this.getUIContext().px2vp(this.safeBottomPx) + HwSpace.xs;
  }

  /**
   * 首行让位（与阅读页 topSpacerHeight 同源取值）：
   * 状态栏 + 顶栏胶囊 + 一条小缝 —— 第一行文字落在顶栏下方，不被胶囊压住；
   * 正文向上滑动时照样从胶囊底下穿过（顶栏下层正常显示文字）。
   */
  private contentTopInset(): number {
    return this.padTop() + HwBar.pill + HwSpace.xs;
  }

  /**
   * 末行让位（与阅读页文末留白同源思路）：手势条 + 底部悬浮工具层实际高度 + 小缝。
   * 工具层 = 片段工具条（ImmersiveBar 定高 pill=52）+ 间距 xs(6) + 底部状态栏（≈44）；
   * 纯预览态没有片段条，只用让开状态栏那一层。
   * 滚到最底时最后一行停在工具层上方，不被底栏遮挡。
   */
  private contentBottomInset(): number {
    const toolLayer: number = this.preview ? 44 : 52 + HwSpace.xs + 44;
    return this.padBottom() + toolLayer + HwSpace.xs;
  }

  private loadExisting(name: string): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      DocStore.init(ctx);
      const meta: DocMeta | undefined = DocStore.find(ctx, name);
      if (meta === undefined) {
        this.toast(L10n.t('文档不存在'));
        return;
      }
      // **预置文档支持修改**（用户要求）：内置文档与普通文档同一编辑链路
      //（保存时 DocStore.update 会把正文写到 docs/<fileName> 覆盖 rawfile 默认内容）；
      // 重命名 / 删除依旧受限。
      this.isNew = false;
      this.originalName = meta.name;
      this.docName = meta.name;
      this.content = DocStore.readText(ctx, meta);
      // 只读文档：正文照常显示，但保存会被拦下（入口侧已隐藏编辑按钮，这里兜底）
      this.docReadOnly = DocStore.isReadOnly(ctx, meta.name);
      // 先复位（@StorageLink 初值可能残留上一次进入的 true）
      this.dirty = false;
      // **恢复「直接离开」留下的草稿**（用户要求"不小心退出的内容还在"）：
      // 草稿与正文一致 = 上次离开后没再改过文档，静默清掉即可，不打扰；
      // 不一致才恢复并标记未保存。
      const draft: string = EditorDraft.load(ctx, meta.name);
      if (draft.length > 0) {
        if (draft !== this.content) {
          this.content = draft;
          this.dirty = true;
          setTimeout(() => {
            this.toast(L10n.t('已恢复上次未保存的修改，可继续编辑或保存'));
          }, 350);
        } else {
          EditorDraft.clear(ctx, meta.name);
        }
      }
    } catch (err) {
      this.toast('读取失败：' + DocStore.describeError(err as BusinessError));
    }
  }

  // ══════════════════════ 基础 ══════════════════════

  /** 设置页保存了 AI 配置：重新判定 AI 入口可用性（编辑页 AI chip 的预设菜单随之出现）。 */
  private onAiCfgTick(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    this.aiReady = c !== null && AiChatStore.isConfigured(AiChatStore.loadConfig(c));
  }

  private ctx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  private isDark(): boolean {
    // 统一转调 isDarkTheme：**羊皮纸 / 护眼绿是浅色纸底**，
    // 漏判会让编辑器背景 / 系统栏按 systemDark 走，与纸色文字对不上。
    return isDarkTheme(this.themeMode, this.systemDark);
  }

  private palette(): ReaderPalette {
    // 三个来源都要显式读一遍落成局部常量：paletteFor 是纯函数读 AppStorage、不登记依赖，
    // 这里不登记的话主题切换会被 ArkUI 跳过重算（文字变黑、退出重进才恢复）
    const tick: number = this.appearanceTick;
    // 羊皮纸 / 护眼绿有独立调色板，必须按主题模式取色，不能只看明暗
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  private measureWidth(): number {
    // **平板全宽**：不再限宽 760——正文要铺满屏幕，左右不留空白（用户要求）
    return this.rootWidth;
  }

  /** 编辑区水平内边距：**平板留一个字符的空隙**（约 16vp，不贴死屏幕边缘），手机保留页边距 */
  private editorHPad(): number {
    return this.rootWidth > 760 ? HwType.bodyDefault : HwSpace.lg;
  }

  /**
   * 自定义阅读背景色；**没选时用固定默认色（与阅读页同一套，不再回退主题渐变）**。
   * 「阅读背景」完全独立于主题（用户要求），切主题编辑页背景也不变。
   */
  private pageBackground(): string {
    if (this.isDark()) {
      return this.customBgDark.length > 0 ? this.customBgDark : READER_BG_DEFAULT_DARK;
    }
    return this.customBgLight.length > 0 ? this.customBgLight : READER_BG_DEFAULT_LIGHT;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1800 });
    } catch (err) {
      // 提示失败不影响主流程
    }
  }

  private stats(): string {
    let chars: number = 0;
    let words: number = 0;
    try {
      const parsed: MdParseResult = MdParser.parse(this.content);
      chars = parsed.charCount;
      words = parsed.wordCount;
    } catch (err) {
      chars = this.content.length;
    }
    return words + ' 字 · ' + chars + ' 字符';
  }

  // ══════════════════════ 片段插入 ══════════════════════

  private insertSnippet(snippet: MdSnippet): void {
    // 实时预览：插进去就**立刻是渲染好的样子**（表格即表格、代码即高亮卡片），
    // 位置落在锚点块之后，点它就能改 —— 不再插入一坨看不懂的源码
    if (this.liveMode) {
      this.insertRawLive(snippet.before + snippet.holder + snippet.after);
      return;
    }
    let offset: number = this.content.length;
    if (this.caret >= 0 && this.caret <= this.content.length) {
      offset = this.caret;
    }
    const inserted: string = snippet.before + snippet.holder + snippet.after;
    this.content = this.content.substring(0, offset) + inserted + this.content.substring(offset);
    this.dirty = true;
    const selStart: number = offset + snippet.before.length;
    const selEnd: number = selStart + snippet.holder.length;
    this.caret = selEnd;
    if (selEnd > selStart) {
      // 选中占位文字，用户可以直接改写而不必再拖光标
      setTimeout(() => {
        try {
          this.controller.setTextSelection(selStart, selEnd);
        } catch (err) {
          // 光标定位失败不影响插入结果
        }
      }, 40);
    }
  }

  /** 在光标处插入一段原文（图片插入用，无占位文字可选中）。 */
  private insertRaw(text: string): void {
    if (this.liveMode) {
      this.insertRawLive(text);
      return;
    }
    let offset: number = this.content.length;
    if (this.caret >= 0 && this.caret <= this.content.length) {
      offset = this.caret;
    }
    this.content = this.content.substring(0, offset) + text + this.content.substring(offset);
    this.dirty = true;
    this.caret = offset + text.length;
  }

  // ══════════════════════ 一键插入目录 ══════════════════════

  /**
   * 目录行判定：`- [标题](#锚点)`。
   * 用于识别「上一次生成的目录」—— 再点一次就替换它，而不是叠第二份。
   * 只在文首区域做这个判定，正文里同形态的链接列表不会被误认。
   */
  private isTocLine(s: string): boolean {
    const t: string = s.trim();
    if (!t.startsWith('- ')) {
      return false;
    }
    const lb: number = t.indexOf('[');
    const rb: number = t.indexOf('](');
    return lb === 2 && rb > lb && t.endsWith(')');
  }

  /**
   * 一键插入 / 刷新目录。
   *
   * 位置：**文首**（front matter 之后）—— 目录放在正文开头是通行做法，
   * 也避开了「光标在哪」的不确定性。已有目录则整段替换，重复点不会叠加。
   * 锚点用标题原文：阅读页的 `normalizeAnchor` 会忽略空格与常见标点后比对，
   * 所以带空格、带标点的中文标题也能跳得到。
   */
  private insertToc(): void {
    const lines: string[] = this.content.split('\n');
    // ① 跳过 YAML front matter（口径与 MdParser.parse 一致）
    let at: number = 0;
    if (lines.length > 1 && lines[0].trim() === '---') {
      for (let k: number = 1; k < lines.length; k++) {
        const t: string = lines[k].trim();
        if (t === '---' || t === '...') {
          at = k + 1;
          break;
        }
      }
    }
    while (at < lines.length && lines[at].trim().length === 0) {
      at++;
    }

    // ② 扫描标题（**跳过围栏代码块内的 #**，否则教程文档里的示例会被当成真标题）
    const items: string[] = [];
    let inFence: boolean = false;
    for (let k: number = 0; k < lines.length; k++) {
      const t: string = lines[k].trim();
      if (inFence) {
        if (t.startsWith('```') || t.startsWith('~~~')) {
          inFence = false;
        }
        continue;
      }
      if (t.startsWith('```') || t.startsWith('~~~')) {
        inFence = true;
        continue;
      }
      if (this.isTocLine(lines[k])) {
        continue;
      }
      let p: number = 0;
      let level: number = 0;
      while (p < t.length && t.charAt(p) === '#') {
        level++;
        p++;
      }
      if (level < 1 || level > 6 || p >= t.length || t.charAt(p) !== ' ') {
        continue;
      }
      const text: string = t.substring(p + 1).trim();
      if (text.length === 0) {
        continue;
      }
      let indent: string = '';
      for (let n: number = 1; n < level; n++) {
        indent = indent + '  ';
      }
      // 标题里的方括号会破坏链接语法，去掉（渲染不受影响）
      const safe: string = text.replace(/[[\]]/g, '');
      items.push(indent + '- [' + safe + '](#' + safe + ')');
    }
    if (items.length === 0) {
      this.toast(L10n.t('文档里还没有标题，先写几个 ## 再插目录'));
      return;
    }

    // ③ 定位旧目录（文首连续的目录行）并整体替换
    let end: number = at;
    if (at < lines.length && this.isTocLine(lines[at])) {
      while (end < lines.length && this.isTocLine(lines[end])) {
        end++;
      }
    }
    const head: string[] = lines.slice(0, at);
    const tail: string[] = lines.slice(end);
    const out: string[] = head.concat(items);
    if (tail.length > 0 && tail[0].trim().length > 0) {
      out.push('');
    }
    this.content = out.concat(tail).join('\n');
    this.dirty = true;
    if (this.liveMode || this.splitMode > 0) {
      this.refreshPreviewBlocks();
    }
    this.toast(end > at ? L10n.t('已刷新目录（') + items.length + ' 条）' : L10n.t('已插入目录（') + items.length + ' 条）');
  }

  // ══════════════════════ 插入图片 ══════════════════════
  //
  // 移植自参考项目「编辑时粘贴图片 → 存进 images/ 目录 → 自动插引用」：
  // 端上没有剪贴板图片的可靠入口，用系统图片选择器替代；
  // 图片复制进沙箱 docs/images/（无权限要求），引用相对路径，阅读页可真实加载。

  /**
   * 进入 AI 对话（1.2.0）：把当前编辑的文档发给 AI（修改 / 润色 / 提问）。
   * 正文走 AppStorage 信号直传（**未保存的修改也在内**，AI 读到的是此刻内容）；
   * quote 非空 = 实时预览里长按选择条「发送AI」带来的选中文本。
   */
  private openAiChat(quote: string): void {
    // **基础模式（纯离线）拦截**（用户要求）：AI 助手要走网络，离线模式直接挡在入口
    if (UpdateService.isOffline()) {
      this.toast(L10n.t('基础模式（纯离线）下 AI 助手不可用'));
      return;
    }
    // **未保存先自动保存**（用户要求）：保证 AI 拿到的文档名 / 正文与磁盘一致；
    // 保存失败（如只读文档）不阻断——正文仍经信号直传给 AI
    if (this.dirty) {
      this.save();
    }
    AppStorage.setOrCreate('aiChatDocName', this.docName);
    AppStorage.setOrCreate('aiChatDocContent', this.content);
    AppStorage.setOrCreate('aiChatQuote', quote);
    if (this.stack !== null) {
      this.stack.pushPath({ name: 'pages/AiChat' }, AppearanceFx.navAnimated());
    }
  }

  /** 编辑页 AI 预设：摘要 / 续写 / 润色 → 进对话页自动发送（复用文档上下文与 <doc> 落盘） */
  private sendAiPreset(prompt: string): void {
    AppStorage.setOrCreate('aiChatPreset', prompt);
    this.openAiChat('');
  }

  /** AI 助手 chip 长按菜单（bindContextMenu LongPress；与 chip 点击进对话不竞争，MenuItem 点击自动收起） */
  @Builder
  aiChipMenu() {
    Menu() {
      MenuItem({ content: L10n.t('进入 AI 对话') })
        .onClick(() => {
          this.openAiChat('');
        })
      if (this.aiReady) {
        MenuItem({ content: L10n.t('生成摘要') })
          .onClick(() => {
            this.sendAiPreset('请为这篇文档生成一份摘要，要点清晰、语言简洁。');
          })
        MenuItem({ content: L10n.t('续写') })
          .onClick(() => {
            this.sendAiPreset('请接着这篇文档的结尾续写一段，保持原文的风格与语气。');
          })
        MenuItem({ content: L10n.t('润色') })
          .onClick(() => {
            this.sendAiPreset('请润色这篇文档的语言表达，保持原意与整体结构，并给出修改后的完整全文。');
          })
      }
    }
  }

  private insertImage(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      // **系统图片选择组件**（PhotoViewPicker）：系统级 UI、无需任何媒体库权限，
      // 选中的 URI 带临时授权，复制进沙箱后长期可用。
      const photoPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      photoPicker.select(options).then((result: photoAccessHelper.PhotoSelectResult) => {
        if (result === undefined || result === null || result.photoUris === undefined
          || result.photoUris.length === 0) {
          return;
        }
        const rel: string | null = DocStore.importImageFromUri(ctx, result.photoUris[0]);
        if (rel === null) {
          this.toast(L10n.t('图片导入失败：格式不支持或超过 20MB'));
          return;
        }
        this.insertRaw('\n![图片](' + rel + ')\n');
        this.toast('已插入 ' + rel + '，预览即可查看');
      }).catch((err: BusinessError) => {
        this.toast('选择图片失败：' + err.message);
      });
    } catch (err) {
      this.toast(L10n.t('无法打开图片选择器'));
    }
  }

  // ══════════════════════ 手写插入 ══════════════════════
  //
  // 「手写」进独立页（Pen Kit 官方 HandwriteComponent 画布）；
  // 完成后 PNG 落 docs/images/，Markdown 片段经 AppStorage 回传，光标处插入。
  // 双通道触发：@Watch（同 UI 上下文 setOrCreate 会触发）+ 编辑页 onShown tick 兜底。

  /** 进入手写页。push 前清掉上一次的待插入片段（防旧值重复插入）。 */
  private openSketch(): void {
    AppStorage.setOrCreate('sketchInsertMd', '');
    try {
      if (this.stack !== null) {
        this.stack.pushPath({ name: 'pages/Sketch' }, AppearanceFx.navAnimated());
      }
    } catch (err) {
      this.toast(L10n.t('无法打开手写页'));
    }
  }

  /** 待插入的手写片段（Sketch 页写回），非空即在光标处插入并清掉。 */
  @StorageProp('sketchInsertMd') @Watch('onSketchInsert') sketchInsertMd: string = '';
  /** 编辑页 onShown tick（Index 转发），兜底检查待插入片段 */
  @StorageProp('editorShownTick') @Watch('onEditorShownTick') editorShownTick: number = 0;

  /** 吸收待插入的手写片段（两个通道共用，幂等：插入即清键）。 */
  private absorbSketch(): void {
    const md: string = AppStorage.get<string>('sketchInsertMd') ?? '';
    if (md.length > 0) {
      AppStorage.setOrCreate('sketchInsertMd', '');
      this.insertRaw(md);
      this.toast(L10n.t('手写笔记已插入，预览即可查看'));
    }
  }

  private onSketchInsert(): void {
    this.absorbSketch();
  }

  private onEditorShownTick(): void {
    this.absorbSketch();
  }

  /** 语法速查某行被点击：把该行写法插到光标位置并收起面板。 */
  private insertSyntax(syntax: string): void {
    this.insertRaw(syntax);
    this.showSyntax = false;
    this.toast(L10n.t('已插入到光标位置'));
  }

  /**
   * 语法速查 / 预览里的「放大」按钮统一入口。
   * · image → 用编辑页既有的图片浮层（可捏合 + 单指拖动）；
   * · 图表（Chart / Math）→ 编辑页没有 Web 渲染器，给明确提示，而不是静默无反应。
   */
  private openPreviewImagePayload(mode: string, payload: string): void {
    if (mode === 'image') {
      this.previewImgScale = 1;
      this.previewImgDx = 0;
      this.previewImgDy = 0;
      this.previewImage = payload;
      return;
    }
    this.toast(L10n.t('图表请在阅读页里放大查看'));
  }

  // ══════════════════════ 查找 / 替换 / 跳转行 ══════════════════════
  //
  // 移植自参考项目 CodeMirror 的查找替换与跳转行。以「匹配位置」为单位导航，
  // 上一处/下一处直接把光标选区设到匹配段上（TextArea 会自动把选区滚进可视区）。

  private openFind(): void {
    this.getUIContext().animateTo(AppearanceFx.anim(260, Curve.FastOutSlowIn), () => {
      this.showFind = true;
    });
  }

  private closeFind(): void {
    this.getUIContext().animateTo(AppearanceFx.anim(260, Curve.FastOutSlowIn), () => {
      this.showFind = false;
      this.replaceRowOpen = false;
    });
  }

  /** 替换行展开 / 收起 */
  @State replaceRowOpen: boolean = false;

  /** 重新计算全部匹配位置（不区分大小写）。内容或关键词变化后调用。 */
  private recomputeMatches(): void {
    const needle: string = this.findQuery.trim().toLowerCase();
    const out: number[] = [];
    if (needle.length > 0) {
      const hay: string = this.content.toLowerCase();
      let from: number = 0;
      while (from <= hay.length) {
        const at: number = hay.indexOf(needle, from);
        if (at < 0) {
          break;
        }
        out.push(at);
        from = at + needle.length;
      }
    }
    this.findMatches = out;
    this.findCursor = out.length > 0 ? 0 : -1;
  }

  private findLabel(): string {
    if (this.findQuery.trim().length === 0) {
      return '';
    }
    if (this.findMatches.length === 0) {
      return '无匹配';
    }
    return (this.findCursor + 1) + ' / ' + this.findMatches.length;
  }

  /** 把光标选区设到指定区间（TextArea 会滚动到该处），并同步记录 caret。 */
  private selectRange(start: number, end: number): void {
    setTimeout(() => {
      try {
        this.controller.setTextSelection(start, end);
      } catch (err) {
        // 定位失败不影响
      }
    }, 40);
    this.caret = end;
  }

  private stepMatch(delta: number): void {
    if (this.findQuery.trim().length === 0) {
      return;
    }
    // 内容可能已被编辑，导航时惰性重算
    this.recomputeMatches();
    const total: number = this.findMatches.length;
    if (total === 0) {
      this.toast(L10n.t('没有匹配的内容'));
      return;
    }
    let next: number = this.findCursor + delta;
    if (next < 0) {
      next = total - 1;
    }
    if (next >= total) {
      next = 0;
    }
    this.findCursor = next;
    const at: number = this.findMatches[next];
    this.selectRange(at, at + this.findQuery.trim().length);
  }

  /** 替换当前匹配：光标必须正好停在一个匹配上，否则先跳到当前匹配。 */
  private replaceCurrent(): void {
    this.recomputeMatches();
    if (this.findMatches.length === 0) {
      this.toast(L10n.t('没有匹配的内容'));
      return;
    }
    const needle: string = this.findQuery.trim();
    const at: number = this.findCursor >= 0 && this.findCursor < this.findMatches.length
      ? this.findMatches[this.findCursor] : this.findMatches[0];
    if (this.content.substring(at, at + needle.length).toLowerCase() !== needle.toLowerCase()) {
      this.toast(L10n.t('请先用「上一处/下一处」定位到要替换的词'));
      return;
    }
    this.content = this.content.substring(0, at) + this.replaceText
      + this.content.substring(at + needle.length);
    this.dirty = true;
    this.caret = at + this.replaceText.length;
    this.recomputeMatches();
    this.toast(L10n.t('已替换'));
  }

  private replaceAll(): void {
    const needle: string = this.findQuery.trim();
    if (needle.length === 0) {
      return;
    }
    this.recomputeMatches();
    const total: number = this.findMatches.length;
    if (total === 0) {
      this.toast(L10n.t('没有匹配的内容'));
      return;
    }
    // 不区分大小写的整体替换：按匹配区间从后往前拼
    let out: string = this.content;
    for (let k = total - 1; k >= 0; k--) {
      const at: number = this.findMatches[k];
      out = out.substring(0, at) + this.replaceText + out.substring(at + needle.length);
    }
    this.content = out;
    this.dirty = true;
    this.caret = -1;
    this.recomputeMatches();
    this.toast('已替换 ' + total + ' 处');
  }

  /** 跳转到指定行（1 起）：行号 → 字符偏移，光标落上去。 */
  private gotoLine(): void {
    const line: number = parseInt(this.gotoLineText.trim(), 10);
    if (isNaN(line) || line < 1) {
      this.toast(L10n.t('请输入大于 0 的行号'));
      return;
    }
    const lines: string[] = this.content.split('\n');
    if (line > lines.length) {
      this.toast('全文共 ' + lines.length + ' 行');
      return;
    }
    let offset: number = 0;
    for (let k = 0; k < line - 1; k++) {
      offset += lines[k].length + 1;
    }
    this.selectRange(offset, offset);
    this.toast('已跳到第 ' + line + ' 行');
  }

  // ══════════════════════ 粘贴图片 ══════════════════════
  //
  // 移植自参考项目的「编辑时粘贴图片 → 存 images/ → 自动插链接」：
  // 拦截 TextArea 的粘贴事件，剪贴板里是图片就落到 docs/images/ 并插入引用；
  // 是文本则不拦截，走系统默认粘贴。

  private onEditorPaste(): void {
    try {
      pasteboard.getSystemPasteboard().getData().then((data: pasteboard.PasteData) => {
        if (data.getRecordCount() === 0) {
          return;
        }
        const record: pasteboard.PasteDataRecord = data.getRecord(0);
        const pixel: image.PixelMap | undefined = record.pixelMap;
        if (pixel === undefined || pixel === null) {
          return; // 文本粘贴交给默认行为
        }
        const packer: image.ImagePacker = image.createImagePacker();
        const opts: image.PackingOption = { format: 'image/png', quality: 100 };
        packer.packToData(pixel, opts).then((buf: ArrayBuffer) => {
          const ctx = this.ctx();
          if (ctx === null) {
            return;
          }
          const rel: string | null = DocStore.saveImageBytes(ctx, buf, '.png');
          if (rel === null) {
            this.toast(L10n.t('图片保存失败'));
            return;
          }
          this.insertRaw('\n![粘贴图片](' + rel + ')\n');
          this.toast('已插入 ' + rel);
        }).catch((err: BusinessError) => {
          this.toast('图片编码失败：' + err.message);
        });
      }).catch((err: BusinessError) => {
        // 读不到剪贴板按普通文本粘贴处理
      });
    } catch (err) {
      // 拦截失败走默认粘贴
    }
  }

  // ══════════════════════ 保存与返回 ══════════════════════

  /**
   * **正在编辑的块草稿提交回正文**（保存 / 离开前必须调用——否则当前块的
   * 修改不在 content 里，保存就丢：用户实测"保存后也没有修改"）。
   */
  private flushLiveEdit(): void {
    if (this.liveMode && this.liveEditing >= 0) {
      this.commitBlockEdit();
    }
  }

  /**
   * **实时自动保存**（用户要求"实时保存修改的内容"）：内容偏离基线 1.2s 后
   * 静默落盘（不打 toast、不打版本快照——快照有 30s 节拍兜底）。
   * 基线 = 加载 / 草稿恢复 / 模板灌入 / 上次保存成功的内容，打开文档本身不触发。
   * 失败（只读等）静默返回，dirty 保持 true 由显式保存兜底。
   */
  private onContentChanged(): void {
    if (this.content === this.autoSaveBase) {
      return;
    }
    if (this.autoSaveTimer >= 0) {
      clearTimeout(this.autoSaveTimer);
    }
    this.autoSaveTimer = setTimeout((): void => {
      this.autoSaveTimer = -1;
      if (this.content !== this.autoSaveBase && this.dirty) {
        this.save(true);
      }
    }, 1200);
  }

  /**
   * 保存。quiet = **实时自动保存通道**（用户要求"实时保存修改的内容"）：
   * 成功不打 toast（连续自动保存不吵）、只读/未命名的提示也静默跳过；
   * 失败照常提示（罕见且必须让用户知道），dirty 保持 true 由显式保存兜底。
   */
  /**
   * 续存被挂起的保存：Web 内容回灌到位（onWebMdChanged）或兜底定时器到点时调用。
   * 没在等就什么都不做（避免手动保存 + 定时器各存一次）。
   */
  private resumePendingSave(): void {
    if (!this.saveAwaitingWeb) {
      return;
    }
    this.save(this.saveAwaitingQuiet);
  }

  private save(quiet: boolean = false): boolean {
    // **正在编辑的块先提交回正文**（否则保存丢当前块——用户实测）
    this.flushLiveEdit();
    // Web 编辑模式：正文在 Web 那边，先把最新内容要回来再落盘。
    if (this.previewMode >= 1 && this.liveMode && !this.saveAwaitingWeb) {
      this.saveAwaitingWeb = true;
      this.saveAwaitingQuiet = quiet;
      try {
        this.editWebCtrl.runJavaScript('window.exportToHost();');
      } catch (err) {
        // Web 未就绪：走兜底定时器，不卡住保存
      }
      // 兜底：Web 侧内容没变时不会回 mdChanged（回调里内容相同直接 return），
      // 光等事件就永远存不下去。400ms 后不管有没有回内容都续存。
      if (this.saveWatchdog >= 0) {
        clearTimeout(this.saveWatchdog);
      }
      this.saveWatchdog = setTimeout((): void => {
        this.saveWatchdog = -1;
        this.resumePendingSave();
      }, 400);
      return false;
    }
    if (this.saveAwaitingWeb) {
      // 这一次是"内容已到手"的续存：清标记、还原 quiet
      this.saveAwaitingWeb = false;
      if (this.saveWatchdog >= 0) {
        clearTimeout(this.saveWatchdog);
        this.saveWatchdog = -1;
      }
      quiet = this.saveAwaitingQuiet;
    }
    const ctx = this.ctx();
    if (ctx === null) {
      return false;
    }
    let wanted: string = this.docName.trim();
    if (wanted.length === 0 && this.isNew) {
      // **未命名时自动以年月日时分秒命名**（用户要求），如 20261003180032
      const d: Date = new Date();
      const pad = (n: number): string => n < 10 ? '0' + n : '' + n;
      wanted = '' + d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate())
        + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds());
    }
    if (wanted.length === 0) {
      if (!quiet) {
        this.toast(L10n.t('请先填写文档名'));
      }
      return false;
    }
    // 只读文档不允许回写（正常入口已隐藏编辑按钮，这里兜底挡住深层路径）
    if (this.docReadOnly && !this.isNew) {
      if (!quiet) {
        this.toast(L10n.t('该文档是只读的，先切成「可写」再编辑'));
      }
      return false;
    }
    try {
      DocStore.init(ctx);
      if (this.isNew) {
        const meta: DocMeta | null = DocStore.create(ctx, wanted, this.content);
        if (meta === null) {
          this.toast(L10n.t('保存失败：名称非法或已存在同名文档'));
          return false;
        }
        this.isNew = false;
        this.originalName = meta.name;
        this.docName = meta.name;
        this.dirty = false;
        EditorDraft.clear(ctx, meta.name);
        this.autoSaveBase = this.content;
        if (!quiet) {
          this.snapshotAfterSave(ctx);
          this.toast('已保存《' + meta.name + '》');
        }
        return true;
      }
      if (wanted !== this.originalName) {
        if (!DocStore.rename(ctx, this.originalName, wanted)) {
          this.toast(L10n.t('重命名失败：名称非法或已存在同名文档'));
          return false;
        }
        this.originalName = DocStore.sanitizeName(wanted);
        this.docName = this.originalName;
      }
      if (!DocStore.update(ctx, this.originalName, this.content)) {
        this.toast(L10n.t('保存失败'));
        return false;
      }
      this.dirty = false;
      // 已写入正文：草稿没有存在意义了，清掉（否则下次打开又会冒出旧内容）
      EditorDraft.clear(ctx, this.originalName);
      this.autoSaveBase = this.content;
      if (!quiet) {
        // 版本快照只在显式保存时记（实时自动保存有 30s 节拍兜底，不打快照防刷屏）
        this.snapshotAfterSave(ctx);
        this.toast('已保存《' + this.originalName + '》');
      }
      return true;
    } catch (err) {
      this.toast('保存失败：' + DocStore.describeError(err as BusinessError));
      return false;
    }
  }

  /** 统一包一层 try/catch：路由返回是被标记「可能抛异常」的接口。 */
  private closePage(): void {
    try {
      if (this.stack !== null) {
        this.stack.pop(AppearanceFx.navAnimated());
      }
    } catch (err) {
      this.toast(L10n.t('返回失败'));
    }
  }

  private goBack(): void {
    if (!this.dirty) {
      this.closePage();
      return;
    }
    // 自绘 2×2 弹窗（用户要求）：系统 showDialog 的按钮只能横排一行，
    // 四个动作（取消 / 直接离开 / 不保存 / 保存）手机上一行放不下。
    this.unsavedDialog.open();
  }

  /**
   * 「直接离开」：不写文档正文，但把当前内容存一份草稿（EditorDraft），
   * 下次打开这篇文档时自动恢复 —— 走人的路要顺，内容不能丢。
   * 新文档（还没存过盘、没有名字）没有草稿挂靠点，退化为不保存直接走。
   */
  private leaveWithDraft(): void {
    // 编辑中的块先提交：草稿要存的是"含当前块修改"的完整内容
    this.flushLiveEdit();
    const ctx = this.ctx();
    if (ctx !== null && this.docName.length > 0) {
      if (EditorDraft.save(ctx, this.docName, this.content)) {
        this.toast(L10n.t('已存草稿，下次打开自动恢复'));
      }
    }
    this.dirty = false;
    // 基线对齐：离开后 aboutToDisappear 的冲刷不能把"直接离开"的内容再写进正文
    this.autoSaveBase = this.content;
    this.unsavedDialog.close();
    this.closePage();
  }

  /** 「不保存」：丢弃修改（连旧草稿一起清掉，用户明确说不要了），返回书架。 */
  private leaveDiscarding(): void {
    const ctx = this.ctx();
    if (ctx !== null) {
      EditorDraft.clear(ctx, this.docName);
    }
    this.dirty = false;
    this.unsavedDialog.close();
    this.closePage();
  }

  /** 「保存」：写入文档后返回书架；保存失败则留在编辑页处理（save 内部已提示）。 */
  private leaveAfterSave(): void {
    if (this.save()) {
      this.unsavedDialog.close();
      this.closePage();
      return;
    }
    this.unsavedDialog.close();
  }

  /** Index 的系统返回拦截发来信号（editorGoBackTick 变化）→ 走与顶栏返回相同的弹窗逻辑。 */
  private onGoBackTick(): void {
    if (this.goBackTick > 0) {
      this.goBack();
    }
  }

  private togglePreview(): void {
    if (!this.preview) {
      try {
        const parsed: MdParseResult = MdParser.parse(this.content);
        this.previewBlocks = parsed.blocks;
      } catch (err) {
        this.previewBlocks = [];
      }
    }
    // 切换包在 animateTo 里：配合两侧的 .transition，预览/编辑互切有淡入淡出 + 轻微缩放
    this.getUIContext().animateTo(AppearanceFx.anim(240, Curve.FastOutSlowIn), () => {
      this.preview = !this.preview;
    });
  }

  /** 语法浮层的开关。条件挂载包在 animateTo 里，进出场动画才会播放。 */
  private openSyntax(): void {
    this.getUIContext().animateTo(AppearanceFx.anim(260, Curve.FastOutSlowIn), () => {
      this.showSyntax = true;
    });
  }

  // ══════════════════════ 顶栏 ══════════════════════

  @Builder
  topBar() {
    ImmersiveBar({ palette: this.palette(), barPaddingH: HwSpace.xs, barPaddingV: HwSpace.xs }) {
      ImmersiveIconButton({
        buttonSize: 34,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          this.goBack();
        }
      }) {
        SymbolGlyph($r('sys.symbol.arrow_left'))
          .fontSize(17)
          .fontColor([this.palette().textPrimary])
      }

      TextInput({ text: this.docName, placeholder: this.isNew ? L10n.t('给文档起个名字') : L10n.t('文档名') })
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .layoutWeight(1)
        .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
        .fontColor(this.palette().textPrimary)
        .placeholderColor(this.palette().textTertiary)
        .backgroundColor('#00000000')
        .padding({ left: HwSpace.sm, right: HwSpace.sm })
        .maxLines(1)
        .onChange((value: string) => {
          this.docName = value;
          this.dirty = true;
        })

      // 三颗按钮包进带间距的 Row：ImmersiveBar 内部 Row 没有 space，会贴在一起
      Row({ space: HwSpace.xs }) {
        // 版本历史（用户要求）：实时预览按钮左边
        ImmersiveIconButton({
          buttonSize: 34,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            this.openVersions();
          }
        }) {
          SymbolGlyph($r('sys.symbol.doc_text_badge_clock'))
            .fontSize(16)
            .fontColor([this.palette().textPrimary])
        }

        // **实时预览编辑**（用户要求：点击直接进入 / 再点退出，不再弹模式菜单）；
        // 金点 = 实时预览中的状态标记
        ImmersiveIconButton({
          buttonSize: 34,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            this.getUIContext().animateTo(AppearanceFx.anim(220, Curve.FastOutSlowIn), () => {
              this.toggleLive();
            });
          }
        }) {
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.square_and_pencil'))
              .fontSize(16)
              .fontColor([this.liveMode ? this.palette().accent : this.palette().textPrimary])
            Circle()
              .width(8)
              .height(8)
              .fill('#D4BA86')
              .offset({ x: 8, y: -7 })
              .opacity(this.liveMode ? 1 : 0)
          }
          .width(22)
          .height(22)
        }
        // **纯预览切换（眼睛）**：实时预览编辑中隐藏（用户要求，带出现/消失过渡）——
        // 实时预览本身全程渲染态，纯预览按钮此时是冗余入口
        if (!this.liveMode) {
          Column() {
            ImmersiveIconButton({
              buttonSize: 34,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.togglePreview();
              }
            }) {
              SymbolGlyph(this.preview ? $r('sys.symbol.highlighter_line') : $r('sys.symbol.eye'))
                .fontSize(17)
                .fontColor([this.preview ? this.palette().accent : this.palette().textPrimary])
            }
          }
          .transition(TransitionEffect.OPACITY.animation(AppearanceFx.anim(220, Curve.FastOutSlowIn))
            .combine(TransitionEffect.scale({ x: 0.7, y: 0.7 })))
        }

        ImmersiveIconButton({
          buttonSize: 34,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            this.openFind();
          }
        }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(16)
            .fontColor([this.palette().textPrimary])
        }

        ImmersiveIconButton({
          buttonSize: 34,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            this.save();
          }
        }) {
          SymbolGlyph(this.dirty ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.checkmark_circle'))
            .fontSize(18)
            .fontColor([this.palette().accent])
        }
      }
      .alignItems(VerticalAlign.Center)
    }
  }

  // ══════════════════════ 片段工具条 ══════════════════════

  // ── 工具条边缘淡入淡出 + 模糊（胶囊弧线裁切与视口内缩互斥，改用软过渡）──
  private barScroller: Scroller = new Scroller();
  private barScrollX: number = 0;
  /** 每颗芯片在内容坐标系里的左缘 / 宽度（onAreaChange 实测） */
  private chipLefts: number[] = [];
  private chipWidths: number[] = [];
  /** 每颗芯片的透明度（滚动时逐帧重算） */
  @State chipAlphas: number[] = [];
  /**
   * 工具条是否展开。收起 = 胶囊条只放常用几颗；展开 = 胶囊条上方再多出一块
   * **分组网格面板**，所有编辑功能按钮一次性摊开供快速点选（用户要求）。
   */
  @State barExpanded: boolean = false;
  /** 当前长按显示气泡说明的按钮 key（'' = 无；松手即清空，气泡随之消失） */
  @State tipKey: string = '';
  /** 「全部编辑功能」面板内容区的实测宽度（vp）：按钮网格按它自适应列数 */
  @State panelInnerW: number = 0;

  /**
   * 文本视觉宽度估算（vp）：CJK 与全角标点按 1 em，半角按 0.55 em。
   * **刻意不用 MeasureUtils**：量出来的单位（fp / px）与 px2vp 的换算在不同
   * 字号缩放下容易差一档，差一点就表现为"某一列被挤到下一行"。估算法确定性、
   * 可离线校验（tools/verify-panel-layout.js），宁可略宽也不裁字。
   */
  private estTextVp(text: string, fp: number): number {
    let em: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      em += code > 0x2E80 ? 1 : 0.55;
    }
    return em * fp;
  }

  /** 一组按钮的统一宽度 = 组内**最长标签**那颗所需的宽度（用户要求）。 */
  private groupCellVp(items: MdSnippet[]): number {
    let w: number = 0;
    for (let i = 0; i < items.length; i++) {
      const it: MdSnippet = items[i];
      const fp: number = it.icon === undefined ? 15 : 13;
      // 图标 15 + ImmersiveChip 内部 Row 间隙 HwSpace.xs(6) = 21；
      // 左右内边距 chipPaddingH 各 8 = 16；再留 6 防估算偏窄把字挤掉。
      const need: number = this.estTextVp(it.label, fp)
        + (it.icon === undefined ? 0 : 21) + 16 + 6;
      if (need > w) {
        w = need;
      }
    }
    return Math.round(w);
  }

  /** 长按气泡文案：没手写 tip 就从插入片段自动推一条，保证每个按钮都有说明。 */
  private tipFor(item: MdSnippet): string {
    if (item.tip !== undefined && item.tip.length > 0) {
      return item.tip;
    }
    if (item.group === 'symcn' || item.group === 'symben') {
      return '插入字符 ' + item.label;
    }
    const b: string = item.before.split('\n').join('⏎');
    const a: string = item.after.split('\n').join('⏎');
    if (item.holder.length === 0) {
      return '插入 ' + b;
    }
    if (a.length === 0) {
      return '插入 ' + b + ' …';
    }
    return '包裹选中文字：' + b + ' … ' + a;
  }

  /** 展开 / 收起：状态翻转包在 animateTo 里，面板的 transition 才会有动画。 */
  private toggleBarExpanded(): void {
    this.getUIContext().animateTo(AppearanceFx.anim(240, Curve.FastOutSlowIn), () => {
      this.barExpanded = !this.barExpanded;
    });
  }

  /** 工具条横向滚动：更新滚动量并重算边缘淡出。 */
  private onBarScroll(): void {
    // 工具条未挂载时 currentOffset() 可能为 undefined（同 Index 的线上崩溃）
    const off: OffsetResult | undefined = this.barScroller.currentOffset();
    if (off === undefined || off === null) {
      return;
    }
    this.barScrollX = off.xOffset;
    this.updateChipFade();
  }

  /** 记录芯片几何（onAreaChange 实测），随后重算淡出。 */
  private rememberChipGeo(index: number, area: Area): void {
    const lw: Length = area.width;
    if (typeof lw !== 'number' || lw <= 0) {
      return;
    }
    this.chipWidths[index] = lw;
    const px: Position = area.position;
    const lx: Length | undefined = px.x;
    if (typeof lx === 'number') {
      // position.x 相对父 Row；Row 自身还有左内缩，一并算进内容坐标（常量见 BAR_PAD_LEFT）
      this.chipLefts[index] = lx + BAR_PAD_LEFT;
    }
    this.updateChipFade();
  }

  /** 胶囊条里的芯片总数（手写 + 插图片 + AI 助手 + 常用片段）。 */
  private chipCount(): number {
    return 3 + CORE_SNIPPETS.length;
  }

  /**
   * 重算每颗芯片的透明度：**按已滑出胶囊边缘的量**淡出（zone = 30vp）。
   * 左侧看芯片右缘 (left+w)、右侧看芯片左缘 (W-left)——
   * 这样静止时贴边 / 出屏一半的芯片不会被整体误淡出。
   */
  private updateChipFade(): void {
    const n: number = this.chipCount();
    const next: number[] = [];
    for (let i = 0; i < n; i++) {
      const cl: number | undefined = this.chipLefts[i];
      const cw: number | undefined = this.chipWidths[i];
      const left: number = (cl === undefined ? 0 : cl) - this.barScrollX;
      const w: number = cw === undefined ? 0 : cw;
      const leftFade: number = (left + w) / 20;
      const rightFade: number = (this.rootWidth - left) / 20;
      const raw: number = Math.min(leftFade, rightFade);
      next.push(Math.max(0, Math.min(1, raw)));
    }
    this.chipAlphas = next;
  }

  /** 指定芯片的透明度（未测量时按 1 处理）。 */
  private chipAlphaAt(index: number): number {
    const a: number | undefined = this.chipAlphas[index];
    return a === undefined ? 1 : a;
  }

  /** 指定芯片的模糊度：越靠近边缘越模糊（淡出 + 模糊 = "融进胶囊"的观感）。 */
  private chipBlurAt(index: number): number {
    return (1 - this.chipAlphaAt(index)) * 6;
  }

  @Builder
  snippetBar() {
    // 边缘处理 = **模糊 + 淡入淡出**（胶囊弧线裁切与视口内缩互斥，弃用）。
    // barPaddingH 保持 0：视口铺满整个胶囊，芯片在滑出过程中透明度/模糊度
    // 按"已滑出胶囊边缘的量"逐帧变化（见上方 chipAlphas 一组方法），
    // 静止时的缩进由 Row 自己的 padding 承担。
    // barPaddingH 8：展开钮与胶囊左缘的间距加大（用户要求往右移一点，别太挤）
    ImmersiveBar({ palette: this.palette(), barPaddingH: 8, barPaddingV: 4, barHeight: HwBar.pill }) {
      // 展开钮**钉在最左边**（在 Scroll 外面，横向滚动不跟着走），且是**圆形**按钮（在 Scroll 外面，横向滚动不跟着走），且是**圆形**按钮
      // —— 之前用胶囊芯片包一枚圆框箭头，外面一层长条、里面一个圆，看着别扭。
      Row({ space: 4 }) {
        ImmersiveIconButton({
          buttonSize: 30,
          buttonRadius: 15,
          // 展开钮整体右移 8vp（用户要求：与胶囊左缘/首颗芯片的间距别太挤）
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            this.toggleBarExpanded();
          }
        }) {
          // ⚠️ `$r()` 的参数必须是**字面量**，写成 $r(cond ? 'a' : 'b') 取不到资源
          //（上一版工具栏就是这么编译不过的）——所以两个图标各写一份。
          // 圆框上下箭头（用户指定的图标）：收起时朝上=可展开，展开时朝下=可收起。
          if (this.barExpanded) {
            Image($r('app.media.chevron_down_circle'))
              .width(19)
              .height(19)
              .fillColor(this.palette().accent)
          } else {
            Image($r('app.media.chevron_up_circle'))
              .width(19)
              .height(19)
              .fillColor(this.palette().accent)
          }
        }
        Scroll(this.barScroller) {
        Row({ space: HwSpace.xs }) {
        // **手写**（用户要求）：进入独立手写页（Pen Kit 官方 HandwriteComponent 画布），
        // 完成后 PNG 落进 docs/images/、Markdown 片段经 AppStorage 传回，光标处插入
        Column() {
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: L10n.t('手写'),
            chipOnTap: () => {
              this.openSketch();
            }
          }) {
            SymbolGlyph($r('sys.symbol.paintbrush'))
              .fontSize(13)
              .fontColor([this.palette().accent])
          }
        }
        .opacity(this.chipAlphaAt(0))
        .blur(this.chipBlurAt(0))
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.rememberChipGeo(0, newValue);
        })

        // 插入图片：从系统选择器选图，复制进文档图片目录后插入相对引用
        // 注意：ImmersiveChip 带**尾随闭包**，闭包之后不能再链式属性（编译错误），
        // 淡出用的 opacity/blur/onAreaChange 挂在外层包装容器上
        Column() {
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: L10n.t('插图片'),
            chipOnTap: () => {
              this.insertImage();
            }
          }) {
            SymbolGlyph($r('sys.symbol.picture'))
              .fontSize(13)
              .fontColor([this.palette().accent])
          }
        }
        .opacity(this.chipAlphaAt(1))
        .blur(this.chipBlurAt(1))
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.rememberChipGeo(1, newValue);
        })

        // AI 助手（1.2.0）：点击**直接进入对话**（真机验证：bindMenu 与 chip 内部手势
        // 竞争导致点击无反应 → 点击直进对话 + 长按弹功能菜单，两者不竞争）
        Column() {
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: L10n.t('AI 助手'),
            chipOnTap: () => {
              this.openAiChat('');
            }
          }) {
            Image($r('app.media.ai_spark'))
              .width(17)
              .height(17)
              .fillColor(this.palette().accent)
          }
        }
        .opacity(this.chipAlphaAt(2))
        .blur(this.chipBlurAt(2))
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.rememberChipGeo(2, newValue);
        })
        .bindContextMenu(this.aiChipMenu.bind(this), ResponseType.LongPress)

        // 常用片段（收起状态也都在条里）：每颗都带图标。
        // ⚠️ ImmersiveChip 带尾随闭包后**不能再链式属性**（编译错误），
        //    所以淡出用的 opacity/blur/onAreaChange 挂在外层包装 Column 上——
        //    与上面手写 / 插图片 / AI 三颗同一写法。
        ForEach(CORE_SNIPPETS, (item: MdSnippet, index: number) => {
          Column() {
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: L10n.t(item.label),
              chipPaddingH: 10,
              // 符号组没有图标：字符本身就是脸，字号放大一点才看得清
              chipFontSize: item.icon === undefined ? 15 : 0,
              chipOnTap: (): void => {
                this.insertSnippet(item);
              }
            }) {
              if (item.icon !== undefined) {
                Image(item.icon)
                  .width(15)
                  .height(15)
                  .fillColor(this.palette().accent)
              }
            }
          }
          .opacity(this.chipAlphaAt(index + 3))
          .blur(this.chipBlurAt(index + 3))
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.rememberChipGeo(index + 3, newValue);
          })
        }, (item: MdSnippet) => item.key)
      }
      // 静止时首/尾芯片**完全落在胶囊直段内**、不与两端弧线重合
      .padding({ left: BAR_PAD_LEFT, right: BAR_PAD_RIGHT })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .onDidScroll(() => {
      // 滚动逐帧重算边缘淡出（透明度 + 模糊）
      this.onBarScroll();
    })
    .width('100%')
    .height(40)
    // **两端圆弧裁切**（用户要求"片段两段裁切要圆形"）：滚动内容从圆弧边缘进出，
    // 不再是直角切断（与底栏胶囊的弧线同语言）
    .borderRadius(HwRadius.pill)
    .clip(true)
    .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 5, right: 5 })
    }
  }

  /**
   * 展开面板：**限高 + 内部滚动**（用户要求"面板不用太高，能滑动选择就行"——
   * 面板一高就把正文挡住了）。顶部一行放「收起」按钮，展开态也能就地收回。
   */
  @Builder
  barExpandPanel() {
    Column({ space: HwSpace.xs }) {
      Row({ space: HwSpace.xs }) {
        Text(L10n.t('全部编辑功能'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
          .layoutWeight(1)
        Row({ space: 4 }) {
          Image($r('app.media.chevron_down_circle'))
            .width(16)
            .height(16)
            .fillColor(this.palette().accent)
          Text(L10n.t('收起'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().accent)
        }
        .padding({ left: 10, right: 12, top: 5, bottom: 5 })
        .borderRadius(HwRadius.pill)
        .backgroundColor(this.palette().quoteBg)
        .onClick(() => {
          this.toggleBarExpanded();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 6 }) {
          this.barGroupRows('格式', SNIPPETS.filter((it: MdSnippet) => it.group === 'fmt'))
          this.barGroupRows('图表', SNIPPETS.filter((it: MdSnippet) => it.group === 'chart'))
          this.barGroupRows('中文符号', SNIPPETS.filter((it: MdSnippet) => it.group === 'symcn'))
          this.barGroupRows('英文符号', SNIPPETS.filter((it: MdSnippet) => it.group === 'symben'))
        }
        .width('100%')
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)
      .width('100%')
      // 实测内容宽 → panelGrid 据此算列数（平板/折叠屏变宽时自动多放几列）
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const w: number = Number(newValue.width);
        if (w > 0 && Math.abs(w - this.panelInnerW) > 1) {
          this.panelInnerW = w;
        }
      })
      // 约 4 行按钮 + 组标题：够滑动挑，又不至于盖住大半屏正文
      .constraintSize({ maxHeight: 208 })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(HwRadius.card)
    .backgroundColor(withAlpha(this.palette().surface, 'FF'))
    .border({ width: 1, color: this.palette().divider })
    .shadow({ radius: 20, color: this.palette().shadow, offsetY: 4 })
    .alignItems(HorizontalAlign.Start)
    .transition(TransitionEffect.OPACITY
      .animation(AppearanceFx.anim(240, Curve.FastOutSlowIn))
      .combine(TransitionEffect.translate({ y: 16 })))
  }

  /**
   * 「全部编辑功能」面板的网格：**四组共用一套格宽与列数**。
   * 原来每组按"本组最长标签"算宽 → 格式组窄、图表组宽，同一面板里按钮大小不一；
   * 现在取**全部片段里最长那颗**的需求当基准格宽，再按面板实测宽度算列数，
   * 并把格宽**拉伸到整行铺满**（列数 × 格宽 + 间隙 = 面板宽），
   * 所以按钮一样大、每行填满、面板变宽变窄都会自动改列数（用户要求三条一起满足）。
   */
  private panelGrid(): GroupLayout {
    const gap: number = 6;
    const avail: number = Math.max(160, this.panelInnerW > 0 ? this.panelInnerW : this.rootWidth - 64);
    const need: number = this.groupCellVp(SNIPPETS);
    let cols: number = Math.floor((avail + gap) / (need + gap));
    if (cols < 2) {
      cols = 2;
    }
    if (cols > 6) {
      cols = 6;
    }
    const cell: number = (avail - (cols - 1) * gap) / cols;
    const empty: MdSnippet[][] = [];
    const out: GroupLayout = { cellVp: cell, cols: cols, rows: empty };
    return out;
  }

  /**
   * 一组按钮：标题 + **每颗同宽（按最长标签算）、每行放得下几列放几列**。
   * 之前是"每行固定 4 颗 + layoutWeight 等分"：格子等宽但芯片按内容伸缩，
   * 于是同一列的文字一个偏左一个偏右（用户反馈"不要一个左一个右"）；
   * 现在宽度由内容算出、行内左对齐，列与列严格对齐，放不下自动少放一列换行。
   */
  @Builder
  barGroupRows(title: string, items: MdSnippet[]) {
    if (items.length > 0) {
      Column({ space: 6 }) {
        Text(title)
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
          .width('100%')
        ForEach(this.chunkRows(items, this.panelGrid().cols), (row: MdSnippet[]) => {
          Row({ space: 6 }) {
            ForEach(row, (item: MdSnippet) => {
              // 格宽取**整个面板**的最长标签（panelGrid），不是本组、更不是本行的：
              // 分组不同就不同宽会让按钮大小一眼看过去不统一
              this.barCell(item, this.panelGrid().cellVp)
            }, (item: MdSnippet) => item.key)
          }
          .width('100%')
          .justifyContent(FlexAlign.Start)
        }, (row: MdSnippet[]) => row.map((it: MdSnippet) => it.key).join('+'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /**
   * 单颗按钮（图标 + 文案；符号组无图标，字符本身放大当脸）。
   * 长按弹气泡说明、松手消失（用户要求）。
   * ⚠️ 气泡与手势挂在**外层包装 Column** 上：ImmersiveChip 带尾随闭包之后不能再
   *    链式属性（编译错误），而且公共组件里也不该为这一个页面加长按逻辑。
   */
  @Builder
  barCell(item: MdSnippet, cellVp: number) {
    Column() {
      ImmersiveChip({
        palette: this.palette(),
        chipLabel: L10n.t(item.label),
        chipPaddingH: 8,
        chipWidth: cellVp,
        chipLabelLeft: true,
        chipFontSize: item.icon === undefined ? 15 : 0,
        chipOnTap: (): void => {
          this.insertSnippet(item);
        }
      }) {
        if (item.icon !== undefined) {
          Image(item.icon)
            .width(15)
            .height(15)
            .fillColor(this.palette().accent)
        }
      }
    }
    .width(cellVp)
    .bindPopup(this.tipKey === item.key, {
      message: this.tipFor(item),
      placement: Placement.Top
    })
    // **priorityGesture 而不是 gesture**：长按挂在包装 Column（父），点击在芯片内部（子）。
    // 默认的父子手势竞争是"子优先"，于是长按 260ms 触发气泡后，抬手时子组件的
    // onClick 仍会执行 —— 想看说明结果把片段插进了正文。父组件用 priorityGesture
    // 抢先识别（SDK common.d.ts:19034），长按成功后子组件的点击不再响应。
    .priorityGesture(
      LongPressGesture({ repeat: false, duration: 260 })
        .onAction(() => {
          this.tipKey = item.key;
        })
        .onActionEnd(() => {
          this.tipKey = '';
        })
        .onActionCancel(() => {
          this.tipKey = '';
        })
    )
  }

  /** 按 size 切行。 */
  private chunkRows(items: MdSnippet[], size: number): MdSnippet[][] {
    const rows: MdSnippet[][] = [];
    for (let i = 0; i < items.length; i += size) {
      rows.push(items.slice(i, i + size));
    }
    return rows;
  }

  // ══════════════════════ 底部状态栏 ══════════════════════

  @Builder
  bottomBar() {
    ImmersiveBar({ palette: this.palette(), barPaddingH: HwSpace.md, barPaddingV: HwSpace.xs }) {
      Text(this.stats())
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
        .fontColor(this.palette().textSecondary)
        .constraintSize({ maxWidth: 120 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // 右侧芯片整排**横向滑动**（与上方片段条同一交互；用户反馈 4 颗 chip 全挤一起）：
      // 占满统计文字之外的剩余宽度，chip 多了滑出来选
      Scroll() {
        Row({ space: HwSpace.xs }) {
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: L10n.t('专注'),
            chipOnTap: () => {
              // 焦点写作（批 5）：隐藏顶栏 / 底部工具层，只留正文
              this.getUIContext().animateTo(AppearanceFx.anim(240, Curve.FastOutSlowIn), () => {
                this.focusMode = true;
              });
            }
          })

          ImmersiveChip({
            palette: this.palette(),
            chipActive: this.dirty,
            chipLabel: this.dirty ? L10n.t('未保存') : (this.isNew ? L10n.t('新文档') : L10n.t('已保存')),
            chipOnTap: () => {
              this.save();
            }
          })

          ImmersiveChip({
            palette: this.palette(),
            chipActive: this.splitMode > 0,
            chipLabel: this.splitMode === 1 ? L10n.t('上下分屏') : (this.splitMode === 2 ? L10n.t('左右分屏') : L10n.t('分屏')),
            chipOnTap: () => {
              this.cycleSplit();
            }
          })

          ImmersiveChip({
            palette: this.palette(),
            chipLabel: L10n.t('目录'),
            chipOnTap: () => {
              this.insertToc();
            }
          }) {
            SymbolGlyph($r('sys.symbol.list_bullet'))
              .fontSize(13)
              .fontColor([this.palette().accent])
          }

          ImmersiveChip({
            palette: this.palette(),
            chipLabel: L10n.t('大纲'),
            chipOnTap: () => {
              this.openOutline();
            }
          }) {
            SymbolGlyph($r('sys.symbol.list_bullet'))
              .fontSize(13)
              .fontColor([this.palette().accent])
          }

          ImmersiveChip({
            palette: this.palette(),
            chipLabel: L10n.t('语法'),
            chipOnTap: () => {
              this.openSyntax();
            }
          }) {
            SymbolGlyph($r('sys.symbol.book'))
              .fontSize(13)
              .fontColor([this.palette().accent])
          }
        }
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.End)
      // **圆弧裁切**（用户要求）：chip 滑入/滑出的交界处按胶囊弧线收，不再是直角
      .borderRadius(HwRadius.pill)
      .clip(true)
    }
  }

  // ══════════════════════ 语法速查 ══════════════════════

  /** 速查行语法 → 解析后的块（按 syntax 缓存，避免每次渲染重复解析） */
  private syntaxBlocks(syntax: string): MdBlock[] {
    const hit: MdBlock[] | undefined = syntaxBlockCache.get(syntax);
    if (hit !== undefined) {
      return hit;
    }
    let out: MdBlock[] = [];
    try {
      out = MdParser.parse(syntax).blocks;
    } catch (err) {
      out = [];
    }
    syntaxBlockCache.set(syntax, out);
    return out;
  }

  /**
   * 版本历史面板：外层是键盘垫高（BindSheet 不参与平台键盘避让，见 ModalSheet 的
   * SheetKeyboardLift），内层是快照列表 / **分屏对比视图**（挂在内层 Row 的 bindSheet 上）。
   */
  @Builder
  versionsSheet() {
    SheetKeyboardLift() {
      this.versionsSheetBody()
    }
  }

  @Builder
  versionsSheetBody() {
    if (this.diffFor < 0) {
      // ── 快照列表（竖向滚动）──
      Scroll() {
      Column({ space: HwSpace.md }) {
        // ── 自动保存设置 ──
        Row({ space: HwSpace.sm }) {
          Column({ space: 2 }) {
            Text(L10n.t('自动保存版本'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
              .fontColor(this.palette().textPrimary)
            Text(L10n.t('按下面的间隔记录快照，内容没变化不重复记'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Toggle({ type: ToggleType.Switch, isOn: this.versionAutoSave })
            .onChange((isOn: boolean) => {
              this.versionAutoSave = isOn;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.versionAutoSave) {
          Row({ space: HwSpace.xs }) {
            Text(L10n.t('间隔'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.versionInterval === 1,
              chipLabel: L10n.t('1 分钟'),
              chipOnTap: () => {
                this.versionInterval = 1;
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.versionInterval === 5,
              chipLabel: L10n.t('5 分钟'),
              chipOnTap: () => {
                this.versionInterval = 5;
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.versionInterval === 10,
              chipLabel: L10n.t('10 分钟'),
              chipOnTap: () => {
                this.versionInterval = 10;
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.versionInterval === 30,
              chipLabel: L10n.t('30 分钟'),
              chipOnTap: () => {
                this.versionInterval = 30;
              }
            })
          }
          .width('100%')
        }

        Divider().strokeWidth(1).color(this.palette().divider)

        if (this.versionList.length === 0) {
          Text(L10n.t('还没有快照。手动保存或自动保存后会出现在这里'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .width('100%')
        }
        ForEach(this.versionList, (v: VersionSnapshot) => {
          Row({ space: HwSpace.sm }) {
            Column({ space: 2 }) {
              Text(this.versionTime(v.ts))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
                .fontColor(this.palette().textPrimary)
              Text(this.versionMeta(v.ts))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            ImmersiveChip({
              palette: this.palette(),
              chipLabel: L10n.t('对比'),
              chipOnTap: () => {
                this.startDiff(v.ts);
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: L10n.t('恢复'),
              chipOnTap: () => {
                this.restoreVersion(v.ts);
              }
            })
          }
          .width('100%')
          .padding({ top: HwSpace.xs, bottom: HwSpace.xs })
        }, (v: VersionSnapshot) => 'v' + v.ts)
      }
      .width('100%')
      .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.sm, bottom: HwSpace.lg })
      .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    } else {
      // ── 对比视图（**恢复单栏**，用户要求）：旧快照 vs 当前内容，一行一行带红绿标记 ──
      // ⚠️ 必须有外层 Scroll + Column 包裹：@Builder 多根并列在 bindSheet 里渲染为空白（踩过）
      Scroll() {
      Column({ space: HwSpace.xs }) {
      Row({ space: HwSpace.xs }) {
        ImmersiveChip({
          palette: this.palette(),
          chipLabel: L10n.t('返回列表'),
          chipOnTap: () => {
            this.diffFor = -1;
          }
        })
        Text(L10n.t('红色 = 旧版独有 · 绿色 = 当前独有'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')

      ForEach(this.diffRows, (r: DiffRow, index: number) => {
        Row({ space: HwSpace.xs }) {
          Text(r.tag === 'del' ? '−' : (r.tag === 'add' ? '+' : ' '))
            .fontSize(HwType.caption)
            .fontWeight(FontWeight.Bold)
            .fontColor(r.tag === 'del' ? '#FFD93B3B' : (r.tag === 'add' ? '#FF2E7D4F' : this.palette().textTertiary))
            .width(14)
            .textAlign(TextAlign.Center)
          Text(r.text.length > 0 ? r.text : ' ')
            .fontSize(HwType.caption)
            .fontColor(r.tag === 'same' ? this.palette().textSecondary : this.palette().textPrimary)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: HwSpace.xs, right: HwSpace.xs, top: 3, bottom: 3 })
        .borderRadius(HwRadius.inner)
        .backgroundColor(r.tag === 'del' ? '#1AD93B3B' : (r.tag === 'add' ? '#1A2E7D4F' : '#00000000'))
        .alignItems(VerticalAlign.Top)
      }, (r: DiffRow, index: number) => 'd' + index + '_' + r.tag)
      }
      .width('100%')
      .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.sm, bottom: HwSpace.lg })
      .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    }
  }

  /** 快照条目的副标题：N 字 + 相对上一条（更旧的）快照的行数增减。 */
  private versionMeta(ts: number): string {
    let out: string = '';
    let cur: VersionSnapshot | null = null;
    let older: VersionSnapshot | null = null;
    for (let k = 0; k < this.versionList.length; k++) {
      if (this.versionList[k].ts === ts) {
        cur = this.versionList[k];
        if (k + 1 < this.versionList.length) {
          older = this.versionList[k + 1];
        }
        break;
      }
    }
    if (cur !== null) {
      out += cur.chars + ' 字';
    }
    if (cur !== null && older !== null) {
      const curLines: number = cur.content.split('\n').length;
      const olderLines: number = older.content.split('\n').length;
      const delta: number = curLines - olderLines;
      if (delta > 0) {
        out += ' · +' + delta + ' 行';
      } else if (delta < 0) {
        out += ' · −' + (-delta) + ' 行';
      }
    }
    return out;
  }

  /** bindSheet 的内容包装：键盘垫高（BindSheet 不参与平台键盘避让，见
   *  ModalSheet 的 SheetKeyboardLift）+ 语法速查整页滚动。
   *  **左右内边距 + 底部留白**：之前内容铺满整宽，卡片直接贴到屏幕边缘
   *  （用户反馈）；底部留白避免最后一张卡被手势条 / 面板圆角压住。 */
  @Builder
  syntaxSheet() {
    SheetKeyboardLift() {
      this.syntaxSheetBody()
    }
  }

  @Builder
  syntaxSheetBody() {
    Scroll() {
      Column() {
        this.syntaxPanel()
      }
      .width('100%')
      .padding({
        left: HwSpace.lg,
        right: HwSpace.lg,
        top: HwSpace.sm,
        bottom: HwSpace.xl
      })
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  @Builder
  syntaxPanel() {
    // 标题栏由 ModalSheet 官方标题区提供，这里只输出语法行内容。
    Column({ space: HwSpace.md }) {
        // **操作提示放在内容里**：官方标题栏的副标题在手机端只有一行、
        // 长句会被截断（用户反馈「看不到全部内容」）——这里完整显示。
        Text(L10n.t('点任意一行即可插入到光标位置；末尾的「语法教程」有完整示例。'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
          .lineHeight(HwFont.sx(HwType.caption * 1.6, this.uiFontScale))
          .width('100%')

        // 语法口径与示例说明的参考来源（用户要求注明）
        Text(L10n.t('语法分类与说明参考：younghz/Markdown（github.com/younghz/Markdown），') +
          '并按澄笺支持的范围补充了提示块 / 脚注 / 公式 / 图表等扩展语法。')
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption - 0.5, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
          .lineHeight(HwFont.sx(HwType.caption * 1.6, this.uiFontScale))
          .width('100%')
          .padding(HwSpace.xs)
          .borderRadius(HwRadius.inner)
          .backgroundColor(this.palette().quoteBg)

        ForEach(SYNTAX_ROWS, (row: SyntaxRow, index: number) => {
          Column({ space: HwSpace.xxs }) {
            Text(row.syntax)
              .fontSize(HwType.label)
              .fontColor(this.palette().accent)
              .width('100%')
            Text(row.desc)
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textSecondary)
              .lineHeight(HwFont.sx(HwType.caption * 1.6, this.uiFontScale))
              .width('100%')

            // **效果预览**：用应用自己的解析器 + 渲染器把该行语法真实渲染出来
            // （解析结果按 syntax 缓存，只解析一次）
            Column({ space: HwSpace.xxs }) {
              Text(L10n.t('效果'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.caption - 1, this.uiFontScale))
                .fontColor(this.palette().textTertiary)
              ForEach(this.syntaxBlocks(row.syntax), (b: MdBlock) => {
                MdBlockView({
                  block: b,
                  palette: this.palette(),
                  bodySize: HwType.label,
                  lineMul: 1.4,
                  fontKey: this.bodyFontKey,
                  uiFontKey: this.uiFontKey,
                  uiFontScale: this.uiFontScale,
                  uiFontWeightDelta: this.uiFontWeightDelta,
                  bodyWeightMode: this.bodyWeightMode,
                  dark: this.isDark(),
                  // **必须传放大回调**（用户反馈：流程图那行的放大按钮点了没反应）——
                  // MdBlockView 的 enlargeHandler / imageTapHandler 不传就是默认空实现，
                  // 卡片右上角的放大钮成了摆设（预览区那处此前也漏传，同因）。
                  enlargeHandler: (mode: string, payload: string, geoKey: string, title: string) => {
                    this.openPreviewImagePayload(mode, payload);
                  },
                  imageTapHandler: (key: string, src: string) => {
                    this.openPreviewImagePayload('image', src);
                  },
                  aiAskHandler: (text: string) => {
                    this.openAiChat(text);
                  }
                })
                .width('100%')
              }, (b: MdBlock) => row.syntax + '_' + b.id)
            }
            .width('100%')
            .padding(HwSpace.sm)
            .borderRadius(HwRadius.inline)
            .backgroundColor(this.palette().pageTop)
          }
          .width('100%')
          .padding(HwSpace.sm)
          .borderRadius(HwRadius.inline)
          .backgroundColor(this.palette().quoteBg)
          // **点整行插入到光标位置**：面板顶部那句"点任意一行即可插入到光标位置"
          // 一直是空头承诺 —— 这里此前根本没有 onClick，点上去毫无反应。
          // 行内的链接 / 图片 / 图表按钮由它们自己先消费点击，不受影响。
          .onClick(() => {
            this.insertSyntax(row.syntax);
          })
        }, (row: SyntaxRow, index: number) => 's' + index)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
  }

  // （旧 findPanel 大面板已删除：查找替换改为顶栏下方的胶囊浮窗）

  // ══════════════════════ 组装 ══════════════════════

  /** 页面转场：标准滑入/滑出（替代默认交叉淡化——两页半透明叠加会出双影）。 */
  /** 页面转场：标准滑入/滑出（交叉淡化会让两页半透明叠成双影）。 */
  pageTransition() {
    // push：新页从右滑入；旧页向左视差退场
    PageTransitionEnter({ type: RouteType.Push, duration: 300, curve: Curve.FastOutSlowIn })
      .translate({ x: '100%' })
    PageTransitionExit({ type: RouteType.Push, duration: 300, curve: Curve.FastOutSlowIn })
      .translate({ x: '-30%' })
    // pop：本页从左滑回；被返回的页向右退场
    PageTransitionEnter({ type: RouteType.Pop, duration: 280, curve: Curve.FastOutSlowIn })
      .translate({ x: '-30%' })
    PageTransitionExit({ type: RouteType.Pop, duration: 280, curve: Curve.FastOutSlowIn })
      .translate({ x: '100%' })
  }


  // ══════════════════════ 分屏实时预览 ══════════════════════

  /**
   * 编辑区（纯编辑与分屏共用）。
   *
   * **首尾空白跟随页面滚动**（用户要求，不是固定内边距）：
   * `Scroll { 顶部空白 + 自适应高度的 TextArea + 底部空白 }`。
   * SDK 明确语义：TextArea **不设高度时高度随内容自适应**（见 text_area.d.ts：
   * "If the component does not have its height set, it adapts its height to the content"），
   * 所以整块内容只有一个滚动条，两段空白属于内容、跟着一起滑走：
   *   · 初始第一行落在顶栏胶囊下方（不被压住）；
   *   · 滚到最底时最后一行停在底部工具层上方（不被遮挡）；
   *   · 滑动过程中文字从两条悬浮栏底下穿过显示（玻璃透字）。
   */
  @Builder
  editorArea() {
    Scroll() {
      Column() {
        // 顶部空白：随内容滚动（滚上去就让出胶囊区域）
        Column()
          .width('100%')
          .height(this.contentTopInset())

        TextArea({ text: this.content, placeholder: L10n.t('在这里写 Markdown……') })
          .width('100%')
          // **刻意不设高度 / layoutWeight**：由 TextArea 按内容自适应撑开，
          // 内部不再有第二个滚动条，空白才能真正"跟着滑动"
          .fontSize(this.fontSize * 0.94)
          .fontColor(this.palette().textPrimary)
          .placeholderColor(this.palette().textTertiary)
          .backgroundColor('#00000000')
          .borderRadius(0)
          .padding({ left: this.editorHPad(), right: this.editorHPad() })
          .onChange((value: string) => {
            this.content = value;
            this.dirty = true;
            // 分屏模式下实时刷新预览（纯编辑模式的预览在切换时才解析）
            if (this.splitMode > 0) {
              this.refreshPreviewBlocks();
            }
            // 双链补全：刚敲下 `[[` 或继续打字时重算候选
            this.refreshLinkPick();
          })
          .onTextSelectionChange((selectionStart: number, selectionEnd: number) => {
            this.caret = selectionStart;
            // 选区末端也记下来：Ctrl+B / Ctrl+I 要给"选中的那段"加标记
            this.caretEnd = selectionEnd;
            // 光标移动也可能进/出 `[[` 语境（比如用方向键退回去）
            this.refreshLinkPick();
          })
          .onPaste((value: string, event: PasteEvent) => {
            this.onEditorPaste();
          })

        // 底部空白：随内容滚动（滚到底再往上滑一段，末行离开工具层）
        Column()
          .width('100%')
          .height(this.contentBottomInset())
      }
      .width('100%')
      // 内容不足一屏时也要撑满，且**顶对齐**（Scroll 默认把不足一屏的内容垂直居中）
      .constraintSize({ minHeight: '100%' })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    // **撑满高度**：左右分屏时本组件挂在 Row 里，没有显式高度会被 Row
    // 按内容高居中（用户反馈：分屏预览内容「居中」而非从上往下）。
    // 上下分屏 / 纯预览里 layoutWeight 在主轴优先生效，height('100%') 不冲突。
    .height('100%')
    .align(Alignment.Top)
  }

  /** 预览区（纯预览与分屏共用） */
  @Builder
  previewArea() {
    List({ space: 0 }) {
      // 顶部空白：**随内容滚动**的留白（不是固定 padding）。
      // 与阅读页首屏占位条目同款：初始第一块落在顶栏胶囊下方，
      // 滑走之后正文占满胶囊区域、从顶栏底下穿过显示
      ListItem() {
        Column()
          .width('100%')
          .height(this.contentTopInset())
      }

      ForEach(this.previewBlocks, (block: MdBlock) => {
        ListItem() {
          MdBlockView({
            block: block,
            palette: this.palette(),
            bodySize: this.fontSize,
            lineMul: this.lineMul,
            fontKey: this.bodyFontKey,
            uiFontKey: this.uiFontKey,
            uiFontScale: this.uiFontScale,
            uiFontWeightDelta: this.uiFontWeightDelta,
            bodyWeightMode: this.bodyWeightMode,
            // **预览里的待办清单要能勾选**（用户反馈：待办点了没反应）——
            // 勾选直接改对应源码行的 [ ]↔[x]，与就地编辑同一套数据。
            taskToggleHandler: (blockId: string): void => {
              this.togglePreviewTask(blockId);
            },
            // **预览里的图片卡片要能放大**（用户反馈：卡片的放大按钮点了没反应）——
            // 此前这两个回调没传，MdBlockView 用的是默认空实现，所以点右上角放大钮
            // 与点图片本体都毫无反应。这里接到编辑页既有的图片浮层上（可捏合 / 拖动）。
            enlargeHandler: (mode: string, payload: string, geoKey: string, title: string) => {
              if (mode === 'image') {
                this.previewImgScale = 1;
                this.previewImgDx = 0;
                this.previewImgDy = 0;
                this.previewImage = payload;
              }
            },
            imageTapHandler: (key: string, src: string) => {
              this.previewImgScale = 1;
              this.previewImgDx = 0;
              this.previewImgDy = 0;
              this.previewImage = src;
            },
            aiAskHandler: (text: string) => {
              // 预览列表长按「发送AI」（1.2.0）
              this.openAiChat(text);
            }
          })
        }
      }, (block: MdBlock) => {
        // 读取公式就绪信号建立依赖：图就绪 → 该块重建 → 文字换成图
        const ft: number = this.formulaTick;
        return 'p_' + block.id + '_' + this.renderEpoch + (ft >= 0 ? this.formulaSuffix(block) : '')
          + (block.task === MdTaskState.Done ? '_d' : (block.task === MdTaskState.Todo ? '_t' : ''));
      })
      ListItem() {
        Text(L10n.t('—— 预览结束 ——'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
          .width('100%')
          .textAlign(TextAlign.Center)
          // 文末留白放在条目自身（与阅读页一致）：List 的 padding 是裁剪边界，
          // 留白必须属于内容才跟着滑动；滚到最底时末行停在底部工具层上方
          .padding({ top: HwSpace.xl, bottom: this.contentBottomInset() })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    // **撑满高度**：左右分屏时挂在 Row 里，内容不足一屏会被居中（同上）；
    // List 撑满后内容天然从顶部往下排（用户反馈）
    .height('100%')
    .alignListItem(ListItemAlign.Start)
    .padding({ left: this.editorHPad(), right: this.editorHPad() })
  }

  /**
   * **实时预览区**（块级所见即所得）。
   *
   * 每一块都包一层可点击外壳：点它 → 该块就地展开成源码编辑，改完立刻变回渲染态。
   * 表格由 MdBlockView 内部的点击事件接管（走网格编辑器），不会被外层抢走。
   */
  @Builder
  liveArea() {
    List({ space: 0, scroller: this.liveScroller }) {
      ListItem() {
        Column()
          .width('100%')
          .height(this.contentTopInset())
      }

      // 即时渲染（IR）：整页源码置顶，下方渲染块随输入防抖更新
      if (this.previewMode === 2) {
        ListItem() {
          Column({ space: HwSpace.xs }) {
            Text(L10n.t('即时渲染 · 直接改源码，下方实时预览'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
            TextArea({ text: this.irDraft })
              .width('100%')
              .height(230)
              .fontSize(HwType.label + 1)
              .fontColor(this.palette().textPrimary)
              .backgroundColor(this.palette().quoteBg)
              .borderRadius(HwRadius.inner)
              .onChange((v: string) => {
                this.onIrInput(v);
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ bottom: HwSpace.sm })
        }
      }

      // 常驻用法提示（编辑态时不显示，免得跟着滚动干扰）：正文明明是渲染态，
      // 不写清楚"可以点"，很容易以为只能看
      if (this.liveEditing < 0 && this.previewBlocks.length > 0) {
        ListItem() {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.square_and_pencil'))
              .fontSize(12)
              .fontColor([this.palette().textTertiary])
            Text(L10n.t('点任意一块即可就地编辑 · 表格点开是网格 · 代码块带实时预览'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
              .layoutWeight(1)
              .maxLines(2)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ bottom: HwSpace.sm })
        }
      }

      ForEach(this.previewBlocks, (block: MdBlock, index: number) => {
        ListItem() {
          if (index === this.liveEditing) {
            // 包一层壳：① 让编辑区有明确的"卡片"边界（与渲染态一眼区分）
            //          ② 挂进出场过渡（编辑态展开 / 收起不能是硬切）
            Column() {
              LiveBlockEditor({
                block: block,
                index: index,
                palette: this.palette(),
                bodySize: this.fontSize,
                lineMul: this.lineMul,
                fontKey: this.bodyFontKey,
                renderEpoch: this.renderEpoch,
                formulaTick: this.formulaTick,
                previewTick: this.livePreviewTick,
                previewBlocks: this.livePreviewBlocks,
                draft: $liveDraft,
                onDelete: (i: number): void => {
                  this.deleteBlockAt(i);
                },
                onCommit: (): void => {
                  this.commitBlockEdit();
                },
                onDraftChange: (value: string): void => {
                  this.dirty = true;
                  // **所有块都刷新预览**（段落 / 标题 / 列表 / 引用同样要即时反馈）
                  this.refreshLivePreview();
                }
              })
            }
            .width('100%')
            .borderRadius(HwRadius.card)
            // 编辑态用**实线**描边 + 底色：与渲染态的虚线区分开
            .border({ width: 1, color: this.palette().accentSoft })
            .backgroundColor(this.palette().surface)
            .padding({ left: HwSpace.sm, right: HwSpace.sm })
            // **与上下相邻段落留出空隙**（用户反馈：引用这类带底色的卡片会与
            // 编辑框贴在一起，两块糊成一坨）—— 编辑框是"卡片"，
            // 相邻块也多是卡片（引用 / 提示块 / 代码块），必须有外边距才分得开
            .margin({ top: HwSpace.sm, bottom: HwSpace.sm })
            .transition(TransitionEffect.asymmetric(
              TransitionEffect.scale({ x: 0.985, y: 0.985 }).combine(TransitionEffect.OPACITY)
                .animation(AppearanceFx.anim(220, Curve.FastOutSlowIn)),
              TransitionEffect.OPACITY.animation(AppearanceFx.anim(140, Curve.FastOutSlowIn))))
          } else {
            Column() {
              MdBlockView({
                block: block,
                palette: this.palette(),
                bodySize: this.fontSize,
                lineMul: this.lineMul,
                fontKey: this.bodyFontKey,
                uiFontKey: this.uiFontKey,
                uiFontScale: this.uiFontScale,
                uiFontWeightDelta: this.uiFontWeightDelta,
                bodyWeightMode: this.bodyWeightMode,
                // **预览里的待办清单要能勾选**（用户反馈：待办点了没反应）——
                // 勾选直接翻转对应源码行的 [ ]↔[x]；同时置 liveChildTap，
                // 防止这次点击冒泡到外层、误触"整块进入编辑态"。
                taskToggleHandler: (blockId: string): void => {
                  this.markChildTap();
                  this.togglePreviewTask(blockId);
                },
                tableEditHandler: (blockId: string): void => {
                  this.markChildTap();
                  this.openLiveTable(index);
                },
                enlargeHandler: (mode: string, payload: string, geoKey: string, title: string): void => {
                  this.markChildTap();
                  if (mode === 'image') {
                    this.previewImgScale = 1;
                    this.previewImgDx = 0;
                    this.previewImgDy = 0;
                    this.previewImage = payload;
                  }
                },
                imageTapHandler: (key: string, src: string): void => {
                  this.markChildTap();
                  this.previewImgScale = 1;
                  this.previewImgDx = 0;
                  this.previewImgDy = 0;
                  this.previewImage = src;
                },
                aiAskHandler: (text: string): void => {
                  // 实时预览长按「发送AI」（1.2.0）：与图片点击同一套防冒泡标记
                  this.markChildTap();
                  this.openAiChat(text);
                }
              })
              // 每块末尾的编辑图标：**明确告诉用户"这一块能改"** ——
              // 只靠"点正文"太隐晦（渲染出来的字看着就像只读的）。
              // 它与外层整块点击是两条路径，都会走到 editBlock（同一块、幂等），
              // 用 liveChildTap 标记避免重复触发。
              Row() {
                Blank()
                Row({ space: 4 }) {
                  SymbolGlyph($r('sys.symbol.square_and_pencil'))
                    .fontSize(12)
                    .fontColor([this.palette().textTertiary])
                  Text(L10n.t('编辑'))
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(HwType.caption - 1, this.uiFontScale))
                    .fontColor(this.palette().textTertiary)
                }
                .padding({ left: 8, right: 4, top: 3, bottom: 3 })
                .opacity(0.6)
                .onClick(() => {
                  this.markChildTap();
                  this.editBlock(index);
                })
              }
              .width('100%')
            }
            .width('100%')
            // **每段的虚线边界**（用户要求）：正文渲染出来是连续一片，
            // 分不清"这一段的编辑按钮管的是上面还是下面"——
            // 虚线画在**包含编辑图标的整段容器**底部，图标归属一眼可见。
            .border({
              width: { bottom: 1 },
              color: this.palette().divider,
              style: BorderStyle.Dashed
            })
            .padding({ bottom: HwSpace.xs })
            // 点整块 → 进这一块的编辑态。
            // ⚠️ ArkUI 的 onClick **没有 stopPropagation**（子先父后都会执行）：
            // 块内部的图片 / 表格 / 放大按钮、以及上面的编辑图标点过后会置
            // `liveChildTap`，这里读到就复位并跳过，避免一次点击进两次编辑态。
            .onClick(() => {
              if (this.liveChildTap && Date.now() - this.liveChildTapAt < 700) {
                this.liveChildTap = false;
                return;
              }
              this.liveChildTap = false;
              this.editBlock(index);
            })
            // 退出编辑态后本段重新挂载：淡入，避免"啪"地一下换回来
            .transition(TransitionEffect.OPACITY.animation({
              duration: 180, curve: Curve.FastOutSlowIn
            }))
          }
        }
      }, (block: MdBlock, index: number) => {
        const ft: number = this.formulaTick;
        return 'L_' + index + '_' + block.id + '_' + this.renderEpoch + (ft >= 0 ? this.formulaSuffix(block) : '')
          + (block.task === MdTaskState.Done ? '_d' : (block.task === MdTaskState.Todo ? '_t' : ''))
          + '_c' + this.liveCommitTick;
      })

      // 文末**正在新建的那一块**：还没写进正文（也没有对应的渲染块），
      // 属于内存态的编辑项 —— 用户输入完成才落到原文，空着就丢弃。
      // 索引用 `previewBlocks.length` 表示"新块"，是这套机制的唯一约定。
      // ⚠️ key 带 liveCommitTick：提交/删除后强制整列表按新内容重建，
      // 否则 ForEach 复用旧节点 = "完成后不刷新 / 点两次才进编辑"（用户实测）。
      if (this.liveEditing >= this.previewBlocks.length && this.liveEditing >= 0) {
        ListItem() {
          Column() {
            LiveBlockEditor({
              block: emptyBlock(),
              index: this.liveEditing,
              palette: this.palette(),
              bodySize: this.fontSize,
              lineMul: this.lineMul,
              fontKey: this.bodyFontKey,
              renderEpoch: this.renderEpoch,
              previewBlocks: this.livePreviewBlocks,
              draft: $liveDraft,
              onDelete: (i: number): void => {
                this.cancelBlockEdit();
              },
              onCommit: (): void => {
                this.commitBlockEdit();
              },
              onDraftChange: (value: string): void => {
                this.dirty = true;
                // 新建段落也实时预览（写 `## 标题` 立刻看到标题样式）
                this.refreshLivePreview();
              }
            })
          }
          .width('100%')
          // 与上方最后一段留出空隙（同正文里的编辑器外壳，避免卡片贴住）
          .margin({ top: HwSpace.sm, bottom: HwSpace.xs })
          // 编辑器内部的点击（输入框、完成、删除）都属于"已消费"，
          // 不要让外层再当成"点空白新建一段"
          .onClick(() => {
            this.markChildTap();
          })
        }
      }

      // 文末「新建段落」：**一大片可点的空白区**（点空白就是新建，符合直觉），
      // 点一下就在末尾出现一块带输入框的编辑项
      ListItem() {
        Column({ space: 6 }) {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(14)
              .fontColor([this.palette().textTertiary])
            Text(L10n.t('点这里新建段落'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
          }
          .alignItems(VerticalAlign.Center)
          .padding({ top: 14, bottom: 14 })
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .borderRadius(HwRadius.inner)
          .border({ width: 1, color: this.palette().divider, style: BorderStyle.Dashed })
        }
        .width('100%')
        // 热区高度给足：正文末尾的"空白处"就是要能点
        .constraintSize({ minHeight: 96 })
        .justifyContent(FlexAlign.Start)
        .padding({ top: HwSpace.sm, bottom: this.contentBottomInset() })
        .onClick(() => {
          this.appendLiveParagraph();
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .height('100%')
    .alignListItem(ListItemAlign.Start)
    .padding({ left: this.editorHPad(), right: this.editorHPad() })
  }

  /**
   * 在文末新建一段并进入编辑（实时预览下的「写下去」入口）。
   *
   * ⚠️ 上一版这里插一个空行再"打开最后一块"，结果是**点了没反应**：
   * 空行不构成新块，`previewBlocks` 长度没变，于是打开的还是原来最后那一块
   * （用户看到的就是"点了没动静"）。现在改成**虚拟新块**：直接把编辑态挂到
   * `previewBlocks.length` 这个越界下标上，界面上立刻出现一个空输入框并自动聚焦，
   * 写完提交时才真正落到原文 —— 没写就什么都不留下。
   */
  private appendLiveParagraph(): void {
    if (this.liveEditing >= 0 && this.liveEditing < this.previewBlocks.length) {
      // 先把手头这块提交掉，避免草稿悬空
      this.commitBlockEdit();
    }
    this.liveAnchor = -1;
    this.liveChildTap = false;
    this.liveDraft = '';
    this.livePreviewBlocks = [];
    this.liveEditing = this.previewBlocks.length;
    // 新块在末尾：等它挂载完再带进可视区（与进编辑态同一条路径）
    setTimeout(() => {
      this.scrollLiveToEditing();
    }, 160);
  }

  /**
   * 列表里正文块之前有几个占位项（顶部空白 + 用法提示）。
   * 用 scrollToIndex 时必须加上，否则会滚到错位的块上（差一两条）。
   */
  private liveListOffset(): number {
    const tip: number = (this.liveEditing < 0 && this.previewBlocks.length > 0) ? 1 : 0;
    return 1 + tip;
  }

  /**
   * 实时预览里的**待办勾选**（用户反馈：待办点了没反应）——
   * 按块 id 找到对应源码行，把 `[ ]` ↔ `[x]` 翻转后整体回写 this.content：
   * 与就地编辑同一套数据，后续保存自然带上。
   */
  private togglePreviewTask(blockId: string): void {
    let at: number = -1;
    for (let k = 0; k < this.previewBlocks.length; k++) {
      if (this.previewBlocks[k].id === blockId) {
        at = k;
        break;
      }
    }
    if (at < 0) {
      return;
    }
    const block: MdBlock = this.previewBlocks[at];
    if (block.task !== MdTaskState.Todo && block.task !== MdTaskState.Done) {
      return;
    }
    const lines: string[] = this.content.split('\n');
    // 块的 srcLine 是 **0 起**（与 Reader 的任务跳转同一口径）
    const i: number = block.srcLine;
    if (i < 0 || i >= lines.length) {
      return;
    }
    if (lines[i].indexOf('[ ]') >= 0) {
      lines[i] = lines[i].replace('[ ]', '[x]');
    } else if (lines[i].indexOf('[x]') >= 0 || lines[i].indexOf('[X]') >= 0) {
      lines[i] = lines[i].replace('[x]', '[ ]').replace('[X]', '[ ]');
    } else {
      return;
    }
    this.content = lines.join('\n');
    this.dirty = true;
    this.refreshPreviewBlocks();
    // ⚠️ 这里**不要** renderEpoch++：那会把整个预览列表的 key 全部换掉、
    // 整列表重建 = 屏幕闪一下（用户反馈）。勾选状态已并入 ForEach 的
    // key 后缀（任务态标记），只有被勾选的那一块会重建。
  }

  /** 解析当前内容供预览区渲染 */
  private refreshPreviewBlocks(): void {
    try {
      const parsed: MdParseResult = MdParser.parse(this.content);
      this.previewBlocks = parsed.blocks;
    } catch (err) {
      this.previewBlocks = [];
    }
    // 预览内容一变就重收公式任务（预览区的 $公式$ 与阅读页同款出图）
    this.syncFormulaTasks();
  }

  /** 收集预览块里的行内公式图任务（缓存键含字号；未就绪时回落线性化文本）。 */
  private syncFormulaTasks(): void {
    // **正在编辑块的迷你预览也要收**（用户要求：实时预览编辑里输入的 $公式$
    // 立刻渲染成公式图）——livePreviewBlocks 是编辑草稿的解析结果。
    const tasks: FormulaTask[] = FormulaTasks.collect(this.previewBlocks, this.isDark(), this.fontSize);
    const live: FormulaTask[] = FormulaTasks.collect(this.livePreviewBlocks, this.isDark(), this.fontSize);
    for (let k: number = 0; k < live.length; k++) {
      let dup: boolean = false;
      for (let q: number = 0; q < tasks.length; q++) {
        if (tasks[q].key === live[k].key) {
          dup = true;
          break;
        }
      }
      if (!dup) {
        tasks.push(live[k]);
      }
    }
    this.formulaTasks = tasks;
  }

  /** 预览块 key 的"公式就绪位"后缀（图就绪 → 该块重建 → 文字换成图）。 */
  private formulaSuffix(block: MdBlock): string {
    return FormulaTasks.readySuffix(this.ctx(), block, this.isDark(), this.fontSize);
  }

  // ══════════════════════ 实时预览编辑（块级所见即所得）══════════════════════
  //
  // 与分屏预览的区别：这里是**单栏**，正文始终以渲染结果呈现，点哪块就编辑哪块。
  // 三类块有专属编辑方式：
  //   · 表格 → 网格编辑器（TableEditorDialog，已有组件）；
  //   · 代码 / 图表 / 公式 → 源码编辑，编辑态下方同步显示这块渲染出来什么样；
  //   · 其余（标题、段落、列表、引用…）→ 直接改 Markdown 源码。
  // 改动一律写回**原文行区间**，不重建整篇，所以不会打乱别处的内容与行号。

  /** 切换实时预览：进入时解析一次，退出时收起编辑态。 */
  private toggleLive(): void {
    this.liveEditing = -1;
    this.liveDraft = '';
    this.liveMode = !this.liveMode;
    if (this.liveMode) {
      // 分屏优先于实时预览（build 的分支顺序），进实时预览必须先退回单栏，
      // 否则点了按钮界面没变化 —— 这类"点了没反应"最难自查
      this.splitMode = 0;
      this.preview = false;
      this.refreshPreviewBlocks();
      // 首次进入给一次用法提示：功能是"点块编辑"，不说明很容易以为点了没反应
      if (!this.liveTipShown) {
        this.liveTipShown = true;
        this.toast(L10n.t('点正文任意一块即可编辑 · 表格点开是网格 · 代码块带实时预览'));
      }
    }
  }

  // ══════════════════════ 大纲重排（整节拖动换序） ══════════════════════
  //
  // 写长文最常见的整理动作是"把某一节挪到别处"。整节 = 标题 + 它的**全部子树**
  // （直到遇到同级或更高级的标题为止），这样拖一个二级标题不会把它下面的三级标题落下。
  // 移动只改**源码行区间**，不重建整篇 —— 与块级编辑同一套地基（MdParser.blockSrcRange）。

  /** 大纲面板是否打开 */
  @State outlineOpen: boolean = false;
  /** 大纲重建纪元：移动一节后 ++，列表按新顺序重排 */
  @State outlineEpoch: number = 0;
  /** 当前解析出的大纲（打开面板 / 移动后重算） */
  @State outlineItems: MdHeading[] = [];
  /** 拖拽起点（List 的 onItemDragStart 记下，drop 时用来算移动） */
  private outlineDragFrom: number = -1;

  /** 重算大纲（基于当前正文）。 */
  private refreshOutline(): void {
    try {
      const parsed: MdParseResult = MdParser.parse(this.content);
      this.outlineItems = parsed.outline;
    } catch (err) {
      this.outlineItems = [];
    }
    // 内容变了，块缓存也失效（移动要用最新块与行号）
    this.refreshPreviewBlocks();
  }

  private openOutline(): void {
    this.refreshOutline();
    this.getUIContext().animateTo(AppearanceFx.anim(220, Curve.FastOutSlowIn), () => {
      this.outlineOpen = true;
    });
  }

  private closeOutline(): void {
    this.getUIContext().animateTo(AppearanceFx.anim(180, Curve.FastOutSlowIn), () => {
      this.outlineOpen = false;
    });
  }

  /**
   * 第 `i` 个标题的**整节**在原文里占的行区间 `[start, end)`。
   * 结束边界 = 第一个"层级不比我深"的后续标题；没有就是文末。
   */
  private sectionRange(outline: MdHeading[], blocks: MdBlock[], lineCount: number,
    i: number): MdSrcRange {
    const res: MdSrcRange = { start: 0, end: 0 };
    if (i < 0 || i >= outline.length) {
      return res;
    }
    res.start = MdParser.blockSrcRange(blocks, outline[i].blockIndex, lineCount).start;
    const lvl: number = outline[i].level;
    let to: number = i + 1;
    while (to < outline.length && outline[to].level > lvl) {
      to++;
    }
    res.end = to < outline.length
      ? MdParser.blockSrcRange(blocks, outline[to].blockIndex, lineCount).start
      : lineCount;
    if (res.end < res.start) {
      res.end = res.start;
    }
    return res;
  }

  /**
   * 把第 `from` 个标题的整节移动到"第 `to` 个标题之前"。
   *
   * 实现是纯行数组搬运：剪出这一段 → 在剩余行里算出落点 → 插回去。
   * 落点要按"剪掉之后的行号"折一次（目标在本节之后时前移 S 行），否则会错位。
   */
  private moveSectionTo(from: number, to: number): void {
    if (from < 0 || to < 0 || from >= this.outlineItems.length
      || to > this.outlineItems.length || from === to) {
      return;
    }
    try {
      const parsed: MdParseResult = MdParser.parse(this.content);
      const outline: MdHeading[] = parsed.outline;
      const blocks: MdBlock[] = parsed.blocks;
      const lines: string[] = this.content.split('\n');
      const lineCount: number = lines.length;
      if (from >= outline.length || to > outline.length) {
        return;
      }
      const sec: MdSrcRange = this.sectionRange(outline, blocks, lineCount, from);
      if (sec.end <= sec.start) {
        return;
      }
      const moved: string[] = lines.slice(sec.start, sec.end);
      const rest: string[] = lines.slice(0, sec.start).concat(lines.slice(sec.end));
      // 落点：目标标题原本的起始行；它在被剪掉的段之后时要往前挪
      const rawTarget: number = to < outline.length
        ? MdParser.blockSrcRange(blocks, outline[to].blockIndex, lineCount).start
        : lineCount;
      let at: number = rawTarget;
      if (rawTarget > sec.start) {
        at = rawTarget - moved.length;
      }
      if (at < 0) {
        at = 0;
      }
      if (at > rest.length) {
        at = rest.length;
      }
      const out: string[] = rest.slice(0, at).concat(moved, rest.slice(at));
      this.content = out.join('\n');
      this.dirty = true;
      this.refreshOutline();
      this.outlineEpoch = this.outlineEpoch + 1;
      this.toast('已移动《' + outline[from].text + '》这一节');
    } catch (err) {
      this.toast(L10n.t('移动失败：正文结构异常'));
    }
  }

  /** 上移 / 下移一位（同级或更高级的相邻标题之间换位）。 */
  private moveSectionStep(index: number, dir: number): void {
    if (index < 0 || index >= this.outlineItems.length) {
      return;
    }
    const lvl: number = this.outlineItems[index].level;
    if (dir < 0) {
      // 往前找最近的"层级不比我深"的标题
      let p: number = index - 1;
      while (p >= 0 && this.outlineItems[p].level > lvl) {
        p--;
      }
      if (p < 0) {
        this.toast(L10n.t('已经是第一节了'));
        return;
      }
      this.moveSectionTo(index, p);
    } else {
      // 往后找本节的结束边界（= 下一个同/更高层级标题）
      let n: number = index + 1;
      while (n < this.outlineItems.length && this.outlineItems[n].level > lvl) {
        n++;
      }
      if (n >= this.outlineItems.length) {
        this.toast(L10n.t('已经是最后一节了'));
        return;
      }
      // 移动到"下一节的下一节"之前 = 与下一节交换
      let after: number = n + 1;
      while (after < this.outlineItems.length && this.outlineItems[after].level > this.outlineItems[n].level) {
        after++;
      }
      this.moveSectionTo(index, after);
    }
  }

  /** 拖拽时跟随手指的小卡片（ArkUI 的 List 拖拽要求返回一个 CustomBuilder）。 */
  @Builder
  outlineDragPreview(index: number) {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.list_bullet'))
        .fontSize(13)
        .fontColor([this.palette().accent])
      Text(index >= 0 && index < this.outlineItems.length ? this.outlineItems[index].text : '')
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
        .fontColor(this.palette().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 8, bottom: 8 })
    .borderRadius(HwRadius.inner)
    .backgroundColor(this.palette().surface)
    .border({ width: 1, color: this.palette().accentSoft })
  }

  /** 拖拽用的落点：把 from 那一节插到 insertIndex 位置之前。 */
  private onOutlineDrop(insertIndex: number): void {
    const from: number = this.outlineDragFrom;
    this.outlineDragFrom = -1;
    if (from < 0 || insertIndex < 0) {
      return;
    }
    // 落点在自己之后时，位置要减一（剪掉自己后索引整体前移）
    let to: number = insertIndex > from ? insertIndex - 1 : insertIndex;
    if (to === from) {
      return;
    }
    this.moveSectionTo(from, to);
  }

  // ══════════════════════ 外接键盘快捷键 ══════════════════════
  //
  // 平板 / 折叠屏接键盘的场景下，用鼠标去点片段工具条很别扭。
  // 用 ArkUI 的 keyboardShortcut 绑定（走焦点链，输入框获焦时也生效）：
  //   Ctrl+S 保存 · Ctrl+B 粗体 · Ctrl+I 斜体 · Ctrl+F 查找
  //   Ctrl+↑ / Ctrl+↓ 调正文字号

  /**
   * 给选中文字套一层标记（Ctrl+B / Ctrl+I）。
   * 没有选中内容时插入一对空标记并把光标放中间，直接往里写即可。
   */
  private wrapSelection(mark: string): void {
    const a: number = this.caret >= 0 && this.caret <= this.content.length
      ? this.caret : this.content.length;
    const e: number = this.caretEnd >= 0 && this.caretEnd <= this.content.length
      ? this.caretEnd : a;
    const from: number = Math.min(a, e);
    const to: number = Math.max(a, e);
    const picked: string = this.content.substring(from, to);
    const inserted: string = mark + picked + mark;
    this.content = this.content.substring(0, from) + inserted + this.content.substring(to);
    this.dirty = true;
    // 选中刚插入的整段（含标记），方便继续改或再按一次取消
    this.caret = from;
    this.caretEnd = from + inserted.length;
    setTimeout(() => {
      try {
        this.controller.setTextSelection(from, from + inserted.length);
      } catch (err) {
        // 定位失败不影响内容
      }
    }, 40);
  }

  /** 快捷键调字号（Ctrl+↑ / Ctrl+↓）：与捏合、设置里的滑块共用同一个全局值。 */
  private bumpFontSize(delta: number): void {
    const next: number = Math.max(HwType.bodyMin,
      Math.min(HwType.bodyMax, Math.round(this.fontSize) + delta));
    if (next === this.fontSize) {
      return;
    }
    this.fontSize = next;
    this.toast('正文字号 ' + next);
  }

  // ══════════════════════ 双链自动补全（[[文档名]]） ══════════════════════
  //
  // 写 `[[` 就弹候选：知识网络靠 `[[名称]]` 连起来，而名称打错一个字就变成
  // 指向"不存在文档"的悬空链接（知识图谱里会落进「待补文档」）。
  // 这里把"记得住名字"这件事交给候选列表，顺手把锚点也算成一条候选。

  /**
   * 光标前是否正处在一个**未闭合的 `[[`** 里。
   * 是 → 返回 `[[` 之后、光标之前的查询串；否 → 返回空串（浮窗不显示）。
   */
  private linkQuery(): string {
    if (!this.linkPickAllowed()) {
      return '';
    }
    const pos: number = this.caret >= 0 && this.caret <= this.content.length
      ? this.caret : this.content.length;
    const before: string = this.content.substring(0, pos);
    const open: number = before.lastIndexOf('[[');
    if (open < 0) {
      return '';
    }
    const seg: string = before.substring(open + 2);
    // 已经闭合、跨行、或又出现新的方括号 → 不算在补全场景里
    if (seg.indexOf(']') >= 0 || seg.indexOf('\n') >= 0 || seg.indexOf('[') >= 0) {
      return '';
    }
    if (seg.length > 40) {
      return '';
    }
    return seg;
  }

  /** 只在纯编辑 / 分屏编辑态补全（预览、实时预览里没有源码输入框）。 */
  private linkPickAllowed(): boolean {
    return !this.preview && !this.liveMode;
  }

  /** 重算候选（输入 / 光标移动时调用）。 */
  private refreshLinkPick(): void {
    const q: string = this.linkQuery();
    if (q === '' && !this.linkPickContextOpen()) {
      this.linkPickOpen = false;
      return;
    }
    if (!this.linkPickContextOpen()) {
      this.linkPickOpen = false;
      return;
    }
    const ctx = this.ctx();
    if (ctx === null) {
      this.linkPickOpen = false;
      return;
    }
    const key: string = q.toLowerCase();
    const starts: string[] = [];
    const contains: string[] = [];
    try {
      DocStore.init(ctx);
      const list: DocMeta[] = DocStore.list(ctx);
      for (let k: number = 0; k < list.length; k++) {
        const name: string = list[k].name;
        const lower: string = name.toLowerCase();
        if (key.length === 0) {
          starts.push(name);
        } else if (lower.indexOf(key) === 0) {
          starts.push(name);
        } else if (lower.indexOf(key) > 0) {
          contains.push(name);
        }
        if (starts.length >= 8) {
          break;
        }
      }
    } catch (err) {
      // 取不到列表就不补全
    }
    const out: string[] = [];
    for (let k: number = 0; k < starts.length && out.length < 8; k++) {
      out.push(starts[k]);
    }
    for (let k: number = 0; k < contains.length && out.length < 8; k++) {
      out.push(contains[k]);
    }
    this.linkItems = out;
    this.linkPickOpen = out.length > 0;
  }

  /** 是否处于"刚才打了 `[[`"的语境里（哪怕查询串为空也要把候选弹出来）。 */
  private linkPickContextOpen(): boolean {
    if (!this.linkPickAllowed()) {
      return false;
    }
    const pos: number = this.caret >= 0 && this.caret <= this.content.length
      ? this.caret : this.content.length;
    const before: string = this.content.substring(0, pos);
    // 以 `[[` 结尾 = 刚敲完两个方括号，此时查询串为空
    return before.endsWith('[[') || this.linkQuery().length > 0;
  }

  private closeLinkPick(): void {
    this.linkPickOpen = false;
    this.linkItems = [];
  }

  /** 选中候选项：把 `[[查询串` 替换成 `[[名称]]`，光标落到后面。 */
  private applyLinkPick(name: string): void {
    const pos: number = this.caret >= 0 && this.caret <= this.content.length
      ? this.caret : this.content.length;
    const before: string = this.content.substring(0, pos);
    const open: number = before.lastIndexOf('[[');
    if (open < 0) {
      this.closeLinkPick();
      return;
    }
    const head: string = this.content.substring(0, open) + '[[' + name + ']]';
    const tail: string = this.content.substring(pos);
    this.content = head + tail;
    this.dirty = true;
    this.closeLinkPick();
    const at: number = head.length;
    this.caret = at;
    setTimeout(() => {
      try {
        this.controller.setTextSelection(at, at);
      } catch (err) {
        // 光标定位失败不影响插入结果
      }
    }, 40);
  }

  /** 行号夹取：块区间来自解析结果，极端情况下可能越界，统一夹到 [0, 行数]。 */
  private clampLine(v: number, lineCount: number): number {
    if (v < 0) {
      return 0;
    }
    return v > lineCount ? lineCount : v;
  }

  /** 取第 index 块的源码（去掉首尾空行——块与块之间的分隔行不属于块本身）。 */
  private blockSourceAt(index: number): string {
    // 虚拟新块：还没有源文本
    if (index >= this.previewBlocks.length) {
      return '';
    }
    const lines: string[] = this.content.split('\n');
    const r: MdSrcRange = MdParser.blockSrcRange(this.previewBlocks, index, lines.length);
    const out: string[] = [];
    const end: number = this.clampLine(r.end, lines.length);
    for (let k: number = this.clampLine(r.start, lines.length); k < end; k++) {
      out.push(lines[k]);
    }
    while (out.length > 0 && out[0].trim().length === 0) {
      out.shift();
    }
    while (out.length > 0 && out[out.length - 1].trim().length === 0) {
      out.pop();
    }
    return out.join('\n');
  }

  /** 点一块 → 进入它的编辑态（表格走网格编辑器）。 */
  // ── Web 编辑器（WYSIWYG / IR）内容同步 ──

  /** Web → 原生：Web 推送整篇 Markdown（防抖后 / 导出时）。 */
  private onWebMdChanged(md: string): void {
    if (this.content === md) {
      // 内容没变也要放行挂起的保存：Web 侧"无改动"时不会带新内容回来，
      // 不等它 —— 直接续存（否则只能等兜底定时器，用户会觉得保存慢半拍）
      this.resumePendingSave();
      return;
    }
    this.content = md;
    this.dirty = true;
    this.refreshPreviewBlocks();
    // 内容刚到手：有挂起的保存就立刻接着存，不再干等定时器
    this.resumePendingSave();
  }

  /** 原生 → Web：整篇 Markdown + 当前模式推给编辑器页面。 */
  private pushContentToWeb(): void {
    try {
      this.editWebCtrl.runJavaScript('window.setMarkdown('
        + JSON.stringify(this.content) + ',' + this.previewMode + ');');
    } catch (err) {
      // Web 未就绪：onPageEnd 会再推一次
    }
  }

  /**
   * 原生 → Web：把 app 当前主题的**调色变量**推给 Web 编辑表面。
   *
   * 编辑表面（editor.html）此前配色固定深色（#11161d）：浅色主题下整块编辑区
   * 变成"深色网页"，与 app 割裂（用户实测"怎么出现 web 端的工具栏了？而且
   * 界面也不一样"）。工具条本身是 vditor 式设计（按用户要求实现、保留），
   * 这里把它的配色与 app 主题对齐——变量名与 editor.html 的 :root 一一对应。
   */
  private pushThemeToWeb(): void {
    const p: ReaderPalette = this.palette();
    const vars: string = '{"--bg":"' + Editor.cssColor(p.pageTop)
      + '","--bg2":"' + Editor.cssColor(withAlpha(p.surface, 'FF'))
      + '","--line":"' + Editor.cssColor(p.divider)
      + '","--tx":"' + Editor.cssColor(p.textPrimary)
      + '","--tx2":"' + Editor.cssColor(p.textTertiary)
      + '","--accent":"' + Editor.cssColor(p.accent)
      + '","--gold":"' + Editor.cssColor(p.accent)
      + '","--code":"' + Editor.cssColor(withAlpha(p.codeBlockBg, 'FF'))
      + '","--press":"' + (this.isDark() ? '255,255,255' : '0,0,0') + '"}';
    try {
      this.editWebCtrl.runJavaScript('window.setTheme(' + vars + ');');
    } catch (err) {
      // Web 未就绪：onPageEnd 会再推一次
    }
  }

  // ── 原生样式工具条（WYSIWYG / IR 模式）──
  //
  // 编辑表面是 Web（连续编辑无法用 ArkUI 重建），但工具条由**原生渲染**：
  // app 字体 / 主题配色 / 圆角 / 中文按钮——用户要求"使用 app 原生的样式"。
  // 点击经 execCmd 桥直达 Web 编辑表面（选区恢复在页面侧处理）。
  // （webCmd 原为顶部原生样式工具条所用——该工具条已按用户要求删除，
  //   execCmd 桥保留：底部工具层与后续功能仍可直达 Web 命令。）

  // ⚠️ Web 自带工具栏与原生样式工具条均已删除（用户要求"删除 web 的工具栏"，
  //    两条工具栏功能重复互相冲突）：格式与插入统一走底部应用工具层；
  //    editor.html 里的 #bar / #toast 已移除，window.execCmd 桥保留备用。

  /**
   * 项目调色板色（**#AARRGGBB**，alpha 在前）→ CSS 颜色字符串（`rgba(r,g,b,a)`）。
   *
   * ⚠️ 不能直接塞进 CSS：CSS 的 8 位 hex 是 **#RRGGBBAA**（alpha 在后）——
   * 直接把 `#FF1B1F27` 给 CSS 会被读成"15% 透明的淡红色"（文字全变淡红），
   * 这正是此前浅色主题下编辑区显示异常的原因。统一转 rgba() 杜绝顺序歧义。
   */
  private static cssColor(appHex: string): string {
    const s: string = appHex.trim();
    if (s.length !== 9 || s.charAt(0) !== '#') {
      return s;
    }
    const a: number = parseInt(s.substring(1, 3), 16);
    const r: number = parseInt(s.substring(3, 5), 16);
    const g: number = parseInt(s.substring(5, 7), 16);
    const b: number = parseInt(s.substring(7, 9), 16);
    if (isNaN(a) || isNaN(r) || isNaN(g) || isNaN(b)) {
      return s;
    }
    const alpha: number = Math.round(a / 255 * 100) / 100;
    return 'rgba(' + r + ',' + g + ',' + b + ',' + alpha + ')';
  }

  private editBlock(index: number): void {
    if (index < 0 || index >= this.previewBlocks.length) {
      return;
    }
    // 所见即所得（WYSIWYG）：编辑在弹出面板完成，正文流全程渲染态（源码不进入正文流）
    if (this.previewMode === 1) {
      this.wysIndex = index;
      this.wysDraft = this.blockSourceAt(index);
      this.wysOpen = true;
      return;
    }
    // 即时渲染（IR）：整页源码置顶，下方即时渲染随输入更新 —— 不做内联编辑
    if (this.previewMode === 2) {
      return;
    }
    // ⚠️ **正在编辑另一段：先把它的草稿提交回正文**（用户实测"改完一段改另一段，
    // 上一段就恢复正常了"= 切块时草稿被直接覆盖、改动全丢）。提交会让块数变化
    //（比如一段里敲出分隔线），点中的目标块若在原编辑块之后，下标要按增量平移。
    let wasSwitching: boolean = false;
    if (this.liveEditing >= 0 && this.liveEditing !== index) {
      wasSwitching = true;
      const before: number = this.previewBlocks.length;
      const prevEditing: number = this.liveEditing;
      this.commitBlockEdit();
      const delta: number = this.previewBlocks.length - before;
      if (index > prevEditing) {
        index = index + delta;
      }
      if (index < 0 || index >= this.previewBlocks.length) {
        return;
      }
    }
    this.liveAnchor = index;
    if (this.previewBlocks[index].kind === MdBlockKind.Table) {
      this.openLiveTable(index);
      return;
    }
    this.liveDraft = this.blockSourceAt(index);
    this.liveEditing = index;
    this.refreshLivePreview();
    // ⚠️ **切块时不滚动**（用户反馈"键盘收起又重新打开"的关键一环）：
    // 用户是**点屏幕上看得见的那一段**进来的，它本来就在可视区里，根本不需要滚；
    // 而滚动会让输入框在替换过程中被搬动，系统很容易判定为"失去焦点场景"而收起输入法。
    // 只有从"没有编辑态"首次进入时（键盘马上要弹起来、可能遮挡目标段）才滚到可见区中部。
    if (!wasSwitching) {
      setTimeout(() => {
        this.scrollLiveToEditing();
      }, 160);
    } else {
      // 记下切换时刻：这之后短时间内输入法若因交接抖动一下，
      // 不要再用滚动去"补偿"，否则画面来回位移
      this.lastEditSwitchAt = Date.now();
    }
  }

  /**
   * 把当前编辑块滚到**可视区中间**。
   *
   * 为什么必须做：页面走系统键盘避让（键盘弹起时整页收缩），但**列表不会自动
   * 滚动** —— 编辑靠底部的段落时，输入框落在键盘底下，底部还压着工具条，
   * 用户得先手动滑一下才能看见自己在打什么（用户反馈"太麻烦了"）。
   *
   * 用 `ScrollAlign.CENTER` 而不是 START：居中于**当前可见区**，无论键盘在不在、
   * 编辑的是哪一块，输入框都落在键盘与工具条上方；也不会把用户点的那一块
   * 猛地拽到屏幕顶端。
   */
  private scrollLiveToEditing(): void {
    if (!this.liveMode || this.liveEditing < 0) {
      return;
    }
    try {
      this.liveScroller.scrollToIndex(this.liveListOffset() + this.liveEditing, true,
        ScrollAlign.CENTER);
    } catch (err) {
      // 列表尚未重建完等：忽略，键盘变化时还会再滚一次
    }
  }

  /** 键盘弹起 / 收起：重新把编辑块带进可视区（见 scrollLiveToEditing）。 */
  onKeyboardTick(): void {
    if (!this.liveMode || this.liveEditing < 0) {
      return;
    }
    // 刚切过块：这段时间内的键盘变化是焦点交接的余波，别再滚一次（否则来回位移）
    if (Date.now() - this.lastEditSwitchAt < 600) {
      return;
    }
    setTimeout(() => {
      this.scrollLiveToEditing();
    }, 140);
  }

  /** 编辑态下方的「这块渲染成什么样」：只解析草稿本身。 */
  private refreshLivePreview(): void {
    try {
      this.livePreviewBlocks = MdParser.parse(this.liveDraft).blocks;
    } catch (err) {
      this.livePreviewBlocks = [];
    }
    // ⚠️ tick 必须递增：块 id 是解析序号（b0/b1…），打字重解析后 key 不变会让
    // ForEach 复用旧节点——"预览效果不实时刷新"（用户实测）
    this.livePreviewTick++;
    // 迷你预览里的 $公式$ 也要出图（收集进公式池，就绪后 key 变化换成图）
    this.syncFormulaTasks();
  }

  /** 所见即所得：提交弹出面板里的块编辑（复用块提交链路）。 */
  private saveWysBlock(): void {
    if (this.wysIndex < 0) {
      return;
    }
    this.liveEditing = this.wysIndex;
    this.liveDraft = this.wysDraft;
    this.commitBlockEdit();
    this.wysOpen = false;
  }

  /** IR 输入：防抖后整页同步渲染。 */
  private onIrInput(value: string): void {
    this.irDraft = value;
    this.dirty = true;
    if (this.irDebounce >= 0) {
      clearTimeout(this.irDebounce);
    }
    this.irDebounce = setTimeout(() => {
      this.irDebounce = -1;
      this.content = this.irDraft;
      this.refreshPreviewBlocks();
    }, 400);
  }

  /** IR 模式切换时的兜底：把未落盘的草稿立即同步。 */
  private flushIrDraft(): void {
    if (this.irDebounce >= 0) {
      clearTimeout(this.irDebounce);
      this.irDebounce = -1;
      this.content = this.irDraft;
      this.refreshPreviewBlocks();
    }
  }

  /** 提交块编辑：把草稿整段替换回原文对应行区间。 */
  private commitBlockEdit(): void {
    const index: number = this.liveEditing;
    if (index < 0) {
      return;
    }
    // ① 虚拟新块：追加到文末（空内容直接丢弃，不往正文里塞空行）
    if (index >= this.previewBlocks.length) {
      const text: string = this.liveDraft;
      if (text.trim().length > 0) {
        const head: string[] = this.content.split('\n');
        if (head.length > 0 && head[head.length - 1].trim().length > 0) {
          head.push('');
        }
        this.content = head.concat(text.split('\n')).join('\n');
        this.dirty = true;
      }
      this.liveEditing = -1;
      this.liveDraft = '';
      this.livePreviewBlocks = [];
      if (text.trim().length > 0) {
        this.liveCommitTick++;
      }
      this.refreshPreviewBlocks();
      return;
    }
    const lines: string[] = this.content.split('\n');
    const r: MdSrcRange = MdParser.blockSrcRange(this.previewBlocks, index, lines.length);
    const start: number = this.clampLine(r.start, lines.length);
    const end: number = this.clampLine(r.end < start ? start : r.end, lines.length);
    const out: string[] = lines.slice(0, start)
      .concat(this.liveDraft.split('\n'), lines.slice(end));
    this.content = out.join('\n');
    this.dirty = true;
    this.liveEditing = -1;
    this.liveDraft = '';
    this.livePreviewBlocks = [];
    // ⚠️ 提交计数必须递增：块内容变了但 id（解析序号）与 renderEpoch 没变，
    // key 不变会让 ForEach 复用旧节点 = "完成后不刷新"（用户实测）
    this.liveCommitTick++;
    this.refreshPreviewBlocks();
  }

  /** 放弃这次块编辑（不改原文）。 */
  private cancelBlockEdit(): void {
    this.liveEditing = -1;
    this.liveDraft = '';
    this.livePreviewBlocks = [];
  }

  /** 删除某块：清空它的行区间，必要时补一个空行避免与相邻块粘连。 */
  private deleteBlockAt(index: number): void {
    const lines: string[] = this.content.split('\n');
    const r: MdSrcRange = MdParser.blockSrcRange(this.previewBlocks, index, lines.length);
    const start: number = this.clampLine(r.start, lines.length);
    const end: number = this.clampLine(r.end < start ? start : r.end, lines.length);
    const head: string[] = lines.slice(0, start);
    const tail: string[] = lines.slice(end);
    if (head.length > 0 && tail.length > 0
      && head[head.length - 1].trim().length > 0 && tail[0].trim().length > 0) {
      head.push('');
    }
    this.content = head.concat(tail).join('\n');
    this.dirty = true;
    this.liveEditing = -1;
    this.liveDraft = '';
    this.livePreviewBlocks = [];
    this.liveAnchor = -1;
    this.liveCommitTick++;
    this.refreshPreviewBlocks();
  }

  /**
   * 实时预览下的插入（工具条 / 插图片 / 手写都走这里）。
   *
   * 位置：插到「插入锚点」那块之后；没有锚点就追加到文末。
   * 前后各补一个空行 —— Markdown 靠空行断块，粘连会让新元素被并进相邻块
   * （表格尤其明显：贴着上一段会被当成段落的一部分）。
   */
  private insertRawLive(text: string): void {
    if (this.liveEditing >= 0) {
      this.commitBlockEdit();
    }
    const lines: string[] = this.content.split('\n');
    let at: number = lines.length;
    const anchor: number = this.liveAnchor;
    if (anchor >= 0 && anchor < this.previewBlocks.length) {
      const r: MdSrcRange = MdParser.blockSrcRange(this.previewBlocks, anchor, lines.length);
      if (r.end > r.start) {
        at = this.clampLine(r.end, lines.length);
      }
    }
    const head: string[] = lines.slice(0, at);
    const tail: string[] = lines.slice(at);
    // 前后补空行时记下"新块第一行"的真实行号（下面用它把光标交回新块）
    let firstNewLine: number = at;
    if (head.length > 0 && head[head.length - 1].trim().length > 0) {
      head.push('');
      firstNewLine = at + 1;
    }
    const out: string[] = head.concat(text.split('\n'));
    if (tail.length > 0 && tail[0].trim().length > 0) {
      out.push('');
    }
    this.content = out.concat(tail).join('\n');
    this.dirty = true;
    this.refreshPreviewBlocks();

    // ── **插入后不丢键盘**（用户反馈：插完片段键盘收起，还得再点一下，很麻烦）──
    // 做法：把编辑态接到"刚插进去的那一块"上。editBlock 会重新挂载编辑组件并
    // 自动聚焦 → 键盘一直在；表格则直接打开网格编辑器（正好就是"插入即可编辑"）。
    let target: number = -1;
    for (let k: number = 0; k < this.previewBlocks.length; k++) {
      if (this.previewBlocks[k].srcLine >= firstNewLine) {
        target = k;
        break;
      }
    }
    if (target < 0) {
      target = this.previewBlocks.length - 1;
    }
    if (target >= 0) {
      const targetIndex: number = target;
      // 列表要等这一帧重建完才能按新下标定位
      setTimeout(() => {
        this.editBlock(targetIndex);
      }, 90);
    }
  }

  /** 打开表格网格编辑器（实时预览里点表格）。 */
  private openLiveTable(index: number): void {
    if (index < 0 || index >= this.previewBlocks.length) {
      return;
    }
    const block: MdBlock = this.previewBlocks[index];
    if (block.rows.length < 1) {
      return;
    }
    const header: string[] = [];
    const headerRaw: string[] = block.rows[0].raw;
    for (let k: number = 0; k < headerRaw.length; k++) {
      header.push(headerRaw[k]);
    }
    const rows: string[][] = [];
    for (let i: number = 1; i < block.rows.length; i++) {
      const r: string[] = [];
      const raw: string[] = block.rows[i].raw;
      for (let k: number = 0; k < header.length; k++) {
        r.push(k < raw.length ? raw[k] : '');
      }
      rows.push(r);
    }
    const align: TableAlign[] = [];
    for (let k: number = 0; k < header.length; k++) {
      const a: number = k < block.aligns.length ? block.aligns[k] : 0;
      align.push(a === 1 ? 'center' : (a === 2 ? 'right' : 'left'));
    }
    this.editTable = { header: header, rows: rows, align: align } as MdTable;
    this.liveTableIndex = index;
    this.tableDialog.open();
  }

  /** 保存表格：按块的行区间写回 content（编辑页不直接落盘，保存时统一写）。 */
  private saveLiveTable(): void {
    this.tableDialog.close();
    const index: number = this.liveTableIndex;
    if (index < 0) {
      return;
    }
    const lines: string[] = this.content.split('\n');
    const start: number = this.clampLine(this.previewBlocks[index].srcLine, lines.length);
    // 定位校验：表头行 + 分隔行必须就位（引用内的表格行号不可靠，直接拦下）
    if (start + 1 >= lines.length
      || !TableTool.isTableRow(lines[start])
      || !TableTool.isDelimiterRow(lines[start + 1])) {
      this.toast(L10n.t('这个表格暂不支持网格编辑（可能嵌在引用里）'));
      this.liveTableIndex = -1;
      return;
    }
    let end: number = start + 2;
    while (end < lines.length && TableTool.isTableRow(lines[end])) {
      end++;
    }
    const out: string[] = lines.slice(0, start)
      .concat(TableTool.toLines(this.editTable), lines.slice(end));
    this.content = out.join('\n');
    this.dirty = true;
    this.liveTableIndex = -1;
    this.refreshPreviewBlocks();
    this.toast(L10n.t('表格已更新'));
  }

  /** 分屏模式：0 纯编辑/预览 1 上下 2 左右。进入分屏时立即解析一次。 */
  private cycleSplit(): void {
    this.getUIContext().animateTo(AppearanceFx.anim(240, Curve.FastOutSlowIn), () => {
      // 分屏顺序（用户要求）：纯编辑 → **左右分屏** → 上下分屏 → 纯编辑
      this.splitMode = this.splitMode === 0 ? 2 : (this.splitMode === 2 ? 1 : 0);
    });
    if (this.splitMode > 0) {
      this.refreshPreviewBlocks();
      // 分屏时退出纯预览态，编辑区必须可见
      this.preview = false;
    }
  }

  /** 背景光斑缓慢漂移（与阅读页同款：无限往复、时长错开） */
  private startBlobDrift(): void {
    this.getUIContext().animateTo({
      duration: 15000, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate
    }, () => {
      this.blobAX = 64;
      this.blobAY = 42;
    });
    this.getUIContext().animateTo({
      duration: 20000, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate
    }, () => {
      this.blobBX = -52;
      this.blobBY = -58;
    });
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 行内公式图生成池（MathJax → PNG）：1×1 隐形，预览里的 $公式$ 出图
      InlineFormulaPool({
        tasks: this.formulaTasks,
        dark: this.isDark(),
        onOneDone: () => {
          this.formulaTick++;
        }
      })

      // 背景：**与阅读页完全同一套优先级与遮罩**——
      //   ① 阅读背景图 → ② 阅读背景样式（readerBgId）→ ③ 外观壁纸
      //   → ④ 函数壁纸 → ⑤ 自定义背景色 → ⑥ 主题渐变
      // 每层都压与阅读页同浓度的可读性遮罩，两个页面观感一致
      if (this.readerBgPath.length > 0) {
        // 整屏背景走 WallpaperImage：模糊**预烘成位图**，转场期间不再每帧重算
        WallpaperImage({ path: this.readerBgPath, radiusVp: this.wallpaperBlur })

        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.isDark()))
      } else if (this.readerBgId.length > 0) {
        GenWallpaper({ styleId: this.readerBgId, darkMode: this.isDark() })

        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.isDark()))
      } else if (this.wallpaperPathEffective().length > 0) {
        WallpaperImage({ path: this.wallpaperPathEffective(), radiusVp: this.wallpaperBlur })

        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.isDark()))
      } else if (this.genWallId.length > 0) {
        GenWallpaper({ styleId: this.genWallId, darkMode: this.isDark() })

        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.isDark()))
      } else if (this.pageBackground().length > 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.pageBackground())
      } else {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [[this.palette().pageTop, 0.0], [this.palette().pageBottom, 1.0]]
          })
      }

      // 光斑两团（与阅读页同款）：**有图片壁纸 / 阅读背景图时不再绘制**（用户要求）
      if (this.readerBgPath.length === 0 && this.wallpaperPathEffective().length === 0) {
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width(340)
          .height(340)
          .borderRadius(170)
          .radialGradient({
            center: ['50%', '50%'],
            radius: 170,
            colors: [[this.palette().glowCool, 0.0], [this.palette().glowCool, 0.30], ['#00000000', 1.0]]
          })
          .blur(26)
          .translate({ x: -100 + this.blobAX, y: -80 + this.blobAY })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)

      Stack({ alignContent: Alignment.BottomEnd }) {
        Column()
          .width(300)
          .height(300)
          .borderRadius(150)
          .radialGradient({
            center: ['50%', '50%'],
            radius: 150,
            colors: [[this.palette().glowWarm, 0.0], [this.palette().glowWarm, 0.28], ['#00000000', 1.0]]
          })
          .blur(26)
          .translate({ x: 90 + this.blobBX, y: 100 + this.blobBY })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)
      }

      Row() {
        Column() {
          if (this.splitMode === 1) {
            // 上下分屏：上编辑下预览，改动实时刷新
            Column({ space: HwSpace.xs }) {
              this.editorArea()
              this.previewArea()
            }
            .width('100%')
            .layoutWeight(1)
          } else if (this.splitMode === 2) {
            // 左右分屏：左编辑右预览
            Row({ space: HwSpace.xs }) {
              this.editorArea()
              this.previewArea()
            }
            .width('100%')
            .layoutWeight(1)
          } else if (this.liveMode && this.previewMode >= 1) {
            // WYSIWYG / IR：Web 编辑表面 + **原生样式工具条**（用户要求
            // "使用 app 原生的样式"：工具条为 ArkTS 原生渲染——app 字体/配色/圆角，
            // 命令经 execCmd 桥直达 Web；Web 自带的 vditor 式 #bar 在注入后隐藏）
            Column() {
              // ⚠️ **Web 自带工具栏已删除**（用户要求"删除 web 的工具栏"）：
              // 页面内 #bar（editor.html）连同原生样式工具条（webToolBar）一并移除，
              // 格式插入统一走底部应用工具层（片段条 + execCmd 桥保留备用）。
              Web({ src: $rawfile('editor/editor.html'), controller: this.editWebCtrl })
                .javaScriptProxy({
                  object: {
                    mdChanged: (md: string) => {
                      this.onWebMdChanged(md);
                    },
                    requestContent: () => {
                      this.pushContentToWeb();
                    }
                  },
                  name: 'editorHost',
                  methodList: ['mdChanged', 'requestContent'],
                  controller: this.editWebCtrl
                })
                .onPageEnd(() => {
                  // 先主题后内容：避免首屏闪一下默认深色
                  //（Web 自带 #bar 已从 editor.html 删除，无需再隐藏）
                  this.pushThemeToWeb();
                  this.pushContentToWeb();
                })
                .width('100%')
                .layoutWeight(1)
                .forceDarkAccess(false)
                .zoomAccess(false)
            }
            .width('100%')
            .height('100%')
            // ⚠️ **顶部让位**（此前缺失）：没有它，原生样式工具条直接落在 y=0
            // **压住系统状态栏**、Web 里的文档标题被悬浮导航胶囊遮住
            //（用户实测"莫名其妙的工具栏、文本被遮挡"）。让位值与其他编辑模式
            // 的首行占位同源（状态栏 + 导航胶囊 + 小缝）。
            .padding({ top: this.contentTopInset() })
          } else if (this.liveMode) {
            // 分段预览编辑：渲染态直接改，块级就地编辑
            this.liveArea()
          } else if (this.preview) {
            this.previewArea()
          } else {
            this.editorArea()
          }

        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .constraintSize({ maxWidth: this.measureWidth() })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      // 版本历史面板：根节点已有语法速查的 bindSheet（一节点只认一条），
      // 这里挂在内容 Row 上（用户要求：顶栏「版本历史」按钮 → 快照列表 / 对比 / 恢复）
      .bindSheet(this.showVersions, this.versionsSheet(), modalSheetOptions({
        title: L10n.t('版本历史'),
        subtitle: this.docName.length > 0 ? '《' + this.docName + '》的编辑快照' : '',
        surface: this.palette().surface,
        phoneLayout: this.rootWidth <= this.rootHeight,
        screenWidth: this.rootWidth,
        onDismiss: () => {
          this.showVersions = false;
        }
      }))

      // ── 悬浮顶栏：材质胶囊，内容从它底下穿过（焦点写作时隐藏）──
      if (!this.focusMode) {
        Column() {
          this.topBar()
        }
        .width('100%')
        .padding({ left: HwSpace.lg, right: HwSpace.lg, top: this.padTop() })
      }

      // ── 实时预览模式选择浮窗（顶栏下方右上角，遮罩点击关闭）──
      if (this.previewModeMenu) {
        Stack({ alignContent: Alignment.TopEnd }) {
          Column()
            .width('100%')
            .height('100%')
            .onClick(() => {
              this.previewModeMenu = false;
            })
          Column() {
            ForEach(PREVIEW_MODE_ITEMS, (item: PreviewModeItem) => {
              Row({ space: 10 }) {
                Column({ space: 2 }) {
                  Text(item.label)
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(15, this.uiFontScale))
                    .fontWeight(HwFont.bump(this.previewMode === item.m ? FontWeight.Bold : FontWeight.Normal,
                      this.uiFontWeightDelta))
                    .fontColor(this.palette().textPrimary)
                  Text(item.desc)
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(12, this.uiFontScale))
                    .fontColor(this.palette().textTertiary)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .borderRadius(10)
              // 引擎管理里关闭了 marked / turndown → WYSIWYG / IR 两项淡显（点了会提示）
              .opacity(this.webModeBlocked() && item.m >= 1 ? 0.4 : 1)
              .onClick(() => {
                this.selectPreviewMode(item.m);
              })
            }, (item: PreviewModeItem) => '' + item.m + '_' + this.previewMode)
            Divider()
              .strokeWidth(1)
              .color(this.palette().divider)
              .margin({ top: 6, bottom: 6 })
            Row({ space: 10 }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(15)
                .fontColor([this.palette().textSecondary])
              Text(L10n.t('关闭实时预览'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(15, this.uiFontScale))
                .fontColor(this.palette().textSecondary)
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 10, bottom: 10 })
            .borderRadius(10)
            .onClick(() => {
              this.previewModeMenu = false;
              if (this.liveMode) {
                this.toggleLive();
              }
            })
          }
          .width(300)
          .padding(8)
          .margin({
            right: HwSpace.lg,
            top: this.padTop() + HwBar.pill + 10
          })
          .borderRadius(HwRadius.card)
          .backgroundColor(withAlpha(this.palette().surface, 'FF'))
          .border({ width: 1, color: this.palette().divider })
          .shadow({ radius: 24, color: this.palette().shadow, offsetY: 6 })
          .alignItems(HorizontalAlign.Start)
          .transition(TransitionEffect.OPACITY
            .animation(AppearanceFx.anim(200, Curve.FastOutSlowIn))
            .combine(TransitionEffect.translate({ y: -10 })))
        }
        .width('100%')
        .height('100%')
      }

      // ── 专注写作：编辑块激活（键盘弹出）时，片段工具条随键盘一同弹出 ──
      // 用户要求：只弹工具条本身，工具条下方的状态栏不弹
      if (this.focusMode && this.liveMode && this.liveEditing >= 0) {
        Stack({ alignContent: Alignment.BottomStart }) {
          Column({ space: HwSpace.xs }) {
            if (this.barExpanded) {
              this.barExpandPanel()
            }
            this.snippetBar()
          }
          .width('100%')
          .padding({
            left: HwSpace.lg,
            right: HwSpace.lg,
            bottom: this.keyboardPx > 0 ? 6 : this.padBottom()
          })
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY
          .animation(AppearanceFx.anim(220, Curve.FastOutSlowIn))
          .combine(TransitionEffect.translate({ y: 18 })))
      }

      // ── 悬浮底部工具层：片段条 + 底栏，固定在键盘之上（焦点写作时隐藏）──
      // 页面走系统键盘避让：键盘弹起时整页高度收缩，钉在底部的那层自然抬到键盘上沿
      if (!this.focusMode) {
        Stack({ alignContent: Alignment.BottomStart }) {
          Column({ space: HwSpace.xs }) {
            if (!this.preview) {
              if (this.barExpanded) {
                this.barExpandPanel()
              }
              this.snippetBar()
            }
            this.bottomBar()
          }
          .width('100%')
          .padding({
            left: HwSpace.lg,
            right: HwSpace.lg,
            bottom: this.keyboardPx > 0 ? 6 : this.padBottom()
          })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // ── 焦点写作的退出钮：右上角小胶囊（避让状态栏），唯一入口提示 ──
      if (this.focusMode) {
        Stack() {
          ImmersiveCardLayer({ layerRadius: HwRadius.pill, layerShadow: false })
          Row({ space: 6 }) {
            Text(L10n.t('专注中'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
            ImmersiveIconButton({
              buttonSize: 30,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.getUIContext().animateTo(AppearanceFx.anim(240, Curve.FastOutSlowIn), () => {
                  this.focusMode = false;
                });
              }
            }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(14)
                .fontColor([this.palette().textPrimary])
            }
          }
          .alignItems(VerticalAlign.Center)
          .padding({ left: 10, right: 6, top: 4, bottom: 4 })
        }
        .borderRadius(HwRadius.pill)
        .margin({ left: HwSpace.lg, top: this.padTop() + 4 })
      }

      // 语法速查：**官方 bindSheet**（居中卡片，高度自适应 + 88% 封顶内滚）
      if (this.showSyntax) {
        // （内容已迁移到根节点的 bindSheet）
      }

      // （画板浮层已删除：手写/画板功能以后重做）

      // 查找替换：**胶囊浮窗**（悬浮在顶栏下方，替代原 52% 底部大面板）
      if (this.showFind) {
        Column({ space: 8 }) {
          // 主胶囊：查找输入 + 匹配数 + 上/下 + 替换开关 + 关闭
          ImmersiveBar({
            palette: this.palette(),
            barPaddingH: HwSpace.sm,
            barPaddingV: 4,
            barHeight: HwBar.pill,
            barWidth: '100%'
          }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(14)
              .fontColor([this.palette().textTertiary])
            TextInput({ text: this.findQuery, placeholder: L10n.t('查找内容') })
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .layoutWeight(1)
              .height('100%')
              .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
              .fontColor(this.palette().textPrimary)
              .placeholderColor(this.palette().textTertiary)
              .backgroundColor('#00000000')
              .padding({ left: HwSpace.xs, right: HwSpace.xs, top: 0, bottom: 0 })
              .maxLines(1)
              .onChange((value: string) => {
                this.findQuery = value;
                this.recomputeMatches();
              })
            Text(this.findLabel())
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
            ImmersiveIconButton({
              buttonSize: 28,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.stepMatch(-1);
              }
            }) {
              SymbolGlyph($r('sys.symbol.chevron_up'))
                .fontSize(13)
                .fontColor([this.palette().accent])
            }
            // ↑↓ 之间的空隙：漏了这层两颗圆钮会贴在一起
            Column()
              .width(HwSpace.xs)
            ImmersiveIconButton({
              buttonSize: 28,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.stepMatch(1);
              }
            }) {
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(13)
                .fontColor([this.palette().accent])
            }
            // 与「替换」开关之间再留一点空隙
            Column()
              .width(HwSpace.xs)
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.replaceRowOpen,
              chipLabel: this.replaceRowOpen ? L10n.t('收起') : L10n.t('替换'),
              chipOnTap: () => {
                this.replaceRowOpen = !this.replaceRowOpen;
              }
            })
            // 与关闭钮之间再留一点空隙
            Column()
              .width(HwSpace.xs)
            ImmersiveIconButton({
              buttonSize: 28,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.closeFind();
              }
            }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(13)
                .fontColor([this.palette().textSecondary])
            }
          }
          // 替换胶囊（点「替换」展开）：替换为 + 替换 + 全部替换
          if (this.replaceRowOpen) {
            ImmersiveBar({
              palette: this.palette(),
              barPaddingH: HwSpace.sm,
              barPaddingV: 4,
              barHeight: HwBar.pill,
              barWidth: '100%'
            }) {
              TextInput({ text: this.replaceText, placeholder: L10n.t('替换为') })
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .layoutWeight(1)
                .height('100%')
                .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
                .fontColor(this.palette().textPrimary)
                .placeholderColor(this.palette().textTertiary)
                .backgroundColor('#00000000')
                .padding({ left: HwSpace.xs, right: HwSpace.xs, top: 0, bottom: 0 })
                .maxLines(1)
                .onChange((value: string) => {
                  this.replaceText = value;
                })
              ImmersiveChip({
                palette: this.palette(),
                chipLabel: L10n.t('替换'),
                chipOnTap: () => {
                  this.replaceCurrent();
                }
              })
              ImmersiveChip({
                palette: this.palette(),
                chipLabel: L10n.t('全部替换'),
                chipOnTap: () => {
                  this.replaceAll();
                }
              })
            }
            // 跳转行胶囊（与替换一起收纳）
            ImmersiveBar({
              palette: this.palette(),
              barPaddingH: HwSpace.sm,
              barPaddingV: 4,
              barHeight: HwBar.pill,
              barWidth: '100%'
            }) {
              TextInput({ text: this.gotoLineText, placeholder: L10n.t('行号') })
                .layoutWeight(1)
                .height('100%')
                .fontSize(HwType.label)
                .fontColor(this.palette().textPrimary)
                .placeholderColor(this.palette().textTertiary)
                .backgroundColor('#00000000')
                .padding({ left: HwSpace.xs, right: HwSpace.xs, top: 0, bottom: 0 })
                .maxLines(1)
                .type(InputType.Number)
                .onChange((value: string) => {
                  this.gotoLineText = value;
                })
              ImmersiveChip({
                palette: this.palette(),
                chipLabel: L10n.t('跳转到行'),
                chipOnTap: () => {
                  this.gotoLine();
                }
              })
            }
          }
        }
        .width('100%')
        .padding({
          top: this.contentTopInset() + 4,
          // **与顶部悬浮胶囊对齐**：顶栏胶囊容器左右内边距是 lg，
          // 查找胶囊原来用 sm，平板上查找条比胶囊长出一截（用户反馈）
          left: HwSpace.lg,
          right: HwSpace.lg
        })
      }
      // ── 所见即所得：块编辑面板（弹出编辑，正文流全程渲染态）──
      if (this.wysOpen) {
        Stack({ alignContent: Alignment.BottomStart }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#33000000')
            .onClick(() => {
              this.wysOpen = false;
            })
          Column({ space: HwSpace.sm }) {
            Row({ space: HwSpace.xs }) {
              SymbolGlyph($r('sys.symbol.square_and_pencil'))
                .fontSize(16)
                .fontColor([this.palette().accent])
              Text(L10n.t('编辑这一块'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.label + 2, this.uiFontScale))
                .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
                .fontColor(this.palette().textPrimary)
              Blank()
              ImmersiveIconButton({
                buttonSize: 30,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.wysOpen = false;
                }
              }) {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(14)
                  .fontColor([this.palette().textPrimary])
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            TextArea({ text: this.wysDraft })
              .width('100%')
              .height(190)
              .fontSize(HwType.label + 1)
              .fontColor(this.palette().textPrimary)
              .backgroundColor(this.palette().quoteBg)
              .borderRadius(HwRadius.inner)
              .onChange((v: string) => {
                this.wysDraft = v;
              })

            Row({ space: HwSpace.sm }) {
              Blank()
              Text(L10n.t('取消'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
                .fontColor(this.palette().textSecondary)
                .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                .borderRadius(HwRadius.pill)
                .border({ width: 1, color: this.palette().divider })
                .onClick(() => {
                  this.wysOpen = false;
                })
              Text(L10n.t('保存'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
                .fontColor('#FFFFFF')
                .padding({ left: 20, right: 20, top: 8, bottom: 8 })
                .borderRadius(HwRadius.pill)
                .backgroundColor(this.palette().accent)
                .onClick(() => {
                  this.saveWysBlock();
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .padding(HwSpace.lg)
          .backgroundColor(withAlpha(this.palette().surface, 'FF'))
          .borderRadius({ topLeft: HwRadius.card, topRight: HwRadius.card })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.OPACITY.animation(AppearanceFx.anim(220, Curve.FastOutSlowIn)))
      }


      // ── **大纲重排面板**：把某一节整段挪到别处（拖动排序，或用 ↑↓ 微调）──
      if (this.outlineOpen) {
        Stack({ alignContent: Alignment.Center }) {
          // 遮罩：点空白关闭
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#66000000')
            .onClick(() => {
              this.closeOutline();
            })

          Column({ space: HwSpace.sm }) {
            Row({ space: HwSpace.xs }) {
              SymbolGlyph($r('sys.symbol.list_bullet'))
                .fontSize(16)
                .fontColor([this.palette().accent])
              Text(L10n.t('大纲重排'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.label + 2, this.uiFontScale))
                .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
                .fontColor(this.palette().textPrimary)
              Blank()
              ImmersiveIconButton({
                buttonSize: 30,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.closeOutline();
                }
              }) {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(14)
                  .fontColor([this.palette().textPrimary])
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Text(L10n.t('长按拖动可整节换序（连同它的子标题一起搬）· 也可用 ↑↓ 微调'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
              .width('100%')

            if (this.outlineItems.length === 0) {
              Text(L10n.t('这篇还没有标题。先写几个 `##` 小节，再回来整理顺序。'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
                .fontColor(this.palette().textSecondary)
                .width('100%')
                .padding({ top: HwSpace.md, bottom: HwSpace.md })
            } else {
              List({ space: 2 }) {
                ForEach(this.outlineItems, (h: MdHeading, index: number) => {
                  ListItem() {
                    Row({ space: HwSpace.xs }) {
                      Text('H' + h.level)
                        .fontFamily(HwFont.resolve(this.uiFontKey))
                        .fontSize(HwFont.sx(HwType.caption - 1, this.uiFontScale))
                        .fontColor(this.palette().textTertiary)
                        .width(20)
                      Text(h.text)
                        .fontFamily(HwFont.resolve(this.uiFontKey))
                        .fontSize(HwFont.sx(h.level <= 2 ? HwType.label + 1 : HwType.label, this.uiFontScale))
                        .fontColor(this.palette().textPrimary)
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      ImmersiveIconButton({
                        buttonSize: 28,
                        buttonMaterialShadow: false,
                        palette: this.palette(),
                        buttonOnTap: () => {
                          this.moveSectionStep(index, -1);
                        }
                      }) {
                        SymbolGlyph($r('sys.symbol.chevron_up'))
                          .fontSize(13)
                          .fontColor([this.palette().textSecondary])
                      }
                      ImmersiveIconButton({
                        buttonSize: 28,
                        buttonMaterialShadow: false,
                        palette: this.palette(),
                        buttonOnTap: () => {
                          this.moveSectionStep(index, 1);
                        }
                      }) {
                        SymbolGlyph($r('sys.symbol.chevron_down'))
                          .fontSize(13)
                          .fontColor([this.palette().textSecondary])
                      }
                    }
                    .width('100%')
                    .height(44)
                    .padding({ left: HwSpace.xs + (h.level - 1) * 12, right: HwSpace.xs })
                    .borderRadius(HwRadius.inner)
                    .backgroundColor(this.palette().quoteBg)
                    .alignItems(VerticalAlign.Center)
                  }
                }, (h: MdHeading) => 'ol_' + h.seq + '_' + this.outlineEpoch)
              }
              .width('100%')
              // 限高内滚（工程铁律：可变长内容必须限高）
              .constraintSize({ maxHeight: this.rootHeight * 0.62 })
              .scrollBar(BarState.Off)
              .edgeEffect(EdgeEffect.Spring)
              // 拖拽换序：ArkUI List 内建（记下起点，落点里算出"插到谁之前"）
              .onItemDragStart((event: ItemDragInfo, itemIndex: number): CustomBuilder => {
                this.outlineDragFrom = itemIndex;
                return this.outlineDragPreview(itemIndex);
              })
              .onItemDrop((event: ItemDragInfo, itemIndex: number, insertIndex: number,
                isSuccess: boolean): void => {
                if (isSuccess) {
                  this.onOutlineDrop(insertIndex);
                }
              })
            }
          }
          .width('86%')
          .padding(HwSpace.lg)
          .borderRadius(HwRadius.card)
          .backgroundColor(withAlpha(this.palette().surface, 'FF'))
          .border({ width: 1, color: this.palette().divider })
          .shadow({ radius: 24, color: this.palette().shadow, offsetY: 6 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
      }

      // ── **双链补全浮窗**：写 `[[` 后从底部工具层上方浮出候选 ──
      // 位置钉在工具层之上（不遮输入行），候选最多 8 条、超出可滚动
      if (this.linkPickOpen && this.linkItems.length > 0) {
        Stack({ alignContent: Alignment.BottomStart }) {
          Column({ space: 6 }) {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.doc_plaintext'))
                .fontSize(13)
                .fontColor([this.palette().accent])
              Text(L10n.t('链接到文档'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                .fontColor(this.palette().accent)
              Blank()
              Text(L10n.t('点一条插入 [[名称]]'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                .fontColor(this.palette().textTertiary)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            List({ space: 2 }) {
              ForEach(this.linkItems, (name: string) => {
                ListItem() {
                  Row({ space: HwSpace.xs }) {
                    SymbolGlyph($r('sys.symbol.arrow_up_right'))
                      .fontSize(12)
                      .fontColor([this.palette().textTertiary])
                    // 显示文件名本身：`[[ ]]` 里要写的就是它（写显示名会变成悬空链接）
                    Text(name)
                      .fontFamily(HwFont.resolve(this.uiFontKey))
                      .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
                      .fontColor(this.palette().textPrimary)
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .width('100%')
                  .height(38)
                  .padding({ left: HwSpace.sm, right: HwSpace.sm })
                  .borderRadius(HwRadius.inner)
                  .backgroundColor(this.palette().quoteBg)
                  .alignItems(VerticalAlign.Center)
                  .onClick(() => {
                    this.applyLinkPick(name);
                  })
                }
              }, (name: string) => 'lp_' + name)
            }
            .width('100%')
            // 候选多了限高内滚（工程铁律：可变长内容必须限高）
            .constraintSize({ maxHeight: 190 })
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
          }
          .width('100%')
          .padding(HwSpace.sm)
          .borderRadius(HwRadius.card)
          .backgroundColor(this.palette().surface)
          .border({ width: 1, color: this.palette().divider })
          .shadow({ radius: 16, color: this.palette().shadow, offsetY: 4 })
        }
        .width('100%')
        .height('100%')
        .padding({
          left: HwSpace.lg,
          right: HwSpace.lg,
          // 浮在片段条 + 底栏之上（两者合计约 100vp），再加键盘避让
          bottom: (this.keyboardPx > 0 ? 6 : this.padBottom()) + 104
        })
        // 只让卡片本身吃掉点击，其余区域穿透（否则会挡住正文点击）
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // ── **预览图片放大浮层**（用户要求：实时预览支持放大查看图片）──
      // 原生 Image（沙箱 file:// URI）+ 双指捏合缩放 + 点空白关闭
      if (this.previewImage.length > 0) {
        Stack({ alignContent: Alignment.Center }) {
          Image(this.previewImage)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .height('100%')
            .scale({ x: this.previewImgScale, y: this.previewImgScale })
            .offset({ x: this.previewImgDx, y: this.previewImgDy })
            // **单指拖动 + 双指缩放并行**（用户反馈：放大后不能单指拖动）——
            // 此前这里只有 PinchGesture，放大后的图根本推不动；现在补上单指 Pan
            // （fingers: 1），与捏合放在 Parallel 组里互不抢手势。
            .gesture(
              GestureGroup(GestureMode.Parallel,
                PanGesture({ fingers: 1, distance: 1 })
                  .onActionStart(() => {
                    this.previewImgDxBase = this.previewImgDx;
                    this.previewImgDyBase = this.previewImgDy;
                  })
                  .onActionUpdate((event: GestureEvent) => {
                    this.previewImgDx = this.previewImgDxBase + event.offsetX;
                    this.previewImgDy = this.previewImgDyBase + event.offsetY;
                  }),
                PinchGesture({ fingers: 2 })
                  .onActionStart(() => {
                    this.previewImgPinchBase = this.previewImgScale;
                  })
                  .onActionUpdate((event: GestureEvent) => {
                    const sc: number = event.scale !== undefined ? event.scale : 1;
                    this.previewImgScale = Math.min(8, Math.max(0.5, this.previewImgPinchBase * sc));
                  })
              )
            )

          Text(L10n.t('点此关闭'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor('#FFFFFFFF')
            .padding({ left: HwSpace.md, right: HwSpace.md, top: 6, bottom: 6 })
            .borderRadius(HwRadius.pill)
            .backgroundColor('#66000000')
            .position({ x: '50%', y: '92%' })
            .markAnchor({ x: '50%', y: '50%' })
            .onClick(() => {
              this.previewImage = '';
            })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#F2000000')
        .onClick(() => {
          this.previewImage = '';
        })
        // **打开 / 关闭的过渡**（用户要求）：淡入 + 轻微放大进场，关闭时反向收回。
        // 必须用显式 TransitionEffect —— 隐式对象形式依赖调用方把状态改动包在
        // animateTo 里才有动画，而"点放大按钮打开"与"点空白关闭"这两条路径都没包，
        // 会直接硬切（本工程在搜索结果面板上已踩过同一个坑）。
        .transition(TransitionEffect.OPACITY
          .animation(AppearanceFx.anim(220, Curve.FastOutSlowIn))
          .combine(TransitionEffect.scale({ x: 0.92, y: 0.92, centerX: '50%', centerY: '50%' })))
      }
    }
    .width('100%')
    .height('100%')
    // 语法速查：**官方规范半模态面板**（material/ModalSheet.ets：模态型 + MEDIUM 高
    // + 官方标题栏 / 关闭按钮 / 拖拽条，内部滚动）
    .bindSheet(this.showSyntax, this.syntaxSheet(), modalSheetOptions({
      title: L10n.t('Markdown 语法速查'),
      subtitle: L10n.t('点任意一行即可插入到光标位置'),
      surface: this.palette().surface,
      // 竖屏（含平板竖屏）按手机形态出底部面板；平板竖屏宽度收一半
      phoneLayout: this.rootWidth <= this.rootHeight,
      screenWidth: this.rootWidth,
      onDismiss: () => {
        this.showSyntax = false;
      }
    }))
    // ── 外接键盘快捷键 ──
    // 绑在**根节点**上：keyboardShortcut 沿焦点链匹配，输入框获焦时也会命中祖先上的绑定。
    // 常用四件套 + 字号两档：写长文时手不用离开键盘。
    .keyboardShortcut('s', [ModifierKey.CTRL], () => {
      this.save();
    })
    .keyboardShortcut('b', [ModifierKey.CTRL], () => {
      this.wrapSelection('**');
    })
    .keyboardShortcut('i', [ModifierKey.CTRL], () => {
      this.wrapSelection('*');
    })
    .keyboardShortcut('f', [ModifierKey.CTRL], () => {
      this.openFind();
    })
    .keyboardShortcut(FunctionKey.DPAD_UP, [ModifierKey.CTRL], () => {
      this.bumpFontSize(1);
    })
    .keyboardShortcut(FunctionKey.DPAD_DOWN, [ModifierKey.CTRL], () => {
      this.bumpFontSize(-1);
    })
    // 根节点铺满整个窗口（含状态栏与手势条区域），避让由 padTop / padBottom 统一负责
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(this.palette().pageBottom)
    .key('editor_l' + this.languageTick)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      // Area.width / height 的类型是 Length（number | string | Resource），必须收窄后再用
      const raw: Length = newValue.width;
      if (typeof raw === 'number' && raw > 0 && raw !== this.rootWidth) {
        this.rootWidth = raw;
      }
      const rawH: Length = newValue.height;
      if (typeof rawH === 'number' && rawH > 0 && rawH !== this.rootHeight) {
        this.rootHeight = rawH;
      }
    })
  }
}
