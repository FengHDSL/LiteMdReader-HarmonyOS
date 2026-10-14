import { L10n } from '../service/L10n';
/**
 * 澄笺 · 设置 · 引擎管理
 * ======================
 *
 * 展示各渲染引擎（版本 / 发布日期 / 开源地址 / 作用），并支持单独关闭：
 * 关闭后对应功能**无法渲染**——图表与块级公式退化为源码展示（附提示），
 * 行内公式不再生成图片（回落文字），编辑器 WYSIWYG/IR 入口停用；
 * 随时可在本页重新开启。数据为本机常量，不联网检查。
 */

import { NavLifecycle } from '../service/NavLifecycle';
import { ImmersiveCard, ImmersiveChip } from '../material/ImmersiveCard';
import { SettingsShell } from './SettingsShell';
import { EngineInfo, ENGINE_LIST, EngineRegistry } from '../service/EngineRegistry';
import { pasteboard } from '@kit.BasicServicesKit';
import { common, Want } from '@kit.AbilityKit';
import {
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  paletteFor
} from '../theme/DesignTokens';

@Component
export struct SettingsEngines {
  /** 导航栈：返回用 */
  stack: NavPathStack | null = null;
  /** 生命周期转发 */
  life: NavLifecycle = new NavLifecycle();

  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 关闭的引擎列表（逗号分隔；本页是写入方，@StorageLink 双向） */
  @StorageLink('disabledEngines') disabled: string = '';

  private palette(): ReaderPalette {
    return paletteFor(this.themeMode, this.systemDark);
  }

  private isOff(id: string): boolean {
    return EngineRegistry.isOff(id, this.disabled);
  }

  private toggle(id: string, on: boolean): void {
    // 开关包动画：行淡显 / 恢复要平滑
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.disabled = EngineRegistry.withToggled(this.disabled, id, !on);
    });
  }

  /** 一键全部启用（关闭列表清空；有引擎处于关闭态时才显示入口）。 */
  private enableAll(): void {
    const n: number = EngineRegistry.countOff(this.disabled);
    this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
      this.disabled = '';
    });
    this.getUIContext().getPromptAction().showToast({ message: L10n.t('已重新启用 ') + n + ' 个引擎' });
  }

  private copyRepo(url: string): void {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.getUIContext().getPromptAction().showToast({ message: L10n.t('仓库地址已复制') });
    } catch (err) {
      // 复制失败静默
    }
  }

  /** **跳转浏览器打开仓库**（用户要求：GitHub 地址改成按钮点击跳转）；失败回落复制。 */
  private openRepo(url: string): void {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      this.copyRepo(url);
      return;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: url
    };
    try {
      (c as common.UIAbilityContext).startAbility(want).catch(() => {
        this.copyRepo(url);
        this.getUIContext().getPromptAction().showToast({ message: L10n.t('未找到浏览器，地址已复制') });
      });
    } catch (err) {
      this.copyRepo(url);
    }
  }

  @Builder
  engineRow(info: EngineInfo) {
    Row({ space: HwSpace.sm }) {
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(info.name)
            .fontSize(HwType.label + 1)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().textPrimary)
          Text('v' + info.version)
            .fontSize(HwType.caption)
            .fontColor(this.palette().accent)
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .borderRadius(6)
            .backgroundColor(this.palette().accentSoft)
        }
        .alignItems(VerticalAlign.Center)

        // **离线库体积**（用户要求：放到名称下方独立一行）：随包内联进模板的实际占用
        Text(L10n.t('离线库 ') + info.size)
          .fontSize(HwType.caption - 1)
          .fontColor(this.palette().textSecondary)
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .borderRadius(6)
          .backgroundColor(this.palette().quoteBg)

        Text(info.desc)
          .fontSize(HwType.caption)
          .fontColor(this.palette().textSecondary)
          .lineHeight(HwType.caption * 1.5)
          .width('100%')

        Row({ space: 6 }) {
          Text(L10n.t('发布于 ') + info.date)
            .fontSize(HwType.caption - 1)
            .fontColor(this.palette().textTertiary)
          // **GitHub 胶囊按钮**（用户要求：只显示 GitHub 字样，不再带长地址）；
          // 点击跳浏览器，长按仍复制地址（地址本身照旧记在 info.repo）
          Text('GitHub')
            .fontSize(HwType.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().accent)
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            .borderRadius(HwRadius.pill)
            .backgroundColor(this.palette().accentSoft)
            .onClick(() => {
              this.openRepo(info.repo);
            })
          .gesture(LongPressGesture({ repeat: false, duration: 500 }).onAction(() => {
            this.copyRepo(info.repo);
          }))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.copyRepo(info.repo);
        })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: !this.isOff(info.id) })
        .onChange((isOn: boolean) => {
          this.toggle(info.id, isOn);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // 关闭后整行淡显（一眼看出哪些被停用）
    .opacity(this.isOff(info.id) ? 0.5 : 1)
  }

  build() {
    Column() {
      SettingsShell({
        shellTitle: L10n.t('引擎管理'),
        shellSubtitle: L10n.t('各功能使用的开源渲染引擎 · 可单独关闭'),
        stack: this.stack,
        life: this.life
      }) {
        ImmersiveCard({
          cardRadius: HwRadius.card,
          cardPadding: HwSpace.md,
          palette: this.palette()
        }) {
          Text(L10n.t('关闭某个引擎后，对应功能将无法渲染：图表与块级公式退化为源码显示，') + '行内公式不再生成图片（回落为文字），编辑器「所见即所得 / 即时渲染」入口停用。'
            + '随时可以重新开启。引擎信息为本机常量，不联网检查更新。')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textSecondary)
            .lineHeight(HwType.caption * 1.7)
            .width('100%')
        }

        // 有引擎被关闭时的快捷恢复入口（全部启用后本行淡出消失）
        if (EngineRegistry.countOff(this.disabled) > 0) {
          Row() {
            ImmersiveChip({
              chipActive: false,
              palette: this.palette(),
              chipLabel: L10n.t('全部启用（') + EngineRegistry.countOff(this.disabled) + ' 个已关闭）',
              chipOnTap: () => {
                this.enableAll();
              }
            })
          }
          .width('100%')
          .transition(TransitionEffect.OPACITY.combine(
            TransitionEffect.scale({ x: 0.92, y: 0.92 })
          ).animation({ duration: 220, curve: Curve.FastOutSlowIn }))
        }

        ForEach(ENGINE_LIST, (info: EngineInfo) => {
          ImmersiveCard({
            cardRadius: HwRadius.card,
            cardPadding: HwSpace.md,
            palette: this.palette()
          }) {
            this.engineRow(info)
          }
        }, (info: EngineInfo) => info.id)
      }
    }
    .width('100%')
    .height('100%')
  }
}
