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

  /** 收到快照产物 → 归属校验 → （块级公式：品红键控抠透明）→ 空白自检 → 入库 → 收尾。 */
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
    // **块级公式：品红底 → 透明底**（键控失败按任务失败处理——绝不把品红图
    // 落进缓存）。透明图让公式卡片的沉浸光感材质透出来（用户要求）。
    const needKey: boolean = t.mode === 'katex' && t.inline !== true;
    const prepare: Promise<image.PixelMap> = needKey
      ? this.keyMagenta(pixel, this.dark)
      : Promise.resolve(pixel);
    prepare.then((final: image.PixelMap) => {
      return this.pixelLooksBlank(final).then((blank: boolean) => {
        if (blank) {
          // **空白自检**：全透明图不落盘——宁可任务保持"未就绪"（正文显示
          // 线性化文本 / 实时渲染），也不把空白写进持久缓存（那会一直空白、
          // 重启也无效）。记入失败集让队列继续。
          this.failed.add(t.key);
          this.finishOne(t);
          return;
        }
        // w/h = 页面内容逻辑尺寸（css px = vp）：写 .dim sidecar，
        // 显示端对超宽公式按自然尺寸 + 横向滚动展示（不压扁）
        ChartCache.save(c, t.key, final, w, h).then(() => {
          this.finishOne(t);
        }).catch(() => {
          this.failed.add(t.key);
          this.finishOne(t);
        });
      });
    }).catch(() => {
      // 键控异常：按任务失败处理（回落实时渲染），队列继续
      this.failed.add(t.key);
      this.finishOne(t);
    });
  }

  /**
   * **品红键控抠图**：块级公式快照以品红（#FF00FF）为底拍摄（DiagramWeb
   * 拍前 __exportBg(true)），这里逐像素从 G 通道反解 alpha、输出
   * **笔画色 + 透明底**的图——公式卡片挂沉浸光感承载层后，材质透过公式面
   * 显示（不透明烘焙底会完全盖住材质）。
   *
   * 反解依据：katex.html 的笔画是单色 currentColor（深色 #ECEFF4 / 浅色 #000），
   * 底色 M=#FF00FF 的 G=0 —— G 通道线性可解且灵敏度最高：
   *   深色：P_G = a·239          → a = P_G / 239
   *   浅色：P_G = (1-a)·255      → a = 1 - P_R/255（G 无区分度，改用 R）
   * 公式反走样 = 笔画与底色的线性混合，反解天然干净、无彩边。
   * 任何异常抛给调用方按任务失败处理（绝不把品红图写进缓存）。
   */
  private async keyMagenta(pixel: image.PixelMap, dark: boolean): Promise<image.PixelMap> {
    const info: image.ImageInfo = await pixel.getImageInfo();
    if (info.pixelFormat !== image.PixelMapFormat.RGBA_8888) {
      return pixel;
    }
    const w: number = info.size.width;
    const h: number = info.size.height;
    if (w <= 0 || h <= 0 || w * h > 40000000) {
      return pixel;
    }
    const buf: ArrayBuffer = new ArrayBuffer(w * h * 4);
    const area: image.PositionArea = {
      pixels: buf, offset: 0, stride: w * 4,
      region: { size: { width: w, height: h }, x: 0, y: 0 }
    };
    await pixel.readPixels(area);
    const px: Uint8Array = new Uint8Array(buf);
    // 笔画色 = katex.html 的 currentColor：深色 #ECEFF4(236,239,244) / 浅色 #000
    const fr: number = dark ? 236 : 0;
    const fgG: number = dark ? 239 : 0;
    const fgB: number = dark ? 244 : 0;
    for (let i: number = 0; i < px.length; i += 4) {
      let a: number;
      if (dark) {
        a = px[i + 1] / 239;
      } else {
        a = 1 - px[i] / 255;
      }
      if (a < 0.015) {
        a = 0;
      } else if (a > 0.985) {
        a = 1;
      }
      // ⚠️ **必须写预乘值**（RGB = 笔画色 × a）：快照缓冲按预乘语义解释，
      // 直写非预乘值时 a=0 的背景像素是非法数据（RGB≠0 且 A=0）——
      // 解码端行为未定义 = 部分卡片背景渲染成**黑色**（用户实测浅色下滑动
    // 回来就变黑）。预乘后 a=0 → RGB=0，解码端反预乘还原笔画色。
      const pa: number = Math.round(a * 255);
      px[i] = Math.round(fr * a);
      px[i + 1] = Math.round(fgG * a);
      px[i + 2] = Math.round(fgB * a);
      px[i + 3] = pa;
    }
    await pixel.writePixels(area);
    return pixel;
  }

  /**
   * 自检：快照是否"基本空白"。
   *
   * 全图扫描（首个 alpha ≥ 16 的像素即判定"有内容"，提前退出）——
   * 键控后的公式图是**透明底**（背景 alpha=0），旧的三行采样会漏掉稀疏笔画
   * 把正常公式误判成空白；不透明烘焙图首像素即退出，开销不变。
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
      for (let i: number = 3; i < px.length; i += 4) {
        if (px[i] >= 16) {
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
