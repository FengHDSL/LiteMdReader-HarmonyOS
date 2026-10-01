# 澄笺 · LiteMdReader

> **「澄」是澄澈透光，「笺」是文人读写的纸笺。**

澄笺是一款 **HarmonyOS 原生**的 Markdown 阅读与写作应用：沉浸光感材质、卡片化排版、
图表与公式离线渲染、荧光笔批注、多标签阅读——**数据全部留在本机，不上传、不收集、不做账号**。

**完全开源**：产品用到的每一行源码、每一个渲染模板、每一份构建配置都在这个仓库里
（唯一的例外是签名证书与密码，见文末）。采用 [MIT License](LICENSE)。

| | |
| --- | --- |
| 当前版本 | **v1.0.2** |
| 平台 | HarmonyOS（ArkTS / ArkUI，Stage 模型） |
| 设备 | 手机 · 平板 · 2in1 |
| 包名 | `com.litemdreader.lzb` |
| 下载 | [Releases](https://github.com/FengHDSL/LiteMdReader-HarmonyOS/releases)（HAP 安装包） |
| 更新日志 | [CHANGELOG.md](CHANGELOG.md) · 应用内「探索中心 → 更新日志」 |
| 许可证 | [MIT](LICENSE) |

---

## 目录

- [功能](#功能)
  - [书架](#书架) · [阅读](#阅读) · [编辑](#编辑) · [外观与体验](#外观与体验) · [数据与设置](#数据与设置)
- [功能是怎么实现的](#功能是怎么实现的)
  - [整体架构](#整体架构) · [Markdown 渲染链路](#markdown-渲染链路) · [图表与公式：完全离线的渲染子系统](#图表与公式完全离线的渲染子系统)
  - [沉浸光感材质](#沉浸光感材质) · [书架与拖拽归组](#书架与拖拽归组) · [阅读器](#阅读器) · [批注坐标系](#批注坐标系)
  - [读写与只读](#读写与只读) · [导出与打印](#导出与打印) · [数据、备份与隐私](#数据备份与隐私) · [检查更新](#检查更新)
- [代码结构](#代码结构)
- [构建与运行](#构建与运行)
- [第三方开源组件](#第三方开源组件)
- [版权与致谢](#版权与致谢)

---

## 功能

### 书架

- **三列封面网格**：程序化书封绘制（`DocCover`，按文档名哈希取色），可自定义底色 /
  封面图 / 是否显示名称
- **长按拖动归组**：拖到另一张封面上 → 合并成文件夹；拖进文件夹格 → 收进该文件夹；
  文件夹 ↔ 文档还能互换位置（**内置教程同样可拖**）
- **文件夹原地展开**（iOS 6 主屏式）：面板排在网格流里从图标下方长出来，同伴留在原格、
  下方的书被推开；可改名、解散、移出文档
- 网格 / 树形双视图；**全库搜索**（命中上下文 + 直达正文位置）
- **底部悬浮胶囊内的快捷按钮**：点击新建文档、长按导入文档，
  与统计文字同在一颗沉浸光感胶囊里
- 「继续阅读」入口与文末统计（篇数 / 文件夹数 / 总字数）

### 阅读

- **多标签阅读**：序号化胶囊标签，长按可关闭其他 / 全部、重新加载；
  标签栏位置可在「更多」里切换——顶部（默认，带文件名的完整形态）或
  **底部悬浮栏**：展开时标签栏在悬浮胶囊上方完整显示，胶囊收起时缩进胶囊内、
  排在「阅读设置」按钮旁，收成一排可滑动的数字
- **侧滑抽屉**：左侧目录（大纲分级折叠、展开全部 / 折叠到二级）、右侧注释；
  宽屏两侧常驻，分隔条可拖宽
- **正文渲染**：标题、列表、任务列表、表格、引用、提示块（callout）、脚注、
  代码高亮、行内 / 块级数学公式
- **图表**：mermaid · echarts · graphviz · flowchart · markmap · abc 乐谱，**全部离线渲染**
- 图表与公式可全屏放大，支持旋转横屏、捏合缩放、± 倍率
- **荧光笔高亮 + 文字批注**：选中即弹胶囊，注释列表点击跳回原文
- 文档内查找、大纲跳转、阅读进度自动记忆与恢复
- 双指捏合即时调字号；亮度滑条与屏幕常亮；五档主题快捷切换
- **每篇文档可切「读写 / 只读」**：只读锁编辑入口、任务勾选不写盘
- 详情信息卡：字数 / 字符 / 标题 / 代码块 / 表格统计、文件大小与 MD5
- 复制全文、重新加载、导出与分享、打印

### 编辑

- 与阅读页**同源渲染器**的所见即所得预览；纯编辑 / 上下分屏 / 左右分屏
- Markdown 快捷工具条、语法速查表
- 图库导入图片：复制进沙箱 `docs/images/`，相对路径引用，阅读页真实加载
- 查找替换、跳转行
- **版本历史**：自动快照间隔可选 1 / 5 / 10 分钟（默认 5 分钟）+ 保存留档，
  支持差异对比与一键恢复
- 内置《Markdown 语法教程》与《澄笺示例 · 全功能演示》两篇（默认只读，可解锁为可写）

### 外观与体验

- **沉浸光感材质**：基于 API 26 `uiMaterial` 的材质承载层，深浅色切换整树重建
- 五档主题（跟随系统 / 浅色 / 深色 / 羊皮纸 / 护眼绿）× 五款澄笺主题色
  （澄光 / 宣纸 / 砚青 / 竹影 / 霞笺）+ 自定义色号；卡片沾色、主题色流光、
  **灰体文本深浅两套独立配置**（默认「自动」，深色 / 浅色各设一种颜色）
- 深浅两套壁纸、自定义字体导入（.ttf / .otf）、**函数表达式绘制壁纸**
- 动效：封面一镜到底、文件夹展开、粒子消散；智感握姿让底部工具条贴近持机侧
- 启动页；法务页（隐私政策 / 用户协议）跟随系统深浅色

### 数据与设置

- 设置分四类：阅读调整 / 外观设置 / 数据管理 / 探索中心（平板横屏自动分栏）
- **检查更新**：一键查询发布页上的最新版本，发现新版本可跳转下载
- 本地备份包（zip）导出 / 导入；**WebDAV 备份与恢复**（地址与账号只存本机）
- 缓存清理、内置教程移除与恢复、自建文档批量清理

> 桌面卡片（2×4 书架卡片）因存在已知缺陷，自 v1.0.1 起**暂时停用**，
> `module.json5` 里的 form 扩展已注销；相关代码原位保留，修复后恢复。

---

## 功能是怎么实现的

### 整体架构

- **单 `Navigation` + 多 `NavDestination`**：书架（`Index`）是 Navigation 的首页，
  阅读 / 编辑 / 设置 / 法务都压在同一条 `NavPathStack` 上。与 `router` 的关键差别是
  所有页面在**同一个 UI 实例**里——`geometryTransition`（一镜到底）与自定义转场才能跨页生效。
- **分层**：`pages/`（页面）→ `components/` + `material/`（可复用界面单元）→
  `service/`（数据与能力）→ `theme/`（设计令牌与调色板）→ `markdown/`（解析、渲染、高亮）。
- **设计令牌统一**：尺寸 / 圆角 / 间距 / 字阶全部取自 `theme/DesignTokens.ets`，配色一律走
  `paletteFor(mode, systemDark)`，所以五档主题与自定义主题色改一处即可全应用生效。
- **状态与持久化**：设置项走 `PersistentStorage` + `SettingsMirror`（沙箱内文件镜像，双保险）；
  文档元信息、书架顺序、阅读进度走 `DocStore`（`shelf.json`）。
- **系统深浅色的实时同步**：`AppStorage('systemDark')` 是唯一事实来源（各页面用
  `@StorageProp` 订阅，材质、调色板、系统栏图标都跟着它走）。
  它会被三处一起刷新：`UIAbility.onConfigurationUpdate`、`onForeground`，
  以及每个页面现身时的 `syncSystemDarkFromContext()`。
  ⚠️ **实机结论**：`@StorageProp` 上的 `@Watch` 在 AppStorage 被 Ability 侧改写时
  **不会触发**（值确实变了、回调一次都不来），所以刷新不能依赖它——
  页面在可见期用一个很轻的探测器（`startThemeWatchdog`，~700ms 问一次系统浓淡）
  主动比对，一旦变化就整树重建：书架 / 设置页把 `themeEpoch` 拼进根节点 `key`，
  阅读页递增拼在所有正文条目 key 上的 `renderEpoch`。切换后**当帧整页刷新**，
  不会再出现"要进别的页面才完全刷新"。
- **派生色（灰字 / 主题色 / 沾色）的即时刷新**：`paletteFor()` 是纯函数、内部读 `AppStorage`
  不登记依赖，所以页面把它当参数传或读一个 `appearanceTick` 计数；
  设置页改完会**递增这个计数**，全应用当帧重算，改完不用重进页面。

### Markdown 渲染链路

```
正文 → MdParser（块级 + 行内两级解析）→ MdBlock 数组 → MdView 渲染
                                     ↘ MdToHtml（导出 HTML）
```

- `MdParser.ets` 把正文解析成扁平化的块数组（标题 / 段落 / 列表 / 表格 / 引用 / 代码 /
  提示块 / 公式 / 图表 / 分隔线…），层级用 `indent`、引用嵌套用 `quoteDepth` 表达，
  **块 id 稳定**（用于批注定位与增量刷新）。
- 每块记录源文件行号，任务列表勾选就是按行号改写原文的 `[ ]` ↔ `[x]`——
  只改标记、不动行数，所以块 id 与批注坐标都不会漂移。
- 代码高亮由 `CodeHighlight.ets` 自己做（C 系 / Python / Shell / SQL / 数据 / CSS 几套关键字 +
  注释 / 字符串 / 数字状态机），不依赖外部高亮库。
- 导出 HTML 由 `MdToHtml.ets` 生成自包含页面；公式与图表在导出时**优先复用预渲染缓存图**。

### 图表与公式：完全离线的渲染子系统

这是本项目最花心思的一块，目标：**不联网、不牺牲还原度、翻到即见**。

- **模板 + 内联库**：`resources/rawfile/render/<mode>.html` 共 7 个模板
  （`katex` / `mermaid` / `echarts` / `graphviz` / `flowchart` / `markmap` / `abc`），
  每个模板把对应渲染库**整库内联**在 HTML 里（`mermaid.min.js`、`viz.js`、`echarts.min.js`、
  `katex.min.js` 等），因此完全不产生网络请求。
- **宿主协议**：`DiagramWeb` 组件用 ArkUI `Web` 加载模板，`onPageEnd` 后把源码以 JSON
  注入 `window.renderPayload({src,dark,fit,vw})`；页面渲染完通过
  `javaScriptProxy(arkHost.postHeight)` 把**真实高度**回传，组件高度自适应——
  所以正文里的图表卡片高度永远是准的，不会出现滚动空白或裁切。
- **后台预渲染 + 图片缓存**：`ChartRenderPool` 在打开文档时就把所有公式 / 图表任务排进
  **串行队列**（一次只跑一个 Web，避免 OOM），渲染完成后用
  `WebviewController.webPageSnapshot({id})` 抓**整页绘制结果**（不受可视区限制，
  比 `componentSnapshot` 对 Web 表面可靠），落盘到 `cacheDir/charts/`，
  键是 `md5(mode|深浅|源码)`（`ChartCache.ets`）。
  正文与导出**优先用缓存图**（`Image`），没有缓存才回落到实时 Web 渲染。
- **放大浮层**：图表 / 公式点开是全屏大画布，支持旋转横屏与缩放；`webZoom` 通过
  `body.style.zoom` 应用，markmap 用「撑满高度 + 关闭高度回传」避免 autoFit 与高度回传
  互相触发导致的缩小漂移。

### 沉浸光感材质

- 系统材质（API 26 `uiMaterial`）**不能直接铺在普通组件上**：材质绘制在节点背景之下，
  近实色底会把材质整块盖住。项目里所有卡片 / 按钮 / 芯片 / 面板统一走
  `material/` 下的承载层（`ImmersiveCardLayer` 等）：`matchParent` 尺寸 + 与外壳**同源圆角**
  + 透明底 + `enabled(false)` / `hitTestBehavior(None)`（只做视觉，不吃事件）+ 置尾的
  `attributeModifier`。
- 材质**惰性构造**，失败返回 null 并降级为毛玻璃，绝不构造空材质。
- 材质缓存键按「应用深浅 + 系统深浅」双维组织（材质底子只跟系统深浅走，应用深浅只决定压哪层色），
  深浅切换时靠承载层的 `key` 强制重建节点，避免材质不刷新。
- 全局开关在 `module.json5` 的 `metadata: ohos.arkui.UIMaterial.state = enable`。

### 书架与拖拽归组

- **统一排序**：`shelf.json` 里存一份 `order`（`F|<文件夹名>` / `D|<文档名>`），
  文件夹与松散文档**排在同一条流**里，所以「文件夹 ↔ 文档」也能互换位置；
  缺失项由 `normalizeOrder()` 兜底补齐（老索引平滑升级）。
- **系统拖拽**：只在**同一个节点**上注册 `onDragStart` / `onDrop`，并且**不加**
  `draggable(true)`——长按即起拖，不与点击、网格滚动手势打架。
- **文件夹原地展开**：面板作为一个跨满列数的 `GridItem` 插进网格流，高度 0 → 目标高度
  用弹簧曲线撑开，于是把下方的书推开；其余格子淡出 + 模糊退到后面。
- **一镜到底**：每张封面在 `onAreaChange` 时记录自己在窗口里的真实矩形
  （`docRects` + `HeroTransition`），打开阅读页时共享元素从那一格长出来，
  返回时再缩回去——页面本身不做位移，避免两套动画抢时序。

### 阅读器

- `Reader.ets` 是一个 `List` + 稳定的块 key；字号 / 行高 / 主题 / 批注变化时递增
  `renderEpoch` 并拼进 `ForEach` 的 key，强制重建正文节点——这是让 `@Prop` 真正同步的
  必要手段（键不变时 `@Prop` 不会更新）。
- 顶 / 底栏随滚动收起：`onDidScroll` 累计同方向位移超过阈值才收起，向上滚或回到顶部展开。
- 目录 / 注释抽屉是**侧滑面板**（`ImmersiveSheetPanel`），不是半模态；半模态面板
  （阅读设置 / 批注 / 标签菜单 / 亮度 / 导出 / 更多）统一走 `material/ModalSheet.ets`，
  且一个组件只能挂一条 `bindSheet`，用 `activeSheet` 字符串鉴别内容、与显隐开关**分离**
  （否则 dismiss 动画期间会渲染成空面板、在屏幕上留一块白板）。

### 批注坐标系

- 批注不按字符下标存，而是 **块 id + 该块内渲染文本区间**（`MdViewUtil.buildPieces`
  的拼接不变式保证一致），所以改字号、行高、版心都不会让高亮错位。
- 删除 / 编辑文档时按块 id 清理失效批注。

### 读写与只读

- 每篇文档一个持久标记 `DocMeta.readOnly`（存 `shelf.json`，`update()` / `rename()`
  都会显式搬运，保存正文不会把锁弄丢）；未设置过时兜底「内置教程只读、自建文档可写」。
- 只读 = **锁住"改写正文"这条路**：编辑入口不出现、任务勾选框只改内存态不写盘；
  阅读、批注、封面、导出、重命名一概不受影响。
- **判据只有这一个标记**：可写就能编辑（内置教程切成「可写」后同样能进编辑页），
  只读才不给编辑。所有编辑入口（阅读页顶栏笔形按钮、阅读页工具栏「编辑」、
  书架「选择操作 → 编辑」、编辑页保存）都只查 `readOnly`，不再顺带按 `builtin` 拦截。
- 入口有两处：书架格子的「选择操作」面板与阅读页「更多」面板，共用同一枚标记。
  面板里的开关状态**显式存成 `@State`**（打开时从数据层同步一次、切换时立即更新）——
  每次渲染现问数据层的写法在「面板打开后内容不重建」的场景下不会重绘，
  表现为"点了有提示、按钮没变化"。

### 底部悬浮胶囊里的快捷按钮（书架）

- 一颗圆形小钮**就在底部那颗悬浮胶囊内部**（胶囊的第三个子节点，与统计文字同一行），
  材质由 `ImmersiveBar` 统一承载，所以它天然是沉浸光感的，不是一个悬浮在外面的独立控件。
- **点击新建文档、长按导入**（长按 600ms，与「新建卡」同款）。

### 导出与打印

- 导出走自包含 HTML（`MdToHtml`）；图片长图用**分批离屏快照**（每批 20 块，
  参数化 `@Builder` + 闭包捕获批次数据，避免 `@State` 异步导致白屏）→
  逐批 `readPixelsToArea` 读像素 → 拼成完整 `PixelMap`。
- 打印走「长图 → A4 切片 → 每页 JPEG → 手工组装 PDF（`SimplePdf`）」，
  绕开 Web `createPdf` 在真机上抓不到帧的问题。
- PDF / 图片导出都受 `componentSnapshot` 单张约 8192px 的硬限约束，所以必须有分批与合并这两步。

### 数据、备份与隐私

- 所有数据落**应用沙箱**：`docs/*.md`（正文 + 图片）、`shelf.json`（元信息 / 顺序 / 进度 /
  封面 / 只读标记 / 文件夹）、`annotations`（批注）、`tabs.json`（标签）、
  `cacheDir/charts/`（图表缓存）。
- 备份：`BackupStore` 打包沙箱关键目录为 zip（文件名带日期），恢复时由系统文件选择器交回；
  `WebDavStore` 用 `PROPFIND / PUT / GET` 与**用户自己填写**的服务器同步，
  地址与账号只存本机，项目没有任何中转服务器。
- 权限只有两项：`INTERNET`（网络图片 / WebDAV / 检查更新）与 `DETECT_GESTURE`
  （智感握姿，不支持则降级居中）。**不收集任何个人数据，无统计 / 广告 / 推送 SDK**。
  详见应用内《隐私政策》。

### 检查更新

- 在「探索中心」点「检查更新」→ `http.createHttp()` 拉取发布页
  （`https://www.sydxky.cn/detail.php?id=956`）→ 解析页面上的版本徽标
  （`fa-code-branch` 图标后紧跟的 `<span>vX.Y.Z</span>`）→ 与 `bundleManager`
  读到的当前版本**逐段数字比对**：远端更高提示前往更新，当前更高提示版本超前，
  相等提示已是最新。带 8 秒超时与"进行中忽略重复点击"保护。

---

## 代码结构

```
AppScope/                         应用级配置与图标（app.json5：版本号、包名）
entry/src/main/
  module.json5                    模块配置：权限、Ability、form 扩展（卡片已注销）
  resources/
    base/element,profile          字符串 / 颜色 / 页面与备份 profile
    rawfile/
      README.md                   内置《Markdown 语法教程》正文
      chengjian.md                内置《澄笺示例 · 全功能演示》正文
      legal_privacy.html          隐私政策（跟随系统深浅色）
      legal_terms.html            用户协议
      render/*.html               7 个离线渲染模板（库整库内联）
      render/lib/                 渲染库与模板源文件
  ets/
    entryability/                 应用入口：沉浸窗口、持久化键注册、Web 整页绘制开关
    entrybackupability/           系统备份扩展
    entryformability/             桌面卡片扩展（**暂时停用**，代码保留）
    pages/
      Index.ets                   书架（首页）：网格 / 树形 / 搜索 / 拖拽归组 / 一镜到底
      Reader.ets                  阅读器：多标签 / 抽屉 / 批注 / 面板 / 图表放大
      Editor.ets                  编辑器：分屏预览 / 查找替换 / 版本历史 / 图片插入
      Settings*.ets               设置：主页 + 阅读调整 / 外观 / 数据 / 探索中心
      Changelog.ets               更新日志      LegalDoc.ets  法务文档页
      form/ShelfCard.ets          桌面卡片（暂时停用）
    components/                   DocCover / DiagramWeb / ChartRenderPool / ExportOptionsPanel …
    material/                     沉浸光感：ImmersiveCard 系列、ModalSheet、SystemMaterial
    markdown/                     MdParser / MdTypes / MdView / MdToHtml / CodeHighlight / MathLite
    service/                      DocStore / TabStore / AnnotationStore / ChartCache / BackupStore /
                                  WebDavStore / FontStore / WallpaperStore / ExportService /
                                  HeroTransition / NavLifecycle / SettingsMirror / GripAware …
    theme/                        DesignTokens（令牌 + 调色板）/ ThemeStore / GenWallpaper / FuncExpr
    util/                         全局上下文等小工具
    settings/ReadingSettings.ets  阅读排版设置面板（阅读页与设置页共用）
tools/                            开发用的小脚本（括号平衡检查、构建辅助）
build-profile.json5               构建配置（**已移除签名材料**）
build-profile.signing.example.json5  签名配置示例（照抄到自己机器上用）
```

---

## 构建与运行

**环境**：DevEco Studio 6.x（HarmonyOS SDK，`compatibleSdkVersion 6.1.1(24)`，
`targetSdkVersion 26.0.0`）。

1. 克隆仓库，用 **DevEco Studio** 打开根目录（首次会自动 `ohpm install`）。
2. **配置签名**：本仓库**不含**签名证书与密码。请在
   `File → Project Structure → Signing Configs` 勾选
   「Automatically generate signature」，DevEco 会自动生成调试证书并写回
   `build-profile.json5`（需要手写时照抄 `build-profile.signing.example.json5`）。
3. 直接运行到真机 / 模拟器，或构建安装包：

   ```bash
   # 产物：entry/build/default/outputs/default/
   hvigorw --mode module -p product=default assembleHap --no-daemon
   ```

**注意**：`oh_modules`、`build/`、`.hvigor/`、以及所有 `*.p12 / *.cer / *.p7b`
都已在 `.gitignore` 中排除——**请不要把签名材料提交上来**。

---

## 第三方开源组件

应用内图表与公式的渲染库**全部离线内联**在 `entry/src/main/resources/rawfile/render/` 中，
渲染过程不产生任何网络请求。各组件的版权与许可归其各自作者所有：

| 组件 | 用途 | 许可 |
| --- | --- | --- |
| [KaTeX](https://katex.org/) | 数学公式 | MIT |
| [mermaid](https://mermaid.js.org/) | 流程图 / 时序图 / 甘特图等 | MIT |
| [Apache ECharts](https://echarts.apache.org/) | 数据图表 | Apache-2.0 |
| [Graphviz (viz.js)](https://github.com/mdaines/viz.js/) | DOT 图 | MIT |
| [flowchart.js](http://adrai.github.io/flowchart.js/) + [Raphaël](http://dmitrybaranovskiy.github.io/raphael/) | 流程图 | MIT |
| [markmap](https://markmap.js.org/)（markmap-lib / markmap-view / d3） | 脑图 | MIT |
| [abcjs](https://abcjs.net/) | 乐谱 | MIT |
| HarmonyOS / OpenHarmony SDK | 系统能力与示例参考 | 见官方许可 |

设计与实现参考（**仅参考思路，未复制其代码**）：

- [MrCashmere/miha_hm](https://github.com/MrCashmere/miha_hm) — 沉浸光感承载层（Toggle + attributeModifier）方案
- [skadjhljhas/zhumo-reader](https://github.com/skadjhljhas/zhumo-reader) — 注释卡片式阅读形态
- [HarmonyOS_Samples/transitions-collection](https://gitcode.com/HarmonyOS_Samples/transitions-collection) — 一镜到底 / 多模态转场动效

字体、壁纸等用户自行导入的第三方资源，其授权由使用者自行确认。

---

## 版权与致谢

Copyright 2026 FengHDSL，基于 [MIT License](LICENSE) 开源。

**澄笺 · 光 · 美 · 舒 · 开源** —— 如果这个项目对你有帮助，欢迎 Star、提 Issue 或 PR。

> 说明：仓库中不包含签名证书（`.p12` / `.cer` / `.p7b`）与签名密码，
> 也不包含开发过程产物（`.workbuddy/`、`.codegenie/`）。
> 除这些之外，产品的全部源码、资源与配置都在这里——**完全开源**。
> 应用内联的第三方渲染库（ECharts 为 Apache-2.0，其余多为 MIT）仍遵循其各自许可，
> 详见上方「第三方开源组件」。
