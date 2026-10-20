import { L10n } from '../service/L10n';
import { AppearanceFx } from '../service/AppearanceFx';
/**
 * 澄笺 · 应用初始化确认弹窗（AppResetDialog）
 * ==========================================
 *
 * 「应用初始化」是**不可撤销**的危险操作（清空全部数据，效果等同卸载重装），
 * 因此除了文案警示，还加了**强制等待**：进入弹窗后确认键倒计时 5 秒才可点，
 * 期间显示剩余秒数并置灰——避免误触/连点把数据清掉（用户要求）。
 *
 * 视觉沿用项目自绘弹窗规范（同 UnsavedConfirmDialog）：宽 '82%'、实底卡片色、
 * 深浅自适应（弹窗内直接读主题两键登记依赖）。
 */
import {
  HwRadius,
  LIGHT_PALETTE,
  ReaderPalette,
  ReaderThemeMode,
  paletteFor,
  withAlpha
} from '../theme/DesignTokens';

@CustomDialog
export struct AppResetDialog {
  controller?: CustomDialogController;
  /** 取消（什么都不做） */
  onCancel: () => void = () => {
  };
  /** 倒计时结束后点「确认清除」 */
  onConfirm: () => void = () => {
  };

  @StorageProp('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 倒计时剩余秒数（>0 时确认键不可点） */
  @State left: number = 5;
  private timer: number = -1;

  /** 实际取色：按当前主题现算（显式读两键落局部常量，登记渲染依赖）。 */
  private pal(): ReaderPalette {
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  /** 卡片底：surface 自带透明度，顶满 alpha 才是「实底卡片」。 */
  private cardBg(): string {
    return withAlpha(this.pal().surface, 'FF');
  }

  aboutToAppear(): void {
    this.left = 5;
    this.timer = setInterval(() => {
      if (this.left > 0) {
        this.left = this.left - 1;
      }
      if (this.left <= 0 && this.timer !== -1) {
        clearInterval(this.timer);
        this.timer = -1;
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  build() {
    Column({ space: 12 }) {
      Text(L10n.t('应用初始化'))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFD93B3B')
        .width('100%')

      Text(L10n.t('将清空应用的全部数据：文档与文件夹、批注与手写、AI 配置与对话记录、') + '阅读设置与外观、版本历史与备份记录。')
        .fontSize(13)
        .fontColor(this.pal().textPrimary)
        .lineHeight(20)
        .width('100%')

      Text(L10n.t('效果等同于卸载后重装，且**无法恢复**，请谨慎操作。'))
        .fontSize(13)
        .fontColor('#FFD93B3B')
        .lineHeight(20)
        .width('100%')

      // 倒计时提示（每秒刷新；动画过渡避免数字硬切）
      Text(this.left > 0
        ? L10n.t('为防止误触，请等待 ') + this.left + ' 秒后再确认'
        : L10n.t('已可确认：此操作不可撤销'))
        .fontSize(HwTypeLabel())
        .fontColor(this.left > 0 ? this.pal().textTertiary : '#FFD93B3B')
        .width('100%')
        .animation(AppearanceFx.anim(200, Curve.FastOutSlowIn))

      Row({ space: 10 }) {
        Text(L10n.t('取消'))
          .fontSize(14)
          .fontColor(this.pal().textPrimary)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .border({ width: 1, color: this.pal().divider })
          .onClick(() => {
            this.onCancel();
          })

        Text(this.left > 0 ? L10n.t('确认清除（') + this.left + 's）' : L10n.t('确认清除'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFFFF')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          // 倒计时期间置灰不可点（enabled 拦截 + 视觉半透明）
          .backgroundColor('#FFD93B3B')
          .opacity(this.left > 0 ? 0.45 : 1)
          .enabled(this.left <= 0)
          .animation(AppearanceFx.anim(200, Curve.FastOutSlowIn))
          .onClick(() => {
            if (this.left <= 0) {
              this.onConfirm();
            }
          })
      }
      .width('100%')
    }
    .padding(20)
    .borderRadius(16)
    .backgroundColor(this.cardBg())
    .width('82%')
    .constraintSize({ maxWidth: 520 })
  }
}

/** 弹窗内小字号（与项目 HwType.caption 同档，这里避免多引一个常量表） */
function HwTypeLabel(): number {
  return 13;
}
