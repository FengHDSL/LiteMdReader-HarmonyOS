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
 *   placeholder: '提示文字',
 *   onInput: (v: string) => { this.someValue = v; }
 * }).layoutWeight(1)                    // 无尾随闭包，可以直接链式属性
 * ```
 *
 * 注意：
 *  · **不要**给本组件再接尾随闭包（会触发「尾随闭包后不能链式属性」的限制）；
 *  · `onInput` 是普通函数成员（函数类型不能加 V1 装饰器）。
 */

import {
  HwRadius,
  HwSpace,
  HwType,
  LIGHT_PALETTE,
  ReaderPalette,
  barFrostColor
} from '../theme/DesignTokens';
import { ImmersiveCardLayer } from './ImmersiveCard';
import { getImmersiveMaterial } from './SystemMaterial';

@Component
export struct ImmersiveInput {
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  @Prop text: string = '';
  @Prop placeholder: string = '';
  /** 输入字号（vp），默认与设置页正文一致 */
  @Prop inputFontSize: number = HwType.label;
  @StorageProp('immersiveLightEnabled') immersiveOn: boolean = true;

  /** 输入回调（普通成员：函数类型禁止加 V1 装饰器） */
  onInput: (value: string) => void = () => {
  };

  /** 沉浸光感是否真的会渲染（开关 × 材质构造成功）。 */
  private materialOn(): boolean {
    return this.immersiveOn && getImmersiveMaterial() !== null;
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      // ① 降级层：材质不可用时磨砂，可用时全透明
      Column()
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .borderRadius(HwRadius.inner)
        .backgroundColor(this.materialOn() ? '#00000000' : barFrostColor(this.palette.surface))
        .backgroundBlurStyle(this.materialOn() ? BlurStyle.NONE : BlurStyle.Thin)
        .hitTestBehavior(HitTestMode.None)

      // ② 沉浸光感承载层
      ImmersiveCardLayer({ layerRadius: HwRadius.inner, layerShadow: false })

      // ③ 输入框本体：透明底，文字直接落在材质上
      TextInput({ text: this.text, placeholder: this.placeholder })
        .width('100%')
        .fontSize(this.inputFontSize)
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
  }
}
