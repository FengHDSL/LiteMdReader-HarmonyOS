/**
 * 澄笺 · 系统打印服务
 * ================================================================
 *
 * 链路（用户要求：先转换成 HTML，HTML 再使用系统打印组件打印）：
 *   文档 → rich HTML（图表渲染库内联，复用导出链路）→ 图片引用绝对化 →
 *   写 cache 文件 → WebView 加载 → `createWebPrintDocumentAdapter`
 *   调起系统打印预览（系统负责分页、预览、输出）。
 *
 * 不再使用快照+分页方式，全部交由系统打印组件处理。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { print } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DocStore } from './DocStore';
import { MdParser } from '../markdown/MdParser';
import { MdBlockKind } from '../markdown/MdTypes';
import { MdToHtml } from '../markdown/MdToHtml';
import { ChartRuntimeService } from './ChartRuntimeService';
import { InlineRuntime } from '../markdown/MdToHtml';
import { ExportService } from './ExportService';

const TAG: string = 'PrintService';

export class PrintService {
  /**
   * 构建打印用 HTML：rich 模式（图表渲染库内联）+ 图片引用绝对化
   * （HTML 会写到 cache 目录再以 file:// 加载，相对路径图片需转绝对路径）。
   */
  static async buildPrintHtml(ctx: common.UIAbilityContext, docName: string,
                              content: string,
                              notify: (message: string) => void): Promise<string> {
    const parsed = MdParser.parse(content);
    const chartCount: number = MdToHtml.countCharts(parsed.blocks);
    let inline: InlineRuntime[] | null = null;
    if (chartCount > 0) {
      const needed: string[] = [];
      for (let k = 0; k < parsed.blocks.length; k++) {
        const b = parsed.blocks[k];
        let files: string[] = [];
        if (b.kind === MdBlockKind.Chart) {
          files = ChartRuntimeService.filesForLang(b.lang.trim().toLowerCase(), b.code);
        } else if (b.kind === MdBlockKind.Math) {
          files = ChartRuntimeService.filesForLang('katex');
        }
        for (let f = 0; f < files.length; f++) {
          if (needed.indexOf(files[f]) < 0) {
            needed.push(files[f]);
          }
        }
      }
      // **全图种"等齐 + 裁剪"**（与导出同一套判定，2026-10-16 泛化自"只管 PlantUML"）：
      // 打印页要装进 ArkWeb 再交给系统打印，12MB 的页面在手机上直接空白。
      // 等齐 → 一个渲染库都不带（公式/图表全部是生成的图片）；超时 → 按缺口逐个库
      // 过筛，只有"还有缺图的图种"的库才留。
      const missing0: number = ChartRuntimeService.missingShots(ctx, parsed.blocks, false, '');
      if (missing0 > 0) {
        // 失败集重试信号：Reader 的池子清空失败集重跑一轮（见 ChartRenderPool.retryTick）
        const curRetry: number | undefined = AppStorage.get<number>('chartRetryTick');
        AppStorage.setOrCreate('chartRetryTick', (curRetry === undefined ? 0 : curRetry) + 1);
        // 等待上限 45s（原来 20s 且只管 PlantUML）：示例文档十几张图，5 秒烘不完；
        // 快照不齐就会把渲染库背进打印页（12MB 页面手机上渲染失败）。
        await ChartRuntimeService.waitShots(ctx, parsed.blocks, false, '', 45000, notify);
        for (let i = needed.length - 1; i >= 0; i--) {
          if (!ChartRuntimeService.fileStillNeeded(ctx, parsed.blocks, false, '', needed[i])) {
            needed.splice(i, 1);
          }
        }
      }
      // 用户要求：渲染库提前缓存到应用内、打印时内嵌进 HTML
      notify('正在加载图表渲染库…');
      const loaded: InlineRuntime[] | null =
        await ChartRuntimeService.loadRuntimes(ctx, needed, notify);
      if (loaded !== null) {
        // katex 字体 data URI 化
        for (let k = 0; k < loaded.length; k++) {
          if (loaded[k].name === 'katex.min.css') {
            let css: string = loaded[k].code;
            for (const font of ChartRuntimeService.katexFontFiles()) {
              const b64: string | null =
                await ChartRuntimeService.readFontDataUri(ctx, font);
              if (b64 !== null) {
                css = css.split('fonts/' + font + ')').join(b64 + ')');
              }
            }
            const fixed: InlineRuntime = {
              name: loaded[k].name, code: css, isCss: loaded[k].isCss
            };
            loaded[k] = fixed;
          }
        }
        inline = loaded;
      }
    }
    // **打印同样要内联本地图片**（用户要求：打印也要显示手写笔记 / 插图）
    // ⚠️ 这里必须把 ctx 传下去：不传 ctx，MdToHtml 查不到预渲染池烘好的快照，
    // 打印页就只能背上全部渲染库（实测 12MB+，手机上直接空白）。
    // 打印是纸上输出，深浅一律按浅色取图（pngBase64 会浅色优先、再试深色）。
    let html: string = ExportService.inlineLocalImages(ctx,
      MdToHtml.export(docName, parsed.meta, parsed.blocks, chartCount > 0, inline, ctx, false, ''));
    // 图片相对路径 → file:// 绝对路径（打印 HTML 落在 cache，引用的是 docs/images）
    const docsRoot: string = DocStore.docsRoot();
    if (docsRoot.length > 0) {
      html = html.split('src="images/').join('src="file://' + docsRoot + '/images/');
    }
    return html;
  }

  /** 将打印 HTML 写入 cache 目录，返回 file:// 可加载的绝对路径。 */
  static async writePrintHtml(ctx: common.UIAbilityContext, docName: string,
                              html: string): Promise<string> {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const encoded: Uint8Array = encoder.encodeInto(html);
    return ExportService.bytesToCacheAsync(ctx,
      docName.replace(/[^a-zA-Z0-9_-]/g, '_') + '.html',
      encoded.buffer as ArrayBuffer);
  }

  /**
   * **Web 打印适配器（官方方案）**：把 Web 组件当前渲染内容交给系统打印框架，
   * 拉起系统打印预览（系统负责分页 / 纸张 / 份数），无需转 PDF、无需截图。
   * @param jobName 打印任务名（也作为 Web 打印文档名）。
   */
  static async printWithWeb(ctx: common.UIAbilityContext,
                            controller: webview.WebviewController,
                            jobName: string): Promise<void> {
    const adapter: print.PrintDocumentAdapter =
      controller.createWebPrintDocumentAdapter(jobName + '.pdf');
    // 注：print(name, adapter, attrs, ctx) 的重载返回类型为联合（void | Promise），
    // 用 then 链拿 PrintTask（官方示例同款写法）
    const ret: Promise<print.PrintTask> =
      print.print(jobName, adapter, null, ctx) as Promise<print.PrintTask>;
    const task: print.PrintTask = await ret;
    hilog.info(0x0000, TAG, 'print preview started');
    task.on('succeed', () => {
      hilog.info(0x0000, TAG, 'print succeed');
    });
    task.on('fail', () => {
      hilog.warn(0x0000, TAG, 'print fail');
    });
    task.on('cancel', () => {
      hilog.info(0x0000, TAG, 'print cancel');
    });
  }
}
