/**
 * LiteMdReader · 阅读设置面板
 * ============================
 *
 * 书架页与阅读页共用同一份面板，所以设置项全部从 AppStorage 取订阅值，
 * 不通过构造参数传入——两边改完立即互相可见。
 *
 * 分四段：排版（字体族 / 字号 / 行高 / 段距 / 版心 / 缩进）、
 * 主题（五种：跟随系统 / 浅色 / 深色 / 羊皮纸 / 护眼绿）、
 * 显示（信息卡 / 沉浸光感 / 屏幕常亮 / 亮度）、手势说明。
 *
 * 屏幕常亮与亮度是**窗口级**设置，改动即刻通过 AppWindow 下发；
 * 面板在哪个页面打开都一样，因为主窗口句柄由 AppWindow 持有。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { picker } from '@kit.CoreFileKit';
import {
  DARK_BG_PRESETS,
  HwRadius,
  HwSpace,
  HwType,
  HwFont,
  LIGHT_BG_PRESETS,
  NamedColor,
  ReaderPalette,
  ReaderThemeMode,
  bgPresetName,
  isDarkTheme,
  paletteFor,
  READER_BG_DEFAULT_DARK,
  READER_BG_DEFAULT_LIGHT,
  themeModeLabel
} from '../theme/DesignTokens';
import { materialDiagnostics } from '../material/SystemMaterial';
import { FontStore } from '../service/FontStore';
import { FontPickCache } from '../service/FontPickCache';
import { FontPickerList } from '../components/FontPickerList';
import { FontLoadHint } from '../components/FontLoadHint';
import { setKeepScreenOn, setWindowBrightnessLevel } from '../service/AppWindow';
import { ImmersiveCard, ImmersiveChip } from '../material/ImmersiveCard';
import { WallpaperStore } from '../service/WallpaperStore';
import { SettingsMirror } from '../service/SettingsMirror';
import { GEN_WALLPAPERS, GenWallpaperDef } from '../theme/GenWallpaper';
import { L10n } from '../service/L10n';

/** 一键恢复阅读默认（排版 / 主题 / 批注 / 阅读背景全部回到出厂值）。 */
export function restoreReadingDefaults(ctx: common.UIAbilityContext | null): void {
  AppStorage.setOrCreate('readerFontSize', HwType.bodyDefault);
  AppStorage.setOrCreate('readerFontWeight', 0);
  AppStorage.setOrCreate('readerLineHeight', HwType.lineDefault);
  AppStorage.setOrCreate('readerMeasure', HwType.measureDefault);
  AppStorage.setOrCreate('readerParaSpace', 1.0);
  AppStorage.setOrCreate('readerIndent', false);
  AppStorage.setOrCreate('readerShowMeta', true);
  AppStorage.setOrCreate('readerKeepScreenOn', false);
  AppStorage.setOrCreate('readerBrightness', 0);
  AppStorage.setOrCreate('readerFontFamily', '');
  AppStorage.setOrCreate('readerFontFamilyEn', '');
  AppStorage.setOrCreate('hlOpacity', 1);
  AppStorage.setOrCreate('waveThickness', 1);
  AppStorage.setOrCreate('readerCustomBgLight', '');
  AppStorage.setOrCreate('readerCustomBgDark', '');
  AppStorage.setOrCreate('readerBgPath', '');
  AppStorage.setOrCreate('readerBgId', 'zhu');
  if (ctx !== null) {
    WallpaperStore.clearReaderBg(ctx);
    SettingsMirror.save(ctx);
  }
}

@Component
export struct ReadingSettingsPanel {
  @StorageLink('readerFontSize') fontSize: number = HwType.bodyDefault;
  /**
   * **正文字重**（阅读设置 → 字体粗细滑条）：0 = 跟随原样式（标题粗、正文常规），
   * 100~900 = 整篇正文**绝对覆盖**到这一档（标题与粗体词不再更粗，见 HwFont.bodyWeight）。
   */
  @StorageLink('readerFontWeight') bodyWeight: number = 0;
  @StorageLink('readerLineHeight') lineMul: number = HwType.lineDefault;
  @StorageLink('readerMeasure') measure: number = HwType.measureDefault;
  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  /** 外观刷新计数（见 SettingsMirror）：派生色改完后靠它重算 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  /** **沉浸光感总开关**（外观页）：关闭时字体选择按钮要加一圈实色包边（用户要求） */
  @StorageProp('immersiveLook') fxLookOn: boolean = false;
  /**
   * **字体加载提醒弹窗**（用户要求 2026-10-22）：点字体选择时先弹提醒、**加载完再展开**；
   * 2 分钟内（见 FontPickCache.TTL）再点直接展开，不弹也不再加载。
   */
  private loadHint: CustomDialogController = new CustomDialogController({
    builder: FontLoadHint(),
    autoCancel: false,
    customStyle: true,
    alignment: DialogAlignment.Center,
    openAnimation: { duration: 160, curve: Curve.FastOutSlowIn },
    closeAnimation: { duration: 140, curve: Curve.FastOutSlowIn }
  });
  /** 弹窗当前是否真的开着（避免"没开就 close"导致控制器状态错乱） */
  private hintOpen: boolean = false;
  /** **界面字体**（外观设置 → 界面字体）：本面板的界面文字都从这里取 */
  @StorageProp('appFontFamily') uiFontKey: string = '';
  /** 界面字号缩放系数 / 界面字重相对加粗量（外观设置） */
  @StorageProp('appFontScale') uiFontScale: number = 1;
  @StorageProp('appFontWeightDelta') uiFontWeightDelta: number = 0;
  // 沉浸光感已强制开启（见 EntryAbility），这里不再持有开关状态
  @StorageLink('readerFontFamily') fontKey: string = '';
  /** **英数字体**：拉丁与数字走这一款，CJK 回退到上面那款中文字体（见 HwFont.family） */
  @StorageLink('readerFontFamilyEn') fontEnKey: string = '';
  /**
   * 外观设置「同步应用到阅读页」：开着且界面字体非空时，正文用的其实是界面字体，
   * 「中等 / 粗」能不能选要按那款判（见 bodyFontRawKey）。
   * **必须落成 @StorageProp**：在方法里直接 AppStorage.get 不登记依赖，开关一拨
   * 置灰状态不会重算（与 paletteFor 那条同一个坑）。
   */
  @StorageProp('appFontSyncReader') syncUiFont: boolean = false;
  @StorageLink('readerParaSpace') paraSpace: number = 1.0;
  @StorageLink('readerIndent') indentOn: boolean = false;
  @StorageLink('readerShowMeta') showMeta: boolean = true;
  @StorageLink('readerKeepScreenOn') keepOn: boolean = false;
  /** 窗口亮度：0 = 跟随系统，[0.05, 1] 为固定亮度。
   *  不能叫 brightness——与组件基类的 .brightness() 属性方法重名（同 outline 的坑）。 */
  @StorageLink('readerBrightness') brightLevel: number = 0;
  /** 阅读背景自定义色（亮 / 暗主题分别记忆）；空串 = 主题默认 */
  @StorageLink('readerCustomBgLight') customBgLight: string = '';
  @StorageLink('readerCustomBgDark') customBgDark: string = '';
  /** 字体列表选择器是否展开（默认收起，只显示当前字体那一行） */
  @State fontListOpen: boolean = false;
  /** 英数字体列表是否展开（与中文字体那一行各自独立收放） */
  @State fontEnListOpen: boolean = false;
  /** 导入 / 删除字体后自增，交给 FontPickerList 重取列表（@Watch） */
  @State fontListRev: number = 0;
  /**
   * 流光"立即熄灭"信号：字体选择行卡按下有光斑（用户要求流光触感），
   * 但点完不能再留着——自增它让 ImmersiveCard 的 pressing 立刻复位（见 onGlowClearTick）。
   */
  @State glowTick: number = 0;
  /** 阅读背景（与外观壁纸独立）：手选图路径 / 内置款 id */
  @StorageLink('readerBgPath') readerBgPath: string = '';
  @StorageLink('readerBgId') readerBgId: string = '';
  /** 荧光笔透明度 0.2~1（只缩放批注底纹 alpha） */
  @StorageLink('hlOpacity') hlOpacity: number = 1;
  /** 波浪线粗细（thicknessScale，0.5~3）：系统波浪装饰线唯一可调项 */
  @StorageLink('waveThickness') waveThickness: number = 1;

  /** 选一张图作为阅读背景（只影响阅读页，不动应用壁纸）。 */
  private pickReaderBgImage(): void {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      this.toast(L10n.t('拿不到应用上下文'));
      return;
    }
    const ctx = c as common.UIAbilityContext;
    WallpaperStore.pickReaderBg(ctx).then((err: string) => {
      if (err.length > 0) {
        this.toast(err);
      } else {
        this.toast(L10n.t('阅读背景已更新'));
      }
    }).catch((e: BusinessError) => {
      this.toast(L10n.t('选择图片失败：') + e.message);
    });
  }
  /** 滑块的实测尺寸（vp）：防误触的 responseRegion 只能用数值，先量后算 */
  @State sliderW: number = 0;
  @State sliderH: number = 0;

  aboutToAppear(): void {
    // 列表由 FontPickerList 自己取；这里只保证已导入的字体注册进字体管理器（正文要用）
    const ctx = this.hostCtx();
    if (ctx !== null) {
      FontStore.registerAll(ctx);
    }
  }

  /**
   * 面板消失时落一次设置镜像。
   * 这里改的都是持久化键（排版 / 主题 / 显示），落一份文件兜底
   * —— PersistentStorage 在部分设备上没真正落盘（见 service/SettingsMirror.ets）。
   */
  aboutToDisappear(): void {
    SettingsMirror.save(this.hostCtx());
  }

  private hostCtx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  /**
   * 展开 / 收起字体选择列表（用户要求 2026-10-22）：
   *  · 已展开 → 收起；
   *  · 缓存新鲜（2 分钟内）→ **直接展开**，不弹提醒、不重复加载；
   *  · 缓存过期 → **先弹提醒**（无加载图标），数据到位后再展开列表。
   * 提醒延迟 140ms 出现：真正很快的加载（内存/磁盘索引命中）不会闪一下弹窗。
   */
  private toggleFontPick(isEn: boolean): void {
    // 按下时的流光立刻熄灭（用户要求：点击后不能留着光斑）
    this.glowTick++;
    const open: boolean = isEn ? this.fontEnListOpen : this.fontListOpen;
    if (open) {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
        if (isEn) {
          this.fontEnListOpen = false;
        } else {
          this.fontListOpen = false;
        }
      });
      return;
    }
    if (FontPickCache.fresh()) {
      this.expandFontPick(isEn);
      return;
    }
    const c = this.getUIContext().getHostContext();
    let ctx: common.UIAbilityContext | undefined = undefined;
    if (c !== undefined && c !== null) {
      ctx = c as common.UIAbilityContext;
    }
    let finished: boolean = false;
    const timer: number = setTimeout(() => {
      if (!finished) {
        this.showLoadHint();
      }
    }, 140);
    FontPickCache.ensure(ctx).then(() => {
      finished = true;
      clearTimeout(timer);
      this.closeLoadHint();
      this.expandFontPick(isEn);
    }).catch(() => {
      finished = true;
      clearTimeout(timer);
      this.closeLoadHint();
      this.expandFontPick(isEn);
    });
  }

  /** 展开某一侧的字体列表（带高度过渡） */
  private expandFontPick(isEn: boolean): void {
    this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
      if (isEn) {
        this.fontEnListOpen = true;
      } else {
        this.fontListOpen = true;
      }
    });
  }

  private showLoadHint(): void {
    if (this.hintOpen) {
      return;
    }
    this.hintOpen = true;
    this.loadHint.open();
  }

  private closeLoadHint(): void {
    if (!this.hintOpen) {
      return;
    }
    this.hintOpen = false;
    this.loadHint.close();
  }

  /** 导入 .ttf / .otf 字体：复制进沙箱并注册，选中的键就是 familyName。 */
  private importFont(): void {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return;
    }
    const ctx = c as common.UIAbilityContext;
    try {
      const docPicker = new picker.DocumentViewPicker(ctx);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.ttf', '.otf'];
      docPicker.select(options).then((uris: string[]) => {
        if (uris.length === 0) {
          return;
        }
        const family: string = FontStore.importFromUri(ctx, uris[0]);
        if (family.length === 0) {
          this.toast(L10n.t('字体导入失败：仅支持 .ttf / .otf，且不超过 30MB'));
          return;
        }
        FontPickCache.invalidate();
        this.fontListRev++;
        this.fontKey = family;
        this.toast(L10n.t('已导入并启用字体「') + family + '」');
      }).catch((err: BusinessError) => {
        this.toast(L10n.t('选择字体失败：') + err.message);
      });
    } catch (err) {
      this.toast(L10n.t('无法打开文件选择器'));
    }
  }

  /** 长按字体芯片删除文件（本次运行内已注册的字体仍可用，重启后彻底消失）。 */
  private askRemoveFont(family: string): void {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return;
    }
    const ctx = c as common.UIAbilityContext;
    this.getUIContext().getPromptAction().showDialog({
      title: L10n.t('删除字体'),
      message: L10n.t('将删除「') + family + L10n.t('」的字体文件；正在使用它的文档会回退为默认字体。'),
      buttons: [
        { text: L10n.t('取消'), color: this.palette().textSecondary },
        { text: L10n.t('删除'), color: '#FFD93B3B' }
      ]
    }).then((result) => {
      if (result.index !== 1) {
        return;
      }
      if (FontStore.remove(ctx, family)) {
        if (this.fontKey === family) {
          this.fontKey = '';
        }
        // 英数字体用的是同一份导入清单，删掉的正好是它时也要归零，否则正文会引用一个不存在的族
        if (this.fontEnKey === family) {
          this.fontEnKey = '';
        }
        FontPickCache.invalidate();
        this.fontListRev++;
        this.toast(L10n.t('已删除（正在运行的应用里可能仍可见，重启后彻底消失）'));
      } else {
        this.toast(L10n.t('删除失败'));
      }
    }).catch((err: BusinessError) => {
      this.toast(L10n.t('操作失败：') + err.message);
    });
  }
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 书架页不显示阅读相关的说明文案 */
  @Prop showReadingHints: boolean = true;

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1500 });
    } catch (err) {
      // 提示失败不影响主流程
    }
  }

  private fixed1(v: number): string {
    return (Math.round(v * 10) / 10).toFixed(1);
  }

  private isDark(): boolean {
    // 统一转调 isDarkTheme（全工程唯一判定，别再各页手写，见 DesignTokens 里的说明）
    return isDarkTheme(this.themeMode, this.systemDark);
  }

  private palette(): ReaderPalette {
    // 读一下外观刷新计数：主题色 / 灰字 / 沾色在 paletteFor 里读 AppStorage（纯函数读不登记依赖）
    const tick: number = this.appearanceTick;
    return paletteFor(this.themeMode, this.systemDark);
  }

  /** 亮度滑杆当前显示值：0 显示「跟随系统」，否则显示百分比。 */
  private brightnessText(): string {
    if (this.brightLevel <= 0) {
      return L10n.t('跟随系统');
    }
    return Math.round(this.brightLevel * 100) + '%';
  }

  /** 亮度滑杆位置：跟随系统时停在 50，便于用户一拖就动。 */
  private brightnessSliderValue(): number {
    if (this.brightLevel <= 0 || this.brightLevel > 1) {
      return 50;
    }
    return Math.round(this.brightLevel * 100);
  }

  /**
   * 设置滑块。刻意用 `kind` 字符串分发而不是传回调函数：
   * ArkTS 对函数类型的装饰器成员有硬性限制，用枚举分发最稳妥。
   */
  /**
   * 滑块的响应区域 = 滑块本体周围的一条带（防误触）。
   * 默认整条轨道都响应，纵向滚动时手指扫过就会误改数值。
   *
   * 注意：`responseRegion` 的字段在本机 SDK 上**不接受百分比字符串**，
   * 只吃数值（vp），所以先量出滑块宽高（见 sliderRow 的 onAreaChange）再算。
   */
  private sliderThumbRegion(value: number, min: number, max: number): Rectangle {
    const w: number = this.sliderW > 0 ? this.sliderW : 320;
    const h: number = this.sliderH > 0 ? this.sliderH : 44;
    const ratio: number = max > min ? (value - min) / (max - min) : 0.5;
    const p: number = Math.max(0, Math.min(1, ratio));
    const thumbX: number = p * (w - 24);
    // **只认圆点附近**（用户要求：必须点中圆点才能拖，避免纵向滚动时误触改值）：
    // 收紧成 48×32 的小方框，贴着滑块本体
    return { x: Math.max(0, Math.min(w - 48, thumbX - 12)), y: 0, width: 48, height: 32 };
  }

  /**
   * 面板内容分组（用户要求：设置页拆成 排版 / 主题 / 显示 三张卡片）。
   *   ''           = 全部渲染（阅读页半模态继续用整份）
   *   'layout'     = 排版（字体 / 字号 / 行高 / 段距 / 版心 / 首行缩进）
   *   'theme'      = 主题（五档主题 + 阅读背景）
   *   'display'    = 显示（批注滑块 + 信息卡 / 常亮 / 亮度）
   */
  @Prop panelGroup: string = '';
  /** 是否渲染面板自带的标题区。
   *  半模态形态（阅读页 bindSheet）的标题栏由 material/ModalSheet.ets 的
   *  官方标题区提供，传 false 关掉这里，避免出现两份标题。 */
  @Prop showHeader: boolean = true;

  /** 分组判定：'' = 全部渲染。 */
  private inGroup(g: string): boolean {
    return this.panelGroup.length === 0 || this.panelGroup === g;
  }

  /**
   * 滑块当前数值（**在 builder 体内直接读状态**）。
   *
   * ArkTS 的 @Builder **按值传参不会随参数变化刷新 UI**——此前把
   * `valueText` / `value` 作为参数传进去，滑动后右侧数值要等整页重建才更新
   * （用户反馈的"滑动条数值不实时"）。改成在 builder 体内调用本方法读
   * @StorageLink 状态：builder 体内读状态会登记响应式依赖，数值即可实时刷新。
   */
  private sliderValueOf(kind: string): number {
    if (kind === 'font') {
      return this.fontSize;
    }
    if (kind === 'line') {
      return this.lineMul;
    }
    if (kind === 'para') {
      return this.paraSpace;
    }
    if (kind === 'measure') {
      return this.measure;
    }
    if (kind === 'hlop') {
      return Math.round(this.hlOpacity * 100);
    }
    if (kind === 'wavet') {
      return Math.round(this.waveThickness * 100);
    }
    if (kind === 'brightness') {
      return this.brightnessSliderValue();
    }
    return 0;
  }

  /** 滑块右侧的数值文案（同样在 builder 体内读状态，见 sliderValueOf 注释）。 */
  private sliderTextOf(kind: string): string {
    if (kind === 'font') {
      return Math.round(this.fontSize) + ' fp';
    }
    if (kind === 'line') {
      return this.fixed1(this.lineMul);
    }
    if (kind === 'para') {
      return '×' + this.fixed1(this.paraSpace);
    }
    if (kind === 'measure') {
      return L10n.t('每行 ') + Math.round(this.measure) + L10n.t(' 字');
    }
    if (kind === 'hlop') {
      return Math.round(this.hlOpacity * 100) + '%';
    }
    if (kind === 'wavet') {
      return (Math.round(this.waveThickness * 100) / 100) + 'x';
    }
    if (kind === 'brightness') {
      return this.brightnessText();
    }
    return '';
  }

  @Builder
  sliderRow(kind: string, label: string, min: number, max: number, step: number, hint: string) {
    Column({ space: HwSpace.xs }) {
      Row() {
        Text(label)
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
          .fontColor(this.palette().textSecondary)
        Text(this.sliderTextOf(kind))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
          .fontColor(this.palette().accent)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)

      Slider({ value: this.sliderValueOf(kind), min: min, max: max, step: step, style: SliderStyle.OutSet })
        .width('100%')
        .selectedColor(this.palette().accent)
        .blockColor(this.palette().accent)
        // 防误触：**只有滑块附近可拖**。默认整条轨道都响应，
        // 在设置页里纵向滚动时手指扫过轨道就会改数值。
        .responseRegion(this.sliderThumbRegion(this.sliderValueOf(kind), min, max))
        .onAreaChange((oldValue: Area, newValue: Area) => {
          const lw: Length = newValue.width;
          const lh: Length = newValue.height;
          if (typeof lw === 'number' && lw > 0) {
            this.sliderW = lw;
          }
          if (typeof lh === 'number' && lh > 0) {
            this.sliderH = lh;
          }
        })
        .onChange((v: number, mode: SliderChangeMode) => {
          if (kind === 'font') {
            this.fontSize = Math.round(v);
          } else if (kind === 'line') {
            this.lineMul = Math.round(v * 100) / 100;
          } else if (kind === 'measure') {
            this.measure = Math.round(v);
          } else if (kind === 'para') {
            this.paraSpace = Math.round(v * 100) / 100;
          } else if (kind === 'wavet') {
            this.waveThickness = Math.max(0.5, Math.min(3, Math.round(v) / 100));
          } else if (kind === 'hlop') {
            this.hlOpacity = Math.round(v) / 100;
          } else if (kind === 'brightness') {
            // 拖到最右前的全部区间都是固定亮度；要恢复自动用「跟随系统」按钮
            const ratio: number = Math.round(v) / 100;
            this.brightLevel = ratio < 0.05 ? 0.05 : ratio;
            setWindowBrightnessLevel(this.brightLevel);
          }
        })

      if (hint.length > 0) {
        Text(hint)
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 开关行。`kind` 分发与滑块同理。 */
  @Builder
  switchRow(kind: string, label: string, desc: string, isOn: boolean) {
    Row() {
      Column({ space: 2 }) {
        Text(label)
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
          .fontColor(this.palette().textPrimary)
        Text(desc)
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .onChange((isOn: boolean) => {
          if (kind === 'indent') {
            this.indentOn = isOn;
          } else if (kind === 'meta') {
            this.showMeta = isOn;

          } else if (kind === 'keepon') {
            this.keepOn = isOn;
            setKeepScreenOn(isOn);
          }
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontFamily(HwFont.resolve(this.uiFontKey))
      .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
      .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
      .fontColor(this.palette().textSecondary)
      .width('100%')
      .padding({ top: HwSpace.xs })
  }

  /**
   * 主题芯片（**等宽平铺**）：5 个芯片挤在一行会超出卡片（用户反馈），
   * 改为 3 + 2 两行、每行用 layoutWeight 均分——与亮度面板同一形态。
   */
  @Builder
  themeChip(mode: number, label: string) {
    Text(label)
      .fontFamily(HwFont.resolve(this.uiFontKey))
      .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
      .fontWeight(HwFont.bump(this.themeMode === mode ? FontWeight.Medium : FontWeight.Normal,
        this.uiFontWeightDelta))
      .fontColor(this.themeMode === mode ? this.palette().accent : this.palette().textPrimary)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(34)
      .borderRadius(HwRadius.inner)
      .backgroundColor(this.themeMode === mode ? this.palette().accentSoft : this.palette().quoteBg)
      .onClick(() => {
        // 先提示再干活：主题一变是全应用重渲染 + 图表深浅孪生重烘，占在同一帧里
        // 就是上架自检报的冻屏（与外观页深色开关同一口径）
        this.toast(L10n.t('切换中，请耐心等待'));
        setTimeout((): void => {
          this.themeMode = mode;
          // 主题是持久化键：切完立刻落一次镜像，别等面板消失
          SettingsMirror.save(this.hostCtx());
          this.toast(L10n.t('主题：') + themeModeLabel(mode));
        }, 350);
      })
  }

  /** 当前正文用的那款字体有没有真粗体字面（决定滑条要不要给那句提示） */
  private bodyBoldOk(): boolean {
    return FontStore.supportsBold(this.bodyFontRawKey());
  }

  /**
   * 正文**实际**用哪款字体：外观设置里「同步应用到阅读页」开着且界面字体非空时是界面字体，
   * 否则才是这里的正文字体。判"有没有真粗体"必须用这一款，不然置灰会置错档
   * ——拒掉一个本来有效的档位，或放行一个没粗体的字体。
   * （与 HwFont.bodyFamily 同一套优先级，那里返回的是带回退的族名串，不能直接拿去实测。）
   */
  private bodyFontRawKey(): string {
    return this.syncUiFont && this.uiFontKey.length > 0 ? this.uiFontKey : this.fontKey;
  }

  /** 背景色板：预设色圆点 + 一键恢复默认（默认项就是色板里 value 为空的那个）。 */
  @Builder
  bgSwatchRow(label: string, dark: boolean) {
    Row({ space: HwSpace.xs }) {
      Text(label)
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
        .fontColor(this.palette().textSecondary)
        .width(38)
      ForEach(dark ? DARK_BG_PRESETS : LIGHT_BG_PRESETS, (item: NamedColor) => {
        Column()
          .width(26)
          .height(26)
          .borderRadius(13)
          // 「默认」格 = **固定默认色**（纸白 / 碳黑），不随主题变
          //（用户要求："默认固定是阅读背景颜色"）。阅读背景完全独立于主题。
          .backgroundColor(item.value.length > 0 ? item.value
            : (dark ? READER_BG_DEFAULT_DARK : READER_BG_DEFAULT_LIGHT))
          .border({
            width: 1.5,
            color: this.selectedBg(dark) === item.value
              ? this.palette().accent : this.palette().divider
          })
          .onClick(() => {
            if (dark) {
              this.customBgDark = item.value;
            } else {
              this.customBgLight = item.value;
            }
            this.toast(L10n.t('浅色背景：') + bgPresetName(LIGHT_BG_PRESETS, this.customBgLight)
              + L10n.t(' · 深色背景：') + bgPresetName(DARK_BG_PRESETS, this.customBgDark));
          })
      }, (item: NamedColor) => label + item.name)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  private selectedBg(dark: boolean): string {
    return dark ? this.customBgDark : this.customBgLight;
  }

  build() {
    // 这里只输出内容，外壳由调用方的半模态面板（material/ModalSheet.ets）提供——
    // 面板与内容分层，才能在两个页面复用同一份设置而不嵌套两层材质面板。
    Column({ space: HwSpace.lg }) {
        if (this.showHeader) {
          Column({ space: 2 }) {
            Text(L10n.t('阅读设置'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(this.fontSize + 3)
              .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
              .fontColor(this.palette().textPrimary)
            Text(L10n.t('设置会随应用记忆，切换文档同样生效'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        // ── 排版（分组 'layout'）──
        if (this.inGroup('layout')) {
        this.sectionTitle(L10n.t('排版'))

        // 字体：**列表选择器**（用户要求，替换原来两排横向滚动芯片）。
        // 标题行显示当前字体并用它自己渲染，点一下展开 / 收起；列表里一项一个字体。
        Column({ space: HwSpace.xs }) {
          // **沉浸光感**（用户要求）：按钮用 ImmersiveCard 承载——
          // 光感开时是玻璃材质、关时自动降级为实色不透明（同一组件内部判档）。
          ImmersiveCard({
            cardRadius: HwRadius.inner,
            cardPadding: 0,
            cardMaterialShadow: false,
            palette: this.palette(),
            cardClickable: true,
            // **流光触感**（用户要求）：按下有光斑，但点击后立刻熄灭（见 toggleFontPick 里的 glowTick++）
            cardNoGlow: false,
            glowClearTick: this.glowTick,
            cardOnTap: () => {
              // 缓存新鲜直接展开；否则弹提醒、加载完再展开（见 toggleFontPick）
              this.toggleFontPick(false);
            }
          }) {
          Row({ space: HwSpace.xs }) {
            Text(L10n.t('中文字体'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
              .fontColor(this.palette().textSecondary)
            Text(HwFont.label(this.fontKey))
              .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
              .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
              .fontFamily(HwFont.bodyFamily(this.fontKey))
              .fontColor(this.palette().textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            // ⚠️ $r() 的参数必须是**字面量**：展开 / 收起两个箭头各写一份
            if (this.fontListOpen) {
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
          .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 10, bottom: 10 })
          .borderRadius(HwRadius.inner)
          // **包边恒定 1.5vp**（divider 色：实色底上也看得见）
          .border({ width: 1.5, color: this.palette().divider })
          }

          if (this.fontListOpen) {
            FontPickerList({
              palette: this.palette(),
              fxLookOn: this.fxLookOn,
              chosen: this.fontKey,
              rev: this.fontListRev,
              onPick: (k: string) => {
                this.fontKey = k;
                this.toast(L10n.t('正文字体：') + HwFont.label(k));
              },
              onRemove: (family: string) => {
                this.askRemoveFont(family);
              }
            })
          }

          // ── 英数字体：拉丁与数字用这一款，CJK 仍走上面那款中文字体 ──
          // **沉浸光感**（同中文按钮）：材质承载，光感关自动实色
          ImmersiveCard({
            cardRadius: HwRadius.inner,
            cardPadding: 0,
            cardMaterialShadow: false,
            palette: this.palette(),
            cardClickable: true,
            // **流光触感**（用户要求）：按下有光斑，但点击后立刻熄灭（见 toggleFontPick 里的 glowTick++）
            cardNoGlow: false,
            glowClearTick: this.glowTick,
            cardOnTap: () => {
              this.toggleFontPick(true);
            }
          }) {
          Row({ space: HwSpace.xs }) {
            Text(L10n.t('英数字体'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
              .fontColor(this.palette().textSecondary)
            Text(HwFont.label(this.fontEnKey))
              .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
              .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
              .fontFamily(HwFont.family('', this.fontEnKey))
              .fontColor(this.palette().textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            // ⚠️ $r() 的参数必须是**字面量**：展开 / 收起两个箭头各写一份
            if (this.fontEnListOpen) {
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
          .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 10, bottom: 10 })
          .borderRadius(HwRadius.inner)
          // **包边恒定 1.5vp**（同上）
          .border({ width: 1.5, color: this.palette().divider })
          }

          if (this.fontEnListOpen) {
            FontPickerList({
              palette: this.palette(),
              fxLookOn: this.fxLookOn,
              chosen: this.fontEnKey,
              rev: this.fontListRev,
              onPick: (k: string) => {
                this.fontEnKey = k;
                this.toast(L10n.t('英数字体：') + HwFont.label(k));
              },
              onRemove: (family: string) => {
                this.askRemoveFont(family);
              }
            })
          }

          ImmersiveChip({
            palette: this.palette(),
            chipLabel: L10n.t('导入字体（.ttf / .otf）'),
            chipOnTap: () => {
              this.importFont();
            }
          }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(13)
              .fontColor([this.palette().accent])
          }

          Text(L10n.t('预览行只用拉丁字母与数字画，避免缺中文字形的字体显示成方块；字体被卸载后自动回退 HarmonyOS Sans'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ── 排版氛围预设（批 5 之氛围排版）：一键组合 行距 × 段间距 ──
        Row({ space: HwSpace.xs }) {
          Text(L10n.t('排版氛围'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontColor(this.palette().textSecondary)
            .width(64)
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: L10n.t('紧凑'),
            chipActive: this.lineMul <= 1.55 && this.paraSpace <= 0.9,
            chipOnTap: (): void => {
              this.lineMul = 1.5;
              this.paraSpace = 0.7;
            }
          })
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: L10n.t('标准'),
            chipActive: this.lineMul > 1.55 && this.lineMul <= 1.85 && this.paraSpace > 0.9
              && this.paraSpace <= 1.2,
            chipOnTap: (): void => {
              this.lineMul = HwType.lineDefault;
              this.paraSpace = 1.0;
            }
          })
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: L10n.t('舒展'),
            chipActive: this.lineMul > 1.85 || this.paraSpace > 1.2,
            chipOnTap: (): void => {
              this.lineMul = Math.min(HwType.lineMax, HwType.lineDefault + 0.4);
              this.paraSpace = 1.6;
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(L10n.t('一键切捧行距与段落间距的组合，下面的滑块仍可单独微调'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
          .width('100%')

        this.sliderRow('font', L10n.t('正文字号'), HwType.bodyMin, HwType.bodyMax, 1,
          L10n.t('标题字号会按同一比例跟着缩放'))

        // ── 正文字重：一根滑条 0~900（0 = 跟随原样式，其余整篇绝对覆盖）──
        Row({ space: HwSpace.xs }) {
          Text(L10n.t('字体粗细'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontColor(this.palette().textSecondary)
          Blank()
          Text(HwFont.weightName(this.bodyWeight))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontColor(this.palette().accent)
        }
        .width('100%')

        Slider({ value: this.bodyWeight, min: 0, max: 900, step: 100, style: SliderStyle.OutSet })
          .width('100%')
          .selectedColor(this.palette().accent)
          .blockColor(this.palette().accent)
          // **必须点中圆点才能拖**（用户要求，防纵向滚动误触）
          .responseRegion(this.sliderThumbRegion(this.bodyWeight, 0, 900))
          .onChange((v: number, mode: SliderChangeMode) => {
            this.bodyWeight = Math.round(v);
          })

        Text(this.bodyBoldOk()
          ? L10n.t('最左「跟随原样式」＝标题粗、正文常规；往右整篇正文统一到该档，标题与粗体词不再更粗。')
          : L10n.t('最左「跟随原样式」＝标题粗、正文常规；往右整篇正文统一到该档。当前这款字体没有粗体字面，500 以上可能看不出变化，换一款字体即可。'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
          .width('100%')

        this.sliderRow('line', L10n.t('行高倍数'), HwType.lineMin, HwType.lineMax, 0.05, '')

        this.sliderRow('para', L10n.t('段落间距'), 0.6, 2.2, 0.1,
          L10n.t('段落之间的留白倍数，长文阅读时调大更松弛'))

        this.sliderRow('measure', L10n.t('版心宽度'), HwType.measureMin, HwType.measureMax, 1,
          L10n.t('平板与折叠屏上限制正文最大宽度，避免一行过长'))

        this.switchRow('indent', L10n.t('首行缩进'), L10n.t('段落首行空两格，中文排版习惯'), this.indentOn)
        }

        // ── 主题（分组 'theme'）──
        if (this.inGroup('theme')) {
        this.sectionTitle(L10n.t('主题'))

        // 主题芯片：3 + 2 两行等宽平铺（原来一行 5 个会顶出卡片，用户反馈）
        Row({ space: HwSpace.xs }) {
          this.themeChip(ReaderThemeMode.System, L10n.t('跟随系统'))
          this.themeChip(ReaderThemeMode.Light, L10n.t('浅色'))
          this.themeChip(ReaderThemeMode.Dark, L10n.t('深色'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: HwSpace.xs }) {
          this.themeChip(ReaderThemeMode.Sepia, L10n.t('羊皮纸'))
          this.themeChip(ReaderThemeMode.Green, L10n.t('护眼绿'))
          // 占位：第二行只有两项时也保持与第一行一致的格宽
          Column().layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // ── 阅读背景（分组 'theme'，与主题同卡）──
        this.sectionTitle(L10n.t('阅读背景'))

        Column({ space: HwSpace.sm }) {
          this.bgSwatchRow(L10n.t('浅色'), false)
          this.bgSwatchRow(L10n.t('深色'), true)
          Text(L10n.t('色板第一格是「默认」（纸白 / 碳黑固定色，不随主题变）；选中后所有页面的背景换成所选纯色，光斑保留'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ── 阅读背景壁纸：与「设置 → 外观」的应用壁纸**互相独立**，只影响阅读页 ──
        Column({ space: HwSpace.sm }) {
          Text(L10n.t('阅读背景壁纸'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontColor(this.palette().textPrimary)
          Text(L10n.t('只作用于阅读页正文背后；与「设置 → 外观」里的应用壁纸互不影响'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(GEN_WALLPAPERS, (item: GenWallpaperDef) => {
              Row() {
                ImmersiveChip({
                  palette: this.palette(),
                  chipLabel: item.name,
                  chipActive: this.readerBgId === item.id,
                  chipOnTap: () => {
                    this.readerBgId = this.readerBgId === item.id ? '' : item.id;
                    if (this.readerBgId.length > 0) {
                      // 内置款与手选图互斥：选内置就把图清掉
                      const c = this.getUIContext().getHostContext();
                      if (c !== undefined && c !== null) {
                        WallpaperStore.clearReaderBg(c as common.UIAbilityContext);
                      }
                    }
                  }
                }) {
                  Column()
                    .width(14)
                    .height(14)
                    .borderRadius(4)
                    .linearGradient({ angle: 165, colors: [[item.top, 0.0], [item.bottom, 1.0]] })
                }
              }
              .margin({ right: HwSpace.xs, bottom: HwSpace.xs })
            }, (item: GenWallpaperDef) => 'rbg_' + item.id)
          }
          .width('100%')

          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.readerBgPath.length > 0,
              chipLabel: this.readerBgPath.length > 0 ? L10n.t('更换背景图') : L10n.t('导入背景图'),
              chipOnTap: () => {
                this.pickReaderBgImage();
              }
            })
            if (this.readerBgPath.length > 0) {
              ImmersiveChip({
                palette: this.palette(),
                chipLabel: L10n.t('清除背景图'),
                chipOnTap: () => {
                  const c = this.getUIContext().getHostContext();
                  if (c !== undefined && c !== null) {
                    WallpaperStore.clearReaderBg(c as common.UIAbilityContext);
                  }
                }
              })
            }
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        }

        // ── 显示（分组 'display'）：批注滑块 + 显示相关项 ──
        if (this.inGroup('display')) {
        this.sectionTitle(L10n.t('批注'))

        this.sliderRow('hlop', L10n.t('荧光笔透明度'), 20, 100, 5,
          L10n.t('只影响荧光笔底纹的浓淡；搜索命中与语法底纹不受影响'))

        this.sliderRow('wavet', L10n.t('波浪线粗细'), 50, 300, 25,
          L10n.t('系统波浪装饰线的描边倍率；波峰密度与高度由系统决定，无法单独调节'))

        this.sectionTitle(L10n.t('显示'))

        this.switchRow('meta', L10n.t('文档信息卡'), L10n.t('正文顶部显示字数统计与 Front Matter'), this.showMeta)
        // 沉浸光感开关已移至 设置 → 外观设置（避免重复入口）

        this.switchRow('keepon', L10n.t('屏幕常亮'), L10n.t('阅读时不自动熄屏，仅本应用窗口生效'), this.keepOn)

        Column({ space: HwSpace.xs }) {
          this.sliderRow('brightness', L10n.t('窗口亮度'), 5, 100, 5,
            L10n.t('只调低本应用窗口的亮度，不影响系统设置；夜间阅读不刺眼'))
          if (this.brightLevel > 0) {
            Text(L10n.t('正在使用固定亮度，系统亮度条暂被接管'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: L10n.t('恢复跟随系统'),
              chipOnTap: () => {
                this.brightLevel = 0;
                setWindowBrightnessLevel(0);
                this.toast(L10n.t('亮度已恢复跟随系统'));
              }
            })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        }

        if (this.showReadingHints) {
          Column({ space: HwSpace.xs }) {
            Text(L10n.t('手势'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
              // 用本组件的 palette()（走 paletteFor，含纸色主题的深浅孪生款），
              // 不要 paletteOf(this.isDark())：后者只给纯深/浅色板，
              // 羊皮纸/护眼绿下会拿到不匹配的灰字（截图里这两行说明发灰看不清）
              .fontColor(this.palette().textSecondary)
            Text(L10n.t('阅读页右滑呼出目录，左滑呼出注释；点卡片或划一下另一半屏可收起。'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
              .lineHeight(HwFont.sx(HwType.caption * 1.6, this.uiFontScale))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
