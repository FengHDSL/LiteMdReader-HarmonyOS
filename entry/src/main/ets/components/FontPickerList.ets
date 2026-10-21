/**
 * 澄笺 · 字体列表选择器（阅读正文与界面字体共用）
 * ==============================================
 *
 * 一行一款字体，**字体名与预览句都用该字体本身绘制**（所见即所得），选中项打勾 + 高亮。
 * 三段：默认 → 导入的字体（长按可删除）→ 系统已安装（系统字体管理器 INSTALLED 类型，
 * 由 `FontStore.loadInstalled()` 查列表 + 取 descriptor.fontFamily）。
 * 整块限高 260vp 可上下滑（用户装的字体可能几十款，不能把面板撑出屏幕），四角圆角裁切。
 *
 * 选择结果通过 `onPick` 交回宿主写设置键 —— 本组件不碰 AppStorage：
 * 真机上子组件自己读 AppStorage 不保证回刷（正文字体那条就是栽在这里）。
 */
import { L10n } from '../service/L10n';
import { UserFont, SystemFont, FontStore } from '../service/FontStore';
import { common } from '@kit.AbilityKit';
import {
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  LIGHT_PALETTE,
  HwFont
} from '../theme/DesignTokens';

/** 每行第二句：用该字体画一行短文，一眼看得出字形差别 */
const PREVIEW_LINE: string = '澄笺 Aa 123 · 天地之间';

@Component
export struct FontPickerList {
  /** 调色板：**必须 @Prop**，否则换肤后不更新 */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /** 当前选中的字体族（空串 = 默认） */
  @Prop chosen: string = '';
  /** 是否列「默认」这一项（阅读正文与界面字体都要，卡片等窄面板可以省） */
  @Prop showDefault: boolean = true;
  /** 导入的字体是否允许长按删除（外观页不给删，避免在两个地方做同一件危险操作） */
  @Prop allowRemove: boolean = true;
  /** 选中回调：宿主把它写进自己的设置键 */
  onPick: (key: string) => void = () => {
  };
  /** 删除回调（仅导入的字体可删；宿主没接就只是不给长按动作） */
  onRemove: (family: string) => void = () => {
  };
  /** 宿主导入 / 删除字体后把这个值自增，列表重新取一遍（否则要等下次打开面板才更新） */
  @Prop @Watch('reload') rev: number = 0;

  /** 用户导入进沙箱的字体 */
  @State userFonts: UserFont[] = [];
  /** 系统「字体安装和管理」里导入的字体（INSTALLED） */
  @State systemFonts: SystemFont[] = [];

  aboutToAppear(): void {
    this.reload();
  }

  /** 重新取两份列表（导入 / 删除后宿主可再调一次） */
  reload(): void {
    const c = this.getUIContext().getHostContext();
    if (c !== undefined && c !== null) {
      const ctx = c as common.UIAbilityContext;
      FontStore.registerAll(ctx);
      this.userFonts = FontStore.list(ctx);
    }
    // 系统已安装字体要**先注册进 ArkUI 字体管理器**，fontFamily 才解析得到
    // （直接取 descriptor.fontFamily 在真机上不生效，见 FontStore.registerInstalledAll）
    FontStore.registerInstalledAll().then(() => {
      return FontStore.loadInstalled();
    }).then((list: SystemFont[]) => {
      this.systemFonts = list;
    }).catch(() => {
      // 取不到就只留导入的那份
    });
  }

  @Builder
  row(key: string, name: string, sub: string, removable: boolean) {
    Row({ space: HwSpace.sm }) {
      Column({ space: 1 }) {
        Text(name)
          .fontSize(HwType.label + 3)
          .fontFamily(HwFont.resolve(key))
          .fontColor(this.palette.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(sub)
          .fontSize(HwType.caption)
          .fontFamily(HwFont.resolve(key))
          .fontColor(this.palette.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.chosen === key) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(18)
          .fontColor([this.palette.accent])
      }
    }
    .width('100%')
    .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 7, bottom: 7 })
    .borderRadius(HwRadius.inner)
    .backgroundColor(this.chosen === key ? this.palette.accentSoft : '#00000000')
    .onClick(() => {
      this.onPick(key);
    })
    // 手势总要挂（条件挂要写两套分支）：不可删除的行在回调里直接忽略
    .gesture(
      LongPressGesture()
        .onAction(() => {
          if (removable) {
            this.onRemove(key);
          }
        })
    )
  }

  @Builder
  groupTitle(label: string) {
    Text(label)
      .fontSize(HwType.caption)
      .fontColor(this.palette.textTertiary)
      .width('100%')
      .padding({ left: HwSpace.sm, top: 6, bottom: 2 })
  }

  build() {
    Scroll() {
      Column({ space: 2 }) {
        if (this.showDefault) {
          this.row('', L10n.t('默认'), L10n.t('系统默认字形 · ') + PREVIEW_LINE, false)
        }
        if (this.userFonts.length > 0) {
          this.groupTitle(L10n.t('导入的字体（长按可删除）'))
          ForEach(this.userFonts, (f: UserFont) => {
            this.row(f.family, f.family, PREVIEW_LINE, this.allowRemove)
          }, (f: UserFont) => f.family)
        }
        if (this.systemFonts.length > 0) {
          this.groupTitle(L10n.t('系统已安装'))
          ForEach(this.systemFonts, (f: SystemFont) => {
            this.row(f.family, f.family, f.fullName + ' · ' + PREVIEW_LINE, false)
          }, (f: SystemFont) => f.family)
        }
      }
      .width('100%')
      .padding(4)
      .alignItems(HorizontalAlign.Start)
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .width('100%')
    .constraintSize({ maxHeight: 260 })
    .borderRadius(HwRadius.inner)
    .clip(true)
    .backgroundColor(this.palette.surface)
    .border({ width: 1, color: this.palette.surfaceBorder })
  }
}
