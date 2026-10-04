/**
 * 澄笺 · 开源库图表渲染容器（DiagramWeb）
 * ========================================
 *
 * 用 ArkUI Web 组件加载 rawfile/render/<mode>.html（库已内联，完全离线），
 * onPageEnd 后把源码 JSON 注入 window.renderPayload，页面渲染完成后通过
 * javaScriptProxy(arkHost.postHeight) 把真实高度回传，组件高度自适应。
 *
 * mode: katex | mermaid | echarts | abc | graphviz | flowchart
 */

import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';

@Component
export struct DiagramWeb {
  /** 渲染模板名（对应 rawfile/render/<mode>.html） */
  @Prop mode: string = 'mermaid';
  /** 源码（公式 LaTeX / 图表源码 / echarts JSON） */
  @Prop payload: string = '';
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
  onCaptured: (pixel: image.PixelMap) => void = () => {
  };
  /**
   * 重新自适应请求计数（放大浮层**旋转**后调用）：旋转只改外层角度、不会让
   * 页面重新布局 → 内容仍按旧宽高排布，看起来"变小了"（用户反馈）。
   * 递增即让页面 refit（mermaid/markmap/svg 按新容器重新适配）。
   */
  @Prop @Watch('doRefit') refitRequest: number = 0;
  private ctrl: webview.WebviewController = new webview.WebviewController();

  build() {
    Web({ src: $rawfile('render/' + this.mode + '.html'), controller: this.ctrl })
      .id(this.webId.length > 0 ? this.webId : 'diagram_web')
      .width(this.virtualWidth > 0 ? this.virtualWidth : '100%')
      .height(this.fillHeight ? '100%' : this.hVp)
      .javaScriptProxy({
        object: {
          postHeight: (h: number) => {
            // 撑满模式下**忽略高度回传**：回传会改变组件高度 → 页面 80vh 跟着变 →
            // markmap autoFit 再次重排（缩小 + 漂移的根源）
            if (this.fillHeight) {
              return;
            }
            const v: number = typeof h === 'number' && !isNaN(h) ? h : 100;
            this.hVp = Math.max(56, Math.min(1200, v));
            this.onHeightReady(this.hVp);
          }
        },
        name: 'arkHost',
        methodList: ['postHeight'],
        controller: this.ctrl
      })
      .onPageEnd(() => {
        const json: string = JSON.stringify({ src: this.payload, dark: this.dark, fit: this.fit, vw: this.virtualWidth });
        try {
          this.ctrl.runJavaScript('window.renderPayload(' + json + ');');
          // 渲染注入后立刻应用一次缩放（之后由 @Watch 跟随 ± 按钮变化）
          this.applyZoomJs();
        } catch (err) {
          // 注入失败时页面保持空白高度，不影响正文
        }
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

  /** webZoom 变化时把缩放应用到页面（body.style.zoom），并让页面重新自适应。 */
  private applyWebZoom(): void {
    if (!this.fillHeight) {
      return;
    }
    this.applyZoomJs();
  }

  /**
   * 把缩放应用到页面（`body.style.zoom`）。
   *
   * **这里刻意不调用 refit()**：refit 走的是"让图表铺满可用宽度"的自适应，
   * 缩放后可用空间相对变大 → fit 会把内容重新拉满 → 缩放效果被抵消，用户看到
   * 的正好相反（点减号反而变大、点加号反而变小 —— 用户实测反馈）。
   * 需要 refit 的场合（旋转、打开、恢复）另走 refitRequest。
   */
  private applyZoomJs(): void {
    try {
      this.ctrl.runJavaScript('document.body.style.zoom=' + this.webZoom + ';');
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
   * **整页快照**（webPageSnapshot 抓 Web 的完整绘制结果，不受可视区限制——
   * 比 componentSnapshot 对 Web 表面可靠得多）。captureRequest 递增时触发；
   * 失败静默——池子的 4s 超时会兜底跳过这张。
   */
  private doCapture(): void {
    if (this.captureRequest <= 0 || this.webId.length === 0) {
      return;
    }
    try {
      this.ctrl.webPageSnapshot({ id: this.webId },
        (err: BusinessError, result: webview.SnapshotResult) => {
          if (err !== undefined || result === undefined
            || result.status !== true || result.imagePixelMap === undefined) {
            return;
          }
          this.onCaptured(result.imagePixelMap);
        });
    } catch (err) {
      // 快照接口异常：静默，池子超时兜底
    }
  }
}
