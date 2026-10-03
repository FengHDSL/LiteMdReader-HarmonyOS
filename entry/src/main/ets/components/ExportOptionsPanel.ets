/**
 * 澄笺 · 导出面板（阅读页顶栏 / 书架格子菜单共用）
 * =====================================================
 *
 * 三个动作：导出 HTML / 导出 MD / 分享。
 * （PDF / 图片 / 打印已按用户要求移除——相关渲染链路一并删除。）
 *
 * 点击动作立即显示**加载动画**：系统「另存为」对话框（DocumentViewPicker）
 * 冷启动需要数秒，没有指示的话像卡死；busy 期间面板覆盖 LoadingProgress。
 * 收尾时机 = notify()（完成 / 失败 / 取消都会发），收到即关面板。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { ExportService } from '../service/ExportService';
import { MdToPlain } from '../markdown/MdToPlain';
import { HwRadius, HwSpace, HwType, LIGHT_PALETTE, ReaderPalette } from '../theme/DesignTokens';

@Component
export struct ExportOptionsPanel {
  /** 导出的文档名 */
  @Prop docName: string = '';
  /** 是否内置文档（正文从 rawfile 读） */
  @Prop builtin: boolean = false;
  /** 调色板：**必须 @Prop**，否则主题切换后不更新（普通成员只在创建时赋值一次） */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /** 动作完成（含取消）后收起面板的回调 */
  onClosed: () => void = () => {
  };

  @State busy: boolean = false;

  private ctx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  private notify(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1800 });
    } catch (err) {
      // 提示失败无副作用
    }
    // **通知即收尾**：完成 / 失败 / 取消都必发一条通知，收到后关面板
    if (this.busy) {
      this.busy = false;
      this.onClosed();
    }
  }

  private withBusy(action: () => void): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    action();
  }

  // ── 各动作 ──

  private doExportMd(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const content: string | null = ExportService.readContent(ctx, this.docName, this.builtin);
    if (content === null) {
      this.notify('读取正文失败');
      return;
    }
    this.withBusy(() => {
      ExportService.saveText(ctx, this.docName + '.md', content, (m: string) => {
        this.notify(m);
      });
    });
  }

  private doExportHtml(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const content: string | null = ExportService.readContent(ctx, this.docName, this.builtin);
    if (content === null) {
      this.notify('读取正文失败');
      return;
    }
    this.withBusy(() => {
      try {
        const html: string = ExportService.buildHtml(this.docName, content);
        ExportService.saveText(ctx, this.docName + '.html', html, (m: string) => {
          this.notify(m);
        });
      } catch (err) {
        this.notify('渲染 HTML 失败');
      }
    });
  }

  /** 导出纯文本 TXT：把 Markdown 语法自动剥掉（用户要求）。 */
  private doExportTxt(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const content: string | null = ExportService.readContent(ctx, this.docName, this.builtin);
    if (content === null) {
      this.notify('读取正文失败');
      return;
    }
    this.withBusy(() => {
      try {
        const text: string = MdToPlain.convert(content);
        if (text.length === 0) {
          this.notify('正文为空');
          return;
        }
        ExportService.saveText(ctx, this.docName + '.txt', text, (m: string) => {
          this.notify(m);
        });
      } catch (err) {
        this.notify('转换纯文本失败');
      }
    });
  }

  private doShare(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const content: string | null = ExportService.readContent(ctx, this.docName, this.builtin);
    if (content === null) {
      this.notify('读取正文失败');
      return;
    }
    this.withBusy(() => {
      try {
        const encoder: util.TextEncoder = new util.TextEncoder();
        const encoded: Uint8Array = encoder.encodeInto(content);
        const path: string = ExportService.bytesToCache(ctx, this.docName + '.md',
          encoded.buffer as ArrayBuffer);
        ExportService.shareFile(ctx, path, (m: string) => {
          this.notify(m);
        });
      } catch (err) {
        this.notify('分享失败');
      }
    });
  }

  /** 菜单行（与书架格子菜单同一形态：整行可点 + 右箭头）。 */
  @Builder
  exportRow(label: string, hint: string, action: () => void) {
    Row({ space: HwSpace.sm }) {
      Column({ space: 2 }) {
        Text(label)
          .fontSize(HwType.label + 1)
          .fontColor(this.palette.textPrimary)
        Text(hint)
          .fontSize(HwType.caption)
          .fontColor(this.palette.textTertiary)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([this.palette.textTertiary])
    }
    .width('100%')
    .height(52)
    .borderRadius(HwRadius.inner)
    .onClick(() => {
      action();
    })
  }

  build() {
    Stack() {
      Column({ space: HwSpace.xs }) {
        this.exportRow('导出 HTML', '自包含网页，浏览器直接打开', () => {
          this.doExportHtml();
        })
        this.exportRow('导出 MD', 'Markdown 原文', () => {
          this.doExportMd();
        })
        this.exportRow('导出 TXT', '自动转成纯文本，任何应用都能打开', () => {
          this.doExportTxt();
        })
        this.exportRow('分享', '以文本方式分享给其他应用', () => {
          this.doShare();
        })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // **加载动画**：另存为对话框冷启动要几秒，busy 期间盖在菜单上，
      // 避免"点了没反应"的错觉（用户反馈）
      if (this.busy) {
        Column({ space: HwSpace.sm }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(this.palette.accent)
          Text('正在处理，请稍候…')
            .fontSize(HwType.caption)
            .fontColor(this.palette.textTertiary)
        }
        .padding({ left: HwSpace.xl, right: HwSpace.xl, top: HwSpace.lg, bottom: HwSpace.lg })
        .borderRadius(HwRadius.card)
        .backgroundColor(this.palette.surface)
      }
    }
    .width('100%')
    // Stack 的对齐是构造参数 alignContent（默认居中），没有 alignItems 属性——
    // 加载动画覆盖层靠默认居中即可
  }
}
