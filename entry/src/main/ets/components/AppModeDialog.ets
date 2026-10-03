/**
 * 澄笺 · 使用模式选择弹窗
 * ========================
 *
 * **首次使用**时弹出（`appMode` 为空），让用户明确选择：
 *   · 全量模式：功能正常使用、无限制；
 *   · 基础模式：纯离线——不联网，网络图片不加载，网络备份 / 检查更新等联网功能不可用。
 * 选择后写入 `appMode`；之后可在「探索中心 → 隐私政策 / 用户协议 下方」重新选择。
 *
 * 样式与 UpdateContentDialog 一致（参考本地项目 xjau 的自绘弹窗）：
 * **宽度 '82%' + 卡片实底 + 紧排文字 + 整宽按钮**，不铺满屏幕、不用页面渐变蓝灰底。
 */
import {
  HwSpace, LIGHT_PALETTE, ReaderPalette, ReaderThemeMode, paletteFor, withAlpha
} from '../theme/DesignTokens';
import { APP_MODE_FULL, APP_MODE_OFFLINE } from '../service/UpdateService';

@CustomDialog
export struct AppModeDialog {
  controller?: CustomDialogController;
  /** 标题（首次使用 / 重新选择时不同） */
  @Link titleText: string;
  /** 当前已选模式（'' = 尚未选择） */
  @Link currentMode: string;
  /** 选择回调：写入 appMode 由宿主完成 */
  onPick: (mode: string) => void = (mode: string) => {
  };
  /** 调色板：深浅自适应 */
  @StorageProp('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 调色板：**必须 @Prop**，否则主题切换后不更新（普通成员只在创建时赋值一次） */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;

  private pal(): ReaderPalette {
    // 显式读一遍 themeMode / systemDark 落成局部常量：paletteFor 是纯函数读 AppStorage、
    // 不登记依赖，弹窗构建时若不登记，系统深浅切换后文字会沿用旧配色
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  /** 卡片实底（surface 顶满 alpha，跟随深浅）。 */
  private cardBg(): string {
    return withAlpha(this.pal().surface, 'FF');
  }

  /** 一个模式选项：图标 + 标题 + 一句说明 + 右侧选中标记。 */
  @Builder
  modeRow(mode: string, title: string, desc: string, icon: Resource) {
    Row({ space: 10 }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([this.currentMode === mode ? this.pal().accent : this.pal().textTertiary])
      Column({ space: 2 }) {
        Text(title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().textPrimary)
          .width('100%')
        Text(desc)
          .fontSize(12)
          .fontColor(this.pal().textTertiary)
          .lineHeight(17)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.currentMode === mode) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(16)
          .fontColor([this.pal().accent])
      }
    }
    .width('100%')
    .padding(10)
    .borderRadius(10)
    // 选中态只做**淡色底 + 细描边**，不再是大色块（用户反馈旧版又大又生硬）
    .backgroundColor(this.currentMode === mode ? this.pal().accentSoft : this.pal().quoteBg)
    .border({ width: 1, color: this.currentMode === mode ? this.pal().accent : this.pal().divider })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.onPick(mode);
      this.controller?.close();
    })
  }

  build() {
    Column({ space: 10 }) {
      Text(this.titleText)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.pal().textPrimary)
        .width('100%')

      Text('两种模式随时可在「探索中心」重选，数据完全一致，只是联网能力不同。')
        .fontSize(12)
        .fontColor(this.pal().textTertiary)
        .lineHeight(17)
        .width('100%')

      Column({ space: 8 }) {
        this.modeRow(APP_MODE_FULL, '全量模式',
          '功能正常使用、无任何限制：可加载网络图片、使用网络备份与检查更新',
          $r('sys.symbol.checkmark_circle'))
        this.modeRow(APP_MODE_OFFLINE, '基础模式',
          '纯离线使用：应用不联网，网络图片无法加载，网络备份 / 检查更新不可用',
          $r('sys.symbol.xmark_circle'))
      }
      .width('100%')
      .margin({ top: 2 })
    }
    .width('82%')
    .padding(20)
    .borderRadius(16)
    .backgroundColor(this.cardBg())
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: HwSpace.xs })
  }
}
