/**
 * 澄笺 · 沉浸光感文本框
 * =====================
 *
 * 给设置页等处的 `TextInput` 一个与全应用一致的**沉浸光感外壳**：
 *   ① 降级层：材质不可用时显示磨砂底，可用时全透明；
 *   ② 沉浸光感承载层（Toggle 方案，与卡片 / 芯片同一条路径）；
 *   ③ TextInput 本体（透明底，文字直接落在材质上）。
 *
 * 用法：
 * ```
 * ImmersiveInput({
 *   palette: this.palette(),
 *   text: this.someValue,               // 受控文本（父组件 @State）
 *   placeholder: L10n.t('提示文字'),
 *   onInput: (v: string) => { this.someValue = v; }
 * }).layoutWeight(1)                    // 无尾随闭包，可以直接链式属性
 * ```
 *
 * 注意：
 *  · **不要**给本组件再接尾随闭包（会触发「尾随闭包后不能链式属性」的限制）；
 *  · `onInput` 是普通函数成员（函数类型不能加 V1 装饰器）。
 */

import {
  HwFont,
  HwRadius,
  HwSpace,
  HwType,
  LIGHT_PALETTE,
  ReaderPalette,
  barFrostColor,
  withAlpha
} from '../theme/DesignTokens';
import { ImmersiveCardLayer } from './ImmersiveCard';
import { getImmersiveMaterial } from './SystemMaterial';
import { L10n } from '../service/L10n';
import { AppearanceFx } from '../service/AppearanceFx';

@Component
export struct ImmersiveInput {
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  @Prop text: string = '';
  @Prop placeholder: string = '';
  /** 输入字号（vp），默认与设置页正文一致 */
  @Prop inputFontSize: number = HwType.label;
  @StorageProp('immersiveLightEnabled') immersiveOn: boolean = true;
  /**
   * 沉浸光感**总开关**（设置 → 外观）：必须用 @StorageProp 声明——
   * 原来 materialOn() 直接读 `this.fxLookOn`（AppStorage.get）**不建立依赖**，
   * 开关变化时组件不重绘、材质层 key 不变、材质也不重挂 → 用户看到「开了光感只有部分卡片有材质」。
   */
  @StorageProp('immersiveLook') fxLookOn: boolean = false;
  @StorageProp('immersiveGrade') fxGrade: string = 'default';
  /** **界面字体**（外观设置 → 界面字体）：组件内文字都从这里取 */
  @StorageProp('appFontFamily') uiFontKey: string = '';
  /** 界面字号缩放系数（外观设置）：输入框文字随界面字号一起放大 */
  @StorageProp('appFontScale') uiFontScale: number = 1;

  /** 输入回调（普通成员：函数类型禁止加 V1 装饰器） */
  onInput: (value: string) => void = () => {
  };

  /** 沉浸光感是否真的会渲染（开关 × 材质构造成功）。 */
  private materialOn(): boolean {
    // 与卡片 / 条栏同一套判定：用户总开关 × 档位（节能不挂材质）× 文件夹打开降级 × 内层开关
    return this.fxLookOn && this.fxGrade !== 'eco'
      && this.immersiveOn && getImmersiveMaterial() !== null;
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      // ① 降级层：材质不可用时磨砂，可用时全透明
      Column()
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .borderRadius(HwRadius.inner)
        .backgroundColor(this.materialOn() ? '#00000000' : (this.fxLookOn ? barFrostColor(this.palette.surface) : withAlpha(this.palette.surface, 'FF')))
        .backgroundBlurStyle((this.fxLookOn && !this.materialOn()) ? BlurStyle.Thin : BlurStyle.NONE)
        .hitTestBehavior(HitTestMode.None)

      // ② 沉浸光感承载层
      ImmersiveCardLayer({ layerRadius: HwRadius.inner, layerShadow: false })

      // ③ 输入框本体：透明底，文字直接落在材质上
      TextInput({ text: this.text, placeholder: this.placeholder })
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .width('100%')
        .fontSize(HwFont.sx(this.inputFontSize, this.uiFontScale))
        .fontColor(this.palette.textPrimary)
        .placeholderColor(this.palette.textTertiary)
        .backgroundColor('#00000000')
        .padding({
          left: HwSpace.sm,
          right: HwSpace.sm
        })
        .maxLines(1)
        .onChange((value: string) => {
          this.onInput(value);
        })
    }
    .width('100%')
    .height(38)
    .borderRadius(HwRadius.inner)
    // **包边**（用户要求）：关闭沉浸光感（或节能档）时底色是实色 surface，
    // 输入框会糊在卡片上看不出是输入框 → 补一圈 1.5vp divider；
    // 材质可用时不画（边缘高光由材质自带）。
    .border({
      width: this.materialOn() ? 0 : 1.5,
      color: this.palette.divider
    })
  }
}
