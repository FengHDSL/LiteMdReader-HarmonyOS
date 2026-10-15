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
  /** 已下发给引擎的缩放倍率（zoom() 是相对增量，用它换算下一步的 factor） */
  private zoomApplied: number = 1;
  /** 正文卡片是否已经"出图后自动重载"过一次（每张卡一次，见 postWidth 里的说明） */
  private autoReloaded: boolean = false;

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
      .width(this.inlineMode && this.wVp > 0 ? this.wVp : (this.virtualWidth > 0 ? this.virtualWidth : '100%'))
      .height(this.fillHeight ? '100%' : this.hVp)
      .javaScriptProxy({
        object: {
          postWidth: (w: number) => {
            const v: number = typeof w === 'number' && !isNaN(w) && w > 0 ? Math.ceil(w) : 0;
            // **内容逻辑尺寸**（css px = vp）：任何模式都记录——快照链路把它写进
            // .dim sidecar，显示端据此对超宽公式"按自然尺寸 + 横向滚动"展示
            if (v > 0) {
              this.lastPostW = v;
            }
            // **正文卡片出图后自动重载一次**（用户要求"加载出来后自动点一次刷新"）：
            // 首帧是卡片宽度还没稳定时就排好版画出来的，重载一遍才按最终宽度重排。
            // 后台预渲染池（带 webId）与放大浮层（zoom / fillHeight 开）都不做——
            // 池子重载会和烘图竞速，浮层是用户主动放大的、不该自己动。
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
            const v: number = typeof h === 'number' && !isNaN(h) ? h : 100;
            this.lastPostH = v;
            // 撑满模式下**忽略高度回传**：回传会改变组件高度 → 页面 80vh 跟着变 →
            // markmap autoFit 再次重排（缩小 + 漂移的根源）
            if (this.fillHeight) {
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

  /** 把当前 payload 注入页面（首注与热注入共用；注入后重应用缩放）。 */
  private injectPayload(): void {
    const json: string = JSON.stringify({
      src: this.payload, dark: this.dark, fit: this.fit, bg: this.cssColor(this.cardBg),
      vw: this.inlineMode ? 0 : this.virtualWidth, inline: this.inlineMode,
      html: this.richHtml,
      // 指定高亮行（围栏元数据 js{1,3-5}），1 起的行号 CSV；模板据此给整行铺底
      hl: this.hlLines
    });
    try {
      this.ctrl.runJavaScript('window.renderPayload(' + json + ');');
    } catch (err) {
      // 注入失败时页面保持空白高度，不影响正文
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
    try {
      // 重载期间不接受 payload 热注入（等新页面 onPageEnd 后统一首注）
      this.webReady = false;
      this.ctrl.loadUrl('resource://rawfile/render/' + this.renderTemplate() + '.html');
    } catch (err) {
      // 页面未就绪：忽略
    }
  }

  /** 重新自适应（旋转 / 尺寸互换后调用）。 */
  /** 刷新：重载模板页（内容与尺寸由 onPageEnd → injectPayload 重新来一遍） */
  private doReload(): void {
    if (!this.webReady) {
      return;
    }
    try {
      this.webReady = false;
      this.zoomApplied = 1;
      this.ctrl.loadUrl($rawfile('render/' + this.renderTemplate() + '.html'));
    } catch (e) {
      // 重载失败不拦后续（用户再点一次即可）
      this.webReady = true;
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
   * captureRequest 递增时触发；失败静默——池子的 4s 超时会兜底跳过这张。
   * （块级公式曾试验"品红底 + 键控抠透明"——真机上透明 PNG 在 Image 组件里
   * 渲染不可靠（卡片全黑），已回退为**烘焙卡片底色**的不透明图。）
   */
  private doCapture(): void {
    if (this.captureRequest <= 0 || this.webId.length === 0) {
      return;
    }
    // **延迟再拍**：基础 120ms（行内模式的 Web 表面可能还在「回传宽度 → 组件变宽
    // → 页面重排」的调整中）；**markmap 700ms**——脑图的 fit 在渲染后 350ms 才执行，
    // 拍早了抓到的是 fit 之前的原始布局（未缩放被裁切 = "只有窄窄一条"，用户实测）。
    // 延迟窗口内任务若已切换（webId 变化），放弃本次（池子的 4s 超时仍兜底）。
    const capturedId: string = this.webId;
    // ⚠️ 默认 250ms（原来 120）：组件高度是收到回传后**下一帧**才重排完的，
    // 120ms 抓到的还是旧内容留在旧表面上的那一帧（设备实测：一篇文档 29 张
    // mermaid 里 21 张烘成了初始 100vp 的窄条，判据与兜底见 ChartRenderPool.staleSnapshot）
    const settle: number = this.mode === 'markmap' ? 700 : 250;
    setTimeout(() => {
      if (this.webId !== capturedId) {
        return;
      }
      try {
        this.ctrl.webPageSnapshot({ id: capturedId },
          (err: BusinessError, result: webview.SnapshotResult) => {
            if (err !== undefined || result === undefined
              || result.status !== true || result.imagePixelMap === undefined) {
              return;
            }
            this.onCaptured(result.imagePixelMap, this.lastPostW, this.lastPostH);
          });
      } catch (err) {
        // 快照接口异常：静默，池子超时兜底
      }
    }, settle);
  }
}
