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
import { UserFont, FontStore } from '../service/FontStore';
import { setKeepScreenOn, setWindowBrightnessLevel } from '../service/AppWindow';
import { ImmersiveChip } from '../material/ImmersiveCard';
import { WallpaperStore } from '../service/WallpaperStore';
import { SettingsMirror } from '../service/SettingsMirror';
import { GEN_WALLPAPERS, GenWallpaperDef } from '../theme/GenWallpaper';

/** 一键恢复阅读默认（排版 / 主题 / 批注 / 阅读背景全部回到出厂值）。 */
export function restoreReadingDefaults(ctx: common.UIAbilityContext | null): void {
  AppStorage.setOrCreate('readerFontSize', HwType.bodyDefault);
  AppStorage.setOrCreate('readerLineHeight', HwType.lineDefault);
  AppStorage.setOrCreate('readerMeasure', HwType.measureDefault);
  AppStorage.setOrCreate('readerParaSpace', 1.0);
  AppStorage.setOrCreate('readerIndent', false);
  AppStorage.setOrCreate('readerShowMeta', true);
  AppStorage.setOrCreate('readerKeepScreenOn', false);
  AppStorage.setOrCreate('readerBrightness', 0);
  AppStorage.setOrCreate('readerFontFamily', '');
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
  @StorageLink('readerLineHeight') lineMul: number = HwType.lineDefault;
  @StorageLink('readerMeasure') measure: number = HwType.measureDefault;
  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  /** 外观刷新计数（见 SettingsMirror）：派生色改完后靠它重算 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  // 沉浸光感已强制开启（见 EntryAbility），这里不再持有开关状态
  @StorageLink('readerFontFamily') fontKey: string = '';
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
  /** 用户导入的自定义字体（familyName 即设置键） */
  @State userFonts: UserFont[] = [];
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
      this.toast('拿不到应用上下文');
      return;
    }
    const ctx = c as common.UIAbilityContext;
    WallpaperStore.pickReaderBg(ctx).then((err: string) => {
      if (err.length > 0) {
        this.toast(err);
      } else {
        this.toast('阅读背景已更新');
      }
    }).catch((e: BusinessError) => {
      this.toast('选择图片失败：' + e.message);
    });
  }
  /** 滑块的实测尺寸（vp）：防误触的 responseRegion 只能用数值，先量后算 */
  @State sliderW: number = 0;
  @State sliderH: number = 0;

  aboutToAppear(): void {
    const c = this.getUIContext().getHostContext();
    if (c !== undefined && c !== null) {
      const ctx = c as common.UIAbilityContext;
      FontStore.registerAll(ctx);
      this.userFonts = FontStore.list(ctx);
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
          this.toast('字体导入失败：仅支持 .ttf / .otf，且不超过 30MB');
          return;
        }
        this.userFonts = FontStore.list(ctx);
        this.fontKey = family;
        this.toast('已导入并启用字体「' + family + '」');
      }).catch((err: BusinessError) => {
        this.toast('选择字体失败：' + err.message);
      });
    } catch (err) {
      this.toast('无法打开文件选择器');
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
      title: '删除字体',
      message: '将删除「' + family + '」的字体文件；正在使用它的文档会回退为默认字体。',
      buttons: [
        { text: '取消', color: this.palette().textSecondary },
        { text: '删除', color: '#FFD93B3B' }
      ]
    }).then((result) => {
      if (result.index !== 1) {
        return;
      }
      if (FontStore.remove(ctx, family)) {
        if (this.fontKey === family) {
          this.fontKey = '';
        }
        this.userFonts = FontStore.list(ctx);
        this.toast('已删除（正在运行的应用里可能仍可见，重启后彻底消失）');
      } else {
        this.toast('删除失败');
      }
    }).catch((err: BusinessError) => {
      this.toast('操作失败：' + err.message);
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
      return '跟随系统';
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
    return { x: Math.max(0, Math.min(w - 56, thumbX - 16)), y: 0, width: 56, height: h };
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
      return '每行 ' + Math.round(this.measure) + ' 字';
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
          .fontSize(HwType.label)
          .fontColor(this.palette().textSecondary)
        Text(this.sliderTextOf(kind))
          .fontSize(HwType.label)
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
          .fontSize(HwType.caption)
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
          .fontSize(HwType.label)
          .fontColor(this.palette().textPrimary)
        Text(desc)
          .fontSize(HwType.caption)
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
      .fontSize(HwType.label)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.palette().textSecondary)
      .width('100%')
      .padding({ top: HwSpace.xs })
  }

  @Builder
  /**
   * 主题芯片（**等宽平铺**）：5 个芯片挤在一行会超出卡片（用户反馈），
   * 改为 3 + 2 两行、每行用 layoutWeight 均分——与亮度面板同一形态。
   */
  @Builder
  themeChip(mode: number, label: string) {
    Text(label)
      .fontSize(HwType.label)
      .fontWeight(this.themeMode === mode ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.themeMode === mode ? this.palette().accent : this.palette().textPrimary)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(34)
      .borderRadius(HwRadius.inner)
      .backgroundColor(this.themeMode === mode ? this.palette().accentSoft : this.palette().quoteBg)
      .onClick(() => {
        this.themeMode = mode;
        // 主题是持久化键：切完立刻落一次镜像，别等面板消失
        SettingsMirror.save(this.hostCtx());
        this.toast('主题：' + themeModeLabel(mode));
      })
  }

  @Builder
  fontChip(key: string, label: string) {
    ImmersiveChip({
      chipActive: this.fontKey === key,
      palette: this.palette(),
      chipLabel: label,
      chipOnTap: () => {
        this.fontKey = key;
        this.toast('字体：' + HwFont.label(key));
      }
    })
  }

  /** 背景色板：预设色圆点 + 一键恢复默认（默认项就是色板里 value 为空的那个）。 */
  @Builder
  bgSwatchRow(label: string, dark: boolean) {
    Row({ space: HwSpace.xs }) {
      Text(label)
        .fontSize(HwType.label)
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
            this.toast('浅色背景：' + bgPresetName(LIGHT_BG_PRESETS, this.customBgLight)
              + ' · 深色背景：' + bgPresetName(DARK_BG_PRESETS, this.customBgDark));
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
            Text('阅读设置')
              .fontSize(this.fontSize + 3)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.palette().textPrimary)
            Text('设置会随应用记忆，切换文档同样生效')
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        // ── 排版（分组 'layout'）──
        if (this.inGroup('layout')) {
        this.sectionTitle('排版')

        // 字体：设备自带字体不可靠，只有默认；其余都是用户导入的 .ttf/.otf
        Column({ space: HwSpace.sm }) {
          Text('字体')
            .fontSize(HwType.label)
            .fontColor(this.palette().textSecondary)
          Scroll() {
            Row({ space: HwSpace.xs }) {
              this.fontChip('', '默认')
              ForEach(this.userFonts, (f: UserFont) => {
                Column() {
                  this.fontChip(f.family, f.family)
                }
                .gesture(
                  LongPressGesture()
                    .onAction(() => {
                      this.askRemoveFont(f.family);
                    })
                )
              }, (f: UserFont) => f.family)
            }
            .width('100%')
            .justifyContent(FlexAlign.Start)
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')

          Text('长按字体可删除')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)

          ImmersiveChip({
            palette: this.palette(),
            chipLabel: '导入字体（.ttf / .otf）',
            chipOnTap: () => {
              this.importFont();
            }
          }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(13)
              .fontColor([this.palette().accent])
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        this.sliderRow('font', '正文字号', HwType.bodyMin, HwType.bodyMax, 1, '标题字号会按同一比例跟着缩放')

        this.sliderRow('line', '行高倍数', HwType.lineMin, HwType.lineMax, 0.05, '')

        this.sliderRow('para', '段落间距', 0.6, 2.2, 0.1, '段落之间的留白倍数，长文阅读时调大更松弛')

        this.sliderRow('measure', '版心宽度', HwType.measureMin, HwType.measureMax, 1,
          '平板与折叠屏上限制正文最大宽度，避免一行过长')

        this.switchRow('indent', '首行缩进', '段落首行空两格，中文排版习惯', this.indentOn)
        }

        // ── 主题（分组 'theme'）──
        if (this.inGroup('theme')) {
        this.sectionTitle('主题')

        // 主题芯片：3 + 2 两行等宽平铺（原来一行 5 个会顶出卡片，用户反馈）
        Row({ space: HwSpace.xs }) {
          this.themeChip(ReaderThemeMode.System, '跟随系统')
          this.themeChip(ReaderThemeMode.Light, '浅色')
          this.themeChip(ReaderThemeMode.Dark, '深色')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: HwSpace.xs }) {
          this.themeChip(ReaderThemeMode.Sepia, '羊皮纸')
          this.themeChip(ReaderThemeMode.Green, '护眼绿')
          // 占位：第二行只有两项时也保持与第一行一致的格宽
          Column().layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // ── 阅读背景（分组 'theme'，与主题同卡）──
        this.sectionTitle('阅读背景')

        Column({ space: HwSpace.sm }) {
          this.bgSwatchRow('浅色', false)
          this.bgSwatchRow('深色', true)
          Text('色板第一格是「默认」（纸白 / 碳黑固定色，不随主题变）；选中后所有页面的背景换成所选纯色，光斑保留')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ── 阅读背景壁纸：与「设置 → 外观」的应用壁纸**互相独立**，只影响阅读页 ──
        Column({ space: HwSpace.sm }) {
          Text('阅读背景壁纸')
            .fontSize(HwType.label)
            .fontColor(this.palette().textPrimary)
          Text('只作用于阅读页正文背后；与「设置 → 外观」里的应用壁纸互不影响')
            .fontSize(HwType.caption)
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
              chipLabel: this.readerBgPath.length > 0 ? '更换背景图' : '导入背景图',
              chipOnTap: () => {
                this.pickReaderBgImage();
              }
            })
            if (this.readerBgPath.length > 0) {
              ImmersiveChip({
                palette: this.palette(),
                chipLabel: '清除背景图',
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
        this.sectionTitle('批注')

        this.sliderRow('hlop', '荧光笔透明度', 20, 100, 5,
          '只影响荧光笔底纹的浓淡；搜索命中与语法底纹不受影响')

        this.sliderRow('wavet', '波浪线粗细', 50, 300, 25,
          '系统波浪装饰线的描边倍率；波峰密度与高度由系统决定，无法单独调节')

        this.sectionTitle('显示')

        this.switchRow('meta', '文档信息卡', '正文顶部显示字数统计与 Front Matter', this.showMeta)
        // 沉浸光感开关已移至 设置 → 外观设置（避免重复入口）

        this.switchRow('keepon', '屏幕常亮', '阅读时不自动熄屏，仅本应用窗口生效', this.keepOn)

        Column({ space: HwSpace.xs }) {
          this.sliderRow('brightness', '窗口亮度', 5, 100, 5,
            '只调低本应用窗口的亮度，不影响系统设置；夜间阅读不刺眼')
          if (this.brightLevel > 0) {
            Text('正在使用固定亮度，系统亮度条暂被接管')
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '恢复跟随系统',
              chipOnTap: () => {
                this.brightLevel = 0;
                setWindowBrightnessLevel(0);
                this.toast('亮度已恢复跟随系统');
              }
            })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        }

        if (this.showReadingHints) {
          Column({ space: HwSpace.xs }) {
            Text('手势')
              .fontSize(HwType.label)
              // 用本组件的 palette()（走 paletteFor，含纸色主题的深浅孪生款），
              // 不要 paletteOf(this.isDark())：后者只给纯深/浅色板，
              // 羊皮纸/护眼绿下会拿到不匹配的灰字（截图里这两行说明发灰看不清）
              .fontColor(this.palette().textSecondary)
            Text('阅读页右滑呼出目录，左滑呼出注释；点卡片或划一下另一半屏可收起。')
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
              .lineHeight(HwType.caption * 1.6)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
