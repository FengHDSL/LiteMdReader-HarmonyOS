/**
 * 澄笺 · 设置 · 更新日志
 * =====================
 *
 * 从探索中心的「更新日志」进入。**数据已抽到 service/Changelog.ets**（单一事实源）：
 * 发新版本时只在那一个数组头部插一条，本页与版本更新弹窗同步生效。
 */

import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { NavLifecycle } from '../service/NavLifecycle';
import { ImmersiveCard, ImmersiveIconButton } from '../material/ImmersiveCard';
import { SettingsShell } from './SettingsShell';
import { CHANGELOG_ALL, ChangelogEntry } from '../service/Changelog';
import {
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  paletteFor,
  HwFont
} from '../theme/DesignTokens';

/**
 * 更新日志（**新的在上面**）。内容按实际发布情况增删。
 */
const CHANGELOG: ChangelogEntry[] = CHANGELOG_ALL;

@Component
export struct Changelog {
  /** 导航栈：返回探索中心 */
  stack: NavPathStack | null = null;
  /** 平板分栏嵌入模式：返回改为回探索中心板块（不退设置页） */
  @Prop embedded: boolean = false;
  /** 生命周期转发 */
  life: NavLifecycle = new NavLifecycle();
  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 外观刷新计数：主题色 / 灰字 / 沾色改动后由它触发重算 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  /** **界面字体**（外观设置 → 界面字体）：本页界面文字都从这里取 */
  @StorageProp('appFontFamily') uiFontKey: string = '';

  private palette(): ReaderPalette {
    // 三个来源都要显式读一遍落成局部常量：paletteFor 是纯函数读 AppStorage、
    // 不登记依赖，这里不登记的话主题切换会被 ArkUI 跳过重算（文字变黑、退出重进才恢复）
    const tick: number = this.appearanceTick;
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  /** 格式化更新日志为纯文本，复制到剪贴板。 */
  private copyEntry(entry: ChangelogEntry): void {
    let text: string = `${entry.version} - ${entry.date}\n`;
    for (let k = 0; k < entry.items.length; k++) {
      text += `• ${entry.items[k]}\n`;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(
        pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        try {
          this.getUIContext().getPromptAction().showToast({
            message: '已复制更新日志',
            duration: 1500
          });
        } catch (_) {}
      }).catch((err: BusinessError) => {
        try {
          this.getUIContext().getPromptAction().showToast({
            message: '复制失败',
            duration: 1500
          });
        } catch (_) {}
      });
    } catch (_) {}
  }

  /** 条目类型着色（用户要求）：新增=深绿、优化=蓝、修复=深黄、移除=深红；深浅色各自保证对比度 */
  private itemColor(item: string): string {
    const dark: boolean = this.isDark();
    if (item.startsWith('新增')) {
      return dark ? '#FF7ED957' : '#FF1B7A3D';
    }
    if (item.startsWith('优化')) {
      return dark ? '#FF6FB7FF' : '#FF1565C0';
    }
    if (item.startsWith('修复')) {
      return dark ? '#FFFFD54F' : '#FF9A6B00';
    }
    if (item.startsWith('移除')) {
      return dark ? '#FFFF8A80' : '#FFB3261E';
    }
    return this.palette().textSecondary;
  }

  private isDark(): boolean {
    // 深色判定：跟随主题设置与系统深色（与 paletteFor 同口径）
    if (this.themeMode === ReaderThemeMode.System) {
      return this.systemDark;
    }
    return this.themeMode === ReaderThemeMode.Dark;
  }

  build() {
    SettingsShell({
      shellTitle: '更新日志',
      shellSubtitle: '每个版本做了什么，都在这里',
      stack: this.stack,
      life: this.life,
      onBack: (): boolean => {
        // 分栏嵌入：返回到探索中心（而不是退出设置页 —— 用户要求）
        if (this.embedded) {
          AppStorage.setOrCreate('settingsInlineSection', 'pages/SettingsExplore');
          return true;
        }
        return false;
      }
    }) {
      ForEach(CHANGELOG, (entry: ChangelogEntry) => {
        ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
          Column({ space: HwSpace.sm }) {
            Row() {
              Row({ space: HwSpace.sm }) {
                Text(entry.version)
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwType.label + 2)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.palette().accent)
                Text(entry.date)
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwType.caption)
                  .fontColor(this.palette().textTertiary)
              }

              ImmersiveIconButton({
                buttonSize: 30,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => { this.copyEntry(entry); }
              }) {
                SymbolGlyph($r('sys.symbol.doc_plaintext'))
                  .fontSize(18)
                  .fontColor([this.palette().textSecondary])
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .justifyContent(FlexAlign.SpaceBetween)

            ForEach(entry.items, (item: string) => {
              Row({ space: HwSpace.xs }) {
                Column()
                  .width(4)
                  .height(4)
                  .borderRadius(2)
                  .backgroundColor(this.itemColor(item))
                  .margin({ top: 7 })
                Text(item)
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwType.label)
                  .fontColor(this.itemColor(item))
                  .lineHeight(HwType.label * 1.7)
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }, (item: string) => entry.version + item)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }, (entry: ChangelogEntry) => entry.version)
    }
  }
}
