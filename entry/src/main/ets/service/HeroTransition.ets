/**
 * 澄笺 · 一镜到底转场几何（移植自华为官方 transitions-collection 示例）
 * ======================================================================
 *
 * 参考：HarmonyOS_Samples/transitions-collection · BookFlipLongTakeTransitionProperties
 *
 * 官方做法：不靠 geometryTransition，而是**测量源卡片矩形**，让目标页从该矩形
 * 「缩放 + 平移」展开到全屏（返回时反向缩回），并按长宽比裁剪避免拉伸。
 * 本工程是 router 架构——push 时下层书架页仍在渲染，因此详情页缩回时
 * 露出的正是书架真实的封面格子，观感与 Navigation 版一致。
 *
 * 关键 API：uiContext.getComponentUtils().getRectangleById(id) 拿组件在窗口中的 px 矩形。
 */

import { componentUtils } from '@kit.ArkUI';

/** 组件在窗口中的矩形（px） */
export class HeroRect {
  left: number = 0;
  top: number = 0;
  width: number = 0;
  height: number = 0;
}

/** 转场初始几何（vp，可直接喂给 scale/translate/clip） */
export class HeroInit {
  /** 初始缩放：封面尺寸 / 屏幕尺寸 取大者 */
  scale: number = 1;
  translateX: number = 0;
  translateY: number = 0;
  /** 容器裁剪尺寸：配合 scale 保持封面长宽比 */
  clipW: string = '100%';
  clipH: string = '100%';
  ok: boolean = false;
}

export class HeroTransition {
  /** 跨页传参：源矩形（px）序列化后经 AppStorage 传递 */
  static readonly KEY_SRC_RECT: string = 'heroSrcRect';
  /** 跨页传参：**预算好的初始几何**（书架按自己的窗口尺寸算，阅读页首帧直接用） */
  static readonly KEY_INIT: string = 'heroInit';

  /** 测量指定 id 组件在窗口中的矩形（px）。测不到时 ok=false。 */
  static measure(ui: UIContext, id: string): HeroRect {
    const rect: HeroRect = new HeroRect();
    try {
      const info: componentUtils.ComponentInfo = ui.getComponentUtils().getRectangleById(id);
      if (info === undefined || info === null || info.size.width <= 0 || info.size.height <= 0) {
        return rect;
      }
      const scaleGapW: number = info.size.width * (1 - info.scale.x) / 2;
      const scaleGapH: number = info.size.height * (1 - info.scale.y) / 2;
      rect.left = info.translate.x + info.windowOffset.x + scaleGapW;
      rect.top = info.translate.y + info.windowOffset.y + scaleGapH;
      rect.width = info.size.width * info.scale.x;
      rect.height = info.size.height * info.scale.y;
      return rect;
    } catch (err) {
      return rect;
    }
  }

  /** 存入 AppStorage（跳转前由来源页调用）。 */
  static saveSource(rect: HeroRect): void {
    const json: string = JSON.stringify(rect);
    AppStorage.setOrCreate<string>(HeroTransition.KEY_SRC_RECT, json);
  }

  /** 取出来源矩形；未设置返回 null。 */
  static loadSource(): HeroRect | null {
    const json: string | undefined = AppStorage.get<string>(HeroTransition.KEY_SRC_RECT);
    if (json === undefined || json === null || json.length === 0) {
      return null;
    }
    try {
      const rect: HeroRect = JSON.parse(json) as HeroRect;
      if (rect === null || rect === undefined || rect.width <= 0 || rect.height <= 0) {
        return null;
      }
      return rect;
    } catch (err) {
      return null;
    }
  }

  static clearSource(): void {
    AppStorage.setOrCreate<string>(HeroTransition.KEY_SRC_RECT, '');
  }

  /**
   * 保存初始几何。
   * 为什么要在**来源页**算好：目标页 aboutToAppear 时还没量到自己的窗口尺寸
   * （rootWidth/rootHeight 仍为默认值），自己算会算错；来源页量到的屏幕尺寸是准的。
   */
  static saveInit(init: HeroInit): void {
    AppStorage.setOrCreate<string>(HeroTransition.KEY_INIT, JSON.stringify(init));
  }

  /** 取出并把初始几何作为「首帧就位」用。 */
  static takeInit(): HeroInit | null {
    const json: string | undefined = AppStorage.get<string>(HeroTransition.KEY_INIT);
    AppStorage.setOrCreate<string>(HeroTransition.KEY_INIT, '');
    if (json === undefined || json === null || json.length === 0) {
      return null;
    }
    try {
      const init: HeroInit = JSON.parse(json) as HeroInit;
      if (init === null || init === undefined || init.ok !== true) {
        return null;
      }
      return init;
    } catch (err) {
      return null;
    }
  }

  /**
   * 官方几何算法的 vp 直算版。
   * 来源页 onAreaChange 拿到的 Area.globalPosition 就是 vp（窗口坐标），
   * 用它算最稳（不经过 px 往返，也不依赖 getComponentById 能否命中）。
   */
  static computeInitFromVp(rectVp: HeroRect, screenWvp: number, screenHvp: number): HeroInit {
    const out: HeroInit = new HeroInit();
    if (rectVp.width <= 0 || rectVp.height <= 0 || screenWvp <= 0 || screenHvp <= 0) {
      return out;
    }
    const wRatio: number = rectVp.width / screenWvp;
    const hRatio: number = rectVp.height / screenHvp;
    const useWidth: boolean = wRatio > hRatio;
    out.scale = useWidth ? wRatio : hRatio;
    if (out.scale <= 0) {
      out.scale = 1;
    }
    const cx: number = rectVp.left + rectVp.width / 2;
    const cy: number = rectVp.top + rectVp.height / 2;
    if (useWidth) {
      out.translateX = cx - screenWvp / 2;
      out.clipW = '100%';
      const clipH: number = rectVp.height / out.scale;
      out.clipH = clipH + 'vp';
      // 容器顶部对齐屏幕顶部（Stack TopStart 布局），缩放后视觉顶部落在
      // (clipH - clipH*scale)/2 处，平移量即封面顶部与它的差
      out.translateY = rectVp.top - (clipH - clipH * out.scale) / 2;
    } else {
      out.translateY = cy - screenHvp / 2;
      out.clipH = '100%';
      const clipW: number = rectVp.width / out.scale;
      out.clipW = clipW + 'vp';
      out.translateX = cx - screenWvp / 2;
    }
    out.ok = true;
    return out;
  }

  /**
   * 官方几何算法：由源矩形（px）算出目标页的初始 scale / translate / clip。
   * 取宽高比例较大者做 scale；另一方向超出屏幕的部分用 clip 裁掉，
   * 这样缩放后的画面正好与源封面贴合、且不被拉伸。
   */
  static computeInit(ui: UIContext, rect: HeroRect, screenWvp: number, screenHvp: number): HeroInit {
    const out: HeroInit = new HeroInit();
    if (rect.width <= 0 || rect.height <= 0 || screenWvp <= 0 || screenHvp <= 0) {
      return out;
    }
    const wRatio: number = ui.px2vp(rect.width) / screenWvp;
    const hRatio: number = ui.px2vp(rect.height) / screenHvp;
    const useWidth: boolean = wRatio > hRatio;
    out.scale = useWidth ? wRatio : hRatio;
    if (out.scale <= 0) {
      out.scale = 1;
    }
    const cx: number = ui.px2vp(rect.left + rect.width / 2);
    const cy: number = ui.px2vp(rect.top + rect.height / 2);
    if (useWidth) {
      out.translateX = cx - screenWvp / 2;
      out.clipW = '100%';
      const clipH: number = ui.px2vp(rect.height) / out.scale;
      out.clipH = clipH + 'vp';
      out.translateY = ui.px2vp(rect.top) - (clipH - clipH * out.scale) / 2;
    } else {
      out.translateY = cy - screenHvp / 2;
      out.clipH = '100%';
      const clipW: number = ui.px2vp(rect.width) / out.scale;
      out.clipW = clipW + 'vp';
      out.translateX = cx - screenWvp / 2;
    }
    out.ok = true;
    return out;
  }
}
