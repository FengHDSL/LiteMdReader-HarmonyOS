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
import { webview } from '@kit.ArkWeb';
import {
  HwBar,
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
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
    return paletteFor(this.themeMode, this.systemDark);
  }

  private padTop(): number {
    return this.getUIContext().px2vp(this.safeTopPx) + HwSpace.xs;
  }

  private isDark(): boolean {
    if (this.themeMode === ReaderThemeMode.Dark) {
      return true;
    }
    if (this.themeMode === ReaderThemeMode.Light) {
      return false;
    }
    return this.systemDark;
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
      // 页面底色（HTML 自带深浅色背景，跟随系统）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.palette().pageBottom)

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
