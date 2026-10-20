/**
 * 澄笺 · 外观高级开关（2026-10-20 新增）
 *
 * 两个全局开关，**默认都关闭**（用户要求：默认轻量、省电、不发热）：
 *   · `immersiveLook` 沉浸光感：关闭 → 所有卡片一律**纯色不透明**（不挂材质、不做磨砂）；
 *     开启 → 走 API 26 的 systemMaterial 光感材质（会掉帧 / 发热，开启时弹窗提醒）。
 *   · `motionFx` 过渡动画：关闭 → **所有动效瞬时完成**（页面切换硬切、出现即显示）；
 *     开启 → 恢复项目原有的过渡动画。
 *
 * 判定统一走 AppStorage：键由「设置 → 外观」写入，EntryAbility 负责持久化
 * （persistProp 白名单 + SettingsMirror.KEYS 都要登记）。
 *
 * ⚠️ 约定：新写的动效一律用 `AppearanceFx.anim(ms)` 取参数、`AppearanceFx.fx(effect)`
 * 包过渡效果；页面栈跳转用 `pushPath(info, AppearanceFx.motion())` 传 animated。
 */
export class AppearanceFx {
  /** 沉浸光感（默认关） */
  static readonly KEY_IMMERSIVE: string = 'immersiveLook';
  /** 过渡动画（默认关） */
  static readonly KEY_MOTION: string = 'motionFx';

  /** 沉浸光感是否开启。未写过 / 非 true 一律按关闭处理。 */
  static immersive(): boolean {
    return AppStorage.get<boolean>(AppearanceFx.KEY_IMMERSIVE) === true;
  }

  /** 过渡动画是否开启。 */
  static motion(): boolean {
    return AppStorage.get<boolean>(AppearanceFx.KEY_MOTION) === true;
  }

  /**
   * 统一动画参数：过渡动画关闭时 **duration = 0**（animateTo 里状态直接到位，
   * 视觉上就是"突然出现 / 突然消失"）。
   */
  static anim(duration: number, curve: Curve = Curve.FastOutSlowIn): AnimateParam {
    const param: AnimateParam = {
      duration: AppearanceFx.motion() ? duration : 0,
      curve: curve
    };
    return param;
  }

  /**
   * 统一过渡效果：过渡动画关闭时返回 `TransitionEffect.IDENTITY`（无任何过渡）。
   * 用法：`.transition(AppearanceFx.fx(TransitionEffect.OPACITY.animation({ duration: 200 })))`
   */
  static fx(effect: TransitionEffect): TransitionEffect {
    return AppearanceFx.motion() ? effect : TransitionEffect.IDENTITY;
  }

  /**
   * 原样透传一个 AnimateParam，但**过渡动画关闭时压成 duration 0**。
   * 用于弹簧曲线这类"不是 duration+curve 两参"的形态：
   * `animateTo(AppearanceFx.param({ curve: FOLDER_SPRING }))`
   */
  static param(p: AnimateParam): AnimateParam {
    if (AppearanceFx.motion()) {
      return p;
    }
    const zero: AnimateParam = { duration: 0 };
    return zero;
  }

  /** 页面栈跳转的 `animated` 参数：过渡动画关闭 → false（硬切）。 */
  static navAnimated(): boolean {
    return AppearanceFx.motion();
  }
}
