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
import { applySystemBarTheme, applyAppColorMode } from '../service/AppWindow';
import { GEN_WALLPAPERS, GenWallpaperDef } from '../theme/GenWallpaper';
import { FuncExpr } from '../theme/FuncExpr';
import { WallpaperStore } from '../service/WallpaperStore';
import { SettingsMirror } from '../service/SettingsMirror';
import { ThemeStore } from '../theme/ThemeStore';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  HwRadius,
  HwSpace,
  HwType,
  NamedColor,
  ReaderPalette,
  ReaderThemeMode,
  normalizeHex8,
  paletteFor,
  themeModeLabel
} from '../theme/DesignTokens';

/**
 * 主题色预设：**5 款澄笺色**（与 5 款程序化壁纸同源同名，用户指定）。
 * 取色原则：中等明度、中等饱和——浅色底上够清楚，深色底上不刺眼，
 * 作为强调色与正文搭配时对比度都达标（不艳不淡）。
 * value 是持久化的键，**不要改**（red/blue/orange/purple 等历史键仍保留在
 * ThemeStore 里做兼容解析，只是不再出现在选择项中）。
 */
const THEME_PRESETS: NamedColor[] = [
  { name: '澄光', value: 'cheng' },
  { name: '宣纸', value: 'xuan' },
  { name: '砚青', value: 'yan' },
  { name: '竹影', value: 'zhu' },
  { name: '霞笺', value: 'xia' }
];

/** 灰体文本显示增强的模式（移植自 xjau 的灰字覆盖） */
const GRAY_MODES: NamedColor[] = [
  { name: '自动', value: 'auto' },
  { name: '灰', value: 'gray' },
  { name: '黑', value: 'black' },
  { name: '白', value: 'white' },
  { name: '自定义', value: 'custom' }
];

@Component
export struct SettingsAppearance {
  stack: NavPathStack | null = null;
  life: NavLifecycle = new NavLifecycle();

  @StorageLink('readerThemeMode') @Watch('onThemeChanged') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 外观刷新计数：主题色 / 灰字 / 沾色改动后由它触发重算 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  /**
   * 主题色 / 灰字 / 沾色 / 蒙版这些键：**改一次就落一次镜像盘**
   * （SettingsMirror.save）。PersistentStorage 在部分设备上没真正落盘，
   * 表现为"设置完退出应用就恢复默认"，文件镜像 + 这里的即时保存是兜底。
   */
  @StorageLink('themeColor') @Watch('onAppearanceChanged') themeColor: string = '';
  @State customHex: string = '';
  /** 函数绘制壁纸选中款（空 = 不用） */
  @StorageLink('wallpaperGenId') genWallId: string = '';
  /** 自定义函数壁纸三键（GenWallpaper 的 custom 分支读取绘制） */
  @StorageLink('wallpaperCustomFunc') customFunc: string = 'sin(x*4)*0.25+0.75';
  @StorageLink('wallpaperCustomA') customA: string = '#1E222B';
  @StorageLink('wallpaperCustomB') customB: string = '#E8EDF4';
  /** 编辑草稿（点「应用」先校验再写生效键） */
  @State customFuncDraft: string = '';
  @State customADraft: string = '';
  @State customBDraft: string = '';
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
  /** 页面背景跟随主题色 / 自定义主题色也染背景 */
  @StorageLink('pageBgTint') @Watch('onAppearanceChanged') pageBgTint: boolean = true;
  @StorageLink('customAccentFull') @Watch('onAppearanceChanged') customAccentFull: boolean = false;
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
      this.toast('拿不到应用上下文');
      return;
    }
    WallpaperStore.pickFor(c as common.UIAbilityContext, this.wallpaperEditMode === 'dark')
      .then((err: string) => {
        if (err === '未选择图片') {
          this.toast('未选择图片');
        } else if (err.length > 0) {
          this.toast('导入失败：' + err);
        } else {
          this.toast(this.wallpaperEditMode === 'dark' ? '深色壁纸已更新' : '浅色壁纸已更新');
        }
      }).catch((e: BusinessError) => {
      this.toast('导入失败：' + e.message);
    });
  }

  private clearWallpaper(): void {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      this.toast('拿不到应用上下文');
      return;
    }
    WallpaperStore.clearFor(c as common.UIAbilityContext, this.wallpaperEditMode === 'dark');
    this.toast('已清除壁纸');
  }

  /**
   * 应用自定义函数壁纸：先本地编译表达式校验语法，颜色做 #RRGGBB 归一；
   * 通过后写生效键并选中 custom 款。失败只提示，不覆盖上次有效值。
   */
  private applyCustomFuncWallpaper(): void {
    const check: FuncExpr = FuncExpr.compile(this.customFuncDraft);
    if (!check.ok) {
      this.toast('表达式有误：' + check.error);
      return;
    }
    const normA: string = normalizeHex8(this.customADraft);
    const normB: string = normalizeHex8(this.customBDraft);
    if (normA.length === 0 || normB.length === 0) {
      this.toast('颜色格式：#RRGGBB');
      return;
    }
    this.customFunc = this.customFuncDraft;
    this.customA = '#' + normA.substring(3, 9);
    this.customB = '#' + normB.substring(3, 9);
    this.genWallId = 'custom';
    this.toast('已应用自定义函数壁纸');
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
   * 任一外观键变化（@Watch）：**立刻落一次镜像盘**并广播刷新计数。
   * 不等"退到后台"，避免用户设置完直接杀掉应用时丢设置；
   * 顺带让别的页面（书架 / 阅读页）当场重算派生色。
   *
   * 灰字是**纯函数读 AppStorage**（paletteFor → grayTextOverride），不登记依赖，
   * 所以这里必须递增 appearanceTick：各页面的 palette() 都读了它，
   * 计数一变，全应用当帧重算灰字颜色——改完不用重进页面。
   */
  onAppearanceChanged(): void {
    this.broadcastAppearance();
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
    AppStorage.setOrCreate('cardTint', true);
    AppStorage.setOrCreate('immersivePressGlow', true);
    AppStorage.setOrCreate('cardGlowTouch', true);
    AppStorage.setOrCreate('shelfResumeBanner', true);
    AppStorage.setOrCreate('customAccentFull', false);
    AppStorage.setOrCreate('pageBgTint', true);
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
    this.toast('外观已恢复默认');
  }

  aboutToAppear(): void {
    // 草稿带入当前生效值（已用自定义函数壁纸时打开设置即可见）
    this.customFuncDraft = this.customFunc;
    this.customADraft = this.customA;
    this.customBDraft = this.customB;
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
      Text(title)
        .fontSize(HwType.label)
        .fontColor(this.palette().textPrimary)
        .layoutWeight(1)
      Text(this.grayModeOf(light) === 'auto' ? '自动'
        : (this.grayColorOf(light).length > 0 ? this.grayColorOf(light) : ''))
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
            chipLabel: item.name,
            // 高亮读数在 builder 体内 → 点击后当帧刷新（按值传参才会滞后）
            chipActive: this.grayModeOf(light) === item.value,
            chipOnTap: () => {
              this.applyGrayMode(light, item.value);
              if (item.value !== 'custom') {
                this.toast(title + '灰体文本：' + item.name);
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
          placeholder: '自定义 #RRGGBB',
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
          chipLabel: '应用',
          chipOnTap: () => {
            const norm: string = normalizeHex8(this.grayDraftOf(light));
            if (norm.length === 0) {
              this.toast('格式：#RRGGBB，例如 #9AA0A6');
              return;
            }
            if (light) {
              this.grayColorLight = '#' + norm.substring(3);
            } else {
              this.grayColorDark = '#' + norm.substring(3);
            }
            this.broadcastAppearance();
            this.toast(title + '灰体色已生效');
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
          .animation({ duration: 280, curve: Curve.Friction }),
        TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({ y: -10 }))
          .animation({ duration: 220, curve: Curve.Friction })
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
    this.getUIContext().animateTo({ duration: 260, curve: Curve.Friction }, () => {
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
      shellTitle: '外观设置',
      shellSubtitle: '深色模式 · 主题色 · 应用壁纸 · 卡片与流光 · 灰体文本',
      stack: this.stack,
      life: this.life
    }) {
      // ── ⓪ 主题模式（深色模式开关）──
      // 与「阅读调整 → 主题」的五档是同一个键（readerThemeMode），
      // 这里给一个最常用的快捷开关：深色 on/off + 跟随系统。
      // **标题放进卡片内**（用户要求：卡片外的「主题模式」等文本移入各自卡片）
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.md }) {
          Text('主题模式')
            .fontSize(HwType.label + 1)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().textSecondary)
            .width('100%')

          Row() {
            Column({ space: 2 }) {
              Text('深色模式')
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text('开启后全应用改用深色配色；羊皮纸 / 护眼绿在「阅读调整」里')
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.themeMode === ReaderThemeMode.Dark })
              .onChange((isOn: boolean) => {
                this.themeMode = isOn ? ReaderThemeMode.Dark : ReaderThemeMode.Light;
                this.toast(isOn ? '已切换到深色模式' : '已切换到浅色模式');
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.themeMode === ReaderThemeMode.System,
              chipLabel: '跟随系统',
              chipOnTap: () => {
                this.themeMode = ReaderThemeMode.System;
                this.toast('主题：跟随系统');
              }
            })
            Text('当前：' + themeModeLabel(this.themeMode))
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── ① 主题色（标题已在卡片内，删掉卡片外这一份——用户要求）──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.md }) {
          Text('主题色')
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
                  this.toast('主题色：' + item.name);
                })
            }, (item: NamedColor) => 'tp' + item.name)
          }
          .width('100%')

          // 恢复默认：清空主题色（回到跟随五档主题的默认强调色）
          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.themeColor.length === 0,
              chipLabel: '跟随主题（默认）',
              chipOnTap: () => {
                this.themeColor = '';
                this.toast('已恢复默认主题色');
              }
            })
            Text('当前：' + ThemeStore.label())
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
              placeholder: '自定义 #RRGGBB',
              onInput: (value: string) => {
                this.customHex = value;
              }
            })
            .layoutWeight(1)
            ImmersiveChip({
              palette: this.palette(),
              chipActive: true,
              chipLabel: '应用',
              chipOnTap: () => {
                const norm: string = normalizeHex8(this.customHex);
                if (norm.length === 0) {
                  this.toast('格式：#RRGGBB，例如 #B07A2E');
                  return;
                }
                this.themeColor = norm.substring(3);
                this.toast('自定义主题色已生效');
              }
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Divider().strokeWidth(1).color(this.palette().divider)

          // 页面背景跟随主题色（参考 xjau：内置主题色始终允许染背景）
          Row() {
            Column({ space: 2 }) {
              Text('背景跟随主题色')
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text('页面底色轻微染上主题色，整体更统一')
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
              Text('自定义色也染背景')
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text('关闭时，只有澄笺 5 色会染页面背景')
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
          Text('应用壁纸')
            .fontSize(HwType.label + 1)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().textSecondary)
            .width('100%')

          // **深浅色分别记忆壁纸**：先选要编辑的模式，再选图
          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.wallpaperEditMode === 'light',
              chipLabel: '浅色壁纸',
              chipOnTap: () => {
                this.wallpaperEditMode = 'light';
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.wallpaperEditMode === 'dark',
              chipLabel: '深色壁纸',
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
              chipLabel: '从图库选择',
              chipOnTap: () => {
                this.pickWallpaper();
              }
            })
            if (this.wallpaperEditModePath().length > 0) {
              ImmersiveChip({
                palette: this.palette(),
                chipLabel: '清除壁纸',
                chipOnTap: () => {
                  this.clearWallpaper();
                }
              })
            }
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '取消所有壁纸',
              chipOnTap: () => {
                const c = this.hostCtx();
                if (c !== null) {
                  WallpaperStore.clearFor(c, false);
                  WallpaperStore.clearFor(c, true);
                }
                AppStorage.setOrCreate('wallpaperPath', '');
                this.toast('已取消所有壁纸');
              }
            })
          }
          .width('100%')

          Divider().strokeWidth(1).color(this.palette().divider)

          Text('澄笺壁纸（程序化绘制）')
            .fontSize(HwType.label)
            .fontColor(this.palette().textPrimary)
            .width('100%')
          Text('按「澄·笺」意境生成的渐变纸墨底，无位图资源，任意分辨率都清晰')
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
                    this.toast(this.genWallId.length > 0 ? '壁纸：' + item.name : '已关闭澄笺壁纸');
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

          // ── 自定义函数壁纸（用户要求：支持手动写函数绘画）──
          Divider().strokeWidth(1).color(this.palette().divider)

          Text('自定义函数壁纸')
            .fontSize(HwType.label)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().textPrimary)
            .width('100%')
          Text('写一个 f(x, y) 表达式（结果 0~1），逐格上色：值越大越接近亮色。' +
            '变量 x / y 是 0~1 的位置；可用 + - * / ^ ( ) 与 sin cos tan abs sqrt floor round min max pow、pi、e')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwType.caption * 1.6)
            .width('100%')

          ImmersiveInput({
            palette: this.palette(),
            text: this.customFuncDraft,
            placeholder: '例如 sin(x*4)*0.25+0.75',
            onInput: (value: string) => {
              this.customFuncDraft = value;
            }
          })
            .width('100%')

          Row({ space: HwSpace.xs }) {
            ImmersiveInput({
              palette: this.palette(),
              text: this.customADraft,
              placeholder: '暗端 #1E222B',
              onInput: (value: string) => {
                this.customADraft = value;
              }
            })
              .layoutWeight(1)
            ImmersiveInput({
              palette: this.palette(),
              text: this.customBDraft,
              placeholder: '亮端 #E8EDF4',
              onInput: (value: string) => {
                this.customBDraft = value;
              }
            })
              .layoutWeight(1)
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.genWallId === 'custom',
              chipLabel: '应用',
              chipOnTap: () => {
                this.applyCustomFuncWallpaper();
              }
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: HwSpace.xs }) {
            Text('示例')
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '波纹',
              chipOnTap: () => {
                this.customFuncDraft = 'sin(x*6.28)*sin(y*6.28)*0.4+0.6';
                this.applyCustomFuncWallpaper();
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '对角波',
              chipOnTap: () => {
                this.customFuncDraft = 'sin((x+y)*9)*0.35+0.65';
                this.applyCustomFuncWallpaper();
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '涟漪',
              chipOnTap: () => {
                this.customFuncDraft = 'sqrt(abs(sin(sqrt((x-0.5)*(x-0.5)+(y-0.5)*(y-0.5))*20)))*0.7+0.3';
                this.applyCustomFuncWallpaper();
              }
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 模糊只对手选的图片壁纸有意义；遮罩与「取消蒙版」对两类壁纸都生效
          // （程序化壁纸也会叠这层可读性遮罩），所以放在条件外。
          if (this.wallpaperPathLight.length > 0 || this.wallpaperPathDark.length > 0
            || this.wallpaperPath.length > 0) {
            Row() {
              Text('壁纸模糊')
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
            Text('文字可读性遮罩')
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
              Text('取消蒙版')
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text('关闭后不叠加可读性遮罩，壁纸按原样显示')
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.wallpaperScrim <= 0 })
              .onChange((isOn: boolean) => {
                this.wallpaperScrim = isOn ? 0 : 42;
                this.toast(isOn ? '已取消蒙版（壁纸原样显示）' : '已恢复可读性蒙版');
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text('壁纸越花，遮罩就要越浓，否则正文会看不清；确实不需要时可「取消蒙版」')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── ④ 卡片与流光 ──
      // 「沉浸光感」开关按需求**取消**：材质强制开启（EntryAbility 每次启动置回 true），
      // 「材质类型 / 等级 / 玻璃通透程度 / 卡片降级样式」也一律不再暴露。
      // 这里保留的是真正会被用户感知的三项观感开关（语义照搬 xjau 的外观设置）。
      // **标题放进卡片内**（用户要求）
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.md }) {
          Text('卡片与流光')
            .fontSize(HwType.label + 1)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().textSecondary)
            .width('100%')

          // 卡片沾色：卡片底色混入 10% 主题色（含材质之上的薄染层）
          Row() {
            Column({ space: 2 }) {
              Text('卡片沾色')
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text('卡片染上一成主题色，整体更协调（需先选主题色）')
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
              Text('主题色流光')
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text('按压卡片时的流光改用主题色（关闭为白光）')
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
              Text('卡片流光触感')
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text('按压卡片时出现流光；关闭后按压没有任何光效')
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
              Text('继续阅读卡片')
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text('在书架顶部显示「继续阅读」提示卡片，关闭后书架更清爽')
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
          Text('灰体文本显示增强')
            .fontSize(HwType.label + 1)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().textSecondary)
            .width('100%')

          Text('把说明文字、时间、占位提示这类灰字统一改成选定颜色')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')

          // ── 深色模式用什么颜色（读数在 builder 体内，切换当帧刷新）──
          this.grayBlockDark()

          // ── 浅色模式用什么颜色 ──
          this.grayBlockLight()

          Text('默认「自动」＝有背景亮度信息时按对比度选色、否则跟随主题原本的灰字；' +
            '深浅两套各设各的，互不影响。')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')

          Text('改完立即生效（走 appearanceTick 全应用重算，无需重进页面）')
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

        Text('恢复默认外观')
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
