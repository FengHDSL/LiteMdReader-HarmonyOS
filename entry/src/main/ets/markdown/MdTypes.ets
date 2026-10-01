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
  /** 数学公式块（$$...$$），由 MathLite 自绘子集渲染 */
  Math = 8,
  /** 图表块（```mermaid / markmap / echarts ...），按语言分发渲染 */
  Chart = 9,
  /** 折叠细节块（<details><summary>） */
  Details = 10
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
  /** 行内数学（$...$），线性化为 Unicode 呈现 */
  MathInline = 9,
  /** 上标 ^text^ */
  Sup = 10,
  /** 下标 ~text~ */
  Sub = 11
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

/** 目录条目 */
export interface MdHeading {
  level: number;
  text: string;
  /** 在 blocks 中的下标，用于跳转 */
  blockIndex: number;
  /** 标题序号 */
  seq: number;
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
   * 标注形态：空串 = 荧光笔底纹；'wavy' = 波浪线（画在文字下方）
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
  bold: boolean;
  italic: boolean;
  strike: boolean;
  code: boolean;
  /** 该片段的荧光笔底色；空串表示无底纹 */
  highlight: string;
  /** 该片段是否带波浪线标注（与底纹互斥） */
  wavy: boolean;
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
