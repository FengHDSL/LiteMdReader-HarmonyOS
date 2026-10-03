/**
 * 澄笺 · 法务文档页（隐私政策 / 用户协议）
 * ========================================
 *
 * 从探索中心的「隐私政策 / 用户协议」跳转进来，全屏 Web 加载
 * rawfile 下的 legal_privacy.html / legal_terms.html。
 *
 * 深色模式：HTML 内部使用 `prefers-color-scheme`，**跟随系统深浅色**
 * （用户明确要求跟随系统，不跟应用内主题开关）。
 */

import { NavLifecycle } from '../service/NavLifecycle';
import { ImmersiveBar, ImmersiveIconButton } from '../material/ImmersiveCard';
import { PageBackdrop } from '../components/PageBackdrop';
import { webview } from '@kit.ArkWeb';
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

/** 路由参数（navPageBuilder 注入）：doc = 'privacy' | 'terms' */
export interface LegalDocRoute {
  doc: string;
}

@Component
export struct LegalDoc {
  /** 导航栈：返回探索中心 */
  stack: NavPathStack | null = null;
  /** 生命周期转发 */
  life: NavLifecycle = new NavLifecycle();
  /** 要展示的法务文档：'privacy' | 'terms' */
  doc: string = 'privacy';
  /**
   * 覆盖层承载时的返回回调（探索中心 bindContentCover 滑出面板传入）。
   * 未传 = 走路由栈 stack.pop()。
   */
  onBack: (() => void) | undefined = undefined;
  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 外观刷新计数：主题色 / 灰字 / 沾色改动后由它触发重算 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  private legalCtrl: webview.WebviewController = new webview.WebviewController();

  private palette(): ReaderPalette {
    // 三个来源都要显式读一遍落成局部常量（哪怕不参与运算）：
    // paletteFor 是纯函数读 AppStorage，不登记依赖；这里不登记的话，
    // 主题切换时 ArkUI 会跳过重算，导致部分节点沿用旧调色板（文字变黑、退出重进才恢复）。
    const tick: number = this.appearanceTick;
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  private padTop(): number {
    return this.getUIContext().px2vp(this.safeTopPx) + HwSpace.xs;
  }

  private isDark(): boolean {
    // 统一转调 isDarkTheme：**羊皮纸 / 护眼绿是浅色纸底**，
    // 漏判会让本页背景 / 系统栏按 systemDark 走，与纸色文字对不上。
    return isDarkTheme(this.themeMode, this.systemDark);
  }

  private shellTitle(): string {
    return this.doc === 'terms' ? '用户协议' : '隐私政策';
  }

  private shellSubtitle(): string {
    return this.doc === 'terms'
      ? '使用澄笺前请阅读并同意本协议'
      : '澄笺如何处理你的数据与权限';
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 页面背景：**与探索中心（设置页）同一套优先级**（手选壁纸 → 函数壁纸 → 主题渐变）
      // 此前这里只铺了一层纯色 pageBottom，两个页面背景对不上（用户反馈）。
      PageBackdrop({ palette: this.palette(), dark: this.isDark(), plain: true })

      Column() {
        ImmersiveBar({
          palette: this.palette(),
          barPaddingH: HwSpace.sm,
          barPaddingV: 4,
          barHeight: HwBar.pill,
          barWidth: '100%'
        }) {
          ImmersiveIconButton({
            buttonSize: 34,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              if (this.onBack !== undefined) {
                this.onBack();
              } else if (this.stack !== null) {
                this.stack.pop();
              }
            }
          }) {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(17)
              .fontColor([this.palette().textPrimary])
          }
          Column({ space: 2 }) {
            Text(this.shellTitle())
              .fontSize(HwType.label + 3)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.palette().textPrimary)
            Text(this.shellSubtitle())
              .fontSize(HwType.caption - 1)
              .fontColor(this.palette().textTertiary)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }

        // 协议正文：**撑满剩余高度**（HTML 自带滚动）
        // darkMode(Auto)：随**系统**深浅色切换（与 xjau 的协议页同一套写法）
        Web({ src: this.doc === 'terms' ? $rawfile('legal_terms.html') : $rawfile('legal_privacy.html'),
          controller: this.legalCtrl })
          .width('100%')
          .layoutWeight(1)
          .margin({ top: HwSpace.sm })
          .borderRadius(HwRadius.card)
          .backgroundColor(Color.Transparent)
          // darkMode(Auto)：随**系统**深浅色切换（与 xjau 的协议页同一套写法）。
          // WebDarkMode 是**全局 ambient 枚举**，不能从 @kit.ArkWeb 导入
          .darkMode(WebDarkMode.Auto)
      }
      .width('100%')
      .height('100%')
      .padding({ left: HwSpace.sm, right: HwSpace.sm, top: this.padTop() })
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
