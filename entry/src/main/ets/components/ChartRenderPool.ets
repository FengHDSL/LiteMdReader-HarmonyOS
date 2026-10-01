/**
 * 澄笺 · 图表后台预渲染池
 * ========================
 *
 * 打开文件时把未缓存的公式 / 图表逐个**在真实 Web 表面上后台渲染**，
 * 渲染完成（postHeight 信号）→ 池子递增 captureRequest → DiagramWeb 用
 * **webPageSnapshot 抓整页绘制结果**（不受可视区限制，比 componentSnapshot
 * 对 Web 表面可靠）→ ChartCache 落盘 → 回调宿主刷新正文。
 *
 * 放置要求：挂在**页面根 Stack 的最底层**（真实尺寸渲染，视觉透明 +
 * 不吃触摸），不要用 1×1 裁剪容器——Web 表面必须是真实大小才能渲染。
 *
 * 串行渲染（一次一张）：Web 实例很重，并行多个容易 OOM。
 * 失败的图表记入会话内失败集 + 4s 超时兜底，避免死循环。
 */

import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { DiagramWeb } from './DiagramWeb';
import { ChartCache } from '../service/ChartCache';

/** 一张待渲染的图表：mode = katex / mermaid / markmap / echarts / … */
export interface ChartTask {
  key: string;
  mode: string;
  payload: string;
}

@Component
export struct ChartRenderPool {
  /** 待渲染任务清单（宿主在文档加载后生成；已缓存 / 已失败的会被跳过） */
  @Prop @Watch('pump') tasks: ChartTask[] = [];
  /** 深浅色（参与缓存键） */
  @Prop dark: boolean = false;
  /** 每完成（或失败跳过）一张回调一次：宿主刷新正文让占位换成缓存图 */
  onOneDone: () => void = () => {
  };

  /** 当前正在渲染的任务 */
  @State current: ChartTask | null = null;
  /** 截图请求计数：当前任务高度就绪后递增，驱动 DiagramWeb 快照 */
  @State captureTick: number = 0;
  private busyRendering: boolean = false;
  private failed: Set<string> = new Set();
  private ctx: common.UIAbilityContext | null = null;
  /** 快照兜底超时定时器（webPageSnapshot 无回调时不至于卡死队列） */
  private guardTimer: number = -1;

  aboutToAppear(): void {
    this.pump();
  }

  private pump(): void {
    if (this.busyRendering) {
      return;
    }
    const c: common.UIAbilityContext | null = this.hostCtx();
    if (c === null) {
      return;
    }
    this.ctx = c;
    for (let k = 0; k < this.tasks.length; k++) {
      const t: ChartTask = this.tasks[k];
      if (ChartCache.path(c, t.key).length > 0 || this.failed.has(t.key)) {
        continue;
      }
      this.current = t;
      this.busyRendering = true;
      return;
    }
    // 全部就绪
    this.current = null;
  }

  /** DiagramWeb 高度回传 = 渲染完成 → 递增截图请求，并启动 4s 超时兜底。 */
  private onHeightReady(): void {
    this.captureTick++;
    if (this.guardTimer >= 0) {
      clearTimeout(this.guardTimer);
    }
    this.guardTimer = setTimeout(() => {
      this.guardTimer = -1;
      const t: ChartTask | null = this.current;
      if (t !== null && this.busyRendering) {
        // 快照无响应：跳过这张，队列继续
        this.failed.add(t.key);
        this.finishOne(t);
      }
    }, 4000);
  }

  /** 收到快照产物 → 入库 → 收尾。 */
  private onCaptured(pixel: image.PixelMap): void {
    if (this.guardTimer >= 0) {
      clearTimeout(this.guardTimer);
      this.guardTimer = -1;
    }
    const t: ChartTask | null = this.current;
    const c: common.UIAbilityContext | null = this.ctx;
    if (t === null || c === null) {
      return;
    }
    ChartCache.save(c, t.key, pixel).then(() => {
      this.finishOne(t);
    }).catch(() => {
      this.failed.add(t.key);
      this.finishOne(t);
    });
  }

  private finishOne(t: ChartTask): void {
    this.busyRendering = false;
    this.current = null;
    this.onOneDone();
    this.pump();
  }

  private hostCtx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  build() {
    // 真实尺寸渲染（表面必须真实），近透明 + 不吃触摸；宿主放最底层即可
    Stack() {
      if (this.current !== null) {
        DiagramWeb({
          mode: this.current.mode,
          payload: this.current.payload,
          dark: this.dark,
          webId: 'bgchart_' + this.current.key,
          captureRequest: this.captureTick,
          onHeightReady: () => {
            this.onHeightReady();
          },
          onCaptured: (pixel: image.PixelMap) => {
            this.onCaptured(pixel);
          }
        })
      }
    }
    .width('100%')
    .opacity(0.01)
    .hitTestBehavior(HitTestMode.None)
  }
}
