/**
 * LiteMdReader · 整屏壁纸图（**模糊预烘版**）
 * ==========================================
 *
 * 为什么要有这个组件：上架检测（《模糊场景性能优化》bpta-fuzzy-scene-performance-optimization）
 * 把书架页 JANK_RATE_TRANSITION 192.19ms/s、点击响应 547.73ms 的成因直接指在
 *
 *     Image(壁纸).blur(this.wallpaperBlur)
 *
 * 这一行上。整屏实时模糊是**每一帧**重算的：一进一出两个页面各挂一层，转场期间
 * 就是两层全屏模糊同时跑。
 *
 * 这里改成「烘一次、之后只贴图」：调 WallpaperStore.bakedOf() 用 effectKit
 * 把壁纸一次糊成位图（解码时先缩到不超过 1080px），页面显示的就是已经糊好的图。
 * 还没烘好、模糊强度为 0、或设备不支持滤镜时，退回原来的实时 `.blur()`——观感一致，
 * 只是那一小段时间仍是老写法。
 *
 * 起炉时机：**进场之后 600ms**（与背景光斑动画同一口径），不在转场那一帧发起。
 */

import { image } from '@kit.ImageKit';
import { WallpaperStore, WALLPAPER_BAKED_TICK_KEY } from '../service/WallpaperStore';

@Component
export struct WallpaperImage {
  /** 壁纸在沙箱里的绝对路径（空 = 没有壁纸，调用方自己判，这里不画东西） */
  @Prop @Watch('onSourceChanged') path: string = '';
  /** 模糊强度（vp，与设置页滑杆同一口径） */
  @Prop @Watch('onSourceChanged') radiusVp: number = 0;
  /** 预烘就绪信号：Store 烘完写一次时间戳，这里靠它重绘换成位图 */
  @StorageProp(WALLPAPER_BAKED_TICK_KEY) bakedTick: number = 0;
  /**
   * 起炉防抖计时器。设置页的模糊滑杆会连续改半径，每一档都重新解码 + 烘焙
   * 就是连着十几次全屏解码；停手 400ms 只烘最后一档。
   */
  private bakeTimer: number = -1;

  aboutToAppear(): void {
    // 进场那一帧不起炉：等转场过去（与背景光斑动画同一口径）
    this.scheduleBake(600);
  }

  aboutToDisappear(): void {
    if (this.bakeTimer >= 0) {
      clearTimeout(this.bakeTimer);
      this.bakeTimer = -1;
    }
  }

  private onSourceChanged(): void {
    this.scheduleBake(400);
  }

  private scheduleBake(delayMs: number): void {
    if (this.bakeTimer >= 0) {
      clearTimeout(this.bakeTimer);
    }
    this.bakeTimer = setTimeout((): void => {
      this.bakeTimer = -1;
      if (this.path.length === 0 || this.radiusVp <= 0) {
        return;
      }
      WallpaperStore.bakedOf(this.path, this.radiusVp);
    }, delayMs);
  }

  /** 当前 path + 强度对应的预烘位图；null = 还没有（键对不上也不返回旧的）。 */
  private baked(): image.PixelMap | null {
    if (this.bakedTick <= 0) {
      return null;
    }
    return WallpaperStore.peekBaked(this.path, this.radiusVp);
  }

  /** 当前要显示的源：优先预烘位图，没有才回原图（string）。 */
  private displaySrc(): image.PixelMap | string {
    const b: image.PixelMap | null = this.baked();
    return b !== null ? b : WallpaperStore.imageSourceOf(this.path);
  }

  build() {
    // **单一 Image 节点换源**（2026-10-20 修闪烁）：原来 if/else 是两个分支 = 两个节点，
    // 拖动模糊滑杆时每换一档都会「销毁旧节点 → 新建节点 → 重新解码」，中间一帧空窗
    // 就是用户看到的**壁纸闪烁**。现在节点固定不动，只换源与 blur：
    //   · 有预烘位图 → 直接贴（已糊好，blur 0）；
    //   · 没有 → 原图 + 实时 blur（观感与旧实现一致，只是短时兜底）。
    Image(this.displaySrc())
      .width('100%')
      .height('100%')
      .objectFit(ImageFit.Cover)
      .blur(this.baked() !== null ? 0 : this.radiusVp)
      // 换源那一帧不要淡入淡出（否则又是一次"闪"）
      .animation(null)
  }
}
