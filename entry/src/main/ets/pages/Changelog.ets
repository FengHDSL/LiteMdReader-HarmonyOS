/**
 * 澄笺 · 设置 · 更新日志
 * =====================
 *
 * 从探索中心的「更新日志」进入。内容直接维护在下面的 CHANGELOG 常量里，
 * **发新版本时在数组头部加一条**即可（version / date / items 三段式）。
 */

import { NavLifecycle } from '../service/NavLifecycle';
import { ImmersiveCard } from '../material/ImmersiveCard';
import { SettingsShell } from './SettingsShell';
import {
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  paletteFor
} from '../theme/DesignTokens';

/** 一条更新记录 */
interface ChangelogEntry {
  version: string;
  date: string;
  items: string[];
}

/**
 * 更新日志（**新的在上面**）。内容按实际发布情况增删。
 */
const CHANGELOG: ChangelogEntry[] = [
  {
    version: 'v1.0.2',
    date: '2026-10-01',
    items: [
      '修复文件锁无法使用的问题',
      '修复灰体文本配置错误的问题',
      '书架页底部悬浮栏新增快捷新建 / 导入文档的功能',
      '阅读页支持把标签栏移到底部悬浮栏（展开时在栏上方、收起时缩进栏内）',
      '修复书架打开文件夹后不自动滚动到面板位置的问题',
      '修复深色模式跟随系统切换后页面不立即完全刷新的问题',
      '修复了一些已知问题'
    ]
  },
  {
    version: 'v1.0.1',
    date: '2026-10-01',
    items: [
      '新增「检查更新」：在探索中心一键查询 HAP 资源站上的最新版本',
      '修复平板 / 大屏横屏下切换隐私政策与用户协议无响应的问题',
      '完善隐私政策与用户协议正文，并统一日期格式为年月日',
      '书架的两篇内置教程现在也支持长按拖动：可合并成文件夹或收进文件夹',
      '修复文件夹收起时底部提示文本二次上移的动画跳动',
      '修复了一些已知问题'
    ]
  },
  {
    version: 'v1.0.0',
    date: '2026-09-30',
    items: [
      '首个版本完成开发'
    ]
  }
];

@Component
export struct Changelog {
  /** 导航栈：返回探索中心 */
  stack: NavPathStack | null = null;
  /** 生命周期转发 */
  life: NavLifecycle = new NavLifecycle();
  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 外观刷新计数：主题色 / 灰字 / 沾色改动后由它触发重算 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;

  private palette(): ReaderPalette {
    // 读一下外观刷新计数，主题色 / 灰字 / 沾色改完**当帧**就能重算
    const tick: number = this.appearanceTick;
    return paletteFor(this.themeMode, this.systemDark);
  }

  build() {
    SettingsShell({
      shellTitle: '更新日志',
      shellSubtitle: '每个版本做了什么，都在这里',
      stack: this.stack,
      life: this.life
    }) {
      ForEach(CHANGELOG, (entry: ChangelogEntry) => {
        ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
          Column({ space: HwSpace.sm }) {
            Row({ space: HwSpace.sm }) {
              Text(entry.version)
                .fontSize(HwType.label + 2)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.palette().accent)
              Text(entry.date)
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            ForEach(entry.items, (item: string) => {
              Row({ space: HwSpace.xs }) {
                Column()
                  .width(4)
                  .height(4)
                  .borderRadius(2)
                  .backgroundColor(this.palette().accent)
                  .margin({ top: 7 })
                Text(item)
                  .fontSize(HwType.label)
                  .fontColor(this.palette().textSecondary)
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
