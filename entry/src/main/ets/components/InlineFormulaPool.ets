/**
 * 澄笺 · 行内公式图生成池（MathJax → SVG → PNG）
 * =================================================
 *
 * 行内公式在 Text 流里只能以 ImageSpan 呈现（必须是一张"图"）。旧方案把公式
 * 排版在 Web 里、再靠系统快照（webPageSnapshot）抠像素——链路上有快照时机、
 * 全量绘制、透明度合成、像素密度等一串平台不确定点，真机上连续多轮没有稳定
 * 产出过可用的图。
 *
 * 新方案（开源生态的标准做法，与桌面完全可验证）：
 *   内置 MathJax（tex-svg-full）把 TeX **排版成 SVG** → 在浏览器内用 canvas
 *   **光栅化成 PNG** → PNG dataURL 经 javaScriptProxy（postPng）回调交回
 *   ArkTS 落盘 —— 全链路只用 Web 标准能力，零系统渲染 API：
 *     · 一个 Web 实例处理全部公式（不再每张图一个 Web）
 *     · 不依赖"可见性 / 组件尺寸 / 截图"，宿主 1×1 隐形即可（排版发生在
 *       页面内 -9999px 的离屏容器里，光栅化在 canvas 里）
 *     · 输出 PNG 与图标/封面走同一条加载路径（`file://` 前缀）
 *     · 字体随 SVG 字形内嵌、光栅化时用系统字体渲染文本（中文 \text 正常）
 *
 * 失败（超时 / MathJax 报错 / 桥回调异常）记入会话内失败集，正文回落线性化
 * 文本（绝不空白）。
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { ChartCache } from '../service/ChartCache';
import { FormulaTask } from '../markdown/FormulaTasks';

/** 页面 postPng 回传的消息（字段名与 mjformula-page.js 的 result() 对齐） */
interface FormulaPngMsg {
  id: string;
  ok: boolean;
  png: string;
  w: number;
  h: number;
  err: string;
}

@Component
export struct InlineFormulaPool {
  /** 待生成任务清单（宿主在文档加载后生成；已缓存 / 已失败的会被跳过） */
  @Prop @Watch('pump') tasks: FormulaTask[] = [];
  /**
   * 深浅色：决定公式字形颜色（深色主题用浅色墨——PNG 不透明黑字在深色底上
   * 会看不见）。参与缓存键（inlineKey 含 dark），切换主题自动重生成。
   */
  @Prop dark: boolean = false;
  /** 每完成（或失败跳过）一张回调一次：宿主刷新正文把线性化文本换成公式图 */
  onOneDone: () => void = () => {
  };

  private ctrl: webview.WebviewController = new webview.WebviewController();
  private b64: util.Base64Helper = new util.Base64Helper();
  private ctx: common.UIAbilityContext | null = null;
  /** 当前正在生成的任务 */
  private current: FormulaTask | null = null;
  private busyRendering: boolean = false;
  /** 会话内失败集（同一缺陷不重试，防止队列死循环） */
  private failed: Set<string> = new Set();
  /** mjformula.html 初始化完成（postReady）之前不派发任务 */
  private makerReady: boolean = false;
  /** 单任务超时兜底（桥回调迟迟不来时不至于卡死队列） */
  private waitTimer: number = -1;

  aboutToAppear(): void {
    // 页面可能已经就绪（或稍后 postReady 再触发），这里先试一次
    this.pump();
  }

  private hostCtx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  private pump(): void {
    if (this.busyRendering || !this.makerReady) {
      return;
    }
    const c: common.UIAbilityContext | null = this.hostCtx();
    if (c === null) {
      return;
    }
    this.ctx = c;
    for (let k = 0; k < this.tasks.length; k++) {
      const t: FormulaTask = this.tasks[k];
      if (ChartCache.path(c, t.key).length > 0 || this.failed.has(t.key)) {
        continue;
      }
      this.current = t;
      this.busyRendering = true;
      this.runTask(t);
      return;
    }
    // 全部就绪
    this.current = null;
  }

  private runTask(t: FormulaTask): void {
    if (this.waitTimer >= 0) {
      clearTimeout(this.waitTimer);
    }
    this.waitTimer = setTimeout(() => {
      this.waitTimer = -1;
      const cur: FormulaTask | null = this.current;
      if (cur !== null && this.busyRendering) {
        // 回调超时：跳过这张，队列继续
        this.failed.add(cur.key);
        this.finishOne(cur);
      }
    }, 20000);
    // 源码以 base64(UTF-8) 传递，规避引号/换行/反斜杠的脚本转义问题；
    // 末参 = 字形颜色（深色主题浅墨，与 katex.html 的 body.dark 同色系）
    const ink: string = this.dark ? '#ECEFF4' : '#1A1A1A';
    const texB64: string = this.b64.encodeToStringSync(new util.TextEncoder().encodeInto(t.latex));
    try {
      this.ctrl.runJavaScript('window.tex2png("' + t.key + '","' + texB64 + '",0,' + t.size + ',"' + ink + '");');
    } catch (err) {
      this.failed.add(t.key);
      this.finishOne(t);
    }
  }

  /** 页面回调（javaScriptProxy.postPng）：{id, ok, png, w, h, err} */
  private onPng(json: string): void {
    const cur: FormulaTask | null = this.current;
    const c: common.UIAbilityContext | null = this.ctx;
    if (cur === null || c === null || !this.busyRendering) {
      return;
    }
    if (this.waitTimer >= 0) {
      clearTimeout(this.waitTimer);
      this.waitTimer = -1;
    }
    let ok: boolean = false;
    try {
      const msg: FormulaPngMsg = JSON.parse(json) as FormulaPngMsg;
      // **归属校验**：迟到的回调（上一任务才回来）直接丢弃
      if (msg.id !== cur.key) {
        return;
      }
      if (msg.ok && msg.png.length > 0) {
        // w/h = 渲染时的逻辑尺寸（显示端显式设 vp 宽高；像素保持高清）
        ok = ChartCache.savePngBase64(c, cur.key, msg.png, msg.w, msg.h);
      }
    } catch (err) {
      ok = false;
    }
    if (!ok) {
      this.failed.add(cur.key);
    }
    this.finishOne(cur);
  }

  private finishOne(t: FormulaTask): void {
    if (this.waitTimer >= 0) {
      clearTimeout(this.waitTimer);
      this.waitTimer = -1;
    }
    this.busyRendering = false;
    this.current = null;
    this.onOneDone();
    this.pump();
  }

  build() {
    // **1×1 隐形挂点**：只需要一个 JS 引擎宿主——排版发生在页面内离屏容器
    // （#mhold，-9999px），光栅化在 canvas。与旧的"快照方案"的根本区别：
    // 不依赖任何可见绘制 / 组件尺寸 / 系统截图能力。
    Web({ src: $rawfile('render/mjformula.html'), controller: this.ctrl })
      .width(1)
      .height(1)
      .hitTestBehavior(HitTestMode.None)
      .javaScriptProxy({
        object: {
          postReady: () => {
            this.makerReady = true;
            this.pump();
          },
          postPng: (json: string) => {
            this.onPng(json);
          }
        },
        name: 'arkHost',
        methodList: ['postReady', 'postPng'],
        controller: this.ctrl
      })
      .backgroundColor(Color.Transparent)
  }
}
