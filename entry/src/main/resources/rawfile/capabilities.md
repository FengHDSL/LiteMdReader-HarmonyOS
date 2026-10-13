# 澄笺 · 渲染能力总览

> [!NOTE]
> 这份文档是**能力清单**，不是教程（教程见「Markdown 语法教程」，功能演示见「澄笺示例 · 全功能演示」）。
> 下面每一条都在开发机上用**应用自带的离线渲染库真跑过**，标注了「实测」；
> 只有官方文档写着、这里没实测过的，一律标「未验证」或直接列入文末的不支持清单。
> 版本与开关入口见每节末尾，或「设置 → 引擎管理」。

---

## 一、图表引擎一览

正文里把围栏代码块的语言名写成下面任意一个，就会**渲染成图**而不是代码：

| 语言名 | 引擎 | 版本 | 用来画 |
| --- | --- | --- | --- |
| `mermaid` | Mermaid | 10.9.3 | 流程图、时序图、类图、状态图、ER 图、甘特、饼图、思维导图、时间线、C4 等 |
| `echarts` | Apache ECharts | 6.1.0 | 统计图（柱 / 折线 / 饼 / 散点 / 雷达 / 仪表盘 / 关系图 / 树 / 矩形树图 等） |
| `markmap` | markmap | 0.18.12 | 思维导图（Markdown 大纲直接成图） |
| `graphviz` | Viz.js（内嵌 Graphviz 16.1.0） | 3.31.0 | DOT 语言关系图、有向图、聚类 |
| `flowchart` | flowchart.js | 1.17.1 | 经典 `st=>start:` 写法的流程图 |
| `abc` | abcjs | 6.7.1 | ABC 记谱法五线谱 |
| `wavedrom` | WaveDrom | 3.7.0 | **数字波形图**、逻辑门图、寄存器位段图 |
| `html` | 系统 WebView | — | 可交互 HTML 预览（`<script>` 会执行） |
| `katex` / `$$…$$` | KaTeX | 0.19.0 | 数学公式 |

**关闭某个引擎**：设置 → 引擎管理。关闭后该语言的代码块在阅读页与导出 HTML 里
都退回成**普通代码块**（不会渲染失败留白），导出的网页也不会假装能渲染。

---

## 二、Mermaid：实测可用的图类型

Mermaid 官方类型很多，但**能不能画取决于应用内置的这份构建**。逐个实测结果：

| 图类型 | 首行写法 | 实测 |
| --- | --- | :---: |
| 流程图 | `graph TD` / `flowchart LR` | ✅ |
| 时序图 | `sequenceDiagram` | ✅ |
| 类图 | `classDiagram` | ✅ |
| 状态图 | `stateDiagram-v2` | ✅ |
| 实体关系图 | `erDiagram` | ✅ |
| 用户旅程图 | `journey` | ✅ |
| 甘特图 | `gantt` | ✅ |
| 饼图 | `pie` | ✅ |
| 象限图 | `quadrantChart` | ✅ |
| 桑基图 | `sankey-beta` | ✅ |
| 柱线混合图 | `xychart-beta` | ✅ |
| 需求图 | `requirementDiagram` | ✅ |
| Git 分支图 | `gitGraph` | ✅ |
| 思维导图 | `mindmap` | ✅ |
| 时间线 | `timeline` | ✅ |
| 块图 | `block-beta` | ✅ |
| C4 架构图 | `C4Context` | ✅ |
| 数据包图 | `packet-beta` | ✅（中文标签实测可用） |
| 架构图 | `architecture-beta` | ⚠️ 在构建内，但**标签只认 ASCII** |

实测踩到的坑（逐条在随包引擎上跑过）：

1. **象限图的标签没有冒号**。要写 `quadrant-1 We should expand`，写成 `quadrant-1: 我们要扩张` 会直接解析失败。
2. **类图、需求图靠缩进分块**。`class Animal { +int age }` 的花括号内换行要缩进，否则报 Parse error。
3. **象限图的坐标轴与数据点标签只认 ASCII**。`x-axis 低成本 --> 高成本` 会报 Lexical error，
   必须写成 `x-axis Low cost --> High cost`；图标题（`title`）里可以放中文。这是 Mermaid 10.9 词法的限制。
4. **架构图的 `[标签]` 只认"不带点的 ASCII"**（这条是在随包的 Mermaid 11 上逐个变体实测的，不是猜的）：
   · 中文不行 —— `group app(cloud)[澄笺应用]` 报 `Parsing failed: unexpected character: ->[<-`，
     **加引号也救不了**（`["澄笺应用"]` 同样失败）；
   · 点号不行 —— `[shelf.json]` 同样报错，写成 `[shelf index]` 就正常；
   · 空格可以 —— `[docs folder]`、`[API layer]` 实测正常。
   同一批图种里 `kanban` 的中文列名与 `packet-beta` 的中文段名都实测正常 —— 只有
   architecture-beta 的词法卡在这两处。

## PlantUML（```plantuml）：只桥接时序图，其余显示源码

PlantUML 的本体是 Java 实现，离线要么带 `plantuml.jar` 要么连官方渲染服务器 ——
两者澄笺都不做（无账号、无必需联网是产品底线）。所以 ```` ```plantuml ```` 走的是
**语法桥**：把时序图翻译成 mermaid 的 `sequenceDiagram`，交给上面那套 mermaid 引擎渲染。

**桥得住的**（逐条在随包引擎上跑过）：

| PlantUML 写法 | 翻成 |
| --- | --- |
| `actor` / `participant` / `database` / `boundary` / `entity` / `queue` …（含 `"显示名" as ID`） | `participant ID as 显示名` |
| `A -> B: 文本`、`A --> B: 文本`，以及不带空格的 `A->B: 文本` | `A->>B:` / `A-->>B:`（实线 / 虚线） |
| `A -> B++` / `A -> B--`、`activate B` / `deactivate B` | `activate` / `deactivate` |
| `note over A`、`note over A, B`、`note left of / right of` | `Note …` |
| `alt` / `else` / `end`、`loop` / `opt` / `par` / `and` / `break` / `critical`、`group` | 同名关键字直接透传 |
| `autonumber`、`title …`、`== 分隔线 ==` | 原样透传 |
| `skinparam …`、`!theme`、`!$变量`、`hide/show/style` | **丢弃**（纯外观指令，透传会让整图报错） |
| 认不出的行 | 降格成 mermaid 注释 `%% …`，不再连累整张图 |

**桥不住的**：类图、用例图、活动图、状态图、组件图、时序图之外的任何 PlantUML —— 这些
语法差异过大，**不硬转**，直接以代码块显示源码（以前会被塞成 sequenceDiagram，
渲染出一张 mermaid 解析错误卡，比看源码更没用）。要真渲染全套 PlantUML，请导出源码
交给 PlantUML 服务器，或改用 mermaid / Graphviz / nomnoml 的等价图种。

一张象限图（注意 `quadrant-1` 后面**没有**冒号，且轴标签用英文）：

```mermaid
quadrantChart
    title 功能投入判断
    x-axis Low effort --> High effort
    y-axis Low value --> High value
    quadrant-1 Do it first
    quadrant-2 Do when free
    quadrant-3 Skip
    quadrant-4 Schedule it
    Export: [0.35, 0.82]
    Sync: [0.78, 0.60]
```

一张 ER 图：

```mermaid
erDiagram
    FOLDER ||--o{ DOC : contains
    DOC {
        string name
        int words
    }
```

---

## 三、ECharts：实测可用的系列

应用内置的是 **完整构建**（不是按需裁剪版），下面 14 个系列都实测出图：

`bar` 柱状 · `line` 折线 · `pie` 饼图 · `scatter` 散点 · `radar` 雷达 · `gauge` 仪表盘 ·
`funnel` 漏斗 · `heatmap` 热力图 · `candlestick` K 线 · `sankey` 桑基 · `sunburst` 矩形树图 ·
`themeRiver` 主题河流 · `tree` 树图 · `graph` 关系图

> [!TIP]
> 想要**脑图 / 思维导图**，两条路：ECharts 的 `tree` / `graph` 系列（适合数据结构化的场景），
> 或者直接用 `markmap`（写 Markdown 大纲就能出图，更省事）。

折线 + 柱状混合，直接贴合法 JSON：

```echarts
{
  "title": { "text": "字数与阅读时长", "left": "center" },
  "legend": { "bottom": 0, "data": ["字数", "阅读分钟"] },
  "xAxis": { "type": "category", "data": ["周一", "周二", "周三", "周四"] },
  "yAxis": [
    { "type": "value", "name": "字" },
    { "type": "value", "name": "分钟" }
  ],
  "series": [
    { "name": "字数", "type": "bar", "barWidth": "40%", "data": [1200, 860, 1440, 700] },
    { "name": "阅读分钟", "type": "line", "yAxisIndex": 1, "smooth": true, "data": [22, 15, 28, 12] }
  ]
}
```

> [!WARNING]
> ECharts 块必须是**合法 JSON**。键名的引号可以省（`{signal: …}` 那种会被自动补上），
> 但**字符串值必须带引号**，也不能写注释和尾逗号。

---

## 四、WaveDrom：数字波形（新增引擎）

语言名 `wavedrom`，内容写 WaveJSON。支持 WaveDrom 的全部三种图：

| 种类 | 顶层键 | 画什么 |
| --- | --- | --- |
| 时序波形 | `signal` | 时钟、总线、分组、箭头 |
| 逻辑门图 | `assign` | 信号怎么被门电路合成 |
| 寄存器位段 | `reg` | 指令 / 寄存器的位划分 |

一段总线握手时序：

```wavedrom
{
  "signal": [
    { "name": "clk",  "wave": "p........" },
    { "name": "req",  "wave": "01..0..10" },
    { "name": "gnt",  "wave": "x.34x..2x", "data": ["读", "写", "中"] },
    ["总线", { "name": "addr", "wave": "x.3..4x", "data": ["A0", "A1"] },
             { "name": "data", "wave": "x..34.x", "data": ["D0", "D1"] }],
    { "name": "箭头", "wave": "2........", "node": "a........" }
  ],
  "head": { "text": "总线握手", "tick": 0 },
  "foot": { "text": "WaveDrom 实测", "tocks": 8 }
}
```

寄存器位段图（指令格式最常用这个）：

```wavedrom
{
  "reg": [
    { "name": "opcode", "bits": 8,  "attr": "操作码" },
    { "name": "addr",   "bits": 16 },
    { "bits": 4, "attr": "保留" },
    { "bits": 4, "attr": "标志" }
  ],
  "config": { "bits": 32 }
}
```

逻辑门图（`assign`，一行一个表达式）：

```wavedrom
{
  "assign": [
    ["&", "A", "B", "=", "C"],
    ["|", "C", "D", "=", "F"],
    ["~", "F", "=", "Q"]
  ]
}
```

> [!NOTE]
> **深浅主题都用浅色波形面板**。三种图的底色统一固定为不透明白色：
> `signal` 的白底板是 WaveDrom 皮肤自己画的，`reg` / `assign` 两条路径**不画底板**
> （位段框、分隔线、文字是库里硬编码的黑色描边），深色卡片里等于黑底写黑字、
> 整块糊掉 —— 澄笺会给缺底板的图补一块白底，所以不用配置。
> 官方 dark 皮肤同理不换：它也是白底，换过去只会变成"白底上铺浅色描边"，波形糊掉。

---

## 五、Graphviz

语言名 `graphviz`，内容写 DOT。实测支持 `digraph` / `subgraph cluster_*` 聚类 / 边标签 /
CJK 文字，布局引擎 `dot`：

```graphviz
digraph 渲染管线 {
  rankdir=LR;
  node [shape=box, style=rounded];
  源码 -> 解析器 -> 块结构 -> 视图;
  解析器 -> 大纲;
  subgraph cluster_web {
    label = "Web 渲染层";
    KaTeX; Mermaid; ECharts; WaveDrom;
  }
  块结构 -> KaTeX;
  块结构 -> Mermaid;
  块结构 -> WaveDrom;
}
```

---

## 六、数学公式

| 用途 | 引擎 | 说明 |
| --- | --- | --- |
| 块级公式 `$$…$$` / `\[…\]` | KaTeX 0.19.0 | 完整渲染；未就绪时先用自研 MathLite 线性化兜底，不留空白 |
| 行内公式 `$…$` / `\(…\)` | KaTeX 渲染成图内联 | 与正文同基线，可点开放大 |

覆盖范围（矩阵 / 分段 / 对齐 / 积分 / 装饰 / 字体 / 自定义宏等）在
「澄笺示例 · 全功能演示」第四节有 17 类逐条实测样例。

明确**不支持**的：`\href`（外链）、`\includegraphics`（嵌图）、`\ce{}`（mhchem 化学式）。

---

## 七、Markdown 扩展语法支持矩阵

| 语法 | 支持 | 备注 |
| --- | :---: | --- |
| GFM 表格 + 列对齐 | ✅ | 单元格内可写行内标记 |
| 围栏代码块 | ✅ | 三个反引号与三个波浪号都认，带语言名高亮 |
| 脚注 `[^标签]` | ✅ | 标签可用中文 |
| 提示块 `[!NOTE]` 等 | ✅ | 五类：NOTE / TIP / IMPORTANT / WARNING / CAUTION |
| 折叠块 `<details>` / `::: details` | ✅ | 原生写法、带属性的 `<details open>`（默认展开）与冒号容器都收成可折叠面板；summary 里可放行内标记 |
| 删除线 `~~x~~`、高亮 `==x==` | ✅ | |
| 上标 `^x^`、下标 `~x~` | ✅ | |
| Emoji 短代码 `:smile:` | ✅ | |
| YAML Front Matter | ✅ | 首行 `---` 到 `---`/`...`，抽成信息卡片，不进正文与大纲 |
| 引用式链接 `[a][id]` + `[id]: url` | ✅ | |
| 裸 URL 自动链接 | ✅ | 遇到空格与中文标点自动收尾 |
| 站内锚点 `[文字](#标题)` | ✅ | 按**标题文字**归一化匹配，忽略空格与 `-` `_` `.` `/` 等 |
| 显式标题 ID `## 标题 {#intro}` | ✅ | 花括号不再显示在标题里；导出的网页给 `<h*>` 加真 `id`，中文 id 也可以。阅读页跳转仍按标题文字匹配，两种写法都能跳 |
| 定义列表（`术语` + `: 定义`） | ✅ | 术语一段、每条定义单独一块（可单独批注）；导出不套 `<dl>` 而是缩进段 |
| 行内 HTML（`<kbd>` `<ruby>` `<span style="color">` `<u>` `<mark>` `<sub>` `<sup>` `<a>` `<img>` `<br>`） | ✅ | 键帽用窄空格当内边距（`Span` 没有 padding）；注音是「小号 + 上移」贴在基准字右上，真要压在字上方得整段改 StyledString 自绘，与选词、批注互斥，不做——想看到真注音就把这段写进 html 围栏块走 WebView；`<script>` / `<style>` 丢弃，颜色只放行十六进制 |
| 块级 HTML（`<table>` 合并单元格、`<div style>`、`<svg>`、`<figure>`、音视频） | ✅ | 整段交给内嵌 WebView 渲染（`render/html.html`），所以 colspan / rowspan 这类排版能用；自动识别的块级 HTML 会先摘掉 `<script>` `<iframe>` 与 `on*` 事件属性 |
| 4 空格 / Tab 缩进代码块 | ✅ | 老式写法；紧跟段落的缩进行仍是段落续行，隔一行空行才收成代码 |
| Diff 代码块 ` ```diff ` | ✅ | 按行首 `+` / `-` / `@@` 整行着色（阅读页、导出、放大视图三处一致） |
| 指定行高亮 ` ```js{1,3-5} ` | ✅ | VitePress / Shiki 写法，也认 `hl_lines="1 3"`；阅读页琥珀行底，导出网页同色 |
| 代码组 `::: code-group` | ✅ | 阅读页是真页签；导出的静态网页没有脚本，退成「每段带标题的代码块」，内容一段不丢 |
| 冒号容器 `::: tip / warning / danger / info / details` | ✅ | 前四类映射成提示卡，`details` 收成折叠面板 |
| 粗斜体 `***文字***` | ✅ | 三连是「又粗又斜」，不再漏出字面星号；`*斜 **粗** 斜*` 的嵌套同样收得住 |
| HTML 字符实体 `&amp;` `&#124;` `&#x2014;` | ✅ | 常用命名实体 37 条 + 数字实体全收；行内代码里保持字面 |
| 表格里的竖线 `\|` | ✅ | 转义竖线不断列，`&#124;` 同样可用 |
| 自动目录 `[TOC]` | ✅ | 单独占一行才展开：换成一份按标题层级的列表，每条是 `[标题](#标题)`，点了就跳；导出网页同样可跳。行内出现 `[TOC]` 字样不误伤 |
| 行内脚注 `^[直接写内容]` | ❌ | 脚注走 `[^标签]` + 文末 `[^标签]: 内容` 两段式；行内那种按普通文字显示 |
| 注释式行高亮 `// [!code highlight]` | ⚠️ 降级 | 注释留在代码里，行不 Highlight；指定行请用围栏元数据（上一行那种 ✅ 写法） |
| `+++` 分页（pymdownx.tabbed） | ❌ | 代码组请用 `::: code-group`（上一条），正文分组用提示块或折叠面板 |
| 尖括号自动链接 `<https://…>` `<mailto:…>` `<a@b.com>` | ✅ | 链接文字与地址都不带尖括号；邮箱那种会补上 `mailto:` 前缀。阅读页对 mailto 是**复制地址**（浏览器拉起需要系统能力），网页版正常打开信箱 |
| 硬换行（行尾两空格 / 反斜杠） | ❌ | 段内换行会被并成空格 |
| Pandoc 文献引用 `[@key]`、`-F pandoc-citeproc` | ⚠️ 降级 | 只显示成 `[key]` 上标样子，**不生成参考文献表** —— 没有 bibtex/CSL 数据源，编号与"点击跳到文献"都无从算起。要引用请把文献表自己写在文末（脚注是更合适的载体） |
| Pandoc 图表编号 `![图](a.png){#fig:x}` | ❌ | 图片正常显示，尾部的 `{#fig:x}` 会留在行尾；不自动编号、也不解析 `@fig:x` 交叉引用（同上：需要编号引擎与全文索引，离线渲染器里没有） |
| MDX（`<Component />` 带 props、`export` / `import`） | ❌ | MDX 要在构建期把 JSX 编译成组件，运行时才有组件可渲染；阅读器是"打开即渲染"，没有构建步骤，也没有组件沙箱。这类标签会按上面的"块级 HTML"处理成静态内容，交互部分自然不出现 |

---

## 八、渲染之外的能力

- **导出**：HTML（自包含，渲染库直接内嵌，离线打开也能出图）、Markdown、EPUB、PDF 打印。
- **图片**：文档内图片点击放大，双指缩放与拖动。
- **公式与图表放大**：点卡片右上角的放大，进入全屏浮层，支持双指捏合、± 缩放、旋转、
  重新自适应、切看源码。
- **离线**：所有渲染库随应用打包，全程无网络请求；「基础模式」可彻底断网。

---

*清单里的版本号与实测结果对应本应用当前构建；升级渲染库后本页会同步更新。*
