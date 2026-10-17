/**
 * 澄笺 · 开源库图表渲染容器（DiagramWeb）
 * ========================================
 *
 * 用 ArkUI Web 组件加载 rawfile/render/<mode>.html（库已内联，完全离线），
 * onPageEnd 后把源码 JSON 注入 window.renderPayload，页面渲染完成后通过
 * javaScriptProxy(arkHost.postHeight) 把真实高度回传，组件高度自适应。
 *
 * mode: katex | mermaid | zenuml | echarts | abc | graphviz | flowchart | plantuml
 *
 * 两条快照通道（都是 `webPageSnapshot`，抓的是**整页绘制结果**、不受可视区限制）：
 *   · 后台烘焙池（ChartRenderPool）：正文卡片的缓存图，尺寸 = 卡片宽 × 内容高；
 *   · 下载导出（DiagramDownloadHost）：**独立的、不被任何容器裁剪的**渲染表面，
 *     浅色白底 + 自然尺寸，尺寸稳定后抓一份完整图给用户存文件（见 dl / dlZoom /
 *     layoutTick / onSizeReady 四个下载专用属性）。
 *
 * **rawfile 资源分区说明**（体积敏感，勿混放）：
 *   · render/        —— 离屏渲染模板（库**已内联**进 html，整目录只被本组件加载；
 *                       原 render/lib/ 12MB 源库文件与模板零引用，已剔除瘦身）
 *   · runtimes/      —— 导出 HTML 时的**外部库拷贝**（ChartRuntimeService 打包进
 *                       导出产物，与 render/ 内联副本互不替代，两套都要保留）
 *   · builtin/       —— 预置文档与示例（DocStore 启动拷贝）
 */

import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';

@Component
export struct DiagramWeb {
  /** 渲染模板名（对应 rawfile/render/<mode>.html） */
  @Prop @Watch('onModeChanged') mode: string = 'mermaid';
  /**
   * 源码（公式 LaTeX / 图表源码 / echarts JSON）。
   *
   * ⚠️ **必须带 @Watch 重注入**（后台预渲染池的连续任务靠它推进）：
   * 池子串行渲染多个任务时，**组件会被 ArkUI 复用**（同 if 分支、同组件类型），
   * Web 页面不会重新加载（`src` 属性变化不触发重载——mode 变化的场景已由
   * onModeChanged 的 loadUrl 处理，但**同 mode 的连续任务**（如连续多个 katex
   * 公式）此前完全没有刷新通道：页面停在上一个公式 → 不再回传高度 → 池子卡死，
   * 第二个任务起全部渲染不出（用户实测：除第一个外所有行内公式都不出图）。
   * 这里在 payload 变化时用 runJavaScript 把新 payload 注入已加载的页面
   * （模板各页面的 renderPayload 都是幂等的：清空容器 → 重新渲染 → 重新回传）。
   */
  @Prop @Watch('onPayloadChanged') payload: string = '';
  /**
   * **宿主排好版的富文本**（目前只有「代码块放大」用）。
   *
   * 为什么把 HTML 传进来、而不是把语言 id 丢给页面自己高亮：正文卡片的代码颜色
   * 是 ArkUI `Span` + `CodeHighlighter` 分的词（`MdView.codeView`），渲染模板里
   * 再写一份分词器必然与卡片走偏（同一份代码两处颜色不同）。这里复用
   * `MdViewUtil.highlightToHtml` 生成带色 HTML，浮层与卡片**逐 token 一致**。
   * 留空 = 模板按纯文本渲染（图表源码、无高亮语言的情况）。
   */
  @Prop @Watch('onPayloadChanged') richHtml: string = '';
  /**
   * 需要整行高亮的行号（1 起，逗号分隔，如 `1,3-5` 展开后的 `1,3,4,5`）。
   * 来自围栏元数据 `js{1,3-5}`：正文卡片按 `block.hlLines` 铺行底色，浮层是 Web，
   * 不把这份信息传下去，**一放大高亮就没了**（用户实测）。模板据此给对应 `<tr>` 加 class。
   */
  @Prop @Watch('onPayloadChanged') hlLines: string = '';
  /** 暗色模式（传给页面切主题） */
  @Prop dark: boolean = false;
  /** 允许双指缩放（放大浮层用；行内卡片关闭以免劫持页面滚动） */
  @Prop zoom: boolean = false;
  /** 撑满容器宽（放大浮层用：mermaid/markmap 自适应放大） */
  @Prop fit: boolean = false;
  /** 虚拟画布宽（CSS px）。>0 时页面按此宽度渲染，图表与文字真的变大，外层滚动平移 */
  @Prop virtualWidth: number = 0;
  /**
   * **撑满父容器高度并关闭高度回传**（放大浮层的 markmap 用）。
   * 脑图此前漂移的根因：postHeight 回传 → 组件高度变化 → 页面 80vh 跟着变 →
   * markmap autoFit 再次重排，来回触发"缩小 + 漂移"。撑满模式直接填满可视区，
   * 主体由 markmap fit 居中，拖动范围即可视区。
   */
  @Prop fillHeight: boolean = false;
  /**
   * 页面缩放倍率（放大浮层的 ± 按钮用）。
   *
   * ⚠️ 落地方式是**引擎级页面缩放** `WebviewController.zoom()`，不是往页面里
   * 塞 CSS：此前用「把 SVG 宽度改成 100*z%」的写法，对 `width:100%` 的图表
   * 只会横向拉伸（用户实测"点放大内容变成左右移动"），而引擎缩放对 SVG /
   * canvas / 代码 / 网页预览一律横纵等比，并且和双指捏合是同一套比例，
   * 两种操作可以叠加而不会互相打架。
   * zoom() 收的是**相对**增量，所以内部记着上次下发的倍率来换算增量。
   */
  @Prop @Watch('applyWebZoom') webZoom: number = 1;
  /** 渲染高度（vp），由页面回传 */
  @State hVp: number = 100;
  /** **行内公式模式**：按内容自身尺寸渲染（供正文 ImageSpan 内联），宽度跟随回传 */
  @Prop inlineMode: boolean = false;
  /** 行内公式内容宽度（vp），由页面回传 */
  @State wVp: number = 0;
  /**
   * 卡片底色（十六进制）：**快照用途**（后台池预渲染）必须传——
   * webPageSnapshot 产物不含 alpha，「透明」会被合成成黑色，存下的公式图
   * 就是黑底（用户实测"黑屏"）。渲染时铺上该底色，与正文卡片一致。
   * 纯展示场景（放大浮层）留空即可。
   */
  @Prop @Watch('onPayloadChanged') cardBg: string = '';
  /** 触摸上报：双指落在图表上时通知页面抑制根级捏合（改字号） */
  onWebTouch: (down: boolean) => void = () => {
  };
  /**
   * **图表渲染完成信号**：页面首次回传高度时触发（postHeight 即渲染完成的
   * 副产品）。后台预渲染池用它把握截图时机。
   */
  onHeightReady: (h: number) => void = () => {
  };
  /**
   * 本 Web 的组件 id（后台预渲染池用 `webPageSnapshot({ id })` 按组件 id
   * 抓整页绘制结果；id 由池子传入）。
   */
  @Prop webId: string = '';
  /**
   * 截图请求计数：池子在高度回传后递增，@Watch 触发整页快照。
   * 用计数而不是布尔——连续任务每次递增都能触发一次。
   */
  @Prop @Watch('doCapture') captureRequest: number = 0;
  /** 整页快照产物（imagePixelMap）回传给池子入库 */
  /** 快照完成回调：pixel + 页面**逻辑尺寸**（css px = vp，写入 .dim sidecar 供显示端按自然尺寸展示） */
  onCaptured: (pixel: image.PixelMap, w: number, h: number) => void = () => {
  };
  /**
   * 重新自适应请求计数（放大浮层**旋转**后调用）：旋转只改外层角度、不会让
   * 页面重新布局 → 内容仍按旧宽高排布，看起来"变小了"（用户反馈）。
   * 递增即让页面 refit（mermaid/markmap/svg 按新容器重新适配）。
   */
  @Prop @Watch('doRefit') refitRequest: number = 0;
  /**
   * **导出形态**（下载独立渲染通道用）：页面按"这张图是要存成文件的"渲染 ——
   * 底色层去掉 14px 圆角与内描边（卡片形态的圆角在快照里会变成四角发黑、
   * 四周一圈灰边），其余与浏览形态一致。
   */
  @Prop @Watch('onPayloadChanged') dl: boolean = false;
  /**
   * **导出超宽适配倍率**（CSS zoom，(0,1] 生效，0 = 不缩放）。
   * 公式是"按排版尺寸画出来、宽了就横向滚动"的（katex 模板 overflow:auto），
   * 纵向可长、横向不会自动缩 —— 比画布宽的那部分在快照里根本不存在。
   * 这里按 `画布宽 ÷ 内容宽` 下发 CSS zoom：整幅等比缩进画面（横纵同步，
   * 不拉伸不挤压），要的正是"没显示在画布内的也要显示出来"。
   */
  @Prop @Watch('onPayloadChanged') dlZoom: number = 0;
  /**
   * **强制重新注入当前 payload**（计数）。
   * 下载链路的"宽度收敛"第二遍用：payload 字符串本身没变，@Watch 不会触发，
   * 需要一个独立的触发通道让页面按新的容器宽度重排一次。
   */
  @Prop @Watch('onPayloadChanged') layoutTick: number = 0;
  /**
   * **表面高度钉死**（vp，0 = 不钉）。
   * 脑图这类引擎**不回传自然高度**（它的画布就是容器：fit 形态下 `#app` 直接
   * `height:100vh`，回传的也只是容器高）——下载时若由它决定表面高度，表面会停在
   * 初始的 100vp 上，整张脑图被压成一条。宿主给个高度（放大时的画布高），
   * 脑图的 autoFit 就按这个画布铺满，与用户在浮层里看到的一致。
   */
  @Prop dlForceHeight: number = 0;
  /**
   * **尺寸双通道回调**（宽度 + 高度都到齐后宿主才决策）。
   * ⚠️ 模板回传顺序**不保证**（katex 先 postHeight 再 postWidth），单看某一次
   * 回调拿到的是"新高度 + 上一次的宽度"，所以两个通道都回调、由宿主去抖。
   */
  onSizeReady: (w: number, h: number) => void = () => {
  };

  /**
   * 卡片「刷新」请求计数（用户要求）：递增 → **整页重载**。
   * 重载后 onPageEnd 会用最新 payload 重新注入，等于把这张图从头画一遍。
   */
  @Prop @Watch('doReload') reloadRequest: number = 0;
  private ctrl: webview.WebviewController = new webview.WebviewController();
  /** 页面是否已加载完成（onPageEnd 之后才允许 payload 热注入） */
  private webReady: boolean = false;
  /**
   * 页面最近回传的**内容逻辑尺寸**（css px = vp）。任何模式都记录：
   * 快照完成时随 PixelMap 一起交给池子写 .dim sidecar——显示端对超宽公式
   * 按"自然尺寸 + 横向滚动"展示（用户要求：卡片内左右滑动、不限制大小）。
   */
  private lastPostW: number = 0;
  private lastPostH: number = 0;
  /**
   * 组件**实测布局宽度**（vp，onAreaChange 回报）。快照拍的就是这块表面，
   * 模板不回传宽度时用它当逻辑宽度，`.dim` 才不会缺（见 doCapture）。
   */
  private areaW: number = 0;
  /** 已下发给引擎的缩放倍率（zoom() 是相对增量，用它换算下一步的 factor） */
  private zoomApplied: number = 1;
  /** 正文卡片是否已经"出图后自动重载"过一次（每张卡一次，见 postWidth 里的说明） */
  private autoReloaded: boolean = false;
  /**
   * **正在切换模板页**（loadUrl 之后、onPageEnd 之前）：此窗口内的尺寸报告一律丢弃。
   *
   * ⚠️ 这是"跨页面串图"的闸门（2026-10-16 真机取证实锤）：池子复用同一个组件跑
   * 连续任务，切 mode（或刷新 / 切文档）时旧页面还挂在组件上渲染着 —— 组件尺寸一变，
   * **旧页面的 ResizeObserver 会以"新任务看起来合理的高度"回传**，池子信以为真、
   * 去抖后拍快照，就把**旧页面的内容**存进了**新任务的键**。实例：用户机上 wavedrom
   * 的键下存的是一张**另一个文档**的流程图（内容含 Pandoc，本文档没有这个词），
   * 且尺寸自洽（池子的 stale 检查按"像素/逻辑"两轴比较，完全测不出来）。
   * 闸门落下后池子只会收到**新页面自己的**回传，拍到的必然是它自己画的图。
   *
   * ⚠️ **保险丝（2026-10-16 补）**：闸门在个别路径下可能**没被 onPageEnd 解除**
   * （真机实锤：池子的 Web 加载成功 OnPageEnd 200、页面也渲染了，但后续尺寸报告
   * 全被这个标记吞掉 → 池子每 10 秒"等高度超时"→ 反复 loadUrl、一张图都烘不出）。
   * 所以拦截只在前 **6 秒**（`PAGE_LOAD_GUARD_MS`）内生效——超过就自动放行：
   * 串图窗口本来就只有 loadUrl 后到首绘的 ~1 秒，6 秒是安全上限；宁愿让极端情况下
   * 混一张旧图（有 stale 检查兜底重拍），**绝不能饿死整条烘图队列**。
   */
  private pageLoading: boolean = false;
  /** 闸门生效起点（loadUrl 时刻；配合 PAGE_LOAD_GUARD_MS 保险丝，见 pageLoading） */
  private pageLoadAt: number = 0;
  /**
   * 快照重试状态机（见 doCapture）：本轮已尝试拍次数 / 是否已成功回传产物 /
   * 已处理过的 captureRequest。池子的组件会被**连续任务复用**，所以必须按
   * 请求号归档 —— 新请求（captureRequest 变化）到来时重置前两项。
   */
  private capAttempt: number = 0;
  private capDelivered: boolean = false;
  /**
   * **注入号**：每次 injectPayload 自增，并同时写进页面 `window.__cjInj`。
   * 页面一 reload 这个全局就没了 → 快照前读回来一比，就知道表面上挂的是不是
   * 当前这份 payload（防串图，见 doCapture）。
   */
  private injectSeq: number = 0;
  private capReqSeen: number = -1;

  /**
   * 实际加载的模板名。脑图走 **markmap-card**（一份模板同时管正文卡片与放大浮层
   * 两种画布形态，由 renderPayload 的 fit 标志区分）。
   * ⚠️ 首载与热切换必须走同一个函数：此前 build 用 markmap-card、
   * onModeChanged 却 loadUrl('render/' + mode + '.html') 拼出 markmap.html，
   * 脑图「源码 ↔ 预览」来回切一次就落到另一份模板上，放大行为整个变样。
   */
  private renderTemplate(): string {
    // plantuml 用自己的模板 render/plantuml.html（离线内核 @plantuml/core，2026-10-14 起）；
    // 解析层只在**导出**时才桥成 mermaid，阅读侧不再复用 mermaid 模板
    return this.mode === 'markmap' ? 'markmap-card' : this.mode;
  }

  build() {
    // 脑图走 **markmap-card** 一份模板：正文卡片（fit=false，高度随脑图自然高度回传）
    // 与放大浮层（fit=true，整页撑满画布 + autoFit 铺满）由 renderPayload 的 fit
    // 标志分流；两种形态共用一个模板，才不会像此前那样在浮层里沿用卡片的
    // "按内容定高"，把脑图挤成画布顶部的一条（用户实测只剩四分之一）。
    Web({ src: $rawfile('render/' + this.renderTemplate() + '.html'), controller: this.ctrl })
      .id(this.webId.length > 0 ? this.webId : 'diagram_web')
      // 表面宽度：**必须钉死成确定值**，不能用 '100%'。后台池在转场 / 首帧那几百毫秒
      // 里被父容器量到一个极小的宽度（设备取证：状态图的内容只占了 365 里的 21vp），
      // mermaid 就按 21vp 重排 → 烘出一张窄条。下载链路一直是对的，正是因为它
      // `.width(surfaceW)` 钉死（见 DiagramDownloadHost.build）。
      // 内容比表面宽的图种（wavedrom 自然宽 560）由 dlZoom 等比缩进表面，
      // 两轴同一个倍率 → 只缩不拉，不会被切也不会变形。
      .width(this.inlineMode && this.wVp > 0 ? this.wVp : (this.virtualWidth > 0 ? this.virtualWidth : '100%'))
      .height(this.fillHeight ? '100%' : this.hVp)
      .javaScriptProxy({
        object: {
          postWidth: (w: number) => {
            // 页面切换窗口（loadUrl → onPageEnd）：旧页面残留报告丢弃；
            // **6 秒保险丝**——闸门万一没被 onPageEnd 解除也不能饿死队列（见 pageLoading）
            if (this.pageLoading && Date.now() - this.pageLoadAt < 6000) {
              return;
            }
            const v: number = typeof w === 'number' && !isNaN(w) && w > 0 ? Math.ceil(w) : 0;
            // **内容逻辑尺寸**（css px = vp）：任何模式都记录——快照链路把它写进
            // .dim sidecar，显示端据此对超宽公式"按自然尺寸 + 横向滚动"展示
            if (v > 0) {
              this.lastPostW = v;
            }
            // 下载链路的尺寸通道：宽度到了就先报到宿主，由它和高度去抖对齐
            this.onSizeReady(this.lastPostW, this.lastPostH);
            // **正文卡片出图后自动重载一次**（用户要求"加载出来后自动点一次刷新"，
            // 2026-10-17 明确要加回来）：首帧是卡片宽度还没稳定时就排好版画出来的，
            // 重载一遍才按最终宽度重排。后台预渲染池（带 webId）与放大浮层（zoom /
            // fillHeight 开）都不做——池子重载会和烘图竞速，浮层是用户主动放大的、
            // 不该自己动。
            // （曾试过"宽度没变就不重载"来省掉这一下，实测省不出可感知的流畅度，
            // 反而让一批卡片停在首帧排版上 —— 别再拿它做性能优化。）
            if (v > 0 && !this.autoReloaded && this.webId.length === 0
              && !this.zoom && !this.fillHeight) {
              this.autoReloaded = true;
              setTimeout(() => {
                this.doReload();
              }, 260);
            }
            if (!this.inlineMode) {
              return;
            }
            if (v > 0 && Math.abs(v - this.wVp) > 2) {
              this.wVp = v;
            }
          },
          postHeight: (h: number) => {
            // 页面切换窗口（loadUrl → onPageEnd）：旧页面残留报告丢弃；
            // **6 秒保险丝**——闸门万一没被 onPageEnd 解除也不能饿死队列（见 pageLoading）
            if (this.pageLoading && Date.now() - this.pageLoadAt < 6000) {
              return;
            }
            const v: number = typeof h === 'number' && !isNaN(h) ? h : 100;
            this.lastPostH = v;
            // 下载链路的尺寸通道（见 postWidth 同名调用）
            this.onSizeReady(this.lastPostW, this.lastPostH);
            /**
             * **所有正文卡片出图后都自动刷新一次**（用户要求：加载完成后刷新一次以
             * 调整显示大小）。以前这一枪只在 postWidth 里放，而 20 个模板只有 katex
             * 回传宽度 → 图表卡首帧按瞬时宽度排版后就一直不纠正。
             * 后台池（带 webId，会与烘图竞速）、放大浮层（zoom / fillHeight 用户主动
             * 放大的）、行内图都不做；高度 >60vp 才算"内容真的画出来了"。
             */
            if (!this.autoReloaded && this.webId.length === 0 && !this.zoom
              && !this.fillHeight && !this.inlineMode && v > 60) {
              this.autoReloaded = true;
              setTimeout(() => {
                this.doReload();
              }, 260);
            }
            // 撑满模式下**忽略高度回传**：回传会改变组件高度 → 页面 80vh 跟着变 →
            // markmap autoFit 再次重排（缩小 + 漂移的根源）
            if (this.fillHeight) {
              return;
            }
            // 下载链路：宿主钉死表面高度（脑图这类不回传自然高度的引擎用）。
            // 必须在下面的 floor/cap 之前拦下——钉死值是画布高，可能大于 56、
            // 也可能小于 4096，走正常钳制反而是对的，但语义上不该被 floor 改。
            if (this.dlForceHeight > 0) {
              this.hVp = this.dlForceHeight;
              this.onHeightReady(this.hVp);
              return;
            }
            // ⚠️ html 预览**保底 140vp**：若高度回传偏小/未回传，卡片会矮到与
            // 下一块内容视觉重叠（用户实测「两个卡片叠在一起」）。
            // ⚠️ 行内公式不能吃 56 的保底：公式图只有 ~30px 高，被抬到 56 会让
            // 每个行内公式图底部拖一条空白（基线发虚）。行内模式保底降到 16。
            const floor: number = this.mode === 'html' ? 140 : (this.inlineMode ? 16 : 56);
            // ⚠️ **高度上限按模式区分**：行内图 1200 足够；**块级图 4096**——
            // 旧上限 1200 会把高图（类图/大型流程图）的快照**拦腰截断**，显示端
            // Contain 把截断图当完整图展示 = "显示不完整"（用户实测：类图下半截丢失）。
            // 卡片要先直接展示全貌（用户要求），高图就让它完整长出来。
            const cap: number = this.inlineMode ? 1200 : 4096;
            this.hVp = Math.max(floor, Math.min(cap, v));
            this.onHeightReady(this.hVp);
          }
        },
        name: 'arkHost',
        methodList: ['postHeight', 'postWidth'],
        controller: this.ctrl
      })
      .onPageEnd(() => {
        // 新页面就绪：打开闸门（此后收到的报告才是新页面自己的，见 pageLoading）
        this.pageLoading = false;
        this.webReady = true;
        // 重新加载会把引擎页面比例打回 1：同步内部记账，再按当前 webZoom 补回去，
        // 否则「刷新 / 旋转」之后 ± 的档位与实际显示就对不上了
        this.zoomApplied = 1;
        this.applyWebZoom();
        this.injectPayload();
      })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.onWebTouch(true);
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.onWebTouch(false);
        }
      })
      .zoomAccess(this.zoom)
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const lw: Length = newValue.width;
        if (typeof lw === 'number' && lw > 0) {
          this.areaW = lw;
        }
      })
      .overScrollMode(OverScrollMode.NEVER)
      .backgroundColor(Color.Transparent)
  }

  /**
   * **payload 变化 → 把新源码热注入已加载的页面**（不重载 Web）：
   * 后台预渲染池连续任务的关键通道（见 payload 声明的注释）。各模板的
   * renderPayload 都是幂等的（清空容器 → 重新渲染 → 重新回传高度/宽度）。
   * 页面尚未加载完成时什么都不做 —— onPageEnd 会用**最新的 payload** 首注。
   */
  private onPayloadChanged(): void {
    if (!this.webReady || this.payload.length === 0) {
      return;
    }
    this.injectPayload();
  }

  /**
   * 把当前 payload 注入页面（首注与热注入共用；注入后重应用缩放）。
   * 每次注入递增 `injectSeq` 并把同号写进页面 —— 快照前用它核验"页面上确实是这一份"
   * （见 doCapture 的串图守卫）。号写在 renderPayload **之前**：模板自己抛错也不能把
   * 号丢掉，否则这一拍永远对不上、任务白等。
   */
  private injectPayload(): void {
    const json: string = JSON.stringify({
      src: this.payload, dark: this.dark, fit: this.fit, bg: this.cssColor(this.cardBg),
      vw: this.inlineMode ? 0 : this.virtualWidth, inline: this.inlineMode,
      html: this.richHtml,
      // 指定高亮行（围栏元数据 js{1,3-5}），1 起的行号 CSV；模板据此给整行铺底
      hl: this.hlLines,
      // 导出形态（见 dl / dlZoom 声明）：直角底、无内描边、超宽按 zoom 缩进画面
      dl: this.dl,
      z: this.dlZoom
    });
    this.injectSeq++;
    try {
      this.ctrl.runJavaScript('window.__cjInj=' + this.injectSeq
        + ';window.renderPayload(' + json + ');');
    } catch (err) {
      // 注入失败时页面保持空白高度，不影响正文
    }
    // **主动补报保险**（2026-10-16 真机实锤）：个别路径下模板的自动 report 一次没来
    // （页面加载 200、渲染也完成，但尺寸回传为 0）——池子等到 10s 超时、整条队列
    // 一张图都烘不出（反复 loadUrl）。注入后主动催两次，让页面重跑自己的 report()。
    // 模板的 report 是顶层 function（非 module 脚本），挂在 window 上可直接调用；
    // 多报无害（池子 / 宿主对连续报告都有去抖）。
    setTimeout(() => {
      this.nudgeReport();
    }, 600);
    setTimeout(() => {
      this.nudgeReport();
    }, 1600);
  }

  /** 催页面重跑 report()（见 injectPayload 的补报说明；页面未就绪时静默失败）。 */
  private nudgeReport(): void {
    try {
      this.ctrl.runJavaScript('try { if (typeof report === "function") { report(); } } catch (e) {}');
    } catch (err) {
      // 页面未就绪：忽略
    }
  }

  /**
   * ⚠️ **项目色值 #AARRGGBB → CSS rgba()**（进 Web 的颜色必须转换）：
   * CSS 的 8 位 hex 是 **#RRGGBBAA**——'#FF10131A' 会被解析成
   * "红 255 / 绿 16 / 蓝 26、10% 透明"的**红罩**，公式/图表卡片整卡发红
   * （用户实测截图实锤：烘焙出的 PNG 底色就是这个 10% 红罩叠黑的暗红）。
   * 与 Editor.cssColor 同源实现；cardBg 是唯一走 renderPayload 进 Web 的色值，
   * 在这里统一收口，所有渲染模板（katex/mermaid/…）同时生效。
   */
  private cssColor(appHex: string): string {
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

  /**
   * 把 webZoom 落到**引擎页面缩放**上。
   *
   * `WebviewController.zoom(factor)` 只收**相对**增量（1 = 不变，(0,100]），
   * 所以拿"目标倍率 ÷ 已应用倍率"换算；增量式还有个好处：与双指捏合共用同一
   * 个页面比例，捏合过之后再按 ± 是在当前基础上继续加减，不会跳回自己记的值。
   *
   * ⚠️ **这里刻意不调用 refit()**：refit 走的是"让图表铺满可用宽度"的自适应，
   * 缩放后可用空间相对变大 → fit 会把内容重新拉满 → 缩放效果被抵消，用户看到
   * 的正好相反（点减号反而变大、点加号反而变小 —— 用户实测反馈）。
   * 需要 refit 的场合（旋转、打开、恢复）另走 refitRequest。
   */
  private applyWebZoom(): void {
    const z: number = this.webZoom > 0 ? this.webZoom : 1;
    if (Math.abs(z / this.zoomApplied - 1) < 1e-6) {
      return;
    }
    const factor: number = z / this.zoomApplied;
    try {
      // zoomAccess 必须为 true，否则引擎直接忽略（17100004 Function not enabled）
      this.ctrl.zoom(factor);
      this.zoomApplied = z;
    } catch (err) {
      // 页面未就绪 / 组件尚未挂载：**记账保持不动**，下次变化会重试同一个增量
    }
  }

  /**
   * 「导出图片」：**先让页面把背景置为透明**（PNG 要透明底，用户要求），
   * 稍等重绘后整页快照，回传后再恢复页面背景。
   */
  /**
   * 切到 / 退出"完整内容模式"时，**主动让页面重新回传高度** ——
   * 页面早已加载完成，不会自动再 report()，不主动触发的话组件高度停在旧值，
   * 快照就会严重裁切（用户实测：导出图只剩顶部一小条）。
   */
  /**
   * **渲染形态切换（图表 ↔ 源码）时显式重载页面**。
   * ⚠️ 只改 @Prop `mode` 是不够的：Web 的初始 src 在创建时已固定，
   * 真机上不会因为属性变化自动重新加载 —— 用户实测"放大后点代码按钮，
   * 画面还是图表"。这里手动 loadUrl 到新模板，并等页面重新注入 payload。
   */
  private onModeChanged(): void {
    // 重载期间两道闸：不接受 payload 热注入（等新页面 onPageEnd 后统一首注）+
    // 丢弃旧页面的尺寸报告（防串图，见 pageLoading）
    this.webReady = false;
    this.pageLoading = true;
    this.pageLoadAt = Date.now();
    try {
      this.ctrl.loadUrl('resource://rawfile/render/' + this.renderTemplate() + '.html');
    } catch (err) {
      // 页面未就绪、压根没切换出去：把闸门恢复，别把正常报告全丢了
      this.pageLoading = false;
    }
  }

  /** 重新自适应（旋转 / 尺寸互换后调用）。 */
  /** 刷新：重载模板页（内容与尺寸由 onPageEnd → injectPayload 重新来一遍） */
  private doReload(): void {
    if (!this.webReady) {
      return;
    }
    this.webReady = false;
    this.zoomApplied = 1;
    // 同 onModeChanged：旧页面残留报告不进池子（见 pageLoading）
    this.pageLoading = true;
    this.pageLoadAt = Date.now();
    try {
      this.ctrl.loadUrl($rawfile('render/' + this.renderTemplate() + '.html'));
    } catch (e) {
      // 重载失败不拦后续（用户再点一次即可）
      this.webReady = true;
      this.pageLoading = false;
    }
  }

  private doRefit(): void {
    if (this.refitRequest <= 0) {
      return;
    }
    try {
      // ⚠️ **重载页面**而不是调 window.refit()：各模板的 refit 只重设 SVG 的 CSS
      // 宽度，对"图表按旧宽度画好、内容挤在一起"的情况**毫无作用**（用户实测刷新
      // 没反应）。refresh() 会重新走 onPageEnd → renderPayload，按**当前容器尺寸**
      // 完整重渲染，webZoom 也会在注入后重新应用 —— 这才是真正的"按当前比例刷新"。
      this.ctrl.refresh();
    } catch (err) {
      // 页面未就绪：忽略
    }
  }

  /**
   * **整页快照**（webPageSnapshot 抓 Web 的完整绘制结果，不受可视区限制）。
   * captureRequest 递增时触发。
   *
   * ⚠️ **被平台拒绝必须重试**（2026-10-16 真机实测定位）：Web 刚挂载、首帧还没
   * 合成时调 webPageSnapshot，平台直接回绝（底层日志 `Web is not painted ready
   * for snapshot`）——回调**不带产物**就结束了。此前单拍一次等兜底超时，整单
   * 必然以"生成失败"收场（用户实测）。现在被拒就隔一拍再拍，最多 5 拍
   * （累计约 3.5~5.3s，落在池子 4s / 下载宿主 6s 的兜底窗口内）；回调既不
   * 成功也不报错（被吞掉）时由看门狗推进下一拍。
   * 备注：内容高度回传只是"渲染到了一个稳定点"，不等于"首帧已合成"——
   * mermaid 真机首绘可晚到 1s 以上，多拍就是给这种慢首绘兜底。
   *
   * （块级公式曾试验"品红底 + 键控抠透明"——真机上透明 PNG 在 Image 组件里
   * 渲染不可靠（卡片全黑），已回退为**烘焙卡片底色**的不透明图。）
   */
  private doCapture(): void {
    if (this.captureRequest <= 0 || this.webId.length === 0) {
      return;
    }
    // 新一轮请求：重置重试状态（组件被连续任务复用时，按请求号归档）
    if (this.captureRequest !== this.capReqSeen) {
      this.capReqSeen = this.captureRequest;
      this.capAttempt = 0;
      this.capDelivered = false;
    }
    if (this.capDelivered || this.capAttempt >= 5) {
      return;
    }
    this.capAttempt++;
    const capturedId: string = this.webId;
    // **延迟再拍**：基础 250ms（组件高度是收到回传后**下一帧**才重排完的，
    // 120ms 抓到的还是旧内容留在旧表面上的那一帧，设备实测 29 张 mermaid 里
    // 21 张烘成了初始 100vp 的窄条，判据见 ChartRenderPool.staleSnapshot）；
    // **markmap 700ms**——脑图的 fit 在渲染后 350ms 才执行，拍早了抓到的是
    // fit 之前的原始布局（未缩放被裁切）。重试每一拍再递增 250ms。
    const wait: number = (this.mode === 'markmap' ? 700 : 250) + (this.capAttempt - 1) * 250;
    const myAttempt: number = this.capAttempt;
    setTimeout(() => {
      if (this.webId !== capturedId || this.capDelivered) {
        return;
      }
      // **先问页面"你手上是哪一份 payload"再拍**（2026-10-17 真机实锤）：韦恩图与
      // ZenUML 桥出来的时序图，两个不同键下落盘的是**同一张 Chart.js 图**（md5 逐字节
      // 相同）—— 模板页还没换成新 payload，旧内容仍挂在这块表面上，快照拍到旧帧；
      // 图本身完整、尺寸也自洽，所以池子的空白自检与 `.dim` 自检都拦不住，错图直接
      // 进缓存。注入时宿主往页面写一个自增号，页面一 reload 就被清空：号不对 = 这一拍
      // 拍的不是当前这张，作废、下一拍重来（重试次数与递增延时沿用上面那套）。
      const want: string = String(this.injectSeq);
      try {
        this.ctrl.runJavaScript('String(typeof window.__cjInj==="undefined"?0:window.__cjInj)',
          (jsErr: BusinessError, value: string) => {
            if (this.webId !== capturedId || this.capDelivered) {
              return;
            }
            const got: string = value.split('"').join('');
            if (jsErr !== undefined || got !== want) {
              this.doCapture();
              return;
            }
            this.takeSnapshot(capturedId, myAttempt);
          });
      } catch (err) {
        // 查询本身发不出去（控制器还没就绪）：同"被拒"，交给下一拍
        this.doCapture();
      }
    }, wait);
    // **看门狗**：回调既不成功也不报错（被平台吞掉）时推进下一拍。
    // 检查 attempt 归属：正常路径已推进过就不再重复派发。
    setTimeout(() => {
      if (this.webId !== capturedId || this.capDelivered || this.capAttempt !== myAttempt) {
        return;
      }
      this.doCapture();
    }, wait + 400);
  }

  /** 派发整页快照（doCapture 通过"页面里确实是这份 payload"的核验后才走到这里）。 */
  private takeSnapshot(capturedId: string, myAttempt: number): void {
    try {
      this.ctrl.webPageSnapshot({ id: capturedId },
        (err: BusinessError, result: webview.SnapshotResult) => {
          if (this.capDelivered || this.capAttempt !== myAttempt) {
            return;
          }
          if (err !== undefined || result === undefined
            || result.status !== true || result.imagePixelMap === undefined) {
            // 被拒（最常见：Web is not painted ready）→ 隔一拍再试
            this.doCapture();
            return;
          }
          this.capDelivered = true;
          // **快照归属的逻辑宽度**：模板自己回传的 postWidth 只有 katex 有，
          // 其余 19 个模板一律不回 → `.dim` 缺失，池子的"拍早了"守卫
          // （staleSnapshot）与读取侧的口径自检（dimMatchesPixels）双双失效，
          // 挤成窄条的坏图就这么落盘了（用户实测状态图 / C4 / 韦恩图三类）。
          // 没有回传时用**组件实测宽**顶上：快照拍的正是这块表面，
          // 两者同一口径，守卫这才真正对所有图种生效。
          const logicalW: number = this.lastPostW > 0 ? this.lastPostW : this.areaW;
          this.onCaptured(result.imagePixelMap, logicalW, this.lastPostH);
        });
    } catch (err) {
      // 快照接口异常同样按"被拒"处理，交给下一拍
      this.doCapture();
    }
  }
}
