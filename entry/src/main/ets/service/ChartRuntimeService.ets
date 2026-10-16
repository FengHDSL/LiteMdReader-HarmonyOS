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
import { MdBlock, MdBlockKind } from '../markdown/MdTypes';
import { ChartCache } from './ChartCache';

const TAG: string = 'ChartRuntime';

export class ChartRuntimeService {
  /**
   * 图表语言 → 所需 rawfile 文件名。已关闭引擎返回空（导出降级为代码块，无需库）。
   * @param src PlantUML 块的源码（只有 lang='plantuml' 时用：导出不带 5.7MB 的内核，
   *            能桥成 mermaid 的才需要 mermaid.min.js，桥不动的退化成代码块）
   */
  static filesForLang(lang: string, src: string = ''): string[] {
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
    // 三个自绘图种：导出 HTML 里内联同源的纯函数渲染库（由模板提取，勿两处改不一致）
    if (lang === 'salt') {
      return ['salt-render.js'];
    }
    if (lang === 'ditaa') {
      return ['ditaa-render.js'];
    }
    if (lang === 'nwdiag') {
      return ['nwdiag-render.js'];
    }
    if (lang === 'zenuml') {
      // zenuml 现在在解析层**转译成 mermaid 时序图**（见 ZenumlBridge），
      // 只用 mermaid 本身；6.56MB 的 zenuml.html 与 3.14MB 的插件已从包里删除。
      return ['mermaid.min.js'];
    }
    if (lang === 'plantuml') {
      // 导出带官方内核（用户拍板）：11 类只有内核画得出来，桥只能给三张图。
      // 内核没在手的那条路（CDN 回退）由 MdToHtml.hasRuntime 判定，
      // 那边会退回 PlantumlBridge / 源码，不会留一个空容器。
      // 快照图优先（MdToHtml.export 里先试 ChartCache.pngBase64），命中的话这里只是备用弹药。
      return ['plantuml-kernel.js'];
    }
    if (lang === 'echarts') {
      return ['echarts.min.js'];
    }
    if (lang === 'vega') {
      // 顺序即依赖顺序：vega-lite 的 UMD 按全局 vega 取依赖，反了会 "vega is not defined"
      return ['vega.min.js', 'vega-lite.min.js'];
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
    if (lang === 'nomnoml') {
      // 顺序即依赖顺序：nomnoml 的 UMD 按全局 graphre 取布局引擎
      return ['graphre.min.js', 'nomnoml.js'];
    }
    if (lang === 'chart') {
      return ['chart.umd.js'];
    }
    if (lang === 'wavedrom') {
      // 皮肤必须先于主库加载（主库读全局 WaveSkin，缺皮肤抛 "no skins found"）
      return ['wavedrom-skin-default.js', 'wavedrom.min.js'];
    }
    return [];
  }

  /**
   * **还差几张图没快照**（导出 / 打印"全图片化"的核心计数，2026-10-16 泛化自
   * 原来只管 PlantUML 的 kernelNeeded）。
   *
   * 导出 / 打印里每张图都优先内嵌池子烘的快照（`<img>` base64）——所有图都齐时，
   * 一个个渲染库（mermaid 3.6MB / PlantUML 内核 5.7MB / viz 1.2MB…）全都不必带，
   * 文件能掉一个数量级、打开也快（以前全带时手机浏览器直接空白）。
   *
   * 检查范围 = 导出里**会查快照的块**：
   *   · Chart 块（排除 html——导出原样输出可交互网页；排除 markmap——正文拍板
   *     实时卡、不进池子，导出保留轻量库渲染；引擎被关的排除——导出降级代码块）；
   *   · Math 公式块（katex，引擎被关的排除）。
   * 返回 0 = 所有图都有快照，导出可以**一个渲染库都不带**；大于 0 = 调用方先等
   * （waitShots），仍缺才按缺口带库。
   */
  static missingShots(ctx: common.UIAbilityContext, blocks: MdBlock[],
                      dark: boolean, bg: string): number {
    let n: number = 0;
    for (let k = 0; k < blocks.length; k++) {
      const b: MdBlock = blocks[k];
      let lang: string = '';
      if (b.kind === MdBlockKind.Chart) {
        lang = b.lang.trim().toLowerCase();
        if (lang === 'html' || lang === 'markmap') {
          continue;
        }
      } else if (b.kind === MdBlockKind.Math) {
        lang = 'katex';
      } else {
        continue;
      }
      if (MdToHtml.engineOffForLang(lang)) {
        continue;
      }
      if (!ChartCache.hasShot(ctx, lang, b.code, dark, bg)) {
        n++;
      }
    }
    return n;
  }

  /**
   * **等缺的图烘出来**（有上限；超时返回，调用方按剩余缺口决定带库）。
   * 每轮把"还差几张"报给调用方（进度提示）。池子在后台持续补烘 —— 文档开着
   * 越久缺口越小；打开就导出的大文档可能等不满，超时后按缺口带库兜底。
   */
  static async waitShots(ctx: common.UIAbilityContext, blocks: MdBlock[],
                         dark: boolean, bg: string, maxMs: number,
                         notify: (message: string) => void): Promise<void> {
    const t0: number = Date.now();
    let n: number = ChartRuntimeService.missingShots(ctx, blocks, dark, bg);
    if (n > 0) {
      // 文案改成**总数**、只报一次（用户要求："还差 N 张"读着像在倒退；而旧实现每
      // 500ms 重发一条 toast，覆盖式的 toast 看不出刷新，看着就像卡死）。
      // "有没有在加载"改由界面上的加载动画表达，不再靠刷数字。
      notify('共 ' + n + ' 张图片，请耐心等待');
    }
    while (n > 0) {
      if (Date.now() - t0 >= maxMs) {
        return;
      }
      await new Promise<void>((res: () => void) => {
        setTimeout(res, 500);
      });
      n = ChartRuntimeService.missingShots(ctx, blocks, dark, bg);
    }
  }

  /**
   * **逐个库过筛**：这个库还要不要带？（"还缺图的块"里还有需要它的吗）
   * 全图齐时调用方直接 needed=[]，无需逐个问；有缺时用它把"不缺的库"摘掉 ——
   * 比如全篇只剩 1 张 mermaid 没烘出来，就只留 mermaid.min.js。
   */
  static fileStillNeeded(ctx: common.UIAbilityContext, blocks: MdBlock[],
                         dark: boolean, bg: string, file: string): boolean {
    // **行内公式没有"快照"概念**（它不走图，只有 .kxi 容器现场渲染）——
    // 只要文档里有行内公式，katex 的库就必须保留（用户实测"行内公式没有正常渲染"
    // 的修复：此前 needed 收集只认块级 Math 块，零库导出时行内公式整片变源码）。
    if (MdToHtml.hasInlineMath(blocks)
      && ChartRuntimeService.filesForLang('katex').indexOf(file) >= 0) {
      return true;
    }
    for (let k = 0; k < blocks.length; k++) {
      const b: MdBlock = blocks[k];
      let lang: string = '';
      if (b.kind === MdBlockKind.Chart) {
        lang = b.lang.trim().toLowerCase();
        if (lang === 'html') {
          continue;
        }
        // **markmap 在这里不能跳过**（与上面 missingShots 的口径**故意不同**）：它有意
        // 不进烘焙池（正文要实时可拖拽），所以永远"缺快照"。上一版照抄 missingShots
        // 把它 continue 掉 → "其余图都齐"时 d3 / markmap-lib / markmap-view 被裁库
        // 筛掉，导出页里那个 .markmap 容器没有任何库可画 = 思维导图不显示（用户实测）。
      } else if (b.kind === MdBlockKind.Math) {
        lang = 'katex';
      } else {
        continue;
      }
      if (MdToHtml.engineOffForLang(lang)) {
        continue;
      }
      const files: string[] =
        ChartRuntimeService.filesForLang(lang, b.kind === MdBlockKind.Chart ? b.code : '');
      if (files.indexOf(file) < 0) {
        continue;
      }
      if (!ChartCache.hasShot(ctx, lang, b.code, dark, bg)) {
        return true;
      }
    }
    return false;
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
