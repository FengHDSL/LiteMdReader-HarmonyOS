/**
 * 澄笺 · 图表渲染组件管理（HTML 导出内联用）
 * ================================================================
 *
 * **渲染库内置在应用 rawfile 里**（用户要求：不联网下载）：
 * `resources/rawfile/runtimes/*.js` 与应用一起打包，导出 HTML 时
 * 直接读出来内嵌 —— 导出文件自包含，离线打开也能渲染图表，
 * 全程无网络请求。提示语用「正在导入」。
 *
 * 库版本与 tools/runtimes/ 实测一致（Playwright 验证过渲染）。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { InlineRuntime } from '../markdown/MdToHtml';

const TAG: string = 'ChartRuntime';

export class ChartRuntimeService {
  /** 图表语言 → 所需 rawfile 文件名。 */
  static filesForLang(lang: string): string[] {
    if (lang === 'markmap') {
      return ['d3.min.js', 'markmap-lib.js', 'markmap-view.js'];
    }
    if (lang === 'mermaid') {
      return ['mermaid.min.js'];
    }
    if (lang === 'echarts') {
      return ['echarts.min.js'];
    }
    if (lang === 'katex') {
      return ['katex.min.js', 'katex.min.css'];
    }
    if (lang === 'graphviz') {
      return ['viz2.js', 'viz2-full.render.js'];
    }
    if (lang === 'flowchart') {
      return ['mermaid.min.js'];
    }
    if (lang === 'abc') {
      return ['abcjs.min.js'];
    }
    return [];
  }

  /**
   * 从 rawfile 读取所需的全部渲染库文本。
   * @return 全部成功返回 InlineRuntime 列表（由调用方内嵌进 HTML）；
   *         任一失败返回 null（调用方回退 CDN 引用模式）。
   */
  static async loadRuntimes(ctx: common.UIAbilityContext, files: string[],
                            notify: (message: string) => void): Promise<InlineRuntime[] | null> {
    const out: InlineRuntime[] = [];
    for (let k = 0; k < files.length; k++) {
      const file: string = files[k];
      notify('正在导入图表组件（' + (k + 1) + '/' + files.length + '）…');
      try {
        const data: Uint8Array =
          await ctx.resourceManager.getRawFileContent('runtimes/' + file);
        const code: string =
          util.TextDecoder.create('utf-8').decodeToString(data);
        if (code.length < 1000) {
          hilog.warn(0x0000, TAG, 'runtime too small: %{public}s', file);
          return null;
        }
        const item: InlineRuntime = {
          name: file,
          code: code,
          isCss: file.endsWith('.css')
        };
        out.push(item);
      } catch (err) {
        hilog.warn(0x0000, TAG, 'load runtime failed: %{public}s %{public}s',
          file, (err as Error).message);
        return null;
      }
    }
    return out;
  }

  /** katex 字体文件清单（内联 CSS 时把 url(fonts/xx) 替换成 data URI 用）。 */
  static katexFontFiles(): string[] {
    return [
      'KaTeX_AMS-Regular.woff2', 'KaTeX_Caligraphic-Bold.woff2', 'KaTeX_Caligraphic-Regular.woff2',
      'KaTeX_Fraktur-Bold.woff2', 'KaTeX_Fraktur-Regular.woff2', 'KaTeX_Main-Bold.woff2',
      'KaTeX_Main-BoldItalic.woff2', 'KaTeX_Main-Italic.woff2', 'KaTeX_Main-Regular.woff2',
      'KaTeX_Math-BoldItalic.woff2', 'KaTeX_Math-Italic.woff2', 'KaTeX_SansSerif-Bold.woff2',
      'KaTeX_SansSerif-Italic.woff2', 'KaTeX_SansSerif-Regular.woff2', 'KaTeX_Script-Regular.woff2',
      'KaTeX_Typewriter-Regular.woff2'
    ];
  }

  /** 读 rawfile 字体并转 data URI（woff2）。失败返回 null。 */
  static async readFontDataUri(ctx: common.UIAbilityContext, file: string): Promise<string | null> {
    try {
      const data: Uint8Array =
        await ctx.resourceManager.getRawFileContent('runtimes/fonts/' + file);
      return 'data:font/woff2;base64,' +
        new util.Base64Helper().encodeToStringSync(data);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'font load failed: %{public}s', file);
      return null;
    }
  }
}
