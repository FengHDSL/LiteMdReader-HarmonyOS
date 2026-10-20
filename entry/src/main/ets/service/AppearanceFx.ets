/**
 * 澄笺 · 外观高级开关（2026-10-20 新增）
 *
 * 两个全局开关，**默认都关闭**（用户要求：默认轻量、省电、不发热）：
 *   · `immersiveLook` 沉浸光感：关闭 → 所有卡片一律**纯色不透明**（不挂材质、不做磨砂）；
 *     开启 → 走 API 26 的 systemMaterial 光感材质（会掉帧 / 发热，开启时弹窗提醒）。
 *   · `motionFx` 过渡动画：**只控制"页面切换"**（2026-10-20 收窄语义）——
 *     关闭 → 页面进出直接显示/消失（栈跳转 animated=false、返回键 hardBack、一镜到底归零）；
 *     **展开收起、淡入淡出、按压流光等局部动效一律保留**，不再受这个开关影响。
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
   * 统一动画参数（**局部动效**：展开收起 / 淡入淡出 / 尺寸变化等）。
   * ⚠️ 2026-10-20 起**不再受「过渡动画」开关影响**——该开关只停页面切换，
   * 组件级动效按要求保留（用户："只停用页面切换时的动画，其他保留"）。
   */
  static anim(duration: number, curve: Curve = Curve.FastOutSlowIn): AnimateParam {
    const param: AnimateParam = {
      duration: duration,
      curve: curve
    };
    return param;
  }

  /**
   * **页面级**动画参数（页面进场的一镜到底等）：过渡动画关闭时 duration=0。
   * 只有"页面进出"这类动效才用它，别拿来包组件动效。
   */
  static pageAnim(duration: number, curve: Curve = Curve.FastOutSlowIn): AnimateParam {
    const param: AnimateParam = {
      duration: AppearanceFx.motion() ? duration : 0,
      curve: curve
    };
    return param;
  }

  /**
   * 统一过渡效果（局部出现/消失）——同样**不受「过渡动画」开关影响**。
   * 用法：`.transition(AppearanceFx.fx(TransitionEffect.OPACITY.animation({ duration: 200 })))`
   */
  static fx(effect: TransitionEffect): TransitionEffect {
    return effect;
  }

  /**
   * 原样透传一个 AnimateParam，但**过渡动画关闭时压成 duration 0**。
   * 用于弹簧曲线这类"不是 duration+curve 两参"的形态：
   * `animateTo(AppearanceFx.param({ curve: FOLDER_SPRING }))`
   */
  static param(p: AnimateParam): AnimateParam {
    // 局部动效参数：原样透传（不再受页面切换开关影响）
    return p;
  }

  /** 页面栈跳转的 `animated` 参数：过渡动画关闭 → false（硬切）。 */
  static navAnimated(): boolean {
    return AppearanceFx.motion();
  }
}
