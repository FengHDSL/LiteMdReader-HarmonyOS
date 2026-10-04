/**
 * 澄笺 · 半模态面板（ModalSheet）
 * ================================
 *
 * 本模块是应用内**唯一**的半模态面板实现（2026-09 重做）。
 * 旧的实现已全部删除：自绘的 ImmersiveOverlay、散落在各页面手写的
 * BindOptions（FIT_CONTENT / showClose:false / 自绘标题行）一律不复用。
 *
 * 设计依据（官方规范，逐条对应）：
 *  · 《半模态面板》UX 设计规范：
 *    https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/bindsheet-0000001956852753
 *  · 官方示例仓：https://gitcode.com/HarmonyOS_Samples/HarmonyOSComponentUXExamples
 *
 * 规范落点：
 *  · **模态型**——面板出现时自带遮罩，用户无法与其下方的界面进行交互。
 *    显式声明三件套：`mode: SheetMode.OVERLAY` + `maskColor`（40% 压暗）+
 *    `enableOutsideInteractive: false`（点面板外不响应），不依赖系统默认值。
 *  · **竖屏走手机形态（用户要求 2026-09-30）**——`phoneLayout: true` 时
 *    `preferType: SheetType.BOTTOM` 强制底部全宽面板，平板竖屏不转居中窗口；
 *    横屏交还系统默认（平板按官方规格转居中窗口 480vp）。
 *  · **高度固定 MEDIUM**——屏幕高度的 60%。
 *  · **拖拽条（操作提示）**——dragBar: true。
 *  · **关闭按钮**——规范默认显示，showClose: true，出现在标题栏右上角。
 *  · **标题栏**——官方自带标题区（title / subtitle），渲染在左上角，
 *    业务内容**不再自绘标题**，标题文案由各入口通过 ModalSheetSpec 下发。
 *  · **底色必须显式给且不透明**——BindOptions.backgroundColor 默认是 Color.White，
 *    而调色板 surface 自带 70% 透明度，直接透出遮罩就是「面板是透明的」；
 *    这里统一抬到不透明再下发。
 */

import { withAlpha } from '../theme/DesignTokens';

/** 半模态面板的统一打开参数（全新接口，不复用旧面板的任何参数结构）。 */
export interface ModalSheetSpec {
  /** 官方标题栏主标题（渲染在面板左上角） */
  title: string;
  /** 官方标题栏副标题；空串 = 不显示 */
  subtitle: string;
  /** 面板底色：传当前调色板的 surface，跟随应用主题（内部会强制为不透明） */
  surface: string;
  /**
   * 是否按手机形态出面板（调用方按横竖屏传入：竖屏 true）。
   * true = 强制底部全宽面板（preferType BOTTOM，平板竖屏与手机一致）；
   * false = 交还系统默认（平板横屏按官方规格转居中窗口 480vp）。
   */
  phoneLayout: boolean;
  /**
   * **面板高度改为内容自适应**（SheetSize.FIT_CONTENT）：内容少时面板贴合内容
   * （不留大块空白），内容多时到系统上限、内部滚动区可滚。
   * 不传 / false = 维持 MEDIUM 定高（屏高 60%）。
   */
  fitContent?: boolean;
  /**
   * 调用方实测的根宽（vp）。平板竖屏（>600vp，官方断点）时面板宽度
   * **收一半**且水平居中，不铺满屏幕（用户要求 2026-09-30）；
   * 手机竖屏保持全宽；横屏走系统默认，不用此值。
   */
  screenWidth: number;
  /** 点遮罩 / 关闭按钮 / 下滑关闭后的收起回调（务必把入口状态清空） */
  onDismiss: () => void;
}

/** 统一遮罩浓度：40% 黑。模态型的「自带遮罩」必须有可感知的压暗，否则看起来像非模态。 */
const SHEET_MASK_COLOR: string = '#66000000';

/**
 * 按官方规范组装 bindSheet 的选项。**所有半模态入口统一走这里**，
 * 不要再在页面里手写 SheetOptions。
 */
export function modalSheetOptions(spec: ModalSheetSpec): SheetOptions {
  // 注意：ArkTS 不认三元表达式里的对象字面量（判为「无类型对象」），
  // 所以先按无副标题构造，再按需补 subtitle。
  const title: SheetTitleOptions = { title: spec.title };
  if (spec.subtitle.length > 0) {
    title.subtitle = spec.subtitle;
  }
  // 底色强制不透明：调色板的 surface 自带透明度（70%），透出遮罩就是
  // 「面板是透明的」——这里抬到 FF，卡片观感由材质/内容自己负责。
  const opaqueSurface: string = withAlpha(spec.surface, 'FF');
  const options: SheetOptions = {
    // 高度：fitContent = 内容自适应（内容少贴合内容、多时到上限内部可滚）；
    // 否则官方中档位 = 屏高 60% 定高。
    height: spec.fitContent === true ? SheetSize.FIT_CONTENT : SheetSize.MEDIUM,
    // 构成 1：操作提示（拖拽条），面板尺寸包含多档位时的官方默认结构。
    dragBar: true,
    // 构成 5：关闭按钮，官方默认显示，出现在标题栏右上角。
    showClose: true,
    // 构成 2：标题（业务可配置），渲染在左上角，副标题可选。
    title: title,
    // 显式底色：默认值 Color.White 会盖住主题色（深色模式下尤其刺眼）。
    backgroundColor: opaqueSurface,
    // **模态型三件套**（显式声明，不依赖默认值）：
    // 遮罩盖住下层界面（enableOutsideInteractive=false 即点面板外不响应），
    // OVERLAY 模式浮于页面上层，遮罩给足压暗。
    mode: SheetMode.OVERLAY,
    maskColor: SHEET_MASK_COLOR,
    enableOutsideInteractive: false,
    // 点遮罩 / 关闭按钮 / 下滑关闭都走这里，入口状态由调用方清空。
    onDisappear: spec.onDismiss
  };
  // **竖屏走手机形态**（用户要求 2026-09-30）：强制底部面板，
  // 平板竖屏不转居中窗口；横屏交还系统默认（平板按官方规格居中 480vp）。
  if (spec.phoneLayout) {
    options.preferType = SheetType.BOTTOM;
    // **平板竖屏宽度收一半**（用户要求 2026-09-30）：>600vp（官方平板断点）
    // 时面板取根宽的 50%、水平居中，左右不铺满；手机竖屏不设 width，保持全宽。
    if (spec.screenWidth > 600) {
      options.width = spec.screenWidth / 2;
    }
  }
  return options;
}
