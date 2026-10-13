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
 *
 * **勿与 rawfile/render/lib 混淆**：render/lib（12MB 库源）是 DiagramWeb 内联
 * 模板的**历史构建原料**，html 内联后与代码零引用，已于体积清理时剔除——
 * 恢复它只会白白增大 hap，不会影响任何功能。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { InlineRuntime, MdToHtml } from '../markdown/MdToHtml';

const TAG: string = 'ChartRuntime';

export class ChartRuntimeService {
  /** 图表语言 → 所需 rawfile 文件名。已关闭引擎返回空（导出降级为代码块，无需库）。 */
  static filesForLang(lang: string): string[] {
    // 「设置 → 引擎管理」里关闭了对应引擎 → 不读它的库。判定与 MdToHtml.export
    // 的降级逻辑同源（flowchart 借 mermaid 渲染，两者任一关闭都算关）。
    if (MdToHtml.engineOffForLang(lang)) {
      return [];
    }
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
      // mhchem 必须排在 katex 之后：它是 KaTeX 的扩展包，加载时把自己的 \ce / \pu
      // 注册到**当时已存在**的 katex 对象上（阅读页的 render/katex.html 早就内联了它，
      // 导出侧此前只带 katex，所以 `\ce{CO2 + C -> 2 CO}` 在阅读页正常、导出的网页里
      // 变成红色 "Undefined control sequence"）。
      return ['katex.min.js', 'katex.min.css', 'mhchem.min.js'];
    }
    if (lang === 'graphviz') {
      return ['viz-global.js'];
    }
    if (lang === 'flowchart') {
      return ['mermaid.min.js'];
    }
    if (lang === 'abc') {
      return ['abcjs.min.js'];
    }
    if (lang === 'wavedrom') {
      // 皮肤必须先于主库加载（主库读全局 WaveSkin，缺皮肤抛 "no skins found"）
      return ['wavedrom-skin-default.js', 'wavedrom.min.js'];
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

  /**
   * katex 字体文件清单（内联 CSS 时把 url(fonts/xx) 替换成 data URI 用）。
   * ⚠️ Size1~4 缺一不可：伸缩括号（\left\right、\big 系列）、大号运算符
   * （display 模式的 ∑/∏/∫）、超大矩阵括号全靠这四个字体拼接，
   * 缺失时括号断裂、\big 不放大（用户实测反馈）。
   */
  static katexFontFiles(): string[] {
    return [
      'KaTeX_AMS-Regular.woff2', 'KaTeX_Caligraphic-Bold.woff2', 'KaTeX_Caligraphic-Regular.woff2',
      'KaTeX_Fraktur-Bold.woff2', 'KaTeX_Fraktur-Regular.woff2', 'KaTeX_Main-Bold.woff2',
      'KaTeX_Main-BoldItalic.woff2', 'KaTeX_Main-Italic.woff2', 'KaTeX_Main-Regular.woff2',
      'KaTeX_Math-BoldItalic.woff2', 'KaTeX_Math-Italic.woff2', 'KaTeX_SansSerif-Bold.woff2',
      'KaTeX_SansSerif-Italic.woff2', 'KaTeX_SansSerif-Regular.woff2', 'KaTeX_Script-Regular.woff2',
      'KaTeX_Size1-Regular.woff2', 'KaTeX_Size2-Regular.woff2', 'KaTeX_Size3-Regular.woff2',
      'KaTeX_Size4-Regular.woff2', 'KaTeX_Typewriter-Regular.woff2'
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
