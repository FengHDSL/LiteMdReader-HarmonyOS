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
  /** 行内公式：按公式自身尺寸渲染（供正文 ImageSpan 内联） */
  inline?: boolean;
}

@Component
export struct ChartRenderPool {
  /** 待渲染任务清单（宿主在文档加载后生成；已缓存 / 已失败的会被跳过） */
  @Prop @Watch('pump') tasks: ChartTask[] = [];
  /** 深浅色（参与缓存键） */
  @Prop dark: boolean = false;
  /** 卡片底色（快照防黑底：webPageSnapshot 不含 alpha，透明会被合成成黑） */
  @Prop cardBg: string = '';
  /**
   * **烘焙宽度**（vp，正文字号那一栏的实际宽）。必须显式给 DiagramWeb 当
   * `virtualWidth`：不给的话页面按"组件当时多宽"排版，而池子挂在页面根层，
   * 转场 / 首帧那几百毫秒里组件宽度还不是最终值 —— 图就在一个窄条里重排，
   * 节点竖成一列、文字溢出框外（用户实测导出与打印里"部分图表异常挤压拉伸"，
   * 设备上一张状态图烘成 73×1274 像素）。给了定宽，页面自己把 body 钉到该宽度，
   * 与组件的瞬时宽度彻底无关，烘出来的每张图宽度都一致。
   */
  @Prop hostWidth: number = 0;
  /** 每完成（或失败跳过）一张回调一次：宿主刷新正文让占位换成缓存图 */
  onOneDone: () => void = () => {
  };
  /**
   * **失败重试信号**（导出 / 打印前由页面递增；见 onRetryTick）。
   * 失败多是时序抖动（等高度超时 / 快照无响应 / 旧表面重拍超限），重开文档就会
   * 重试——但导出时文档已经开着（进程内失败集还在），不主动清一遍就会"永远缺那几张"，
   * 于是导出里它们退化成"现场渲染的容器"。清掉重跑一轮，大概率能补上。
   */
  @Prop @Watch('onRetryTick') retryTick: number = 0;

  /** 当前正在渲染的任务 */
  @State current: ChartTask | null = null;
  /** 截图请求计数：当前任务高度就绪后递增，驱动 DiagramWeb 快照 */
  @State captureTick: number = 0;
  private busyRendering: boolean = false;
  private failed: Set<string> = new Set();
  private ctx: common.UIAbilityContext | null = null;
  /** 快照兜底超时定时器（webPageSnapshot 无回调时不至于卡死队列） */
  private guardTimer: number = -1;
  /**
   * **等待高度回传的兜底定时器**。历史上这里是队列卡死的重灾区：
   * 若某个任务始终等不到 DiagramWeb 的高度回传（Web 加载失败、页面脚本异常、
   * 连续任务没触发刷新等），`busyRendering` 将永远为 true，整条队列连同其后
   * 所有公式/图表一起"僵死"——第一个任务之后全部没有缓存图（用户实测）。
   * 超时后把该任务记入失败集并放行队列，让后续任务继续。
   */
  private waitTimer: number = -1;
  /** 快照请求去抖定时器：高度回传会来多份（空报/渲染后/收敛后），等"最后一份 + 150ms"再抓 */
  private captureDebounce: number = -1;
  /** 本次快照归属的任务键（onCaptured 校验用：丢弃迟到快照，防止串图） */
  private pendingKey: string = '';
  /** 当前任务已重拍次数（拍到旧表面时重来，见 staleCapture） */
  private captureRetry: number = 0;

  aboutToAppear(): void {
    this.pump();
  }

  /** 失败重试信号：清空失败集并重新推进队列（导出 / 打印前调用一次，见 retryTick）。 */
  private onRetryTick(): void {
    if (this.retryTick <= 0) {
      return;
    }
    this.failed.clear();
    this.captureRetry = 0;
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
      this.captureRetry = 0;
      // 启动"等高度"兜底：超时仍未回传 → 跳过该任务，队列继续
      if (this.waitTimer >= 0) {
        clearTimeout(this.waitTimer);
      }
      this.waitTimer = setTimeout(() => {
        this.waitTimer = -1;
        const cur: ChartTask | null = this.current;
        if (cur !== null && this.busyRendering) {
          this.failed.add(cur.key);
          this.finishOne(cur);
        }
      }, 10000);
      return;
    }
    // 全部就绪
    this.current = null;
  }

  /**
   * DiagramWeb 高度回传。**注意会收到多份**（页面加载时的空报、注入渲染后的、
   * 尺寸收敛后的……）——这里做 150ms 去抖，只在"最后一份回传后 150ms"递
   * **一次**快照请求：抓到的必然是渲染已稳定完成的画面。
   * （此前收到第一份就立刻抓，可能抓到"内容还没画上去"的中间帧 → 存下空白图，
   * 正文从此一直空白——用户实测"大部分直接空白"的成因之一。）
   */
  private onHeightReady(): void {
    // 高度已回传：撤销"等高度"兜底（任务已进入快照阶段）
    if (this.waitTimer >= 0) {
      clearTimeout(this.waitTimer);
      this.waitTimer = -1;
    }
    if (this.captureDebounce >= 0) {
      clearTimeout(this.captureDebounce);
    }
    this.captureDebounce = setTimeout(() => {
      this.captureDebounce = -1;
      const t: ChartTask | null = this.current;
      if (t === null || !this.busyRendering) {
        return;
      }
      // 记下本次快照归属的任务键：onCaptured 用它丢弃"迟到"的快照
      this.pendingKey = t.key;
      this.captureTick++;
      if (this.guardTimer >= 0) {
        clearTimeout(this.guardTimer);
      }
      this.guardTimer = setTimeout(() => {
        this.guardTimer = -1;
        const cur: ChartTask | null = this.current;
        if (cur !== null && this.busyRendering) {
          // 快照无响应：跳过这张，队列继续
          this.failed.add(cur.key);
          this.finishOne(cur);
        }
      }, 4000);
    }, 150);
  }

  /** 收到快照产物 → 归属校验 → **旧表面校验（拒收并重拍）** → 空白自检 → 入库（含逻辑尺寸 sidecar）→ 收尾。 */
  private onCaptured(pixel: image.PixelMap, w: number, h: number): void {
    if (this.guardTimer >= 0) {
      clearTimeout(this.guardTimer);
      this.guardTimer = -1;
    }
    const t: ChartTask | null = this.current;
    const c: common.UIAbilityContext | null = this.ctx;
    // **归属校验**：迟到的快照（拍完才回来的旧任务）直接丢弃——
    // 写进新任务的缓存键就是串图（B 的键下存 A 的图，比空白更难察觉）
    if (t === null || c === null || t.key !== this.pendingKey) {
      return;
    }
    this.staleSnapshot(pixel, w, h).then((stale: boolean) => {
      if (stale) {
        if (this.captureRetry < 2) {
          // 组件高度是收到回传后才改的（@State → 下一帧重排），而快照是在回传的
          // **同一时刻**派出去的 → 拍到的是上一张图留在旧表面上的那一帧。
          // 等一帧再拍同一张（重新武装 4s 兜底，别让队列悬着）。
          this.captureRetry++;
          const waitKey: string = t.key;
          if (this.captureDebounce >= 0) {
            clearTimeout(this.captureDebounce);
          }
          this.captureDebounce = setTimeout(() => {
            this.captureDebounce = -1;
            const cur: ChartTask | null = this.current;
            if (cur === null || !this.busyRendering || cur.key !== waitKey) {
              return;
            }
            this.pendingKey = waitKey;
            this.captureTick++;
            this.armGuard();
          }, 450);
          return;
        }
        // 重拍两次还是旧表面：这张不入库（正文回落实时 Web，显示的是对的图）
        this.failed.add(t.key);
        this.finishOne(t);
        return;
      }
      this.pixelLooksBlank(pixel).then((blank: boolean) => {
        if (blank) {
          // **空白自检**：整张同色（= 只有烘焙进去的卡片底色、什么都没画出来）的图
          // 不落盘——宁可任务保持"未就绪"（正文回落实时 Web / 线性化文本），
          // 也不把空白写进持久缓存：一旦落盘，正文每次命中缓存键都显示这张空白图，
          // 重开文档也不会恢复。记入失败集让队列继续。
          this.failed.add(t.key);
          this.finishOne(t);
          return;
        }
        ChartCache.save(c, t.key, pixel, w, h, true).then(() => {
          // 顺带登记 payload 索引：导出侧凭 (mode, payload) 反查缓存图（见 ChartCache）
          ChartCache.rememberPayloadKey(c, t.mode, t.payload, this.dark, t.key);
          this.finishOne(t);
        }).catch(() => {
          this.failed.add(t.key);
          this.finishOne(t);
        });
      });
    });
  }

  /** 快照兜底超时（与 onHeightReady 里同一口径；重拍时要用它续命）。 */
  private armGuard(): void {
    if (this.guardTimer >= 0) {
      clearTimeout(this.guardTimer);
    }
    this.guardTimer = setTimeout(() => {
      this.guardTimer = -1;
      const cur: ChartTask | null = this.current;
      if (cur !== null && this.busyRendering) {
        this.failed.add(cur.key);
        this.finishOne(cur);
      }
    }, 4000);
  }

  /**
   * 拍到的还是"上一张图的表面"吗？判据 = **快照两轴的缩放倍数不相等**。
   *
   * 像素尺寸 = 逻辑尺寸 × 屏幕密度，横纵同一个倍数；纵向明显小于横向，说明组件
   * 还没按新回传的高度重排，抓下来的是旧内容留在初始 100vp 表面上的那一条。
   * 设备实锤（2026-10-14 拉取用户手机 charts/ 全量比对 png 与 .dim）：一篇文档
   * 29 张 mermaid 里 **21 张**的 PNG 高度正好是 100vp×3.5，而 .dim 记的是真实高度
   * （81~381），其中一张键属于时序图、像素却是上一块的公式 —— 正文按 .dim 撑框
   * + Contain 显示，图就缩成卡片中间一条（用户报"正常阅读页面渲染也是错误"）。
   * PlantUML / KaTeX 出图慢一拍，高度回传发生在重排之后，所以躲过这一枪。
   *
   * 只判"拍矮了"：矮 = 漏画（串图 / 截断）；高 = 保底高度撑出的空白，显示端
   * Contain 会居中，无害，不该因此丢缓存。
   */
  private async staleSnapshot(pixel: image.PixelMap, w: number, h: number): Promise<boolean> {
    if (w <= 0 || h <= 0) {
      return false;
    }
    try {
      const info: image.ImageInfo = await pixel.getImageInfo();
      const rx: number = info.size.width / w;
      const ry: number = info.size.height / h;
      if (rx <= 0 || ry <= 0) {
        return false;
      }
      return rx - ry > 0.5;
    } catch (err) {
      return false;
    }
  }

  /**
   * 自检：快照是不是"整张一个颜色"。
   *
   * ⚠️ **不能只看 alpha**：卡片快照刻意烘焙**不透明**卡片底色（webPageSnapshot 不带
   * alpha，透明会被合成成黑色——见 DiagramWeb.cardBg 与 cardBgKey 的注释），
   * 于是"什么都没画出来"的失败快照是**整片 alpha=255 的卡片底色**，
   * 用 alpha≥16 判空白永远判不出来 → 空白图照样落盘，正文一直是一张
   * 同色矩形（用户实测"数据可视化卡片上不显示，浅色模式也不显示"；
   * 放大浮层走的是实时 Web 那条支路，所以放大能看到图、卡片看不到）。
   * 改成**与左上角那像素比颜色**：整张都一样才算空白。
   * 全图扫描、发现第一个不同就退出（真实图表第一个像素之后马上就有笔画/网格）。
   * 读取失败保守放行（按有内容处理）。
   */
  private async pixelLooksBlank(pixel: image.PixelMap): Promise<boolean> {
    try {
      const info: image.ImageInfo = await pixel.getImageInfo();
      if (info.pixelFormat !== image.PixelMapFormat.RGBA_8888) {
        return false;
      }
      const w: number = info.size.width;
      const h: number = info.size.height;
      if (w <= 0 || h <= 0) {
        return true;
      }
      const buf: ArrayBuffer = new ArrayBuffer(w * h * 4);
      const area: image.PositionArea = {
        pixels: buf, offset: 0, stride: w * 4,
        region: { size: { width: w, height: h }, x: 0, y: 0 }
      };
      await pixel.readPixels(area);
      const px: Uint8Array = new Uint8Array(buf);
      // 参照色 = 左上角（就是烘焙进去的卡片底色；行内公式是透明底 0,0,0,0）
      const r0: number = px[0];
      const g0: number = px[1];
      const b0: number = px[2];
      const a0: number = px[3];
      for (let i: number = 4; i + 3 < px.length; i += 4) {
        // 阈值 8/通道：合成器抖动最多差 1～2，任何真实内容远超这个量
        if (Math.abs(px[i] - r0) > 8 || Math.abs(px[i + 1] - g0) > 8
          || Math.abs(px[i + 2] - b0) > 8 || Math.abs(px[i + 3] - a0) > 8) {
          return false;
        }
      }
      return true;
    } catch (err) {
      return false;
    }
  }

  private finishOne(t: ChartTask): void {
    // 三个兜底定时器统一在此收尾（无论正常完成还是超时跳过）
    if (this.waitTimer >= 0) {
      clearTimeout(this.waitTimer);
      this.waitTimer = -1;
    }
    if (this.guardTimer >= 0) {
      clearTimeout(this.guardTimer);
      this.guardTimer = -1;
    }
    if (this.captureDebounce >= 0) {
      clearTimeout(this.captureDebounce);
      this.captureDebounce = -1;
    }
    this.pendingKey = '';
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
          cardBg: this.cardBg,
          inlineMode: this.current.inline === true,
          // 定宽烘焙（见 hostWidth 声明）：0 = 沿用组件宽度（老行为）
          virtualWidth: this.hostWidth,
          // **与「手动下载」同一排版路径**（fit=true）：上一版只对齐了 `dl`（直角、
          // 无内边距、不限高），却没给 fit —— 于是页面走的还是**卡片模式**那条支路：
          // 按 viewBox 把整图夹进 capW×capH（340~600），长图被等比缩小 → 烘出一张
          // 又窄又短的条（用户实测导出/打印"部分图表异常挤压拉伸"，设备上一张
          // 状态图 73×1274、树形视图 61vp 宽，正是卡片模式 capH=340 的算结果）。
          fit: true,
          // **导出形态**（2026-10-16 用户实测反馈："打印 / 导出的 html 里，公式块、
          // 图表不是手动下载的样式"）：直角 + 去内边距，与「手动下载」生成的图同形态 ——
          // 导出 / 打印的内嵌图与用户手里存的 PNG 必须长得一样。存盘前还会做一次
          // 裁边（见 onCaptured → ChartCache.save 的 trim 参数）：去掉四周空白，
          // 长宽就是内容边界。
          dl: true,
          webId: 'bgchart_' + this.current.key,
          captureRequest: this.captureTick,
          onHeightReady: () => {
            this.onHeightReady();
          },
          onCaptured: (pixel: image.PixelMap, w: number, h: number) => {
            this.onCaptured(pixel, w, h);
          }
        })
      }
    }
    .width('100%')
    .opacity(0.01)
    .hitTestBehavior(HitTestMode.None)
  }
}
