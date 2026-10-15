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
import { ImageCropOverlay } from '../components/ImageCropOverlay';
import { MdParser } from '../markdown/MdParser';
import { MdBlock, MdBlockKind } from '../markdown/MdTypes';
import { ChartCache } from '../service/ChartCache';
import { fileIo as fs } from '@kit.CoreFileKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { PrintService } from '../service/PrintService';
import { HwSpace, HwType, ReaderPalette, LIGHT_PALETTE, paletteFor, isDarkTheme } from '../theme/DesignTokens';
import { ImmersiveChip, ImmersiveIconButton } from '../material/ImmersiveCard';
import { L10n } from '../service/L10n';

@Component
export struct HtmlViewer {
  stack: NavPathStack | null = null;
  @Prop docName: string = '';
  @Prop content: string = '';
  /** 直接打开的 HTML 文件绝对路径（为空时用 docName + content 现导出） */
  @Prop htmlPath: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  @State status: string = '准备中…';
  /** 语言切换计数：变更时整页重建（key 拼接），文案随词典刷新 */
  @StorageProp('languageTick') languageTick: number = 0;
  @State ready: boolean = false;
  @State printing: boolean = false;
  /** 图表/公式点击 → 裁切（打印页）：当前裁切快照路径与块序号 */
  @State cropImagePath: string = '';
  @State cropBi: number = -1;
  private parsedBlocks: MdBlock[] = [];
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
      this.parsedBlocks = MdParser.parse(this.content).blocks;
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
   * 加载 HTML：**file:// 直接加载落盘文件**（主路径）。
   * 之前主路径是 base64 loadData——大文档（内联渲染库 + 内嵌快照图，10MB+）会被
   * 复制成一份 16MB 字符串一次性灌进 ArkWeb，手机上直接白屏（用户实测：图表越多
   * 越必现）。落盘文件用 file:// 加载没有大小上限，白屏即消失；
   * file:// 打开失败（异常）才退回 base64 loadData 兜底。
   */
  private loadHtml(): void {
    try {
      if (this.loadedPath.length > 0) {
        this.controller.loadUrl('file://' + this.loadedPath);
        return;
      }
    } catch (err) {
      // 落盘路径加载失败 → 回退 loadData
    }
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
          this.status = '已就绪，可打印。若白屏或无法滑动，请退出重新选择打印';
        } else if (attempt >= 12) {
          this.ready = true;
          this.status = '已就绪（部分图表可能未渲染完）。若白屏或无法滑动，请退出重新选择打印';
        } else {
          this.status = '图表渲染中…';
          setTimeout(() => {
            this.probeRendered(attempt + 1);
          }, 700);
        }
      });
    } catch (err) {
      this.ready = true;
      this.status = '已就绪，可打印。若白屏或无法滑动，请退出重新选择打印';
    }
  }

  /** ③ 系统打印组件（打印预览由系统提供）。 */
  /** 打印页点击图表/公式 → 找快照打开裁切（无快照的现场渲染图提示不支持） */
  private onChartClick(bi: number): void {
    if (bi < 0 || bi >= this.parsedBlocks.length || this.cropImagePath.length > 0) {
      return;
    }
    const b: MdBlock = this.parsedBlocks[bi];
    const c: common.UIAbilityContext | null =
      getContext(this) as common.UIAbilityContext;
    if (c === null) {
      return;
    }
    let mode: string = '';
    let payload: string = '';
    if (b.kind === MdBlockKind.Chart) {
      mode = b.lang.trim().toLowerCase();
      payload = b.code;
    } else if (b.kind === MdBlockKind.Math) {
      mode = 'katex';
      payload = b.code;
    } else {
      return;
    }
    const key: string = ChartCache.payloadKey(c, mode, payload, false);
    let path: string = key.length > 0 ? ChartCache.srcPath(c, key) : '';
    if (path.length === 0) {
      const key2: string = ChartCache.payloadKey(c, mode, payload, true);
      path = key2.length > 0 ? ChartCache.srcPath(c, key2) : '';
    }
    if (path.length === 0) {
      this.status = '该图为现场渲染（无快照），裁切请回到阅读页操作';
      return;
    }
    this.cropBi = bi;
    this.cropImagePath = path;
  }

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
        this.docName.length > 0 ? this.docName : L10n.t('澄笺文档'));
      this.status = '已交给系统打印';
    } catch (err) {
      const e = err as BusinessError;
      this.status = '打印失败：' + (e.message !== undefined ? e.message : L10n.t('未知错误'));
    }
    this.printing = false;
  }

  build() {
    Column() {
      // ── 顶栏：沉浸光感胶囊按钮，顶部避让系统状态栏 ──
      Row({ space: HwSpace.sm }) {
        // 返回：**圆形按钮**（用户要求：顶部三钮改圆形，只留图标）
        ImmersiveIconButton({
          buttonSize: 30,
          buttonRadius: 15,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            if (this.stack !== null) {
              this.stack.pop();
            }
          }
        }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(15)
            .fontColor([this.palette().textPrimary])
        }

        Text(this.docName.length > 0 ? this.docName : L10n.t('网页预览'))
          .fontSize(HwType.label)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.palette().textPrimary)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          // 文档名过长 → 自动缓慢滚动（用户要求），不再截断省略
          .textOverflow({ overflow: TextOverflow.MARQUEE })

        // 刷新：胶囊（用户要求，打印左边）——网页卡死/无法滑动时点一下重新载入
        ImmersiveIconButton({
          buttonSize: 30,
          buttonRadius: 15,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            if (this.loadedPath.length === 0 || this.printing) {
              return;
            }
            this.status = '正在重新载入…';
            this.loadHtml();
          }
        }) {
          SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
            .fontSize(15)
            .fontColor([this.loadedPath.length > 0 && !this.printing
              ? this.palette().accent : this.palette().textTertiary])
        }

        // 打印：胶囊；未就绪时置灰不可点，就绪后高亮
        ImmersiveIconButton({
          buttonSize: 30,
          buttonRadius: 15,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
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
          .javaScriptProxy({
            object: {
              chartClick: (bi: number) => {
                this.onChartClick(bi);
              }
            },
            name: 'arkHost',
            methodList: ['chartClick'],
            controller: this.controller
          })
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
            // ⚠️ 不再整页判失败（用户实测：提示加载出错但页面实际正常渲染——
            // file:// 大页面会触发子资源类的加载错误回调，favicon 之类 404 也算）。
            // 就绪提示里已有白屏兜底话术，这里只做软提示。
            this.status = '已就绪，可打印。若白屏或无法滑动，请退出重新选择打印';
          })
        if (this.cropImagePath.length > 0) {
          ImageCropOverlay({
            imagePath: this.cropImagePath,
            onConfirm: () => {
              // 快照已原地替换：把裁切结果回写到页面里对应图（base64 交换，免整页刷新）
              try {
                const file: fs.File = fs.openSync(this.cropImagePath, fs.OpenMode.READ_ONLY);
                let dataUrl: string = '';
                try {
                  const stat: fs.Stat = fs.statSync(this.cropImagePath);
                  const buf: ArrayBuffer = new ArrayBuffer(stat.size);
                  const n: number = fs.readSync(file.fd, buf);
                  if (n > 0) {
                    dataUrl = 'data:image/png;base64,' + new util.Base64Helper()
                      .encodeToStringSync(new Uint8Array(buf, 0, n));
                  }
                } finally {
                  try {
                    fs.closeSync(file);
                  } catch (ce) {
                  }
                }
                if (dataUrl.length > 0) {
                  this.controller.runJavaScript('window.__setChartImg(' + this.cropBi
                    + ', "' + dataUrl + '")');
                }
              } catch (err) {
              }
              this.status = '已裁切';
              this.cropImagePath = '';
            },
            onCancel: () => {
              this.cropImagePath = '';
            }
          })
            .position({ x: 0, y: 0 })
        }

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
