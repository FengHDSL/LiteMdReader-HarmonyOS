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
 *   · 顶栏与状态条是**悬浮材质胶囊**（ImmersiveBar，与书架 / 阅读页同一套承载层，
 *     吃沉浸光感），Web 铺满整页 → 滚动时正文穿到胶囊下层；
 *   · 状态文字浮在 Web 之上 —— 任何阶段（准备 / 渲染 / 出错）用户都能看到，
 *     不会出现"白屏无信息"；就绪前胶囊里带 LoadingProgress 转圈；
 *   · 打印前注入 JS 轮询探测图表渲染完成，未完成时打印不可点。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { PrintService } from '../service/PrintService';
import { HwSpace, HwType, HwBar, ReaderPalette, LIGHT_PALETTE, paletteFor } from '../theme/DesignTokens';
import { ImmersiveBar, ImmersiveChip, ImmersiveIconButton } from '../material/ImmersiveCard';
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

  @State failed: boolean = false;
  @State loadedPath: string = '';
  /** 顶部安全区（像素）：顶栏避让系统状态栏 */
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  @StorageProp('systemDark') systemDark: boolean = false;
  @StorageProp('readerThemeMode') themeMode: number = 0;
  /**
   * 外观刷新计数。**必须显式读它**：paletteFor 是纯函数、内部读 AppStorage 不登记依赖，
   * 不读这个 tick 的话切深浅会被 ArkUI 跳过重算 —— 顶栏胶囊的文字色就停在旧主题上
   *（用户实测"切深色浅色，顶栏悬浮胶囊没有立即切换"；阅读页同一坑见 Reader.palette()）。
   */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  /** 待打印 HTML 内容（loadData 直接注入，规避沙箱 file URI 不被 Web 接受的问题） */
  private pendingHtml: string = '';
  private started: boolean = false;
  private pendingLoad: boolean = false;

  private palette(): ReaderPalette {
    // 三个来源都要显式读一遍落成局部常量：不登记依赖的话主题切换会被 ArkUI 跳过重算
    //（与 Reader.palette() 同一条教训）
    const tick: number = this.appearanceTick;
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
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

  /** 悬浮胶囊底边到屏幕顶的距离（vp），由 onAreaChange 实测回填 */
  private barInset: number = 0;

  /**
   * **把正文初始位置推到悬浮胶囊下方**（用户要求：别一进来就被胶囊压住；往上滑
   * 仍然可以走到胶囊底层）。
   *
   * 只改**活页面**的样式，不碰沙箱里那份 HTML —— 另存出去的那份保持原样；
   * `@media print` 里再归零，纸上不会多出这条空白。留白加在 body 上（不是 Web
   * 组件的 padding）：组件加 padding 会让文档永远到不了胶囊底下，正是要避免的。
   */
  private applyTopInset(): void {
    if (this.loadedPath.length === 0 || this.barInset <= 0) {
      return;
    }
    const v: number = Math.round(this.barInset + 8);
    const js: string = '(function(){var s=document.getElementById("hwTopInset");'
      + 'if(!s){s=document.createElement("style");s.id="hwTopInset";document.head.appendChild(s);}'
      + 's.textContent="body{padding-top:' + v + 'px !important}'
      + '@media print{body{padding-top:0 !important}}";})()';
    try {
      this.controller.runJavaScript(js, (err: BusinessError, result: string) => {
        // 注入失败无副作用：正文只是被胶囊压住一点，滚动就能看到
      });
    } catch (err) {
      // 控制器未 attach / 页面已切走：下一次 onAreaChange 或 onPageEnd 会再试
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
          this.status = '已就绪。若白屏或无法滑动，请退出重新选择打印';
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
      this.status = '已就绪。若白屏或无法滑动，请退出重新选择打印';
    }
  }

  /** ③ 系统打印组件（打印预览由系统提供）。 */
  /** 打印页点击图表/公式 → 找快照打开裁切（无快照的现场渲染图提示不支持） */
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
    // **悬浮胶囊顶栏**（用户要求）：Web 铺满整页，顶栏与状态条浮在它上面，
    // 滚动时正文可以一直穿到顶栏下层。上一版是 Column 上下分栏，顶栏那条
    // 28vp 是**占位**的 —— 内容被压在下面，看着就像被顶栏"切掉了一截"。
    Stack({ alignContent: Alignment.Top }) {
      // **加载态底色：纯白 / 纯黑按深浅走**（用户 2026-10-17 拍板，不要再透渐变）。
      // Web 在内容画出来之前露的就是这块底色 —— 浅色下纯白、深色下纯黑，最简单直白。
      Web({ src: 'about:blank', controller: this.controller })
        .width('100%')
        .height('100%')
        .backgroundColor(this.systemDark ? '#FF000000' : '#FFFFFFFF')
        .javaScriptAccess(true)
        .fileAccess(true)
        .domStorageAccess(true)
        /**
         * **关掉深色强制反色**（陈年"滑不动/卡死"的头号嫌疑）：导出页是白底长文档，
         * 系统开深色时 ArkWeb 可能对整页做 force dark 重绘 —— 几十张高清 base64 图的
         * 长页面被重新着色一遍，滚动就直接冻住，只有重新加载才好（用户实测）。
         * 页面自带浅色样式，本来也不需要内核反色。
         */
        .darkMode(WebDarkMode.Off)
        .forceDarkAccess(false)
        .onPageEnd(() => {
          if (this.started && !this.failed) {
            this.probeRendered(0);
            this.applyTopInset();
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
          this.status = '已就绪。若白屏或无法滑动，请退出重新选择打印';
        })

      Column({ space: HwSpace.xs }) {
        // ── 顶栏：与书架 / 阅读页同一枚材质胶囊（ImmersiveBar 承载沉浸光感）──
        ImmersiveBar({
          palette: this.palette(),
          barPaddingH: HwSpace.sm,
          barPaddingV: 4,
          barHeight: HwBar.pill
        }) {
          Row({ space: HwSpace.xs }) {
          // 返回：圆形材质按钮（36 装进 52-8=44 的内高，与书架顶栏同尺寸）
          ImmersiveIconButton({
            buttonSize: 36,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              if (this.stack !== null) {
                this.stack.pop();
              }
            }
          }) {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(18)
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

          // 刷新：网页卡死/无法滑动时点一下重新载入
          ImmersiveIconButton({
            buttonSize: 36,
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
              .fontSize(18)
              .fontColor([this.loadedPath.length > 0 && !this.printing
                ? this.palette().accent : this.palette().textTertiary])
          }

          // 打印：未就绪时置灰不可点，就绪后高亮
          ImmersiveIconButton({
            buttonSize: 36,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              this.doPrint();
            }
          }) {
            SymbolGlyph($r('sys.symbol.printer'))
              .fontSize(18)
              .fontColor([this.ready && !this.printing
                ? this.palette().accent : this.palette().textTertiary])
          }
          }
          .width('100%')
        }

        // ── 状态胶囊：同一套材质（自动高，状态文字换两行不会被切）──
        ImmersiveBar({
          palette: this.palette(),
          barPaddingH: HwSpace.md,
          barPaddingV: 6
        }) {
          Row({ space: HwSpace.xs }) {
            if (!this.ready || this.printing) {
              LoadingProgress()
                .width(14)
                .height(14)
                .color(this.failed ? '#FFD93B3B' : this.palette().accent)
            }
            Text(this.status)
              .fontSize(12)
              .fontColor(this.failed ? '#FFD93B3B' : this.palette().textSecondary)
              .maxLines(2)
              .textAlign(TextAlign.Center)
          }
        }
      }
      .width('100%')
      .padding({
        left: HwSpace.lg,
        right: HwSpace.lg,
        top: this.topPad(),
        bottom: HwSpace.xs
      })
      .alignItems(HorizontalAlign.Center)
      // 换 key 强制整层重挂：材质承载层自己也会按深浅换 key，但**文字色/降级磨砂**
      // 走的是 @Prop palette，主题切换时不重建就停在旧配色上（与阅读页
      // 'readerTopLayer_' 同一条做法）
      .key('htmlViewerBar_' + this.appearanceTick + '_l' + this.languageTick)
      // 胶囊本身不吃触摸：顶栏两侧与两条胶囊之间的空隙，触摸要落到下层 Web 上
      //（HitTestMode.None = 自身不响应，但**不阻止子节点**命中 —— 按钮照常可点）
      .hitTestBehavior(HitTestMode.None)
      // 实测胶囊底边 → 正文初始位置留白（见 applyTopInset）
      .onAreaChange((_o: Area, n: Area) => {
        const bottom: number = Number(n.globalPosition.y) + Number(n.height);
        if (bottom > 0 && !isNaN(bottom) && Math.abs(bottom - this.barInset) > 2) {
          this.barInset = bottom;
          this.applyTopInset();
        }
      })
    }
    .width('100%')
    .height('100%')
    // 阅读页同款纸面渐变（加载 / 白屏期间露出来的就是它，不再是纯白纯黑）
    .linearGradient({
      angle: 180,
      colors: [[this.palette().pageTop, 0], [this.palette().pageBottom, 1]]
    })
  }
}
