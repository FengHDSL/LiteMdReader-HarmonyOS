/**
 * 澄笺 · 设置 · 子页面骨架
 * =====================
 *
 * 设置中心原来在一页里塞了全部内容（约 1400 行），过于臃肿。
 * 现在拆成 4 个独立页面：外观设置 / 数据管理 / 阅读调整 / 探索中心。
 *
 * 本文件提供 4 个页面共用的**外壳**（顶栏 + 背景 + 返回），
 * 各页面只负责往里面填内容——这样拆分过程中每一步都能编译通过，
 * 不会出现「设置页打不开」的中间状态。
 *
 * 注意：这些都是 NavDestination 的内容组件（不是 @Entry 页），
 * 生命周期由 NavDestination 转发（见 service/NavLifecycle.ets）。
 */
import { NavLifecycle } from '../service/NavLifecycle';
import { ImmersiveBar, ImmersiveIconButton, ImmersiveCard } from '../material/ImmersiveCard';
import { GenWallpaper } from '../theme/GenWallpaper';
import { WallpaperStore } from '../service/WallpaperStore';
import { applySystemBarTheme, applyAppColorMode, syncSystemDarkFromContext,
  markThemeApplied, themeChangedSince, startThemeWatchdog, stopThemeWatchdog } from '../service/AppWindow';
import {
  HwBar,
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  isDarkTheme,
  paletteFor
} from '../theme/DesignTokens';

/**
 * 4 个设置子页共用的外壳。
 *
 * 用法：`SettingsShell({ shellTitle: '外观设置', shellSubtitle: '...', stack: this.stack }) { ...内容... }`
 * —— ArkTS 不允许「自定义组件 + 尾随闭包」之后再链式调属性，
 * 所以尺寸/内边距一律走构造参数。
 */
@Component
export struct SettingsShell {
  /** 页面标题 */
  @Prop shellTitle: string = '';
  /** 标题下的说明 */
  @Prop shellSubtitle: string = '';
  /** 导航栈：返回用 */
  stack: NavPathStack | null = null;
  /** 生命周期转发（NavDestination.onShown/onHidden 调用） */
  life: NavLifecycle = new NavLifecycle();
  /**
   * 内容槽：由调用方用尾随闭包传入。
   * ArkUI 里组件要给外部留插槽必须走 @BuilderParam（@Builder 不能被外部覆写）。
   */
  @BuilderParam shellContent: () => void = this.placeholderContent;

  @StorageLink('readerThemeMode') @Watch('onThemeChanged') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 主题纪元：拼进根容器 key，明暗变了整树重建（一次刷新到位） */
  @State themeEpoch: number = 0;
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  @StorageProp('safeBottomPx') safeBottomPx: number = 0;
  @StorageProp('wallpaperPath') wallpaperPath: string = '';
  /** 浅色 / 深色模式各自的壁纸（深浅模式自动切换） */
  @StorageProp('wallpaperPathLight') wallpaperPathLight: string = '';
  @StorageProp('wallpaperPathDark') wallpaperPathDark: string = '';

  /** 当前模式生效的壁纸：浅色用浅色壁纸，深色用深色壁纸；未设置则回退旧全局壁纸 */
  private wallpaperPathEffective(): string {
    if (this.isDark()) {
      return this.wallpaperPathDark.length > 0 ? this.wallpaperPathDark : this.wallpaperPath;
    }
    return this.wallpaperPathLight.length > 0 ? this.wallpaperPathLight : this.wallpaperPath;
  }
  @StorageProp('wallpaperGenId') genWallId: string = '';
  @StorageProp('wallpaperBlur') wallpaperBlur: number = 4;
  /** 遮罩浓度：**必须订阅并在 build 里引用**，否则拖滑块不会实时重绘 */
  @StorageProp('wallpaperScrim') wallpaperScrim: number = 42;

  onThemeChanged(): void {
    applyAppColorMode(this.themeMode);
    applySystemBarTheme(this.isDark());
  }

  /** 系统深浅变化：整页刷新一次（材质 / 壁纸 / 派生色一次到位）。 */
  /**
   * 明暗真的变了才整树重建（themeEpoch 拼在根容器 key 上）。
   * 实机证明 @StorageProp 的 @Watch 不触发，所以由这里主动比对。
   */
  private applyThemeChange(): void {
    const dark: boolean = this.isDark();
    if (!themeChangedSince(dark)) {
      markThemeApplied(dark);
      return;
    }
    markThemeApplied(dark);
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.themeEpoch = this.themeEpoch + 1;
    });
  }

  aboutToAppear(): void {
    // 进来先问一次系统深浅；不一致就整页刷新一次
    syncSystemDarkFromContext();
    this.applyThemeChange();
    applySystemBarTheme(this.isDark());
    // 延后一帧挂内容：转场动画跑在"空内容"的页面上，避免掉帧（用户反馈切二级页卡顿）。
    // **加重试兜底**（大屏 / 平板横屏下转场更重，32ms 的一次性置位偶发竞争失败 →
    // 内容永远不挂载，页面空白 —— 写作日志在大屏横屏"打不开"的嫌疑根因）：
    // 之后 500ms 内每 100ms 再置位一次，幂等无害，任何时序下都能挂上。
    setTimeout(() => {
      this.contentReady = true;
    }, 32);
    let contentRetries: number = 0;
    const contentRetry: number = setInterval(() => {
      this.contentReady = true;
      contentRetries++;
      if (contentRetries >= 5) {
        clearInterval(contentRetry);
      }
    }, 100);
    this.life.onShow = () => {
      syncSystemDarkFromContext();
      this.applyThemeChange();
      // **contentReady 双保险**：大屏 / 平板横屏下转场与 32ms 延迟的时序竞争
      // 偶发内容未挂载（写作日志打开空白的嫌疑之一），页面再次可见时兜底置位
      if (!this.contentReady) {
        this.contentReady = true;
      }
      startThemeWatchdog(() => {
        this.applyThemeChange();
        applySystemBarTheme(this.isDark());
      });
      applySystemBarTheme(this.isDark());
    };
    this.life.onHide = () => {
      stopThemeWatchdog();
    };
  }

  private isDark(): boolean {
    // 统一转调 isDarkTheme：**羊皮纸 / 护眼绿是浅色纸底**。
    // 之前这里只判 Dark / Light，两档纸色会掉到 systemDark → 系统深色时本壳把背景
    // （GenWallpaper darkMode / 遮罩 / 自定义背景色档）按深色压黑，而内容层仍取浅色系深绿字，
    // 结果黑底浅字完全看不清（用户截图：护眼绿芯片高亮、整页纯黑）。
    return isDarkTheme(this.themeMode, this.systemDark);
  }

  /** 外观刷新计数：主题色 / 灰字 / 沾色这类派生色改完后，页面靠它重算（见 SettingsMirror） */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  private palette(): ReaderPalette {
    // 三个来源都要显式读一遍落成局部常量：纯函数 paletteFor 里读 AppStorage 不登记依赖，
    // 这里不登记 themeMode / systemDark 的话主题切换会被 ArkUI 跳过重算（文字变黑）
    const tick: number = this.appearanceTick;
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  private padTop(): number {
    return this.getUIContext().px2vp(this.safeTopPx) + HwSpace.xs;
  }

  private padBottom(): number {
    return this.getUIContext().px2vp(this.safeBottomPx) + HwSpace.sm;
  }

  /**
   * **二级页面切页卡顿优化**：内容延后一帧再构建。
   * 进入二级页时导航转场（右滑）与重内容构建撞在同一帧会掉帧；
   * 先只渲染背景 + 顶栏（轻骨架），转场跑完再挂真正的内容。
   */
  @State contentReady: boolean = false;

  // ── 顶栏折叠：与书架同一套（onDidScroll 每帧累计阈值，别用 onScrollIndex）──
  private scroller: Scroller = new Scroller();
  private scrollAccum: number = 0;
  @State barVisible: boolean = true;

  private toggleBar(show: boolean): void {
    if (this.barVisible === show) {
      return;
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.barVisible = show;
    });
  }

  private onScrollFrame(offset: number): void {
    if (offset > 0) {
      this.scrollAccum += offset;
      if (this.scrollAccum > 72) {
        this.scrollAccum = 0;
        this.toggleBar(false);
      }
    } else if (offset < 0) {
      this.scrollAccum = 0;
      this.toggleBar(true);
    }
  }

  /** 返回设置中心 */
  private goBack(): void {
    if (this.stack !== null) {
      this.stack.pop();
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 背景：与全应用同一套优先级（手选壁纸 → 函数壁纸 → 主题渐变）
      if (this.wallpaperPathEffective().length > 0) {
        Image(WallpaperStore.imageSourceOf(this.wallpaperPathEffective()))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(this.wallpaperBlur)

        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.isDark()))
    } else if (this.genWallId.length > 0) {
      // 设置页用**纯底模式**（不画两个光斑圆，用户要求）
      GenWallpaper({ styleId: this.genWallId, darkMode: this.isDark(), plain: true })

        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.isDark()))
      } else {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [[this.palette().pageTop, 0.0], [this.palette().pageBottom, 1.0]]
          })
      }

      // ── 内容滚动区：从悬浮顶栏底下穿过（与书架同一套）──
      Scroll(this.scroller) {
        Column({ space: HwSpace.lg }) {
          // 内容延后一帧挂载（转场期间是轻骨架，减少掉帧）
          if (this.contentReady) {
            this.shellContent()
          }
        }
        .width('100%')
        // **左对齐**：卡片等内容靠左排在标题栏下方（Column 默认居中，窄卡片会被挤到中间）
        .alignItems(HorizontalAlign.Start)
        .padding({
          left: HwSpace.lg,
          right: HwSpace.lg,
          // 顶部留出「状态栏 + 悬浮胶囊」的高度，首屏不被顶栏压住；
          // 之后滚动内容从胶囊底下穿过
          top: this.padTop() + HwBar.pill + HwSpace.sm,
          bottom: this.padBottom() + HwSpace.xxl
        })
      }
      .width('100%')
      .height('100%')
      // **内容不足一屏时 Scroll 会默认垂直居中**（项目老坑：抽屉标题「居中」的真因）——
      // 内容短的页面（如更新日志）整块会漂到屏幕中间，必须显式顶对齐
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onDidScroll((offset: number, state: ScrollState) => {
        this.onScrollFrame(offset);
      })

      // ── 悬浮材质顶栏：返回 + 标题 + 说明 ──
      // 收起 = 淡出 + 上移 + 关闭命中（不占触摸），与书架底栏同一套处理。
      Column() {
        ImmersiveBar({
          palette: this.palette(),
          barPaddingH: HwSpace.sm,
          barPaddingV: 4,
          barHeight: HwBar.pill,
          barWidth: '100%'
        }) {
          Row({ space: HwSpace.xs }) {
            ImmersiveIconButton({
              buttonSize: 36,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.goBack();
              }
            }) {
              SymbolGlyph($r('sys.symbol.arrow_left'))
                .fontSize(17)
                .fontColor([this.palette().textPrimary])
            }

            Column({ space: 2 }) {
              Text(this.shellTitle)
                .fontSize(HwType.label + 3)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.palette().textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.shellSubtitle.length > 0) {
                Text(this.shellSubtitle)
                  .fontSize(HwType.caption - 1)
                  .fontColor(this.palette().textTertiary)
                  .maxLines(1)
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')
      .padding({ left: HwSpace.md, right: HwSpace.md, top: this.padTop() })
      .hitTestBehavior(this.barVisible ? HitTestMode.Transparent : HitTestMode.None)
      .opacity(this.barVisible ? 1 : 0)
      .translate({ y: this.barVisible ? 0 : -16 })
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(this.palette().pageBottom)
    // **主题纪元拼进根容器 key**：系统深浅一变整树重建，设置页也一次刷新到位
    .key('settings_theme_' + this.themeEpoch)
  }

  /** 默认内容：调用方没传闭包时的占位，避免出现空白页 */
  @Builder
  placeholderContent() {
    ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
      Text('这一板块的内容正在迁入…')
        .fontSize(HwType.label)
        .fontColor(this.palette().textSecondary)
        .width('100%')
    }
  }
}
