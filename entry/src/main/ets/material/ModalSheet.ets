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
 *  · **高度**——手机形态给**档位阶梯**（起档 = 原来那档：fitContent 或 MEDIUM，
 *    往上可拖到 MEDIUM / LARGE，用户要求面板要能手动抬高）；横屏/平板居中窗口
 *    平台不支持多档拖拽，仍走 height 定高。
 *  · **键盘避让**——交给系统：真机实测键盘弹起时半模态自己会让位到输入法上方，
 *    以前在 `SheetKeyboardLift` 里再垫一整段键盘高度属于重复让位，会把面板顶出屏幕
 *    （2026-10-21 删）。那一层现在只当各面板 @Builder 的单根容器。
 *  · **拖拽条（操作提示）**——dragBar: true。
 *  · **关闭按钮**——规范默认显示，showClose: true，出现在标题栏右上角。
 *  · **标题栏**——官方自带标题区（title / subtitle），渲染在左上角，
 *    业务内容**不再自绘标题**，标题文案由各入口通过 ModalSheetSpec 下发。
 *  · **底色必须显式给且不透明**——BindOptions.backgroundColor 默认是 Color.White，
 *    而调色板 surface 自带 70% 透明度，直接透出遮罩就是「面板是透明的」；
 *    这里统一抬到不透明再下发。
 */

import { withAlpha } from '../theme/DesignTokens';

/**
 * 半模态内容的**单根容器**（所有面板共用，内容都包在里面）。
 *
 * **这里以前还负责"键盘抬高"，2026-10-21 实测后删掉了**：原来给内容垫一段等于
 * 键盘高度的底部 padding，理由是 SDK 在 `UIContext.setKeyboardAvoidMode` 的 NOTE 里
 * 把 BindSheet 列进"不做键盘避让"的弹窗清单（Sdk/26.0.0/ets/api/@ohos.arkui.UIContext.d.ts）。
 * 但那条讲的是**页面级避让模式这个 API 管不管弹窗**，不等于半模态自己完全不理会输入法——
 * 真机上键盘弹起时面板已经让位到输入法上方，于是那段 padding 变成纯死空间：
 * 内容被顶到状态栏（原文条被切一半）、下面空一大截，而且**所有**半模态面板一起中招
 * （用户两次反馈，第二次明确说"其他面板也这样，非常高"）。
 *
 * 现在保留这一层只为两件事：① 给各面板的 @Builder 一个**单根**（半模态要求单根节点）；
 * ② 万一哪天系统不再让位，键盘避让的开关仍然只在这一个地方。
 */
@Component
export struct SheetKeyboardLift {
  @Builder
  doNothing() {
  }

  @BuilderParam content: () => void = this.doNothing;

  build() {
    Column() {
      this.content()
    }
    .width('100%')
  }
}

/**
 * 半模态面板的统一打开参数（全新接口，不复用旧面板的任何参数结构）。
 */
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
   * **多档高度**（用户要求：批注面板支持自由调节）：
   * 传入后走 `detents`（拖拽条在几档间切换），忽略 fitContent / 默认高度。
   * ⚠️ SheetOptions.detents 是 **1~3 个元素的元组**（不是数组）。
   * 例：`[SheetSize.FIT_CONTENT, SheetSize.MEDIUM, SheetSize.LARGE]`。
   */
  detents?: [string | number | Resource, (string | number | Resource)?, (string | number | Resource)?];
  /**
   * **大尺寸面板**（网页面板：近乎满屏）：height = SheetSize.LARGE（屏高 90%）。
   * 不传 = 维持 MEDIUM 定高（屏高 60%）。与 detents 互斥（detents 优先）。
   */
  large?: boolean;
  /**
   * **自定义标题区**（CustomBuilder）：传了就用它替换官方标题文案，
   * 用于在标题栏内放操作按钮（如网页面板的「刷新 / 复制链接」）。
   * ⚠️ @Builder 传入必须 `.bind(this)`（括号调用运行时静默失效）。
   */
  titleBuilder?: CustomBuilder;
  /**
   * 隐藏顶部拖拽条：内容本身就是可滚动的 Web 时，拖拽条会与网页内滚动打架。
   */
  hideDragBar?: boolean;
  /**
   * **强制底部全宽面板**（忽略横竖屏与平板断点）：网页面板等「近乎满屏」场景用。
   * 传 true = 始终 SheetType.BOTTOM 且不做宽度收半（横屏也是全宽大面板）。
   */
  fullWidth?: boolean;
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
    // 高度：有 detents 时**不设 height**（detents 接管，拖拽条切档）；
    // 否则 fitContent = 内容自适应，默认官方中档位 = 屏高 60% 定高。
    // dragBar 已开（构成 1），detents 的档位切换正是靠它拖动。
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
  if (spec.detents !== undefined) {
    options.detents = spec.detents;
  } else if (spec.phoneLayout && spec.large !== true) {
    // **手动抬高**（用户要求：所有半模态都要能自己拉高）：以前只给 height = 定高，
    // 拖拽条没有第二档可去，等于"看着能拖、实际拖不动"。这里把单一高度改成
    // **档位阶梯**，起档仍是原来那一档（视觉不变），往上多出可拖的档。
    // ⚠️ 多档拖拽只在手机形态生效（横屏/平板居中窗口不支持），所以宽屏仍走 height。
    const ladderFit: [string | number | Resource,
      (string | number | Resource)?, (string | number | Resource)?] =
      [SheetSize.FIT_CONTENT, SheetSize.MEDIUM, SheetSize.LARGE];
    const ladderMedium: [string | number | Resource,
      (string | number | Resource)?, (string | number | Resource)?] =
      [SheetSize.MEDIUM, SheetSize.LARGE];
    options.detents = spec.fitContent === true ? ladderFit : ladderMedium;
  } else {
    options.height = spec.fitContent === true ? SheetSize.FIT_CONTENT
      : (spec.large === true ? SheetSize.LARGE : SheetSize.MEDIUM);
  }
  // 自定义标题区（网页面板的操作按钮）：给了就替换官方标题文案。
  if (spec.titleBuilder !== undefined) {
    options.title = spec.titleBuilder;
  }
  // 内容自带滚动（Web）时隐藏拖拽条
  if (spec.hideDragBar === true) {
    options.dragBar = false;
  }
  // **竖屏走手机形态**（用户要求 2026-09-30）：强制底部面板，
  // 平板竖屏不转居中窗口；横屏交还系统默认（平板按官方规格居中 480vp）。
  // fullWidth（网页面板）：无视上述规则，始终底部全宽。
  if (spec.fullWidth === true) {
    options.preferType = SheetType.BOTTOM;
  } else if (spec.phoneLayout) {
    options.preferType = SheetType.BOTTOM;
    // **平板竖屏宽度收一半**（用户要求 2026-09-30）：>600vp（官方平板断点）
    // 时面板取根宽的 50%、水平居中，左右不铺满；手机竖屏不设 width，保持全宽。
    if (spec.screenWidth > 600) {
      options.width = spec.screenWidth / 2;
    }
  }
  return options;
}
