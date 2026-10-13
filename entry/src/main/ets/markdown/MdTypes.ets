/**
 * LiteMdReader · Markdown 抽象语法树（AST）类型
 * ==============================================
 *
 * 设计取舍：**块级采用扁平数组，不做嵌套树**。
 * ArkUI 的 @Builder 递归渲染在 ArkTS 里约束很多（自定义组件不能递归引用自身），
 * 扁平化之后列表的层级用 `indent` 字段表达、引用的嵌套用 `quoteDepth` 表达，
 * 渲染侧只需一次 ForEach 遍历，无需递归。
 *
 * 行内样式同理：不建嵌套节点，而是给每个片段带上「继承下来的样式标志位」，
 * 解析 `**粗体里的 `代码`**` 时会产出两个片段（都带 bold），而不是一棵父子树。
 */

/** 块级元素种类 */
export enum MdBlockKind {
  Heading = 0,
  Paragraph = 1,
  Code = 2,
  Quote = 3,
  ListItem = 4,
  Table = 5,
  Divider = 6,
  Callout = 7,
  /** 数学公式块（$$...$$ / \[...\]），由 KaTeX 完整渲染（未就绪时 MathLite 线性化兜底） */
  Math = 8,
  /** 图表块（```mermaid / markmap / echarts ...），按语言分发渲染 */
  Chart = 9,
  /** 折叠细节块（<details><summary>） */
  Details = 10,
  /** 代码组（::: code-group，多段代码标签页切换） */
  CodeGroup = 11
}

/** 代码组里的一段代码（语言 + 页签名 + 源码） */
export interface GroupCode {
  label: string;
  lang: string;
  code: string;
}

/** 行内片段种类 */
export enum MdInlineKind {
  Plain = 0,
  Strong = 1,
  Em = 2,
  Code = 3,
  Strike = 4,
  Link = 5,
  Image = 6,
  Mark = 7,
  FootnoteRef = 8,
  /** 行内数学（$...$ / \(...\)），KaTeX 渲染成图内联；未就绪时线性化兜底 */
  MathInline = 9,
  /** 上标 ^text^ */
  Sup = 10,
  /** 下标 ~text~ */
  Sub = 11,
  /**
   * **键盘按键**（原生 HTML `<kbd>` / `<samp>` / `<var>`）。
   * 与行内代码同为等宽，但画成"按键帽"底色——导出侧写成真正的 `<kbd>` 标签。
   */
  Key = 12,
  /**
   * **中文注音**（原生 HTML `<ruby>` 里 `<rt>` 的那段读音）。
   * 扁平结构里没法做上下两层，所以基准文字仍是普通片段，读音作为紧随其后的
   * 小号上移片段——导出侧会重新拼成 `<ruby>`。
   */
  Ruby = 13,
  /** **带颜色的文字**（`<span style="color:…">` / `<font color>`），颜色在 `color` 字段 */
  Color = 14,
  /** **下划线**（`<u>` / `<ins>`） */
  Under = 15
}

/** GFM 提示块种类 */
export enum MdCalloutKind {
  None = 0,
  Note = 1,
  Tip = 2,
  Important = 3,
  Warning = 4,
  Caution = 5
}

/** 列表项任务状态 */
export enum MdTaskState {
  None = -1,
  Todo = 0,
  Done = 1
}

/**
 * 行内片段。
 * 样式用「标志位」表达继承关系，而不是嵌套结构——见文件头说明。
 */
export interface MdInline {
  kind: MdInlineKind;
  /** 显示文本（脚注引用为 label） */
  text: string;
  /** 链接 / 图片地址 */
  href: string;
  /** 脚注序号（1 起；0 表示引用缺失定义） */
  num: number;
  bold: boolean;
  italic: boolean;
  strike: boolean;
  code: boolean;
  /**
   * **指定颜色**（原生 HTML `<span style="color:…">` / `<font color>`）。
   * 空串/未设 = 跟随正文颜色；值形如 `#RRGGBB` 或 `#AARRGGBB`（解析器已过滤，
   * 只放行十六进制色值，`red`/`rgb()`/`url()` 之类一律丢弃，避免把任意 CSS 注入渲染层）。
   */
  color?: string;
  /**
   * **指定背景色**（`<span style="background:#eee">` 这类实心色值）。渐变 / url() 背景
   * 画不出来，解析器就不会写这个字段；渲染层拿它当"实色底"，与学习卡同一套通道。
   */
  bg?: string;
}

/** 表格行 */
export interface MdTableRow {
  /** 每格的原始 Markdown 文本，渲染时再解析行内 */
  raw: string[];
  /** 每格解析后的行内片段 */
  cells: MdInline[][];
  header: boolean;
}

/** 块级元素 */
export interface MdBlock {
  /** 指定高亮行（围栏元数据 ```lang{1,3-5}，1 起） */
  hlLines?: number[];
  /**
   * 标题的**显式锚点**（`## 标题 {#intro}` 里那个 `intro`，Pandoc / markdown-it-anchor
   * 同一套写法）。导出网页据此给 `<h*>` 加 id，`[文字](#intro)` 才能精确命中；
   * 阅读页仍按标题文字模糊匹配跳转，不依赖这个字段。
   */
  anchor?: string;
  /** 代码组的分段（kind=CodeGroup 时有效） */
  groupCodes?: GroupCode[];
  /**
   * 折叠面板**默认展开**（`<details open>` 的 open 属性；kind=Details 时有效）。
   * 没有这个字段时，带属性的写法整块会被块级 HTML 路径吞掉、正文被空行拆散。
   */
  open?: boolean;
  /** 稳定 key（块序号） */
  id: string;
  kind: MdBlockKind;
  /** 标题层级 1–6 */
  level: number;
  /** 代码块语言 */
  lang: string;
  /** 代码块原始文本 */
  code: string;
  /** 代码块行数组 */
  codeLines: string[];
  /** 段落 / 标题 / 引用 / 列表项的行内片段 */
  inlines: MdInline[];
  /** 纯文本（用于字数统计、目录、无障碍） */
  plain: string;
  /** 列表缩进层级（0 起） */
  indent: number;
  /** 有序列表 */
  ordered: boolean;
  /** 列表标记原文（`-`、`1.` 等） */
  marker: string;
  /** 任务状态 */
  task: number;
  /** 表格行 */
  rows: MdTableRow[];
  /** 表格列对齐：0 左 1 中 2 右 */
  aligns: number[];
  /** 提示块种类 */
  callout: MdCalloutKind;
  /** 脚注卡序号（0 表示非脚注块） */
  footnoteNo: number;
  /** 标题序号（1 起，非标题为 0） */
  headingSeq: number;
  /** 该块首行在原文中的行号（0 起）。任务列表勾选靠它改写原文对应行 */
  srcLine: number;
}

/**
 * 一个块在**原文**中占据的行区间（0 起，左闭右开 `[start, end)`）。
 *
 * 块级实时编辑与大纲拖拽都靠它定位源文本：块上只记了起始行 `srcLine`，
 * 结束行用「下一个块的起始行」推断——Markdown 的块在原文里是**连续且有序**的，
 * 所以这个推断成立；块之间的空行会被算进区间尾部，替换时一并带走，
 * 再写回时由调用方保证块与块之间留一个空行。
 */
export interface MdSrcRange {
  start: number;
  end: number;
}

/** 目录条目 */
export interface MdHeading {
  level: number;
  text: string;
  /** 在 blocks 中的下标，用于跳转 */
  blockIndex: number;
  /** 标题序号 */
  seq: number;
  /**
   * 显式锚点（`## 标题 {#intro}` 里那个 id，无则空串）。
   * 有了它，阅读页的 `[文字](#intro)` 才能按 id 跳——以前跳转只比标题文字，
   * 于是"显式锚点"这件事只有导出的网页成立，应用里点了没反应（用户实测）。
   */
  anchor: string;
}

/**
 * 注释（脚注）条目。
 * 阅读界面右滑抽屉「注释」用它渲染注释卡，点击可跳回正文对应位置——
 * 这是借鉴 zhumo-reader「注释不是附加物、而是第二正文」的思路。
 */
export interface MdNote {
  /** 序号（1 起） */
  no: number;
  /** 原始 label（[^label] 中的 label） */
  label: string;
  /** 纯文本 */
  text: string;
  /** 行内片段，用于注释卡内渲染富文本 */
  inlines: MdInline[];
  /** 注释块在 blocks 中的下标，用于跳转 */
  blockIndex: number;
}

/**
 * 用户批注（荧光笔 / 文字批注）。
 *
 * 定位方式：`blockId` + 该块**渲染文本**内的字符区间 [start, end)。
 * 之所以用「渲染文本」而不是源码偏移，是因为选区偏移由 `onTextSelectionChange`
 * 给出，它的坐标系就是 Text 里 Span 拼接后的文本——两者必须同一套坐标系，
 * 否则高亮会位移（见 MdView 里的 buildPieces）。
 *
 * 批注存的是区间而不是插入标记，所以正文被编辑后位置可能失效——
 * v1 的策略是失效的批注原样保留、不静默删除，由用户在注释抽屉里清理。
 */
export interface MdAnnotation {
  id: string;
  blockId: string;
  start: number;
  end: number;
  text: string;
  /** 荧光笔颜色索引（见 DesignTokens.ANNOTATION_COLORS）；-1 表示纯文字批注、无底色 */
  color: number;
  /** 文字批注内容，可为空 */
  note: string;
  /**
   * 标注形态：空串 = 荧光笔底纹；'wavy' = 波浪线（画在文字下方）；
   * 'dbl' = **红色双下划线**（手写批注；手写图路径存在 note 里，前缀 `hw:`）
   */
  style: string;
  created: number;
}

/**
 * 行内渲染片段。
 *
 * 与 `MdInline` 的区别：一段 `MdInline` 可能被批注区间切开成若干 `MdPiece`，
 * 每个 piece 带自己的底色。**所有 piece 的 text 拼接后必须与切分前完全一致**，
 * 否则选区偏移会错位。
 */
export interface MdPiece {
  text: string;
  kind: MdInlineKind;
  href: string;
  num: number;
  /**
   * 该片段在块内**渲染文本**（各 spanLabel 拼接）中的字符范围 [start, end)。
   * 供**非文本片段**（行内公式图）的批注定位用——图片没有选区，落注/查询
   * 都靠这段区间与批注系统的「块 id + 渲染区间」坐标系对齐。
   */
  start: number;
  end: number;
  bold: boolean;
  italic: boolean;
  strike: boolean;
  code: boolean;
  /** 指定颜色（`MdInlineKind.Color` 用；从 MdInline.color 原样带过来） */
  color?: string;
  /** 该片段的荧光笔底色；空串表示无底纹 */
  highlight: string;
  /**
   * **注音配对信息**（`<ruby>汉<rt>hàn</rt></ruby>` 解析后的两段之间互相指认）：
   * 基准字片段带 `rubyOver`（要压在它上面的读音），读音片段带 `rubyBase`（它属于哪个字）。
   * 有了这一对，视图才能量出两个宽度、把读音**水平居中到基准字上方**并把它自己的
   *  advance 抵消掉（否则注音会占位、把后面的文字推歪）。
   */
  rubyOver?: string;
  rubyBase?: string;
  /**
   * **实色底**（学习卡）：true 时 highlight 按**不透明**渲染，
   * 不走荧光笔透明度缩放（默认黄色实底）
   */
  solid?: boolean;
  /** 该片段是否带波浪线标注（与底纹互斥） */
  wavy: boolean;
  /** **红色双下划线**（手写批注的标记形态，`TextDecorationStyle.DOUBLE`） */
  dblLine: boolean;
  /** 该片段是否被批注覆盖（用于注释抽屉里的定位校验） */
  annotated: boolean;
  /** 是否命中当前搜索关键词 */
  searchHit: boolean;
}

/**
 * YAML Front Matter 的一条元数据。
 * 移植自参考项目 MD Reader：顶部 `---` 之间的 `key: value` 不再混进正文，
 * 而是单独抽出来渲染成一张信息卡片。
 */
export interface MdMetaItem {
  key: string;
  value: string;
}

/** 解析结果 */
export interface MdParseResult {
  blocks: MdBlock[];
  outline: MdHeading[];
  notes: MdNote[];
  /** YAML Front Matter 抽出的元数据（无则为空数组） */
  meta: MdMetaItem[];
  /** 脚注条数 */
  footnoteCount: number;
  /** 标题数 */
  headingCount: number;
  /** 代码块数 */
  codeBlockCount: number;
  /** 表格数 */
  tableCount: number;
  /** 字符数（不含空白） */
  charCount: number;
  /** 字数（中日韩按字计，西文按词计） */
  wordCount: number;
}

/** 空块，仅用作组件参数的默认值，避免在 ArkTS 里出现未初始化成员。 */
export function emptyBlock(): MdBlock {
  const block: MdBlock = {
    id: '0',
    kind: MdBlockKind.Paragraph,
    level: 0,
    lang: '',
    code: '',
    codeLines: [],
    inlines: [],
    plain: '',
    indent: 0,
    ordered: false,
    marker: '',
    task: MdTaskState.None,
    rows: [],
    aligns: [],
    callout: MdCalloutKind.None,
    footnoteNo: 0,
    headingSeq: 0,
    srcLine: 0
  };
  return block;
}

/** 空行内片段。 */
export function emptyInline(): MdInline {
  const item: MdInline = {
    kind: MdInlineKind.Plain,
    text: '',
    href: '',
    num: 0,
    bold: false,
    italic: false,
    strike: false,
    code: false
  };
  return item;
}
