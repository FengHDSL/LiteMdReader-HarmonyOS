/**
 * LiteMdReader · 沉浸光感卡片组件族
 * ==================================
 *
 * 全部卡片、按钮、芯片、弹窗面板共用「Toggle 承载层 + Stack 分层」这一条路径，
 * 因为内容区里普通组件挂 systemMaterial 不渲染（见 SystemMaterial.ets 文件头第 2 条）。
 *
 * 分层顺序（自下而上）：
 *   ① 降级层   —— 材质不可用时才可见（半透明底 + 毛玻璃），材质生效时全透明
 *   ② 承载层   —— 隐形 Toggle 画布，材质由它渲染
 *   ③ 内容层   —— 调用方传入的卡片内容
 *
 * 三条容易踩的约定：
 *   · 承载层尺寸用 LayoutPolicy.matchParent，**不能用百分比**。Stack 子节点的百分比
 *     按父级「可用尺寸」解析，卡片在列表里时可用高度往往是整列剩余空间，会把卡片顶大。
 *   · 承载层圆角必须与外壳圆角同源（都取 HwRadius），否则卡片四角会露出内嵌的小圆角边框。
 *   · 固定高度的卡片把高度写在**自己的内容容器**上，不要试图给卡片加 height——
 *     承载层按实测尺寸适配，外壳高度由内容撑开是这套结构的既定语义。
 */

import { LengthMetrics } from '@kit.ArkUI';
import { getImmersiveMaterial, carrierModifier, appAppearanceDark } from './SystemMaterial';
import { appearanceMaterialType } from './SystemMaterial';
import { HwRadius, HwSpace, LIGHT_PALETTE, ReaderPalette, barFrostColor, withAlpha } from '../theme/DesignTokens';

/**
 * 材质承载层：一块「看不见的画布」。
 *
 * 五条属性缺一不可，逐条原因：
 *   ① LayoutPolicy.matchParent —— 少了尺寸会塌成 0，材质画不出来
 *   ② borderRadius            —— 少了 Toggle 会画自己的按钮图形（自带小圆角 + 描边）
 *   ③ backgroundColor 透明    —— 不透明底色垫在材质之下，叠出灰感甚至完全遮住
 *   ④ enabled(false) 等       —— 承载层抢走焦点与点击，内容点不动
 *   ⑤ attributeModifier 置末尾 —— 材质必须放在所有样式属性之后，否则被后续属性覆盖
 */
@Component
export struct ImmersiveCardLayer {
  @Prop layerRadius: number = HwRadius.card;
  @Prop layerShadow: boolean = true;
  /** 非对称圆角（书形封面等）：四角分别指定；>=0 才生效，否则用 layerRadius */
  @Prop layerRadiusTL: number = -1;
  @Prop layerRadiusTR: number = -1;
  @Prop layerRadiusBL: number = -1;
  @Prop layerRadiusBR: number = -1;
  @StorageProp('immersiveLightEnabled') immersiveOn: boolean = true;
  /** 深浅外观（材质深色罩的依赖）：切深浅模式时承载层重挂对应材质 */
  @StorageProp('readerThemeMode') themeModeForMaterial: number = 0;
  @StorageProp('systemDark') systemDarkForMaterial: boolean = false;

  /** 圆角：四角独立值（书形封面）优先，未指定的角回落统一值 */
  private radiusValue(): BorderRadiuses {
    return {
      topLeft: this.layerRadiusTL >= 0 ? this.layerRadiusTL : this.layerRadius,
      topRight: this.layerRadiusTR >= 0 ? this.layerRadiusTR : this.layerRadius,
      bottomLeft: this.layerRadiusBL >= 0 ? this.layerRadiusBL : this.layerRadius,
      bottomRight: this.layerRadiusBR >= 0 ? this.layerRadiusBR : this.layerRadius
    };
  }

  build() {
    Toggle({ type: ToggleType.Button, isOn: false })
      // **深浅切换时强制重建节点**：systemMaterial 在同一节点上重复设置
      // 不保证生效（实测切深浅后材质不变），换 key 让框架销毁重建承载层，
      // 新节点挂对应外观的材质（深色罩 / 浅色透明）。
      .key('matlayer_' + this.themeModeForMaterial + '_' + (this.systemDarkForMaterial ? 'D' : 'L'))
      .width(LayoutPolicy.matchParent)
      .height(LayoutPolicy.matchParent)
      .borderRadius(this.radiusValue())
      .backgroundColor(Color.Transparent)
      .enabled(false)
      .focusable(false)
      .accessibilityLevel('no')
      .hitTestBehavior(HitTestMode.None)
      .attributeModifier(carrierModifier(this.layerShadow, this.immersiveOn, appAppearanceDark()))
  }
}

/**
 * 通用光感卡片外壳。
 *
 * 用法：`ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.md }) { ...内容... }`
 *
 * 注意 ArkTS 不允许在「尾随闭包初始化的自定义组件」后面继续链式调用属性，
 * 所以 `Row`/`Column` 上原来的 `.onClick()`、`.padding()`、`.alignItems()` 等
 * 必须改写成构造参数（cardOnTap / cardPadding / cardAlignItems）。
 */
@Component
export struct ImmersiveCard {
  /** 圆角，与承载层同源 */
  @Prop cardRadius: number = HwRadius.card;
  /** 内边距。padding 挂在内部内容容器上，卡片外层不设 padding，承载层才能铺满整张卡 */
  @Prop cardPadding: number = HwSpace.md;
  /** 是否保留材质自带投影。成排小卡片传 false，避免投影在卡间缝隙叠成暗带 */
  @Prop cardMaterialShadow: boolean = true;
  /** 内容排列方向 */
  @Prop cardDirection: FlexDirection = FlexDirection.Column;
  /** 内容间距 */
  @Prop cardSpace: number = 0;
  /** 内容交叉轴对齐。默认 Start；Flex 的交叉轴默认值与 Row/Column 不同，必须显式给 */
  @Prop cardAlignItems: ItemAlign = ItemAlign.Start;
  /** 卡片宽度 */
  @Prop cardWidth: Length = '100%';
  /** 覆盖降级底色；空串表示用调色板的 surface */
  @Prop cardBackground: string = '';
  /** 是否参与点击（空实现即不可点） */
  @Prop cardClickable: boolean = false;
  /** 卡片流光触感（外观设置）：开启后按压卡片才出现流光（照搬 xjau cardGlowTouch） */
  @StorageProp('cardGlowTouch') flowTouch: boolean = true;
  /** 主题色流光（外观设置）：按压光晕改用主题色；关闭为白光 */
  @StorageProp('immersivePressGlow') pressGlow: boolean = true;
  /** 卡片降级样式：mica（云母磨砂）/ solid（实色纯底） */
  @StorageProp('cardFallback') fallbackMode: string = 'mica';
  @State pressing: boolean = false;
  /**
   * 流光坐标换算用的**普通字段组**（不参与渲染，不用 @State——照搬 xjau MaterialCard）。
   *   · cardWinX/Y：卡片左上角在窗口中的位置。按下那一瞬由 `windowX - x` 反推
   *     （这时组件内坐标一定准），之后靠 onAreaChange 的**位移增量**维护——
   *     列表滚动时卡片在动，增量必须跟上，否则光斑会黏在卡片原处。
   *   · lastTouchWinX/Y：最近一次触摸的窗口坐标，卡片位置变了要重算。
   *   · lastAreaX/Y + areaReady：上一次 onAreaChange 报的全局坐标，用来求增量。
   *     只取增量、不用绝对值：globalPosition 的原点与 windowX/Y 未必是同一套，
   *     但两者在滚动中的**变化量**必然一致。
   *   · glowX/Y：光斑中心（@State，触发重绘）。
   */
  private cardWinX: number = 0;
  private cardWinY: number = 0;
  private lastTouchWinX: number = 0;
  private lastTouchWinY: number = 0;
  private lastAreaX: number = 0;
  private lastAreaY: number = 0;
  private areaReady: boolean = false;
  @State glowX: number = 0;
  @State glowY: number = 0;
  /** 沉浸光感开关（已强制开启，见 EntryAbility；此项不再暴露给用户） */
  @StorageProp('immersiveLightEnabled') immersiveOn: boolean = true;
  /** 卡片沾色：卡片上再压一层 10% 主题色薄染（材质生效时降级层是透明的，靠这层才看得见沾色） */
  @StorageProp('cardTint') cardTintOn: boolean = true;
  /**
   * 主题色键（'' = 跟随主题默认色）。
   * 沾色层只在**用户显式选了主题色**时才画：否则每张卡片都会被默认强调色染一层，
   * 属于"没设置却被改了外观"。与 paletteFor 里沾色分支的判定口径保持一致。
   */
  @StorageProp('themeColor') themeColorKey: string = '';
  /**
   * 调色板由调用方传入，避免组件内部重复读全局态。
   *
   * ⚠️ **必须加 `@Prop`**：不加的话它是普通成员变量，ArkUI 只在**组件创建时**赋值一次，
   * 之后父组件重渲染传进来的新调色板**不会更新**（`@Prop` 才是"父变子跟着变"）。
   * 本工程 5 个沉浸组件（Card / IconButton / Chip / SheetPanel / Bar）都踩过这个坑：
   * 切羊皮纸/护眼绿后，芯片与按钮里的文字仍是旧配色（深色下发灰、浅色下发白），
   * 表现为"文字颜色不对、按钮看不清"——而页面其它用 palette() 直取的节点是对的，
   * 于是形成"局部错、整体对"的怪现象。
   */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /** 点击回调 */
  cardOnTap: () => void = () => {
  };

  @Builder
  doNothing() {
  }

  @BuilderParam cardContent: () => void = this.doNothing;

  /** 材质是否真的会渲染。用于决定降级层是否可见。 */
  private materialOn(): boolean {
    return this.immersiveOn && getImmersiveMaterial() !== null;
  }

  private fallbackColor(): string {
    // **材质可用时不能铺不透明底**：以前先判 cardBackground，于是传了底色的卡片
    // （代码块、引用、图表）永远压着一层实色，材质叠上去也看不出光感。
    // 现在保留卡片自身色调但降到 55% 不透明——既有色差，又让材质透出来。
    if (this.materialOn()) {
      return this.cardBackground.length > 0 ? withAlpha(this.cardBackground, '8C') : '#00000000';
    }
    if (this.cardBackground.length > 0) {
      return this.cardBackground;
    }
    // 云母磨砂：与顶/底栏同一套配方（barFrostColor，随「玻璃通透程度」变化），
    // 半透明能看到壁纸透出来——实色纯底会像一块灰板贴在壁纸上。
    if (this.fallbackMode === 'mica') {
      return barFrostColor(this.palette.surface);
    }
    return withAlpha(this.palette.surface, 'FF');
  }

  /** 流光颜色：主题色流光开 = accent；关 = 白光（照搬 xjau 语义）。build 内不能声明变量。 */
  private glowColor(): string {
    return this.pressGlow ? this.palette.accent : "#FFFFFF";
  }

  /**
   * 跟手滑动的流光（照搬 xjau MaterialCard.updatePressGlow）。
   * Move 也要处理：流光像「光」而不是「按下高亮」，就在于手指滑动时跟着走。
   * 抬起与取消必须熄灭，否则会在卡片上留一块不会消失的光斑。
   */
  private updatePressGlow(event: TouchEvent): void {
    if (!this.flowTouch) {
      return;
    }
    if (event.touches.length === 0) {
      return;
    }
    const t: TouchObject = event.touches[0];
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.pressing = false;
      return;
    }
    if (event.type !== TouchType.Down && event.type !== TouchType.Move) {
      return;
    }
    if (event.type === TouchType.Down) {
      // 按下这一瞬 x/y 一定是相对当前卡片位置的准确值，用它反推卡片窗口原点
      this.cardWinX = t.windowX - t.x;
      this.cardWinY = t.windowY - t.y;
    }
    this.lastTouchWinX = t.windowX;
    this.lastTouchWinY = t.windowY;
    this.syncGlowPosition();
    this.pressing = true;
  }

  /**
   * 用最近一次触摸的窗口坐标重算光斑位置。
   * 手指不动、页面在滚时也要调用它（onAreaChange 里同样会调）——
   * 这正是「光效追随手指」与「卡片自己移动了但手指没动」两种情况的分界。
   */
  private syncGlowPosition(): void {
    this.glowX = this.lastTouchWinX - this.cardWinX;
    this.glowY = this.lastTouchWinY - this.cardWinY;
  }

  private fallbackBlur(): BlurStyle {
    if (this.materialOn()) {
      return BlurStyle.NONE;
    }
    return this.fallbackMode === 'mica' ? BlurStyle.Thin : BlurStyle.NONE;
  }

  /**
   * 按压流光：**必须走 overlay，不能放进 Stack 里**。
   * 它是一块装饰层；卡片根 Stack 的高度是内容驱动的，
   * 把它作为 Stack 的孩子会把卡片撑到 240 高——首页长按「继续阅读」卡片
   * 会整块弹大，就是这个原因。overlay 不参与父组件尺寸计算。
   *
   * 规模按用户反馈收小收淡（原来 240 直径 / 35% 不透明度，太抢眼）：
   * 现在 150 直径、峰值 18%。
   */
  @Builder
  pressGlowOverlay() {
    // 不再要求 cardClickable：多数卡片（设置节、信息卡）不可点，
    // 要求可点的话「卡片流光触感 / 主题色流光」调了也看不到效果。
    if (this.flowTouch && this.pressing) {
      Column()
        .width(150)
        .height(150)
        .radialGradient({
          center: ['50%', '50%'],
          radius: 75,
          colors: [[withAlpha(this.glowColor(), '2E'), 0], ['#00000000', 1]]
        })
        .position({ x: this.glowX - 75, y: this.glowY - 75 })
        .hitTestBehavior(HitTestMode.None)
    }
  }

  build() {
    Stack() {
      // ① 降级层：仅在材质不可用时可见。底色必须带透明度，否则毛玻璃被完全盖住。
      Column()
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .borderRadius(this.cardRadius)
        .backgroundColor(this.fallbackColor())
        .backgroundBlurStyle(this.fallbackBlur())
        .hitTestBehavior(HitTestMode.None)

      // ② 材质承载层
      ImmersiveCardLayer({ layerRadius: this.cardRadius, layerShadow: this.cardMaterialShadow })

      // ②′ 卡片沾色层（可选）：材质生效时降级层是全透明的，**底色沾色根本看不见**
      //     （palette.surface 的沾色只落在内容色上），所以单独压一层 10% 主题色薄染
      //     —— 参考项目 xjau 的 cardTintLayer 同款做法。
      //     只在「开了沾色 + 选了主题色」时才画（用户没选主题色就不该被动改观感）。
      if (this.cardTintOn && this.themeColorKey.length > 0) {
        Column()
          .width(LayoutPolicy.matchParent)
          .height(LayoutPolicy.matchParent)
          .borderRadius(this.cardRadius)
          .backgroundColor(withAlpha(this.palette.accent, '1A'))
          .hitTestBehavior(HitTestMode.None)
      }

      // ③ 内容层。
      // **这里刻意不设 hitTestBehavior(HitTestMode.None)。**
      // 曾经照抄「内容层设 None 让承载层收到触摸」的做法，结果是卡片里任何
      // Scroll / Slider / 长按选择都失效——因为 None 会让该节点自身不参与触摸测试，
      // 而滚动、拖动、长按选择都需要节点自身接到手势。
      // 我们用的是静态材质，不需要承载层接收触摸（它自己已经是 None），
      // 所以内容层保持默认即可：子组件照常可交互，卡片自身的 onClick 由
      // 未被子组件消费的点击冒泡上来触发。
      Flex({
        direction: this.cardDirection,
        justifyContent: FlexAlign.Start,
        alignItems: this.cardAlignItems,
        space: { main: LengthMetrics.vp(this.cardSpace) }
      }) {
        this.cardContent()
      }
      .width('100%')
      .padding(this.cardPadding)
    }
    .width(this.cardWidth)
    .borderRadius(this.cardRadius)
    .clip(true)
    // 流光走 overlay（不占布局），见 pressGlowOverlay 注释
    .overlay(this.pressGlowOverlay, { align: Alignment.TopStart })
    // 记录卡片窗口原点的**位移增量**（照搬 xjau MaterialCard：滚动时卡片被带走，
    // 增量必须跟上并重算光斑，否则手指不动、页面滚动，光斑黏在卡片原处）
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      const gx: number = typeof newArea.globalPosition.x === 'number' ? newArea.globalPosition.x : this.lastAreaX;
      const gy: number = typeof newArea.globalPosition.y === 'number' ? newArea.globalPosition.y : this.lastAreaY;
      if (this.areaReady) {
        this.cardWinX += gx - this.lastAreaX;
        this.cardWinY += gy - this.lastAreaY;
        if (this.pressing) {
          this.syncGlowPosition();
        }
      }
      this.lastAreaX = gx;
      this.lastAreaY = gy;
      this.areaReady = true;
    })
    .onTouch((event: TouchEvent) => {
      this.updatePressGlow(event);
    })
    .onClick(() => {
      if (this.cardClickable) {
        this.cardOnTap();
      }
    })
  }
}

/**
 * 圆形图标按钮：Toggle 承载层 + 调用方叠加的 SymbolGlyph。
 *
 * 官方虽写明 `Button` 支持 systemMaterial，但真机实测普通 Button 挂材质**不渲染**，
 * 同尺寸的 ToggleType.Button 则正常，所以全仓统一只走 Toggle。
 */
@Component
export struct ImmersiveIconButton {
  @Prop buttonSize: number = 40;
  @Prop buttonRadius: number = HwRadius.pill;
  /** 是否保留材质投影。小尺寸按钮建议 false */
  @Prop buttonMaterialShadow: boolean = true;
  @StorageProp('immersiveLightEnabled') immersiveOn: boolean = true;
  /** 调色板：**必须 @Prop**，否则父组件换主题后不更新（见 ImmersiveCard 里的说明） */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /**
   * 按压跟手流光（与 ImmersiveCard 同一套实现、同一组开关）。
   * miha_hm 的做法：材质本身**不做**按压反馈（`interactive: true` 的材质实测不渲染），
   * 按压光效是在材质**之上**再叠一层跟手的径向渐变光斑 —— 手指滑到哪，光跟到哪。
   */
  /** 卡片流光触感（外观设置）：关闭后按压一点光都不出现 */
  @StorageProp('cardGlowTouch') flowTouch: boolean = true;
  /** 主题色流光（外观设置）：开启用 accent，关闭为白光 */
  @StorageProp('immersivePressGlow') pressGlow: boolean = true;
  @State pressing: boolean = false;
  @State glowX: number = 0;
  @State glowY: number = 0;
  /**
   * 坐标换算用的普通字段组（照搬 ImmersiveCard / xjau MaterialCard，不参与渲染）：
   * 按下那一瞬用 `windowX - x` 反推按钮的窗口原点，之后靠 onAreaChange 的**位移增量**维护
   * —— 网格滚动时按钮在动，增量必须跟上，否则光斑会黏在按钮原处。
   */
  private cardWinX: number = 0;
  private cardWinY: number = 0;
  private lastTouchWinX: number = 0;
  private lastTouchWinY: number = 0;
  private lastAreaX: number = 0;
  private lastAreaY: number = 0;
  private areaReady: boolean = false;
  buttonOnTap: () => void = () => {
  };

  @Builder
  doNothing() {
  }

  @BuilderParam buttonIcon: () => void = this.doNothing;

  private materialOn(): boolean {
    return this.immersiveOn && getImmersiveMaterial() !== null;
  }

  // ── 按压跟手流光：开关与坐标字段的声明放在组件顶部，见 struct 开头 ──

  /** 流光颜色：主题色流光开 = accent；关 = 白光。 */
  private glowColor(): string {
    return this.pressGlow ? this.palette.accent : '#FFFFFF';
  }

  /**
   * 光斑直径：取按钮本身的 2 倍。
   * 按钮只有 26~36vp 且常成排挨着，光斑再大就会糊到相邻按钮上（面板又裁不到），
   * 所以这里缩放为按钮尺寸的 2 倍，配合外层 clip(true) 收在按钮圆内。
   */
  private glowSize(): number {
    return this.buttonSize * 2;
  }

  /** 跟手更新光斑位置；Up / Cancel 必须熄灭，否则按钮上会留一块不消失的光斑。 */
  private updatePressGlow(event: TouchEvent): void {
    if (!this.flowTouch) {
      return;
    }
    if (event.touches.length === 0) {
      return;
    }
    const t: TouchObject = event.touches[0];
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.pressing = false;
      return;
    }
    if (event.type !== TouchType.Down && event.type !== TouchType.Move) {
      return;
    }
    if (event.type === TouchType.Down) {
      this.cardWinX = t.windowX - t.x;
      this.cardWinY = t.windowY - t.y;
    }
    this.lastTouchWinX = t.windowX;
    this.lastTouchWinY = t.windowY;
    this.syncGlowPosition();
    this.pressing = true;
  }

  /** 用最近一次触摸的窗口坐标重算光斑位置（页面滚动导致按钮移动时也要调）。 */
  private syncGlowPosition(): void {
    this.glowX = this.lastTouchWinX - this.cardWinX;
    this.glowY = this.lastTouchWinY - this.cardWinY;
  }

  /**
   * 流光层走 **overlay**（不参与布局）：作为 Stack 子节点会把按钮撑大，
   * 而 overlay 只画在按钮自己的区域上。
   */
  @Builder
  pressGlowOverlay() {
    if (this.flowTouch && this.pressing) {
      Column()
        .width(this.glowSize())
        .height(this.glowSize())
        .radialGradient({
          center: ['50%', '50%'],
          radius: this.glowSize() / 2,
          // 两档淡出：单档实色会得到一个硬边圆盘，看着不像光
          colors: [[withAlpha(this.glowColor(), '2E'), 0], ['#00000000', 1]]
        })
        .position({ x: this.glowX - this.glowSize() / 2, y: this.glowY - this.glowSize() / 2 })
        .hitTestBehavior(HitTestMode.None)
    }
  }

  build() {
    Stack() {
      // 降级层：材质不可用时给一个可见的底，否则圆形按钮会「消失」
      Column()
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .borderRadius(this.buttonRadius)
        .backgroundColor(this.materialOn() ? '#00000000' : this.palette.surface)
        .backgroundBlurStyle(this.materialOn() ? BlurStyle.NONE : BlurStyle.Thin)
        .hitTestBehavior(HitTestMode.None)

      ImmersiveCardLayer({ layerRadius: this.buttonRadius, layerShadow: this.buttonMaterialShadow })

      this.buttonIcon()
    }
    .width(this.buttonSize)
    .height(this.buttonSize)
    .borderRadius(this.buttonRadius)
    // **光斑裁在按钮圆内**：按钮小、彼此挨得近，不裁就会糊到相邻按钮上。
    // 必须在 borderRadius 之后，圆角才参与裁剪（否则裁成直角）。
    .clip(true)
    .overlay(this.pressGlowOverlay, { align: Alignment.TopStart })
    // 位移增量维护：按钮被列表/网格带走时重算光斑（否则手指不动、光斑黏在原处）
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      if (!this.flowTouch) {
        // 流光关闭时不维护坐标：书架上每个格子都挂着一颗 ⋯ 按钮，
        // 网格滚动会高频回调，能省的换算就省掉。areaReady 保持 false，
        // 之后重新打开开关时第一次回调只记基准、不算增量，不会跳。
        return;
      }
      const gx: number = typeof newArea.globalPosition.x === 'number' ? newArea.globalPosition.x : this.lastAreaX;
      const gy: number = typeof newArea.globalPosition.y === 'number' ? newArea.globalPosition.y : this.lastAreaY;
      if (this.areaReady) {
        this.cardWinX += gx - this.lastAreaX;
        this.cardWinY += gy - this.lastAreaY;
        if (this.pressing) {
          this.syncGlowPosition();
        }
      }
      this.lastAreaX = gx;
      this.lastAreaY = gy;
      this.areaReady = true;
    })
    .onTouch((event: TouchEvent) => {
      this.updatePressGlow(event);
    })
    .onClick(() => {
      this.buttonOnTap();
    })
  }
}

/**
 * 小尺寸芯片。默认关闭材质自带投影（成排小卡片投影会叠成暗带）。
 */
@Component
export struct ImmersiveChip {
  @Prop chipPaddingH: number = HwSpace.sm;
  @Prop chipPaddingV: number = 6;
  @Prop chipActive: boolean = false;
  @StorageProp('immersiveLightEnabled') immersiveOn: boolean = true;
  /** 调色板：**必须 @Prop**，否则父组件换主题后不更新（见 ImmersiveCard 里的说明） */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /**
   * **自定义色调**（8 位 hex，如 '#FF2E7D32' 绿 / '#FFD32F2F' 红）：
   * 非空时覆盖 accent（前景 + 材质薄染同色）；空串 = 跟随主题 accent。
   */
  @Prop chipTint: string = '';
  /** **必须 @Prop**：文案随状态变化（如使用模式切换后）要能回刷 */
  @Prop chipLabel: string = '';
  chipOnTap: () => void = () => {
  };

  @Builder
  doNothing() {
  }

  @BuilderParam chipPrefix: () => void = this.doNothing;

  private materialOn(): boolean {
    return this.immersiveOn && getImmersiveMaterial() !== null;
  }

  private tintSoft(): string {
    // 8 位 hex → 把 alpha 段换成 33 的薄染版本
    return this.chipTint.length >= 9 ? ('#33' + this.chipTint.substring(3)) : this.chipTint;
  }

  private chipColor(): string {
    if (this.chipTint.length > 0) {
      return this.chipActive ? this.tintSoft() : this.palette.surface;
    }
    if (this.materialOn()) {
      // 材质生效时只留一层主题色薄染，颜色优先级低于材质，不会被完全遮住
      return this.chipActive ? this.palette.accentSoft : '#00000000';
    }
    return this.chipActive ? this.palette.accentSoft : this.palette.surface;
  }

  private chipTextColor(): string {
    if (this.chipTint.length > 0) {
      return this.chipActive ? this.chipTint : this.palette.textSecondary;
    }
    return this.chipActive ? this.palette.accent : this.palette.textSecondary;
  }

  build() {
    Stack() {
      Column()
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .borderRadius(HwRadius.pill)
        .backgroundColor(this.chipColor())
        .backgroundBlurStyle(this.materialOn() ? BlurStyle.NONE : BlurStyle.Thin)
        .hitTestBehavior(HitTestMode.None)

      ImmersiveCardLayer({ layerRadius: HwRadius.pill, layerShadow: false })

      Row({ space: HwSpace.xs }) {
        this.chipPrefix()
        Text(this.chipLabel)
          .fontSize(13)
          .fontColor(this.chipTextColor())
          .fontWeight(this.chipActive ? FontWeight.Medium : FontWeight.Normal)
      }
      .padding({ left: this.chipPaddingH, right: this.chipPaddingH, top: this.chipPaddingV, bottom: this.chipPaddingV })
    }
    .borderRadius(HwRadius.pill)
    .onClick(() => {
      this.chipOnTap();
    })
  }
}

/**
 * 半模态面板 / 侧滑抽屉的光感外壳。
 *
 * 面板和普通卡片遇到的是同一堵墙，所以内容统一包这一层，由 Toggle 承载层渲染材质。
 * 与卡片唯一的差别：面板需要裁切，所以这里 clip(true)——不需要往外溢光。
 *
 * 宽高做成参数，是为了同一套外壳能同时服务底部半模态面板（100% × 内容高）
 * 与左右侧滑抽屉（固定宽 × 100%）。
 */
@Component
export struct ImmersiveSheetPanel {
  @Prop panelRadius: number = HwRadius.sheet;
  @Prop panelPadding: number = HwSpace.lg;
  @Prop panelWidth: Length = '100%';
  @Prop panelHeight: Length = '100%';
  @Prop panelScrollable: boolean = true;
  /**
   * 侧边栏是否使用沉浸光感（用户可在阅读页「更多」里关闭）。
   * 关闭后不走材质承载层，底色改用 `panelPlainColor`（阅读背景同色）。
   */
  @StorageProp('drawerImmersive') drawerImmersive: boolean = true;
  /** 关闭沉浸光感时的面板底色（空串 = 回落 palette.surface）。 */
  @Prop panelPlainColor: string = '';
  @StorageProp('immersiveLightEnabled') immersiveOn: boolean = true;
  /** 调色板：**必须 @Prop**，否则父组件换主题后不更新（见 ImmersiveCard 里的说明） */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;

  @Builder
  doNothing() {
  }

  @BuilderParam panelContent: () => void = this.doNothing;

  private materialOn(): boolean {
    return this.drawerImmersive && this.immersiveOn && getImmersiveMaterial() !== null;
  }

  build() {
    Stack() {
      Column()
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .borderRadius(this.panelRadius)
        .backgroundColor(this.materialOn() ? '#00000000'
          : (this.panelPlainColor.length > 0 ? this.panelPlainColor : this.palette.surface))
        .backgroundBlurStyle(this.materialOn() ? BlurStyle.NONE : BlurStyle.Thin)
        .hitTestBehavior(HitTestMode.None)

      // 关闭沉浸光感时不挂材质承载层（纯色面板）
      if (this.materialOn()) {
        ImmersiveCardLayer({ layerRadius: this.panelRadius, layerShadow: true })
      }

      if (this.panelScrollable) {
        // **Scroll 绝对不能设 hitTestBehavior(HitTestMode.None)。**
        // None 会让该节点自身不参与触摸测试，而滚动正是节点自身的手势——
        // 设了之后浮层内容就完全滑不动了（这是本工程真实踩过的坑）。
        Scroll() {
          Column() {
            this.panelContent()
          }
          .width('100%')
          .padding(this.panelPadding)
        }
        .scrollBar(BarState.Off)
        // Scroll 默认会把**不足一屏**的内容垂直居中——抽屉内容短时整个面板
        // 漂到中间，标题不在左上角。显式顶对齐，内容才从面板顶部开始排。
        .align(Alignment.Top)
        .width('100%')
        .height('100%')
      } else {
        Column() {
          this.panelContent()
        }
        .width('100%')
        .height('100%')
        .padding(this.panelPadding)
      }
    }
    .width(this.panelWidth)
    .height(this.panelHeight)
    .borderRadius(this.panelRadius)
    .clip(true)
    .alignContent(Alignment.TopStart)
  }
}

/** 供页面顶部/底部使用的胶囊容器（单行内容，左右排布）。 */

/**
 * 材质**可用时**的顶/底栏底色。
 *
 * 为什么不能沿用 barFrostColor：材质是**采样它后面那层**来出光感的。
 * 之前把磨砂底垫在材质下面，材质采到的就是那层磨砂而不是正文，
 * 视觉上退化成普通毛玻璃——这就是「沉浸光感没加上」的真正原因。
 * 所以材质可用时只留一层很淡的底（保正文可读），把采样对象让给正文。
 */
export function barBaseColorOnMaterial(surface: string): string {
  const kRaw: number | undefined = AppStorage.get<number>('glassStrength');
  const k: number = kRaw === undefined || isNaN(kRaw) ? 0.7 : Math.max(0, Math.min(100, kRaw)) / 100;
  const a: number = 0.34 - 0.20 * k; // 0.34（保住可读）→ 0.14（尽量通透）
  const v: number = Math.round(a * 255);
  const s: string = v.toString(16).toUpperCase();
  return withAlpha(surface, s.length === 1 ? '0' + s : s);
}

@Component
export struct ImmersiveBar {
  @Prop barPaddingH: number = HwSpace.sm;
  @Prop barPaddingV: number = HwSpace.xs;
  /** 胶囊定高。0 = 自适应；顶栏/底栏随滚动折叠时必须给确定值（HwBar.pill），否则高度过渡没有动画。 */
  @Prop barHeight: number = 0;
  @StorageProp("immersiveLightEnabled") immersiveOn: boolean = true;
  /** 调色板：**必须 @Prop**，否则父组件换主题后不更新（见 ImmersiveCard 里的说明） */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /**
   * 胶囊宽度。必须是 **@Prop**：普通成员不会随父组件状态变化而更新。
   * 顶/底栏「原地横向收缩」就是让这个值在整幅与胶囊宽之间插值——
   * 所以必须传**数值**，字符串 '100%' 插不出中间态。
   */
  @Prop barWidth: Length = "100%";
  /**
   * 条宽的**数值**形式（vp）。官方 HDS 材质层需要数值宽度来计算放大倍率，
   * 字符串 '100%' 算不出来——所以页面知道宽度时必须传这个，不知道就留 0（按 360 兜底）。
   */
  @Prop barWidthPx: number = 0;

  @Builder
  doNothing() {
  }

  @BuilderParam barContent: () => void = this.doNothing;

  /** 材质真的可用吗（开关开 + 构造成功）。只有不可用时才需要磨砂兜底。 */
  private materialOn(): boolean {
    return this.immersiveOn && getImmersiveMaterial() !== null;
  }

  build() {
    Stack() {
      // ① 降级层：**仅在材质不可用时可见**——和 ImmersiveCard 完全同一套配方。
      //    之前这里不管材质是否可用都铺一层磨砂，材质再叠上去等于被盖住，
      //    所以顶栏/底栏胶囊看起来「没有沉浸光感」。
      Column()
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .borderRadius(HwRadius.pill)
        .backgroundColor(this.materialOn() ? '#00000000' : barFrostColor(this.palette.surface))
        .backgroundBlurStyle(this.materialOn() ? BlurStyle.NONE : BlurStyle.Thin)
        .hitTestBehavior(HitTestMode.None)

      // ② 材质承载层：与卡片/芯片/按钮**同一个承载层组件**（鸿米家那套 Toggle 方案）。
      //    条栏曾经单独走官方 HDS(Tabs) 材质，但它在设备上不渲染，
      //    于是全应用只有条栏没有光感——统一回承载层。
      ImmersiveCardLayer({ layerRadius: HwRadius.pill, layerShadow: true })

      // ③ 内容层
      Row() {
        this.barContent()
      }
      .width("100%")
      .height(this.barHeight > 0 ? this.barHeight - this.barPaddingV * 2 : "auto")
      .padding({ left: this.barPaddingH, right: this.barPaddingH, top: this.barPaddingV, bottom: this.barPaddingV })
    }
    .width(this.barWidth)
    .height(this.barHeight > 0 ? this.barHeight : "auto")
    .borderRadius(HwRadius.pill)
    // **裁到胶囊内**：收起时宽度插值收缩，里面的按钮淡出/移动时不能溢出胶囊外壳
    //（否则会看到按钮飘在胶囊外面）。必须放在 borderRadius 之后，
    // 圆角才参与裁剪，否则裁成直角。
    .clip(true)
    // 宽度插值就是「原地横向收缩」的动画本体。放在链尾，只作用于上面声明过的属性。
    .animation({ duration: 320, curve: Curve.FastOutSlowIn })
  }
}
