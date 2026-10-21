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
import { DocStore, PrintRoute } from '../service/DocStore';
import { HwFont, HwRadius, HwSpace, HwType, LIGHT_PALETTE, ReaderPalette } from '../theme/DesignTokens';
import { L10n } from '../service/L10n';
import { AppearanceFx } from '../service/AppearanceFx';

@Component
export struct ExportOptionsPanel {
  /** 导出的文档名 */
  @Prop docName: string = '';
  /** 是否内置文档（正文从 rawfile 读） */
  @Prop builtin: boolean = false;
  /** 调色板：**必须 @Prop**，否则主题切换后不更新（普通成员只在创建时赋值一次） */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /** **界面字体**（外观设置 → 界面字体）：组件内文字都从这里取 */
  @StorageProp('appFontFamily') uiFontKey: string = '';
  /** 界面字号缩放系数 / 界面字重相对加粗量（外观设置） */
  @StorageProp('appFontScale') uiFontScale: number = 1;
  @StorageProp('appFontWeightDelta') uiFontWeightDelta: number = 0;
  /** 动作完成（含取消）后收起面板的回调 */
  onClosed: () => void = () => {
  };
  /** 导航栈（打印入口 push 打印准备页用；未传则不显示打印项） */
  stack: NavPathStack | null = null;

  @State busy: boolean = false;
  /** 加载层上显示的那句话（过程消息会实时更新它，见 progress()） */
  @State busyText: string = '';

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

  /**
   * **过程提示**（只弹提示 + 更新加载层文字，**不收面板**）。
   *
   * 导出 HTML 现在会先等后台把图表烘成图片（可能几十秒），期间要让用户看得见
   * "还在动"。以前这些过程消息也走 notify()，第一条就把 busy 清掉、面板收起 ——
   * 加载动画跟着消失，剩下几十秒完全没反馈（用户实测"不知道有没有在加载"）。
   */
  private progress(message: string): void {
    this.busyText = message;
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1800 });
    } catch (err) {
      // 提示失败无副作用
    }
  }

  /** 异步动作统一入口：转圈开始 → 过程消息进加载层 → 结束（含异常）才收。 */
  private withBusyAsync(action: () => Promise<void>): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.busyText = L10n.t('正在处理，请稍候…');
    action().then(() => {
      this.busy = false;
      this.onClosed();
    }).catch(() => {
      this.busy = false;
      this.onClosed();
    });
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

  /**
   * HTML 导出入口（用户要求）：渲染库提前缓存到应用内、导出时内嵌进 HTML
   * （自包含、离线可渲染）；首次导出自动下载一次；下载失败回退在线模式。
   */
  private askExportHtml(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const content: string | null = ExportService.readContent(ctx, this.docName, this.builtin);
    if (content === null) {
      this.notify('读取正文失败');
      return;
    }
    this.withBusyAsync(() => ExportService.exportHtmlSmart(ctx, this.docName, content,
      (m: string) => {
        this.progress(m);
      }));
  }

  /** 打印：进入打印准备页（HTML 构建在页内完成，完成后调起系统打印预览）。 */
  private printDoc(): void {
    if (this.stack === null) {
      this.notify('当前环境不支持打印');
      return;
    }
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const content: string | null = ExportService.readContent(ctx, this.docName, this.builtin);
    if (content === null) {
      this.notify('读取正文失败');
      return;
    }
    try {
      this.stack.pushPath({
        name: 'pages/HtmlViewer',
        param: { docName: this.docName, content: content, htmlPath: '' } as PrintRoute
      }, AppearanceFx.navAnimated());
    } catch (err) {
      this.notify('无法打开打印');
    }
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
    this.withBusy(() => {
      try {
        // 非内置文档：直接分享原文件，不创建临时副本
        if (!this.builtin) {
          DocStore.init(ctx);
          const meta = DocStore.find(ctx, this.docName);
          if (meta === undefined) {
            this.notify('找不到文档');
            return;
          }
          const path: string = DocStore.docAbsolutePath(ctx, meta);
          ExportService.shareFile(ctx, path, (m: string) => {
            this.notify(m);
          });
        } else {
          // 内置文档：读取正文后写缓存再分享
          const content: string | null = ExportService.readContent(ctx, this.docName, true);
          if (content === null) {
            this.notify('读取正文失败');
            return;
          }
          const encoder: util.TextEncoder = new util.TextEncoder();
          const encoded: Uint8Array = encoder.encodeInto(content);
          const path: string = ExportService.bytesToCache(ctx, this.docName + '.md',
            encoded.buffer as ArrayBuffer);
          ExportService.shareFile(ctx, path, (m: string) => {
            this.notify(m);
          });
        }
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
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
          .fontColor(this.palette.textPrimary)
        Text(hint)
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
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
        // **图表显示兜底提示**（用户要求原文照录）：导出 / 打印的图靠阅读页后台
        // 逐张烘成图片，卡片没加载完就会退化成"要 JS 现场画的容器"，手机上有可能
        // 画不出来 —— 先把自救方法和反馈口径写在面板里。
        Row({ space: HwSpace.sm }) {
          SymbolGlyph($r('sys.symbol.info_circle'))
            .fontSize(15)
            .fontColor([this.palette.textTertiary])
          Text(L10n.t('若导出HTML与打印，图表显示不完全或不显示，请尝试回到阅读页面，'
            + '完全浏览并加载完所有卡片，若仍不行，请提供文件并反馈，等待后续适配。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette.textTertiary)
            .lineHeight(18)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .padding({ left: HwSpace.md, right: HwSpace.md, top: HwSpace.sm, bottom: HwSpace.sm })
        .borderRadius(HwRadius.inner)
        .backgroundColor(this.palette.surface)
        .margin({ bottom: HwSpace.xs })

        this.exportRow('导出 HTML', '自包含网页，浏览器直接打开', () => {
          this.askExportHtml();
        })
        this.exportRow('打印', '调起系统打印，图表自动渲染', () => {
          this.printDoc();
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
      // 避免"点了没反应"的错觉（用户反馈）。文字跟着过程消息走 ——
      // 导出 HTML 会先等图表烘完（可能几十秒），这行就是"还在动"的证据。
      if (this.busy) {
        Column({ space: HwSpace.sm }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(this.palette.accent)
          Text(this.busyText.length > 0 ? this.busyText : L10n.t('正在处理，请稍候…'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette.textTertiary)
            .textAlign(TextAlign.Center)
            .maxLines(3)
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
