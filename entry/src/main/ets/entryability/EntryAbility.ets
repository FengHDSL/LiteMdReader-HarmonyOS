import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PageWarmup } from '../service/PageWarmup';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
// 接收其他应用分享的数据（分享面板 → 澄笺）
import { systemShare } from '@kit.ShareKit';
import { setupImmersiveWindow, applyAppColorMode, syncSystemDarkFromContext } from '../service/AppWindow';
import { WallpaperStore } from '../service/WallpaperStore';
import { SettingsMirror } from '../service/SettingsMirror';
import { L10n } from '../service/L10n';
import { DocStore } from '../service/DocStore';
import { BackupStore } from '../service/BackupStore';
import { WebDavStore } from '../service/WebDavStore';
// 桌面卡片数据同步（2×2 最近阅读卡片）：onForeground/onBackground 主动推送
import { FormSync } from '../service/FormSync';
import GlobalUIAbilityContext from '../util/ContextConfig';

const DOMAIN = 0x0000;

/**
 * 正文字重键的旧值归零。这一档最早存的是**档位字符串**（'follow' / 'medium' …），
 * 现在两把字重键统一是**绝对数值**（0 = 跟随，100~900）。老设备上残留的字符串会让
 * 整棵正文树拿非数值去算字重，所以镜像恢复之后立刻洗一次。
 * 只洗类型，不猜语义：数值 100 / 200 在新旧两套语义里都合法，不能当"旧值"清掉。
 */
function normalizeBodyWeight(): void {
  const raw: number | undefined = AppStorage.get<number>('readerFontWeight');
  if (raw !== undefined && typeof raw !== 'number') {
    AppStorage.setOrCreate('readerFontWeight', 0);
  }
}

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

    // **跨设备接续**（多设备流转）：冷启动的迁移恢复（热启动走 onNewWant）
    if (launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION) {
      this.restoreContinueData(want);
    }

    // **外部内容落地**：既可能是"打开方式"关联的 .md 文件（want.uri），
    // 也可能是其他应用「分享」过来的文本 / 文件（Share Kit 的 sendData）——
    // 统一交给 handleSharedData：它先试分享数据，失败再退回 want.uri
    this.handleSharedData(want);

    // **桌面卡片点击路由**（冷启动）
    this.handleCardAction(want);

    // 全局上下文：手写组件等需要 UIAbilityContext 的能力从这里取
    GlobalUIAbilityContext.setContext(this.context);

    // **开启 Web 整页绘制能力**（一次性全局开关）：图表后台预渲染池的
    // webPageSnapshot 依赖它才能拿到视口之外的完整绘制结果
    webview.WebviewController.enableWholeWebPageDrawing();

    // 使用模式：'' 未选择（首次启动会弹窗让用户选）/ 'full' 全量 / 'offline' 基础（纯离线）
    PersistentStorage.persistProp('appMode', '');
    PersistentStorage.persistProp('reviewSwapMode', false);
    PersistentStorage.persistProp('reviewTypingMode', false);
    // 已经弹过「本次更新内容」的版本号（更新后首次启动弹一次）
    PersistentStorage.persistProp('lastSeenVersion', '');
    // 上次自动检查更新的时间戳（固定 48 小时一次）
    PersistentStorage.persistProp('lastAutoCheckAt', 0);
    // 好评鼓励：本机是否已经自动弹过一次应用内评分框（满 24 小时只弹一次，弹过不再打扰）
    PersistentStorage.persistProp('ratingPrompted', false);

    PersistentStorage.persistProp('readerFontSize', 16);
    // 正文字重：0 = 跟随原样式，100~900 = 整篇绝对覆盖（见 HwFont.bodyWeight）
    PersistentStorage.persistProp('readerFontWeight', 0);
    PersistentStorage.persistProp('readerLineHeight', 1.75);
    PersistentStorage.persistProp('readerMeasure', 40);
    PersistentStorage.persistProp('readerThemeMode', 0);
    // 旧「材质开关」（内层开关，设置页已不暴露）：**必须恒为 true**。
    // 用户真正控制的是 immersiveLook；1.1.5 曾把它默认成 false，
    // 结果磁盘被写成 false，开光感也不挂材质（用户反馈「效果像开到了最低」）。
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
    // 停靠侧边栏宽度记忆（大屏横屏：拖分隔条调过的位置，侧滑再拉开保持不变）
    PersistentStorage.persistProp('readerTocPanelW', 300);
    PersistentStorage.persistProp('readerNotesPanelW', 300);
    // 第五轮新增的排版 / 显示设置。键名与默认值必须和 ReadingSettings 里的 @StorageLink 一致
    PersistentStorage.persistProp('readerFontFamily', '');
    // 英数字体：与中文字体分开设置，靠 fontFamily 列表按字符回退（见 HwFont.family）
    PersistentStorage.persistProp('readerFontFamilyEn', '');
    // **界面字体**（外观设置）：空串 = 系统默认；syncReader = 是否把这款字体也用到阅读正文
    PersistentStorage.persistProp('appFontFamily', '');
    PersistentStorage.persistProp('appFontFamilyEn', '');
    PersistentStorage.persistProp('appFontSyncReader', false);
    // 界面字号缩放系数（1 = 不调）与字重相对加粗量（0 = 不调，100 / 200 两档）
    PersistentStorage.persistProp('appFontScale', 1);
    PersistentStorage.persistProp('appFontWeightDelta', 0);
    PersistentStorage.persistProp('readerParaSpace', 1.0);
    PersistentStorage.persistProp('readerIndent', false);
    // 网页开放（阅读页「更多」面板开关）：开启后点正文 http(s) 链接半模态打开
    PersistentStorage.persistProp('readerWebOpen', false);
    // **卡片滑动忽略**（阅读页「更多」）：默认开 —— 滑到卡片上不被停住
    PersistentStorage.persistProp('readerCardSwipeIgnore', true);
    // 目录 / 批注侧边栏是否使用沉浸光感（关闭后用阅读背景色）
    PersistentStorage.persistProp('drawerImmersive', true);
    PersistentStorage.persistProp('readerShowMeta', true);
    // 引擎管理：被关闭的渲染引擎列表（逗号分隔 id，空串 = 全部开启）
    PersistentStorage.persistProp('disabledEngines', '');
    PersistentStorage.persistProp('readerKeepScreenOn', false);
    // 阅读页标签栏位置：false = 顶栏下方（默认）/ true = 底部悬浮栏上方（「更多」里可切换）
    PersistentStorage.persistProp('readerTabBarAtBottom', false);
    // 大屏 / 平板横屏专属：侧边栏「默认展开」偏好（更多面板里设置，仅宽屏显示）
    PersistentStorage.persistProp('readerTocPinnedDefault', true);
    PersistentStorage.persistProp('readerNotesPinnedDefault', true);
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
    // 标签拖动排序后的顺序（JSON 字符串数组，见 service/TagStore.ets）
    PersistentStorage.persistProp('tagOrder', '[]');
    PersistentStorage.persistProp('customAccentFull', false);
    PersistentStorage.persistProp('pageBgTint', true);
    // **手机端横屏开关**（外观设置里那一行，只在手机上显示）：默认关 = 锁竖屏
    PersistentStorage.persistProp('phoneLandscape', false);
    // 灰体文本显示增强：**默认自动**（跟随主题）。
    // 自动时深浅两套各自定义（对应「深色模式用什么颜色 / 浅色模式用什么颜色」）：
    //   grayTextModeLight / grayTextModeDark：auto | gray | black | white | custom
    //   grayTextColorLight / grayTextColorDark：custom 的自定义 #RRGGBB
    // 旧的单套键 grayTextMode / grayTextColor 保留做兼容解析（见 DesignTokens.grayTextOverride）。
    PersistentStorage.persistProp('grayTextMode', 'auto');
    PersistentStorage.persistProp('grayTextColor', '');
    // 深浅两套灰体配置的默认值：**自动**（有背景亮度信息才按对比度覆盖，
    // 否则跟随主题原本的灰字——用户要求默认自动）
    PersistentStorage.persistProp('grayTextModeLight', 'auto');
    PersistentStorage.persistProp('grayTextModeDark', 'auto');
    PersistentStorage.persistProp('grayTextColorLight', '');
    PersistentStorage.persistProp('grayTextColorDark', '');
    // 玻璃通透程度 0~100（越高越透明），默认 70
    PersistentStorage.persistProp('glassStrength', 70);
    // **沉浸光感改为用户可控**（2026-10-20）：外观设置新增「沉浸光感」总开关，
    // **默认关闭**（关掉后卡片纯色不透明，更省电、帧率更稳）。
    // 这里不再强制置 true——否则用户关了光感、下次启动又被打开。
    PersistentStorage.persistProp('immersiveLook', false);
    // 光感档位：default 完整材质 / eco 节能（磨砂降级）
    PersistentStorage.persistProp('immersiveGrade', 'default');
    // 过渡动画总开关，**默认关闭**（关掉后所有动效瞬时完成、页面硬切）
    PersistentStorage.persistProp('motionFx', false);
    // 「页面组件预热」beta 开关，默认关闭（关闭后不预热、不占内存）
    PersistentStorage.persistProp('preloadPages', false);
    // 纠正：磁盘上若已被写成 false（1.1.5 首次启动的默认值），这里拉回 true。
    // persistProp 建立的是双向同步，这一步会同时覆盖磁盘。
    if (AppStorage.get<boolean>('immersiveLightEnabled') !== true) {
      AppStorage.setOrCreate('immersiveLightEnabled', true);
    }

    // 材质类型 / 等级（外观设置；口径与参考工程的 HDS systemMaterialEffect 一致）
    PersistentStorage.persistProp("appearanceMaterialType", 0);
    PersistentStorage.persistProp('appearanceMaterialLevel', 1);
    PersistentStorage.persistProp('appearanceMaterialEngine', 0);

    // 版本历史（编辑页）：自动保存开关与间隔（分钟）
    PersistentStorage.persistProp('versionAutoSave', true);
    PersistentStorage.persistProp('versionAutoSaveInterval', 5);

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
    // 书架顶部「继续阅读」卡片是否显示（外观设置里的开关）
    PersistentStorage.persistProp('shelfResumeBanner', true);
    // 书架「回头看看」卡片：**默认关闭**（用户要求），在「写作日志」页里开启
    PersistentStorage.persistProp('shelfMemoryCard', false);
    // 手写画布背景：底色（空 = 跟随主题）+ 底纹（none / grid / lines / dots）+ 线条粗细
    PersistentStorage.persistProp('sketchBgColor', '');
    PersistentStorage.persistProp('sketchBgPattern', 'none');
    PersistentStorage.persistProp('sketchBgLineWidth', 1);
    PersistentStorage.persistProp('particleDissolve', true); // 默认开启（用户要求）
    // 老安装的持久化值可能是 false（此前默认关）——启动时强制开一次，
    // 用户之后仍可通过外观设置关闭（本会话内生效）
    AppStorage.setOrCreate('particleDissolve', true);
    // 设置镜像的写入时间戳（与 settings.json 里的 at 比新旧，决定启动时用哪份）
    PersistentStorage.persistProp(SettingsMirror.KEY_SAVED_AT, 0);
    // 应用语言（外观设置里的选择器）：'system' = 跟随系统，其它是内置语言 id；
    // languageTick 是刷新计数，页面靠它重画文案（见 service/L10n.ets）
    PersistentStorage.persistProp('appLanguage', 'system');
    PersistentStorage.persistProp('languageTick', 0);

    // **文件镜像兜底**：PersistentStorage 在部分设备上没真正落盘（表现为
    // "设置改完、退出应用重进就恢复默认"）。放在 persistProp 之后恢复，
    // 镜像更新时覆盖刚读进来的值 —— 见 service/SettingsMirror.ets 的冲突处理说明。
    SettingsMirror.restore(this.context);
    // **旧「自定义函数壁纸」这个 id 已经不存在了**：存过 'custom' 的设备会既画不出
    // 对应的款、设置页也没有任何芯片高亮，看起来像"壁纸丢了"。归零成「不用程序化壁纸」。
    if (AppStorage.get<string>('wallpaperGenId') === 'custom') {
      AppStorage.setOrCreate('wallpaperGenId', '');
    }
    // **正文字重键的旧值归零**：这一档最早存的是档位字符串（'follow' / 'medium' …），
    // 现在改成绝对数值（0 = 跟随）。老设备上留着一个字符串会让整棵正文树拿到非数值去算字重。
    normalizeBodyWeight();
    // 收藏名单的第二腿：按镜像把收藏标记补回 shelf.json（真机上出现过重启丢收藏）
    DocStore.applyStarredMirror(this.context);
    // 应用语言：把持久化的选择同步给平台（setAppPreferredLanguage 是冷启动生效，
    // 应用内文案走 L10n 词典，切语言当帧就能看见）
    L10n.init();

    // **应用级颜色模式跟随应用内主题**（浅色模式下系统部件出白字的根因修复）：
    // 深色 → DARK / 浅色 → LIGHT / 跟随系统 → NOT_SET
    const themeRaw: number | undefined = AppStorage.get<number>('readerThemeMode');
    applyAppColorMode(themeRaw !== undefined && themeRaw !== null ? themeRaw : 0);

    this.syncSystemColorMode();
  }

  onDestroy(): void {
    PageWarmup.clear();
    SettingsMirror.save(this.context);
    hilog.info(DOMAIN, 'LiteMdReader', '%{public}s', 'Ability onDestroy');
  }

  /** 应用已在运行时，再次被"打开方式" / 分享拉起（热启动）也要接住新内容 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleSharedData(want);
    // **桌面卡片点击路由**（热启动；冷启动走 onCreate 同名分支）
    this.handleCardAction(want);
    // **跨设备接续**：热启动也要接住迁移数据（冷启动走 onCreate 同名分支）
    if (launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION) {
      this.restoreContinueData(want);
    }
  }

  /**
   * 桌面卡片点击路由（postCardAction router 带 params）：
   *   · target=doc   → 打开指定文档（name 参数）；
   *   · target=newdoc → 进编辑器新建；
   *   · target=shelf → 回书架（无阅读记录时点卡片）。
   * UIAbility 不能直接路由 Navigation 栈，写 AppStorage 信号由书架页
   * （Index.onPageShow）消费——与 pendingOpenDocName 同一套模式。
   */
  private handleCardAction(want: Want): void {
    try {
      const params: Record<string, Object> | undefined = want.parameters;
      if (params === undefined) {
        return;
      }
      const target: Object | undefined = params['target'];
      if (target === undefined || target === null) {
        return;
      }
      const t: string = target as string;
      if (t === 'doc') {
        const raw: Object | undefined = params['name'];
        const name: string = raw === undefined || raw === null ? '' : raw as string;
        if (name.length > 0) {
          AppStorage.setOrCreate('formJumpDoc', name);
        }
      } else if (t === 'newdoc') {
        // tick 自增保证连续点两次也能触发 @StorageProp 变更
        const tick: number = AppStorage.get<number>('formJumpNewDoc') ?? 0;
        AppStorage.setOrCreate('formJumpNewDoc', tick + 1);
      } else if (t === 'study') {
        // 学习卡「具体」按钮：进背诵页看批注详情（Index.onPageShow 消费）
        const tick: number = AppStorage.get<number>('formJumpStudy') ?? 0;
        AppStorage.setOrCreate('formJumpStudy', tick + 1);
      }
      // target=shelf 无需信号：拉起后本来就落在书架
    } catch (err) {
      // 解析失败不影响启动
    }
  }

  /**
   * **多设备流转 · 源端**（用户要求）：跨设备迁移发起时把当前阅读现场
   * （文档名 / 正文 / 进度行）写进 wantParam——正文 ≤90KB 直接传；
   * 超长文档只迁移名字与进度（正文不完整，目标端会提示）。
   */
  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    const name: string = AppStorage.get<string>('continueDocName') ?? '';
    if (name.length === 0) {
      return AbilityConstant.OnContinueResult.AGREE;
    }
    const content: string = AppStorage.get<string>('continueDocContent') ?? '';
    const progress: number = AppStorage.get<number>('continueDocProgress') ?? 0;
    const oversize: boolean = content.length > 90000;
    wantParam['continueDocName'] = name;
    wantParam['continueDocContent'] = oversize ? '' : content;
    wantParam['continueOversize'] = oversize ? '1' : '0';
    wantParam['continueProgressRatio'] = progress;
    return AbilityConstant.OnContinueResult.AGREE;
  }

  /** **多设备流转 · 目标端**：从迁移参数恢复 → 写 pendingContinue* 交给书架页落盘并打开。 */
  private restoreContinueData(want: Want): void {
    const params: Record<string, Object> | undefined =
      want.parameters === undefined ? undefined : want.parameters as Record<string, Object>;
    if (params === undefined) {
      return;
    }
    const name: string = (params['continueDocName'] as string) ?? '';
    if (name.length === 0) {
      return;
    }
    AppStorage.setOrCreate('pendingContinueDocName', name);
    AppStorage.setOrCreate('pendingContinueDocContent', (params['continueDocContent'] as string) ?? '');
    AppStorage.setOrCreate('pendingContinueOversize', (params['continueOversize'] as string) ?? '0');
    AppStorage.setOrCreate('pendingContinueProgress', (params['continueProgressRatio'] as number) ?? 0);
  }

  /**
   * **迁移恢复的窗口阶段**：接续启动不会走 onWindowStageCreate——官方要求
   * 其中的初始化逻辑在这里**同样执行**，否则沉浸窗口没设置 → 背景不全屏、
   * 顶/底白条、底栏安全区计算全部异常（用户实测）。loadContent 逻辑保持一致。
   */
  onWindowStageRestore(windowStage: window.WindowStage): void {
    // 与 onWindowStageCreate 相同：必须在 loadContent 之前进入沉浸模式
    setupImmersiveWindow(windowStage);

    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(DOMAIN, 'LiteMdReader', 'restore loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'LiteMdReader', '%{public}s', 'restore loadContent succeeded.');
    });

    try {
      const themeRaw2: number | undefined = AppStorage.get<number>('readerThemeMode');
      applyAppColorMode(themeRaw2 !== undefined && themeRaw2 !== null ? themeRaw2 : 0);
    } catch (err) {
      hilog.error(DOMAIN, 'LiteMdReader', 'restore colorMode failed: %{public}s',
        JSON.stringify(err));
    }
  }

  /**
   * **关联 .md 文件**（用户要求）：读取外部传来的文件内容，**立即导入为一篇新文档**
   * （在 onCreate / onNewWant 阶段读，此时持有 uri 的临时授权；稍后读会失效）。
   * 导入结果写进 AppStorage（pendingOpenDocName），书架页 onShow 时检测并刷新 + 提示。
   */
  /**
   * **接收其他应用分享的内容**（用户要求：分享到澄笺）。
   *
   * 两条来源：
   *  1. Share Kit 的标准分享（`systemShare.getSharedData`）—— 文本在 `content`、
   *     文件在 `uri`，标题在 `title`，这是「分享面板 → 澄笺」的主路径；
   *  2. 老式的 `want.uri`（部分入口如"用其他应用打开"也走 sendData）。
   * 解析失败（不是分享数据 / 能力不可用）时退回第 2 条，保证不空跑。
   *
   * 导入完成后写 `pendingOpenDocName`，书架页 onShow 时读它刷新并提示 ——
   * 与「打开方式关联」共用同一条落地链路。
   */
  private handleSharedData(want: Want): void {
    systemShare.getSharedData(want).then((data: systemShare.SharedData) => {
      let handled: boolean = false;
      try {
        const records: systemShare.SharedRecord[] = data.getRecords();
        for (let k: number = 0; k < records.length; k++) {
          const rec: systemShare.SharedRecord = records[k];
          const title: string = rec.title !== undefined ? rec.title : '';
          // 文件型记录优先按文件导入（uri → 沙箱副本）
          if (rec.uri !== undefined && rec.uri.length > 0) {
            if (this.importFileFromUri(rec.uri, title)) {
              handled = true;
              break;
            }
          } else if (rec.content !== undefined && rec.content.length > 0) {
            if (this.importTextContent(rec.content, title)) {
              handled = true;
              break;
            }
          }
        }
      } catch (err) {
        hilog.warn(DOMAIN, 'LiteMdReader', 'read shared records failed: %{public}s',
          JSON.stringify(err));
      }
      if (!handled) {
        this.handleOpenFile(want);
      }
    }).catch((err: BusinessError) => {
      // 不是分享数据（普通 viewData 启动等）：走老路径
      hilog.info(DOMAIN, 'LiteMdReader', 'not shared data: %{public}s', err.message);
      this.handleOpenFile(want);
    });
  }

  /** 分享来的**文本**：直接建一篇文档，标题取分享标题，取不到就用首行 / 时间。 */
  private importTextContent(content: string, title: string): boolean {
    try {
      let name: string = title.trim();
      if (name.length === 0) {
        const firstLine: string = content.split('\n')[0].trim().replace(/^#+\s*/, '');
        name = firstLine.length > 0 ? firstLine.substring(0, 20) : L10n.t('分享内容');
      }
      name = DocStore.sanitizeName(name);
      if (name.length === 0) {
        name = '分享内容';
      }
      let finalName: string = name;
      if (DocStore.exists(this.context, finalName)) {
        finalName = name + ' ' + new Date().getHours().toString()
          + new Date().getMinutes().toString() + new Date().getSeconds().toString();
      }
      const meta = DocStore.create(this.context, finalName, content);
      if (meta === null) {
        return false;
      }
      AppStorage.setOrCreate('pendingOpenDocName', meta.name);
      hilog.info(DOMAIN, 'LiteMdReader', '%{public}s', 'shared text imported: ' + meta.name);
      return true;
    } catch (err) {
      hilog.error(DOMAIN, 'LiteMdReader', 'import shared text failed: %{public}s',
        JSON.stringify(err));
      return false;
    }
  }

  /**
   * 读取外部 uri 指向的文件并导入为一篇文档。
   * `nameHint` 非空时优先当标题（分享记录里带的 title 比 uri 尾段更准）。
   */
  private importFileFromUri(uri: string, nameHint: string): boolean {
    try {
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      // 上限 2MB：Markdown 文本远小于此，防异常超大文件拖垮启动
      const size: number = stat.size > 2 * 1024 * 1024 ? 2 * 1024 * 1024 : stat.size;
      const buffer = new ArrayBuffer(size);
      const bytesRead: number = fileIo.readSync(file.fd, buffer);
      const textDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const content: string =
        textDecoder.decodeToString(new Uint8Array(buffer.slice(0, bytesRead)));
      fileIo.closeSync(file.fd);
      let name: string = nameHint.trim().length > 0
        ? nameHint.trim() : this.nameFromUri(uri);
      name = this.stripMdExt(name);
      let finalName: string = name;
      if (DocStore.exists(this.context, finalName)) {
        finalName = name + ' ' + new Date().getHours().toString()
          + new Date().getMinutes().toString() + new Date().getSeconds().toString();
      }
      const meta = DocStore.create(this.context, finalName, content);
      if (meta === null) {
        return false;
      }
      AppStorage.setOrCreate('pendingOpenDocName', meta.name);
      hilog.info(DOMAIN, 'LiteMdReader', '%{public}s', 'shared file imported: ' + meta.name);
      return true;
    } catch (err) {
      hilog.error(DOMAIN, 'LiteMdReader', 'import shared file failed: %{public}s',
        JSON.stringify(err));
      return false;
    }
  }

  /** uri 尾段当文件名（去查询串）。 */
  private nameFromUri(uri: string): string {
    let s: string = uri;
    const q: number = s.indexOf('?');
    if (q >= 0) {
      s = s.substring(0, q);
    }
    const cut: number = s.lastIndexOf('/');
    if (cut >= 0 && cut + 1 < s.length) {
      return decodeURIComponent(s.substring(cut + 1));
    }
    return '外部文档';
  }

  /** 去掉 .md / .markdown / .txt 扩展名（含双扩展 xxx.md.txt）。 */
  private stripMdExt(name: string): string {
    let out: string = name;
    for (let round: number = 0; round < 2; round++) {
      const lower: string = out.toLowerCase();
      if (lower.endsWith('.md') || lower.endsWith('.markdown') || lower.endsWith('.txt')) {
        const dot: number = out.lastIndexOf('.');
        if (dot > 0) {
          out = out.substring(0, dot);
          continue;
        }
      }
      break;
    }
    return out.length > 0 ? out : L10n.t('外部文档');
  }

  private handleOpenFile(want: Want): void {
    const uri: string | undefined = want.uri;
    if (uri === undefined || uri === null || uri.length === 0) {
      return;
    }
    // **.zip 只用于导入备份**（用户要求）：关联打开的 zip 不当文档导入，
    // 直接走备份恢复（BackupStore.importFromUri），结果经 Index 的
    // pendingBackupImportMsg 提示一次。
    const uriLower: string = uri.toLowerCase();
    if (uriLower.endsWith('.zip')) {
      BackupStore.importFromUri(this.context, uri).then((msg: string): void => {
        AppStorage.setOrCreate('pendingBackupImportMsg', msg);
        hilog.info(DOMAIN, 'LiteMdReader', '%{public}s', 'zip import: ' + msg);
      }).catch((err: BusinessError): void => {
        AppStorage.setOrCreate('pendingBackupImportMsg', '导入失败：' + err.message);
      });
      return;
    }
    try {
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      // 上限 2MB：Markdown 文本远小于此，防异常超大文件拖垮启动
      const size: number = stat.size > 2 * 1024 * 1024 ? 2 * 1024 * 1024 : stat.size;
      const buffer = new ArrayBuffer(size);
      const bytesRead: number = fileIo.readSync(file.fd, buffer);
      const textDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const content: string =
        textDecoder.decodeToString(new Uint8Array(buffer.slice(0, bytesRead)));
      fileIo.closeSync(file.fd);
      // 文件名从 uri 尾段截取（file://.../xxx.md），去掉 .md / .markdown / .txt 扩展名
      let name: string = '外部文档';
      const cut: number = uri.lastIndexOf('/');
      if (cut >= 0 && cut + 1 < uri.length) {
        name = decodeURIComponent(uri.substring(cut + 1));
      }
      const lower: string = name.toLowerCase();
      if (lower.endsWith('.md') || lower.endsWith('.markdown') || lower.endsWith('.markdown.txt')
        || lower.endsWith('.txt')) {
        const dot: number = name.lastIndexOf('.');
        if (dot > 0) {
          name = name.substring(0, dot);
        }
        // 双扩展（xxx.md.txt）剥完一层可能仍是 .md，再剥一次
        if (name.toLowerCase().endsWith('.md') || name.toLowerCase().endsWith('.markdown')) {
          const dot2: number = name.lastIndexOf('.');
          if (dot2 > 0) {
            name = name.substring(0, dot2);
          }
        }
      }
      // 重名时加时间后缀，避免"打开方式"导入悄悄失败
      let finalName: string = name;
      if (DocStore.exists(this.context, finalName)) {
        finalName = name + ' ' + new Date().getHours().toString() + new Date().getMinutes().toString()
        + new Date().getSeconds().toString();
      }
      const meta = DocStore.create(this.context, finalName, content);
      if (meta !== null) {
        AppStorage.setOrCreate('pendingOpenDocName', meta.name);
        hilog.info(DOMAIN, 'LiteMdReader', '%{public}s', 'open-file imported: ' + meta.name);
      }
    } catch (err) {
      hilog.error(DOMAIN, 'LiteMdReader', 'open file failed: %{public}d, %{public}s',
        (err as BusinessError).code, (err as BusinessError).message);
    }
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

    // **WebDAV 定时备份检查**（用户要求：可设定多久自动上传一次）：
    // 启动后延迟 4s（等首页首帧与壁纸铺好）再判定——「已配置 + 开启间隔 + 已到期」才执行，
    // 备份在后台异步跑，结果写 AppStorage 'webdavAutoStatus' 供数据管理页显示。
    setTimeout(() => {
      try {
        WebDavStore.maybeAutoBackup(this.context);
      } catch (err) {
        hilog.error(DOMAIN, 'LiteMdReader', 'auto webdav backup failed: %{public}s',
          JSON.stringify(err));
      }
    }, 4000);
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'LiteMdReader', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'LiteMdReader', '%{public}s', 'Ability onForeground');
    // **回前台信号**：阅读页据此把后台被系统回收的 Web 浮层重新挂载
    //（用户要求：关屏再开不要退出图表界面，但 Web 状态要重建才不异常）
    try {
      const ft: number = AppStorage.get<number>('appForegroundTick') ?? 0;
      AppStorage.setOrCreate('appForegroundTick', ft + 1);
    } catch (err) {
      // 信号失败不影响主流程
    }
    // **回前台补一次系统深浅同步**：用户在后台（或系统设置里）改了深浅色时，
    // 这个时机最可靠——部分设备切深浅并不下发 onConfigurationUpdate。
    this.syncSystemColorMode();
    // 桌面卡片推送：回前台刷一次最近阅读数据（30 分钟定时刷新兜底之外的即时通道）
    try {
      FormSync.pushRecents(this.context, false);
      FormSync.pushStudy(this.context);
    } catch (err) {
      // 推送失败不影响主流程
    }
  }

  /** 退到后台 / 被系统回收前落盘一次设置镜像（用户"退出应用"最常见的路径）。 */
  onBackground(): void {
    // 退后台即释放页面预热（Beta：不长期占内存）
    PageWarmup.clear();
    SettingsMirror.save(this.context);
    // **后台信号**：阅读页据此复位易失的浮层状态（如图表放大浮层）——
    // 关屏 / 切后台再回来时，Web 浮层容易残留异常（触摸错乱、错误控制阅读页）。
    try {
      const tick: number = AppStorage.get<number>('appBackgroundTick') ?? 0;
      AppStorage.setOrCreate('appBackgroundTick', tick + 1);
    } catch (err) {
      // 信号失败不影响主流程
    }
    // 桌面卡片兜底推送：退后台前最后一次（force 跳过节流）
    try {
      FormSync.pushRecents(this.context, true);
    } catch (err) {
      // 卡片推送失败不影响主流程
    }
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
