/**
 * 澄笺 · 开源库图表渲染容器（DiagramWeb）
 * ========================================
 *
 * 用 ArkUI Web 组件加载 rawfile/render/<mode>.html（库已内联，完全离线），
 * onPageEnd 后把源码 JSON 注入 window.renderPayload，页面渲染完成后通过
 * javaScriptProxy(arkHost.postHeight) 把真实高度回传，组件高度自适应。
 *
 * mode: katex | mermaid | echarts | abc | graphviz | flowchart
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
   * 页面内容缩放（0.5~3，body.style.zoom）：放大浮层的 ± 按钮用。
   * @Prop 变化时通过 @Watch 应用到已加载的页面。
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
  @Prop cardBg: string = '';
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

  build() {
    Web({ src: $rawfile('render/' + this.mode + '.html'), controller: this.ctrl })
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
        this.injectZoomHelper();
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
      vw: this.inlineMode ? 0 : this.virtualWidth, inline: this.inlineMode
    });
    try {
      this.ctrl.runJavaScript('window.renderPayload(' + json + ');');
      // 渲染注入后立刻应用一次缩放（之后由 @Watch 跟随 ± 按钮变化）
      this.applyZoomJs();
    } catch (err) {
      // 注入失败时页面保持空白高度，不影响正文
    }
  }

  /**
   * 注入**通用缩放助手** `window.applyZoom(z)`（每次页面加载后注入一次）。
   *
   * ⚠️ 为什么不用 `document.body.style.zoom` 一刀切：**`width:100%` 的 SVG**
   * （mermaid/graphviz 等 fit 模式）在 body.zoom 下方向不可控——桌面实测
   * zoom 1.25 时 SVG 视觉宽度 385→380 **反而变小**（真机用户实测"加号减号
   * 功能反了"）。fit 场景改为直接把 SVG 宽度设为 `100*z%`（纯宽度缩放，
   * 任何内核方向都可预期：>100% 溢出可平移，<100% 完整显示）；
   * 非 SVG 模板（代码 / 网页预览 / katex 文本）退回 body.zoom（方向正确）。
   * 选择器覆盖 `#app > svg` 与 `#app > div > svg`（markmap 的 svg 包在 div 里）；
   * katex 的装饰 svg 深嵌套不会命中 → 走 body.zoom（文本方向正确）。
   */
  private injectZoomHelper(): void {
    try {
      this.ctrl.runJavaScript(
        'window.applyZoom=function(z){try{var app=document.getElementById("app");' +
        'if(app){app.style.overflow="auto";}' +
        'var sv=app?(app.querySelector(":scope > svg")||app.querySelector(":scope > div > svg")):null;' +
        'if(sv){sv.style.width=(100*z)+"%";sv.style.maxWidth="none";sv.style.height="auto";}' +
        'else{document.body.style.zoom=z;}}catch(e){document.body.style.zoom=z;}};');
    } catch (err) {
      // 页面未就绪：忽略（onPageEnd 会再注入）
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

  /** webZoom 变化时把缩放应用到页面（body.style.zoom），并让页面重新自适应。 */
  private applyWebZoom(): void {
    if (!this.fillHeight) {
      return;
    }
    this.applyZoomJs();
  }

  /**
   * 把缩放应用到页面：走 `window.applyZoom(z)` 助手（onPageEnd 注入）——
   * **SVG(width:100%) 模板直接缩放 SVG 宽度**（body.zoom 方向在真机不可控，
   * 用户实测"加号减号功能反了"），非 SVG 模板退回 body.zoom（方向正确）。
   *
   * **这里刻意不调用 refit()**：refit 走的是"让图表铺满可用宽度"的自适应，
   * 缩放后可用空间相对变大 → fit 会把内容重新拉满 → 缩放效果被抵消，用户看到
   * 的正好相反（点减号反而变大、点加号反而变小 —— 用户实测反馈）。
   * 需要 refit 的场合（旋转、打开、恢复）另走 refitRequest。
   */
  private applyZoomJs(): void {
    try {
      this.ctrl.runJavaScript(
        '(function(){var f=window.applyZoom;if(f){f(' + this.webZoom + ');}' +
        'else{document.body.style.zoom=' + this.webZoom + ';}})()');
    } catch (err) {
      // 页面未就绪时忽略（onPageEnd 后会再应用一次）
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
      this.ctrl.loadUrl('resource://rawfile/render/' + this.mode + '.html');
    } catch (err) {
      // 页面未就绪：忽略
    }
  }

  /** 重新自适应（旋转 / 尺寸互换后调用）。 */
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
    // **延迟 120ms 再拍**：刚回传高度时，行内模式的 Web 表面可能还在
    // 「回传宽度 → 组件变宽 → 页面重排 → 再回传」的调整中——立即抓会拍到
    // 内容挤在左侧的宽图。延迟窗口内任务若已切换（webId 变化），放弃本次。
    const capturedId: string = this.webId;
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
    }, 120);
  }
}
