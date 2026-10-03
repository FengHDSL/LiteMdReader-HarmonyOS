/**
 * 澄笺 · 设置中心
 * ==============
 *
 * 原设置页把阅读偏好、外观、备份、书架数据、关于全塞在一页（1600+ 行），
 * 过于臃肿。现已按主题拆成 4 个**独立页面**：
 *
 *   外观设置  pages/SettingsAppearance —— 主题色 / 应用壁纸 / 沉浸光感
 *   数据管理  pages/SettingsData       —— 备份恢复 / 书架数据 / 缓存
 *   阅读调整  pages/SettingsReading    —— 排版 / 主题 / 批注 / 阅读背景
 *   探索中心  pages/SettingsExplore    —— 关于应用 / 法务 / 致谢
 *
 * 本页只保留：总览信息 + 进入四个板块的入口。
 * 搬迁期间各功能在新页与旧页都可用；旧页代码已随本轮重写移除。
 */
import { NavLifecycle } from '../service/NavLifecycle';
import { ImmersiveCard, ImmersiveIconButton } from '../material/ImmersiveCard';
import { SettingsShell } from './SettingsShell';
import { SettingsAppearance } from './SettingsAppearance';
import { SettingsData } from './SettingsData';
import { SettingsReading } from './SettingsReading';
import { SettingsWriting } from './SettingsWriting';
import { SettingsExplore } from './SettingsExplore';
import { DocStore } from '../service/DocStore';
import { bundleManager, common } from '@kit.AbilityKit';
import { GenWallpaper } from '../theme/GenWallpaper';
import { WallpaperStore } from '../service/WallpaperStore';
import {
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  isDarkTheme,
  paletteFor
} from '../theme/DesignTokens';

/** 一个设置板块 */
interface SectionItem {
  name: string;
  route: string;
  note: string;
}

const SECTIONS: SectionItem[] = [
  {
    name: '写作日志',
    route: 'pages/SettingsWriting',
    note: '每天写了多少字 · 一年热力图'
  },
  {
    name: '外观设置',
    route: 'pages/SettingsAppearance',
    note: '主题色 · 应用壁纸 · 卡片与流光'
  },
  {
    name: '阅读调整',
    route: 'pages/SettingsReading',
    note: '排版 · 主题 · 批注 · 阅读背景 · 显示'
  },
  {
    name: '数据管理',
    route: 'pages/SettingsData',
    note: 'zip / WebDAV 备份恢复 · 书架数据 · 缓存'
  },
  {
    name: '探索中心',
    route: 'pages/SettingsExplore',
    note: '关于应用 · 隐私政策与用户协议 · 参考致谢'
  }
];

@Component
export struct Settings {
  /** 导航栈：进入子页 / 返回书架 */
  stack: NavPathStack | null = null;
  /** 生命周期转发（NavDestination.onShown/onHidden） */
  life: NavLifecycle = new NavLifecycle();

  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  // ── 平板分栏右栏的背景订阅（与 SettingsShell 左栏外壳同一套键）──
  @StorageProp('wallpaperPath') wallpaperPath: string = '';
  @StorageProp('wallpaperPathLight') wallpaperPathLight: string = '';
  @StorageProp('wallpaperPathDark') wallpaperPathDark: string = '';
  @StorageProp('wallpaperGenId') genWallId: string = '';
  @StorageProp('wallpaperBlur') wallpaperBlur: number = 4;
  @StorageProp('wallpaperScrim') wallpaperScrim: number = 42;
  @State docCount: number = 0;
  @State totalWords: number = 0;
  /** 本页实测宽度（平板分栏判定） */
  @State rootW: number = 0;
  /** 本页实测高度（横竖屏判定：仅横屏启用分栏） */
  @State rootH: number = 0;
  /**
   * 平板分栏时右栏正在显示的板块路由；空串 = 未选择。
   * **用 @StorageLink 而非 @State**：旋转收栈时 Index 需要把被弹子页的板块名
   * 写回来（右栏接上用户正在看的板块）——AppStorage 是两边的共享通道。
   */
  @StorageLink('settingsInlineSection') inlineSection: string = '';
  /** 进入设置页时的导航栈深（写进 AppStorage 供 Index 在子页侧读取收栈） */
  @State stackDepthAtOpen: number = 0;
  /** 应用版本号（loadVersion 从资源/包信息读取） */
  @State versionName: string = '1.0.0';

  aboutToAppear(): void {
    this.refresh();
    this.loadVersion();
    // 上报进入设置页时的栈深：宽屏切换时 Index 在子页侧据此收栈
    //（主页被 NavDestination 盖住收不到尺寸回调，必须由可见的子页侧触发）
    if (this.stack !== null) {
      this.stackDepthAtOpen = this.stack.size();
      AppStorage.setOrCreate('settingsStackDepth', this.stack.size());
    }
    this.life.onShow = () => {
      this.refresh();
    };
  }

  /** 总览统计：只数用户自建文档（内置教程不计入） */
  private refresh(): void {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return;
    }
    try {
      DocStore.init(c as common.UIAbilityContext);
      const list = DocStore.list(c as common.UIAbilityContext);
      let count: number = 0;
      let words: number = 0;
      for (let k = 0; k < list.length; k++) {
        if (!DocStore.isBuiltinName(list[k].name)) {
          count++;
          words += list[k].wordCount;
        }
      }
      this.docCount = count;
      this.totalWords = words;
    } catch (err) {
      // 统计失败不阻断
    }
  }

  private loadVersion(): void {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName !== undefined && info.versionName.length > 0) {
        this.versionName = info.versionName;
      }
    } catch (err) {
      // 读不到沿用默认
    }
  }

  /** 当前模式生效的壁纸：浅色用浅色壁纸，深色用深色壁纸；未设置则回退旧全局壁纸 */
  private wallpaperPathEffective(): string {
    if (this.isDark()) {
      return this.wallpaperPathDark.length > 0 ? this.wallpaperPathDark : this.wallpaperPath;
    }
    return this.wallpaperPathLight.length > 0 ? this.wallpaperPathLight : this.wallpaperPath;
  }

  private isDark(): boolean {
    // 统一转调 isDarkTheme：**羊皮纸 / 护眼绿是浅色纸底**，
    // 漏判会让本页背景 / 系统栏按 systemDark 走，与纸色文字对不上。
    return isDarkTheme(this.themeMode, this.systemDark);
  }

  /** 外观刷新计数：主题色 / 灰字 / 沾色这类派生色改完后，页面靠它重算（见 SettingsMirror） */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  private palette(): ReaderPalette {
    // 三个来源都要显式读一遍落成局部常量：纯函数 paletteFor 里读 AppStorage 不登记依赖，
    // 这里不登记的话主题切换会被 ArkUI 跳过重算（文字变黑、退出重进才恢复）
    const tick: number = this.appearanceTick;
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1600 });
    } catch (err) {
      // 忽略
    }
  }

  /** 进入设置板块子页：宽屏分栏时在右栏展开（带切换动画），窄屏跳转独立页 */
  private openSection(route: string): void {
    if (this.isWide()) {
      if (this.inlineSection !== route) {
        this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
          this.inlineSection = route;
        });
      }
      return;
    }
    if (this.stack === null) {
      return;
    }
    try {
      this.stack.pushPath({ name: route });
    } catch (err) {
      this.toast('页面跳转失败');
    }
  }

  build() {
    // **平板分栏**（参考系统设置）：宽屏时左侧是设置主页列表，右侧直接显示
    // 选中板块的完整页面；窄屏保持"进入独立页"的跳转方式。
    if (this.isWide()) {
      Row() {
        // 左栏：设置主页
        Column() {
          this.hubShell()
        }
        .width(400)
        .height('100%')

        // 右栏：选中板块的详情页（切换时淡入 + 右移入场）。
        // 背景与左栏（SettingsShell 外壳）同一套——壁纸 / 澄笺壁纸 / 主题渐变，
        // 不再是发白的空板（用户反馈）
        Stack({ alignContent: Alignment.TopStart }) {
          this.paneBackdrop()
          if (this.inlineSection.length > 0) {
            Column() {
              this.inlineDetail()
            }
            .width('100%')
            .height('100%')
            .transition({
              opacity: 0,
              translate: { x: 24 }
            })
          } else {
            Column({ space: HwSpace.sm }) {
              Text('从左侧选择一个设置板块')
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textTertiary)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
          }
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')
      // **不透明底**：修「滑动进入时短暂看到上一级页面」与深色下右栏发白
      .backgroundColor(this.palette().pageBottom)
      // 铺进状态栏 / 手势条区域：右栏背景与左栏一样全出血（避让由各栏内容自理）
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((oldValue: Area, newValue: Area) => {
        // 实测宽度：跨过 760 阈值时分栏 / 收栏自动切换
        const w: Length = newValue.width;
        if (typeof w === 'number' && w > 0) {
          this.rootW = w;
        }
        const h: Length = newValue.height;
        if (typeof h === 'number' && h > 0) {
          this.rootH = h;
        }
        // **宽转窄**（用户要求）：横屏分栏打开的板块，旋转到竖屏应进入该板块的独立页，
        // 而不是回到设置主页。push 后清 inlineSection 防重复。
        if (!this.isWide() && this.inlineSection.length > 0 && this.stack !== null) {
          const route: string = this.inlineSection;
          this.inlineSection = '';
          this.stack.pushPath({ name: route });
        }
      })
    } else {
      Column() {
        this.hubShell()
      }
      .width('100%')
      .height('100%')
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const w: Length = newValue.width;
        if (typeof w === 'number' && w > 0) {
          this.rootW = w;
        }
        const h: Length = newValue.height;
        if (typeof h === 'number' && h > 0) {
          this.rootH = h;
        }
        // **宽转窄**（同上，窄屏分支）：平板横屏分栏打开板块后旋转到竖屏，
        // 主页此时可见，由这里把分栏板块转入独立页。
        if (!this.isWide() && this.inlineSection.length > 0 && this.stack !== null) {
          const route2: string = this.inlineSection;
          this.inlineSection = '';
          this.stack.pushPath({ name: route2 });
        }
      })
    }
  }

  /**
   * 宽屏分栏判定（原：>760vp 启用左右分栏）。
   * **用户要求（2026-09-30）：仅横屏启用分栏**——竖屏（含平板竖屏）与手机端
   * 界面完全一致（单页）；横屏且 >760vp 才分栏。
   */
  private isWide(): boolean {
    return this.rootW > 760 && this.rootW > this.rootH;
  }

  /**
   * 右栏背景：与 SettingsShell（左栏外壳）**同一套优先级**——
   * 手选壁纸 → 澄笺程序化壁纸（纯底模式）→ 主题渐变，再叠可读性遮罩。
   */
  @Builder
  paneBackdrop() {
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
  }

  /** 右栏渲染选中板块的完整页面。 */
  @Builder
  inlineDetail() {
    // ForEach 按 route 建键：**切换板块时整页强制重建**，
    // 避免 if 链在同一槽位复用组件导致"切不过去"
    ForEach([this.inlineSection], (route: string) => {
      if (route === 'pages/SettingsWriting') {
        SettingsWriting({ stack: this.stack })
      } else if (route === 'pages/SettingsAppearance') {
        SettingsAppearance({ stack: this.stack })
      } else if (route === 'pages/SettingsData') {
        SettingsData({ stack: this.stack })
      } else if (route === 'pages/SettingsReading') {
        SettingsReading({ stack: this.stack })
      } else if (route === 'pages/SettingsExplore') {
        SettingsExplore({ stack: this.stack, embedded: true })
      }
    }, (route: string) => route)
  }

  @Builder
  hubShell() {
    SettingsShell({
      shellTitle: '设置',
      shellSubtitle: '按板块进入，各自独立成页',
      stack: this.stack,
      life: this.life
    }) {
      // ── 总览 ──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.xs }) {
          Row({ space: HwSpace.md }) {
            Stack() {
              Image($r('app.media.background'))
                .width(48)
                .height(48)
              Image($r('app.media.foreground'))
                .width(48)
                .height(48)
            }
            .width(48)
            .height(48)
            .borderRadius(12)
            .clip(true)
            .border({ width: 0.8, color: this.palette().divider })

            Column({ space: 2 }) {
              Text('澄笺·ChéngJiān')
                .fontSize(HwType.label + 4)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.palette().textPrimary)
              Text('版本 ' + this.versionName + ' · 沉浸光感 Markdown 阅读器')
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── 四个板块入口 ──
      ForEach(SECTIONS, (item: SectionItem) => {
        ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
          Row({ space: HwSpace.sm }) {
            Column({ space: 3 }) {
              Text(item.name)
                .fontSize(HwType.label + 2)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.palette().textPrimary)
              Text(item.note)
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
                .maxLines(2)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // **圆形按钮**（用户要求：不要胶囊形状）
            ImmersiveIconButton({
              buttonSize: 34,
              buttonRadius: HwRadius.pill,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.openSection(item.route);
              }
            }) {
              Image($r('app.media.chevron_right_circle'))
                .width(20)
                .height(20)
                .fillColor(this.palette().accent)
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          // 平板分栏：整卡可点，宽屏直接在右栏展开，不跳页
          .onClick(() => {
            this.openSection(item.route);
          })
        }
      }, (item: SectionItem) => item.route)

      // ── 页脚 ──
      Text('澄笺 · 光 · 美 · 舒 · 开源')
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: HwSpace.sm })
    }
  }
}
