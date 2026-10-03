/**
 * 澄笺 · Web 阅读器（导出 HTML → 打开 → 系统打印）
 * ============================================================
 *
 * 用户指定流程：
 *   点「打印」→ ① 先把文档**导出成 HTML 文件**（写 cache）→
 *   ② **Web 阅读器打开这个文件** → ③ 页面（含图表）渲染完成后再走
 *   **系统打印组件**（createWebPrintDocumentAdapter + print.print）。
 *
 * 实现要点：
 *   · 只用最基础的 ArkUI 组件（Column/Row/Text/Stack/Web），避免自定义
 *     承载层/图标组件带来的构建期风险；
 *   · 状态文字浮在 Web 之上 —— 任何阶段（准备 / 渲染 / 出错）用户都能看到，
 *     不会出现"白屏无信息"；
 *   · 打印前注入 JS 轮询探测图表渲染完成，未完成时打印不可点。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { PrintService } from '../service/PrintService';
import { HwSpace, HwType, ReaderPalette, LIGHT_PALETTE, paletteFor, isDarkTheme } from '../theme/DesignTokens';
import { ImmersiveChip } from '../material/ImmersiveCard';

@Component
export struct HtmlViewer {
  stack: NavPathStack | null = null;
  @Prop docName: string = '';
  @Prop content: string = '';
  /** 直接打开的 HTML 文件绝对路径（为空时用 docName + content 现导出） */
  @Prop htmlPath: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  @State status: string = '准备中…';
  @State ready: boolean = false;
  @State printing: boolean = false;
  @State failed: boolean = false;
  @State loadedPath: string = '';
  /** 顶部安全区（像素）：顶栏避让系统状态栏 */
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  @StorageProp('systemDark') systemDark: boolean = false;
  @StorageProp('readerThemeMode') themeMode: number = 0;
  /** 待打印 HTML 内容（loadData 直接注入，规避沙箱 file URI 不被 Web 接受的问题） */
  private pendingHtml: string = '';
  private started: boolean = false;
  private pendingLoad: boolean = false;

  private isDark(): boolean {
    return isDarkTheme(this.themeMode, this.systemDark);
  }

  private palette(): ReaderPalette {
    return paletteFor(this.themeMode, this.systemDark);
  }

  /** 顶栏顶部内边距：系统状态栏高度 + 一点呼吸（与全应用口径一致） */
  private topPad(): number {
    return this.getUIContext().px2vp(this.safeTopPx) + HwSpace.xs;
  }

  aboutToAppear(): void {
    // 先让界面（含状态文字）渲染出来，再开始耗时准备
    this.status = '正在导出 HTML…';
    setTimeout(() => {
      this.prepare();
    }, 80);
  }

  /** ① 导出 HTML 到 cache；② 交给 Web 阅读器打开。 */
  private async prepare(): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    let ctx: common.UIAbilityContext | null = null;
    try {
      ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    } catch (err) {
      ctx = null;
    }
    if (ctx === null) {
      this.failed = true;
      this.status = '无法获取应用上下文';
      return;
    }
    try {
      if (this.htmlPath.length > 0) {
        // 直接打开已有 HTML 文件：读文本注入
        this.pendingHtml = fs.readTextSync(this.htmlPath, { encoding: 'utf-8' });
        this.loadedPath = this.htmlPath;
      } else {
        const html: string =
          await PrintService.buildPrintHtml(ctx, this.docName, this.content,
            (m: string) => {
              this.status = m;
            });
        this.pendingHtml = html;
        // 仍落一份 HTML 文件（用户要求"先导出成 HTML"，也便于排查）
        this.loadedPath = await PrintService.writePrintHtml(ctx, this.docName, html);
      }
      if (this.pendingHtml.length === 0) {
        this.failed = true;
        this.status = 'HTML 内容为空';
        return;
      }
      this.status = '正在打开网页…';
      if (this.pendingLoad) {
        this.loadHtml();
      }
    } catch (err) {
      this.failed = true;
      this.status = '导出 HTML 失败：' + (err as Error).message;
    }
  }

  /**
   * 加载 HTML：**base64 loadData 注入**（主路径）—— Web 组件不接受
   * `fileUri.getUriFromPath` 生成的沙箱 URI（报 Invalid resource path or file type），
   * 直接注入内容最可靠；失败再退回 file:// 绝对路径。
   */
  private loadHtml(): void {
    try {
      const bytes: Uint8Array = new util.TextEncoder().encodeInto(this.pendingHtml);
      const b64: string = new util.Base64Helper().encodeToStringSync(bytes);
      this.controller.loadData(b64, 'text/html', 'base64');
    } catch (err) {
      // 回退：file:// 绝对路径
      try {
        this.controller.loadUrl('file://' + this.loadedPath);
      } catch (err2) {
        this.failed = true;
        this.status = '打开失败：' + (err2 as Error).message;
      }
    }
  }

  /** 探测页面内图表是否全部渲染完成（未渲染完打印会缺组件）。 */
  private probeRendered(attempt: number): void {
    if (this.ready || this.failed) {
      return;
    }
    const script: string = '(function(){'
      + 'var boxes=document.querySelectorAll(".markmap,.mermaid,.ktx,.ech,.gv,.abc");'
      + 'var done=document.querySelectorAll(".markmap svg,.mermaid svg,.ktx svg,.ech canvas,.gv svg,.abc svg");'
      + 'return boxes.length + "|" + done.length;})()';
    try {
      this.controller.runJavaScript(script, (err: BusinessError, result: string) => {
        let allDone: boolean = false;
        if (err === undefined && result !== undefined && result.length > 0) {
          const parts: string[] = result.split('|');
          if (parts.length === 2) {
            const total: number = Number.parseInt(parts[0], 10);
            const fin: number = Number.parseInt(parts[1], 10);
            allDone = Number.isNaN(total) || total === 0 || fin >= total;
          }
        }
        if (allDone) {
          this.ready = true;
          this.status = '已就绪，可打印';
        } else if (attempt >= 12) {
          this.ready = true;
          this.status = '已就绪（部分图表可能未渲染完）';
        } else {
          this.status = '图表渲染中…';
          setTimeout(() => {
            this.probeRendered(attempt + 1);
          }, 700);
        }
      });
    } catch (err) {
      this.ready = true;
      this.status = '已就绪，可打印';
    }
  }

  /** ③ 系统打印组件（打印预览由系统提供）。 */
  private async doPrint(): Promise<void> {
    if (this.printing || !this.ready) {
      return;
    }
    this.printing = true;
    this.status = '正在调起系统打印…';
    let ctx: common.UIAbilityContext | null = null;
    try {
      ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    } catch (err) {
      ctx = null;
    }
    if (ctx === null) {
      this.printing = false;
      this.status = '无法获取应用上下文';
      return;
    }
    try {
      await PrintService.printWithWeb(ctx, this.controller,
        this.docName.length > 0 ? this.docName : '澄笺文档');
      this.status = '已交给系统打印';
    } catch (err) {
      const e = err as BusinessError;
      this.status = '打印失败：' + (e.message !== undefined ? e.message : '未知错误');
    }
    this.printing = false;
  }

  build() {
    Column() {
      // ── 顶栏：沉浸光感胶囊按钮，顶部避让系统状态栏 ──
      Row({ space: HwSpace.sm }) {
        // 返回：胶囊（沉浸光感材质由 ImmersiveChip 承载）
        ImmersiveChip({
          chipPaddingH: HwSpace.sm + 2,
          chipPaddingV: 7,
          palette: this.palette(),
          chipLabel: '返回',
          chipOnTap: () => {
            if (this.stack !== null) {
              this.stack.pop();
            }
          }
        }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(15)
            .fontColor([this.palette().textPrimary])
        }

        Text(this.docName.length > 0 ? this.docName : '网页预览')
          .fontSize(HwType.label)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.palette().textPrimary)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 打印：胶囊；未就绪时置灰不可点，就绪后高亮
        ImmersiveChip({
          chipPaddingH: HwSpace.sm + 2,
          chipPaddingV: 7,
          chipActive: this.ready && !this.printing,
          palette: this.palette(),
          chipLabel: this.printing ? '调起中' : '打印',
          chipOnTap: () => {
            this.doPrint();
          }
        }) {
          SymbolGlyph($r('sys.symbol.printer'))
            .fontSize(15)
            .fontColor([this.ready && !this.printing
              ? this.palette().accent : this.palette().textTertiary])
        }
      }
      .width('100%')
      .padding({
        left: HwSpace.md,
        right: HwSpace.md,
        top: this.topPad(),
        bottom: HwSpace.xs
      })

      // ── 主体：Web 阅读器 + 状态浮层（状态永远可见，不会白屏无信息）──
      Stack({ alignContent: Alignment.Top }) {
        Web({ src: 'about:blank', controller: this.controller })
          .width('100%')
          .height('100%')
          .backgroundColor('#FFFFFFFF')
          .javaScriptAccess(true)
          .fileAccess(true)
          .domStorageAccess(true)
          .onPageEnd(() => {
            if (this.started && !this.failed) {
              this.probeRendered(0);
            }
          })
          .onControllerAttached(() => {
            if (this.loadedPath.length > 0) {
              this.loadHtml();
            } else {
              this.pendingLoad = true;
            }
          })
          .onErrorReceive(() => {
            this.failed = true;
            this.status = '网页加载出错';
          })

        // 状态条：浮在 Web 顶部（就绪后淡出为不打扰的一行提示）
        Row() {
          Text(this.status)
            .fontSize(12)
            .fontColor(this.failed ? '#FFD93B3B' : '#FF5A6270')
            .maxLines(2)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        }
        .width('100%')
        .backgroundColor('#F2FFFFFF')
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.palette().pageBottom)
  }
}
