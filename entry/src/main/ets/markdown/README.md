# Markdown 引擎 · 文件与依赖说明

澄笺的 Markdown 能力**全部自研**（不依赖第三方 Markdown 库），分为
「解析 → 渲染 → 行内增强」三层，外加一组必须配套的组件与离线资源。

---

## 一、引擎本体（`entry/src/main/ets/markdown/`）

| 文件 | 职责 | 必须性 |
|---|---|---|
| `MdTypes.ets` | **数据模型唯一来源**：`MdBlock` / `MdInline` / `MdPiece` / `MdAnnotation` / `MdOutline` 等。所有层共用这些类型，改字段要全局搜 | 必须 |
| `MdParser.ets` | **块级 + 行内解析器**。Front Matter、标题、列表、任务列表、表格、引用、代码围栏、脚注、`<details>`、数学块、行内语法（粗斜体/删除线/行内代码/链接/图片/上下标/表情/脚注引用）全在这里 | 必须 |
| `MdView.ets` | **渲染层**（最大的一个文件）。`MdBlockView` 组件按块类型分发到各 `@Builder`；文件内的 `MdViewUtil` 负责把「块 + 批注 + 搜索词」切成 `MdPiece[]`（`buildPieces`），是批注底纹/波浪线/搜索高亮的落点 | 必须 |
| `CodeHighlight.ets` | 代码块语法高亮（自研分词器，按语言族：cLike / hash 注释 / markup / data 等） | 代码块高亮需要 |
| `Emoji.ets` | `:smile:` 之类表情短码 → Unicode | 表情短码需要 |
| `MathLite.ets` | **轻量 LaTeX 渲染**：把 LaTeX 线性化成 Unicode 文本 + 结构段（分式/根号/矩阵），块级公式交给 `katex.html` | 公式需要 |
| `FlowChart.ets` | `flowchart` 流程图的**纯 ArkUI 布局**（不依赖 Web）：解析节点/边、分层、绘制 | 流程需要 |
| `MdToHtml.ets` | 导出用：把 `MdBlock[]` 转成完整 HTML（**自研渲染，不依赖任何 Web 引擎**） | 导出需要 |

> **不再存在于本目录**：`SimpleCharts.ets`（已废弃，无人引用，已删除，备份在
> `.workbuddy/backup/deadcode_20260927/`）。

## 二、引擎必须配套的组件（`entry/src/main/ets/components/`）

| 组件 | 为什么必须 |
|---|---|
| `DiagramWeb.ets` | 所有「用 Web 渲染」的块都靠它：mermaid / markmap / echarts / graphviz / abc / flowchart / katex。它负责加载 `rawfile/render/*.html`、注入 payload、回传渲染高度（`postHeight`）、上报触摸（抑制页面捏合改字号） |
| `DocCover.ets` | 文档封面（书架格子与「一镜到底」飞行的封面都用它） |
| `HandWriteView.ets` | 手写笔迹（HMS PenKit），与 Markdown 无关但同属内容层 |

## 三、必须的离线资源（`entry/src/main/resources/rawfile/render/`）

| 资源 | 用途 |
|---|---|
| `katex.html` + `lib/` | 块级公式渲染 |
| `mermaid.html` | mermaid 流程图 / 时序图 / 甘特图 |
| `markmap.html` | 思维导图 |
| `echarts.html` | 图表 |
| `graphviz.html` | Graphviz |
| `abc.html` | 五线谱 |
| `flowchart.html` | flowchart.js |

**删任何一个 html，对应语言的代码块会渲染失败**（会退回普通代码块）。

> `lute.html`（4.3MB）原用于导出排版，因其内联脚本转义损坏且常驻挂载会留残影，
> 已连同导出链路一并移除，导出统一走 `MdToHtml` 自研渲染。

## 四、材质与外壳（渲染层依赖，不在 markdown 目录）

| 文件 | 作用 |
|---|---|
| `material/ImmersiveCard.ets` | `ImmersiveCard` / `ImmersiveChip` / `ImmersiveIconButton` / `ImmersiveSheetPanel` / **`ImmersiveCardLayer`**（沉浸光感承载层，全应用唯一材质通路） |
| `material/SystemMaterial.ets` | 承载层的实现：`carrierModifier`（Toggle + attributeModifier 画 uiMaterial）+ `getImmersiveMaterial()` |
| `material/ModalSheet.ets` | 半模态面板（官方规范：模态型 + MEDIUM + 官方标题栏/关闭按钮/拖拽条） |
| `theme/DesignTokens.ets` | 尺寸/圆角/字号/调色板唯一来源 + `FOLDER_SPRING` 弹簧曲线 + `paletteFor()` |

## 五、硬性约束（改渲染层前必读）

1. **批注坐标系 = 「块 id + 该块渲染文本内的字符区间」**，必须与 `onTextSelectionChange`
   同一坐标系。`MdViewUtil.buildPieces()` 的**不变式**：切分后各 piece 文本拼接
   必须与切分前完全一致。任何改变文本切分方式的重构都要先验证这条。
2. **行内图片不进 Span**：只有「独立成段」的 `![]()` 渲染成真实图片；
   与文字混排的行内图片保持替代文本（Span 里塞图会破坏逐字坐标系）。
3. **正文行内富文本必须用** `Text() { ForEach(...) { Span(...) } }`：
   编译器会在 ForEach 分支重置父组件名追踪（这是有意为之的写法，不要改成嵌套 Text）。
4. 代码高亮/公式解析等**所有「返回游标」的函数必须保证游标前进**
   （历史上一个 `\frac25` 就把整个应用卡死过，见 `MathLite.readGroup` 注释）。
