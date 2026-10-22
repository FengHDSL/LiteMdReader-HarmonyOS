import { L10n } from '../service/L10n';
/**
 * 澄笺 · 设置 · 功能帮助
 * ======================
 *
 * 「探索中心 → 功能帮助」：把**全部功能、使用方法与常见问题**集中在一页。
 *
 * 为什么要有这一页：应用的功能是长出来的（书架、阅读、编辑、统计、导出、大屏、
 * 设备能力），散落在各处入口里；很多东西不看说明根本不知道存在
 * （典型如"自动滚屏开了以后那颗悬浮钮怎么关"）。
 *
 * 组织方式：
 *  · 顶部一条**关键词筛选**（功能多了以后靠翻页找不现实）；
 *  · 正文按板块分卡：每个板块 = 若干条「条目名 + 怎么做」；
 *  · 末尾「常见问题」按问答体，写的是**用户真实会卡住的地方**。
 *
 * ⚠️ ArkUI 白屏四坑（本页同样规避，见 MEMORY.md）：
 *   ① ForEach 第一参数必须真数组（筛选结果是真数组）；
 *   ② 不用 Set/Map/for...of（线性查找）；
 *   ③ @Builder 内不跨分支返回异构结构；
 *   ④ ForEach 的 itemGenerator 里不调 @Builder（条目全部内联画）。
 */
import { NavLifecycle } from '../service/NavLifecycle';
import { SettingsShell } from './SettingsShell';
import { ImmersiveCard } from '../material/ImmersiveCard';
import { ImmersiveInput } from '../material/ImmersiveInput';
import { AppearanceFx } from '../service/AppearanceFx';
import {
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  paletteFor,
  HwFont
} from '../theme/DesignTokens';

/** 一条帮助条目：叫什么 + 怎么用 */
interface HelpItem {
  title: string;
  body: string;
}

/** 一个功能板块 */
interface HelpSection {
  /** 板块名 */
  name: string;
  /** 板块图标（用系统符号，工程已有同款用法） */
  icon: Resource;
  items: HelpItem[];
}

/** 顶部速查：最容易被问到的三件事（放最前面，省得翻） */
const QUICK: HelpItem[] = [
  {
    title: L10n.t('图表卡片右上角那排按钮是什么？'),
    body: L10n.t('从左到右：**刷新**（重新渲染这张图）、**源码**（预览 ↔ 源码切换）、**放大**（全屏查看）。')
      + L10n.t('切换深浅模式时所有图表 / 公式卡会**自动刷新**，不用手动点。')
  },
  {
    title: L10n.t('网络图 / 盐图 / Ditaa 这些新图表怎么写？'),
    body: L10n.t('编辑页工具条「图表」组有一键模板（网络图、盐图、Ditaa、统计图、极简UML、Chart.js、ZenUML）：')
      + L10n.t('点一下插入带占位的代码块，改占位内容即可。也可手写 ```nwdiag / ```salt / ```ditaa 围栏。')
  },
  {
    title: L10n.t('代码块太长会折叠吗？'),
    body: L10n.t('**不会**：代码块全部行直接完整铺开（与放大后的形态一致），不再限高滚动、也没有"展开全部"按钮。')
  },
  {
    title: L10n.t('自动滚屏的悬浮按钮怎么关掉？'),
    body: L10n.t('**长按**那颗圆钮即结束并收起；只点一下是「暂停」（图标变播放，再点继续）。')
      + L10n.t('离开阅读页也会自动收起。开始与调速在「更多」面板里的「自动滚屏」一格。')
  },
  {
    title: L10n.t('想改某一段文字，点了没反应？'),
    body: L10n.t('编辑页顶栏第 2 颗按钮（✎）进入**实时预览**：点段落本身、或点段落末尾的「✎ 编辑」即可就地改，')
      + L10n.t('改完点「完成」变回渲染样子。每段下面有虚线，虚线内的图标就是这一段的。')
  },
  {
    title: L10n.t('为什么有些文档改不了？'),
    body: L10n.t('文档被标成了**只读**（内置教程默认只读，且正文在应用包内，勾选与表格编辑都不写盘）。')
      + L10n.t('自建文档可在阅读页「更多」里切「可写 / 只读」。')
  },
  {
    title: L10n.t('AI 正在回答，我能切别的话题吗？'),
    body: L10n.t('**可以**。切历史会话、开新话题都不打断它——原话题会继续在后台生成（历史里带转圈图标），')
      + L10n.t('跑完后书架底栏的 AI 入口会出现**红色角标**，进去即清零。')
      + L10n.t('回到那条会话还能看到「正在思考…」，结果落盘后自动出现。')
  },
  {
    title: L10n.t('AI 附件有数量 / 大小限制吗？'),
    body: L10n.t('**不限制**：图片、文件都可以多选，也能拍照或引用应用内文档。')
      + L10n.t('只是附件很大时（尤其多张原图）请求会等更久，应用会在偏大时提醒一句。')
  }
];

/** 全部功能板块 */
const SECTIONS: HelpSection[] = [
  {
    name: L10n.t('书架（首页）'),
    icon: $r('sys.symbol.book'),
    items: [
      {
        title: L10n.t('顶栏下方的标签栏'),
        body: L10n.t('给文档加过标签（阅读页「更多」→「标签」）后，书架顶栏下方会出现标签筛选条：')
          + L10n.t('点标签只看对应文档，**筛选结果直接平铺**（不按文件夹分组）。一篇标签都没有时这行不显示。')
          + L10n.t('在某个标签下**新建或导入文档会自动带上该标签**；停在「全部」下新建 / 导入则不打标签。')
          + L10n.t('标签可以**长按拖动排序**（阅读页标签面板里同样支持），顺序会被记住；')
          + L10n.t('「全部」是筛选保留词，不能拿来当标签名。')
      },
      {
        title: L10n.t('新建与导入'),
        body: L10n.t('「新建文档」可写空白文档，也可从模板开始；文件夹按钮一次最多导入 50 个 .md / .txt（结束后汇总成功与失败数量）。')
          + L10n.t('也可以把文件从文件管理器拖进书架窗口直接导入。')
      },
      {
        title: L10n.t('网格 / 列表视图'),
        body: L10n.t('右上角切换。列表（树形）视图按文件夹归组展开，网格视图按封面墙铺开。')
      },
      {
        title: L10n.t('文件夹'),
        body: L10n.t('长按一张封面拖到另一张上即合并成文件夹；文件夹可展开、可重命名。')
          + L10n.t('展开会自动滚到该文件夹位置，收回时自动滚回原来的位置。')
      },
      {
        title: L10n.t('数学公式（LaTeX）'),
        body: L10n.t('块级公式用 `$$公式$$` 或 `\\[公式\\]`，行内用 `$公式$` 或 `\\(公式\\)`。')
          + L10n.t('公式由内置 KaTeX 完整渲染（与标准 LaTeX 效果一致）：希腊字母与数学符号、上下标、分数与根式、')
          + L10n.t('求和/积分等大型运算符、矩阵与多行环境（pmatrix/bmatrix/vmatrix/cases/aligned/array 等）、')
          + L10n.t('对齐与编号（\\tag）、自动缩放的括号定界符（\\left\\right、\\big 系列）、')
          + L10n.t('数学字体与文本（\\mathbb/\\mathcal/\\mathbf/\\text）、颜色与框注（\\boxed），')
          + L10n.t('并支持公式内自定义宏（\\newcommand）。导出 HTML/PDF 同样使用完整 KaTeX 渲染。')
      },
      {
        title: L10n.t('搜索'),
        body: L10n.t('顶部搜索同时搜**文件名、全部正文、图片名**，结果分三组；点一条直接打开并定位。')
      },
      {
        title: L10n.t('封面与阅读进度'),
        body: L10n.t('封面由文档名生成，可在格子菜单里改成图片或指定底色；封面底部进度条与右下角百分比反映阅读进度。')
      },
      {
        title: L10n.t('收藏 / 批量操作'),
        body: L10n.t('阅读页信息卡右上角点爱心即收藏，「我的收藏」面板可集中查看。')
          + L10n.t('点封面进入多选后可批量删除、批量移入文件夹。')
      },
      {
        title: L10n.t('文档编码'),
        body: L10n.t('非 UTF-8 的文件（如 GBK 存出的 txt）会整篇乱码：在格子的「更多」或阅读设置里手动指定编码，')
          + L10n.t('按文档记忆，下次自动沿用。')
      },
      {
        title: L10n.t('文档体检'),
        body: L10n.t('封面 ⋯ 菜单里扫描结构隐患：围栏未闭合、图片路径不存在、锚点失配、表格列数不齐、空章节、超长行等，')
          + L10n.t('每条都给行号。')
      },
      {
        title: L10n.t('知识图谱'),
        body: L10n.t('把各篇之间的 `[[文档链接]]` 汇总成一张关系图（生成一篇含 mermaid 图的新文档），')
          + L10n.t('并列出「待补文档」与「未连接」的文档。')
      },
      {
        title: L10n.t('Front Matter 元数据（封面三件套）'),
        body: L10n.t('文首 `---` 区块里写元数据，书架封面会照它显示：`title:` 换封面上的名字（文件名不动）、')
          + L10n.t('`cover:` / `color:` 指定封面色（写 #RRGGBB）、`date:` 顶掉"最后修改时间"那一行；')
          + L10n.t('`tags:` 会被全文搜索搜到。手动设过的封面色优先于文档里的设置。')
          + L10n.t('（正文一改动会重新读取，没改过不会重复解析。）')
      },
      {
        title: L10n.t('今日笺'),
        body: L10n.t('封面 ⋯ →「今日笺」：一页告诉你今天该干什么 —— 待办（含最紧的一条）、今天到期的复习卡片、')
          + L10n.t('今日修改与今日读过的文档、以及读到一半的书。数据实时取自书架状态，不会过期。')
      },
      {
        title: L10n.t('批注汇总'),
        body: L10n.t('封面 ⋯ →「批注汇总」看这一篇的全部标注；「批注汇总导出为文档」把**所有文档**的标注')
          + L10n.t('整理成一篇《批注汇总》放进书架，方便复盘。')
      },
      {
        title: L10n.t('打开方式关联'),
        body: L10n.t('在系统文件管理器中长按 .md / .txt 选「打开方式」可直接用澄笺打开；')
          + L10n.t('从外部导入的文件会落在书架并自动打开。')
      }
    ]
  },
  {
    name: L10n.t('阅读'),
    icon: $r('sys.symbol.doc_text'),
    items: [
      {
        title: L10n.t('多标签阅读'),
        body: L10n.t('同时开多篇，标签栏默认在顶栏下方，也可改到**底部悬浮栏上方**（更多面板里的开关）。')
          + L10n.t('标签长按可关闭此标签 / 其他 / 全部、重新加载。')
      },
      {
        title: L10n.t('目录与注释侧栏'),
        body: L10n.t('右滑出目录、左滑出注释。大屏横屏时可停靠成左右两栏（宽度记忆，拖好了就记住）。')
      },
      {
        title: L10n.t('批注：荧光笔 / 文字 / 手写'),
        body: L10n.t('长按选中文字后选荧光笔颜色或写批注；手写批注以红色双下划线呈现，点「查看」看手写图。')
          + L10n.t('所有批注在注释侧栏集中显示，可跳回原文。')
      },
      {
        title: L10n.t('批注里的图片与关联文档'),
        body: L10n.t('写批注时可以**插入图片**（显示为缩略图，点开全屏看）和**关联其他文档**（点一下直接跳过去）。')
          + L10n.t('内容存在批注正文里：**修改批注只改正文**，划选的那段原文永远是查找锚点，不会被覆盖。')
          + L10n.t('删除批注、图片会先进「数据管理 → 回收站」，7 天内可找回。')
      },
      {
        title: L10n.t('点批注文字看详情'),
        body: L10n.t('点正文里带荧光的那段字，屏幕中间弹出批注条：内容、图片缩略图、关联文档，以及修改 / 复制 / 删除三颗图标。')
          + L10n.t('从注释侧栏点「跳转」时，正文会把那条批注**居中显示并闪烁 5 次**，只闪这条批注自己的文字。')
      },
      {
        title: L10n.t('排版与主题'),
        body: L10n.t('字号、行高、版心宽度、段落间距、首行缩进、字体；正文里**双指捏合**可直接改字号。')
          + L10n.t('主题五档：跟随系统 / 浅色 / 深色 / 羊皮纸 / 护眼绿。')
      },
      {
        title: L10n.t('沉浸阅读'),
        body: L10n.t('顶栏、底栏、标签栏与查找条整层不渲染，屏幕上只留一颗退出钮，进入入口在顶栏返回键右侧。')
      },
      {
        title: L10n.t('自动滚屏'),
        body: L10n.t('「更多」面板 →「自动滚屏」一格可开始与调速（1–10 档，约 20–200 vp/秒）。')
          + L10n.t('滚动时屏幕中部靠边会出现一颗悬浮钮：**点一下暂停 / 再点继续 / 长按关闭并收起**；')
          + L10n.t('点正文任意处也会暂停。它跟随左右手（智感握姿），也可以拖到别处（松手自动贴边）。')
      },
      {
        title: L10n.t('学习卡与复习'),
        body: L10n.t('阅读时长按文字选「**学习卡**」，写上内容（实色黄底高亮）。')
          + L10n.t('书架右滑进「文房」，复习卡片把这些卡做成**背卡**：正面是划选的原文，')
          + L10n.t('点卡片翻面看内容；底部三档评分——忘了 / 模糊会**重复出现直到记住**，')
          + L10n.t('**累计 3 次「记得」才算掌握**，之后按艾宾浩斯遗忘曲线拉长间隔。')
          + L10n.t('支持选择只背某几篇文档，还带**每日目标**、**签到日历**与**遗忘曲线分布**。')
      },
      {
        title: L10n.t('桌面卡片：学习卡（背诵 / 记忆）'),
        body: L10n.t('把「学习卡」放上桌面（长按桌面 → 卡片 → 澄笺），有两种尺寸形态：')
          + L10n.t('**学习卡·背诵**默认只显示正面，右中的「具体」按钮翻到批注内容、再点回正面；')
          + L10n.t('**学习卡·记忆**正面与批注同时显示。右上角是今天剩下的张数，右下「下一个」换下一张。')
      },
      {
        title: L10n.t('书架的三个页面'),
        body: L10n.t('书架支持**左右滑动**切换：左滑进「文房」（复习卡片 / 今日笺 / 全部待办 / 批注速记 / 阅读统计），')
          + L10n.t('右滑进「写作日志」（热力图 / 字数 / 回头看看）。循环滑动，顶栏页名与底栏圆点跟随。')
          + L10n.t('搜索按钮常驻：在任何一页点它都能原地搜索全部文档。')
      },
      {
        title: L10n.t('对照阅读'),
        body: L10n.t('「更多」→「对照阅读」选一篇文档并排对照，可切成左右分屏；退出浮钮可拖动吸附到屏幕侧缘。')
      },
      {
        title: L10n.t('朗读全文（听读）'),
        body: L10n.t('「更多 → 朗读全文」用系统语音把正文一段一段读出来：代码块、表格与图表会跳过，')
          + L10n.t('**读到哪一段，屏幕就自动跟到那一段**。朗读期间屏幕中部靠边出现一颗浮钮')
          + L10n.t('（点一下暂停 / 再点继续 / 长按结束），与自动滚屏共用这一颗钮、二者互斥。')
          + L10n.t('离开阅读页会自动停止并释放语音引擎。')
      },
      {
        title: L10n.t('图片管理'),
        body: L10n.t('「更多 → 图片管理」把这篇引用过的图列成清单（缩略图 + 本地/网络 + 是否存在）：')
          + L10n.t('点缩略图放大看、另存（交给系统分享面板）、替换（从相册选一张替换掉这一处引用）、')
          + L10n.t('删除引用（只从正文移除，图片文件保留，可到数据管理里清理）。')
      },
      {
        title: L10n.t('被引用（反向链接）'),
        body: L10n.t('「更多」→「被引用」列出所有用 `[[本篇名]]` 引用了当前文档的文档，点一条直接跳过去。')
      },
      {
        title: L10n.t('任务勾选与表格编辑'),
        body: L10n.t('任务列表的勾选框在阅读页可直接点选（写回原文）；点正文表格会打开**网格编辑器**，')
          + L10n.t('可改单元格、增删行列、调对齐，保存按原位置写回。')
      },
      {
        title: L10n.t('图表 / 公式 / 代码块'),
        body: L10n.t('图表（mermaid、mindmap、echarts、graphviz、flowchart、abc 乐谱）、公式、代码块都能放大查看；')
          + L10n.t('代码块有行号、超 10 行自动折叠、按语言显示彩色徽标；语言写 `html` 时按网页效果渲染，可一键切回源码。')
      },
      {
        title: L10n.t('只读 / 可写'),
        body: L10n.t('在「更多」或书架格子里切换。只读时编辑入口上锁、勾选与表格编辑不写盘，批注与导出照常。')
      },
      {
        title: L10n.t('阅读设置详解'),
        body: L10n.t('底栏「阅读设置」里另有几组常用项：**排版氛围**（紧凑 / 标准 / 舒展一键切行距与段距）、')
          + L10n.t('正文字号 / 行高 / 版心宽度 / 段落间距 / 首行缩进、**字体**（可导入 .ttf / .otf，长按已导入字体可删除）、')
          + L10n.t('**批注**（荧光笔浓淡、波浪线粗细）、**亮度**（跟随系统或用固定亮度接管）、屏幕常亮、')
          + L10n.t('文档信息卡开关、标签栏位置（顶部 / 底部）。')
      },
      {
        title: L10n.t('目录侧栏的折叠'),
        body: L10n.t('目录面板顶部有「展开全部 / 折叠到二级」：长文档先把层级收起来再找，比一路滚下去快。')
      },
      {
        title: L10n.t('长文档的打开与渲染'),
        body: L10n.t('大文档分批渲染（首批 80 块，滚到底自动续载），所以打开长文不会长时间卡住；')
          + L10n.t('代码块超过 10 行会自动折叠，需要细看时点放大。')
      },
      {
        title: L10n.t('网页开放（点链接直接开网页）'),
        body: L10n.t('阅读页「更多」面板里有「网页开放」开关（会记住）。**开启后**点正文里的 http(s) 链接，')
          + L10n.t('会在**半模态面板**里直接打开网页（近乎满屏，标题栏带「刷新 / 复制链接」）；')
          + L10n.t('**关闭**时维持原行为——点链接只复制地址。')
      },
      {
        title: L10n.t('侧边栏：抽屉还是停靠'),
        body: L10n.t('手机与**竖屏**（含平板竖屏）下是侧滑抽屉：右滑出目录、左滑出注释，')
          + L10n.t('**抽屉打开时背景整屏柔化**（与书架搜索展开同一效果）。')
          + L10n.t('**大屏横屏**才启用左右停靠三栏，是否默认展开在「更多」面板里设。')
      }
    ]
  },
  {
    name: L10n.t('编辑与实时预览'),
    icon: $r('sys.symbol.square_and_pencil'),
    items: [
      {
        title: L10n.t('实时预览编辑（推荐）'),
        body: L10n.t('顶栏 ✎ 进入：正文以**渲染后的样子**呈现，点哪一段就改哪一段。')
          + L10n.t('每段末尾有「✎ 编辑」图标（点它或点段落本身都行），改的时候下方会同步显示**这一段的预览效果**，')
          + L10n.t('点「完成」回到渲染样子。表格点开是网格编辑器，代码块带着实时预览。')
      },
      {
        title: L10n.t('新建段落'),
        body: L10n.t('文末那片虚线空白「点这里新建段落」：点一下立刻出现一个空输入框并弹出键盘，写完点「完成」落进正文。')
      },
      {
        title: L10n.t('片段工具条'),
        body: L10n.t('键盘上方一排：手写、插图片、标题、粗体、斜体、删除线、高亮、行内代码、代码块、引用、提示块、')
          + L10n.t('列表、任务、表格、链接、图片、分割线、脚注。**在实时预览里插入即呈现渲染效果**，键盘不会收起。')
      },
      {
        title: L10n.t('一键插入目录'),
        body: L10n.t('编辑页底栏「目录」：扫描标题生成带锚点的目录插到文首；再点一次是刷新（不会叠第二份），')
          + L10n.t('围栏代码块里的 `#` 不会被误认成标题。')
      },
      {
        title: L10n.t('分屏预览'),
        body: L10n.t('底栏「分屏」在纯编辑 / 左右分屏 / 上下分屏之间循环，改动实时刷新预览。')
      },
      {
        title: L10n.t('查找 / 替换 / 跳转行'),
        body: L10n.t('顶栏放大镜：支持上一处 / 下一处、替换、全部替换，还能按行号跳转。')
      },
      {
        title: L10n.t('版本历史'),
        body: L10n.t('顶栏时钟按钮：自动快照 + 手动快照，可对比（红绿标注差异）与一键恢复。自动保存间隔可调。')
      },
      {
        title: L10n.t('草稿保护'),
        body: L10n.t('未保存就退出时会问「保存 / 存草稿 / 直接离开」；选存草稿后下次打开该文档会自动恢复。')
      },
      {
        title: L10n.t('语法速查与专注写作'),
        body: L10n.t('底栏「语法」里每一行都**真实渲染**成效果，点一行插到光标处；')
          + L10n.t('底栏「专注」隐藏顶栏与工具条，只留正文与退出钮。')
      },
      {
        title: L10n.t('双链补全（[[ 文档名 ]]）'),
        body: L10n.t('在编辑页输入 `[[` 就会从底部浮出候选列表（最多 8 条，可继续打字筛选），点一条即插入 `[[文档名]]`；')
          + L10n.t('名称打错会变成指向"不存在文档"的悬空链接（知识图谱里会落进「待补文档」），')
          + L10n.t('所以尽量用候选插入。')
      },
      {
        title: L10n.t('外接键盘快捷键'),
        body: L10n.t('接键盘时可用：`Ctrl+S` 保存、`Ctrl+B` 粗体、`Ctrl+I` 斜体、`Ctrl+F` 查找、')
          + L10n.t('`Ctrl+↑ / Ctrl+↓` 调正文字号。加粗 / 斜体作用于当前选中的文字，没选就插入一对空标记。')
      },
      {
        title: L10n.t('大纲重排（整节换序）'),
        body: L10n.t('编辑页底栏「大纲」打开面板：**长按拖动**某一节即可换序（连同它的子标题一起搬），')
          + L10n.t('也可以用行尾的 ↑↓ 微调。整节 = 该标题到下一个同级/更高级标题之前的全部内容，')
          + L10n.t('所以挪一个二级标题不会把它下面的三级标题落下。')
      },
      {
        title: L10n.t('版本历史怎么用'),
        body: L10n.t('顶栏时钟按钮：可设自动保存快照的**间隔**（1 / 5 / 10 / 30 分钟），也能手动记一份；')
          + L10n.t('快照之间可「对比」（红绿标注差异）并一键「恢复」。内容没变化时不会重复记。')
      },
      {
        title: L10n.t('一键插入目录'),
        body: L10n.t('底栏「目录」芯片：按标题层级生成带锚点的目录插到文首，再点一次是刷新。')
      },
      {
        title: L10n.t('写完一篇的收尾'),
        body: L10n.t('底栏会显示字数与保存状态；点「未保存」芯片或顶栏对勾即保存。')
          + L10n.t('直接返回时会问「保存 / 存草稿 / 直接离开」，存草稿下次打开自动恢复。')
      }
    ]
  },
  {
    name: L10n.t('知识与统计'),
    icon: $r('sys.symbol.square_grid_2x2'),
    items: [
      {
        title: L10n.t('复习卡片'),
        body: L10n.t('由批注自动派生（高亮当正面、文字批注当背面），按简化 SM-2 间隔重复排期；')
          + L10n.t('书架「复习卡片」入口只出今天该复习的。')
      },
      {
        title: L10n.t('全部待办'),
        body: L10n.t('聚合所有文档里的 `- [ ]`，可按文档分组查看、直接勾选，点条目跳到原文对应行。')
      },
      {
        title: L10n.t('阅读轨迹'),
        body: L10n.t('书架顶部一条最近打开提示（可在「外观设置」里关掉），面板里是带进度徽章的时间轴。')
      },
      {
        title: L10n.t('写作日志与阅读时长'),
        body: L10n.t('「设置 → 写作日志」：一年热力图、总字数 / 本月 / 今日、最近动态，以及阅读统计（今日、近 7 天、累计、')
          + L10n.t('读得最多的几篇）。只统计真实停留时间，退后台不计。')
      },
      {
        title: L10n.t('回头看看'),
        body: L10n.t('书架**左滑**进「写作日志」页，顶部就是这张回顾卡：**随机**挑一篇旧文，')
          + L10n.t('或打开「那年今天」动过的文档。卡片常驻展示。')
      },
      {
        title: L10n.t('知识图谱与文档体检'),
        body: L10n.t('都是"整理期"用的工具：图谱把 `[[链接]]` 关系画成一张图（另存为一篇新文档），')
          + L10n.t('体检则逐条列出结构隐患并给出行号。入口都在文档封面的 ⋯ 菜单里。')
      }
    ]
  },
  {
    name: L10n.t('导出与备份'),
    icon: $r('sys.symbol.doc_text_badge_arrow_up'),
    items: [
      {
        title: L10n.t('导出格式'),
        body: L10n.t('阅读页「更多」→「导出与分享」：HTML（可带样式与内嵌图片）、Markdown 原文、图片、')
          + L10n.t('EPUB 电子书、打印、复制全文；「文献引用」一次复制 GB/T 7714 / APA / BibTeX 三种格式。')
      },
      {
        title: L10n.t('分享到澄笺（接收分享）'),
        body: L10n.t('在别的应用里选「分享」，分享面板上会出现澄笺：')
          + L10n.t('**文本 / 链接**会直接存成一篇新文档（标题取分享标题，取不到就用首行），')
          + L10n.t('**md / txt 文件**会导入成一篇文章。落地后书架会自动刷新并打开它。')
          + L10n.t('（应用没在运行时也能收 —— 分享会直接把澄笺拉起来。）')
      },
      {
        title: L10n.t('一键备份与恢复'),
        body: L10n.t('「设置 → 数据管理」里 zip 备份（文档、书架、批注、手写），走系统选择器，不需要存储权限；')
          + L10n.t('换机时用同一入口导入恢复。')
      },
      {
        title: L10n.t('WebDAV 备份'),
        body: L10n.t('支持坚果云、群晖等标准 WebDAV 服务，填好地址与账号即可一键上传备份。')
      },
      {
        title: L10n.t('图片管理'),
        body: L10n.t('「数据管理 → 图片管理」把本机所有图片列出来（本地插图 / 手写笔记、以及抓取过的网络图），')
          + L10n.t('点击可查看；放进文档的图片都收在文档目录的 images 下，删文档不会连带删图片，可在这里清理。')
      },
      {
        title: L10n.t('内置文档的移除与恢复'),
        body: L10n.t('内置文档不能删除，只能从书架移除显示：「数据管理 → 书架数据 → 从书架中移除」。')
          + L10n.t('移除后在同页「已移除的内置教程」里一键恢复回书架，封面与阅读进度都保留；')
          + L10n.t('正文始终以应用包内版本为准（更新应用后会跟着更新）。')
      },
      {
        title: L10n.t('缓存清理'),
        body: L10n.t('数据管理里可清理图表渲染缓存等临时文件；**不会**动你的文档与批注。')
      },
      {
        title: L10n.t('回收站'),
        body: L10n.t('删掉的文档、图片、批注都会先进「数据管理 → 回收站」：可单条**恢复**或**彻底删除**，也能一键清空（清空前要确认）。')
          + L10n.t('自动清理可选 2 / 5 / 7 / 30 天，过期才真正删除；列表上会写还有几天。')
          + L10n.t('外部导入的文档只从书架移除，**不会删你原来的文件**。')
      },
      {
        title: L10n.t('备份里包含什么'),
        body: L10n.t('zip 备份是全量的：文档与图片、书架索引（文件夹与排序）、批注与学习卡、手写笔迹、AI 会话与配置、草稿、版本快照、字体、壁纸与阅读背景、阅读与写作日志、阅读标签页、复习数据、全部阅读与外观设置、网盘账号配置、桌面卡片快照，以及图表与导出缓存。包内按类别分文件夹并附 manifest.json 清单，导入时按清单把每类写回它本来的位置。')
      }
    ]
  },
  {
    name: L10n.t('外观与个性化'),
    icon: $r('sys.symbol.paintbrush'),
    items: [
      {
        title: L10n.t('主题与深浅'),
        body: L10n.t('「阅读调整」里五档主题：跟随系统 / 浅色 / 深色 / 羊皮纸 / 护眼绿；')
          + L10n.t('深浅由主题决定，羊皮纸与护眼绿也有对应的深色款（改了深色不会把浅色一起改掉）。')
      },
      {
        title: L10n.t('主题色与沾色'),
        body: L10n.t('「外观设置」里可选主题色，并决定它染到哪些地方：页面底色沾一点、卡片沾色、')
          + L10n.t('按压流光用主题色、背景跟随主题色；不选主题色时只有澄笺自带的五色可用。')
      },
      {
        title: L10n.t('阅读背景'),
        body: L10n.t('优先用「阅读背景图」，其次是阅读背景样式（程序化壁纸，出厂为竹影），再是外观壁纸、函数壁纸，')
          + L10n.t('最后是自定义纯色。侧边栏底色会自动跟同一套优先级。')
      },
      {
        title: L10n.t('应用壁纸与函数壁纸'),
        body: L10n.t('「外观设置 → 应用壁纸」可选用内置壁纸、自己的图片，或**自定义函数壁纸**')
          + L10n.t('（用数学函数生成图案，光斑只在角落缓慢活动）；壁纸可调模糊与文字可读性遮罩浓度。')
      },
      {
        title: L10n.t('卡片与流光'),
        body: L10n.t('卡片质感、卡片沾色、按压流光与触感、粒子消散等开关都在「外观设置」里；')
          + L10n.t('整机手感偏素时可以只开卡片流光，关掉粒子。')
      },
      {
        title: L10n.t('灰体文本与恢复默认'),
        body: L10n.t('「灰体文本显示增强」把说明文字、时间、占位提示统一改成选定颜色（深浅可分别设）；')
          + L10n.t('外观与阅读设置各自都有「恢复默认」，调乱了可以一键回退。')
      }
    ]
  },
  {
    name: L10n.t('大屏与设备能力'),
    icon: $r('sys.symbol.rectangle_split_2x1'),
    items: [
      {
        title: L10n.t('平板 / 横屏分栏'),
        body: L10n.t('宽屏横屏时设置页与阅读页都会分栏：目录与批注可停靠左右两侧，宽度拖好后自动记住。')
      },
      {
        title: L10n.t('自由窗口'),
        body: L10n.t('支持全屏 / 分屏 / 悬浮三种窗口形态，最小尺寸 320 × 240；窗口变窄时自动回到单栏排版。')
      },
      {
        title: L10n.t('智感握姿'),
        body: L10n.t('识别你正用左手还是右手：底部胶囊、悬浮按钮会跟到该手一侧。')
          + L10n.t('首次进书架会申请「智感握姿」权限，拒绝或设备不支持时静默降级（居中显示）。')
      },
      {
        title: L10n.t('多设备流转（应用接续）'),
        body: L10n.t('两台登录同一华为账号的鸿蒙设备间，可把当前阅读现场迁到另一台继续；')
          + L10n.t('接续过去的临时文档 5 分钟未编辑会自动清理。')
      },
      {
        title: L10n.t('沉浸光感'),
        body: L10n.t('顶栏、底栏、芯片、面板都用系统的沉浸光感材质（磨砂玻璃，采样背后的窗口内容）；')
          + L10n.t('设备不支持该材质时自动降级为毛玻璃，观感一致、功能不变。')
      },
      {
        title: L10n.t('协同窗口 / 横屏'),
        body: L10n.t('应用声明支持**全屏 / 分屏 / 悬浮窗**三种窗口模式，多窗布局为**横向**，')
          + L10n.t('因此协同窗口、自由窗都能横着铺满；在自由窗状态下标题栏会出现「最大化」。')
          + L10n.t('窗口配置里 `isMaximize` 打开时，协同 / 自由窗**启动即最大化**。')
          + L10n.t('屏幕方向：平板 / 2in1 随系统横竖切换；**手机默认锁竖屏**，')
          + L10n.t('要在「外观设置 → 支持横屏模式」打开后才随系统转（这一行只在手机上出现）。')
      },
      {
        title: L10n.t('AI 助手在大屏横屏下'),
        body: L10n.t('大屏横屏进 AI 助手：左侧历史对话栏**固定展开**（顶栏的「新建 / 历史」与抽屉的关闭按钮自动隐藏），')
          + L10n.t('右侧是对话区；气泡版心居中限宽，历史栏不会压住正文。')
      }
    ]
  },
  {
    name: L10n.t('AI 助手'),
    icon: $r('sys.symbol.paperplane'),
    items: [
      {
        title: L10n.t('配置与模型'),
        body: L10n.t('在「设置 → 助手设置」里填 **API 地址 / Key / 模型**（可配多份，随时切换），并可按需设「思考强度」。')
          + L10n.t('「测试连接」会真的发一次极小的请求验证；保存后对话页**立即生效**（不用退出重进）。')
          + L10n.t('页底的「词元消耗」按今天 / 近一周 / 近一月 / 历年 / 按模型统计。')
      },
      {
        title: L10n.t('对话与历史'),
        body: L10n.t('顶栏「＋」开新话题，「时钟」打开历史（手机右滑侧栏 / 大屏横屏左侧常驻）。')
          + L10n.t('**正在生成时也可以切历史、开新话题**：旧话题会**继续在后台跑**，')
          + L10n.t('左侧历史里那条会带一个转圈图标；跑完后书架底栏的 **AI 入口会出现红色角标**，进去即清零。')
          + L10n.t('回到正在生成的那条会话，会看到「正在思考…」，跑完自动把结果拉回来。')
      },
      {
        title: L10n.t('附件（图片 / 文件 / 文档）'),
        body: L10n.t('点输入框左侧「＋」展开：图片（可多选）、文件（可多选）、拍照、以及引用**应用内文档**。')
          + L10n.t('**不限数量、也不限大小**：文件超过约 128KB 时不再整份塞进一次请求，')
          + L10n.t('而是**按块从磁盘读取、自动分批上传**（大文件会看到「第 k/N 批」的连续消息，')
          + L10n.t('回复到一批自动发下一批，中途可随时点停止），所以几百 MB 的文本也不会撑爆内存或请求体。')
          + L10n.t('附件很大时请求会久一些，应用会在开始时提醒一句。')
      },
      {
        title: L10n.t('代码块与图表放大'),
        body: L10n.t('AI 回复里的**代码块**（带行号）与**图表 / 公式**都带放大箭头：点开是**与阅读页同一套全屏界面**——')
          + L10n.t('左上标题、缩小 / 放大（0.5~3 倍）、重新自适应、关闭，内容可横向纵向滚动平移。')
      },
      {
        title: L10n.t('让 AI 直接生成文档'),
        body: L10n.t('直接说「把这个整理成一篇 md 存到书架」：AI 会按约定格式输出整篇正文，应用解析后')
          + L10n.t('**真正落盘到书架**（同名自动编号），气泡里同时出现文档卡，点一下就进阅读页。')
      },
      {
        title: L10n.t('基础模式下不可用'),
        body: L10n.t('「基础模式（纯离线）」下一切联网能力关停，AI 助手入口点了会直接提示不可用；')
          + L10n.t('切回「全量模式」即可恢复。')
      }
    ]
  },
  {
    name: L10n.t('关于与更新'),
    icon: $r('sys.symbol.arrow_counterclockwise'),
    items: [
      {
        title: L10n.t('检查更新'),
        body: L10n.t('「探索中心 → 检查更新」一次查两个渠道：测试版（HAP 资源站发布页）与正式版（华为应用市场），')
          + L10n.t('结果两条一起显示。测试版有新版时只提示版本号（确认按钮），不再提供站内下载；')
          + L10n.t('正式版有新版则直接弹市场官方更新框。市场正式版通常比资源站晚几个版本。')
      },
      {
        title: L10n.t('使用模式（全量 / 基础离线）'),
        body: L10n.t('「探索中心」底部可重新选择：全量模式功能齐全；基础离线模式完全离线、')
          + L10n.t('不发起任何网络请求（图表等依赖内置库的功能会相应精简）。')
      },
      {
        title: L10n.t('隐私政策与用户协议'),
        body: L10n.t('「探索中心」内的两份法务文本可在应用内直接阅读，也可在平板分栏里并排看。')
      },
      {
        title: L10n.t('更新日志'),
        body: L10n.t('「探索中心 → 更新日志」按版本列出每一次的新增、优化、修复与移除，四类各用一种颜色区分；')
          + L10n.t('应用升级后首次启动也会弹出本次更新内容。')
      },
      {
        title: L10n.t('参考与致谢'),
        body: L10n.t('列明本项目在渲染形态、动效与交互上参考过的开源项目及其作者。')
      }
    ]
  }
];

/** 常见问题 */
const FAQ: HelpItem[] = [
  {
    title: L10n.t('自动滚屏的那颗悬浮按钮怎么关？'),
    body: L10n.t('长按它。只点一下是暂停（再点继续）；点正文任意处也是暂停；离开阅读页会自动收起。')
  },
  {
    title: L10n.t('点了段落却没法改？'),
    body: L10n.t('先在编辑页顶栏点 ✎ 进入实时预览；如果已经在实时预览里，点段落末尾的「✎ 编辑」图标（图标与虚线同属一段）。')
  },
  {
    title: L10n.t('表格为什么改不了？'),
    body: L10n.t('嵌套在引用里的表格暂不支持写回（行号不可靠），会给出提示；普通表格点开即可网格编辑。')
  },
  {
    title: L10n.t('勾选框点了没反应？'),
    body: L10n.t('文档处于**只读**（含所有内置教程）；内置文档即使切成可写也不写盘。')
  },
  {
    title: L10n.t('图片显示不出来？'),
    body: L10n.t('相对路径的图片要放在文档目录的 `images/` 下；内置文档里的图片需要先从应用包解出来（打开一次即可）；')
      + L10n.t('网络图需要联网。')
  },
  {
    title: L10n.t('打开是乱码怎么办？'),
    body: L10n.t('在书架格子「更多」或阅读设置里手动选编码（UTF-8 / GBK / GB18030 / Big5 / Latin-1），选对后会自动记住。')
  },
  {
    title: L10n.t('图表 / 公式不显示？'),
    body: L10n.t('图表依赖内置渲染库，首次打开该文档时需要渲染一次（应用内渲染，不联网）。基础离线模式下可用库较少。')
  },
  {
    title: L10n.t('数据会丢吗？会不会上传？'),
    body: L10n.t('所有文档、批注、设置都只在本机沙箱内，不上传。建议定期用「数据管理」里的 zip 或 WebDAV 备份。')
  },
  {
    title: L10n.t('智感握姿完全没反应？'),
    body: L10n.t('需要在首次启动时同意「智感握姿」权限；设备不支持该能力时一律居中显示，不影响其它功能。')
  },
  {
    title: L10n.t('目录 / 批注侧栏每次都要手动滑出来？'),
    body: L10n.t('在「阅读调整」里把「目录侧边栏默认展开」「批注侧边栏默认展开」打开，进阅读页就自动停靠。')
  },
  {
    title: L10n.t('怎么让书架上不要那几张卡？'),
    body: L10n.t('「外观设置」里可关「继续阅读卡片」；「回头看看」卡片已搬到书架左滑的「写作日志」页顶部，')
      + L10n.t('不再出现在书架上。')
  },
  {
    title: L10n.t('内置文档能删吗？'),
    body: L10n.t('不能删除，只能**从书架中移除显示**：数据管理 → 书架数据 →「从书架中移除」。')
      + L10n.t('移除后书架上看不到它们，正文仍在应用内，随时可在同页「已移除的内置教程」里恢复回书架。')
      + L10n.t('内置文档的正文以应用包内版本为准（更新应用会跟着更新）。')
  },
  {
    title: L10n.t('改错了怎么退回上一版？'),
    body: L10n.t('编辑页顶栏时钟按钮 → 版本历史，挑一个快照「恢复」即可；也能用「对比」先看看差异在哪里。')
      + L10n.t('平时把自动保存间隔设成 5 分钟就够了。')
  },
  {
    title: L10n.t('批注散落在各篇里，怎么集中看？'),
    body: L10n.t('单个文档：右滑出注释侧栏，或用封面 ⋯ 里的「批注汇总」。')
      + L10n.t('全部文档：封面 ⋯ →「批注汇总导出为文档」，会生成一篇汇总文档放进书架。')
  },
  {
    title: L10n.t('今天该干什么？'),
    body: L10n.t('书架封面的 ⋯ 菜单里有「今日笺」：待办、今日到期的复习卡片、今日改过 / 读过的文档、')
      + L10n.t('以及读到一半的书，一页看完。')
  },
  {
    title: L10n.t('怎么换字体？'),
    body: L10n.t('「阅读调整 → 字体」直接列出**系统里已安装的全部字体**（含每款字体的各个样式），点一款即生效；')
      + L10n.t('也可以导入 .ttf / .otf，长按已导入的字体可删除，正在用它的文档会回退为默认字体。')
      + L10n.t('中文与英数可以**分开选**（英数默认跟随中文）：分别调出两款字体就是英文数字用一款、汉字用另一款。')
      + L10n.t('字体列表点开时需要读一次系统字体表，会弹一句「正在加载字体…」，读完才展开；')
      + L10n.t('两分钟内再点开直接展开，不会重复加载。标题字号会按同一比例跟着缩放。')
  },
  {
    title: L10n.t('图片占空间，能清理吗？'),
    body: L10n.t('「数据管理 → 图片管理」能看到本地图片与抓取过的网络图，点击可查看。')
      + L10n.t('删文档不会连带删图片（图片被多篇共用），要清就到这里来。')
  },
  {
    title: L10n.t('长文档打开会卡吗？'),
    body: L10n.t('不会：正文分批渲染（首批 80 块，滚到底自动续载）。代码块超过 10 行会自动折叠，')
      + L10n.t('需要细看时点卡片上的放大。')
  },
  {
    title: L10n.t('想把文档发给别人，怎么弄？'),
    body: L10n.t('「更多 → 导出与分享」：HTML（可内嵌图片，对方有浏览器就能看）、Markdown 原文、')
      + L10n.t('EPUB 电子书，或直接「分享」交给系统分享面板（微信、邮件等）。')
  },
  {
    title: L10n.t('怎么把别处的文章存进澄笺？'),
    body: L10n.t('在来源应用里点「分享」并选澄笺：文本会新建一篇文档，md / txt 文件会导入。')
      + L10n.t('也可以用系统文件管理器「打开方式」选澄笺，或在书架里拖文件进窗口。')
  },
  {
    title: L10n.t('封面上的名字和文件名不一样？'),
    body: L10n.t('正文文首 `---` 区块里写了 `title:`，封面就显示这个标题（文件名与标识仍是原名，')
      + L10n.t('所以链接 `[[文件名]]` 不受影响）。封面色与日期同理：`cover:` / `date:`。')
  },
  {
    title: L10n.t('写 [[ 会弹出候选，怎么关掉？'),
    body: L10n.t('候选项只在"未闭合的 `[[`"后面出现：把 `]]` 补上、换行、或把光标移开就会自动消失，')
      + L10n.t('不需要手动关。点候选项会插入 `[[文档名]]`。')
  },
  {
    title: L10n.t('朗读没有声音 / 提示引擎不可用？'),
    body: L10n.t('朗读用的是**系统语音（Core Speech Kit）**，不依赖本应用的下载内容：')
      + L10n.t('若是"基础离线模式"，只能用设备上的离线音色，有些设备可能没装中文离线语音；')
      + L10n.t('在线音色需要联网。提示引擎不可用时，可以切回全量模式再试。')
  },
  {
    title: L10n.t('挪动一节会不会把内容弄乱？'),
    body: L10n.t('不会：移动只改**源文本的行区间**（把这一节的行整段搬走），')
      + L10n.t('不重新排版、不重新生成 Markdown。挪完正文与光标位置都会跟着刷新，')
      + L10n.t('不满意可以到「版本历史」里回到上一版。')
  },
  {
    title: L10n.t('接键盘能用吗？有哪些快捷键？'),
    body: L10n.t('能。编辑页支持 `Ctrl+S` 保存、`Ctrl+B` 粗体、`Ctrl+I` 斜体、`Ctrl+F` 查找、')
      + L10n.t('`Ctrl+↑/↓` 调字号。其余操作仍走界面按钮。')
  },
  {
    title: L10n.t('备份文件能跨设备用吗？'),
    body: L10n.t('能。zip 备份走系统文件选择器，放到哪台设备都能用同一入口「导入备份」恢复；')
      + L10n.t('WebDAV 备份则适合定期自动留一份在网盘。')
  }
];

@Component
export struct SettingsHelp {
  stack: NavPathStack | null = null;
  life: NavLifecycle = new NavLifecycle();

  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  /** 关键词筛选（空串 = 全部） */
  @State query: string = '';
  /** 语言切换计数：变更时整页重建（key 拼接），文案随词典刷新 */
  @StorageProp('languageTick') languageTick: number = 0;
  /** **界面字体**（外观设置 → 界面字体）：本页界面文字都从这里取 */
  @StorageProp('appFontFamily') uiFontKey: string = '';
  /** 界面字号缩放系数 / 界面字重相对加粗量（外观设置） */
  @StorageProp('appFontScale') uiFontScale: number = 1;
  @StorageProp('appFontWeightDelta') uiFontWeightDelta: number = 0;

  private palette(): ReaderPalette {
    return paletteFor(this.themeMode, this.systemDark);
  }

  /** 关键词是否命中某条（标题或正文包含即算命中） */
  private hit(it: HelpItem, q: string): boolean {
    return it.title.indexOf(q) >= 0 || it.body.indexOf(q) >= 0;
  }

  /**
   * 按关键词过滤后的板块列表（返回**真数组**：ForEach 的第一参数必须是真数组）。
   * 整块都不命中时该板块不显示。
   */
  private visibleSections(): HelpSection[] {
    const q: string = this.query.trim();
    if (q.length === 0) {
      return SECTIONS;
    }
    const out: HelpSection[] = [];
    for (let k = 0; k < SECTIONS.length; k++) {
      const sec: HelpSection = SECTIONS[k];
      const keep: HelpItem[] = [];
      for (let i = 0; i < sec.items.length; i++) {
        if (this.hit(sec.items[i], q)) {
          keep.push(sec.items[i]);
        }
      }
      // 板块名本身命中时，整块保留（用户搜"阅读"应该看到整个阅读板块）
      if (keep.length === 0 && sec.name.indexOf(q) >= 0) {
        out.push(sec);
      } else if (keep.length > 0) {
        out.push({ name: sec.name, icon: sec.icon, items: keep } as HelpSection);
      }
    }
    return out;
  }

  /** 筛选后的常见问题 */
  private visibleFaq(): HelpItem[] {
    const q: string = this.query.trim();
    if (q.length === 0) {
      return FAQ;
    }
    const out: HelpItem[] = [];
    for (let k = 0; k < FAQ.length; k++) {
      if (this.hit(FAQ[k], q)) {
        out.push(FAQ[k]);
      }
    }
    return out;
  }

  build() {
    SettingsShell({
      shellTitle: L10n.t('功能帮助'),
      shellSubtitle: L10n.t('全部功能 · 使用方法 · 常见问题'),
      stack: this.stack,
      life: this.life
    }) {
      Column({ space: HwSpace.lg }) {
        // ① 搜索：功能多了靠翻页找不现实
        ImmersiveCard({
          cardRadius: HwRadius.card,
          cardPadding: HwSpace.md,
          palette: this.palette()
        }) {
          Column({ space: HwSpace.xs }) {
            Row({ space: HwSpace.sm }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(15)
                .fontColor([this.palette().textTertiary])
              ImmersiveInput({
                palette: this.palette(),
                text: this.query,
                placeholder: L10n.t('搜功能或问题，例如「滚屏」「表格」「备份」'),
                onInput: (v: string) => {
                  this.query = v;
                }
              }).layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Text(this.query.trim().length === 0
              ? L10n.t('共 ') + SECTIONS.length + L10n.t(' 个板块 · ') + FAQ.length + L10n.t(' 条常见问题')
              : L10n.t('筛选结果：') + this.visibleSections().length + L10n.t(' 个板块 · ')
                + this.visibleFaq().length + L10n.t(' 条问题'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              // 计数行加一个轻微淡入（内容随输入变化，配合下方结果的过渡一起看）
              .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
              .width('100%')
              .animation(AppearanceFx.anim(200, Curve.FastOutSlowIn))
          }
          .width('100%')
        }

        // ② 先回答最容易卡住的三件事（只有没筛选时才占版面）
        if (this.query.trim().length === 0) {
          ImmersiveCard({
            cardRadius: HwRadius.card,
            cardPadding: HwSpace.lg,
            palette: this.palette()
          }) {
            Column({ space: HwSpace.md }) {
              Row({ space: 6 }) {
                SymbolGlyph($r('sys.symbol.lightbulb'))
                  .fontSize(18)
                  .fontColor([this.palette().accent])
                Text(L10n.t('先用三句话说明白'))
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(HwType.label + 3, this.uiFontScale))
                  .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
                  .fontColor(this.palette().textPrimary)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              ForEach(QUICK, (it: HelpItem) => {
                Column({ space: 4 }) {
                  Text(it.title)
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(HwType.label + 2, this.uiFontScale))
                    .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
                    .fontColor(this.palette().accent)
                    .width('100%')
                  Text(it.body)
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
                    .fontColor(this.palette().textSecondary)
                    .lineHeight(HwFont.sx((HwType.label + 1) * 1.75, this.uiFontScale))
                    .width('100%')
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding(HwSpace.sm)
                .borderRadius(HwRadius.inner)
                .backgroundColor(this.palette().quoteBg)
              }, (it: HelpItem) => 'q_' + it.title)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }

        // ③ 功能板块
        // 包一层壳：ImmersiveCard 是尾随闭包组件、后面不能链属性，过渡只能挂在壳上。
        // key 里带上命中条目数 —— 筛选结果变化时节点才重建，过渡（淡入 + 轻微上移）
        // 才会播出来；同一段文字继续输入时 key 不变，不会每敲一字都重排一遍。
        ForEach(this.visibleSections(), (sec: HelpSection) => {
          Column() {
          ImmersiveCard({
            cardRadius: HwRadius.card,
            cardPadding: HwSpace.lg,
            palette: this.palette()
          }) {
            Column({ space: HwSpace.md }) {
              Row({ space: HwSpace.xs }) {
                SymbolGlyph(sec.icon)
                  .fontSize(18)
                  .fontColor([this.palette().accent])
                Text(sec.name)
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(HwType.label + 3, this.uiFontScale))
                  .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
                  .fontColor(this.palette().textPrimary)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              // ⚠️ 条目全部内联画（itemGenerator 里不能调 @Builder）
              ForEach(sec.items, (it: HelpItem) => {
                Column({ space: 4 }) {
                  Text(it.title)
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(HwType.label + 2, this.uiFontScale))
                    .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
                    .fontColor(this.palette().textPrimary)
                    .width('100%')
                  Text(it.body)
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
                    .fontColor(this.palette().textSecondary)
                    .lineHeight(HwFont.sx((HwType.label + 1) * 1.75, this.uiFontScale))
                    .width('100%')
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .border({
                  width: { bottom: 1 },
                  color: this.palette().divider,
                  style: BorderStyle.Dashed
                })
                .padding({ bottom: HwSpace.md })
              }, (it: HelpItem) => 'i_' + sec.name + '_' + it.title)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          }
          .width('100%')
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 10 }))
            .animation(AppearanceFx.anim(220, Curve.FastOutSlowIn)))
        }, (sec: HelpSection) => 's_' + sec.name + '_' + sec.items.length)

        // ④ 常见问题
        if (this.visibleFaq().length > 0) {
          Column() {
          ImmersiveCard({
            cardRadius: HwRadius.card,
            cardPadding: HwSpace.lg,
            palette: this.palette()
          }) {
            Column({ space: HwSpace.md }) {
              Row({ space: 6 }) {
                SymbolGlyph($r('sys.symbol.info_circle'))
                  .fontSize(18)
                  .fontColor([this.palette().accent])
                Text(L10n.t('常见问题'))
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(HwType.label + 3, this.uiFontScale))
                  .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
                  .fontColor(this.palette().textPrimary)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              ForEach(this.visibleFaq(), (it: HelpItem) => {
                Column({ space: 4 }) {
                  Text('Q · ' + it.title)
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(HwType.label + 2, this.uiFontScale))
                    .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
                    .fontColor(this.palette().accent)
                    .width('100%')
                  Text('A · ' + it.body)
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
                    .fontColor(this.palette().textSecondary)
                    .lineHeight(HwFont.sx((HwType.label + 1) * 1.75, this.uiFontScale))
                    .width('100%')
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .border({
                  width: { bottom: 1 },
                  color: this.palette().divider,
                  style: BorderStyle.Dashed
                })
                .padding({ bottom: HwSpace.md })
              }, (it: HelpItem) => 'f_' + it.title)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          }
          .width('100%')
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 10 }))
            .animation(AppearanceFx.anim(220, Curve.FastOutSlowIn)))
        } else if (this.query.trim().length > 0) {
          // 一条都没命中：给个明确交代（否则用户只看到搜索框下面空着）
          Column() {
            Text(L10n.t('没有找到相关内容，换个词试试（例如「滚屏」「表格」「备份」「编码」）'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
              .textAlign(TextAlign.Center)
              .width('100%')
              .padding(HwSpace.lg)
          }
          .width('100%')
          .transition(TransitionEffect.OPACITY.animation(AppearanceFx.anim(200, Curve.FastOutSlowIn)))
        }

        Text(L10n.t('没找到想要的？可在「参考与致谢」里查看项目主页，或到更新日志里看看每个版本新增了什么。'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
          .width('100%')
      }
      .width('100%')
      // ⚠️ 不加左右 padding（SettingsShell 内容区已有一层），只留底部避让
      .padding({ bottom: HwSpace.xxl })
    }
  }
}
