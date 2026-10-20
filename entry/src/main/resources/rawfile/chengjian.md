# 澄笺介绍与功能展示

![澄笺应用图标](chengjian-icon.png)

> **澄笺（ChéngJiān）**，一款为 HarmonyOS 打造的沉浸式 Markdown 阅读与写作应用。
> 「澄」是澄澈透光，「笺」是文人纸笺 —— 我们把这两件事放在了一起：
> 玻璃质感的界面，与一张安静好写的纸。

这一篇不只是介绍文档，更是**渲染效果的验收样张**：从头读下去，你会依次看到排版、
批注、公式、十类图表、导出与手写，最后还有一整章**各引擎的实测能力**（第十节：
哪个图种出得来、哪个是降级、哪个根本不接）。如果你看到每一节都正确显示，说明这台设备上的渲染链路工作正常。

> [!TIP]
> 想边读边试？长按任意一段文字试试批注；或者点卡片右上角的「⋯」把这篇文档切成
> 「可写」，直接在上面改。

---

## 一、它是什么

一句话：**本地优先、不打扰、能装下复杂内容的 Markdown 工具。**

| 你关心的事 | 澄笺怎么做的 |
| --- | --- |
| 我的文件在哪 | 全部在本机应用目录里，不联网也能用（可用「基础模式」彻底断网） |
| 阅读体验 | 五档纸色主题、四档字号、可换字体、可调行距与栏宽 |
| 界面观感 | 默认纯色卡片；可开「沉浸光感」（API 26 材质，通透玻璃，略耗电）与「过渡动画」 |
| 写东西 | 多标签、分屏实时预览、版本历史、查找替换、语法速查 |
| 标东西 | 长按选字做批注（荧光底 / 波浪线）、手写笔记、手写批注 |
| 复杂内容 | 公式、流程图、时序图、思维导图、统计图、乐谱，全部**离线**渲染 |
| 拿出去 | 导出 HTML（自包含单文件）/ Markdown，系统打印，跨设备分享 |

### 开源与致谢

**源码仓库**

- GitHub：[FengHDSL/LiteMdReader-HarmonyOS](https://github.com/FengHDSL/LiteMdReader-HarmonyOS)
- Gitee：[pandasoos/LiteMdReader-HarmonyOS](https://gitee.com/pandasoos/LiteMdReader-HarmonyOS)

**开源许可**：澄笺以 **MIT License** 开源 —— 可以自由地使用、修改、再分发；
唯一的要求是保留版权声明与许可文本，全文见仓库根目录的 `LICENSE` 文件。

**参考的项目**（仅参考思路，未复制其代码）

- [MrCashmere/miha_hm](https://github.com/MrCashmere/miha_hm)：沉浸光感承载层（Toggle + attributeModifier）方案
- [skadjhljhas/zhumo-reader](https://github.com/skadjhljhas/zhumo-reader)：注释卡片式的阅读形态
- [younghz/Markdown](https://github.com/younghz/Markdown)：《Markdown 语法教程》的语法口径与分类参考
- [Vditor](https://b3log.org/vditor/)：浏览器端 Markdown 编辑器（b3log / 88250 团队）；该团队的
  [链滴](https://ld246.com) 社区所著《Markdown 使用指南》系列是本文档第三节语法教程的分节与
  覆盖面参考（详见文末「参考与声明」）
- [luvi/lv-markdown-in](https://gitee.com/luvi/lv-markdown-in)：代码块行号 / 折叠 / 操作区、HTML 常用标签与 **font 快速样式**、懒渲染与预渲染块数的实现思路

**内置的渲染组件**（随应用打包、全部离线可用，各自遵循其原始开源许可，许可全文见各自仓库）：

| 组件 | 用途 |
| --- | --- |
| Mermaid（v11） | 流程图 / 时序图 / 状态图 / 类图 / 甘特图 / 饼图 / 看板 / 架构图 / 数据包图 |
| @plantuml/core | PlantUML 官方内核（TeaVM 编译），14 个图种离线出图 |
| Apache ECharts | 柱状 / 折线等统计图 |
| Chart.js | 数据可视化（JSON 配置，四类入门示例见下） |
| Vega / Vega-Lite | 声明式统计图（矢量 SVG） |
| Markmap（含 d3） | 思维导图 |
| Graphviz（viz.js） | 关系网络图 |
| flowchart.js | 流程图（另一套写法） |
| nomnoml（含 graphre） | 极简 UML 类图 |
| KaTeX + mhchem | 数学公式与化学方程式 |
| MathJax | 公式兜底引擎（KaTeX 未就绪时） |
| abcjs | 五线谱（ABC 记谱） |
| WaveDrom | 数字波形 / 逻辑门 / 寄存器位段图 |
| Lute | Markdown 解析 |

### 它不太想做的事

- 不想让你注册账号：没有登录页，没有云端账号体系。
- 不想替你决定文件去哪：导入就是复制一份进应用，原文件不动。
- 不想在你读书时打扰你：网络链接**点击只复制地址**，不弹浏览器。

---

## 二、界面一览

### 书架

网格与列表两种形态，长按封面拖动可**合并成文件夹**；封面颜色由文件名哈希生成，
也能自己指定底色或换成图片。集齐的文档可以拖来拖去重新排序。

- [x] 继续阅读横幅（可在「外观设置」里关掉）
- [x] 长按拖动合并 / 收进文件夹
- [x] 全文搜索：文件名、正文、图片三组结果
- [x] 列表模式：树形的文件夹展开

### 阅读页

正文区之外，一切都可以收起来：

- 顶栏 / 底栏滚动时自动收起，上滑或回顶恢复；
- 左侧目录、右侧批注可停靠（大屏专属），列表里的批注可一键跳回原文；
- 标签栏可以放在顶部，也可以沉到底部胶囊里；
- 信息卡展示字数、行数、标题数、代码块数、文件大小、MD5 / SHA-256。

### 编辑器

| 能力 | 说明 |
| --- | --- |
| 多标签 | 同时开好几篇，标签名过长自动截断 |
| 分屏预览 | 左写右看，两侧滚动互相带 |
| 版本历史 | 定时快照 + 手动记录；支持左右**分屏对比**（新增行 / 删除行着色） |
| 查找替换 | 支持正则式的匹配计数、上一处 / 下一处、全部替换 |
| 语法速查 | 十八行语法，点一行插到光标位置，旁边就是真实渲染效果 |
| 手写 | 调起手写画布，写完插入正文或作为批注 |

---

## 三、Markdown 语法教程

> [!NOTE]
> 这一节**既是教程也是样张**：下面每一条示例都在这篇文档里真实渲染，看到的排版就是它自己的效果。
> 语法的分类与讲解顺序参考了链滴 Vanessa 的《Markdown 使用指南》系列（见文末**参考与声明**），
> 但内容**按澄笺的实际支持情况逐条重写**了 —— 标准写法很多，澄笺只实现了一部分，
> 不支持的会在 3.16 明确列出，免得你照着写完发现没反应。

### 3.1 标题

两种写法都认。ATX 用 `#` 的个数定层级（1~6 级），Setext 用下一行的 `===` / `---`：

```
# 一级标题        ←  本文档的大节用 ##，所以正文里你看不到 H1
## 二级标题         ←  就是「三、Markdown 语法教程」这一行
### 三级标题        ←  就是「3.1 标题」这一行
…… 一直到 ######  六级

Setext 一级标题
===============

Setext 二级标题
---------------
```

**最佳实践**：一篇文档只放一个 H1；别跳级（H2 下面直接 H4）—— 澄笺的目录面板按层级缩进，跳级会看起来错位。

### 3.2 段落与折行

空一行就是新段落。这是第一段。

这是第二段，中间隔了一个空行。

> [!WARNING]
> **澄笺没有"硬换行"**：段落内部的单次换行会被并成一个空格（上面这两段就是靠空行分开的）。
> 常见的"行尾加两个空格"或"行尾加 `\`"在澄笺里都不产生换行。要断行就空行分段，
> 或者改用列表、表格、引用。

### 3.3 强调与标记

**粗体**、*斜体*、***粗斜体***、~~删除线~~、==高亮==、`行内代码`、上标 x^2^、下标 H~2~O。

同一个词可以叠加：***又粗又斜***、**粗体里有 `代码` 和 ==高亮==**。

**下划线（`_`）与斜体的分界**，这是最容易踩的一条：

| 写法 | 渲染成 | 为什么 |
| --- | --- | --- |
| `_斜体_`、`__粗体__` | 斜体 / 粗体 | 定界符两侧是空格或标点，算"词边界" |
| `user_name`、`md_chart_id`、`__init__.py` | **原样**（词内不算强调） | ASCII 词内的 `_` 不作定界符 |
| `这是_一_个测试` | **原样** | 中文也是"词字符"，同一条规则（按 Unicode 判，不是只看 a-zA-Z） |
| `这是*一*个测试` | 斜体 | `*` 允许词内强调，只有 `_` 不允许 |
| `\_(转义)` | 一个下划线字符 | 反斜杠优先 |

**想要真正的下划线**，`_` 不是给它用的（`_x_` 归斜体），走这三条之一：
`++插入线++`（= HTML 的 `<ins>`，导出也是真 `<ins>`）、`<u>下划线</u>`、`<ins>插入</ins>`。

### 3.4 块引用与提示块

> 单层引用。
>
> > 嵌套一层，适合"引用里再引用"。
> >
> > > 还能更深，但手机上三层已经很挤了。

提示块是 GFM 风格，一共五类，颜色各不相同 —— NOTE 蓝、TIP 绿、IMPORTANT 紫、WARNING 黄、CAUTION 红：

> [!TIP]
> 提示块要在 `> [!类型]` 之后**换行**写正文，写在同一行不会被识别。

> [!CAUTION]
> 类型名不区分大小写，`> [!tip]` 和 `> [!TIP]` 一样；但必须是这五种之一，写错会退化成普通引用。

### 3.5 列表

无序列表的 `-` `*` `+` 三种标记等价（**建议统一用 `-`**，混用时源码不好读）：

- 第一项
- 第二项里可以有 **粗体**、`代码`、[链接](#3-5-列表) 和 ==高亮==
  - 缩进两格就是嵌套
  - 嵌套层里再来一层：
    - 第三层
    - 还是第三层
- 收尾项

有序列表按数字自增，中间换编号不打断顺序：

1. 第一步
2. 第二步
3. 第三步

列表项可以有**续行**：比标记缩进更深、又不算新块起始的行，会接进同一个列表项 ——

- 这是第一项的第一行，
  这是它的续行，两行都属于第一项。
- 第二项。

> [!WARNING]
> **列表项里嵌不了代码块和引用**。围栏、`>` 开头、标题、分隔线、脚注定义、另一个列表标记，
> 在澄笺里都算"新的块起始"，遇到它们当前列表就地断开，那些内容会作为**独立的块**显示在下面。
> 空一行同样会结束当前列表。想要"代码块紧跟在列表后面"，直接写在列表下面即可，只是它不属于那一项。

任务列表（GFM）：

- [x] 已完成：把这篇文档读完
- [ ] 待办：长按一段文字试试批注
- [ ] 待办：把标签栏切到底部看看

### 3.6 代码

行内代码用一对反引号包住：`npm run build`、`SELECT * FROM docs`。

> [!WARNING]
> 澄笺的行内代码**只认单对反引号**：内容里不能再出现反引号，标准里"外面用两个反引号来包住
> 含反引号的内容"这种写法在澄笺不生效（会被当成一对空代码块）。要写反引号本身，只能放进围栏代码块。

围栏代码块：单独一行写三个反引号起始，后面可以跟语言名以获得语法高亮；再以单独一行同样的标记结束。
另一种起始标记是三个波浪号。

```js
const greet = function (name) { return '你好，' + name; };
```

~~~python
def fib(n):
    return n if n < 2 else fib(n - 1) + fib(n - 2)
~~~

语言名写成 `mermaid` / `echarts` / `chart` / `markmap` / `graphviz` / `flowchart` / `nomnoml` / `abc` / `html`
时不再是"高亮代码"，而是**直接渲染成图表或可交互预览** —— 见第五节和第九节。

### 3.7 分隔线

下面这条就是 `---`（`***`、`___` 等价）：

---

### 3.8 超链接

三种写法（**这一节里的网址都是 `example.com` 占位域名**，专门留给文档示例用，
不是真实站点；本文档只有「开源与致谢」和文末「参考与声明」里放真链接）：

- 行内式：[带标题的链接](https://example.com "示例站点")（URL 后面空格加引号写标题，标题只在悬停/提示里出现）
- 引用式：正文写 [引用式链接][ref-1]，文末（任意位置）写定义 —— 适合同一个链接出现很多次
- 自动链接：裸写 https://example.com 就会自己变成链接

引用式定义长这样（上面那个"引用式链接"就是靠它生效的，点开是占位页）：

[ref-1]: https://example.com/guide "引用式链接的定义"

**不想让某个 URL 变成链接**？把它写成行内代码就不会自动识别：`https://example.com`。
（别指望反斜杠 —— 可转义字符集合里没有冒号，`https\://…` 会把那个反斜杠原样显示出来。）

**站内跳转**：`#` 后面写**目标标题的文字**，例如 [← 跳回 3.5 列表](#3-5-列表)。
匹配时会忽略空格、大小写和常见标点（`-` `_` `.` `/` `·` `。` `，` `、` `：` `:`），
所以 `#3.5 列表`、`#3-5-列表`、`#35列表` 都能命中同一个标题。找不到时会提示"找不到锚点"。

> [!WARNING]
> 澄笺**不认尖括号写法** `<https://example.com>` —— 那不是自动链接，会照原样显示字符。
> 另外站内锚点用的是"标题文字"，**不是** GitHub 那种 `#my-section-id` 片段。

### 3.9 图片

```
![替代文字](images/cover.png "标题，可省略")
[![点我打开首页](小图.png)](https://example.com)
```

链接套图片是合法的，整张图会变成可点的链接。图片的实际显示效果与点击放大见第二节。

### 3.10 转义字符

在符号前加反斜杠即可让它失去语法含义，澄笺认这一批：

```
\  `  *  _  {  }  [  ]  (  )  #  +  -  .  !  ~  =  |  >
```

例如想写出字面的 \*\*不是粗体\*\*，或者 1990\. 不想被当成有序列表。

### 3.11 表格

冒号控制列对齐：`:---` 左、`:---:` 中、`---:` 右。单元格里**可以写行内标记**：

| 能力 | 入口 | 说明 |
| --- | :---: | ---: |
| 全文搜索 | 书架顶栏 | 正文与文件名都搜 |
| 文档内查找 | 阅读页 | 命中**全部高亮** |
| 跳转行 | 编辑页 → 更多 | 输入行号直达 |
| 版本对比 | 编辑页 → 版本历史 | 左右分屏，支持 `==高亮==` |

表格过宽时内部横向滚动；点表格会打开可视化编辑器。

### 3.12 脚注

正文里放一个引用[^1]，另一处再来一个[^2]。

[^1]: 脚注定义写在文档任意位置（`[^标签]: 内容`），澄笺会把它们收集起来统一展示。
[^2]: 标签可以是中文，比如 `[^注]` 配 `[^注]: 内容`，只要两边一致。

### 3.13 Emoji

短代码 `:名字:` 会渲染成表情：:smile: :grin: :joy: :rofl:。
中文标点、emoji 直接打进正文也完全正常，不必都走短代码。

### 3.14 折叠块

块级的 `<details>` / `<summary>` 会被识别成可展开的折叠块（正文里的其他 HTML 标签不算）：

<details>
<summary>点我展开：一段不想常驻屏幕的补充说明</summary>

折叠起来的内容支持完整的行内标记 —— **粗体**、`代码`、列表都行。

- 比如这样一个列表项

</details>

### 3.15 正文里的 HTML

行内 HTML 的常用标签（`<kbd>` 键帽、`<ruby>` 注音、`<u>`/`<ins>` 下划线、`<mark>`、
`<small>`、`<b>`/`<i>`/`<s>`、`<a>`、`<img>`、`<br>`、`<span style="color:…">`…）都能渲染，
完整清单与放行的样式见最后一节的能力总览；不认识的成对标签会**脱掉标签、留下内容**，
`<script>` / `<style>` 整段丢弃。

块级 HTML（`<div>` / `<table>` / `<svg>` / `<figure>` / `<details>`…）整段收成一张
**网页预览卡**（`render/html.html`），所以 colspan / rowspan、内嵌 SVG、进度条这类
ArkUI 文本排不出来的东西能原样显示；自动识别出来的块会先摘掉 `<script>` `<iframe>`
与 `on*` 事件属性。

把语言写成 `html` 的**围栏代码块**不走上面那条闸，它按"我知道我在跑这段 HTML"处理：
渲染成可交互的预览卡片，`<script>` 照常执行 —— 见第九节那个能用手指点着放的烟花。

> [!TIP]
> **GitHub README 的铭牌（shields 徽章）专门做了离线渲染**：
> `[![Version](https://img.shields.io/badge/version-1.4.1-blue)](…)` 这类**整行徽标**被识别成
> 「铭牌」，用本地绘制代替远程图片 —— 网络拉不到、基础离线模式下都照常显示，
> 点一下打开它包着的链接；HTML 块里的 `<img src="https://img.shields.io/…">` 同样就地替换。
>
> 认得的写法：`/badge/<标签>-<值>-<颜色>` 两段与三段式、`?label=` `?color=` `?labelColor=`
> `?style=` 覆盖、`/static/v1?label=&message=&color=` 入口，形态有 `flat` / `flat-square` /
> `plastic` / `for-the-badge` / `social`；颜色既收十六进制与 `rgb()`，也收 shields 自己的
> 命名色（用实测值，不是 CSS 那套）。`?logo=` 的小图标不画。
> 夹在句子中间的徽标、以及要调 API 的动态徽章（`/github/v/release/…`）仍走网络图片，
> 拉不到时和普通图片一样显示不出来。

### 3.16 澄笺不支持的写法

这一节原先列的「4 空格缩进代码块 / 尖括号自动链接 / 标题自定义 ID / 行内 HTML」**都已经支持了**，
留在"不支持"里会劝人不用写；现在只留真的没做的：

> [!CAUTION]
> - **硬换行**（行尾两空格 / 行尾 `\`）：段内换行会被并成空格，见 3.2
> - **行内脚注** `^[内容直接写在后面]`：脚注是 `[^标签]` + 文末定义两段式，见 3.13
> - **`+++` 分页**（pymdownx.tabbed 那套）：代码分组用 `::: code-group`，正文分组用提示块或折叠面板
> - **跨文件引用 / include**：澄笺是单文档模型，没有 `{% include %}` 之类的机制
> - **Pandoc 的图表编号与文献引用**、**MDX 可交互组件**：支持**可静态翻译的子集**（见下面两段活例子）

MDX 的本体是"构建期把 JSX 编译成 React 组件"，离线阅读器没有组件运行时。但示例里的
常见形状可以按语义翻译，澄笺现在这么做：

- `import …` 行：渲染态不显示（与各家 MDX 表现一致）；
- `<Tabs><TabItem value="x">…</TabItem></Tabs>`：翻译成**标签组**（页签可点）；
- `<Chart data={[…] } type="bar" />`：翻译成 **Chart.js 真图表**；
- 其它 `<组件>内容</组件>`：保留组件名做小标题、内容按 Markdown 渲染（不静默吞内容）。

真正"运行组件"（跑 React 组件逻辑、访问外部模块）仍需构建期编译，离线不做。

**Pandoc 专属：图表编号 + 文献引用**

![澄笺应用图标](chengjian-icon.png){#fig:icon width=60%}

如图 @fig:icon 所示，Markdown 的语法设计受[@gruber2004]影响。

pandoc 的图表编号（`{#fig:x}` / `@fig:x`）**已按反馈移除**——离线实现与预期观感不符。
现在只保留属性块词法本身：`{#id .类名 key=value}` 的花括号照常吃掉不显示，
`@fig:x` 与图注文字原样保留（不伪装成"图 1"）。

**文档内不做**：pandoc 的过滤器链（Lua filter）、`.bib` 文献库解析与样式化——这两项依赖
pandoc 本体运行时，本应用不假装支持。

---

## 四、数学公式

公式由 **KaTeX** 排版，行内与块级四种写法都支持：`$…$`、`\(…\)`、`$$…$$`、`\[…\]`。
下面按类别给出**可直接复制走**的写法，全部是真实渲染结果（不是截图），逐条对照即可
判断某类语法是否受支持。

### 4.1 行内：混在句子里

质能方程 $E = mc^2$，勾股定理 $a^2 + b^2 = c^2$，圆面积 $S = \pi r^2$，欧拉恒等式
$e^{i\pi} + 1 = 0$，标准差 $\sigma = \sqrt{\frac{1}{N}\sum_{i=1}^{N}(x_i-\mu)^2}$。

> [!WARNING]
> 开头的 `$` 后面**不能紧跟空格**：`$ a+b $` 会被当成普通美元符号，要写 `$a+b$`。

### 4.2 希腊字母

$\alpha,\ \beta,\ \gamma,\ \theta,\ \lambda,\ \mu,\ \pi,\ \sigma,\ \phi,\ \omega$

$\Gamma,\ \Delta,\ \Theta,\ \Lambda,\ \Sigma,\ \Phi,\ \Omega$

### 4.3 上下标

普通上标 $x^2,\ e^{i\pi},\ a^{b^c}$；普通下标 $x_1,\ a_{ij},\ H_2O$；
同排上下标 $x_1^2,\ A_{ij}^{k}$。

### 4.4 分式与根式

行内有 $\frac{a}{b},\ \frac{n!}{k!},\ \tfrac{1}{2},\ \dfrac{x+1}{x-1}$，根式有
$\sqrt{x},\ \sqrt[3]{8},\ \sqrt[n]{x^2}$。嵌套分式单独成块更清楚：

$$
\frac{1}{1 + \frac{1}{1 + \frac{1}{x}}}
$$

### 4.5 运算符、关系与逻辑

$+,\ -, \times,\ \div,\ \pm,\ \mp,\ \cdot,\ \ast,\ \star,\ \circ$

$\oplus,\ \otimes,\ \odot,\ \bullet,\ \cap,\ \cup$

$=,\ \neq,\ <,\ >,\ \leq,\ \geq,\ \ll,\ \gg,\ \approx,\ \equiv,\ \propto,\ \sim$

$\forall,\ \exists,\ \neg,\ \wedge,\ \vee,\ \therefore,\ \because$

### 4.6 箭头

$\to,\ \rightarrow,\ \leftarrow,\ \uparrow,\ \downarrow,\ \mapsto,\ \longmapsto$

$\Rightarrow,\ \Leftarrow,\ \Leftrightarrow,\ \implies,\ \iff,\ \longrightarrow$

### 4.7 集合论

$\subset,\ \subseteq,\ \supset,\ \in,\ \notin,\ \setminus,\ \emptyset,\ \varnothing$

数集记号 $\mathbb{N},\ \mathbb{Z},\ \mathbb{Q},\ \mathbb{R},\ \mathbb{C}$，
描述法 $\{x \in \mathbb{R} \mid x^2 < 2\}$。

### 4.8 括号与定界符

自动缩放会跟着内容长：

$$
\left( \frac{a}{b} \right),\quad \left[ \frac{a}{b} \right],\quad \left\{ \frac{a}{b} \right\},\quad \left| \frac{a}{b} \right|,\quad \left\| \frac{a}{b} \right\|
$$

手动四档 $\big( x \big),\ \Big( x \Big),\ \bigg( x \bigg),\ \Bigg( x \Bigg)$，
嵌套也没问题 $\left( \left[ \left\{ \frac{a}{b} \right\} \right] \right)$。
取整与内积：$\lfloor x \rfloor,\ \lceil x \rceil,\ \langle u, v \rangle$。

### 4.9 矩阵与行列式

五种括号样式一次给全，外加可自定义对齐与分隔线的 `array`：

$$
\begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}
\qquad
\begin{bmatrix} a & b \\ c & d \end{bmatrix}
\qquad
\begin{Bmatrix} p & q \\ r & s \end{Bmatrix}
$$

$$
\begin{vmatrix} x & y \\ z & w \end{vmatrix} = xw - yz
\qquad
\begin{Vmatrix} a & b \\ c & d \end{Vmatrix}
$$

$$
\begin{array}{c|c}
a & b \\
\hline
c & d
\end{array}
\qquad
\begin{matrix} 1 & 0 \\ 0 & 1 \end{matrix}
$$

分块矩阵（矩阵套矩阵）：

$$
\begin{pmatrix}
\begin{matrix} 1 & 0 \\ 0 & 1 \end{matrix} & 0 \\
0 & \begin{matrix} 1 & 0 \\ 0 & 1 \end{matrix}
\end{pmatrix}
$$

矩阵乘向量：

$$
\begin{pmatrix} a & b \\ c & d \end{pmatrix}
\begin{pmatrix} x \\ y \end{pmatrix}
= \begin{pmatrix} ax + by \\ cx + dy \end{pmatrix}
$$

### 4.10 分段函数与多行对齐

$$
f(x) =
\begin{cases}
1, & x = 0 \\
\dfrac{\sin x}{x}, & x \neq 0
\end{cases}
$$

$$
\begin{aligned}
(a + b)^2 &= a^2 + 2ab + b^2 \\
(a - b)^2 &= a^2 - 2ab + b^2
\end{aligned}
$$

$$
\begin{aligned}
\sin x &= x - \frac{x^3}{3!} + \frac{x^5}{5!} - \cdots \\
&= \sum_{n=0}^{\infty} \frac{(-1)^n}{(2n+1)!}\,x^{2n+1}
\end{aligned}
$$

居中堆叠用 `gathered`，只在一侧加括号用 `\right.`：

$$
\begin{gathered}
a^2 + b^2 = c^2 \\
e^{i\pi} + 1 = 0
\end{gathered}
\qquad
\left\{ \begin{array}{ll} 1 & \text{if } x > 0 \\ 0 & \text{if } x \le 0 \end{array} \right.
$$

### 4.11 微积分

极限：

$$
\lim_{x \to 0} \frac{\sin x}{x} = 1
\qquad
\lim_{n \to \infty} \left(1 + \frac{1}{n}\right)^n = e
\qquad
\underset{x \to 0}{\lim} f(x)
$$

导数与偏导 $\frac{dy}{dx},\ f'(x),\ y'',\ \frac{\partial f}{\partial x},\ \frac{\partial^2 f}{\partial x \partial y}$，
梯度 $\nabla f = \left( \frac{\partial f}{\partial x}, \frac{\partial f}{\partial y} \right)$。
微积分基本定理：

$$
\frac{d}{dx}\left( \int_{a}^{x} f(t)\,dt \right) = f(x)
$$

四种积分：定积分 $\int_{a}^{b} f(x)\,dx$、二重 $\iint_{D} f(x,y)\,dx\,dy$、
三重 $\iiint_{V} f(x,y,z)\,dV$、曲线 $\oint_{\gamma} f\,ds$。高斯积分：

$$
\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
$$

### 4.12 求和、乘积与组合数

$$
\sum_{i=1}^{n} i = \frac{n(n+1)}{2}, \qquad
\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}
$$

$$
\prod_{k=1}^{n} k = n!
\qquad
\sum_{i=0}^{n} \binom{n}{i} = 2^n
\qquad
\binom{n}{k} = \frac{n!}{k!(n-k)!}
$$

### 4.13 装饰符号

上划线 $\overline{z},\ \overline{AB}$，下划线 $\underline{x}$；
帽子 $\hat{a},\ \widehat{ABC}$；波浪线 $\tilde{x},\ \widetilde{ABC}$；
向量 $\vec{v},\ \overrightarrow{AB}$；时间导数 $\dot{x},\ \ddot{x},\ \dddot{x}$；
上下标注 $\overset{\text{def}}{=}$，括号说明
$\underbrace{1 + 1 + \cdots + 1}_{n\ \text{个}} = n$，
$\overbrace{a + b + c}^{\text{三项}}$。

### 4.14 字体

空心体 $\mathbb{R},\ \mathbb{N},\ \mathbb{Z}$；花体 $\mathcal{F},\ \mathcal{L},\ \mathcal{O},\ \mathcal{P}$；
粗体 $\mathbf{A},\ \mathbf{v},\ \mathbf{x}_1$；粗体希腊字母
$\boldsymbol{\alpha},\ \boldsymbol{\beta},\ \boldsymbol{\theta}$；
正体（微分号与虚数单位）$\mathrm{d}x,\ \mathrm{e},\ \mathrm{i}$。

中文直接写进 `\text{}` 里就行：$\text{如果 } a = b \text{，则 } c = d$，
$\text{当 } x > 0 \text{ 时，} f(x) = x^2$。

### 4.15 框注、编号与颜色

$$
\boxed{E = mc^2}
\qquad
f(x) = x^2 \tag{1}
$$

$\color{red}{\text{红色}}\quad \color{blue}{\text{蓝色}}\quad \color{#2F63E8}{\text{十六进制}}$

### 4.16 自定义宏

`\newcommand` 在同一条公式内定义并使用（带参数用 `[1]`）：

$$
\newcommand{\vctr}[1]{\mathbf{#1}} \lvert \vctr{a} \rvert^2 = \vctr{a} \cdot \vctr{a}
$$

### 4.17 函数名与余波

$\gcd(a, b)\bmod m,\quad \log_2 n,\quad \ln x,\quad \arctan t,\quad \zeta(s) = \sum_{n=1}^{\infty} \frac{1}{n^s}$

> [!TIP]
> 公式太长时**单独成块**（`$$…$$`）比塞进行内更好看：块级公式居中、上下标会
> 展开成分式形式；行内公式为了不打断行高，会把分式压小。

---

## 五、十类图表：这才是重头戏

下面是澄笺支持的全部图表类型。每一节都给出**能直接复制走的最小示例**，以及
"渲染不出来"时最可能的原因。

> [!TIP]
> 所有图表都**离线渲染** —— 渲染库随应用打包，飞行模式下照常出图。
> 画好的图右上角有放大按钮：可缩放、双指捏合、**单指拖动**、还能旋转；
> 放大后工具栏里还可以**存成图片**：浅色底 PNG（与当前主题无关）、按内容边界出图
> （不留大片空白）、等比不拉伸，屏外没画进画布的部分也会完整出图。

### 5.1 流程图（mermaid · graph）

```mermaid
graph TD
  A[打开澄笺] --> B{这篇文档读完了吗}
  B -- 没有 --> C[继续往下读]
  C --> B
  B -- 读完了 --> D{想做什么}
  D -- 写点东西 --> E[新建文档 / 分屏预览]
  D -- 标点东西 --> F[长按选字批注]
  D -- 给别人看 --> G[导出 HTML 或 Markdown]
  E --> H[结束]
  F --> H
  G --> H
```

要点与坑：

- 第一行的 `graph TD` 决定方向：`TD` 上到下、`LR` 左到右、`RL` 右到左、`BT` 下到上。
- `[]` 是矩形、`()` 是圆角、`{}` 是菱形、`(())` 是圆。
- 节点文字里出现括号、冒号等符号时，用引号包住：`A["说明（带括号）"]`。
- 箭头上的文字写 `-- 文字 -->`。

### 5.2 时序图（mermaid · sequenceDiagram）

```mermaid
sequenceDiagram
  autonumber
  participant U as 用户
  participant S as 书架
  participant R as 阅读页
  participant E as 编辑器

  U->>S: 点开一篇文档
  S->>R: 打开阅读页（一镜到底）
  R-->>U: 显示正文与信息卡
  U->>R: 长按选中一句话
  R->>U: 弹出批注胶囊
  U->>R: 选择「波浪线」
  R-->>R: 记录批注（块 id + 区间）
  U->>E: 切到编辑器改正文
  E->>R: 保存后刷新，批注跟随文本
  R-->>U: 回到书架时进度已存盘
```

要点与坑：

- 参与者用 `participant 别名 as 显示名` 起中文名；不写就用默认的 A、B。
- 实线箭头 `->>`、虚线 `-->>`；`autonumber` 会自动编号。
- 想加备注：`Note over U,R: 说明文字`。

### 5.3 状态图（mermaid · stateDiagram）

```mermaid
stateDiagram-v2
  [*] --> 空闲
  空闲 --> 阅读中: 打开文档
  阅读中 --> 已批注: 长按选字
  已批注 --> 阅读中: 完成
  阅读中 --> 空闲: 返回书架
  阅读中 --> 编辑中: 点编辑
  编辑中 --> 阅读中: 保存
  编辑中 --> 空闲: 放弃修改
  空闲 --> [*]
```

要点：`[*]` 是起点 / 终点；`A --> B: 事件` 冒号后是触发条件。

### 5.4 类图（mermaid · classDiagram）

```mermaid
classDiagram
  class 文档 {
    +名称
    +文件大小
    +修改时间
    +进度
    +打开()
    +重命名()
  }
  class 文件夹 {
    +名称
    +包含文档数
    +展开()
    +收起()
  }
  class 批注 {
    +块标识
    +起止位置
    +颜色
    +样式
  }
  class 标签 {
    +名称
    +激活()
    +关闭()
  }
  文件夹 "1" o-- "0..*" 文档 : 收纳
  文档 "1" *-- "0..*" 批注 : 依附
  标签 "1" --> "1" 文档 : 指向
```

要点：`+` 公开、`-` 私有；`o--` 聚合、`*--` 组合、`-->` 关联。

### 5.5 甘特图（mermaid · gantt）

```mermaid
gantt
  title 澄笺 1.0 系列的迭代节奏
  dateFormat YYYY-MM-DD
  axisFormat %m/%d
  section 阅读核心
  渲染与主题           :done,    a1, 2026-09-20, 6d
  目录与批注           :done,    a2, after a1, 5d
  大屏三栏             :done,    a3, after a2, 4d
  section 写作能力
  编辑器与分屏预览     :active,  b1, 2026-10-01, 5d
  版本历史与对比       :         b2, after b1, 4d
  section 图表与导出
  图表离线渲染         :done,    c1, 2026-10-02, 4d
  自包含 HTML 导出     :         c2, after c1, 3d
```

要点与坑：

- `title` 写标题；`dateFormat` 必须与任务日期格式一致（这里都是 `YYYY-MM-DD`）。
- `done` / `active` 标出已完成与进行中；`after 任务名` 让任务接在前一个之后。
- **日期标签挤在一起**？跨度只有两三周时，刻度默认按天铺，`%m/%d` 就糊成一片。
  澄笺已把甘特图刻度固定为**一周一格**；若你的跨度更短（几天），把
  `axisFormat` 换成 `%d`（只显示日）就能进一步拉开。

### 5.6 饼图（mermaid · pie）

```mermaid
pie showData
  title 一周里，你把时间花在哪
  "读文档" : 42
  "写文档" : 26
  "做批注" : 12
  "整理书架" : 10
  "导出与分享" : 10
```

要点与坑：

- 第一行必须是 `pie`，`showData` 让扇区上直接显示数值。
- **标签必须用双引号包住**：`"读文档" : 42`。中文或含空格的标签不加引号会直接报
  `Lexical error`（整张图变成错误提示），这是饼图最常见的失败原因。
- 冒号两侧各留一个空格，数值不要带百分号（写了 `%` 会当成语法）。

### 5.7 统计图（echarts）

```echarts
{
  "title": { "text": "各文档阅读完成度", "left": "center" },
  "tooltip": { "trigger": "axis" },
  "legend": { "bottom": 0, "data": ["已读百分比"] },
  "grid": { "left": 40, "right": 20, "top": 50, "bottom": 40 },
  "xAxis": {
    "type": "category",
    "data": ["语法教程", "功能演示", "读书笔记", "会议记录"]
  },
  "yAxis": { "type": "value", "max": 100, "name": "%" },
  "series": [
    {
      "name": "已读百分比",
      "type": "bar",
      "barWidth": "46%",
      "itemStyle": { "borderRadius": [6, 6, 0, 0] },
      "data": [100, 86, 42, 15]
    }
  ]
}
```

折线 + 面积图同理，把 `"type": "bar"` 换成 `"line"`，并可用 `"areaStyle": {}` 填充。

> [!TIP]
> **坐标轴文字太长、挤成一片怎么办**？在对应轴的配置里加两行即可：
> ```json
> "axisLabel": { "rotate": 30, "interval": 0 }
> ```
> `rotate` 让标签倾斜排布，`interval: 0` 表示每个标签都显示（不自动跳档）。
> 类目名特别长时，再配 `"grid": { "bottom": 80 }` 给下方留出空间。
> 甘特图（mermaid）则用 `axisFormat` 控制日期格式，跨度大就用 `%m/%d`、跨度小用 `%d`。

> [!CAUTION]
> `echarts` 块里的内容**必须是合法 JSON**：不能有单引号、注释、尾随逗号。
> 图空白九成是 JSON 写错了 —— 贴到任意 JSON 校验工具过一遍最快。

### 5.8 思维导图（markmap）

```markmap
# 澄笺
## 阅读
### 五档纸色主题
### 目录 / 批注侧栏
### 标签多开
## 写作
### 分屏实时预览
### 版本历史与对比
### 查找替换
## 表达
### 公式与十类图表
### 手写笔记与手写批注
### 荧光底 / 波浪线批注
## 数据
### 本地优先，不联网可用
### 导出 HTML / Markdown
### 跨设备分享
```

要点：结构就是 **Markdown 大纲** —— `#` 是根节点、`##` 一级分支、`-` 也可以当节点。
**首行写的那个标题会成为根节点**。

### 5.9 关系网络图（graphviz）与乐谱（abc）

`graphviz` 用 DOT 语法画关系网：

```graphviz
digraph 澄笺模块 {
  rankdir=LR;
  node [shape=box, style=rounded, fontname="sans-serif"];
  书架 -> 阅读页 [label="打开"];
  阅读页 -> 编辑器 [label="编辑"];
  阅读页 -> 手写页 [label="手写"];
  编辑器 -> 手写页 [label="插图片"];
  手写页 -> 编辑器 [label="回传片段"];
  阅读页 -> 导出 [label="导出 / 打印"];
  导出 -> 分享 [label="跨设备"];
}
```

`abc` 用 ABC 记谱法画**五线谱**（多声部也可以，下面这首是专为澄笺写的主题小曲）：

> [!NOTE]
> 这首《澄笺 · 主题》为**AI 为本文创作**的原创小曲（C 宫五声音阶，未参考任何现有作品），
> 若觉得好听可以随便用 —— MIT 同款待遇。

**钢琴谱（ABC 记谱 · 高低音双谱表）**

```abc
X:1
T:澄笺 · 主题（AI 创作）
C:Melody written by AI for ChengJian
M:4/4
L:1/8
Q:1/4=72
K:C
%%score { RH LH }
V:RH clef=treble name="Piano"
V:LH clef=bass name="Piano"
V:RH
C2 D2 E2 G2 | A2 G2 E2 D2 | E2 G2 A2 c2 | A4 z4 |
c2 A2 G2 E2 | G2 E2 D2 C2 | D2 E2 G2 A2 | G4 z4 |
V:LH
[C,E,G]4 [C,E,G]4 | [A,,C,E]4 [G,,C,D]4 | [C,E,G]4 [C,E,A]4 | [A,,C,E]4 [A,,C,E]4 |
[C,E,G]4 [C,E,A]4 | [C,E,G]4 [G,,C,D]4 | [A,,C,D]4 [C,E,G]4 | [C,E,G]4 [C,E,G]4 |
```

> [!TIP]
> ABC 里 `,` 表示低八度（`C,` = 低音 do）、`'` 表示高八度；`[C,E,G]` 是同时按下的和弦；
> 音符后的数字拉长时值（`G4` 是两个二分音符的长度，按 `L:1/8` 计）。

**没效果？**

- **语言名必须是 `abc`**（全小写）；拼错只会当代码块显示。
- **`X:1` 与 `K:C` 两行不能少**：没有调号行（`K:`）abcjs 不渲染。
- **多声部**：`V:名字` 声部 + `%%score { RH LH }` 声部编排，缺 `%score` 行会按顺序叠谱。
- **播放按钮没出现**：说明设备不支持 Web Audio（极少见），或 ABC 语法在解析时报错 ——
  先把内容简化到四小节试播，逐步加回来定位问题。

> [!NOTE]
> 还有第六个语言名 `flowchart`（flowchart.js 的老写法），澄笺也支持：
> 它以 `st=>start:` 开头、`e=>end:` 结尾，用 `->` 连接节点。
> 三种流程图写法（mermaid / flowchart / graphviz）任选一种顺手的即可。

### 5.10 数字波形（wavedrom）

写硬件、写协议文档要用到的**时序波形**，语言名 `wavedrom`，内容是 WaveJSON：

```wavedrom
{
  "signal": [
    { "name": "clk",  "wave": "p........" },
    { "name": "req",  "wave": "01..0..10" },
    { "name": "gnt",  "wave": "x.34x..2x", "data": ["读", "写", "中"] },
    ["总线",
      { "name": "addr", "wave": "x.3..4x", "data": ["A0", "A1"] },
      { "name": "data", "wave": "x..34.x", "data": ["D0", "D1"] }
    ]
  ],
  "head": { "text": "总线握手", "tick": 0 },
  "foot": { "text": "一个周期一格", "tocks": 8 }
}
```

同一套语法还能画**寄存器位段**（指令格式）与**逻辑门图**：

```wavedrom
{
  "reg": [
    { "name": "opcode", "bits": 8, "attr": "操作码" },
    { "name": "addr",   "bits": 16 },
    { "bits": 4, "attr": "保留" },
    { "bits": 4, "attr": "标志" }
  ],
  "config": { "bits": 32 }
}
```

逻辑门图一行写一个表达式，`=` 左边是结果、右边是输入：

```wavedrom
{
  "assign": [
    ["&", "A", "B", "=", "C"],
    ["|", "C", "D", "=", "F"],
    ["~", "F", "=", "Q"]
  ]
}
```

**没效果？**

- **必须是合法 JSON**。键名的引号可以省（`signal:` 会自动补成 `"signal":`），
  但**字符串值必须带引号** —— `wave:p....` 不行，要写 `"wave":"p...."`。
- 顶层要有 `signal`（波形）/ `reg`（位段）/ `assign`（逻辑门）三者之一。
- 深浅主题**都用浅色波形面板**：`signal` 的白底板由皮肤自带，`reg` / `assign`
  不画底板（位段框和文字是硬编码的黑描边黑字），澄笺会给它们补一块不透明白底，
  免得像"黑底写黑字"那样在深色卡片里糊掉。换官方 dark 皮肤反而更糟（同样是白底，
  描边却变浅色），所以固定用 default 皮肤，不需要配置。

### 5.10b Mermaid v11 新图种（看板 / 架构图 / 数据包图）

升级到 mermaid v11 后新增三种图。**看板**（kanban，任务列与卡片）：

```mermaid
kanban
  学习计划
    todo[本周]
      card1[过一遍语法教程]
    doing[进行中]
      card2[整理错题本]
    done[已完成]
      card3[读完第一章]
```

**架构图**（architecture-beta，服务分组与连接）——
⚠️ **`[标签]` 只认不带点的 ASCII**：`[澄笺应用]` 与 `[shelf.json]` 都会报
`Parsing failed: unexpected character: ->[<-`（加引号也救不了），实测 `[docs folder]` 这种
带空格的英文没问题。分组名与服务名请写成 ASCII 单词，说明文字放正文：

```mermaid
architecture-beta
    group app(cloud)[ChengJian]
    service md(database)[docs folder] in app
    service web(server)[WebView] in app
    service store(database)[shelf index] in app
    web:T -- B:md
    web:T -- B:store
```

**数据包图**（packet-beta，字节位段可视化）：

```mermaid
packet-beta
  0-15: "源端口"
  16-31: "目标端口"
  32-95: "序列号"
  96-127: "确认号"
```

### 5.11 Chart.js 数据可视化（chart）

语言名 `chart`，内容是 **Chart.js 的 JSON 配置**，支持柱状 / 折线 / 饼图 / 环形 / 雷达等全部图种。
深色模式下会自动切换浅色文字；`options.width` / `options.height` 控制画布尺寸（默认 560×320）：

```chart
{
  "type": "bar",
  "data": {
    "labels": ["1 天", "3 天", "7 天", "半月", "一月"],
    "datasets": [
      { "label": "复习条数", "data": [12, 8, 5, 3, 2],
        "backgroundColor": "rgba(47, 99, 232, 0.65)" },
      { "label": "掌握条数", "data": [9, 7, 4, 2, 2],
        "backgroundColor": "rgba(31, 158, 102, 0.65)" }
    ]
  },
  "options": {
    "width": 560,
    "height": 300,
    "scales": { "y": { "beginAtZero": true } }
  }
}
```

折线图（`type: "line"`），`tension` 控制曲线圆滑程度：

```chart
{
  "type": "line",
  "data": {
    "labels": ["周一", "周二", "周三", "周四", "周五", "周六", "周日"],
    "datasets": [
      { "label": "写作字数", "data": [820, 932, 901, 1290, 1330, 1320, 1010],
        "borderColor": "#2F63E8", "backgroundColor": "rgba(47, 99, 232, 0.15)",
        "fill": true, "tension": 0.35 }
    ]
  },
  "options": { "width": 560, "height": 280 }
}
```

饼图（`type: "pie"`，环形用 `doughnut`）：

```chart
{
  "type": "pie",
  "data": {
    "labels": ["直接打开", "邮件营销", "联盟广告"],
    "datasets": [
      { "data": [335, 310, 234],
        "backgroundColor": ["#2F63E8", "#1F9E66", "#E08000"] }
    ]
  },
  "options": { "width": 420, "height": 300 }
}
```

> 注意：内容**必须是合法 JSON**（双引号、无注释、无尾随逗号）；`options.scales`
> 可以进一步定制坐标轴，`plugins.legend` 控制图例位置。
>
> 颜色写 **CSS 格式**（`#2F63E8`、`rgba(47,99,232,0.65)`），**不是**应用内部的
> `#AARRGGBB`：这里的字符串直接交给 Chart.js 填画布，`#FF2F63E8` 会被当成
> "红 255 绿 47 蓝 99、透明度 91%" 的**粉红**，而不是想要的蓝色。

### 5.12 nomnoml 极简 UML（nomnoml）

语言名 `nomnoml`，一行一个框，用 `[名称 | 字段 | 方法]` 描述类；关系写在两个框之间，
**箭头整体是一个词**：`[甲] 起点修饰-线终点修饰 标签 [乙]`。

```nomnoml
[澄笺|MdParser; MdView; DocStore|渲染(); 批注(); 备份()]
[MdParser|- fence 识别|+ 解析正文]
[MdView|- 卡片排版|+ 增量刷新]
[DocStore|- shelf.json|+ 备份恢复]

[澄笺] +-> [MdParser]
[澄笺] +-> [MdView]
[澄笺] +-> [DocStore]
[MdView] --> [MdParser]
```

可用的关系符号（引擎 nomnoml 1.7.0 实测，写错整块报错而不是画歪）：

| 写法 | 线型 | 端点 | 语义 |
| --- | --- | --- | --- |
| `-` | 实线 | 无 | 关联 |
| `->` / `<-` | 实线 | 实心箭头 | 有向关联 |
| `-->` | 虚线 | 实心箭头 | 依赖 |
| `+-` / `-+` | 实线 | 实心菱形 | 组合（强拥有） |
| `o-` / `-o` | 实线 | 空心菱形 | 聚合（弱拥有） |
| `-:>` / `<:-` | 实线 | 空心三角 | 泛化（继承） |
| `--:>` | 虚线 | 空心三角 | 实现 |
| `-/-` | 无 | 无 | 只排位置，不画线 |

标签直接写在符号两侧，各算一头：`[甲] 使用 --> 被用 [乙]`。
**`=>`、`++`、`<|`、`<:` 单写都不是合法符号**，只能按上表组合。

```nomnoml
[学习者]
[复习计划|每日目标]
[学习卡|正面; 背面|拼写记忆()]
[批注|位置; 颜色]
[手写卡|笔迹]

[学习者] -> 安排 [复习计划]
[复习计划] o- 汇总 [学习卡]
[学习卡] +- 挂载 [批注]
[学习卡] -:> 派生 [手写卡]
```

> nomnoml 语法极简但表达力有限，复杂 UML（泳道 / 时序）请用 mermaid。

### 5.12b Vega-Lite 声明式统计图（vega-lite）

语言名 `vega-lite`（别名 `vl` / `vega`），内容是 **Vega-Lite 的 JSON spec**：
`data` 给数据、`mark` 给图形类型、`encoding` 说哪个字段映射到什么通道。
引擎是随包的 Vega 6.4.0 + Vega-Lite 6.5.0（BSD-3-Clause），出的是**矢量 SVG**，
放大浮层里捏合不会糊：

```vega-lite
{
  "data": { "values": [
    { "平台": "鸿蒙", "篇数": 42 },
    { "平台": "Web", "篇数": 88 },
    { "平台": "iOS", "篇数": 31 }
  ] },
  "mark": { "type": "bar", "cornerRadiusEnd": 4 },
  "encoding": {
    "x": { "field": "平台", "type": "nominal" },
    "y": { "field": "篇数", "type": "quantitative" },
    "color": { "field": "平台", "type": "nominal" }
  },
  "width": 320,
  "height": 200
}
```

聚合与折线也一样写（`aggregate` 直接挂在通道上）：

```vl
{
  "data": { "values": [
    { "周": 1, "字数": 820 }, { "周": 2, "字数": 932 },
    { "周": 3, "字数": 901 }, { "周": 4, "字数": 1290 }
  ] },
  "layer": [
    { "mark": { "type": "line", "point": true } },
    { "mark": { "type": "rule", "color": "firebrick", "strokeDash": [4, 4] },
      "encoding": { "y": { "aggregate": "mean", "field": "字数" } } }
  ],
  "encoding": {
    "x": { "field": "周", "type": "ordinal" },
    "y": { "field": "字数", "type": "quantitative" }
  },
  "width": 320,
  "height": 200
}
```

三条边界说清楚：

1. **内容必须是合法 JSON**（双引号、无注释、无尾随逗号），与 `chart` / `echarts` 同一口径。
2. `width` / `height` 不写时按卡片宽度出图；写了就尊重作者的，但**超过卡宽会等比缩**，
   不会把正文横向撑破。
3. 深色卡片下只兜底色与文字颜色（轴标签、图例、网格线跟着翻），
   **作者自己写过的 `config` 一律不覆盖** —— 自定义配色不会被引擎冲掉。
   纯 Vega 语法（`"mark": {"type": ...}` 那套底层写法）也支持，但推荐用 Lite。

### 5.13 化学方程式（mhchem）

数学公式引擎挂载了 **mhchem 扩展**，`\ce{}` 命令直接写化学式，自动处理
下标、配平系数、气体沉淀箭头：

$$
\ce{CO2 + C -> 2 CO}
$$

$$
\ce{2H2 + O2 ->[点燃] 2H2O}
$$

可逆与沉淀：

$$
\ce{CaCO3 + 2HCl = CaCl2 + H2O + CO2 ^}
$$

> 行内也可以用：水的电离 $\ce{H2O <=> H+ + OH-}$ 是可逆反应。

### 5.13b PlantUML 的独立图种（网络图 / 盐图 / ditaa）

PlantUML 官方离线内核**自带 14 个图种**（时序 / 用例 / 类 / 活动 / 组件 / 部署 / 状态 / 脑图 /
WBS / 甘特 / JSON / YAML / Archimate / ER），另外三个内核没有渲染器的图种由澄笺自己出图：

**网络图 nwdiag**（`@startnwdiag`）——按「网络」归组设备并标出网段地址：

```plantuml
@startnwdiag
network dmz {
  address = "210.x.x.x/24"
  web01 [address = "210.x.x.1"];
  web02 [address = "210.x.x.2"];
}
network internal {
  web01 [address = "172.16.x.1"];
  db01 [address = "172.16.x.2"];
}
@endnwdiag
```

**盐图 salt**（`@startsalt`）——界面线框走查：`{+` 开带框容器，`|` 分列，`[按钮]`、
`[x]` 勾选、`(o)` 单选、`"输入"` 输入框：

```plantuml
@startsalt
{+
  用户名 | "alice"
  密码   | "******"
  ----
  [ ] 记住我 | (o) 保持登录
  [登录]   [取消]
}
@endsalt
```

**ditaa**（`@startditaa`）——ASCII 图元转成带色方框（方框里写 `cBLU` / `cGRE` 之类
颜色码就能着色，字母是色调：R 红 / G 绿 / B 蓝 / Y 黄 / C 青 / M 品红 / O 橙 / W 白 / K 灰）：

```plantuml
@startditaa
+---------+     +---------------+
| 客户端  |---->| 服务端 cBLU   |
+---------+     +---------------+
     |                |
     v                v
+---------------------------+
|      数据库 cGRE          |
+---------------------------+
@endditaa
```

> 这三个图种归在「设置 → 引擎管理 → PlantUML」开关下，关掉 PlantUML 就一起关。

### 5.14 图表速查

| 语言名 | 首行怎么写 | 最容易踩的坑 |
| --- | --- | --- |
| `mermaid` | `graph TD` / `sequenceDiagram` / `stateDiagram-v2` / `classDiagram` / `gantt` / `pie` | 语言名必须全小写；一张图一个代码块 |
| `zenuml` | 写在 ` ```mermaid ` 里，首行 `zenuml`，然后 `@Actor User` / `User->App.open()` | 澄笺带了这个插件，直接画；深色卡片里仍是白底面板（插件自己的配色） |
| `echarts` | 直接写 JSON 的 `{` | 必须是合法 JSON |
| `markmap` | `# 根节点` | 根节点就是第一行标题 |
| `graphviz` | `digraph 名字 {` | 别忘了最外层大括号 |
| `flowchart` | `st=>start: 开始` | 末尾要有 `e=>end:` |
| `abc` | `X:1` | `K:` 调号行不能少 |
| `wavedrom` | `{` 开头的 WaveJSON | 值必须带引号；顶层要有 signal / reg / assign |
| `chart` | `{` 开头的 Chart.js 配置 | 颜色写 **CSS 格式**（`#2F63E8`），不是应用内部的 `#AARRGGBB` |
| `nomnoml` | `[框 \| 字段 \| 方法]` | 复杂 UML（泳道 / 时序）改用 mermaid |
| `vega-lite` | `{` 开头的 spec，含 `data` / `mark` / `encoding` | 必须合法 JSON；`width` / `height` 不写就按卡宽出图 |
| `plantuml` | `@startuml` / `@startmindmap` / `@startwbs` / `@startgantt` / `@startjson` / `@startyaml` | 官方内核离线渲染；`@startsalt`、`@startnwdiag`、`@startditaa` 由澄笺自带渲染器画，`@startmath` 转公式，`@starttimeline` 转 mermaid（逐图种实测见第十节） |

---

## 六、批注与手写

### 批注

阅读时长按选中文字，会弹出一枚可拖动的胶囊：

- **荧光底**：整段变成浅色底纹，适合划重点；
- **波浪线**：文字下方一条波浪，适合标"这里要再看一遍"；
- 颜色四选：红 / 绿 / 蓝 / 黄；
- 右侧批注抽屉按文档汇总，点一条可跳回原文位置。

批注是**跟着文本走**的：坐标系记的是「块 id + 渲染文本区间」，
所以你在编辑器里改了别处、批注仍会贴在原来那句话上。

### 批注公式

公式渲染出来是一张图，**没有文字选区**，所以长按选字那条路对公式无效。
改用这两个入口，打开的是同一个批注面板，只是会**把公式渲染出来**：

- **行内公式**（段落里的 `$…$`）：点它 → 菜单里选「批注」（这个菜单本身也会先把公式渲染出来，源码放下面当对照）；
- **块级公式卡片**（`$$…$$`）：卡片顶部「公式」栏右边那排按钮里**最左那个**（在放大按钮左边）。

面板里有四样东西：

| 位置 | 作用 |
| --- | --- |
| 渲染预览 | 显示**将要被批注的那一段**（选中对得上就渲染选中段，否则整条） |
| 源码框 | 这条公式的 LaTeX，可以选、可以改 |
| 「保存公式」 | 把改过的源码写回文档原位（块级保留原有 `$$` / `\[…\]` 与单行多行形态） |
| 「普通批注 / 学习卡」 | 选这条批注的形态：普通批注只加底纹，学习卡进背诵系统（书架「文房」复习） |

不管是文字批注还是公式批注，**开始打字时面板会平滑地抬到输入法上方**（约 0.2 秒的过渡，
键盘收起再平滑落回），输入框不会被键盘盖住。输入框还会**随你写的行数继续长高**，
长到"键盘之外那块可视高度"的上限后改为框内滚动 —— 所以键盘弹起时它不会把面板顶出屏幕，
键盘收起后还能继续长。所有半模态面板（批注、重命名、新建文档、导出、阅读设置……）顶部那根
**拖拽条都能往上拉**，逐档变高（贴合内容 → 60% → 大屏），松手吸附；往下拖回原档。
横屏与平板居中窗口按系统限制不提供多档拖拽，面板维持贴合内容的高度。

**只批注公式里的一小段**：在源码框里长按选中那一段（比如只选 `\frac{a}{b}`），
再点「保存批注」——存下来的区间就是这一小段，批注抽屉里也只渲染它。
正文里的底纹仍然铺在整条公式上（图切不开，切开的半截 LaTeX 渲染不出来）。

> [!NOTE]
> 选中必须是**文档里已有的内容**才生效：改了源码但还没点「保存公式」时，
> 草稿的字符位置和正文已经对不上，这时保存批注会退回整条（标题会提示你）。

### 手写

从编辑页或阅读页进入手写画布（华为手写笔套件 Pen Kit）：

- 画布背景可换：12 款淡色底 + 「主题色」动态跟随 + 五款壁纸同色底；
- 底纹四选：无 / 小方格 / 单行线 / 点阵，线条粗细三档；
- 写完点「插入」——手写图会带着**你选的底色与底纹**一起插进正文；
- 批注模式下写完，会落成一条带手写图的双下划线批注。

> [!IMPORTANT]
> 手写图的底色与底纹是**烘焙进图片**的，所以插入正文后在任何主题下都不会糊掉。

---

## 七、数据在自己手里

| 动作 | 入口 | 说明 |
| --- | --- | --- |
| 导出单篇 | 卡片「⋯」→ 导出 / 分享 | HTML（自包含）或 Markdown |
| 打印 | 导出面板 → 打印 | 走系统打印，真实分页 |
| 整库备份 | 设置 → 数据管理 | 打包成 zip，含图片与设置 |
| 图片管理 | 设置 → 数据管理 → 图片管理 | 集中查看、导出、移除 |
| 跨设备分享 | 阅读页碰一碰 / 隔空传送 | HarmonyOS 设备间直传 |

> [!NOTE]
> 全量模式下可开启网络备份与检查更新；**基础模式**彻底不联网，
> 网络图片不加载、网络功能不可用，本地功能一切照常。

---

## 八、这篇文档怎么用

1. 把它当**样张**：从头翻一遍，确认图表、公式、表格都正常显示。
2. 把它当**模板**：切到「可写」，删掉不需要的章节，留下你要的结构。
3. 把它当**速查**：上面的图表速查表可以直接复制到你的新文档里改。
4. 想知道**哪一个画得出、哪一个是降级**，看第十节《各引擎实测能力》——逐图种实测，含版本号。
5. 更细的语法规则（含"没效果"的排查）见另一篇内置文档《Markdown 语法教程》。

想深入哪一种图表，就去「更多 → 语法」面板里找那一行 —— 点一下，示例会直接插进你的正文。

---

*澄笺 · 安静地读，顺手地写。*

---

## 九、代码块与 HTML 预览

### 代码块：行号 + 长代码折叠

代码块**默认显示行号**；超过 **10 行**的代码块会自动折叠，点下方的「展开全部 N 行」看完整内容
（再点「收起代码」收回去）。

```js
// 这段超过 10 行，在阅读页里默认是折叠状态
function fib(n) {
  if (n <= 1) {
    return n;
  }
  let a = 0;
  let b = 1;
  for (let i = 2; i <= n; i++) {
    const t = a + b;
    a = b;
    b = t;
  }
  return b;
}
```

下面三段都是**超过 10 行**的长代码，用来验证折叠与行号（点「展开全部」看全文）：

**Python**

```python
def quicksort(arr):
    """快速排序：小数组直接插入排序，避免递归开销。"""
    if len(arr) <= 1:
        return arr
    pivot = arr[len(arr) // 2]
    left = [x for x in arr if x < pivot]
    mid = [x for x in arr if x == pivot]
    right = [x for x in arr if x > pivot]
    return quicksort(left) + mid + quicksort(right)

if __name__ == '__main__':
    data = [3, 6, 1, 8, 2, 9, 4]
    print(quicksort(data))
```

**C**

```c
#include <stdio.h>
#include <string.h>

#define BUF_SIZE 256

int main(void) {
    char buf[BUF_SIZE];
    int words = 0;
    printf("请输入一行文字：");
    if (fgets(buf, BUF_SIZE, stdin) == NULL) {
        return 1;
    }
    for (int i = 0; buf[i] != '\0'; i++) {
        if (buf[i] == ' ' || buf[i] == '\n') {
            words++;
        }
    }
    printf("大约 %d 个单词\n", words);
    return 0;
}
```

**Java**

```java
import java.util.HashMap;
import java.util.Map;

public class WordCount {
    /** 统计每个字符出现的次数，按插入顺序输出。 */
    public static Map<Character, Integer> count(String text) {
        Map<Character, Integer> map = new HashMap<>();
        for (char c : text.toCharArray()) {
            if (Character.isWhitespace(c)) {
                continue;
            }
            map.put(c, map.getOrDefault(c, 0) + 1);
        }
        return map;
    }

    public static void main(String[] args) {
        for (Map.Entry<Character, Integer> e : count("澄心执笔 笺上生光").entrySet()) {
            System.out.println(e.getKey() + " -> " + e.getValue());
        }
    }
}
```

### 支持高亮的常用语言（一览）

语言名写在起始围栏的后面（三个反引号或三个波浪号紧跟语言名，例如波浪号写法 `~~~python`），
它决定左上角的**语言徽标**与**语法高亮**。下面每种给一个短例子，方便对照：

**Python**
```python
from dataclasses import dataclass


@dataclass
class Doc:
    name: str
    words: int
    starred: bool = False


def summary(docs):
    total = sum(d.words for d in docs)
    starred = sum(1 for d in docs if d.starred)
    return f"共 {len(docs)} 篇 · {total} 字 · 星标 {starred}"


docs = [Doc("读书笔记", 1200, True), Doc("周报", 800)]
print(summary(docs))
```

**JavaScript**
```js
// 文档集合的简单统计
const docs = [
  { name: '读书笔记', words: 1200, starred: true },
  { name: '周报', words: 800, starred: false },
  { name: '会议记录', words: 640, starred: true },
];

const totalWords = (xs) => xs.reduce((sum, d) => sum + d.words, 0);
const starredCount = (xs) => xs.filter((d) => d.starred).length;

console.log(`共 ${docs.length} 篇`);
console.log(`总字数 ${totalWords(docs)}`);
console.log(`星标 ${starredCount(docs)} 篇`);
```

**TypeScript**
```ts
interface Doc {
  name: string;
  words: number;
  starred?: boolean;
}

function summary(docs: Doc[]): string {
  const total = docs.reduce((sum, d) => sum + d.words, 0);
  const starred = docs.filter((d) => d.starred).length;
  return `共 ${docs.length} 篇 · ${total} 字 · 星标 ${starred}`;
}

const docs: Doc[] = [
  { name: '读书笔记', words: 1200, starred: true },
  { name: '周报', words: 800 },
];

console.log(summary(docs));
```

**Java**
```java
import java.util.List;

public class Main {
    record Doc(String name, int words, boolean starred) {}

    public static void main(String[] args) {
        List<Doc> docs = List.of(
            new Doc("读书笔记", 1200, true),
            new Doc("周报", 800, false)
        );
        int total = docs.stream().mapToInt(Doc::words).sum();
        System.out.println("共 " + docs.size() + " 篇 · " + total + " 字");
        docs.forEach(d -> System.out.println(d.name()));
    }
}
```

**C**
```c
#include <stdio.h>
#include <string.h>

typedef struct {
    char name[32];
    int words;
} Doc;

int main(void) {
    Doc docs[2] = {
        {"读书笔记", 1200},
        {"周报", 800}
    };
    int total = 0;
    for (int i = 0; i < 2; i++) {
        total += docs[i].words;
        printf("%s · %d 字\n", docs[i].name, docs[i].words);
    }
    printf("合计 %d 字\n", total);
    printf("长度校验 %zu\n", strlen(docs[0].name));
    return 0;
}
```

**C++**
```cpp
#include <iostream>
#include <string>
#include <vector>

struct Doc {
    std::string name;
    int words;
};

int main() {
    std::vector<Doc> docs = {
        {"读书笔记", 1200},
        {"周报", 800}
    };
    int total = 0;
    for (const auto& d : docs) {
        std::cout << d.name << " · " << d.words << " 字" << std::endl;
        total += d.words;
    }
    std::cout << "合计 " << total << " 字" << std::endl;
    return 0;
}
```

**C#**
```cs
using System;
using System.Collections.Generic;
using System.Linq;

class Doc
{
    public string Name { get; set; }
    public int Words { get; set; }
}

class Program
{
    static void Main()
    {
        var docs = new List<Doc>
        {
            new Doc { Name = "读书笔记", Words = 1200 },
            new Doc { Name = "周报", Words = 800 }
        };
        Console.WriteLine($"共 {docs.Count} 篇 · {docs.Sum(d => d.Words)} 字");
    }
}
```

**Go**
```go
package main

import "fmt"

type Doc struct {
	Name    string
	Words   int
	Starred bool
}

func main() {
	docs := []Doc{
		{"读书笔记", 1200, true},
		{"周报", 800, false},
	}
	total := 0
	for _, d := range docs {
		total += d.Words
		fmt.Printf("%s · %d 字\n", d.Name, d.Words)
	}
	fmt.Println("合计", total, "字")
}
```

**Rust**
```rust
struct Doc {
    name: String,
    words: u32,
    starred: bool,
}

fn summary(docs: &[Doc]) -> String {
    let total: u32 = docs.iter().map(|d| d.words).sum();
    let starred = docs.iter().filter(|d| d.starred).count();
    format!("共 {} 篇 · {} 字 · 星标 {}", docs.len(), total, starred)
}

fn main() {
    let docs = vec![
        Doc { name: "读书笔记".into(), words: 1200, starred: true },
        Doc { name: "周报".into(), words: 800, starred: false },
    ];
    println!("{}", summary(&docs));
}
```

**Swift**
```swift
struct Doc {
    let name: String
    var words: Int
    var starred: Bool
}

func summary(_ docs: [Doc]) -> String {
    let total = docs.reduce(0) { $0 + $1.words }
    let starred = docs.filter { $0.starred }.count
    return "共 \(docs.count) 篇 · \(total) 字 · 星标 \(starred)"
}

let docs = [
    Doc(name: "读书笔记", words: 1200, starred: true),
    Doc(name: "周报", words: 800, starred: false)
]
print(summary(docs))
```

**Kotlin**
```kotlin
data class Doc(val name: String, val words: Int, val starred: Boolean = false)

fun summary(docs: List<Doc>): String {
    val total = docs.sumOf { it.words }
    val starred = docs.count { it.starred }
    return "共 ${docs.size} 篇 · $total 字 · 星标 $starred"
}

fun main() {
    val docs = listOf(
        Doc("读书笔记", 1200, true),
        Doc("周报", 800)
    )
    println(summary(docs))
    docs.forEach { println("· ${it.name}") }
}
```

**Shell**
```sh
#!/bin/sh
# 统计目录下所有 Markdown 的字数（示意）
total=0
count=0
for f in *.md; do
  words=$(wc -m < "$f")
  echo "$f · $words 字"
  total=$((total + words))
  count=$((count + 1))
done
echo "共 $count 篇 · $total 字"
if [ "$total" -gt 10000 ]; then
  echo "产出很稳定，继续保持"
fi
```

**SQL**
```sql
SELECT
    d.name    AS 文档名,
    d.words   AS 字数,
    f.name    AS 所在文件夹,
    d.starred AS 是否星标
FROM docs AS d
LEFT JOIN folders AS f ON f.id = d.folder_id
WHERE d.words > 500
ORDER BY d.words DESC, d.name ASC
LIMIT 10;

-- 星标文档的字数合计
SELECT SUM(words) FROM docs WHERE starred = 1;
```

**JSON**
```json
{
  "app": "澄笺",
  "version": "1.0.8",
  "docs": [
    { "name": "读书笔记", "words": 1200, "starred": true },
    { "name": "周报", "words": 800, "starred": false }
  ],
  "settings": {
    "fontSize": 18,
    "lineHeight": 1.75,
    "theme": "纸色"
  },
  "features": ["表格编辑", "对照阅读", "多设备流转"]
}
```

**YAML**
```yaml
app: 澄笺
version: 1.0.8
settings:
  fontSize: 18
  lineHeight: 1.75
  themeMode: 跟随系统
docs:
  - name: 读书笔记
    words: 1200
    starred: true
  - name: 周报
    words: 800
    starred: false
features:
  - 表格编辑
  - 对照阅读
```

**HTML / CSS** —— 注意：`html` 围栏会**渲染成预览**，想展示源码请用 `markdown` 或 `text`
```markdown
# 一份 HTML 样式示例

<div class="card">
  <p>一段 <b>HTML</b> 也可以直接写在围栏里。</p>
  <p>想看渲染效果：把语言名改成 <code>html</code>（见下一节）。</p>
</div>
```

```css
.card {
  max-width: 640px;
  margin: 16px auto;
  padding: 16px 20px;
  border-radius: 16px;
  background: #ffffff;
  box-shadow: 0 2px 12px rgba(18, 50, 79, 0.08);
  font-family: HarmonyOS Sans, system-ui, sans-serif;
  color: #2a3f5f;
  line-height: 1.7;
}

.card b {
  color: #1f8a70;
}
```

### HTML 快速样式与预览

把代码块的语言写成 `html`，它会**直接渲染成预览**（不显示源码），于是 `<font>` 这类
**快速样式**与常见标签都能立刻看到效果：

```html
<style>
  .fx {
    font-family: HarmonyOS Sans, system-ui, sans-serif;
    padding: 12px 14px 14px; border-radius: 16px; user-select: none;
    background: radial-gradient(120% 90% at 50% 0%, #1B2340 0%, #0B0E1D 62%, #06070F 100%);
    border: 1px solid rgba(150,180,255,0.16);
    box-shadow: 0 10px 30px rgba(6,8,18,0.55);
  }
  .fx .hud {
    display: flex; justify-content: space-between; align-items: baseline;
    font-size: 12.5px; color: #9FB2DC; margin-bottom: 8px;
    font-variant-numeric: tabular-nums; letter-spacing: .02em;
  }
  .fx .hud .t { color:#EAF0FF; font-size:13.5px; text-shadow:0 0 12px rgba(120,180,255,.55); }
  .fx .hud b { color:#fff; }
  .fx .combo { margin-left:8px; color:#FFD37A; text-shadow:0 0 10px rgba(255,190,80,.55); }
  .fx .shape { margin-left:8px; color:#8FE3C8; text-shadow:0 0 10px rgba(120,230,190,.5); }
  /* 画布按容器宽自适应；位图尺寸由 JS 按 devicePixelRatio 对齐，不会拉伸 */
  .fx canvas {
    display:block; width:100%; aspect-ratio:4/3; min-height:150px;
    border-radius:12px; background:#070A16; touch-action:none;
  }
  .fx .tip { margin-top:8px; font-size:11.5px; color:#7286B4; text-align:center; }
</style>
<div class="fx" id="fxRoot">
  <div class="hud">
    <span class="t">✦ 指尖烟花</span>
    <span>发射 <b id="fxShots">0</b> · 粒子 <b id="fxParts">0</b><span class="shape" id="fxShape"></span><span class="combo" id="fxCombo"></span></span>
  </div>
  <canvas id="fxCanvas"></canvas>
  <div class="tip">点一下炸一朵（爱心 / 星星 / 笑脸 / 菊花…）· 按住拖动拉出光带 · 连点触发二次连爆 · 停手 3 秒自动表演</div>
</div>
<script>
(function () {
  var cv = document.getElementById('fxCanvas');
  if (!cv || cv.__fx) { return; }
  cv.__fx = true;
  var ctx = cv.getContext('2d');
  var elShots = document.getElementById('fxShots');
  var elParts = document.getElementById('fxParts');
  var elCombo = document.getElementById('fxCombo');
  var elShape = document.getElementById('fxShape');

  var W = 320, H = 240, u = 1, dpr = 1;
  var parts = [], rock = [], trail = [], stars = [], fuse = [], flashes = [];
  var shots = 0, combo = 0, comboT = 0, lastTouch = 0, frame = 0, hueSeed = Math.random() * 360;
  var MAX = 700, GRAV = 0.055;
  // 圆壳类 + 造型类（造型用高阻尼"停"在轮廓上，才看得清形状）+ 二次起爆类
  var KINDS = ['peony', 'ring', 'willow', 'chrys', 'palm', 'crackle',
    'star', 'heart', 'smiley', 'diamond', 'crossette', 'double'];
  var CN = {
    peony: '牡丹', ring: '圆环', willow: '垂柳', chrys: '菊花', palm: '棕榈', crackle: '碎金',
    star: '五角星', heart: '爱心', smiley: '笑脸', diamond: '菱形', crossette: '二次爆', double: '双响'
  };
  var SHAPE_KIND = { star: 1, heart: 1, smiley: 1, diamond: 1 };

  function fit() {
    var cw = cv.clientWidth || 320, ch = cv.clientHeight || Math.round(cw * 3 / 4);
    dpr = Math.min(2.5, Math.max(1, window.devicePixelRatio || 1));
    cv.width = Math.round(cw * dpr); cv.height = Math.round(ch * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    W = cw; H = ch; u = Math.max(0.7, H / 240);
    stars = [];
    for (var i = 0; i < 78; i++) {
      stars.push({ x: Math.random() * W, y: Math.random() * H * 0.94, r: Math.random() * 1.4 * u + 0.4, p: Math.random() * 6.3 });
    }
  }

  function push(p) { if (parts.length < MAX) { parts.push(p); } }
  function flash(x, y, hue, a) { flashes.push({ x: x, y: y, hue: hue, life: 12, a: a || 1 }); }

  // 沿多边形周长均匀取 n 个点（五角星 / 菱形用）
  function walkPoly(v, n) {
    var seg = [], total = 0, i, j, a, b, d;
    for (i = 0; i < v.length; i++) {
      a = v[i]; b = v[(i + 1) % v.length];
      d = Math.sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]));
      seg.push(d); total += d;
    }
    var out = [], step = total / n, acc = 0, si = 0, sl = 0;
    for (j = 0; j < n; j++) {
      var want = step * j;
      while (si < seg.length - 1 && want > acc + seg[si]) { acc += seg[si]; si++; }
      var t = seg[si] > 0 ? (want - acc) / seg[si] : 0;
      a = v[si]; b = v[(si + 1) % v.length];
      out.push([a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]);
    }
    return out;
  }

  // 造型轮廓上的单位方向（长度即相对速度）
  function shapePts(kind, n) {
    var out = [], i, a, t, m;
    if (kind === 'star') {
      var v = [];
      for (i = 0; i < 10; i++) {
        a = Math.PI / 5 * i - Math.PI / 2;
        var r = (i % 2 === 0) ? 1 : 0.42;
        v.push([Math.cos(a) * r, Math.sin(a) * r]);
      }
      return walkPoly(v, n);
    }
    if (kind === 'diamond') { return walkPoly([[0, -1], [0.6, 0], [0, 1], [-0.6, 0]], n); }
    if (kind === 'heart') {
      for (i = 0; i < n; i++) {
        t = Math.PI * 2 * i / n;
        var hx = 16 * Math.pow(Math.sin(t), 3);
        var hy = 13 * Math.cos(t) - 5 * Math.cos(2 * t) - 2 * Math.cos(3 * t) - Math.cos(4 * t);
        out.push([hx / 15, -hy / 15]);
      }
      return out;
    }
    if (kind === 'smiley') {
      m = Math.floor(n * 0.55);
      for (i = 0; i < m; i++) { a = Math.PI * 2 * i / m; out.push([Math.cos(a), Math.sin(a)]); }
      var eyes = [[-0.38, -0.3], [0.38, -0.3]], e, k, mm = Math.floor(n * 0.08);
      for (e = 0; e < 2; e++) {
        for (k = 0; k < mm; k++) {
          a = Math.PI * 2 * k / mm;
          out.push([eyes[e][0] + Math.cos(a) * 0.13, eyes[e][1] + Math.sin(a) * 0.18]);
        }
      }
      m = Math.floor(n * 0.22);
      for (i = 0; i < m; i++) {
        a = Math.PI * (0.18 + 0.64 * i / m);
        out.push([Math.cos(a) * 0.62, 0.2 + Math.sin(a) * 0.42]);
      }
      return out;
    }
    return out;
  }

  function shell(x, y, hue, kind, n) {
    var i, a, sp, life, p;
    if (SHAPE_KIND[kind]) {
      var pts = shapePts(kind, n);
      var R = Math.min(W, H) * 0.29;
      var dr = 0.885, V = R * (1 - dr);
      for (i = 0; i < pts.length; i++) {
        life = 74 + Math.random() * 30;
        push({
          x: x, y: y, vx: pts[i][0] * V, vy: pts[i][1] * V,
          life: life, max: life, hue: hue + (i % 9) * 2.2, s: 2.1 * u,
          dr: dr, g: 0.012 * u, tw: Math.random() * 6.3, st: false, k: kind
        });
      }
      flash(x, y, hue, 0.7);
      return;
    }
    for (i = 0; i < n; i++) {
      a = (Math.PI * 2 * i) / n + Math.random() * 0.08;
      if (kind === 'palm' && i % 3) { continue; }
      sp = (1.5 + Math.random() * 2.4) * u;
      if (kind === 'ring') { sp = 2.9 * u; }
      if (kind === 'willow') { sp = 1.7 * u; }
      life = 64 + Math.random() * 44;
      p = {
        x: x, y: y, vx: Math.cos(a) * sp, vy: Math.sin(a) * sp,
        life: life, max: life, hue: hue + (kind === 'willow' ? 0 : Math.random() * 26 - 13),
        s: (kind === 'chrys' ? 2.1 : 2.7) * u, dr: kind === 'willow' ? 0.985 : 0.962,
        g: kind === 'willow' ? GRAV * 0.55 : (kind === 'ring' ? GRAV * 1.4 : GRAV),
        tw: Math.random() * 6.3, st: kind === 'chrys' || kind === 'palm', k: kind
      };
      // 二次起爆：一部分粒子飞到一半再各自炸一小朵
      if (kind === 'crossette' && i % 7 === 0) { p.split = Math.floor(life * 0.52); }
      push(p);
    }
    if (kind === 'crackle') {
      for (i = 0; i < 14; i++) {
        a = Math.random() * 6.3; sp = Math.random() * 1.3 * u;
        push({ x: x, y: y, vx: Math.cos(a) * sp, vy: Math.sin(a) * sp, life: 22 + Math.random() * 26,
          max: 48, hue: hue + 30, s: 1.2 * u, dr: 0.97, g: GRAV * 0.8, tw: Math.random() * 6.3, st: false, k: 'sp' });
      }
    }
    flash(x, y, hue, 1);
  }

  function launch(tx, ty) {
    // 贴着边点会把整个造型甩出画布（爱心被裁掉半朵很难看），先把炸点收进安全区。
    // 0.32 而不是 shell 里的 0.29：爱心的横向外扩是标称半径的 ~1.07 倍
    var R = Math.min(W, H) * 0.32;
    tx = Math.min(W - R, Math.max(R, tx));
    ty = Math.min(H - R * 0.75, Math.max(R * 0.8, ty));
    var sx = tx + (Math.random() * 2 - 1) * W * 0.14;
    var dx = tx - sx, dy = ty - (H + 6 * u), d = Math.sqrt(dx * dx + dy * dy) || 1;
    var sp = 6.4 * u + Math.random() * 1.4 * u;
    rock.push({ x: sx, y: H + 6 * u, vx: dx / d * sp, vy: dy / d * sp, tx: tx, ty: ty,
      hue: (hueSeed + Math.random() * 160) % 360, k: KINDS[(Math.random() * KINDS.length) | 0], n: 0 });
    shots++;
    var now = Date.now();
    combo = (now - comboT < 900) ? combo + 1 : 1;
    comboT = now;
  }

  function spark(x, y, vx, vy, hue) {
    if (trail.length > 240) { trail.shift(); }
    trail.push({ x: x, y: y, vx: vx * 0.25 + (Math.random() - 0.5) * 0.7 * u,
      vy: vy * 0.25 + (Math.random() - 0.5) * 0.7 * u, life: 18, max: 18, hue: hue, s: 1.15 * u });
  }

  function step() {
    frame++;
    var i, j, p, r, q;
    for (i = rock.length - 1; i >= 0; i--) {
      r = rock[i]; r.n++;
      r.x += r.vx; r.y += r.vy; r.vy += 0.05 * u;
      if (r.n % 3 === 0) { spark(r.x, r.y, r.vx, r.vy, r.hue); }
      if (r.n > 3 && (r.y <= r.ty || Math.abs(r.x - r.tx) < 3 * u)) {
        var n = 84 + ((Math.random() * 48) | 0) + (combo > 2 ? 24 : 0);
        if (SHAPE_KIND[r.k]) { n = Math.floor(n * 0.9); }
        shell(r.tx, r.ty, r.hue, r.k, n);
        showShape(r.k);
        // 双响：主炸之后隔一拍再补一炸；连点够快还会多朵齐放
        if (r.k === 'double') { fuse.push({ x: r.tx, y: r.ty, t: 26, hue: (r.hue + 150) % 360, k: 'chrys' }); }
        if (combo >= 3) {
          shell(r.tx + (Math.random() * 2 - 1) * 44 * u, r.ty + (Math.random() * 2 - 1) * 28 * u,
            (r.hue + 40) % 360, KINDS[(Math.random() * KINDS.length) | 0], 46);
        }
        if (combo >= 6) {
          for (q = 0; q < 3; q++) {
            fuse.push({ x: r.tx + (Math.random() * 2 - 1) * 80 * u, y: r.ty + (Math.random() * 2 - 1) * 40 * u,
              t: 10 + q * 12, hue: (r.hue + 90 + q * 34) % 360, k: KINDS[(Math.random() * KINDS.length) | 0] });
          }
        }
        rock.splice(i, 1);
      } else if (r.y > H + 12 * u || r.n > 140) { rock.splice(i, 1); }
    }
    for (i = fuse.length - 1; i >= 0; i--) {
      fuse[i].t--;
      if (fuse[i].t <= 0) {
        shell(fuse[i].x, fuse[i].y, fuse[i].hue, fuse[i].k, 56);
        if (fuse[i].k === 'double') { fuse.push({ x: fuse[i].x, y: fuse[i].y, t: 20, hue: (fuse[i].hue + 120) % 360, k: 'ring' }); }
        fuse.splice(i, 1);
      }
    }
    for (i = parts.length - 1; i >= 0; i--) {
      p = parts[i];
      p.vx *= p.dr; p.vy = p.vy * p.dr + p.g * u;
      p.x += p.vx; p.y += p.vy; p.life--;
      if (p.split && p.life === p.split) {
        shell(p.x, p.y, (p.hue + 60) % 360, 'ring', 14);
        p.split = 0;
      }
      if (p.life <= 0 || p.y > H + 8 * u) { parts.splice(i, 1); }
    }
    for (i = trail.length - 1; i >= 0; i--) {
      p = trail[i];
      p.x += p.vx; p.y += p.vy; p.vy += 0.03 * u; p.life--;
      if (p.life <= 0) { trail.splice(i, 1); }
    }
    for (i = flashes.length - 1; i >= 0; i--) { flashes[i].life--; if (flashes[i].life <= 0) { flashes.splice(i, 1); } }

    if (Date.now() - lastTouch > 3000 && frame % 46 === 0) {
      launch(W * (0.14 + Math.random() * 0.72), H * (0.12 + Math.random() * 0.4));
      lastTouch = Date.now() - 2200;
    }
    if (combo && Date.now() - comboT > 900) { combo = 0; }
  }

  var shapeT = 0;
  function showShape(k) {
    if (!elShape) { return; }
    elShape.innerText = '· ' + (CN[k] || k);
    shapeT = frame + 72;
  }

  function draw() {
    ctx.globalCompositeOperation = 'source-over';
    ctx.fillStyle = 'rgba(7,10,22,0.25)';
    ctx.fillRect(0, 0, W, H);

    ctx.globalCompositeOperation = 'lighter';
    var i, p, a, g;
    for (i = 0; i < stars.length; i++) {
      p = stars[i];
      a = 0.26 + 0.26 * Math.sin(frame * 0.02 + p.p);
      ctx.fillStyle = 'rgba(200,218,255,' + a.toFixed(3) + ')';
      ctx.fillRect(p.x, p.y, p.r, p.r);
    }
    for (i = 0; i < flashes.length; i++) {
      p = flashes[i]; a = (p.life / 12) * p.a;
      g = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, 30 * u);
      g.addColorStop(0, 'hsla(' + p.hue + ',100%,74%,' + (0.14 * a).toFixed(3) + ')');
      g.addColorStop(1, 'hsla(' + p.hue + ',100%,60%,0)');
      ctx.fillStyle = g; ctx.beginPath(); ctx.arc(p.x, p.y, 30 * u, 0, 6.3); ctx.fill();
    }
    for (i = 0; i < trail.length; i++) {
      p = trail[i]; a = p.life / p.max;
      ctx.fillStyle = 'hsla(' + p.hue + ',100%,' + (62 + 22 * a) + '%,' + (a * 0.8).toFixed(3) + ')';
      ctx.beginPath(); ctx.arc(p.x, p.y, p.s * a + 0.3, 0, 6.3); ctx.fill();
    }
    for (i = 0; i < parts.length; i++) {
      p = parts[i]; a = p.life / p.max;
      var tw = 0.74 + 0.26 * Math.sin(frame * 0.5 + p.tw);
      var al = (a > 0.86 ? 1 : a) * tw;
      ctx.strokeStyle = 'hsla(' + p.hue + ',94%,' + (52 + 16 * a) + '%,' + (al * 0.92).toFixed(3) + ')';
      ctx.lineWidth = p.s;
      // 先铺一层大而淡的光晕再画亮核：叠加混合下才有"发光"而不是"点"
      ctx.fillStyle = 'hsla(' + p.hue + ',94%,60%,' + (al * 0.05).toFixed(3) + ')';
      ctx.beginPath(); ctx.arc(p.x, p.y, p.s * 2.3, 0, 6.3); ctx.fill();
      if (p.st) {
        ctx.beginPath(); ctx.moveTo(p.x - p.vx * 2.4, p.y - p.vy * 2.4); ctx.lineTo(p.x, p.y); ctx.stroke();
      } else {
        ctx.fillStyle = ctx.strokeStyle;
        ctx.beginPath(); ctx.arc(p.x, p.y, p.s * (0.5 + a * 0.6), 0, 6.3); ctx.fill();
      }
    }
    ctx.globalCompositeOperation = 'source-over';
    if (frame % 8 === 0) {
      if (elShots) { elShots.innerText = String(shots); }
      if (elParts) { elParts.innerText = String(parts.length + trail.length); }
      if (elCombo) { elCombo.innerText = combo >= 2 ? '连锁 x' + combo : ''; }
      if (elShape && frame > shapeT) { elShape.innerText = ''; }
    }
  }

  function loop() {
    if (!document.body.contains(cv)) { return; }
    step(); draw();
    requestAnimationFrame(loop);
  }

  var down = false, px = 0, py = 0;
  function xy(e) {
    var r = cv.getBoundingClientRect();
    var t = (e.touches && e.touches[0]) || e;
    return { x: (t.clientX - r.left), y: (t.clientY - r.top) };
  }
  function onDown(e) {
    e.preventDefault();
    var p = xy(e); down = true; px = p.x; py = p.y; lastTouch = Date.now();
    launch(p.x, Math.max(H * 0.12, p.y));
  }
  function onMove(e) {
    if (!down) { return; }
    e.preventDefault();
    var p = xy(e), hue = (hueSeed + frame) % 360;
    for (var k = 0; k < 3; k++) {
      spark(px + (p.x - px) * (k / 3), py + (p.y - py) * (k / 3), p.x - px, p.y - py, hue);
    }
    px = p.x; py = p.y; lastTouch = Date.now();
  }
  function onUp() { down = false; }

  fit();
  if (typeof ResizeObserver !== 'undefined') { new ResizeObserver(function () { fit(); }).observe(cv); }
  window.addEventListener('resize', fit);
  cv.addEventListener('pointerdown', onDown);
  cv.addEventListener('pointermove', onMove);
  window.addEventListener('pointerup', onUp);
  cv.addEventListener('pointercancel', onUp);
  cv.addEventListener('touchmove', function (e) { e.preventDefault(); }, { passive: false });
  document.addEventListener('keydown', function (e) {
    if (e.code === 'Space') { e.preventDefault(); launch(W * (0.2 + Math.random() * 0.6), H * (0.15 + Math.random() * 0.35)); lastTouch = Date.now(); }
  });

  launch(W * 0.5, H * 0.3);
  requestAnimationFrame(loop);
})();
</script>

```

预览区可以点开放大查看。预览运行在**离线沙箱 Web** 里，`<script>` 会照常执行（所以上面
这片烟花真的能用手指点着放）—— 内容来自你自己的本地文档，不加载任何远程脚本，外链脚本与网络请求
都不会发生。

## 十、各引擎实测能力（验收清单）

> [!NOTE]
> 这一节是**能力清单**，不是教程。下面每一条都在开发机上用**应用自带的离线渲染库真跑过**，
> 标注「实测」；只有官方文档写着、这里没跑过的，一律列入不支持项或明确标 ⚠️ 降级。
> 版本号从实际随包文件里读出来对，不抄声明。开关入口：设置 → 引擎管理。

### 10.1 引擎一览

正文里把围栏代码块的语言名写成下面任意一个，就会**渲染成图**而不是代码：

| 语言名 | 引擎 | 版本 | 用来画 |
| --- | --- | --- | --- |
| `mermaid`（别名 `mmd`） | Mermaid | 11.17.2 | 流程图、时序图、类图、状态图、ER 图、甘特、饼图、思维导图、时间线、C4、看板、数据包、架构图、块图、象限、需求、git 分支等 |
| `zenuml`（写在 ` ```mermaid ` 里，首行 `zenuml`） | Mermaid（ZenumlBridge 文本转译） | 11.17.2 | ZenUML 时序图（`@Actor 读者` / `A->B: 文本` / `A.m() { … }` / `return`）。零额外体积：翻成 `sequenceDiagram` 交给同一个 mermaid；中文参与者实测可翻 |
| `echarts` | Apache ECharts | 6.1.0 | 统计图（柱 / 折线 / 饼 / 散点 / 雷达 / 仪表盘 / 关系图 / 树 / 矩形树图 等） |
| `markmap` | markmap | 0.18.12 | 思维导图（Markdown 大纲直接成图） |
| `graphviz`（别名 `dot` / `gv` / `viz`） | Viz.js（内嵌 Graphviz 16.1.0） | 3.31.0 | DOT 语言关系图、有向图、聚类 |
| `nomnoml`（别名 `noml` / `nml`） | nomnoml（UMD，只依赖 graphre） | 1.7.0 | 极简 UML：关系符号见 5.12 那张表 |
| `chart`（别名 `chartjs` / `chart.js`） | Chart.js | 4.5.1 | 统计图，配置写 JSON（与 `echarts` 重叠，写法不同） |
| `vega-lite`（别名 `vl` / `vega`） | Vega 6.4.0 + Vega-Lite 6.5.0（BSD-3-Clause） | 6.5.0 | 声明式统计图：JSON spec 写 `data` / `mark` / `encoding`，出**矢量 SVG**；分面、聚合、交互选择子集都认 |
| `flowchart` | flowchart.js | 1.17.1 | 经典 `st=>start:` 写法的流程图 |
| `plantuml`（别名 `puml` / `iuml` / `startuml`） | **@plantuml/core 官方内核（MIT，TeaVM 编译）** | 1.2026.8 | PlantUML 原生语法 **14 个图种直接出图**（细节见 10.4；模板 5.5MB，含 Graphviz 布局引擎） |
| `abc` | abcjs | 6.7.1 | ABC 记谱法五线谱 |
| `wavedrom` | WaveDrom | 3.7.0 | **数字波形图**、逻辑门图、寄存器位段图 |
| `html` | 系统 WebView | — | 可交互 HTML 预览（`<script>` 会执行） |
| `katex` / `$$…$$` | KaTeX | 0.19.0 | 数学公式 |

**关闭某个引擎**：设置 → 引擎管理。关闭后该语言的代码块在阅读页与导出 HTML 里
都退回成**普通代码块**（不会渲染失败留白），导出的网页也不会假装能渲染。

### 10.2 随包库版本巡检（2026-10-14，逐个对过 npm 最新版）

| 库 | 随包 | npm 最新 | 结论 |
| --- | --- | --- | --- |
| KaTeX | 0.19.0 | 0.19.0 | 已最新 |
| Mermaid | 11.17.2 | 12.2.0 | **不升**：33 个样本实测 12.2.0 把 `requirementDiagram` 跑挂，且时序图参与者类型、C4 画法都没改善 |
| markmap-lib / -view | 0.18.12 | 0.18.12 | 已最新 |
| d3 | 7.9.0 | 7.9.0 | 已最新 |
| Apache ECharts | 6.1.0 | 6.1.0 | 已最新 |
| abcjs | 6.7.1 | 6.7.1 | 已最新 |
| Viz.js（Graphviz 16.1.0） | 3.31.0 | 3.31.0 | 已最新 |
| WaveDrom | 3.7.0 | 3.7.0 | 已最新 |
| nomnoml | 1.7.0 | 1.7.0 | 已最新 |
| Chart.js | **4.5.1** | 4.5.1 | 本轮升级（原 4.4.7；升级后浏览器实测仍正常出图） |
| Vega / Vega-Lite | 6.4.0 / 6.5.0 | 6.4.0 / 6.5.0 | 已最新（本轮刚引入） |
| @plantuml/core | 1.2026.8 | 1.2026.8 | 已最新（本轮引入；随它打包的 Viz.js 是 **3.24.0**，与 ```dot 用的 3.31.0 是两份，各配各的引擎） |
| @mermaid-js/mermaid-zenuml | 不随包 | 1.0.1 | **已移除**：插件在 11.17.2 上真机必报语法错，`zenuml.html` 与 3.14MB 插件一并删掉，ZenUML 改走 ZenumlBridge 文本转译（见 10.3 第 10 条） |
| flowchart.js | 1.17.1 | 1.18.0 | **不升**：1.18.0 的 npm 包里只剩 `src/` 与 `index.js`，**不再发布浏览器 UMD**，接它得自搭 bundler，而这是条借 raphael 画的老引擎 |
| MathJax | 3.2.2 | 4.1.3 | **不升**：v4 要 API 适配（`mjformula.html` 的加载与 `tex.packages` 配置按 v3 写）；它是 KaTeX 之外的兜底引擎，动它风险大于收益 |
| marked | **18.1.1** | 18.1.1 | 本轮升级（编辑器即时渲染用；Node 里跑过一遍解析自检） |
| turndown | 7.2.4 | 7.2.4 | 已最新 |

巡检顺带修了一处**声明与实际不符**：引擎管理页里 Mermaid 一直写着 10.9.3，
而随包文件早就是 11.17.2 —— 界面上的版本号也是承诺，不能滞后于包里真正带的东西。

### 10.3 Mermaid：实测可用的图类型

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
| C4 架构图 | `C4Context` / `C4Container` / `C4Component` | ✅（能画，但⚠️ 见下面第 5 条：图天生 1000px+ 宽，卡片里缩得小） |
| 数据包图 | `packet-beta` | ✅（中文标签实测可用） |
| 架构图 | `architecture-beta` | ✅（中文 / 空格 / 点号标签实测可解析——见下面第 4 条，这条是升级到 11.17.2 才通的） |
| 雷达图 | `radar-beta` | ✅（轴名英文） |
| 矩形树图 | `treemap-beta` | ✅（节点名英文） |
| 韦恩图 | `venn-beta` | ✅ |
| 鱼骨图 | `ishikawa-beta` | ✅ |
| 树形视图 | `treeView-beta` | ✅ |
| Wardley 战略地图 | `wardley-beta` | ✅ |
| 语法图 / EBNF | `railroad-ebnf-beta` | ✅ |
| 事件建模 | `eventmodeling` | ✅ |
| 泳道图 | `swimlane-beta` | ✅ |
| ZenUML | `zenuml` | ✅ —— 由 `ZenumlBridge` 转成 `sequenceDiagram` 后出图（见下面第 10 条：官方插件那条路在 11.17.2 上真机必报错，已废弃并删除） |

上面这些围栏不是照抄官方清单：是把《鸿蒙 Markdown 全量渲染示例》里的**每一个 mermaid 块**
逐个喂给随包的 11.17.2 实测出来的结果（当时 32 个出图、ZenUML 缺渲染路径不行；
补上转译桥之后那个 zenuml 样本实测出图，中文参与者、`@Actor`、两层 `return`、
`if{}`/`while{}` 花括号块与 `group` 丢弃配平都逐例在真 mermaid 里渲染验过）。
同一批样本也跑过 12.2.0 —— 结论是升级并不划算（见下面第 9 条）。

实测踩到的坑（逐条在**随包引擎**上跑过，每条都在 11.17.2 重新验过一遍）：

1. **象限图的标签没有冒号**。要写 `quadrant-1 We should expand`，写成 `quadrant-1: 我们要扩张` 会直接解析失败。
2. **类图、需求图靠缩进分块**。`class Animal { +int age }` 的花括号内换行要缩进，否则报 Parse error。
3. **`gitGraph` 的分支名只认 ASCII**。`branch 特性/登录` 报 `Lexer error … unexpected character: ->特<-`，
   写成 `branch feat/login` 就正常——同一批里 `kanban` 的中文列名、`packet-beta` 的中文段名、
   `quadrantChart` 的中英文轴名、`classDiagram` 的中文类名、`architecture-beta` 的中文标签**都没问题**，
   别把这条当成"Mermaid 不支持中文"。
4. **架构图的标签**在 11.17.2 之前确实是死的：`group app(cloud)[澄笺应用]`、`[API 层]`、`[shelf.json]`
   一律报 `Parsing failed: unexpected character: ->[<-`，**加引号也救不了**——那是 architecture-beta
   自带的词法器不吃 CJK，跟空格与点号无关。升级到 11.17.2 后这三种写法逐个重测，全部可解析。
   旧的"只认 ASCII"结论就写在文档里，现在已改过来；留着这条是为了说明：**图种报错先怀疑构建版本，
   别急着怪用户写法**。
5. **C4 图天生就宽，卡片里看不清字是正常的**。实测官方 `C4Context` 样例的 viewBox 是
   `1564×844`，正文卡片只有三百多 px 宽 → 等比缩到 **0.23 倍**，14px 的标签变成 3.2px：
   形状、连线、边界框都在，字糊成一团。C4 没有 `useMaxWidth` 这类"铺满容器"开关，
   缩略只能这样（放大浮层里 ± 或双指捏合到 3~5 倍就能读；`-` 到底可以再看全貌）。
   真要在小屏上读，建议把一张 C4 拆成 Context / Container / Component 三张。
6. **C4 的画法在 11.x 变了，而且改不回去**：11.17.2 把小人画成"圆头 + 大圆角身"、类型写成
   `[Person]`；旧版（10.9.x）是紧凑方框加 `<<person>>`。实测 `c4.showStereotype` /
   `c4.showIcon` / `boxMargin` / `rankSpacing` 等配置**在这个构建里一律没有效果**
   （五种配置组合出的 SVG viewBox 与填充完全一致），所以只能接受新画法。
   如果你手上留着一张旧引擎烘出来的紧凑 C4 卡片图，那是**缓存**，不是现在的引擎画的。
7. **浅色主题的时序图以前是灰框黑字**：`neutral` 给参与者框 `rgb(238,238,238)`，
   `default` 才是 `#ECECFF` 淡紫。实测四种图种（流程 / 类 / 状态 / ER）在两种主题下填充一样，
   **只有时序图不同**——"图表家族没颜色"这一条从头到尾就是主题选择，不是引擎不支持。
   现在浅色走 `default`，与导出的网页同口径。
8. 图里报错时正文会显示引擎的原始错误（`syntax error in text` 这类），不会静默变成空白卡。
9. **"换最新库"不解决问题，实测过**：把 12.2.0 拉下来跑同一批样本 —— 时序图的参与者类型
   仍然只认 `actor` / `participant`（`database` 等 6 种照样 Parse error）、C4 仍然是大圆头 +
   `[Person]` 的新画法，反而把 `requirementDiagram` 从"能画"变成 `Parse error on line 8`。
   所以随包版本停在 11.17.2，升级要连同这三十几个样本一起重验，不是换文件那么简单。
10. **ZenUML 走纯文本转译，不走官方插件**：`@mermaid-js/mermaid-zenuml` 那条路试过并删掉了——
    它的浏览器包 3.14MB 里装的是一份 React + @zenuml/core，而它对 mermaid 内部约定的假设
    停在更早的 11.x，换到随包的 11.17.2 上**真机必报 `Syntax error in text`**（插件路线
    不可靠，`zenuml.html` 与插件已一并从包里删）。
    现在由 `ZenumlBridge` 在解析层把 ZenUML 翻成 mermaid `sequenceDiagram`，
    复用已经在用的 mermaid 引擎：确定性、离线、零额外体积。
    转译覆盖：`title` / `@Actor X` / `A->B: 文本` / `A->B.m()` / `A-->B`（虚线）/
    `A.m() { … }` 调用块（`return` 回给发起者）/ `if{}→alt` / `while{}|for{}→loop` /
    `par|opt|alt|critical|break`，**中文参与者同样能翻**（标识符按 Unicode 认，
    只写 `[A-Za-z_$]` 时 `读者->App.open()` 整条不匹配，zenuml 块会整个退回代码块）。
    ⚠️ mermaid 没有的容器（`group` / `ref` / `try` / `catch` / `finally`）**连它的 `end` 一起丢**：
    只丢开头不丢收尾，产物里就剩一个孤儿 `end`，mermaid 直接语法错——比退回源码更糟。
    翻不动的（一条消息都没有、形状对不上）整块退回显示源码，不画坏图。

下面三张是这一节**自己渲染出来**的样本，分别对应上面第 1、10 条与 ER 图那一行：

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

```mermaid
zenuml
    title 读一篇文档
    @Actor 读者
    @Application 澄笺
    读者->MdParser.parse(markdown)
    MdParser->MdView.render(blocks)
    return 富文本
```

```mermaid
erDiagram
    FOLDER ||--o{ DOC : contains
    DOC {
        string name
        int words
    }
```

### 10.4 PlantUML：官方内核离线渲染 14 个图种 + 自带渲染器 3 个 + 分流 3 个

2026-10-14 起，阅读页的 ```` ```plantuml ```` **不再靠语法桥转成 mermaid**，而是直接跑
PlantUML 官方内核：npm `@plantuml/core`（MIT）—— 官方 Java 实现用 TeaVM 编译成 JS，
**不需要 Java、不需要服务端、不需要联网**，连同 Graphviz 布局一起内联在
`render/plantuml.html`（5.5MB 一个页面）。

**下面这张表是拿用户文档里 20 个 PlantUML 图种逐个实测出来的**（量 viewBox、SVG 节点数、
实际填充色，不是"看起来能跑"）：

| 首行写法 | 阅读页 | 说明 |
| --- | :---: | --- |
| `@startuml` 时序图 | ✅ 内核 | 参与者框 / 激活条 / note / alt-loop 全家都在，`database` 这类**画得出圆柱**（mermaid 桥做不到的一件，这里做到了） |
| `@startuml` 用例图 / 类图 / 活动图 / 组件图 / 部署图 / 状态图 | ✅ 内核 | 官方 dot 布局，跟 plantuml.com 出的图同形 |
| `@startuml` + `archimate` / `entity`（ER） | ✅ 内核 | Archimate 元素构造型、ER 的"一 / 多"基数记号都画得出 |
| `@startmindmap` / `@startwbs` / `@startgantt` | ✅ 内核 | 脑图、工作分解、甘特 |
| `@startjson` / `@startyaml` | ✅ 内核 | 数据可视化 |
| `@starttimeline` | ⚠️ 桥 mermaid `timeline` | 内核这份构建**没有 timeline 渲染器**（抛 `Unsupported diagram type`），mermaid 有同款图，逐行转过去 |
| `@startmath` | ⚠️ 转 KaTeX | 内核没有 JLaTeXMath（那是 Java），正文就是 LaTeX，直接进块级公式链路 |
| `@startfiles` | ⚠️ 制表符树 | 内核没有 files 渲染器；层级本身用 `└── ├── │` 画出来（代码卡片，离线导出也在） |
| `@startsalt`（盐图 / UI 线框） | ✅ 自带渲染器 | 内核这份构建没有 salt 渲染器，所以澄笺自己画（`salt-render.js`，卡片与导出同一份代码） |
| `@startnwdiag`（网络图） | ✅ 自带渲染器 | 同上：`nwdiag-render.js` 画网络分组 + 设备行 |
| `@startditaa`（ASCII 转图） | ✅ 自带渲染器 | 同上：`ditaa-render.js` 把 `+---+` / `-->` 画成方框与箭头 |
| `<:name:>` 表情精灵 | ❌ 画不出 | `emoji.js`（1.9MB）故意没打包；`<&star/>` 这类 openiconic 图标**有**（51KB） |
| `!theme xxx` | ✅ 有主题 | `themes.js`（326KB）已内联，不用联网取主题 |

三条硬限制，说清楚比"支持全套"诚实：

1. **标准库 `!include <C4/C4_Context>`、Azure / AWS / Kubernetes 图标包不在包里**（官方就没
   随 `@plantuml/core` 发，要另外下 sprite 库），用到时图里会出现 "Cannot load" 提示；
2. `@startfiles` 导出的是**制表符树文本**（代码卡片），`@startmath` 导出是公式、
   `@starttimeline` 导出是 mermaid 时序外的另一种图 —— 这三类是"换一种画法"，不是原样；
3. **导出与打印以"生成的图片"为主**（2026-10-16 起）：导出前会自动把缺的快照补生成
   （有进度提示，等齐即出），公式与图表全部以图片内嵌 —— 图齐全时**一个渲染库都不带**，
   文件小一个数量级、打开即见。个别实在生成不出来的才走兜底：`runtimes/plantuml-kernel.js`
   5.5MB 内联进含 PlantUML 块的导出文件，浏览器打开后 runner **一张一张串行**渲染
   （内核是 TeaVM 编译的，`renderToString` 共用一组模块级全局，并发会互相覆盖——
   实测 11 张一起发只有第一张出图），这类文件里这 14 类与阅读页是**同一套官方渲染**。
   （历史：2026-10-14 起曾"必带内核"，那是快照覆盖率还不稳时的权宜；现在浅色快照能
   稳定补生成，就以图片为主了。）

⚠️ 关闭「设置 → 引擎管理」里的 **PlantUML（官方内核）** 后，阅读页退回源码卡片，
导出侧同样退成代码块（关闭后不再假装能渲染）。

#### 兜底用的语法桥（只在没有快照、又没内联到内核时才走）

**判定规则**（这条决定"桥不了的写法为什么不会给你一张坏图"）：**翻译器本身就是验收器** ——
逐行白名单，有一行认不出来就**整体不桥**，正文退回代码块显示源码。
所以结果只有两种：一张画对的图，或者完整源码，**不存在"半桥"**。
（上一版就栽在这上面：状态图的 `[*] --> 草稿` 被当成消息塞进 `sequenceDiagram`，
mermaid 报 `Expecting 'TXT', got 'NEWLINE'`，用户看到的是一张报错卡。）

时序图 → `sequenceDiagram`：

| PlantUML 写法 | 翻成 |
| --- | --- |
| `actor` / `participant` / `database` / `boundary` / `entity` / `queue` …（含 `"显示名" as ID`） | `actor` 留住（小人 + 淡紫底），其余一律 `participant ID as 显示名`，**画不出圆柱与队列** |
| `A -> B: 文本`、`A --> B: 文本`，以及不带空格的 `A->B: 文本` | `A->>B:` / `A-->>B:`（实线 / 虚线） |
| `A -> B++` / `A -> B--`、`activate B` / `deactivate B` | `activate` / `deactivate` |
| `note over A`、`note over A, B`、`note left of / right of` | `Note …` |
| `alt` / `else` / `end`、`loop` / `opt` / `par` / `and` / `break` / `critical`、`group` | 同名关键字直接透传 |
| `autonumber`、`title …` | 原样透传 |
| `== 阶段分隔 ==` | **降成注释** `%% 分隔：阶段`——mermaid 时序图没有分隔线语法，原样透传实测直接 Parse error |
| `skinparam …`、`!theme`、`!$变量`、`hide/show/style` | **丢弃**（纯外观指令，透传会让整图报错） |
| 认不出的行 | 降格成 mermaid 注释 `%% …`，不再连累整张图 |

**参与者类型只认两种**：实测这个 mermaid 构建（11.17.2）的时序图声明只接受 `actor` 与
`participant`，`database` / `boundary` / `control` / `entity` / `collections` / `queue`
带不带 `as`、裸写、引号写法 —— 30 个组合逐个渲染**全部 Parse error**。所以 PlantUML 的
`database "插件注册表" as R` 只能画成普通框（圆柱形没有），小人 `actor` 则完整保留。
宁缺形状，也不给一张报错卡。

状态图 → `stateDiagram-v2`：

| PlantUML 写法 | 翻成 |
| --- | --- |
| `[*] --> 草稿`、`草稿 --> 已发布 : 发布` | 同形直接透传（两种语法本来就一样） |
| `state "审核中" as rev`、`rev : 内容与格式都要看` | 同形透传（中文状态名、中文描述实测都画得出） |
| `state 判定 <<choice>>`（也收 `<<fork>>` / `<<join>>`） | 同形透传 |
| `state 外层 { A --> B }` 复合状态 | 同形透传 |
| `note right of S1` … `end note`、`note left of S2 : 文本` | 多行原样透传；单行拆成三行 |
| `title …` | **丢弃**（mermaid 状态图不吃 `title` 语句，宁可不画标题也不整图不桥） |

类图 → `classDiagram`：

| PlantUML 写法 | 翻成 |
| --- | --- |
| `class Foo {` 换行写成员 换行 `}`（`+name: String`、`+move()`、`+get(): T`） | 同形透传，成员按字面显示 |
| `Animal <\|-- Dog`、`A --> B`、`A *-- B`、`A o-- B`、`A ..> B`、`A ..\|> B`、`A <--> B` | 同形透传 |
| 多重性 `Teacher "1" --> "*" Student : 教授` | 同形透传 |
| `class 子 extends 父` / `class 子 implements 父` | `父 <\|-- 子` / `父 <\|.. 子` |
| `interface Foo` | 原样透传 |
| `interface Foo { 成员 }`、`abstract class Foo { 成员 }` | `class Foo { <<interface>> / <<abstract>> … }` ——**这个 mermaid 构建不认 `interface X {` 和 `abstract class`**（实测词法/语法报错），换成构造型写法，成员一个不丢 |
| `enum Color { RED GREEN }` | `class Color { <<enumeration>> … }` |
| `泛型 class Box~T~`、中文类名 | 原样透传（实测可解析） |
| `note left of X : 文本`、`note left of X` … `end note` | `note for X "文本"` / `note for X """…"""`（左右位置信息丢失） |

**桥不住的**：用例图、活动图、组件图、部署图、脑图、WBS、甘特、JSON / YAML 可视化、
`package { }` 嵌套、彩色箭头 `-[#red]->`、命名框写法 `[A] --> [B]` —— 这条只影响**兜底路径**：
内核在场时它们由内核原生出图（阅读页与导出都一样），只有"没有快照 PNG、又拿不到内核"
（CDN 回退模式）时才会退成源码。

下面四张就是**本文档自己渲染出来的**内核结果（源码是 PlantUML，不是 mermaid）：

```plantuml
@startuml
title 渲染链路（内核原生，桥路径画不出）
package "解析层" {
  [MdParser]
  [PlantumlBridge]
}
package "渲染层" {
  [DiagramWeb]
  [render/plantuml.html]
}
[MdParser] --> [PlantumlBridge] : 分流图种
[PlantumlBridge] --> [DiagramWeb] : 源码
[DiagramWeb] --> [render/plantuml.html] : 离线内核
@enduml
```

```plantuml
@startmindmap
* 澄笺渲染
** 文本
*** 批注 / 学习卡
*** 注音 ruby
** 图表
*** 内核 PlantUML
*** mermaid 30 种
*** 波形 WaveDrom
** 公式
*** KaTeX + mhchem
*** MathJax 兜底
@endmindmap
```

```plantuml
@startuml
title 发布流程
[*] --> 草稿
草稿 --> 审核中 : 提交
state "审核中" as 审核中
审核中 : 内容与格式都要看
审核中 --> 已发布 : 通过
审核中 --> 草稿 : 退回
已发布 --> [*]
note right of 审核中
  批注与学习卡
  都在这一步生成
end note
@enduml
```

```plantuml
@startuml
abstract class MdBlock {
  +kind: string
  +srcLine: int
}
class MdParser {
  +parse(md): MdBlock[]
  +fenceLang(line): string
}
class PlantumlBridge {
  +kindOf(src): string
  +toMermaid(src): string
}
interface Renderable {
  +render(): svg
}
MdParser --> PlantumlBridge : 交给桥
MdParser --|> MdBlock
PlantumlBridge ..|> Renderable
note right of PlantumlBridge : 认不出一行就整体不桥
@enduml
```

### 10.5 ECharts：实测可用的系列

应用内置的是 **完整构建**（不是按需裁剪版），下面 14 个系列都实测出图：

`bar` 柱状 · `line` 折线 · `pie` 饼图 · `scatter` 散点 · `radar` 雷达 · `gauge` 仪表盘 ·
`funnel` 漏斗 · `heatmap` 热力图 · `candlestick` K 线 · `sankey` 桑基 · `sunburst` 矩形树图 ·
`themeRiver` 主题河流 · `tree` 树图 · `graph` 关系图

> [!TIP]
> 想要**脑图 / 思维导图**，两条路：ECharts 的 `tree` / `graph` 系列（适合数据结构化的场景），
> 或者直接用 `markmap`（写 Markdown 大纲就能出图，更省事）。

> [!WARNING]
> ECharts 块必须是**合法 JSON**。键名的引号可以省（`{signal: …}` 那种会被自动补上），
> 但**字符串值必须带引号**，也不能写注释和尾逗号。

### 10.6 WaveDrom、Graphviz 与公式

WaveDrom 三种图全支持（样本见 5.10）：

| 种类 | 顶层键 | 画什么 |
| --- | --- | --- |
| 时序波形 | `signal` | 时钟、总线、分组、箭头 |
| 逻辑门图 | `assign` | 信号怎么被门电路合成 |
| 寄存器位段 | `reg` | 指令 / 寄存器的位划分 |

> [!NOTE]
> **深浅主题都用浅色波形面板**。三种图的底色统一固定为不透明白色：
> `signal` 的白底板是 WaveDrom 皮肤自己画的，`reg` / `assign` 两条路径**不画底板**
> （位段框、分隔线、文字是库里硬编码的黑色描边），深色卡片里等于黑底写黑字、
> 整块糊掉 —— 澄笺会给缺底板的图补一块白底，所以不用配置。
> 官方 dark 皮肤同理不换：它也是白底，换过去只会变成"白底上铺浅色描边"，波形糊掉。

Graphviz 实测支持 `digraph` / `subgraph cluster_*` 聚类 / 边标签 / CJK 文字，布局引擎 `dot`
（样本见 5.9）。

| 用途 | 引擎 | 说明 |
| --- | --- | --- |
| 块级公式 `$$…$$` / `\[…\]` | KaTeX 0.19.0 | 完整渲染；未就绪时先用自研 MathLite 线性化兜底，不留空白 |
| 行内公式 `$…$` / `\(…\)` | KaTeX 渲染成图内联 | 与正文同基线，可点开放大 |
| 化学方程式 `\ce{…}` | mhchem 扩展 | 第四节 5.13 有逐条样本 |

明确**不支持**的：`\href`（外链）、`\includegraphics`（嵌图）。

### 10.7 Markdown 扩展语法支持矩阵

| 语法 | 支持 | 备注 |
| --- | :---: | --- |
| GFM 表格 + 列对齐 | ✅ | 单元格内可写行内标记 |
| 围栏代码块 | ✅ | 三个反引号与三个波浪号都认；**139 个语言标识 / 8 个语言族**逐语言着色，未识别的语言按纯文本渲染 |
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
| 显式标题 ID `## 标题 {#intro}` | ✅ | 花括号不再显示在标题里；导出的网页给 `<h*>` 加真 `id`，中文 id 也可以。阅读页跳转**先认这个 id、再按标题文字匹配**。pandoc 的**多属性写法**同样收：`{#bg .unnumbered}`、`{width=60%}` 都按属性块词法吃掉，id 落地、其余忽略 |
| 裸标签锚点 `<a id="x"></a>` | ⚠️ 半支持 | 标签被脱掉、内容保留，但这个 id **不参与应用内跳转**（行内那条路上没有可登记的块位置）；把锚点写在标题后面那个 `{#x}` 上才两边都通 |
| 定义列表（`术语` + `: 定义`） | ✅ | 术语一段、每条定义单独一块（可单独批注）；导出不套 `<dl>` 而是缩进段 |
| 行内 HTML（`<kbd>` `<ruby>` `<span style="color">` `<u>` `<mark>` `<sub>` `<sup>` `<small>` `<a>` `<img>` `<br>`） | ✅ | 键帽用窄空格当内边距；注音量宽后居中压在基准字上方、不占推进宽度（量不出来就退回小号上标），含注音的段自动加行距；`<script>` / `<style>` 丢弃。样式放行五样：十六进制字色、实心背景色、**渐变取第一个色标当近似底**、`font-size` 的 em / %（`<small>` 同义，px 不接）、font-weight ≥600 粗体 |
| 块级 HTML（`<table>` 合并单元格、`<div style>`、`<svg>`、`<figure>`、音视频） | ✅ | 整段交给内嵌 WebView 渲染（`render/html.html`），所以 colspan / rowspan 这类排版能用；自动识别的块级 HTML 会先摘掉 `<script>` `<iframe>` 与 `on*` 事件属性 |
| **离线铭牌**（GitHub README 的 shields 徽章） | ✅ | 整行徽标在**本地绘制**：灰底标签 + 彩底值，不联网、基础离线模式也显示，导出与打印一致，点开它包着的链接。形态与参数见 3.15 节 |
| 4 空格 / Tab 缩进代码块 | ✅ | 老式写法；紧跟段落的缩进行仍是段落续行，隔一行空行才收成代码 |
| Diff 代码块 ` ```diff ` | ✅ | 按行首 `+` / `-` / `@@` 整行着色（阅读页、导出、放大视图三处一致） |
| 指定行高亮 ` ```js{1,3-5} ` | ✅ | VitePress / Shiki 写法，也认 `hl_lines="1 3"`；阅读页琥珀行底，导出网页同色 |
| 代码组 `::: code-group` | ✅ | 阅读页是真页签；导出的静态网页没有脚本，退成「每段带标题的代码块」，内容一段不丢 |
| 冒号容器 `::: tip / warning / danger / info / details` | ✅ | 前四类映射成提示卡，`details` 收成折叠面板 |
| Pandoc 围栏 div `::: {#note1 .tip}` | ✅ | 类名驱动（`tip` / `info` / `warning` / `caution` / `important` / `danger` / `details`…），`#id` 进锚点。`::: {=html}` 按"原生块"语义直接当 HTML 渲染，脚本能跑 |
| Pandoc 行内属性 `[文字]{.bold color=#2F63E8}` | ✅ | `.bold` / `.italic` / `.strikeout` / `.underline` 与 `color=` / `background-color=` 走原生 HTML 那两条通道（导出网页里不丢色）；图片 / 链接尾部的 `{#fig:x width=60%}` 同样吃掉 |
| 粗斜体 `***文字***` | ✅ | 三连是「又粗又斜」，不再漏出字面星号；`*斜 **粗** 斜*` 的嵌套同样收得住 |
| 下划线定界符 `_词_` / `__词__` | ✅ | **词内不算强调**，且按 **Unicode** 判词字符：`user_name`、`这是_一_个测试`、`Markdown_语法` 都按字面输出（旧实现只量 ASCII，中文里的下划线全被排成斜体）。`*` 不受这条限制，`这是*一*个测试` 仍是斜体 |
| 真正的下划线 `++文字++` / `<u>` / `<ins>` | ✅ | `_x_` 归斜体不是下划线；插入线三条都出真下划线，导出是 `<ins>` / `<u>` |
| HTML 字符实体 `&amp;` `&#124;` `&#x2014;` | ✅ | 常用命名实体 37 条 + 数字实体全收；行内代码里保持字面 |
| 表格里的竖线 `\|` | ✅ | 转义竖线不断列，`&#124;` 同样可用 |
| 自动目录 `[TOC]` | ✅ | 单独占一行才展开：换成一份按标题层级的列表，每条是 `[标题](#标题)`，点了就跳；导出网页同样可跳。行内出现 `[TOC]` 字样不误伤 |
| 尖括号自动链接 `<https://…>` `<mailto:…>` `<a@b.com>` | ✅ | 链接文字与地址都不带尖括号；邮箱那种会补上 `mailto:` 前缀。阅读页对 mailto 是**复制地址**（浏览器拉起需要系统能力），网页版正常打开信箱 |
| 行内脚注 `^[直接写内容]` | ❌ | 脚注走 `[^标签]` + 文末 `[^标签]: 内容` 两段式；行内那种按普通文字显示 |
| 注释式行高亮 `// [!code highlight]` | ⚠️ 降级 | 注释留在代码里，行不 Highlight；指定行请用围栏元数据（上一行那种 ✅ 写法） |
| `+++` 分页（pymdownx.tabbed） | ❌ | 代码组请用 `::: code-group`，正文分组用提示块或折叠面板 |
| 硬换行（行尾两空格 / 反斜杠） | ❌ | 段内换行会被并成空格 |
| Pandoc 文献引用 `[@key]`、`-F pandoc-citeproc` | ⚠️ 降级 | 只显示成 `[key]` 上标样子，**不生成参考文献表** —— 没有 bibtex/CSL 数据源，编号与"点击跳到文献"都无从算起。要引用请把文献表自己写在文末（脚注是更合适的载体） |
| Pandoc 图表编号 `![图](a.png){#fig:x}` | ⚠️ 降级 | 图片正常显示，尾部 `{#fig:x width=60%}` 会被吃掉（不再污染正文），但**不自动编号、也不解析 `@fig:x` 交叉引用**（需要编号引擎与全文索引，离线渲染器里没有） |
| MDX（`<Component />` 带 props、`export` / `import`） | ❌ | MDX = 在 Markdown 里写 JSX，要**构建期**用 `@mdx-js/*` 编译成组件。阅读器没有构建步骤，也没有组件沙箱，这类标签按"块级 HTML"处理成静态内容；要能跑的交互请用 `html` 语言围栏（它**故意**执行 `<script>`） |

### 10.8 渲染之外的能力

- **导出**：HTML（自包含，**公式与图表以生成的图片内嵌** —— 导出前自动把缺的图补生成，
  图齐时一个渲染库都不背、文件小一个数量级，打开即见；个别生成失败的才退回内联渲染库
  兜底）、Markdown、EPUB、PDF 打印。
- **图片**：文档内图片点击放大，双指缩放与拖动。
- **公式与图表放大**：点卡片右上角的放大，进入全屏浮层，支持双指捏合、± 缩放、旋转、
  重新自适应、切看源码。
- **存成图片**：放大浮层工具栏一键下载 **PNG**（代码 / 图片 / 网页预览这三类不出按钮：
  代码该复制、图片本来就在磁盘上、网页预览是交互内容）—— 强制浅色底、按内容边界出图
  不留空白、等比不拉伸，屏外没画进画布的部分也完整出图。**另开一条渲染通道重画一遍**，
  不是截屏幕上那块；超宽内容先整体等比缩进再出图。
- **离线**：所有渲染库随应用打包，全程无网络请求；「基础模式」可彻底断网。

---

## 附、参考与声明

第三节这份 Markdown 语法教程的**分类方式与讲解顺序**，参考了链滴（ld246.com）作者 **Vanessa**
的《Markdown 使用指南》系列三篇，特此声明并致谢：

- [Markdown 使用指南 - 基础语法](https://ld246.com/article/1583129520165)
- [Markdown 使用指南 - 扩展语法](https://ld246.com/article/1583305480675)
- [Markdown 使用指南 - 语法速查手册](https://ld246.com/article/1583308420519)

链滴是 [Vditor](https://b3log.org/vditor/) 同一团队（b3log / 88250）旗下的社区，
Vditor 是一款浏览器端的 Markdown 编辑器 —— 一并列入本文档开头「开源与致谢 → 参考的项目」。

需要说清楚的一点：**这三篇的原文没有被复制进本文档**。每一条语法都按澄笺解析器的实际实现
重写并逐条核对过，因此覆盖面与措辞和原文不同；3.16 那份"不支持清单"也是据澄笺自己的实现补充的，
与原作者无关 —— 若本文档某处与实际渲染效果不符，责任在本文档，请以上文"实测为准"。

**关于示例里的网址**：正文中所有演示用的链接一律使用 `example.com`（IANA 保留给文档示例的
占位域名），不指向任何真实站点；本文档只有本节的参考链接与「开源与致谢」里的项目仓库是真实链接。
文中出现的其它名称与商标归各自所有者。数学公式由 KaTeX 渲染，
各类图表由 D3 / markmap / Mermaid / ECharts / Graphviz / ABCjs 等开源库离线渲染，
版本与许可证见本文档开头「开源与致谢」。

---

*本文档（含其中展示的示例乐谱小曲，以及那段可以用手指点着放的烟花）由 AI 辅助生成，
并经人工校对；示例内容仅供参考，准确性由使用者自行判断。*
