/**
 * 澄笺 · 图表渲染结果磁盘缓存
 * ============================
 *
 * 公式 / 图表块在阅读页由 DiagramWeb（Web 组件）实时渲染——有三个代价：
 * 滑到位置才加载、每次打开都重渲、**导出快照无法捕获 Web 表面**。
 *
 * 本服务把渲染产物（PixelMap → PNG）按内容哈希写入 `<cacheDir>/charts/`：
 *   · 键 = md5(mode | 深浅 | 源码)——内容或主题变了自动换新键，天然失效；
 *   · 正文的 mathView / chartView 优先用缓存图（Image），没有才回落 DiagramWeb；
 *   · 后台预渲染池（ChartRenderPool）在打开文件时逐个补齐缓存。
 */

import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { display } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';

export class ChartCache {
  /** 键 → 路径 的会话内缓存（含「无缓存」的空串），避免每次渲染都 accessSync */
  private static memo: Map<string, string> = new Map();
  /** 键 → **Image/ImageSpan 可用源**（`file://` 前缀）的会话内缓存 */
  private static uriMemo: Map<string, string> = new Map();
  /** 键 → 'w|h'（**逻辑尺寸** = 期望显示的 vp 值）的会话内缓存 */
  private static dimMemo: Map<string, string> = new Map();

  /**
   * 清空三份会话内缓存，让下次查询按磁盘重建。
   * 备份恢复与清缓存后必须调它：memo 里记的是**恢复前**的路径与尺寸，
   * 不清的话界面上还会拿旧条目显示（新导入的 PNG / .dim 明明在盘上却读不到）。
   */
  static invalidate(): void {
    ChartCache.memo.clear();
    ChartCache.uriMemo.clear();
    ChartCache.dimMemo.clear();
  }

  /**
   * 内容哈希：mode | 深浅 | **卡片底色** | 源码 → md5 hex。同步实现（输入都是小文本）。
   *
   * **键盐代际**（历史包袱的教训，别再往回调）：
   *  · v2（首轮快照管线修复）：清掉"快照竞速"可能存下的空白图；
   *  · v3（2026-10-10 二度升级）：清掉"快照黑底"图（webPageSnapshot 不含
   *    alpha，透明被合成成黑——块级公式显示黑块）与"无尺寸 sidecar"的行内图。
   *  · v4（2026-10-10 三度升级）：键里加入**卡片底色 bg**——块级图的页面底色
   *    就是 codeBlockBg，而五档主题的深色孪生款（Sepia/Green）底色是暖棕/墨绿，
   *    旧键只有 dark 布尔 → 换深色主题后复用别主题烘焙的图 = **"深色下背景发红/发绿"**
   *   （用户实测）。
   *  · v5（2026-10-10 四度升级）：修**烘焙底色被 CSS 误解析**——cardBg 以项目
   *    #AARRGGBB 格式直接进 CSS，被按 #RRGGBBAA 解析成 10% 红罩，烘焙出的
   *    PNG 全部带暗红底（用户实测截图实锤）。DiagramWeb 现已转 rgba() 再进页面，
   *    键升盐让带红罩的旧图全部失效重生成。
   *  · v6（2026-10-11 五度升级）：修**快照高度上限 1200 截断高图**——类图/大型
   *    流程图在整窗宽下烘焙高度超限，PNG 被拦腰截断、显示端当完整图展示
   *    （用户实测"类图显示不完整"）。块级图上限提到 4096，键升盐让截断旧图失效。
   *  · v7（2026-10-11 六度升级）：块级公式改**品红底拍摄 + 键控抠透明**——
   *    公式卡片挂沉浸光感承载层，透明图让材质透出（不透明烘焙底会盖住材质）。
   *  · v8（2026-10-11 七度升级）：①键控改**预乘写法**；②图表模板页应用卡片底色
   *    （o.bg，修浅色图表卡黑背景）。
   *  · v9（2026-10-11 八度升级）：**公式键控透明方案整体回退**——真机上透明 PNG
   *    在 Image 组件里渲染不可靠（卡片全黑），公式恢复烘焙卡片底色不透明图。
   *  · v10（2026-10-11 九度升级）：markmap 高度回传改**画布实际高度**——此前
   *    scrollHeight 被 svg 内部尺寸虚高，脑图快照成"上方一条 + 下方空白"、
   *    卡片按虚高拉满（用户实测"显示面积异常"）。键升盐作废虚高期脑图缓存。
   *  · v11～v12：放大浮层画布形态与模板统一（markmap-card 一份模板管两种形态）。
   *  · v13（2026-10-11 十度升级）：修**超宽公式快照被裁断**——katex 块级路径此前是
   *    `#app{overflow:auto}`，#app 自己吞掉溢出，文档宽度恒等于视口宽
   *    （实测 2195px 的公式 documentElement.scrollWidth 仍只有 617），整页快照
   *    只拍得到左边一截 → 烘焙出的 PNG 天生缺一段，卡片里怎么滑都补不回来
   *    （用户实测"部分内容被裁切显示不完全"）。当时改为溢出可见 + body max-content；
   *    ⚠️ 但这批改动让用户实测更差（卡片被拉得一屏长、有的公式内容反而变小），
   *    已**整体撤回**，katex.html 恢复原状。
   *  · v15（2026-10-13 十二次升级）：mermaid 10.9.3→11.4.1（新图种 packet/kanban/architecture）
   *    与 KaTeX 挂载 mhchem 化学扩展——旧引擎时代的错误渲染图（kanban/架构图/数据包图/
   *    化学式的报错 SVG）全部作废，按新引擎重生成。
   *  · v16（2026-10-13 十三次升级）：mermaid 11.4.1→11.17.2（architecture-beta 的中文标签
   *    在旧构建里是词法层直接拒收）。**这条同时是"引擎升级必须升键"的又一例**：缓存键里
   *    没有引擎版本，用户机上就会留着旧引擎烘出来的"Syntax error in text"报错图，
   *    卡片读缓存、放大走实时渲染 → "卡片显示错误、放大后正常"（用户实测）。
   *  · v14（2026-10-11 十一次升级）：跟随公式卡片撤回**键升盐**——v13 那批
   *    "按公式自身尺寸"的 PNG 与 .dim 和撤回后的模板产物尺寸口径不同，
   *    两代混存会让卡片高度忽高忽低，必须一并作废重生成。
   *  · v17（2026-10-13 十四次升级）：修「**空白图能被写进持久缓存**」——卡片快照刻意
   *    烘焙不透明卡片底色，而池子的空白自检只看了 alpha，一片底色 alpha=255 直接过关，
   *    于是"什么都没画出来"的失败快照永久落盘；正文命中缓存键就一直显示同色矩形，
   *    重开文档也不恢复（放大浮层走实时 Web，所以"卡片空白、放大正常"，
   *    用户实测 chart.js「数据可视化卡片上不显示，浅色模式也不显示」正是这一条）。
   *    自检改成"整张同色才算空白"，同时升键把已经躺在用户机上的空白图作废重生成。
   *  · v18（2026-10-14 十五次升级）：mermaid 浅色主题 **neutral → default**（实测时序图
   *    参与者框 neutral 是灰框黑字、default 才是淡紫；用户对比别家渲染说"图表没颜色"）。
   *    主题只改渲染产物、不改缓存键 → 不升键就会出现"卡片还是灰的、放大才有色"，
   *    与 v16 那条"引擎升级必须升键"是同一个坑。
   *  · v19（2026-10-14 十六次升级）：**新增 Vega-Lite 引擎**（vega 6.4.0 + vega-lite 6.5.0，
   *    围栏 ```vega-lite / ```vl，模板 render/vega.html 走 vegaLite.compile → vega.View 出 SVG）。
   *    新引擎本来没有旧缓存，仍按"引擎有变动就升键"的统一口径升一次。
   *  · v20（2026-10-14 十七次升级）：**Chart.js 4.4.7 → 4.5.1**（全库版本巡检里唯一
   *    "小版本可安全升"的一项；升级后浏览器实测 chart.html 仍然正常出图）。
   *    同批巡检结论：KaTeX / markmap / d3 / ECharts / abcjs / Viz.js / WaveDrom /
   *    nomnoml / vega / turndown 都已是最新；mermaid 停 11.17.2（12 实测回归）、
   *    flowchart.js 停 1.17.1（1.18 不再发浏览器包）、MathJax 停 3.2.2（v4 要 API 适配）。
   *  · v21（2026-10-14 十八次升级）：**PlantUML 换成离线内核 @plantuml/core 1.2026.8**
   *    （模板 render/plantuml.html，阅读侧不再桥成 mermaid）。同一份源码在旧键里是
   *    "mermaid 桥出来的图"，新键才是"内核原生图"，不升盐就会**卡片读旧桥图、放大才变**
   *    （v17 那轮 blank 图的同款坑）。
   *  · v22（2026-10-14 十九次升级）：**新增 ZenUML 引擎**（当时走 mermaid 外部图种插件，
   *    模板 render/zenuml.html）。⚠️ 插件路线后来废掉了（真机报 Syntax error，
   *    zenuml.html 与 3.14MB 插件已从包里删，现在由 ZenumlBridge 在解析层转成 mermaid 时序图），
   *    这条盐只是当时的记录。
   *  · v23（2026-10-14 二十次升级）：**PlantUML 内核模板由 ES module 改成普通脚本**。
   *    module 版在真机上整族画不出（用例/活动/组件/部署/mindmap/WBS/甘特/JSON/YAML/
   *    Archimate/ER），而失败态的**错误文字会被预渲染池烘成 PNG**（"PlantUML 引擎未就绪"
   *    那张红字卡），键不升就会一直拿那张坏卡当缓存图显示——修好了也看不见。
   *  · v24（2026-10-15 二十一次升级）：**预渲染池拍到旧表面就入库**这一整类坏图。
   *    拉取用户手机 charts/ 与 .dim 逐张比对：1595 张里 **104 张**的 PNG 高度正好是
   *    初始 100vp×密度，而 .dim 记的是真实高度（其中一篇文档 29 张 mermaid 中 21 张中招，
   *    一张时序图的键下存的是上一块公式的像素）。正文按 .dim 撑框 + Contain 显示 =
   *    图缩成卡片中间一条，且**重开文档也不会恢复**（用户报"正常阅读页面渲染也是错误"）。
   *    池子现在会拒收这类快照并重拍，这批已落盘的坏图必须靠升键作废。
   *  · v25（2026-10-16 二十二次升级）：**"跨页面串图"坏图**（尺寸自洽、内容却是别的图）。
   *    v24 治的是"拍矮了"（像素/逻辑两轴比较能测出来），但**旧页面在 loadUrl 窗口里
   *    报的身高**会让池子在尺寸完全自洽的情况下拍下旧内容 —— 这类图 v24 的检查测不到，
   *    例：用户机上 wavedrom 的键下存的是一张**另一个文档**的流程图（内容含 Pandoc，
   *    本文档没有这个词），尺寸还是 wavedrom 该有的 365×94。修法 = DiagramWeb 在
   *    "模板页切换窗口"（loadUrl → onPageEnd）丢弃全部尺寸报告（旧页面残报进不来，
   *    池子只会收到新页面的真实回传）；这批已落盘的串图靠升键作废重生成。
   *  · v26（2026-10-16 二十三次升级）：**图的形态统一为"下载样式"**。池子烘图改传
   *    `dl: true`（直角 + 去内边距）并在落盘前裁到内容边界（`save(…, trim=true)`）——
   *    导出 / 打印的内嵌图与用户"手动下载"的 PNG 长得一样（用户实测反馈："打印的
   *    html 里，公式块、图表不是手动下载的样式"）。v25 的"卡片圆角 + 四周留白"图
   *    形状不同（尺寸、边距全变），不升键就会新旧混用。
   *  · v27（2026-10-16 二十四次升级）：**窄条坏图**（用户实测状态图 / C4 / 韦恩图
   *    在导出与打印里被挤成一条）。v26 对齐"下载样式"时只给了 `dl`、漏了 `fit`，
   *    页面于是仍走**卡片模式**：按 viewBox 把整图夹进 capW×capH(340~600)，长图被
   *    等比缩小（73×1274 那张状态图正是 capH=340 的算结果）。池子补 `fit:true` +
   *    定宽烘焙，且 `.dim` 改用组件实测宽补齐 —— 出图尺寸口径整体变了，
   *    v26 落盘的窄条图必须作废重烘（否则改了代码也还是旧图，用户实测"没修复"）。
   *  · v28（2026-10-16 二十五次升级）：**v27 没治住窄条**（用户实测状态图 / C4 /
   *    韦恩图 / 树形视图照旧挤压，而"单独下载图片"是正常的）。拉整机缓存取证 507 张：
   *    5 张窄条的 `.dim` 与像素**两轴倍数自洽**（rx≈ry≈3.5，状态图 21|363 对 73×1274）
   *    —— 说明不是"拍早了"、也不是 v27 猜的卡片限高（那条公式算不出 21vp 这么窄的
   *    结果），而是页面**真的按 21vp 宽重排**了：池子的表面宽度写的是 `'100%'`，
   *    父容器在转场 / 首帧那几百毫秒里量到一个极小值，mermaid 就照它排版。
   *    下载链路一直是对的，正是因为它 `.width(surfaceW)` 把表面钉死了。
   *    现在池子改用同一套 DlFit（钉死表面 + 超宽内容下发等比 zoom + layoutTick 重排），
   *    v27 那批窄条图与 39 张两轴倍数对不上的 `.dim`（钉死前 areaW 取到的是瞬时宽）
   *    一起作废重烘。
   *  · v29（2026-10-16 二十六次升级）：`.dim` 改由**裁边后的像素 ÷ 屏幕密度**反推
   *    （原来用页面滞后的回传高度，量到的尺寸与图本体不是一套）。尺寸口径变了，
   *    旧 sidecar 全部作废。
   *  · （v30 升过又撤了，记在这里别再重犯）：池子加"内容被表面切掉"的像素守卫时
   *    顺手把盐升到 v30，想让用户机上那两张截断图重烘 —— 代价是**整篇几千张好图
   *    一起作废**：用户机上导出立刻从"31 张内嵌图"退回"一堆现场渲染容器 + 背 12MB
   *    渲染库"，实测反馈"一堆图表又不加载了"。守卫只影响**新烘**的图，旧图里被切
   *    的是极少数（31 张里 2 张），为两张图作废整批缓存是亏本买卖。
   *    升盐只该用于"口径变了，旧图必然是错的"，不能用来修个别坏图。
   */
  static keyFor(mode: string, payload: string, dark: boolean, bg: string = ''): string {
    return ChartCache.hashOf(ChartCache.SALT + '|' + bg + '|' + mode + ChartCache.revOf(mode)
      + '|' + (dark ? 'd' : 'l') + '|' + payload);
  }

  /**
   * **按图种的局部版本号** —— 只作废"出图口径变了"的那一个图种。
   *
   * 整块 `SALT` 一升就是几千张全部重烘：用户机上表现为下一次导出/打印全退回
   * "现场渲染的容器" + 背十几 MB 渲染库（2026-10-16 为修 31 张里 2 张截断图升 v30，
   * 结果换来"一堆图表又不加载了"）。所以**个别图种的口径变更升这一位**，
   * 其余图种的缓存原样留着。
   */
  private static revOf(mode: string): string {
    if (mode === 'katex') {
      // r2（2026-10-17）：模板报宽改用公式元素自身的布局宽 —— `scrollWidth` 量不到
      // 向左的溢出，超宽公式报回来的宽度偏小 → 缩放倍率偏大 → 烘出的图左边缺一截。
      // r3（2026-10-17）：用户实测"部分公式块背景是黑色"。那是**旧代缓存**留下的：
      // 更早的烘焙里卡片底色没传进模板，webPageSnapshot 不含 alpha，透明被合成成黑。
      // 公式任务只在点导出 / 打印时排队，所以这次作废不产生阅读期负载。
      return ':r3';
    }
    if (mode === 'mermaid' || mode === 'wavedrom') {
      // r3（2026-10-17）：**串图实锤** —— 真机导出里"5.6 Journey 用户旅程图"的键下
      // 存的是一张白字黑底的公式图（浅色孪生与正文任务同模式背靠背、组件不重载，
      // 深色那一帧被写进浅色的键）。这批脏键全部作废重烘。
      return ':r3';
    }
    return '';
  }

  /**
   * 缓存键盐。**payload 反查索引也必须带上它**（`idxKeyOf`）：索引文件名的哈希原本
   * 只含 `mode|深浅|payload`，升盐只换了图本体的键，索引里那条还指着**上一个盐版本
   * 落盘的旧图** —— 于是"升了键作废旧图"这件事对走索引的导出/打印根本不生效，
   * 用户机上那 5 张窄条图在 v28 之后照样被索引捞出来显示（用户实测"还是挤在一起"）。
   */
  static readonly SALT: string = 'v29';

  /** payload → 索引文件名（含盐：换烘焙口径时索引与图本体一起作废） */
  private static idxKeyOf(mode: string, payload: string, dark: boolean): string {
    return ChartCache.hashOf(ChartCache.SALT + '#i|' + mode + ChartCache.revOf(mode)
      + '|' + (dark ? 'd' : 'l') + '|' + payload);
  }

  private static hashOf(raw: string): string {
    try {
      const encoder: util.TextEncoder = new util.TextEncoder();
      const md: cryptoFramework.Md = cryptoFramework.createMd('MD5');
      md.updateSync({ data: encoder.encodeInto(raw) });
      const digest: cryptoFramework.DataBlob = md.digestSync();
      let hex: string = '';
      for (let k = 0; k < digest.data.length; k++) {
        const v: number = digest.data[k];
        hex += (v < 16 ? '0' : '') + v.toString(16);
      }
      return hex;
    } catch (err) {
      return raw.length.toString(16);
    }
  }

  /**
   * **payload 索引**（导出反查用）：池子每烘成一张图，就登记
   * `md5(mode|payload) → 实际缓存 key`。
   * key 里混着 bg 与深浅位，导出侧拿不到渲染当时的准确组合 —— 有了这份索引，
   * 导出只凭 (mode, payload) 就能反查到图（用户实测：bg 对不上时导出全是代码块）。
   */
  static rememberPayloadKey(ctx: common.UIAbilityContext, mode: string, payload: string,
                            dark: boolean, key: string): void {
    try {
      const dir: string = ctx.cacheDir + '/charts/payload';
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const p: string = dir + '/' + ChartCache.idxKeyOf(mode, payload, dark) + '.txt';
      const file: fs.File = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, key);
      fs.closeSync(file);
    } catch (err) {
      // 索引写失败不影响缓存本体
    }
  }

  /** payload 索引反查：拿到该 (mode, payload, 深浅) 实际落盘的缓存 key（没有返回空串）。 */
  static payloadKey(ctx: common.UIAbilityContext, mode: string, payload: string,
    dark: boolean): string {
    try {
      const p: string = ctx.cacheDir + '/charts/payload/'
        + ChartCache.idxKeyOf(mode, payload, dark) + '.txt';
      if (!fs.accessSync(p)) {
        return '';
      }
      const file: fs.File = fs.openSync(p, fs.OpenMode.READ_ONLY);
      let key: string = '';
      try {
        const buf: ArrayBuffer = new ArrayBuffer(128);
        const n: number = fs.readSync(file.fd, buf);
        if (n > 0) {
          key = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, n)).trim();
        }
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
        }
      }
      return key;
    } catch (err) {
      return '';
    }
  }

  /** 已缓存的图表图片路径；无缓存返回空串（结果记入 memo）。 */
  static path(ctx: common.UIAbilityContext, key: string): string {
    const hit: string | undefined = ChartCache.memo.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const p: string = ctx.cacheDir + '/charts/' + key + '.png';
    let found: string = '';
    try {
      if (fs.accessSync(p)) {
        found = p;
      }
    } catch (err) {
      found = '';
    }
    // ⚠️ **只记"有"，不记"没有"**（2026-10-16 用户实测导出进度"还差 75 张"从头到尾
    // 不往下走）：导出 / 打印前会轮询等池子补烘（ChartRuntimeService.waitShots，
    // 每 500ms 问一次 missingShots）。把"还没烘出来"也缓存进内存，第二轮起问的都是
    // 上一轮的旧答案 —— 图明明在一张张落盘，计数却冻在第一次的值上。
    if (found.length > 0) {
      ChartCache.memo.set(key, found);
    }
    return found;
  }

  /**
   * **行内公式图的缓存键**（v3：MathJax 光栅化的紧凑公式图）。
   *
   * 与旧键（`iminl2_` = 快照裁出的整页图）区分；**含字号**：公式图按正文
   * 字号排版，用户改字号后应重新生成（旧实现没有字号维度，公式大小不随
   * 正文字号联动——顺带修复）。
   */
  static inlineKey(latex: string, dark: boolean, size: number): string {
    return 'iminl3_' + ChartCache.keyFor('katex', size + '|' + latex, dark);
  }

  /**
   * 记录"逻辑尺寸"（生成端按正文字号排版后回传的设计尺寸）。
   *
   * ⚠️ 为什么必须有：PNG 是"逻辑尺寸 × 屏幕密度"的高清像素（保清晰度）。
   * 显示端 Image/ImageSpan 对图片像素的默认换算不可依赖（实测像素被 1:1
   * 当 vp 用 → 图放大 density 倍——用户实测"公式渲染放大这么大"）。
   * 显示时**显式**把宽高设为这里的逻辑尺寸（vp），尺寸精确、像素仍高清。
   */
  static setDim(key: string, w: number, h: number): void {
    if (w > 0 && h > 0) {
      ChartCache.dimMemo.set(key, Math.round(w) + '|' + Math.round(h));
    }
  }

  /** 读取逻辑尺寸（'w|h'；无记录返回空串）。会话内走内存，重启后读 sidecar。 */
  static dimOf(ctx: common.UIAbilityContext, key: string): string {
    const hit: string | undefined = ChartCache.dimMemo.get(key);
    if (hit !== undefined) {
      return hit;
    }
    let v: string = '';
    try {
      const p: string = ctx.cacheDir + '/charts/' + key + '.dim';
      if (fs.accessSync(p)) {
        const file: fs.File = fs.openSync(p, fs.OpenMode.READ_ONLY);
        try {
          const buf: ArrayBuffer = new ArrayBuffer(64);
          const n: number = fs.readSync(file.fd, buf);
          if (n > 0) {
            v = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, n)).trim();
          }
        } finally {
          try {
            fs.closeSync(file);
          } catch (closeErr) {
            // 关闭失败无副作用
          }
        }
      }
    } catch (err) {
      v = '';
    }
    ChartCache.dimMemo.set(key, v);
    return v;
  }

  /**
   * 行内公式图落盘：PNG dataURL（base64）→ 文件 + memo 更新 + 逻辑尺寸 sidecar。
   *
   * 与 `save()`（PixelMap 打包）的区别：那个走 image packer（快照链路），
   * 这个直接写字节（MathJax 光栅化链路回传的就是 PNG base64）。
   */
  static savePngBase64(ctx: common.UIAbilityContext, key: string, dataUrl: string,
                       w: number, h: number): boolean {
    try {
      const comma: number = dataUrl.indexOf(',');
      if (comma < 0) {
        return false;
      }
      const bytes: Uint8Array =
        new util.Base64Helper().decodeSync(dataUrl.substring(comma + 1));
      if (bytes.length < 32) {
        return false;
      }
      const dir: string = ctx.cacheDir + '/charts';
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const p: string = dir + '/' + key + '.png';
      const file: fs.File = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes.buffer as ArrayBuffer);
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
      ChartCache.memo.set(key, p);
      ChartCache.uriMemo.set(key, 'file://' + p);
      // 逻辑尺寸：内存 + sidecar（重启后显示端仍能取到，不必反推像素/密度）
      if (w > 0 && h > 0) {
        const dim: string = Math.round(w) + '|' + Math.round(h);
        ChartCache.dimMemo.set(key, dim);
        try {
          const dp: string = dir + '/' + key + '.dim';
          const df: fs.File = fs.openSync(dp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          try {
            fs.writeSync(df.fd, new util.TextEncoder().encodeInto(dim).buffer as ArrayBuffer);
          } finally {
            try {
              fs.closeSync(df);
            } catch (e2) {
              // 关闭失败无副作用
            }
          }
        } catch (err2) {
          // sidecar 写失败：内存仍有效（本次会话）；重启后回退自然尺寸
        }
      }
      return true;
    } catch (err) {
      return false;
    }
  }

  /**
   * 缓存图 → **Image / ImageSpan 组件可用的源**（`file://` 前缀）。
   *
   * ⚠️ 为什么必须单独有它（2026-10-10 用户实测"全部空白"的直接根因）：
   * Image / ImageSpan 传入**裸沙箱路径**时**加载失败且静默空白**——官方 FAQ：
   * string 路径要么带 `file:///` 前缀、要么用 `fileUri.getUriFromPath` 转 URI；
   * 项目的 `DocStore.resolveImagePath`（封面 / 正文插图，一直显示正常）也正是
   * 先拼了 `file://` 才交给 Image。而此前的 ChartCache.path 返回裸路径直接喂给
   * Image/ImageSpan —— 公式/图表缓存图**第一次真正批量生成**后（后台池修复后），
   * 所有切到图片的位置全部空白。文件系统读写（EpubExport 读字节等）仍用
   * `path()` 的裸路径，两者不可互相替换。
   */
  /**
   * 导出侧认的**浅色快照键**，按优先级排（`pngEmbed` 与 `hasShot` 必须共用这一份，
   * 两边口径不一样就会"判定说有图、嵌图时找不到图"——内核被丢掉、图又没嵌上，
   * 导出页里那块直接空/退成源码，正是用户报的"graphviz 和 abc 也没加载出来"）。
   */
  private static lightShotKeys(ctx: common.UIAbilityContext, mode: string,
    payload: string, bg: string): string[] {
    return [
      ChartCache.keyFor(mode, payload, false, bg),
      ChartCache.keyFor(mode, payload, false, ''),
      ChartCache.payloadKey(ctx, mode, payload, false)
    ];
  }

  /**
   * 这张图**是否已有可嵌进导出的快照**（只判文件在不在，不读字节）。
   *
   * 导出 / 打印侧用它做"缺图判定"（ChartRuntimeService.missingShots）：阅读页已经
   * 把每张图烘好了，导出嵌 PNG 就够 —— 设备实测一篇全图种文档的导出 HTML **17.8MB**
   * （62 张图 4.3MB + 渲染库 11.6MB），缺图判定让"图齐就一个库都不带"。
   *
   * ⚠️ `dark` 参数**故意不参与取键**：导出与打印恒定浅色（用户要求"深色底图永不进
   * 导出"），所以只有浅色版才算数。深色模式下读书时这里会判"缺图"、导出把渲染库
   * 背上（页面重），那是正确一侧的代价；根治是预渲染池把浅色版也烘一份（#65）。
   */
  static hasShot(ctx: common.UIAbilityContext, mode: string, payload: string,
                 dark: boolean, bg: string): boolean {
    const variants: string[] = ChartCache.lightShotKeys(ctx, mode, payload, bg);
    for (let k = 0; k < variants.length; k++) {
      // 走 srcPath 而不是 path：尺寸口径自检不过的坏图（见 dimMatchesPixels）不能算"有快照"，
      // 否则导出会以为能嵌图、把内核丢掉，结果那张图在导出页里根本不存在
      if (variants[k].length > 0 && ChartCache.srcPath(ctx, variants[k]).length > 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 导出用：把阅读页预渲染池**已烘好的缓存 PNG**读成 base64 dataURL。
   * 深浅两个 key 都试（导出时的主题与渲染时不一定一致）。都没有返回空串。
   */
  /**
   * 导出内嵌快照图 + **逻辑尺寸**（用户实测"部分图片过小或被拉伸"）：
   * 快照是按阅读页卡片的设备像素烘的，浏览器不知道该显示多宽 → 被拉伸/过小。
   * 这里有 .dim 逻辑尺寸（w|h，vp）随图返回，导出侧据此显式定宽、等比缩放。
   *
   * ⚠️ **.dim 不是总有**：只有 katex 模板回传 postWidth，mermaid / plantuml / graphviz…
   * 一律不回（见各模板的 report），那些键的 sidecar 就是空的。上一版此时返回裸图，
   * 导出侧只能写 `max-width:100%` → 浏览器按**物理像素**显示 = 放大 density 倍
   * （用户实测导出的公式块比正文大两三倍、图与图之间大小完全不一致）。
   * 现在量不到 .dim 就按「PNG 像素 ÷ 屏幕密度」反推逻辑尺寸：像素本来就是
   * 逻辑尺寸 × 密度，这一条恒等式比"等某个模板回传"可靠。
   */
  static pngEmbed(ctx: common.UIAbilityContext, mode: string, payload: string,
    dark: boolean, bg: string): string {
    // 强制浅色（用户要求）：深色底图永不进导出/打印——只试浅色键
    //（bg 两个变体：实参 bg 与空 bg；payload 索引也是浅色档）
    const candidates: string[] = ChartCache.lightShotKeys(ctx, mode, payload, bg);
    for (let k = 0; k < candidates.length; k++) {
      const key: string = candidates[k];
      if (key.length === 0) {
        continue;
      }
      const file: string = ChartCache.path(ctx, key);
      if (file.length === 0) {
        continue;
      }
      const dataUrl: string = ChartCache.dataUrlOf(file);
      if (dataUrl.length === 0) {
        continue;
      }
      let dim: string = ChartCache.dimOf(ctx, key);
      if (dim.length === 0) {
        dim = ChartCache.logicalDimOfPixels(file);
      }
      return dim.length > 0 ? dataUrl + String.fromCharCode(1) + dim : dataUrl;
    }
    return '';
  }

  /** PNG 文件 → data URL（读不出返回空串）。 */
  private static dataUrlOf(file: string): string {
    try {
      const fh: fs.File = fs.openSync(file, fs.OpenMode.READ_ONLY);
      let url: string = '';
      try {
        const stat: fs.Stat = fs.statSync(file);
        const buf: ArrayBuffer = new ArrayBuffer(stat.size);
        const n: number = fs.readSync(fh.fd, buf);
        if (n > 0) {
          url = 'data:image/png;base64,' + new util.Base64Helper()
            .encodeToStringSync(new Uint8Array(buf, 0, n));
        }
      } finally {
        try {
          fs.closeSync(fh);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
      return url;
    } catch (err) {
      return '';
    }
  }

  /**
   * 由 PNG 头反推**逻辑尺寸**（'w|h'，vp）：IHDR 宽高是物理像素，除以屏幕密度。
   * 读不出（拿不到密度 / 头不完整）返回空串，导出侧退回自适应。
   */
  private static logicalDimOfPixels(file: string): string {
    try {
      const dens: number = display.getDefaultDisplaySync().densityPixels;
      if (!(dens > 0)) {
        return '';
      }
      const fh: fs.File = fs.openSync(file, fs.OpenMode.READ_ONLY);
      let buf: ArrayBuffer = new ArrayBuffer(24);
      let n: number = 0;
      try {
        n = fs.readSync(fh.fd, buf);
      } finally {
        try {
          fs.closeSync(fh);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
      if (n < 24) {
        return '';
      }
      const b: Uint8Array = new Uint8Array(buf);
      const pw: number = ((b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19]) >>> 0;
      const ph: number = ((b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23]) >>> 0;
      if (pw <= 0 || ph <= 0) {
        return '';
      }
      return Math.round(pw / dens) + '|' + Math.round(ph / dens);
    } catch (err) {
      return '';
    }
  }

  /**
   * **PNG 内容裁边**（下载/导出用，用户实测"一张小图浮在巨大空白画布里"+ 四角黑角）：
   * 以角落像素为背景色，扫描全部像素求**内容包围盒**，裁掉四周空白
   *（含圆角卡片的黑角区域）+ 留 12px 呼吸边。全空白图原样返回。
   * ⚠️ 颜色通道序（BGRA/RGBA）无关——背景采样与比较都在同一份像素上做。
   */
  static async trimPng(bytes: ArrayBuffer): Promise<ArrayBuffer> {
    try {
      const src: image.ImageSource = image.createImageSource(bytes);
      const pm: image.PixelMap = await src.createPixelMap();
      const info: image.ImageInfo = await pm.getImageInfo();
      const w: number = info.size.width;
      const h: number = info.size.height;
      if (w < 40 || h < 40) {
        return bytes;
      }
      // 标准读取：readPixelsToBuffer 的缓冲区尺寸 = w*h*4（SDK 约定，紧凑无行距）
      const buf: ArrayBuffer = new ArrayBuffer(w * h * 4);
      await pm.readPixelsToBuffer(buf);
      const u8: Uint8Array = new Uint8Array(buf);
      const stride: number = w * 4;
      // 背景采**上边缘中点**（内缩 2px）——圆角快照的角是黑色，不能采角
      const bgO: number = 2 * stride + Math.floor(w / 2) * 4;
      const bgR: number = u8[bgO];
      const bgG: number = u8[bgO + 1];
      const bgB: number = u8[bgO + 2];
      // 四个角区（圆角黑角所在）整体排除在内容扫描之外
      const cs: number = 44;
      let minX: number = w;
      let minY: number = h;
      let maxX: number = -1;
      let maxY: number = -1;
      const tol: number = 12;
      for (let y = 0; y < h; y++) {
        const row: number = y * stride;
        for (let x = 0; x < w; x++) {
          if ((x < cs && y < cs) || (x >= w - cs && y < cs)
            || (x < cs && y >= h - cs) || (x >= w - cs && y >= h - cs)) {
            continue;
          }
          const o: number = row + x * 4;
          if (Math.abs(u8[o] - bgR) > tol || Math.abs(u8[o + 1] - bgG) > tol
            || Math.abs(u8[o + 2] - bgB) > tol) {
            if (x < minX) { minX = x; }
            if (x > maxX) { maxX = x; }
            if (y < minY) { minY = y; }
            if (y > maxY) { maxY = y; }
          }
        }
      }
      src.release();
      pm.release();
      if (maxX < 0) {
        return bytes;
      }
      const pad: number = 12;
      const cx: number = Math.max(0, minX - pad);
      const cy: number = Math.max(0, minY - pad);
      const cw: number = Math.min(w - cx, maxX - cx + 1 + pad * 2);
      const ch: number = Math.min(h - cy, maxY - cy + 1 + pad * 2);
      if (cw >= w && ch >= h) {
        return bytes;
      }
      const src2: image.ImageSource = image.createImageSource(bytes);
      const pm2: image.PixelMap = await src2.createPixelMap();
      const region: image.Region = { x: cx, y: cy, size: { width: cw, height: ch } };
      await pm2.crop(region);
      const packer: image.ImagePacker = image.createImagePacker();
      const out: ArrayBuffer = await packer.packToData(pm2, { format: 'image/png', quality: 100 });
      src2.release();
      pm2.release();
      return out;
    } catch (err) {
      return bytes;
    }
  }

  /**
   * **PNG 等比降档**（下载用，尺寸上限保护）。
   *
   * 只处理"正常尺寸之外的巨型图"：最长边超过 `maxSide`、或像素总面积超过
   * `maxArea` 时，按**同一个倍率**（横纵同倍）缩到限度内 —— 等比缩放不拉伸不挤压，
   * 只是别让用户拿到一张几十兆、发不出去的图。正常尺寸的公式/图表原样返回。
   * 解码失败、尺寸本就合规、缩放结果比原图还大，都原样返回（保守）。
   */
  static async capPngSize(bytes: ArrayBuffer, maxArea: number, maxSide: number): Promise<ArrayBuffer> {
    try {
      const src: image.ImageSource = image.createImageSource(bytes);
      const pm: image.PixelMap = await src.createPixelMap();
      const info: image.ImageInfo = await pm.getImageInfo();
      const w: number = info.size.width;
      const h: number = info.size.height;
      src.release();
      pm.release();
      if (w <= 0 || h <= 0) {
        return bytes;
      }
      const longSide: number = Math.max(w, h);
      const area: number = w * h;
      if ((maxSide <= 0 || longSide <= maxSide) && (maxArea <= 0 || area <= maxArea)) {
        return bytes;
      }
      const kSide: number = maxSide > 0 ? maxSide / longSide : 1;
      const kArea: number = maxArea > 0 ? Math.sqrt(maxArea / area) : 1;
      const k: number = Math.min(1, kSide, kArea);
      if (!(k > 0) || k >= 1) {
        return bytes;
      }
      // ⚠️ **必须两轴一起给**（desiredSize 只给一边时，SDK 不保证等比）：
      // 按同一个 k 算出两轴目标尺寸，四舍五入后至少留 1px
      const nw: number = Math.max(1, Math.round(w * k));
      const nh: number = Math.max(1, Math.round(h * k));
      const src2: image.ImageSource = image.createImageSource(bytes);
      const pm2: image.PixelMap = await src2.createPixelMap({ desiredSize: { width: nw, height: nh } });
      const packer: image.ImagePacker = image.createImagePacker();
      const out: ArrayBuffer = await packer.packToData(pm2, { format: 'image/png', quality: 100 });
      src2.release();
      pm2.release();
      // 缩放结果反而更大（源图本就是极致压缩的小图）时保留原图
      return out.byteLength > 0 && out.byteLength < bytes.byteLength ? out : bytes;
    } catch (err) {
      return bytes;
    }
  }

  static pngBase64(ctx: common.UIAbilityContext, mode: string, payload: string,
    dark: boolean, bg: string): string {
    // **先要请求的那个深浅版本，再退到另一版**（顺序不能反）。
    // 上一轮为了"浅色导出页别混进深色底图"改成只认同版本，结果在深色模式下读书再打印时
    // 一张快照都拿不到 → 导出/打印只能背上全部渲染库（实测 11.4MB），ArkWeb 装不下，
    // 整页空白（用户实测"打印又不显示了，graphviz 和 abc 也没加载出来"）。
    // 两权相害：宁可出现"深色底图"这种观感瑕疵，也不能整页不出图；
    // 真正的解法是让预渲染池把浅色版也烘一份（已记待办）。
    // **强制浅色**（用户要求）：深色底图永不进导出/打印——只试浅色键
    //（bg 两个变体：实参 bg 与空 bg；payload 索引也是浅色档）。
    const variants: string[] = [
      ChartCache.keyFor(mode, payload, false, bg),
      ChartCache.keyFor(mode, payload, false, ''),
      ChartCache.payloadKey(ctx, mode, payload, false)
    ];
    for (let k = 0; k < variants.length; k++) {
      const key: string = variants[k];
      const path: string = ChartCache.srcPath(ctx, key);
      if (path.length === 0) {
        continue;
      }
      try {
        const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
        let dataUrl: string = '';
        try {
          const stat: fs.Stat = fs.statSync(path);
          const buf: ArrayBuffer = new ArrayBuffer(stat.size);
          const n: number = fs.readSync(file.fd, buf);
          if (n > 0) {
            const b64: string = new util.Base64Helper()
              .encodeToStringSync(new Uint8Array(buf, 0, n));
            dataUrl = 'data:image/png;base64,' + b64;
          }
        } finally {
          try {
            fs.closeSync(file);
          } catch (closeErr) {
          }
        }
        if (dataUrl.length > 0) {
          return dataUrl;
        }
      } catch (err) {
        // 读失败 → 试下一个变体
      }
    }
    return '';
  }

  static srcPath(ctx: common.UIAbilityContext, key: string): string {
    const hit: string | undefined = ChartCache.uriMemo.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const p: string = ChartCache.path(ctx, key);
    let uri: string = p.length > 0 ? 'file://' + p : '';
    // **读取侧的尺寸口径自检**：这张图与 .dim 对不上 = 池子"拍早了"的旧表面，
    // 当"没有缓存"处理 → 正文回落实时 Web（显示的是对的图）。见 dimMatchesPixels。
    if (uri.length > 0 && !ChartCache.dimMatchesPixels(ctx, key, p)) {
      uri = '';
    }
    // 与 path() 同一口径：**空结果不进缓存**（否则导出轮询等补烘时读到的是旧答案，
    // 见 path() 的说明）
    if (uri.length > 0) {
      ChartCache.uriMemo.set(key, uri);
    }
    return uri;
  }

  /**
   * 缓存图与 `.dim` 是不是**同一个尺寸口径**（只读 PNG 头 24 字节，不解码像素）。
   *
   * 像素尺寸应当 = 逻辑尺寸 × 屏幕密度，横纵同一个倍数。预渲染池曾经拍到"组件还没
   * 按新回传高度重排"的那一帧：像素是 365×100，`.dim` 却记 365×319 —— 正文按 .dim
   * 撑框 + Contain 显示，图就缩成卡片中间一条，而且**重开文档也不会恢复**
   * （用户实测"卡片第一次渲染大小异常，要点一次刷新才正常"；设备取证 1592 张里 24 张中招）。
   * 写入侧的守卫在 ChartRenderPool.staleSnapshot，这里是**读取侧的第二道**：
   * 用户机上那批已经落盘的坏图，不升键、不清缓存也不会再被显示出来。
   */
  private static dimMatchesPixels(ctx: common.UIAbilityContext, key: string, pngPath: string): boolean {
    const dim: string = ChartCache.dimOf(ctx, key);
    if (dim.length === 0) {
      return true;
    }
    const bar: number = dim.indexOf('|');
    const dw: number = Number(dim.substring(0, bar));
    const dh: number = Number(dim.substring(bar + 1));
    if (bar <= 0 || !(dw > 0) || !(dh > 0)) {
      return true;
    }
    try {
      const file: fs.File = fs.openSync(pngPath, fs.OpenMode.READ_ONLY);
      let buf: ArrayBuffer = new ArrayBuffer(24);
      let n: number = 0;
      try {
        n = fs.readSync(file.fd, buf);
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
      if (n < 24) {
        return true;
      }
      const b: Uint8Array = new Uint8Array(buf);
      // PNG 的 IHDR 固定紧跟签名：宽高是大端 4 字节，位于第 16 / 20 字节
      const pw: number = ((b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19]) >>> 0;
      const ph: number = ((b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23]) >>> 0;
      if (pw <= 0 || ph <= 0) {
        return true;
      }
      const rx: number = pw / dw;
      const ry: number = ph / dh;
      // 容差取"半个密度倍"：重排一帧的误差远大于此，取整误差只有 1px
      return Math.abs(rx - ry) <= Math.max(0.5, rx * 0.2);
    } catch (err) {
      return true;
    }
  }

  /**
   * 把渲染完成的 PixelMap 存成 PNG 并登记。失败返回空串。
   *
   * w/h（可选）：页面的**逻辑尺寸**（css px = vp，DiagramWeb 的 postWidth/Height
   * 回传值）。传入时写 `<key>.dim` sidecar——显示端据此**按自然尺寸 + 横向滚动**
   * 展示超宽公式（"卡片内左右滑动、不限制大小"），不再被 objectFit.Contain
   * 压扁成"全部重叠到一起"（用户实测）。
   *
   * trim（可选，2026-10-16）：**落盘前裁到内容边界**——与「手动下载」出的图同款
   * （trimPng：裁掉四周空白 + 留 12px 呼吸边）。池子烘的图供正文 / 导出 / 打印
   * 共用，用户实测反馈"打印的 html 里，公式块、图表不是手动下载的样式"——
   * 现在从烘焙源头统一成"下载样式"（配合池子 DiagramWeb 的 dl:true 直角形态）。
   * 裁后 .dim 按"像素比例"折算（逻辑尺寸跟着内容边界缩）。
   */
  static async save(ctx: common.UIAbilityContext, key: string, pixel: image.PixelMap,
                    w: number = 0, h: number = 0, trim: boolean = false): Promise<string> {
    try {
      const dir: string = ctx.cacheDir + '/charts';
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const packer: image.ImagePacker = image.createImagePacker();
      let bytes: ArrayBuffer = await packer.packToData(pixel, { format: 'image/png', quality: 100 });
      if (trim) {
        try {
          const cut: ArrayBuffer = await ChartCache.trimPng(bytes);
          if (cut.byteLength > 0 && cut.byteLength !== bytes.byteLength) {
            bytes = cut;
          }
        } catch (cutErr) {
          // 裁边失败按原图存（宁可多一圈白边，不能丢图）
        }
      }
      /**
       * **逻辑尺寸一律由"落盘像素 ÷ 屏幕密度"反推**，不再用页面回传的 w/h 折算。
       *
       * 设备取证（533 张）：44 张的 `.dim` 两轴倍数不一致，最狠的一张像素 1278×1092
       * （= 365×312vp）而 `.dim` 记 365|75 —— 因为它是拿"页面某一刻回传的高度"
       * 折算出来的，那一拍的高度报告滞后于真实重排。正文按 `.dim` 给 Image 定框，
       * 312vp 的图被塞进 75vp 的框里 = 用户看到的"挤在一起"。
       * 像素是**唯一不会说谎的那一份**：图就是这么高，除以密度就是它该显示的 vp 尺寸，
       * 与回传时机再无关系，两轴倍数天然自洽（读取侧的 dimMatchesPixels 也再不会误判）。
       */
      let wOut: number = 0;
      let hOut: number = 0;
      try {
        const dens: number = display.getDefaultDisplaySync().densityPixels;
        const src3: image.ImageSource = image.createImageSource(bytes);
        const pm3: image.PixelMap = await src3.createPixelMap();
        const info3: image.ImageInfo = await pm3.getImageInfo();
        if (dens > 0 && info3.size.width > 0 && info3.size.height > 0) {
          wOut = Math.round(info3.size.width / dens);
          hOut = Math.round(info3.size.height / dens);
        }
        src3.release();
        pm3.release();
      } catch (dimErr) {
        // 密度取不到才退回回传值（有总比没有好）
        wOut = w;
        hOut = h;
      }
      const p: string = dir + '/' + key + '.png';
      const file: fs.File = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes);
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
      ChartCache.memo.set(key, p);
      // **同步刷新 URI 缓存**：图就绪前若已查询过 srcPath（缓存里是空串），
      // 这里必须换新——否则图生成了、组件仍拿到空源（持续空白）
      ChartCache.uriMemo.set(key, 'file://' + p);
      // 逻辑尺寸 sidecar（与 savePngBase64 同款；重启后显示端仍能取到）
      if (wOut > 0 && hOut > 0) {
        ChartCache.setDim(key, wOut, hOut);
        try {
          const dim: string = Math.round(wOut) + '|' + Math.round(hOut);
          const dp: string = dir + '/' + key + '.dim';
          const df: fs.File = fs.openSync(dp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          try {
            fs.writeSync(df.fd, new util.TextEncoder().encodeInto(dim).buffer as ArrayBuffer);
          } finally {
            try {
              fs.closeSync(df);
            } catch (e2) {
              // sidecar 写失败：内存仍有效（本次会话）
            }
          }
        } catch (err2) {
          // 忽略
        }
      }
      return p;
    } catch (err) {
      return '';
    }
  }
}
