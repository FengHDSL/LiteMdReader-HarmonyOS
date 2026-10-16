/**
 * 澄笺 · 下载独立渲染宿主（DiagramDownloadHost）
 * ==============================================
 *
 * 放大浮层里点「下载」时，**另开一块渲染表面把这张公式 / 图表重画一遍再出图**，
 * 而不是去截屏幕上那块。这是与 v1~v4 那四版（都从可见表面截图）的本质区别。
 *
 * 为什么必须独立渲染（四次失败的教训）：
 *   · 浮层里的 Web 被画布容器 `.clip(true)` 裁着、高度被画布钉死 → 快照拿到的
 *     只有"看得见的那一块"，屏外内容永远出不来（用户实测"公式太宽太长被裁"）；
 *   · 那条路把时序全押在**屏幕上的那块表面**上：既要它渲染完成、又要用户没动它、
 *     还要在切浅色与截完之间不出岔子，本身就不稳（重渲染 + 2.5s 等待 + 恢复三次
 *     主题切换，每一次都可能被别的事件打断）。
 *
 * 这里的表面挂在**页面根 Stack 的独立一层**（与 ChartRenderPool 同一挂法）：
 * 不被任何容器裁剪、不吃触摸、近透明；宽度由本组件钉死为"放大时的画布宽"，
 * 高度由渲染页回传（内容自然高度）。于是四条要求各自落在机制上：
 *   · 下载时强制浅色背景 → dark=false + 白底（cardBg），与当前主题无关；
 *   · 长宽就是渲染内容的边界 → 高度取内容真实高度，宽度/空白由 trimPng 裁到包围盒；
 *   · 不要拉伸不要挤压 → 各引擎自己排版（fit=true 时 SVG 按视窗等比缩放），
 *     本组件只改容器尺寸、不做任何缩放；超宽公式走 dlZoom **等比**缩进画面；
 *   · 没显示在画布内的也要显示出来 → webPageSnapshot 抓的是**整页绘制结果**，
 *     不是可视区（同一接口在后台烘焙池里已稳定跑了多轮）。
 */

import { image } from '@kit.ImageKit';
import { DiagramWeb } from './DiagramWeb';

/** 一次下载渲染任务 */
export interface DlJob {
  /** 渲染模板名（katex / mermaid / …，与放大浮层的 enlargeMode 同源） */
  mode: string;
  /** 源码（LaTeX / 图表源码） */
  payload: string;
  /** 排版宽度（vp）= 放大浮层的画布宽：与用户当时看到的排版一致 */
  width: number;
  /** 表面高度（vp，>0 时钉死）：脑图这类"按容器自适应、不报自然高度"的引擎用 */
  forceHeight: number;
}

/** 画布宽的兜底（取不到画布尺寸时用；随便一个手机都是这个量级） */
const DL_FALLBACK_W: number = 360;
/** 表面宽度上下限（vp）：上限防"画布异常大"时开出一块超大表面 */
const DL_MIN_W: number = 160;
const DL_MAX_W: number = 2048;
/** 超宽适配的最小倍率：再宽也不缩过这个（否则字小到没意义，宁可缩到最小） */
const DL_MIN_ZOOM: number = 0.1;
/**
 * 表面高度上限（vp）——**必须与 DiagramWeb 里块级图的 4096 上限一致**：
 * 那边钳的是组件高度（= 快照能覆盖的范围），这边用它判断"内容高到装不下、
 * 该整体缩一档"。两处对不上就会出现"内容比表面高、底部整段丢失"。
 */
const DL_MAX_SURFACE_H: number = 4096;
/** 尺寸去抖：模板会连续回传（空报 / 渲染后 / 收敛后），等"最后一份 + 这段"再决策 */
const DL_SETTLE_MS: number = 420;
/** 等待安静的上限：ResizeObserver 一直在回传时（收敛过程不静）也要派发快照 */
const DL_MAX_QUIET_WAIT_MS: number = 3500;
/** 快照兜底：派发后这么久没有产物就失败（别把浮层永远卡在"生成中"） */
const DL_CAPTURE_GUARD_MS: number = 6000;
/** 总兜底：从挂载算起（Web 加载 + 渲染 + 两遍收敛 + 快照） */
const DL_HARD_TIMEOUT_MS: number = 18000;

/**
 * 下载链路的**收敛决策**（纯函数，无副作用）。
 *
 * 单独抽出来的原因：这是整条链路里唯一"算错就会出坏图"的地方（宽了要缩、
 * 高了要缩、能装下就别动），把它做成纯函数，校验脚本可以直接跑**真实实现**
 * （tools/sim-chart-download.js 按 `@Component` 截断本文件后 import 这个类），
 * 而不是在脚本里手抄一份口径 —— 手抄的口径永远会和实现对不上。
 */
export class DlFit {
  /**
   * 表面宽度：钉死为放大时的画布宽（与用户看到的排版一致），并做上下限保护。
   * 上限的存在意义：画布尺寸异常（旋转中测量、极端分屏）时不开出一块荒唐大的表面。
   */
  static surfaceWidthOf(canvasW: number): number {
    const w: number = canvasW > 0 ? Math.ceil(canvasW) : DL_FALLBACK_W;
    return Math.max(DL_MIN_W, Math.min(DL_MAX_W, w));
  }

  /**
   * 内容装不进表面时要下发的 CSS zoom（1 = 原样，不需要缩）。
   * 宽高两轴各自算一个"装下所需倍率"，取小者 = 两轴同时装下；再夹一层最小倍率。
   * **同一个倍率作用于两轴** → 等比缩放，不拉伸不挤压。
   */
  static zoomFor(surfaceW: number, contentW: number, contentH: number): number {
    if (surfaceW <= 0 || contentW <= 0 || contentH <= 0) {
      return 1;
    }
    const zW: number = contentW > surfaceW + 2 ? surfaceW / contentW : 1;
    const zH: number = contentH > DL_MAX_SURFACE_H + 2 ? DL_MAX_SURFACE_H / contentH : 1;
    const z: number = Math.min(1, zW, zH);
    if (z >= 0.995) {
      return 1;
    }
    return Math.max(DL_MIN_ZOOM, Math.round(z * 1000) / 1000);
  }
}

@Component
export struct DiagramDownloadHost {
  /** 当前任务（宿主按 `if` 挂载，一次一个，卸载即换表面） */
  @Prop job: DlJob = { mode: '', payload: '', width: 0, forceHeight: 0 };
  /** 快照产物 + 页面回传的**内容逻辑尺寸**（vp） */
  onDone: (pixel: image.PixelMap, w: number, h: number) => void = () => {
  };
  /** 失败（超时 / 快照不可用）：reason 只用于日志与提示文案 */
  onFail: (reason: string) => void = () => {
  };

  /** 渲染表面宽度（vp）：钉死为画布宽，收敛过程中不变 */
  @State surfaceW: number = DL_FALLBACK_W;
  /** 超宽适配倍率（CSS zoom，0 = 不缩放） */
  @State dlZoom: number = 0;
  /** 强制重新注入计数（payload 没变时也要按新容器重排） */
  @State layoutTick: number = 0;
  /** 快照请求计数 */
  @State captureTick: number = 0;
  /** 表面高度钉死（脑图用；0 = 由页面回传决定） */
  @State dlForceH: number = 0;

  /** 页面最近回传的内容尺寸 */
  private lastW: number = 0;
  private lastH: number = 0;
  /** 0 = 首遍；1 = 已按超宽缩放、等第二遍；2 = 已派发快照 */
  private phase: number = 0;
  /** 快照重拍次数（尺寸自检不过时重来一次） */
  private retry: number = 0;
  private settleTimer: number = -1;
  private guardTimer: number = -1;
  private hardTimer: number = -1;
  /** 第一份尺寸回传的时刻（等待安静的上限从这里算） */
  private firstAt: number = 0;
  /** 是否已结束（防止 onFail 与 onDone 竞态重复回调） */
  private finished: boolean = false;

  aboutToAppear(): void {
    this.surfaceW = DlFit.surfaceWidthOf(this.job.width);
    // 脑图这类"自适应容器、不回传自然高度"的引擎：由宿主钉死表面高度
    if (this.job.forceHeight > 0) {
      this.dlForceH = Math.ceil(this.job.forceHeight);
    }
    this.hardTimer = setTimeout(() => {
      this.hardTimer = -1;
      this.fail('timeout');
    }, DL_HARD_TIMEOUT_MS);
  }

  aboutToDisappear(): void {
    this.clearTimers();
  }

  private clearTimers(): void {
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
      this.settleTimer = -1;
    }
    if (this.guardTimer >= 0) {
      clearTimeout(this.guardTimer);
      this.guardTimer = -1;
    }
    if (this.hardTimer >= 0) {
      clearTimeout(this.hardTimer);
      this.hardTimer = -1;
    }
  }

  private fail(reason: string): void {
    if (this.finished) {
      return;
    }
    this.finished = true;
    this.clearTimers();
    this.onFail(reason);
  }

  /**
   * 尺寸回传（宽高各一路，顺序不保证）→ 去抖 → 决策。
   * 决策只有两条：内容比画布宽（公式横向溢出）就先缩放再等一遍；否则直接快照。
   */
  private onSizeReady(w: number, h: number): void {
    if (this.finished || this.phase >= 2) {
      return;
    }
    if (w > 0) {
      this.lastW = w;
    }
    if (h > 0) {
      this.lastH = h;
    }
    if (this.lastH <= 0) {
      return;
    }
    const now: number = Date.now();
    if (this.firstAt <= 0) {
      this.firstAt = now;
    }
    // 收敛过程一直不静（mermaid / markmap 的 ResizeObserver 回传）时，等够就派发
    if (now - this.firstAt > DL_MAX_QUIET_WAIT_MS) {
      this.step();
      return;
    }
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
    }
    this.settleTimer = setTimeout(() => {
      this.settleTimer = -1;
      this.step();
    }, DL_SETTLE_MS);
  }

  private step(): void {
    if (this.finished || this.phase >= 2) {
      return;
    }
    // **内容装不进这块表面**（或宽 → 公式横向溢出；或高 → 长图超过表面高度上限）
    // → 下发 CSS zoom **等比**缩进画面：横纵同一个比例，不拉伸不挤压，整幅都在图里。
    // 只做一次：缩放后页面在**自己那套 CSS 坐标**里回传的尺寸还是原值（zoom 不改
    // 元素坐标空间），照着再缩第二遍就会无限缩小。
    if (this.phase === 0) {
      const z: number = DlFit.zoomFor(this.surfaceW, this.lastW, this.lastH);
      if (z < 1) {
        this.phase = 1;
        this.dlZoom = z;
        this.lastW = 0;
        this.lastH = 0;
        // payload 字符串没变 → 用 layoutTick 走同一条注入通道，页面按 zoom 重排
        this.layoutTick = this.layoutTick + 1;
        return;
      }
    }
    this.phase = 2;
    this.captureTick = this.captureTick + 1;
    if (this.guardTimer >= 0) {
      clearTimeout(this.guardTimer);
    }
    this.guardTimer = setTimeout(() => {
      this.guardTimer = -1;
      this.fail('capture-timeout');
    }, DL_CAPTURE_GUARD_MS);
  }

  /** 快照产物 → 尺寸自检（横向没被裁）→ 回传 */
  private onCaptured(pixel: image.PixelMap, w: number, h: number): void {
    if (this.finished || this.phase < 2) {
      return;
    }
    if (this.guardTimer >= 0) {
      clearTimeout(this.guardTimer);
      this.guardTimer = -1;
    }
    const lh: number = this.lastH > 0 ? this.lastH : (h > 0 ? h : this.dlForceH);
    this.checkThenDeliver(pixel, lh);
  }

  /**
   * **横向自检**：像素宽应当 ≈ 表面宽 × 设备像素比。
   * 设备像素比由高度轴反推（同一张图两轴倍数必然相同），不依赖任何设备常量。
   * 明显偏窄 = 这块表面被按可视区裁了（平台对"超宽表面"的兜底），重拍一次仍不行
   * 就如实报错 —— 宁可告诉用户没出成，也不存一张缺右边的图。
   */
  private async checkThenDeliver(pixel: image.PixelMap, lh: number): Promise<void> {
    let narrow: boolean = false;
    try {
      const info: image.ImageInfo = await pixel.getImageInfo();
      const dpr: number = lh > 0 ? info.size.height / lh : 0;
      if (dpr > 0) {
        const expectW: number = this.surfaceW * dpr;
        narrow = info.size.width < expectW * 0.85;
      }
    } catch (err) {
      narrow = false;
    }
    if (narrow && this.retry < 1) {
      this.retry++;
      this.captureTick = this.captureTick + 1;
      if (this.guardTimer >= 0) {
        clearTimeout(this.guardTimer);
      }
      this.guardTimer = setTimeout(() => {
        this.guardTimer = -1;
        this.fail('capture-timeout');
      }, DL_CAPTURE_GUARD_MS);
      return;
    }
    if (narrow) {
      this.fail('narrow');
      return;
    }
    if (this.finished) {
      return;
    }
    this.finished = true;
    this.clearTimers();
    this.onDone(pixel, this.lastW > 0 ? this.lastW : this.surfaceW, lh);
  }

  build() {
    // 表面：宽度钉死（画布宽）、高度由渲染页回传或宿主钉死；近透明 + 不吃触摸。
    // ⚠️ 不要套 `.clip(true)` / 固定高容器：Web 表面必须是真实尺寸才渲染得出整张图，
    //    这也正是浮层里那块表面做不到的事（v1~v4 的坑）。
    Stack() {
      DiagramWeb({
        mode: this.job.mode,
        payload: this.job.payload,
        // **强制浅色**（用户要求）：与当前主题无关，下载恒定浅色纯底
        dark: false,
        cardBg: '#FFFFFFFF',
        // 导出形态：底色层直角、无内描边（见 DiagramWeb.dl）
        dl: true,
        dlZoom: this.dlZoom,
        dlForceHeight: this.dlForceH,
        layoutTick: this.layoutTick,
        // 按视窗自适应 + 高度随内容长：与放大浮层同一套排版，只把"画布"换成这块表面
        fit: true,
        fillHeight: false,
        webId: 'dl_web',
        captureRequest: this.captureTick,
        onSizeReady: (w: number, h: number) => {
          this.onSizeReady(w, h);
        },
        onCaptured: (pixel: image.PixelMap, w: number, h: number) => {
          this.onCaptured(pixel, w, h);
        }
      })
    }
    .width(this.surfaceW)
    .opacity(0.01)
    .hitTestBehavior(HitTestMode.None)
  }
}
