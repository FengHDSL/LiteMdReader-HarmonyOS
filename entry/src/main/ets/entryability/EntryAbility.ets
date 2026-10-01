import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { setupImmersiveWindow, applyAppColorMode, syncSystemDarkFromContext } from '../service/AppWindow';
import { WallpaperStore } from '../service/WallpaperStore';
import { SettingsMirror } from '../service/SettingsMirror';
// 桌面卡片暂时停用（见 onForeground / onBackground 里的注释）：FormSync 调用一并注释
// import { FormSync } from '../service/FormSync';
import GlobalUIAbilityContext from '../util/ContextConfig';

const DOMAIN = 0x0000;

/**
 * 应用级能力入口。
 *
 * 有两件事必须在页面加载前做完：
 *  1. 注册阅读设置的持久化键（PersistentStorage.persistProp）。放在这里而不是页面里，
 *     是因为页面可能被多次重建，注册动作只应在启动时发生一次。
 *  2. 把系统深浅色同步进 AppStorage，供页面的「跟随系统」主题模式读取。
 */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'LiteMdReader', '%{public}s', 'Ability onCreate');

    // 全局上下文：手写组件等需要 UIAbilityContext 的能力从这里取
    GlobalUIAbilityContext.setContext(this.context);

    // **开启 Web 整页绘制能力**（一次性全局开关）：图表后台预渲染池的
    // webPageSnapshot 依赖它才能拿到视口之外的完整绘制结果
    webview.WebviewController.enableWholeWebPageDrawing();

    PersistentStorage.persistProp('readerFontSize', 16);
    PersistentStorage.persistProp('readerLineHeight', 1.75);
    PersistentStorage.persistProp('readerMeasure', 40);
    PersistentStorage.persistProp('readerThemeMode', 0);
    PersistentStorage.persistProp('immersiveLightEnabled', true);
    // 函数绘制壁纸（无位图）的选中款；空串 = 不用
    PersistentStorage.persistProp('wallpaperGenId', 'zhu'); // 默认竹影
    PersistentStorage.persistProp('readerBgId', 'zhu'); // 阅读背景默认竹影
    // **阅读背景图片路径**：此前漏注册 → 选完阅读背景一重启就"消失"（文件还在、路径丢了）
    PersistentStorage.persistProp('readerBgPath', '');
    // 荧光笔透明度（阅读设置里可调）
    PersistentStorage.persistProp('hlOpacity', 1);
    // 波浪线粗细（thicknessScale 0.5~3，系统波浪装饰线唯一可调项）
    PersistentStorage.persistProp('waveThickness', 1);
    // 第五轮新增的排版 / 显示设置。键名与默认值必须和 ReadingSettings 里的 @StorageLink 一致
    PersistentStorage.persistProp('readerFontFamily', '');
    PersistentStorage.persistProp('readerParaSpace', 1.0);
    PersistentStorage.persistProp('readerIndent', false);
    PersistentStorage.persistProp('readerShowMeta', true);
    PersistentStorage.persistProp('readerKeepScreenOn', false);
    // 阅读页标签栏位置：false = 顶栏下方（默认）/ true = 底部悬浮栏上方（「更多」里可切换）
    PersistentStorage.persistProp('readerTabBarAtBottom', false);
    // 窗口亮度，0 表示跟随系统；[0.05, 1] 为固定亮度
    PersistentStorage.persistProp('readerBrightness', 0);
    // 阅读背景自定义色（移植自参考项目的亮/暗分别自定义背景色）；空串 = 主题默认
    PersistentStorage.persistProp('readerCustomBgLight', '');
    PersistentStorage.persistProp('readerCustomBgDark', '');
    // 外观设置（照搬 xjau 的 AppearanceStore 语义，持久化走 PersistentStorage）
    // themeColor：'' = 跟随主题；cheng/xuan/yan/zhu/xia（澄光/宣纸/砚青/竹影/霞笺）或自定义 '#RRGGBB'
    PersistentStorage.persistProp('themeColor', '');
    PersistentStorage.persistProp('cardTint', true);
    PersistentStorage.persistProp('immersivePressGlow', true);
    PersistentStorage.persistProp('cardGlowTouch', true);
    PersistentStorage.persistProp('customAccentFull', false);
    PersistentStorage.persistProp('pageBgTint', true);
    // 灰体文本显示增强：**默认自动**（跟随主题）。
    // 自动时深浅两套各自定义（对应「深色模式用什么颜色 / 浅色模式用什么颜色」）：
    //   grayTextModeLight / grayTextModeDark：auto | gray | black | white | custom
    //   grayTextColorLight / grayTextColorDark：custom 的自定义 #RRGGBB
    // 旧的单套键 grayTextMode / grayTextColor 保留做兼容解析（见 DesignTokens.grayTextOverride）。
    PersistentStorage.persistProp('grayTextMode', 'auto');
    PersistentStorage.persistProp('grayTextColor', '');
    PersistentStorage.persistProp('grayTextModeLight', 'auto');
    PersistentStorage.persistProp('grayTextModeDark', 'auto');
    PersistentStorage.persistProp('grayTextColorLight', '');
    PersistentStorage.persistProp('grayTextColorDark', '');
    // 玻璃通透程度 0~100（越高越透明），默认 70
    PersistentStorage.persistProp('glassStrength', 70);
    // **沉浸光感强制开启**：设置项已按需求移除，这里每次启动都置回 true，
    // 免得旧版本关过它的用户升级后一直跑在降级样式上
    AppStorage.setOrCreate('immersiveLightEnabled', true);

    // 材质类型 / 等级（外观设置；口径与参考工程的 HDS systemMaterialEffect 一致）
    PersistentStorage.persistProp("appearanceMaterialType", 0);
    PersistentStorage.persistProp('appearanceMaterialLevel', 1);
    PersistentStorage.persistProp('appearanceMaterialEngine', 0);

    // 版本历史（编辑页）：自动保存开关与间隔（分钟）
    PersistentStorage.persistProp('versionAutoSave', true);
    PersistentStorage.persistProp('versionAutoSaveInterval', 5);
    // 自定义函数壁纸：表达式 + 暗端 / 亮端颜色
    PersistentStorage.persistProp('wallpaperCustomFunc', 'sin(x*4)*0.25+0.75');
    PersistentStorage.persistProp('wallpaperCustomA', '#1E222B');
    PersistentStorage.persistProp('wallpaperCustomB', '#E8EDF4');

    // 壁纸：路径 + 模糊强度 + 可读性遮罩浓度
    PersistentStorage.persistProp('wallpaperPath', '');
    PersistentStorage.persistProp('wallpaperPathLight', '');
    PersistentStorage.persistProp('wallpaperPathDark', '');
    PersistentStorage.persistProp('wallpaperBlur', 4);
    PersistentStorage.persistProp('wallpaperScrim', 42);
    // 沙箱里的壁纸可能被清掉（清数据 / 换设备），启动时校验一次，避免背景空一块；
    // 同时做"键丢了但文件还在"的自愈（应用壁纸 + 阅读背景各一次）
    WallpaperStore.validate(this.context);
    WallpaperStore.validateReaderBg(this.context);
    // 卡片降级样式：mica（云母磨砂）/ solid（实色纯底）
    PersistentStorage.persistProp('cardFallback', 'mica');
    PersistentStorage.persistProp('particleDissolve', true); // 默认开启（用户要求）
    // 老安装的持久化值可能是 false（此前默认关）——启动时强制开一次，
    // 用户之后仍可通过外观设置关闭（本会话内生效）
    AppStorage.setOrCreate('particleDissolve', true);
    // 设置镜像的写入时间戳（与 settings.json 里的 at 比新旧，决定启动时用哪份）
    PersistentStorage.persistProp(SettingsMirror.KEY_SAVED_AT, 0);

    // **文件镜像兜底**：PersistentStorage 在部分设备上没真正落盘（表现为
    // "设置改完、退出应用重进就恢复默认"）。放在 persistProp 之后恢复，
    // 镜像更新时覆盖刚读进来的值 —— 见 service/SettingsMirror.ets 的冲突处理说明。
    SettingsMirror.restore(this.context);

    // **应用级颜色模式跟随应用内主题**（浅色模式下系统部件出白字的根因修复）：
    // 深色 → DARK / 浅色 → LIGHT / 跟随系统 → NOT_SET
    const themeRaw: number | undefined = AppStorage.get<number>('readerThemeMode');
    applyAppColorMode(themeRaw !== undefined && themeRaw !== null ? themeRaw : 0);

    this.syncSystemColorMode();
  }

  onDestroy(): void {
    SettingsMirror.save(this.context);
    hilog.info(DOMAIN, 'LiteMdReader', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 必须在 loadContent 之前进入沉浸模式，否则首帧会先按非沉浸布局渲染一次，出现闪动
    setupImmersiveWindow(windowStage);

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'LiteMdReader', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'LiteMdReader', '%{public}s', 'Succeeded in loading the content.');
    });

    try {
      // **颜色模式由应用内主题驱动**（applyAppColorMode 已在 onCreate 同步），
      // 这里按恢复出的主题再设一次，保证窗口期配色同向
      const themeRaw2: number | undefined = AppStorage.get<number>('readerThemeMode');
      applyAppColorMode(themeRaw2 !== undefined && themeRaw2 !== null ? themeRaw2 : 0);
    } catch (err) {
      hilog.error(DOMAIN, 'LiteMdReader', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'LiteMdReader', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'LiteMdReader', '%{public}s', 'Ability onForeground');
    // **回前台补一次系统深浅同步**：用户在后台（或系统设置里）改了深浅色时，
    // 这个时机最可靠——部分设备切深浅并不下发 onConfigurationUpdate。
    this.syncSystemColorMode();
    // 桌面卡片：**暂时停用**（用户要求，卡片有 bug 待修），推送一并关掉。
    // 恢复时取消注释即可（同时要在 module.json5 里恢复 EntryFormAbility 注册）。
    // try {
    //   FormSync.pushRecents(this.context, false);
    // } catch (err) {
    //   // 推送失败不影响主流程
    // }
  }

  /** 退到后台 / 被系统回收前落盘一次设置镜像（用户"退出应用"最常见的路径）。 */
  onBackground(): void {
    SettingsMirror.save(this.context);
    // 桌面卡片兜底推送：随卡片一起停用（恢复时取消注释）
    // try {
    //   FormSync.pushRecents(this.context, true);
    // } catch (err) {
    //   // 卡片推送失败不影响主流程
    // }
    hilog.info(DOMAIN, 'LiteMdReader', '%{public}s', 'Ability onBackground');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.syncSystemColorMode();
  }

  private syncSystemColorMode(): void {
    // 统一走 AppWindow.syncSystemDarkFromContext：它会读 config.colorMode、
    // **值有变化才写 AppStorage**（避免无意义的整树刷新），读不到时沿用旧值。
    // 页面侧 onPageShow 也会调一次，用于兜住"系统切深浅但不下发 onConfigurationUpdate"
    // 的设备（用户反馈的「必须重启应用才生效」就是这个）。
    syncSystemDarkFromContext();
  }
}
