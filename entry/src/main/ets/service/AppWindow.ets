/**
 * LiteMdReader · 窗口沉浸（状态栏 / 导航栏）
 * ==========================================
 *
 * 默认情况下应用窗口不占用状态栏与导航栏区域，系统会用窗口底色把那两条填满——
 * 在浅色主题下就表现为屏幕顶部、底部各一条「大白条」。
 *
 * 两件事一起做才算真沉浸，缺一不可：
 *  ① `setWindowLayoutFullScreen(true)`：让页面布局延伸进状态栏与导航栏区域；
 *  ② `setWindowSystemBarProperties(...)` 把两条系统栏的底色设成**透明**。
 *     只做 ① 的话，系统栏仍会画出自己的底色，看起来依旧是一条色带。
 *
 * 布局延伸之后，正文不能直接压在状态栏下面，所以这里把「避让区」高度也读出来，
 * 由各页面按需内缩（见 `safeTopPx` / `safeBottomPx`）。
 *
 * 注意：px2vp 依赖 UI 上下文，放在 Ability 生命周期里调用不可靠，
 * 因此这里存的是**原始 px**，换算交给页面做。
 */

import { window } from '@kit.ArkUI';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ReaderThemeMode } from '../theme/DesignTokens';
import GlobalUIAbilityContext from '../util/ContextConfig';

/** 状态栏避让区高度（px），由页面用 px2vp 换算 */
export const SAFE_TOP_PX: string = 'safeTopPx';
/** 导航栏 / 手势条避让区高度（px） */
export const SAFE_BOTTOM_PX: string = 'safeBottomPx';

/** 主窗口句柄。系统的 Window 对象不能进 AppStorage（无法跨序列化），所以用模块级变量持有。 */
let mainWindow: window.Window | null = null;

/** 是否成功进入沉浸模式。失败时页面退回系统默认布局，界面依然可用。 */
let immersiveReady: boolean = false;

export function isImmersiveWindow(): boolean {
  return immersiveReady;
}

/**
 * 在 `onWindowStageCreate` 里调用一次。
 * 必须在 `loadContent` 之前调用，否则首帧会先按非沉浸布局渲染一次，出现一次闪动。
 */
export function setupImmersiveWindow(windowStage: window.WindowStage): void {
  try {
    const win: window.Window = windowStage.getMainWindowSync();
    mainWindow = win;
    win.setWindowLayoutFullScreen(true);

    // 系统栏底色透明：不放开的话，系统栏会画自己的底色，压在应用内容之上
    const barProperties: window.SystemBarProperties = {
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: '#FF1B1F27',
      navigationBarContentColor: '#FF1B1F27'
    };
    win.setWindowSystemBarProperties(barProperties);

    syncAvoidArea(win);
    immersiveReady = true;

    // 旋转、折叠、手势条显隐都会改变避让区，必须跟着更新，否则正文会被状态栏盖住
    win.on('avoidAreaChange', () => {
      syncAvoidArea(win);
    });

    // 键盘高度广播：编辑页底部工具层「固定在键盘之上」靠它。
    // 数据源用 **avoidAreaChange 的 TYPE_KEYBOARD**（键盘真实占位）；
    // 之前用 keyboardHeightChange，其上报值与实际面板高度不一致，
    // 导致工具层悬在键盘上方一大截（用户截图证实）。
    win.on('avoidAreaChange', (data) => {
      if (data.type === window.AvoidAreaType.TYPE_KEYBOARD) {
        AppStorage.setOrCreate('keyboardPx', data.area.bottomRect.height);
      }
      syncAvoidArea(win);
    });
    try {
      const kb: window.AvoidArea =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD);
      AppStorage.setOrCreate('keyboardPx', kb.bottomRect.height);
    } catch (err) {
      AppStorage.setOrCreate('keyboardPx', 0);
    }
  } catch (err) {
    immersiveReady = false;
  }
}

function syncAvoidArea(win: window.Window): void {
  try {
    const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const bottom: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    AppStorage.setOrCreate(SAFE_TOP_PX, sys.topRect.height);
    AppStorage.setOrCreate(SAFE_BOTTOM_PX, bottom.bottomRect.height);
  } catch (err) {
    // 读不到避让区时按 0 处理，最坏情况是正文贴到状态栏边缘，不影响可用性
  }
}

/**
 * 按当前明暗切换系统栏图标颜色。
 * 底色是透明的，图标如果还是黑的，在深色主题下会看不清。
 */
export function applySystemBarTheme(dark: boolean): void {
  const win: window.Window | null = mainWindow;
  if (win === null) {
    return;
  }
  const content: string = dark ? '#FFFFFFFF' : '#FF1B1F27';
  const barProperties: window.SystemBarProperties = {
    statusBarColor: '#00000000',
    navigationBarColor: '#00000000',
    statusBarContentColor: content,
    navigationBarContentColor: content
  };
  try {
    win.setWindowSystemBarProperties(barProperties);
  } catch (err) {
    // 切换失败只影响图标配色，不阻断阅读
  }
}

/**
 * **应用级颜色模式跟随应用内主题**（用户反馈：浅色模式下部分半模态面板文字白色不可见）。
 *
 * 根因：应用 colorMode 一直是 NOT_SET（跟随系统）。系统停在深色、应用内切到浅色时，
 * 系统渲染的部件（半模态面板的官方标题栏 / 关闭按钮等）按**系统深色**配色出白字，
 * 落在应用的浅色面板上就看不见了。
 * 同步后（Dark→COLOR_MODE_DARK / Light→COLOR_MODE_LIGHT / 跟随系统→NOT_SET），
 * 系统部件与应用配色永远同向；EntryAbility.onConfigurationUpdate 里的 systemDark
 * 也会随之同步，材质深浅、系统栏等整条链路一起跟正。
 */
export function applyAppColorMode(themeMode: number): void {
  const c = GlobalUIAbilityContext.getContext();
  if (c === null) {
    return;
  }
  try {
    if (themeMode === ReaderThemeMode.Dark) {
      c.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } else if (themeMode === ReaderThemeMode.Light) {
      c.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } else {
      c.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    }
  } catch (err) {
    // 同步失败下次主题变更再试，不阻断主流程
  }
}

/**
 * 各页面最近一次"已生效"的明暗状态（模块级，跨组件重建保留）。
 *
 * **为什么需要它**：实机日志证明 `@StorageProp('systemDark')` 上的 `@Watch`
 * 在 AppStorage 被 Ability 侧改写时**不会触发**（值确实变了、回调一次都不来），
 * 于是当前页面只更新一部分，用户得进别的页面才完全刷新。
 * 各页面在 onPageShow / onShown 时用这份记录跟自己的实际明暗比一比，
 * 不一致就强制重建整棵树（见各页的 themeEpoch / renderEpoch）。
 */
class ThemeState {
  /** 上次已应用到界面的"有效明暗"（含应用内主题覆盖） */
  static appliedDark: boolean = false;
  /** 是否已初始化过（首帧不算变化） */
  static inited: boolean = false;
}

/** 记录"界面已经用上了这个明暗"（各页刷新完调用）。 */
export function markThemeApplied(dark: boolean): void {
  ThemeState.appliedDark = dark;
  ThemeState.inited = true;
}

/** 供页面判断：当前明暗跟"界面已用上的"是否不同。 */
export function themeChangedSince(dark: boolean): boolean {
  return ThemeState.inited && ThemeState.appliedDark !== dark;
}

/**
 * 页面可见时的**环境变化探测器**。
 *
 * 为什么需要：实机日志证明切系统深浅时，
 *   · `onConfigurationUpdate` 会来、AppStorage 里的 systemDark 也写对了；
 *   · 但 `@StorageProp` 的 `@Watch` **不触发**，`@StorageProp` 的值变化也不一定
 *     让当前页面重绘 —— 于是用户必须先离开再回来（各页 onPageShow 里的比对）才刷新。
 * 所以可见期间用一个很轻的定时器（默认 700ms）主动问一次系统浓淡：
 * 一旦真的变了，就调用页面传进来的回调强制重建整页 —— 肉眼就是"切换后立刻刷新"。
 *
 * 只在页面可见时跑（onPageShow 启动 / onPageHide 停止），不做常驻轮询。
 */
class ThemeWatchdog {
  private static timer: number = -1;

  static start(onChanged: () => void, intervalMs: number = 700): void {
    ThemeWatchdog.stop();
    try {
      ThemeWatchdog.timer = setInterval(() => {
        const before: boolean = ThemeState.appliedDark;
        const dark: boolean = syncSystemDarkFromContext();
        if (!ThemeState.inited) {
          // 首帧：只登记，不触发刷新
          markThemeApplied(dark);
          return;
        }
        if (before !== dark) {
          markThemeApplied(dark);
          hilog.info(0x0000, 'LiteMdReader', 'ThemeWatchdog: 系统明暗变化 → 刷新页面（%{public}s）',
            dark ? 'dark' : 'light');
          onChanged();
        }
      }, intervalMs);
    } catch (err) {
      // 定时器不可用不影响其它功能
    }
  }

  static stop(): void {
    if (ThemeWatchdog.timer >= 0) {
      try {
        clearInterval(ThemeWatchdog.timer);
      } catch (err) {
        // 忽略
      }
      ThemeWatchdog.timer = -1;
    }
  }
}

/** 启动可见期轮询（页面 onPageShow / onShown 调）。 */
export function startThemeWatchdog(onChanged: () => void): void {
  ThemeWatchdog.start(onChanged);
}

/** 停止可见期轮询（页面 onPageHide / onHidden 调）。 */
export function stopThemeWatchdog(): void {
  ThemeWatchdog.stop();
}

/**
 * **把系统当前深浅色同步进 AppStorage `systemDark`**（跟随系统的唯一事实来源）。
 *
 * 实机验证过的链路：
 *   · `onConfigurationUpdate` 会来（日志里能看到 colorMode 值）；
 *   · 这里也会把 `systemDark` 写对（日志：系统=dark 变化=true）；
 *   · **但 @Watch 不会触发**——所以页面刷新不能依赖它，必须由页面自己比对
 *     （themeChangedSince + 各页 onPageShow 里的刷新）。
 *
 * 返回值：当前系统是否深色。读不到配置时沿用 AppStorage 里的旧值。
 */
export function syncSystemDarkFromContext(): boolean {
  const c = GlobalUIAbilityContext.getContext();
  let dark: boolean | undefined = undefined;
  if (c !== null) {
    try {
      const mode: ConfigurationConstant.ColorMode | undefined = c.config.colorMode;
      if (mode !== undefined && mode !== null) {
        dark = mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      }
    } catch (err) {
      dark = undefined;
    }
  }
  if (dark === undefined) {
    const old: boolean | undefined = AppStorage.get<boolean>('systemDark');
    return old === true;
  }
  if (AppStorage.get<boolean>('systemDark') !== dark) {
    AppStorage.setOrCreate('systemDark', dark);
  }
  return dark;
}

// ══════════════════════ 阅读显示设置 ══════════════════════
//
// 屏幕常亮与亮度调节都作用于主窗口。亮度取值 [0, 1]；
// **-1.0 表示交还系统亮度**（SDK 文档明确的语义，不是"最暗"），
// 退出阅读页或用户关掉开关时用 -1.0 恢复，否则系统控制中心的亮度条会被锁死。

/** 屏幕常亮开关（阅读时不熄屏）。 */
export function setKeepScreenOn(on: boolean): void {
  const win: window.Window | null = mainWindow;
  if (win === null) {
    return;
  }
  try {
    win.setWindowKeepScreenOn(on);
  } catch (err) {
    // 失败只影响体验，不阻断
  }
}

/**
 * 设置窗口亮度。value 取 [0.05, 1.0]；传 -1（或 0）表示恢复跟随系统。
 * 设为固定值期间，控制面板调系统亮度不会生效——这是窗口级亮度的既定行为。
 */
export function setWindowBrightnessLevel(value: number): void {
  const win: window.Window | null = mainWindow;
  if (win === null) {
    return;
  }
  let target: number = value;
  if (target < 0.05 || target > 1) {
    target = -1.0;
  }
  try {
    win.setWindowBrightness(target);
  } catch (err) {
    // 部分设备（模拟器 / PC）不支持窗口亮度，失败即静默
  }
}
