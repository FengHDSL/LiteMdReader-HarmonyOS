/**
 * 澄笺 · 设置 · 外观设置
 * ====================
 *
 * 从设置中心拆出来的独立页，四块内容：
 *   ① 主题色（澄光 / 宣纸 / 砚青 / 竹影 / 霞笺 + 自定义色号 + 背景染色开关）
 *   ② 应用壁纸（图库选图 / 澄笺程序化壁纸 / 模糊 / 遮罩 / 取消蒙版）
 *   ③ 卡片与流光（卡片沾色 / 主题色流光 / 卡片流光触感）
 *   ④ 灰体文本显示增强（自动 / 灰 / 黑 / 白 / 自定义）
 *
 * 「沉浸光感」开关与「材质类型 / 等级 / 玻璃通透程度 / 卡片降级样式」**已取消**：
 * 材质强制开启（EntryAbility 启动时置回 true）。
 *
 * ⚠️ 主题色 / 灰字模式等键的取值会被 DesignTokens.paletteFor 与 ThemeStore 消费，
 * 键名不要再改（历史键保留兼容解析）。
 */
import { NavLifecycle } from '../service/NavLifecycle';
import { ImmersiveCard, ImmersiveCardLayer, ImmersiveChip } from '../material/ImmersiveCard';
import { ImmersiveInput } from '../material/ImmersiveInput';
import { SettingsShell } from './SettingsShell';
import { applySystemBarTheme, applyAppColorMode, isPhoneDevice, setPhoneLandscapeAllowed } from '../service/AppWindow';
import { GEN_WALLPAPERS, GenWallpaperDef } from '../theme/GenWallpaper';
import { WallpaperStore } from '../service/WallpaperStore';
import { SettingsMirror } from '../service/SettingsMirror';
import { L10n } from '../service/L10n';
import { ThemeStore } from '../theme/ThemeStore';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppearanceFx } from '../service/AppearanceFx';
import {
  HwRadius,
  HwSpace,
  HwType,
  NamedColor,
  ReaderPalette,
  ReaderThemeMode,
  normalizeHex8,
  paletteFor,
  themeModeLabel,
  withAlpha,
  HwFont
} from '../theme/DesignTokens';
import { FontPickerList } from '../components/FontPickerList';
import { FontStore } from '../service/FontStore';

/**
 * 主题色预设：**5 款澄笺色**（与 5 款程序化壁纸同源同名，用户指定）。
 * 取色原则：中等明度、中等饱和——浅色底上够清楚，深色底上不刺眼，
 * 作为强调色与正文搭配时对比度都达标（不艳不淡）。
 * value 是持久化的键，**不要改**（red/blue/orange/purple 等历史键仍保留在
 * ThemeStore 里做兼容解析，只是不再出现在选择项中）。
 */
const THEME_PRESETS: NamedColor[] = [
  { name: L10n.t('澄光'), value: 'cheng' },
  { name: L10n.t('宣纸'), value: 'xuan' },
  { name: L10n.t('砚青'), value: 'yan' },
  { name: L10n.t('竹影'), value: 'zhu' },
  { name: L10n.t('霞笺'), value: 'xia' }
];

/** 灰体文本显示增强的模式（移植自 xjau 的灰字覆盖） */
/**
 * 沉浸光感两档（只在总开关打开后可选）：
 *   · 默认 = 完整系统材质（ImmersiveMaterial，通透玻璃）；
 *   · 节能 = 不挂系统材质，走既有的磨砂降级（省 GPU，观感就是"弱光感"那一版）。
 */
const GRADE_MODES: NamedColor[] = [
  { name: L10n.t('默认'), value: 'default' },
  { name: L10n.t('节能'), value: 'eco' }
];

const GRAY_MODES: NamedColor[] = [
  { name: L10n.t('自动'), value: 'auto' },
  { name: L10n.t('灰'), value: 'gray' },
  { name: L10n.t('黑'), value: 'black' },
  { name: L10n.t('白'), value: 'white' },
  { name: L10n.t('自定义'), value: 'custom' }
];

@Component
export struct SettingsAppearance {
  stack: NavPathStack | null = null;
  life: NavLifecycle = new NavLifecycle();

  @StorageLink('readerThemeMode') @Watch('onThemeChanged') themeMode: number = ReaderThemeMode.System;
  /**
   * **拨杆自己的即时状态**：点下去先按这个画，真正的主题切换排到下一帧之后。
   * 主题一变会牵动全应用重渲染 + 图表深浅孪生重烘，主线程一占就是几秒；拨杆若
   * 跟着 `themeMode` 走，用户看到的就是"按了没反应"（上架自检判成冻屏）。
   */
  @State themeKnobOn: boolean = false;
  /** 收掉本卡片流光的信号（自增即触发 ImmersiveCard 熄灭按压光斑） */
  @State glowTick: number = 0;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 外观刷新计数：主题色 / 灰字 / 沾色改动后由它触发重算 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  /** 用户选的语言（'system' 或内置 id）与语言刷新计数。
   *  ⚠️ 装饰器参数写**字面量**（与全仓库一致）：键名的权威定义在 service/L10n.ets
   *     的 KEY_CHOICE / KEY_TICK，改这里要同时改那里。 */
  @StorageLink('appLanguage') @Watch('onLanguageChanged') appLang: string = 'system';
  @StorageProp('languageTick') langTick: number = 0;
  /**
   * 主题色 / 灰字 / 沾色 / 蒙版这些键：**改一次就落一次镜像盘**
   * （SettingsMirror.save）。PersistentStorage 在部分设备上没真正落盘，
   * 表现为"设置完退出应用就恢复默认"，文件镜像 + 这里的即时保存是兜底。
   */
  @StorageLink('themeColor') @Watch('onAppearanceChanged') themeColor: string = '';
  @State customHex: string = '';
  /** 语言切换计数：变更时整页重建（key 拼接），文案随词典刷新 */
  @StorageProp('languageTick') languageTick: number = 0;
  /** 应用语言区块的隐藏入口：标题连点计数（≥5 显示） */
  @State langHiddenTaps: number = 0;
  /** 应用语言区块是否显示（默认隐藏：功能未完成） */
  @State showLangSection: boolean = false;
  /** 函数绘制壁纸选中款（空 = 不用） */
  @StorageLink('wallpaperGenId') genWallId: string = '';
  /** 应用壁纸（手选图）的路径 / 模糊 / 遮罩 */
  @StorageProp('wallpaperPath') wallpaperPath: string = '';
  /** 浅色 / 深色模式各自的壁纸路径（自动切换不同壁纸） */
  @StorageProp('wallpaperPathLight') wallpaperPathLight: string = '';
  @StorageProp('wallpaperPathDark') wallpaperPathDark: string = '';
  @StorageLink('wallpaperBlur') @Watch('onAppearanceChanged') wallpaperBlur: number = 4;
  @StorageLink('wallpaperScrim') @Watch('onAppearanceChanged') wallpaperScrim: number = 42;
  /** 滑块实测尺寸：responseRegion 只吃数值，先量后算（与设置中心同款防误触） */
  /** 卡片与流光三键（移植自 xjau 的外观设置项） */
  @StorageLink('cardTint') @Watch('onAppearanceChanged') cardTint: boolean = true;
  @StorageLink('immersivePressGlow') @Watch('onAppearanceChanged') pressGlow: boolean = true;
  @StorageLink('cardGlowTouch') @Watch('onAppearanceChanged') glowTouch: boolean = true;
  /** 书架顶部的「继续阅读」卡片是否显示（用户要求：可在外观设置里关掉） */
  @StorageLink('shelfResumeBanner') @Watch('onAppearanceChanged') resumeBanner: boolean = true;
  /** 沉浸光感总开关（2026-10-20 新增，**默认关**）：关 → 所有卡片纯色不透明 */
  @StorageLink('immersiveLook') @Watch('onAppearanceChanged') immersiveLook: boolean = false;
  /** 光感档位：'default' 完整材质 / 'eco' 节能（磨砂降级），仅总开关打开时可选 */
  @StorageLink('immersiveGrade') immersiveGrade: string = 'default';
  /**
   * 光感开关的**视觉草稿**：Toggle 的 isOn 绑它，而不是直接绑 immersiveLook。
   * 原因（用户要求）：开启光感必须先点「依然开启」才真正切换——
   * 若直接绑真实值，取消就得"先置 true 再回滚"，档位行会闪一下再收回去。
   * 绑草稿后：拨开关只动草稿（视觉跟手），确认才写真实值；取消仅把草稿拨回。
   */
  @State lookDraft: boolean = false;
  /** 过渡动画总开关（**默认关**）：关 → 所有动效瞬时完成、页面切换硬切 */
  @StorageLink('motionFx') @Watch('onAppearanceChanged') motionFx: boolean = false;
  /** 页面组件预热（beta，默认关）：结合「页面加载逻辑」使用，关掉即不占内存 */
  @StorageLink('preloadPages') @Watch('onAppearanceChanged') preloadPages: boolean = false;
  /** 页面背景跟随主题色 / 自定义主题色也染背景 */
  @StorageLink('pageBgTint') @Watch('onAppearanceChanged') pageBgTint: boolean = true;
  @StorageLink('customAccentFull') @Watch('onAppearanceChanged') customAccentFull: boolean = false;
  /**
   * **手机端横屏开关**（关＝锁竖屏，开＝随系统横竖切换）。
   * 只有手机显示这一行（`phoneDevice`），平板 / 2in1 本来就能转，不需要开关。
   */
  @StorageLink('phoneLandscape') @Watch('onPhoneLandscapeChanged') phoneLandscape: boolean = false;
  /** 设备类型：手机端才渲染横屏开关（进程内不变，普通字段即可，不用进状态） */
  private phoneDevice: boolean = isPhoneDevice();
  /**
   * **界面字体**（空串 = 系统默认）：全应用文字都跟着换（正文是否也换由下面的开关决定）。
   * 必须像这样用 @StorageLink 持有——真机上子组件自读 AppStorage 不保证回刷。
   */
  @StorageLink('appFontFamily') @Watch('onUiFontChanged') uiFontKey: string = '';
  /** 界面字体是否**同步应用到阅读正文**（关闭时正文仍用「阅读调整 → 字体」的选择） */
  @StorageLink('appFontSyncReader') @Watch('onUiFontChanged') uiFontSyncReader: boolean = false;
  /**
   * **界面字号**（0.85~1.30，步进 0.05）与**界面字重**（0 跟随 / 100 略粗 / 200 加粗）。
   * 与界面字体一样是逐点生效：各页把 fontSize 走 HwFont.sx、fontWeight 走 HwFont.bump；
   * 改完广播 appearanceTick。
   * 注意 ArkUI 数字字号单位是 fp，本来也跟随系统「字体与样式」缩放，两者是叠乘关系。
   */
  @StorageLink('appFontScale') @Watch('onUiFontChanged') uiFontScale: number = 1;
  @StorageLink('appFontWeightDelta') @Watch('onUiFontChanged') uiFontWeightDelta: number = 0;
  /** 界面字体列表是否展开 */
  @State uiFontListOpen: boolean = false;
  /** 列表重取信号（导入 / 删除字体后自增） */
  @State uiFontRev: number = 0;
  /** 灰体文本显示增强：**深浅两套独立配置**（各自默认 auto）。
   *  取值 auto / gray / black / white / custom + 对应模式的自定义色。 */
  @StorageLink('grayTextModeLight') @Watch('onAppearanceChanged') grayModeLight: string = 'auto';
  @StorageLink('grayTextModeDark') @Watch('onAppearanceChanged') grayModeDark: string = 'auto';
  @StorageLink('grayTextColorLight') @Watch('onAppearanceChanged') grayColorLight: string = '';
  @StorageLink('grayTextColorDark') @Watch('onAppearanceChanged') grayColorDark: string = '';
  /** 旧单套键：兼容解析（新键未设过时才生效），也一起改一次，避免旧值把新值顶掉 */
  @StorageLink('grayTextMode') @Watch('onAppearanceChanged') grayMode: string = 'auto';
  @StorageLink('grayTextColor') @Watch('onAppearanceChanged') grayColor: string = '';
  /** 自定义灰字输入框的草稿（点「应用」才写进设置）；深浅两套各一份 */
  @State grayDraft: string = '';
  @State grayDraftLight: string = '';
  @State grayDraftDark: string = '';
  @State sliderW: number = 0;
  @State sliderH: number = 0;

  private sliderThumbRegion(value: number, min: number, max: number): Rectangle {
    const w: number = this.sliderW > 0 ? this.sliderW : 320;
    const h: number = this.sliderH > 0 ? this.sliderH : 44;
    const ratio: number = max > min ? (value - min) / (max - min) : 0.5;
    const p: number = Math.max(0, Math.min(1, ratio));
    const thumbX: number = p * (w - 24);
    return { x: Math.max(0, Math.min(w - 56, thumbX - 16)), y: 0, width: 56, height: h };
  }

  /** 从系统图库选一张图作为应用壁纸（选出来的图会复制进沙箱，不需要媒体库权限） */
  /** 壁纸编辑模式：浅色 / 深色分别记忆（深浅模式自动切换不同壁纸） */
  @State wallpaperEditMode: string = 'light';

  /** 当前编辑模式的壁纸路径（用于"清除壁纸"的显示与生效） */
  private wallpaperEditModePath(): string {
    return this.wallpaperEditMode === 'dark' ? this.wallpaperPathDark : this.wallpaperPathLight;
  }

  private pickWallpaper(): void {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      this.toast(this.s('拿不到应用上下文'));
      return;
    }
    WallpaperStore.pickFor(c as common.UIAbilityContext, this.wallpaperEditMode === 'dark')
      .then((err: string) => {
        // '未选择图片' 是 WallpaperStore 的**内部哨兵值**，不参与翻译（译文换了这里就断）
        if (err === '未选择图片') {
          this.toast(this.s('未选择图片'));
        } else if (err.length > 0) {
          this.toast(this.s1('导入失败：%1', err));
        } else {
          this.toast(this.wallpaperEditMode === 'dark'
            ? this.s('深色壁纸已更新') : this.s('浅色壁纸已更新'));
        }
      }).catch((e: BusinessError) => {
      this.toast(this.s1('导入失败：%1', e.message));
    });
  }

  private clearWallpaper(): void {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      this.toast(this.s('拿不到应用上下文'));
      return;
    }
    WallpaperStore.clearFor(c as common.UIAbilityContext, this.wallpaperEditMode === 'dark');
    this.toast(this.s('已清除壁纸'));
  }

  private rememberSliderSize(area: Area): void {
    const lw: Length = area.width;
    const lh: Length = area.height;
    if (typeof lw === 'number' && lw > 0) {
      this.sliderW = lw;
    }
    if (typeof lh === 'number' && lh > 0) {
      this.sliderH = lh;
    }
  }

  private palette(): ReaderPalette {
    // 三个来源都要显式读一遍落成局部常量：主题色 / 灰字 / 沾色是在 paletteFor 里读
    // AppStorage 的（纯函数读不登记依赖），这里不登记的话主题切换会被 ArkUI 跳过重算
    const tick: number = this.appearanceTick;
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  /**
   * 取当前语言的文案。
   * ⚠️ 必须像 palette() 那样显式读一次 langTick：L10n 是静态类，它读 AppStorage
   *    不会给这个组件登记依赖，光调 L10n.t() 的话切语言时界面不会重画。
   */
  private s(src: string): string {
    const lang: number = this.langTick;
    return L10n.t(src);
  }

  /** 带一个占位符的文案（%1）。 */
  private s1(src: string, a: string): string {
    const lang: number = this.langTick;
    return L10n.f1(src, a);
  }

  /** 带两个占位符的文案（%1 %2）。 */
  private s2(src: string, a: string, b: string): string {
    const lang: number = this.langTick;
    return L10n.f2(src, a, b);
  }

  /** 语言选择芯片的文案（跟随系统要翻译，其它语言用自称）。 */
  private langChip(id: string): string {
    const lang: number = this.langTick;
    return L10n.chipLabel(id);
  }

  /** 当前语言说明：跟随系统时把解析到的语言一并写出来（跟随系统（当前：日本語））。 */
  private langDescribe(): string {
    const lang: number = this.langTick;
    return L10n.describe();
  }

  /**
   * 切语言：写选择 + 递增 languageTick（挂了 langTick 的节点当帧重画），
   * 动画上下文里做，卡片高度的变化才不会"啪"地跳。
   */
  private applyLanguage(id: string): void {
    if (id === this.appLang) {
      return;
    }
    this.getUIContext().animateTo(AppearanceFx.anim(220, Curve.Friction), () => {
      L10n.setChoice(id);
    });
    this.toast(this.s1('语言已切换为 %1', L10n.endonym(L10n.current())));
  }

  /** 语言变化：把选择镜像给平台，并落一次设置镜像盘。 */
  onLanguageChanged(): void {
    L10n.mirrorToPlatform();
    SettingsMirror.save(this.hostCtx());
  }

  /**
   * 任一外观键变化（@Watch）：**立刻落一次镜像盘**并广播刷新计数。
   * 不等"退到后台"，避免用户设置完直接杀掉应用时丢设置；
   * 顺带让别的页面（书架 / 阅读页）当场重算派生色。
   *
   * 灰字是**纯函数读 AppStorage**（paletteFor → grayTextOverride），不登记依赖，
   * 所以这里必须递增 appearanceTick：各页面的 palette() 都读了它，
   * 计数一变，全应用当帧重算灰字颜色——改完不用重进页面。
   */
  onAppearanceChanged(): void {
    // 光感真实值被外部改动（恢复默认 / 其它页）时，草稿跟着对齐
    this.lookDraft = this.immersiveLook;
    this.broadcastAppearance();
  }

  /**
   * 拨「支持横屏模式」：不广播外观（改的不是配色，没必要全应用重算 palette），
   * 只做两件事——把方向立刻作用到主窗口、落一次设置镜像。
   */
  onPhoneLandscapeChanged(): void {
    setPhoneLandscapeAllowed(this.phoneLandscape);
    SettingsMirror.save(this.hostCtx());
  }

  /**
   * 换界面字体 / 拨同步开关：广播一次外观刷新（appearanceTick 让全应用的卡片、
   * 芯片、面板都重渲染，字体属性才能真的落到每一行文字上），再落一次设置镜像。
   */
  onUiFontChanged(): void {
    this.broadcastAppearance();
  }

  /** 选字重档位：这款字体没有真粗体时不给切（档位同时置灰），只说明怎么办 */
  private pickUiWeight(delta: number): void {
    if (!FontStore.supportsBold(this.uiFontKey)) {
      this.toast(this.s('这款字体没有粗体字重；换一款字体或选「跟随」'));
      return;
    }
    this.uiFontWeightDelta = delta;
  }

  /** 广播一次外观刷新：递增 appearanceTick + 落镜像盘。 */
  private broadcastAppearance(): void {
    try {
      const cur: number | undefined = AppStorage.get<number>(SettingsMirror.KEY_TICK);
      const next: number = (cur === undefined || cur === null ? 0 : cur) + 1;
      AppStorage.setOrCreate(SettingsMirror.KEY_TICK, next);
    } catch (err) {
      // 广播失败不影响设置本身
    }
    SettingsMirror.save(this.hostCtx());
  }

  /** Ability 上下文（镜像落盘用）。 */
  private hostCtx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  /**
   * 主题切换时同步系统栏图标颜色，并落一次镜像。
   * 不跟着切的话，深色模式下状态栏 / 手势条仍是深色图标（"图标全是黑的看不清"）。
   */
  onThemeChanged(): void {
    // 拨杆跟随真正生效的主题（「跟随系统」芯片、阅读页主题五档改的都是同一个键）
    this.themeKnobOn = this.themeMode === ReaderThemeMode.Dark;
    applyAppColorMode(this.themeMode);
    applySystemBarTheme(this.themeMode === ReaderThemeMode.Dark
      || (this.themeMode === ReaderThemeMode.System && this.systemDark));
    SettingsMirror.save(this.hostCtx());
  }

  /** 轻提示（与设置中心同款：走系统 promptAction，不引额外依赖） */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1600 });
    } catch (err) {
      // 提示失败无副作用
    }
  }

  /** 一键恢复外观默认：主题色 / 卡片 / 灰体 / 壁纸 / 遮罩全部回到出厂值。 */
  private restoreDefaults(): void {
    AppStorage.setOrCreate('themeColor', '');
    // 性能与动效三项回到默认（都关）
    AppStorage.setOrCreate('immersiveLook', false);
    AppStorage.setOrCreate('immersiveGrade', 'default');
    AppStorage.setOrCreate('motionFx', false);
    AppStorage.setOrCreate('preloadPages', false);
    AppStorage.setOrCreate('cardTint', true);
    AppStorage.setOrCreate('immersivePressGlow', true);
    AppStorage.setOrCreate('cardGlowTouch', true);
    AppStorage.setOrCreate('shelfResumeBanner', true);
    AppStorage.setOrCreate('customAccentFull', false);
    AppStorage.setOrCreate('pageBgTint', true);
    // 横屏开关走 @StorageLink 赋值：@Watch 里负责把方向真正作用到主窗口
    this.phoneLandscape = false;
    // 界面字体与「同步到阅读页」也一起恢复默认（空 = 系统默认字形）
    this.uiFontKey = '';
    this.uiFontSyncReader = false;
    // 界面字号与字重也回到"不调"
    this.uiFontScale = 1;
    this.uiFontWeightDelta = 0;
    AppStorage.setOrCreate('grayTextMode', 'auto');
    AppStorage.setOrCreate('grayTextColor', '');
    AppStorage.setOrCreate('grayTextModeLight', 'auto');
    AppStorage.setOrCreate('grayTextModeDark', 'auto');
    AppStorage.setOrCreate('grayTextColorLight', '');
    AppStorage.setOrCreate('grayTextColorDark', '');
    AppStorage.setOrCreate('glassStrength', 70);
    AppStorage.setOrCreate('cardFallback', 'mica');
    AppStorage.setOrCreate('particleDissolve', false);
    AppStorage.setOrCreate('appearanceMaterialType', 0);
    AppStorage.setOrCreate('appearanceMaterialLevel', 1);
    AppStorage.setOrCreate('wallpaperGenId', 'zhu');
    AppStorage.setOrCreate('wallpaperBlur', 4);
    AppStorage.setOrCreate('wallpaperScrim', 42);
    // 壁纸：浅色 / 深色 / 旧全局键全部清空（含落盘文件）
    const c = this.hostCtx();
    if (c !== null) {
      WallpaperStore.clearFor(c, false);
      WallpaperStore.clearFor(c, true);
    }
    AppStorage.setOrCreate('wallpaperPath', '');
    this.themeColor = '';
    SettingsMirror.save(this.hostCtx());
    this.toast(this.s('外观已恢复默认'));
  }

  aboutToAppear(): void {
    // 开关视觉跟真实值对齐（进页面时可能是上次开着的状态）
    this.lookDraft = this.immersiveLook;
    // 拨杆与生效主题对齐（从别处改过主题再进这页时不能对不上）
    this.themeKnobOn = this.themeMode === ReaderThemeMode.Dark;
    // 灰字自定义草稿带入各自当前值
    this.grayDraftLight = this.grayColorLight;
    this.grayDraftDark = this.grayColorDark;
  }

  /**
   * 一套灰体文本配置块（深色 / 浅色各用一次）。
   *
   * **注意（重要）**：这里不再把 mode / color / draft 当参数传进来——
   * ArkTS 的 @Builder **按值传参不随参数变化刷新**，之前点模式芯片时
   * "颜色变了但芯片高亮没变、选自定义也不出现输入框"就是这个原因。
   * 现在两个主题各一个 builder，内部直接读对应的 @StorageLink / @State。
   */
  @Builder
  grayBlockLight() {
    this.grayBlockBody('浅色模式', true)
  }

  @Builder
  grayBlockDark() {
    this.grayBlockBody('深色模式', false)
  }

  /** 配置块主体：`light=true` 读浅色主题的键，false 读深色主题的键。 */
  private grayModeOf(light: boolean): string {
    return light ? this.grayModeLight : this.grayModeDark;
  }

  private grayColorOf(light: boolean): string {
    return light ? this.grayColorLight : this.grayColorDark;
  }

  private grayDraftOf(light: boolean): string {
    return light ? this.grayDraftLight : this.grayDraftDark;
  }

  @Builder
  grayBlockBody(title: string, light: boolean) {
    Row() {
      Text(this.s(title))
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwType.label)
        .fontColor(this.palette().textPrimary)
        .layoutWeight(1)
      Text(this.grayModeOf(light) === 'auto' ? this.s('自动')
        : (this.grayColorOf(light).length > 0 ? this.grayColorOf(light) : ''))
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)

    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(GRAY_MODES, (item: NamedColor) => {
        Row() {
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: this.s(item.name),
            // 高亮读数在 builder 体内 → 点击后当帧刷新（按值传参才会滞后）
            chipActive: this.grayModeOf(light) === item.value,
            chipOnTap: () => {
              this.applyGrayMode(light, item.value);
              if (item.value !== 'custom') {
                this.toast(this.s2('%1灰体文本：%2', this.s(title), this.s(item.name)));
              }
            }
          })
        }
        .margin({ right: HwSpace.xs, bottom: HwSpace.xs })
      }, (item: NamedColor) => 'gm_' + title + '_' + item.value)
    }
    .width('100%')

    if (this.grayModeOf(light) === 'custom') {
      Row({ space: HwSpace.xs }) {
        ImmersiveInput({
          palette: this.palette(),
          text: this.grayDraftOf(light).length > 0
            ? this.grayDraftOf(light) : this.grayColorOf(light),
          placeholder: this.s('自定义 #RRGGBB'),
          onInput: (value: string) => {
            if (light) {
              this.grayDraftLight = value;
            } else {
              this.grayDraftDark = value;
            }
          }
        })
        .layoutWeight(1)
        ImmersiveChip({
          palette: this.palette(),
          chipActive: true,
          chipLabel: this.s('应用'),
          chipOnTap: () => {
            const norm: string = normalizeHex8(this.grayDraftOf(light));
            if (norm.length === 0) {
              this.toast(this.s('格式：#RRGGBB，例如 #9AA0A6'));
              return;
            }
            if (light) {
              this.grayColorLight = '#' + norm.substring(3);
            } else {
              this.grayColorDark = '#' + norm.substring(3);
            }
            this.broadcastAppearance();
            this.toast(this.s1('%1灰体色已生效', this.s(title)));
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      // **滑出 / 滑回**（照搬本地项目 xjau 的写法）：进场自上滑入、退场向上滑回，
      // 曲线用 Friction（阻尼感，收放不生硬）；之前只有淡入淡出、且曲线偏硬。
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({ y: -12 }))
          .animation(AppearanceFx.anim(280, Curve.Friction)),
        TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({ y: -10 }))
          .animation(AppearanceFx.anim(220, Curve.Friction))
      ))
    }
  }

  /**
   * 写入对应主题的灰体模式并广播刷新。
   *
   * **整体包在 animateTo 里**：切到「自定义」时输入框是条件挂载的，
   * 只有把状态变更放进动画上下文，**外层卡片的高度**才会跟着输入框一起
   * 平滑伸展 / 收回；否则子行在动画、卡片却"啪"地跳一下（用户反馈）。
   */
  private applyGrayMode(light: boolean, mode: string): void {
    this.getUIContext().animateTo(AppearanceFx.anim(260, Curve.Friction), () => {
      if (light) {
        this.grayModeLight = mode;
      } else {
        this.grayModeDark = mode;
      }
      // 旧键（grayTextMode）同步为 auto：它只在「新键为空」时才参与解析，
      // 但老安装里可能是手动设过的值，留着会盖住新键的效果。
      this.grayMode = 'auto';
    });
    this.broadcastAppearance();
  }

  build() {
    SettingsShell({
      shellTitle: this.s('外观设置'),
      onTitleTap: () => {
        this.langHiddenTaps = this.langHiddenTaps + 1;
        if (this.langHiddenTaps >= 5 && !this.showLangSection) {
          this.getUIContext().animateTo(AppearanceFx.anim(260, Curve.FastOutSlowIn), () => {
            this.showLangSection = true;
          });
        }
      },
      shellSubtitle: this.s('深色模式 · 主题色 · 应用壁纸 · 卡片与流光 · 灰体文本'),
      stack: this.stack,
      life: this.life
    }) {
      // ── ⓪ 主题模式（深色模式开关）──
      // 与「阅读调整 → 主题」的五档是同一个键（readerThemeMode），
      // 这里给一个最常用的快捷开关：深色 on/off + 跟随系统。
      // **标题放进卡片内**（用户要求：卡片外的「主题模式」等文本移入各自卡片）
      ImmersiveCard({
        cardRadius: HwRadius.card, cardPadding: HwSpace.lg,
        palette: this.palette(), glowClearTick: this.glowTick
      }) {
        Column({ space: HwSpace.md }) {
          Text(this.s('主题模式'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.label + 1)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().textSecondary)
            .width('100%')

          Row() {
            Column({ space: 2 }) {
              Text(this.s('深色模式'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text(this.s('开启后全应用改用深色配色；羊皮纸 / 护眼绿在「阅读调整」里'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.themeKnobOn })
              .onChange((isOn: boolean) => {
                // 三步顺序不能换：**先给反馈，再干活**。
                //  ① 拨杆立刻滑过去（走本地 themeKnobOn，不等 themeMode 生效）；
                //  ② 流光当场收掉，不留"按着不放的一团光"；
                //  ③ 提示"切换中，请耐心等待"，然后**把真正的主题切换推到下一帧之后**
                //     —— 主题一变是全应用重渲染 + 图表深浅孪生重烘，主线程一占几秒，
                //     占在同一帧里就是审核报告里的冻屏（THREAD_BLOCK_6S）。
                // ⚠️ 延时取 350ms：Toggle 拨杆自己的滑动动画要这么久。延得太短（试过
                //     80ms）动画播到一半就被占住，拨杆停在卡片中间——比原来更难看。
                this.themeKnobOn = isOn;
                this.glowTick++;
                this.toast(this.s('切换中，请耐心等待'));
                setTimeout((): void => {
                  this.themeMode = isOn ? ReaderThemeMode.Dark : ReaderThemeMode.Light;
                  // 完成提示排在真正的切换之后：切换中那条还挂着时它会被顶替，
                  // 用户看到的就是"切换中 → 已切换"两步反馈
                  this.toast(isOn ? this.s('已切换到深色模式') : this.s('已切换到浅色模式'));
                }, 350);
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.themeMode === ReaderThemeMode.System,
              chipLabel: this.s('跟随系统'),
              chipOnTap: () => {
                // 与深色开关同一口径：先给提示，真正的主题切换推到下一帧之后
                this.glowTick++;
                this.toast(this.s('切换中，请耐心等待'));
                setTimeout((): void => {
                  this.themeMode = ReaderThemeMode.System;
                }, 350);
              }
            })
            Text(this.s1('当前：%1', this.s(themeModeLabel(this.themeMode))))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // **只有手机端显示**：平板 / 2in1 本来就随系统横竖切换，不给这一行
          if (this.phoneDevice) {
            Row() {
              Column({ space: 2 }) {
                Text(this.s('支持横屏模式'))
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwType.label + 1)
                  .fontColor(this.palette().textPrimary)
                Text(this.s('开启后手机可随系统横竖屏切换；关闭则锁定竖屏'))
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwType.caption)
                  .fontColor(this.palette().textTertiary)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: this.phoneLandscape })
                .onChange((isOn: boolean) => {
                  this.phoneLandscape = isOn;
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── 界面字体（用户要求：外观设置也能选字体，调整应用内所有文本；并可决定是否同步到阅读页）
      // ArkUI 没有应用级字体钩子（Theme 只有 colors，fontFamily 也不是通用属性），
      // 所以这份字体是**逐处 Text 挂 fontFamily** 生效的（见 HwFont.resolve / 各页 uiFontKey）。
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Text(this.s('界面字体'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.label + 1)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().textSecondary)
            .width('100%')

          Row({ space: HwSpace.xs }) {
            Text(this.s('全应用文字'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwType.label)
              .fontColor(this.palette().textSecondary)
            Text(HwFont.label(this.uiFontKey))
              .fontSize(HwType.label)
              .fontWeight(FontWeight.Medium)
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontColor(this.palette().textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            // ⚠️ $r() 的参数必须是**字面量**：展开 / 收起两个箭头各写一份
            if (this.uiFontListOpen) {
              SymbolGlyph($r('sys.symbol.chevron_up'))
                .fontSize(16)
                .fontColor([this.palette().textTertiary])
            } else {
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(16)
                .fontColor([this.palette().textTertiary])
            }
          }
          .width('100%')
          .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 8, bottom: 8 })
          .borderRadius(HwRadius.inner)
          .backgroundColor(this.palette().surface)
          .border({ width: 1, color: this.palette().surfaceBorder })
          .onClick(() => {
            this.uiFontListOpen = !this.uiFontListOpen;
          })

          if (this.uiFontListOpen) {
            FontPickerList({
              palette: this.palette(),
              chosen: this.uiFontKey,
              rev: this.uiFontRev,
              allowRemove: false,
              onPick: (k: string) => {
                this.uiFontKey = k;
                this.toast('界面字体：' + HwFont.label(k));
              }
            })
          }

          Row() {
            Column({ space: 2 }) {
              Text(this.s('同步应用到阅读页'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text(this.s('开启后阅读正文也用它；关闭则正文仍用「阅读调整 → 字体」里选的那款'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.uiFontSyncReader })
              .onChange((isOn: boolean) => {
                this.uiFontSyncReader = isOn;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // ── 界面字号：85%~130%，步进 5%（逐点生效，见 HwFont.sx）──
          Row({ space: HwSpace.xs }) {
            Text(this.s('界面字号'))
              .fontSize(HwType.label + 1)
              .fontColor(this.palette().textPrimary)
            Blank()
            Text(Math.round(this.uiFontScale * 100) + '%')
              .fontSize(HwType.label)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.palette().accent)
          }
          .width('100%')

          Slider({ value: this.uiFontScale * 100, min: 85, max: 130, step: 5, style: SliderStyle.OutSet })
            .width('100%')
            .selectedColor(this.palette().accent)
            .blockColor(this.palette().accent)
            .onChange((v: number, mode: SliderChangeMode) => {
              this.uiFontScale = Math.round(v) / 100;
            })

          Text(this.s('标题、正文与数字会按同一系数放大；系统的「字体与样式」缩放是叠加生效的'))
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')

          // ── 界面字重：三档；**不支持真粗体的字体，两档加粗置灰** ──
          // 判据只能是实测：SDK 查不到字重信息（FontInfo 只有 path / family / fullName），
          // 所以 FontStore.supportsBold 用 400 与 700 各量一次宽度，几乎不变就算不支持。
          Row({ space: HwSpace.xs }) {
            Text(this.s('界面字重'))
              .fontSize(HwType.label + 1)
              .fontColor(this.palette().textPrimary)
            Blank()
            if (!FontStore.supportsBold(this.uiFontKey)) {
              Text(this.s('这款字体没有粗体字重'))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
          }
          .width('100%')

          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.uiFontWeightDelta === 0,
              chipLabel: this.s('跟随'),
              chipOnTap: () => {
                this.uiFontWeightDelta = 0;
              }
            })
            Column() {
              ImmersiveChip({
                palette: this.palette(),
                chipActive: this.uiFontWeightDelta === 100,
                chipLabel: this.s('略粗'),
                chipOnTap: () => {
                  this.pickUiWeight(100);
                }
              })
            }
            .opacity(FontStore.supportsBold(this.uiFontKey) ? 1 : 0.4)
            Column() {
              ImmersiveChip({
                palette: this.palette(),
                chipActive: this.uiFontWeightDelta === 200,
                chipLabel: this.s('加粗'),
                chipOnTap: () => {
                  this.pickUiWeight(200);
                }
              })
            }
            .opacity(FontStore.supportsBold(this.uiFontKey) ? 1 : 0.4)
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── ⓪½ 应用语言（**默认隐藏**：连点标题 5 次显示；功能未完成）──
      // 语言名一律用**该语言的自称**（简体中文 / 繁體中文（台灣）/ English (US) /
      // 日本語 / 한국어…），只有「跟随系统」这一项跟着界面语言翻译；
      // 系统语言不在内置列表里时，L10n.match 归一到简体中文。
      if (this.showLangSection) {
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.md }) {
          Text(this.s('应用语言'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.label + 1)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().textSecondary)
            .width('100%')

          Text(this.s('只改澄笺里的文字，不动系统语言；澄笺这个名字和拼音都不翻译。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(L10n.IDS, (id: string) => {
              Row() {
                ImmersiveChip({
                  palette: this.palette(),
                  chipLabel: this.langChip(id),
                  chipActive: this.appLang === id,
                  chipOnTap: () => {
                    this.applyLanguage(id);
                  }
                })
              }
              .margin({ right: HwSpace.xs, bottom: HwSpace.xs })
            }, (id: string) => 'lang_' + id)
          }
          .width('100%')

          Text(this.langDescribe())
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')

          Text(this.s('系统语言不在内置列表里时，按简体中文显示。')
            + ' ' + this.s('应用内文字立刻生效；日期格式这类系统级文字在下次启动时同步。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwType.caption * 1.6)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      }

      // ── ① 主题色（标题已在卡片内，删掉卡片外这一份——用户要求）──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.md }) {
          Text(this.s('主题色'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.label + 1)
            .fontColor(this.palette().textPrimary)
          Row({ space: HwSpace.sm }) {
            ForEach(THEME_PRESETS, (item: NamedColor) => {
              Column()
                .width(44)
                .height(44)
                .borderRadius(10)
                // **色块要画"键对应的颜色"**：item.value 是 cheng/xuan/… 这类键，
                // 直接当颜色用是非法值（旧版 red/blue 恰好吃 ArkUI 的命名色才看着有色）。
                .backgroundColor(ThemeStore.colorOf(item.value))
                .justifyContent(FlexAlign.Center)
                .border({
                  width: 2,
                  color: this.themeColor === item.value ? this.palette().accent : this.palette().divider
                })
                .onClick(() => {
                  this.themeColor = item.value;
                  // 五色名（澄光 / 宣纸…）是品牌名，任何语言都不翻译
                  this.toast(this.s1('主题色：%1', item.name));
                })
            }, (item: NamedColor) => 'tp' + item.name)
          }
          .width('100%')

          // 恢复默认：清空主题色（回到跟随五档主题的默认强调色）
          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.themeColor.length === 0,
              chipLabel: this.s('跟随主题（默认）'),
              chipOnTap: () => {
                this.themeColor = '';
                this.toast(this.s('已恢复默认主题色'));
              }
            })
            Text(this.s1('当前：%1', ThemeStore.label()))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: HwSpace.xs }) {
            ImmersiveInput({
              palette: this.palette(),
              text: this.customHex,
              placeholder: this.s('自定义 #RRGGBB'),
              onInput: (value: string) => {
                this.customHex = value;
              }
            })
            .layoutWeight(1)
            ImmersiveChip({
              palette: this.palette(),
              chipActive: true,
              chipLabel: this.s('应用'),
              chipOnTap: () => {
                const norm: string = normalizeHex8(this.customHex);
                if (norm.length === 0) {
                  this.toast(this.s('格式：#RRGGBB，例如 #B07A2E'));
                  return;
                }
                this.themeColor = norm.substring(3);
                this.toast(this.s('自定义主题色已生效'));
              }
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Divider().strokeWidth(1).color(this.palette().divider)

          // 页面背景跟随主题色（参考 xjau：内置主题色始终允许染背景）
          Row() {
            Column({ space: 2 }) {
              Text(this.s('背景跟随主题色'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text(this.s('页面底色轻微染上主题色，整体更统一'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.pageBgTint })
              .onChange((isOn: boolean) => {
                this.pageBgTint = isOn;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 自定义 hex 默认只影响强调色；要看它染背景得开这个（xjau 的高权限开关）
          Row() {
            Column({ space: 2 }) {
              Text(this.s('自定义色也染背景'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text(this.s('关闭时，只有澄笺 5 色会染页面背景'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.customAccentFull })
              .onChange((isOn: boolean) => {
                this.customAccentFull = isOn;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── ② 应用壁纸（图库选图 / 澄笺程序化款 / 模糊 / 遮罩 / 取消蒙版）──
      // **标题放进卡片内**（用户要求）
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.md }) {
          Text(this.s('应用壁纸'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.label + 1)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().textSecondary)
            .width('100%')

          // **深浅色分别记忆壁纸**：先选要编辑的模式，再选图
          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.wallpaperEditMode === 'light',
              chipLabel: this.s('浅色壁纸'),
              chipOnTap: () => {
                this.wallpaperEditMode = 'light';
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.wallpaperEditMode === 'dark',
              chipLabel: this.s('深色壁纸'),
              chipOnTap: () => {
                this.wallpaperEditMode = 'dark';
              }
            })
          }
          .width('100%')

          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipActive: true,
              chipLabel: this.s('从图库选择'),
              chipOnTap: () => {
                this.pickWallpaper();
              }
            })
            if (this.wallpaperEditModePath().length > 0) {
              ImmersiveChip({
                palette: this.palette(),
                chipLabel: this.s('清除壁纸'),
                chipOnTap: () => {
                  this.clearWallpaper();
                }
              })
            }
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: this.s('取消所有壁纸'),
              chipOnTap: () => {
                const c = this.hostCtx();
                if (c !== null) {
                  WallpaperStore.clearFor(c, false);
                  WallpaperStore.clearFor(c, true);
                }
                AppStorage.setOrCreate('wallpaperPath', '');
                this.toast(this.s('已取消所有壁纸'));
              }
            })
          }
          .width('100%')

          Divider().strokeWidth(1).color(this.palette().divider)

          Text(this.s('澄笺壁纸（程序化绘制）'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.label)
            .fontColor(this.palette().textPrimary)
            .width('100%')
          Text(this.s('按「澄·笺」意境生成的渐变纸墨底，无位图资源，任意分辨率都清晰'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(GEN_WALLPAPERS, (item: GenWallpaperDef) => {
              Row() {
                ImmersiveChip({
                  palette: this.palette(),
                  chipLabel: item.name,
                  chipActive: this.genWallId === item.id,
                  chipOnTap: () => {
                    this.genWallId = this.genWallId === item.id ? '' : item.id;
                    // 壁纸款名（竹影 / 澄光…）与拼音 id 都是品牌名，不翻译
                    this.toast(this.genWallId.length > 0
                      ? this.s1('壁纸：%1', item.name)
                      : this.s('已关闭澄笺壁纸'));
                  }
                }) {
                  Column()
                    .width(14)
                    .height(14)
                    .borderRadius(4)
                    .linearGradient({
                      angle: 165,
                      colors: [[item.top, 0.0], [item.bottom, 1.0]]
                    })
                }
              }
              .margin({ right: HwSpace.xs, bottom: HwSpace.xs })
            }, (item: GenWallpaperDef) => item.id)
          }
          .width('100%')

          Divider().strokeWidth(1).color(this.palette().divider)

          // 模糊只对手选的图片壁纸有意义；遮罩与「取消蒙版」对两类壁纸都生效
          // （程序化壁纸也会叠这层可读性遮罩），所以放在条件外。
          if (this.wallpaperPathLight.length > 0 || this.wallpaperPathDark.length > 0
            || this.wallpaperPath.length > 0) {
            Row() {
              Text(this.s('壁纸模糊'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.label)
                .fontColor(this.palette().textPrimary)
              Blank()
              Text('' + Math.round(this.wallpaperBlur))
                .fontSize(HwType.label)
                .fontColor(this.palette().accent)
            }
            .width('100%')

            Slider({ value: this.wallpaperBlur, min: 0, max: 20, step: 1, style: SliderStyle.OutSet })
              .width('100%')
              .selectedColor(this.palette().accent)
              .blockColor(this.palette().accent)
              // 防误触：只有滑块附近可拖（整条轨道会响应，纵向滚动时容易误改）
              .responseRegion(this.sliderThumbRegion(this.wallpaperBlur, 0, 20))
              .onAreaChange((oldValue: Area, newValue: Area) => {
                this.rememberSliderSize(newValue);
              })
              .onChange((v: number, mode: SliderChangeMode) => {
                this.wallpaperBlur = Math.round(v);
              })
          }

          Row() {
            Text(this.s('文字可读性遮罩'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwType.label)
              .fontColor(this.palette().textPrimary)
            Blank()
            Text('' + Math.round(this.wallpaperScrim))
              .fontSize(HwType.label)
              .fontColor(this.palette().accent)
          }
          .width('100%')

          Slider({ value: this.wallpaperScrim, min: 0, max: 100, step: 5, style: SliderStyle.OutSet })
            .width('100%')
            .selectedColor(this.palette().accent)
            .blockColor(this.palette().accent)
            .responseRegion(this.sliderThumbRegion(this.wallpaperScrim, 0, 100))
            .onAreaChange((oldValue: Area, newValue: Area) => {
              this.rememberSliderSize(newValue);
            })
            .onChange((v: number, mode: SliderChangeMode) => {
              this.wallpaperScrim = Math.round(v);
            })

          // 取消蒙版（移植自 xjau 的「壁纸蒙版」开关）：一键把遮罩归零，
          // 壁纸原图全亮度显示；再关掉则回到默认浓度。
          Row() {
            Column({ space: 2 }) {
              Text(this.s('取消蒙版'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text(this.s('关闭后不叠加可读性遮罩，壁纸按原样显示'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.wallpaperScrim <= 0 })
              .onChange((isOn: boolean) => {
                this.wallpaperScrim = isOn ? 0 : 42;
                this.toast(isOn ? this.s('已取消蒙版（壁纸原样显示）') : this.s('已恢复可读性蒙版'));
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(this.s('壁纸越花，遮罩就要越浓，否则正文会看不清；确实不需要时可「取消蒙版」'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── ④ 性能与动效（2026-10-20 新增：沉浸光感 / 过渡动画 / 页面预热，默认全关）──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.md }) {
          Row({ space: HwSpace.xs }) {
            Text(this.s('性能与动效'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwType.label + 1)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.palette().textSecondary)
            // BETA 徽章（用户要求）
            Text('BETA')
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.palette().accent)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(5)
              .backgroundColor(withAlpha(this.palette().accent, '26'))
            Blank()
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(this.s('实验性质，酌情开启'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')

          // 沉浸光感：开 → 卡片/条栏挂系统材质；关 → 一律纯色不透明
          Row() {
            Column({ space: 2 }) {
              Text(this.s('沉浸光感'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text(this.s('关闭后所有卡片为纯色不透明；开启会掉帧、发热'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            // isOn 绑**草稿**：拨动只改视觉，确认后才写真实开关（见 lookDraft 注释）
            Toggle({ type: ToggleType.Switch, isOn: this.lookDraft })
              .onChange((isOn: boolean) => {
                this.lookDraft = isOn;
                if (!isOn) {
                  // 关闭不需要确认：立即生效，档位行同步收起（高度走过渡）
                  this.getUIContext().animateTo(AppearanceFx.anim(260, Curve.FastOutSlowIn), () => {
                    this.immersiveLook = false;
                  });
                  return;
                }
                // **开启：先弹窗，点「依然开启」才真正切换**（用户要求）
                this.getUIContext().showAlertDialog({
                  title: this.s('开启沉浸光感？'),
                  message: this.s('开启后会导致应用帧率下降，设备发热，请酌情考虑开启！'),
                  primaryButton: {
                    value: this.s('取消'),
                    action: () => {
                      // 只把草稿拨回：真实开关从未动过 → 档位行不会先冒出来再收回去
                      this.getUIContext().animateTo(AppearanceFx.anim(200, Curve.FastOutSlowIn), () => {
                        this.lookDraft = false;
                      });
                    }
                  },
                  secondaryButton: {
                    value: this.s('依然开启'),
                    action: () => {
                      // 此刻才落真实值：档位行随 animateTo 展开
                      this.getUIContext().animateTo(AppearanceFx.anim(260, Curve.FastOutSlowIn), () => {
                        this.immersiveLook = true;
                      });
                    }
                  }
                });
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 光感档位（只在开启后出现）：默认 = 完整玻璃材质；节能 = 磨砂降级、明显省电
          if (this.immersiveLook) {
            Column({ space: HwSpace.md }) {
              Row() {
                Text(this.s('光感强度'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.label)
                .fontColor(this.palette().textPrimary)
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(GRADE_MODES, (item: NamedColor) => {
                  Row() {
                    ImmersiveChip({
                      palette: this.palette(),
                      chipLabel: this.s(item.name),
                      chipActive: this.immersiveGrade === item.value,
                      chipOnTap: () => {
                        this.immersiveGrade = item.value;
                        this.toast(item.value === 'eco'
                          ? this.s('已切到节能：不挂系统材质，更省电')
                          : this.s('已切到默认：完整沉浸光感'));
                      }
                    })
                  }
                  .margin({ right: HwSpace.xs, bottom: HwSpace.xs })
                }, (item: NamedColor) => 'grade_' + item.value)
              }
              .width('100%')

              Text(this.s('节能档走磨砂、几乎不耗 GPU；默认档是完整玻璃光感（耗电、可能掉帧）'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            // 出现/收起：淡入淡出（高度变化由外层 animateTo 插值）
            .transition(AppearanceFx.fx(
              TransitionEffect.OPACITY.animation(AppearanceFx.anim(180, Curve.FastOutSlowIn))))
          }

          // 过渡动画：关 → 所有 animateTo / transition / 页面转场瞬时完成（硬切）
          Row() {
            Column({ space: 2 }) {
              Text(this.s('过渡动画'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text(this.s('只停用页面切换动画：进出直接显示/消失；打开文档的展开动画与其它动效保留'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.motionFx })
              .onChange((isOn: boolean) => {
                this.motionFx = isOn;
                this.toast(isOn ? this.s('已开启页面切换动画') : this.s('已关闭页面切换动画（其它动效保留）'));
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 页面组件预热（beta）：打开页面即后台预加载组件，进程退出或超时自动释放
          Row() {
            Column({ space: 2 }) {
              Text(this.s('页面组件预热（Beta）'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text(this.s('提前把页面与组件加载进内存（不含文档内容），退出应用或超时后自动清除'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.preloadPages })
              .onChange((isOn: boolean) => {
                this.preloadPages = isOn;
                this.toast(isOn ? this.s('已开启页面预热（Beta）') : this.s('已关闭页面预热'));
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── ⑤ 卡片与流光 ──
      // 「沉浸光感」开关按需求**取消**：材质强制开启（EntryAbility 每次启动置回 true），
      // 「材质类型 / 等级 / 玻璃通透程度 / 卡片降级样式」也一律不再暴露。
      // 这里保留的是真正会被用户感知的三项观感开关（语义照搬 xjau 的外观设置）。
      // **标题放进卡片内**（用户要求）
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.md }) {
          Text(this.s('卡片与流光'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.label + 1)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().textSecondary)
            .width('100%')

          // 卡片沾色：卡片底色混入 10% 主题色（含材质之上的薄染层）
          Row() {
            Column({ space: 2 }) {
              Text(this.s('卡片沾色'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text(this.s('卡片染上一成主题色，整体更协调（需先选主题色）'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.cardTint })
              .onChange((isOn: boolean) => {
                this.cardTint = isOn;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 主题色流光：按压卡片的流光/光晕用主题色还是白光
          Row() {
            Column({ space: 2 }) {
              Text(this.s('主题色流光'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text(this.s('按压卡片时的流光改用主题色（关闭为白光）'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.pressGlow })
              .onChange((isOn: boolean) => {
                this.pressGlow = isOn;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 卡片流光触感：关掉后按卡片不再出现任何流光
          Row() {
            Column({ space: 2 }) {
              Text(this.s('卡片流光触感'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text(this.s('按压卡片时出现流光；关闭后按压没有任何光效'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.glowTouch })
              .onChange((isOn: boolean) => {
                this.glowTouch = isOn;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 显示「继续阅读」卡片：书架顶部那条最近阅读提示的开关
          Row() {
            Column({ space: 2 }) {
              Text(this.s('继续阅读卡片'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text(this.s('在书架顶部显示「继续阅读」提示卡片，关闭后书架更清爽'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.resumeBanner })
              .onChange((isOn: boolean) => {
                this.resumeBanner = isOn;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── ⑤ 灰体文本显示增强 ──
      // 把「次级 / 三级」灰字统一换掉：壁纸很花、或深色主题下灰字发灰看不清时很管用。
      // 生效路径：DesignTokens.paletteFor 里的 grayTextOverride()（全应用统一）。
      // **标题放进卡片内**（用户要求）
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.md }) {
          Text(this.s('灰体文本显示增强'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.label + 1)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().textSecondary)
            .width('100%')

          Text(this.s('把说明文字、时间、占位提示这类灰字统一改成选定颜色'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')

          // ── 深色模式用什么颜色（读数在 builder 体内，切换当帧刷新）──
          this.grayBlockDark()

          // ── 浅色模式用什么颜色 ──
          this.grayBlockLight()

          Text(this.s('默认「自动」＝有背景亮度信息时按对比度选色、否则跟随主题原本的灰字；深浅两套各设各的，互不影响。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')

          Text(this.s('改完立即生效（走 appearanceTick 全应用重算，无需重进页面）'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── 恢复默认（红色按钮，用户要求）＋ 沉浸光感 ──
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height(40)
          .borderRadius(HwRadius.pill)
          .backgroundColor('#D93025')
          .hitTestBehavior(HitTestMode.None)

        ImmersiveCardLayer({ layerRadius: HwRadius.pill, layerShadow: true })

        Text(this.s('恢复默认外观'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwType.label + 1)
          .fontColor('#FFFFFFFF')
      }
      .width('100%')
      .height(40)
      .borderRadius(HwRadius.pill)
      .clip(true)
      .onClick(() => {
        this.restoreDefaults();
      })
    }
  }
}
