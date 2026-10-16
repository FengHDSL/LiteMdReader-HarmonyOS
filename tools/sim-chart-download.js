#!/usr/bin/env node
/**
 * 「图表 / 公式下载」（独立渲染通道）的校验
 * ==========================================
 *
 * 与工程里其它 sim 一样：**不手抄端口**。收敛决策（DlFit：表面宽度钳制 + 装不下时
 * 的等比缩放倍率）是整条链路里唯一"算错就出坏图"的地方，脚本按 `@Component`
 * 把 DiagramDownloadHost.ets 的真实源码截出来直接执行（Node 22 内置类型擦除），
 * 测的就是应用里跑的那份实现。
 *
 * 另外三层断言（源码同步 + 模板形态 + 图种与模板一一对应）覆盖"接线掉了"这类
 * 光靠跑逻辑测不出来的回归：
 *   · 表面宽度绝不超过屏幕（超宽内容靠 zoom 缩进来，不靠开一块巨宽表面）；
 *   · 内容装得下 → 倍率必须是 1（不能无缘无故缩图 —— "不要拉伸不要挤压"）；
 *   · 宽/高两轴各算一个倍率、取小者 → 同一个倍率作用两轴（等比，不是两轴各缩各的）。
 *
 * 用法：node tools/sim-chart-download.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const ETS = path.join(ROOT, 'entry', 'src', 'main', 'ets');
const RENDER = path.join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'render');
const readEts = (rel) => fs.readFileSync(path.join(ETS, rel), 'utf8').replace(/\r\n/g, '\n');

const hostEts = readEts('components/DiagramDownloadHost.ets');
const webEts = readEts('components/DiagramWeb.ets');
const readerEts = readEts('pages/Reader.ets');
const cacheEts = readEts('service/ChartCache.ets');

let fails = 0;
function check(label, ok, extra) {
  if (!ok) { fails++; console.log('  FAIL  ' + label + (extra === undefined ? '' : '  ' + extra)); }
  else { console.log('  ok    ' + label); }
}

// ── ① 接入点：链路各段的"接口"都还在（改名 / 摘属性会让本脚本与实现脱节）──
check('① DiagramWeb：下载专用四个通道都声明了（dl / dlZoom / layoutTick / dlForceHeight）',
  webEts.includes('dl: boolean = false') && webEts.includes('dlZoom: number = 0')
  && webEts.includes('layoutTick: number = 0') && webEts.includes('dlForceHeight: number = 0'));
check('① DiagramWeb：dl 与 z 真的进了 renderPayload（模板据此切导出形态）',
  /dl:\s*this\.dl/.test(webEts) && /z:\s*this\.dlZoom/.test(webEts));
check('① DiagramWeb：onSizeReady 在 postWidth 与 postHeight **两路**都回调（回传顺序不保证）',
  (webEts.match(/this\.onSizeReady\(this\.lastPostW, this\.lastPostH\)/g) || []).length === 2);
check('① DiagramWeb：钉死高度在 floor/cap **之前**拦下（否则画布高会被 56 保底改掉）',
  webEts.indexOf('if (this.dlForceHeight > 0)') > 0
  && webEts.indexOf('if (this.dlForceHeight > 0)') < webEts.indexOf('const floor: number'));
check('① 宿主：挂在根 Stack（不被任何容器裁剪）+ 用完即卸（dlJob 空即卸载）',
  readerEts.includes('DiagramDownloadHost({') && readerEts.includes('if (this.dlJob !== null)'));
check('① 宿主：强制浅色（dark=false + 纯白底），与当前主题无关',
  /dark:\s*false/.test(hostEts) && hostEts.includes("cardBg: '#FFFFFFFF'"));
// 只看 @Component 之后的**代码**（先摘注释）：注释里正解释着"不要套 .clip"，
// 扫原文会自己撞上自己（实测就这么失败过一次）
const hostBody = hostEts.substring(hostEts.search(/^@Component\s*$/m))
  .replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
check('① 宿主：表面**不带** .clip / 固定高容器（那正是浮层做不到的事）',
  !/\.clip\(/.test(hostBody) && !/\.height\(/.test(hostBody));
check('① 宿主：整页快照走 webId + captureRequest（不是截可视区）',
  hostEts.includes("webId: 'dl_web'") && hostEts.includes('captureRequest: this.captureTick'));
check('① 宿主：快照产物做横向自检（设备像素比由高度轴反推，不硬编码密度）',
  hostEts.includes('expectW') && hostEts.includes('0.85'));
check('① 阅读页：按钮只对可下载图种显示；保存链路 = 裁边 + 尺寸上限保护 + 另存',
  readerEts.includes('this.dlSupported()') && readerEts.includes('ChartCache.trimPng(bytes)')
  && readerEts.includes('ChartCache.capPngSize(bytes, DL_PNG_MAX_AREA, DL_PNG_MAX_SIDE)'));
check('① ChartCache：capPngSize **两轴一起给**目标尺寸（只给一边 SDK 不保证等比）',
  cacheEts.includes('desiredSize: { width: nw, height: nh }'));
check('① 阅读页：下载中按钮置淡 + 防重复触发（dlBusy 三处收尾）',
  readerEts.includes('this.dlBusy = true') && readerEts.includes('this.dlBusy = false'));

// ── ② 模板形态：底色层的圆角 / 内描边在导出形态里必须关掉 ──
// （圆角在快照里会合成成四角发黑、inset 描边会变成图上一圈灰边 —— 都是用户实测过的观感问题）
const BG_TEMPLATES = ['abc', 'chart', 'ditaa', 'echarts', 'flowchart', 'graphviz',
  'markmap', 'markmap-card', 'mermaid', 'nomnoml', 'nwdiag'];
const dlMissing = [];
const chromeMissing = [];
for (const t of BG_TEMPLATES) {
  const html = fs.readFileSync(path.join(RENDER, t + '.html'), 'utf8');
  if (!html.includes('if(o.dl){')) { dlMissing.push(t); continue; }
  if (!/__bg\.style\.borderRadius='0'/.test(html) || !/__bg\.style\.boxShadow='none'/.test(html)) {
    chromeMissing.push(t);
  }
}
check('② 十一个带底色层的模板都认导出形态（o.dl）', dlMissing.length === 0, dlMissing.join(', '));
check('② 导出形态里圆角与内描边都关掉了（不去掉就是四角发黑 + 一圈灰边）',
  chromeMissing.length === 0, chromeMissing.join(', '));
const katexHtml = fs.readFileSync(path.join(RENDER, 'katex.html'), 'utf8');
check('② katex 认超宽适配倍率（o.z → body CSS zoom）且**每次显式复位**',
  /document\.body\.style\.zoom = \(o\.z && o\.z > 0 && o\.z !== 1\)/.test(katexHtml));

// **mermaid 的 fit 限高必须与导出形态分开**（2026-10-16 真机定位的根因）：
// 下载表面高度由"内容回传"分级撑起，Web 挂载时视口只有初始 100vp —— 若按
// 100vh 限高，svg 被压成一条、app 高度从此不再变化 → ResizeObserver 不再回传
// → 宿主拿着"没画完的假稳定尺寸"提前派发快照 → 被平台以「Web is not painted
// ready for snapshot」拒绝，整单失败（用户看到的"图片生成失败"）。
const mermaidHtml = fs.readFileSync(path.join(RENDER, 'mermaid.html'), 'utf8');
check('② mermaid 标记导出形态（window.__dl，且在 __render 之前赋值）',
  mermaidHtml.indexOf('window.__dl=!!o.dl') > 0
  && mermaidHtml.indexOf('window.__dl=!!o.dl') < mermaidHtml.indexOf('window.__render(o.src'));
check('② mermaid 导出时不按 100vh 限高（限高会压扁 + 卡住高度回传）',
  /sv\.style\.maxHeight = window\.__dl \? 'none' : 'calc\(100vh - 24px\)'/.test(mermaidHtml));

// **快照被平台拒绝要重试**："Web is not painted ready" 时回调不带产物；
// 此前单拍一次就等兜底超时，整单必然失败。重试链上限 5 拍（~3.5s），
// 回调被吞时由看门狗推进；按 captureRequest 归档（池子复用组件不能串轮次）。
check('② DiagramWeb 快照被拒会隔拍重试（capAttempt / capDelivered / capReqSeen + 看门狗）',
  webEts.includes('capAttempt') && webEts.includes('capDelivered')
  && webEts.includes('capReqSeen') && webEts.includes('看门狗')
  && webEts.includes('Web is not painted ready'));

// ── ③ 图种白名单与渲染模板一一对应 ──
// 白名单少一个 → 按钮该出现时不出现；多一个（模板不存在）→ 点了没反应
const dlBody = readerEts.substring(readerEts.indexOf('private dlSupported()'),
  readerEts.indexOf('private startEnlargeDownload()'));
const modes = (dlBody.match(/m === '([a-z0-9]+)'/g) || []).map((s) => s.replace(/m === '|'/g, ''));
const noTpl = modes.filter((m) => {
  const file = m === 'markmap' ? 'markmap-card.html' : m + '.html';
  return !fs.existsSync(path.join(RENDER, file));
});
check('③ 白名单里的每个图种都有渲染模板（' + modes.length + ' 个：' + modes.join('/') + '）',
  modes.length >= 12 && noTpl.length === 0, noTpl.join(', '));
check('③ 白名单排除了代码 / 图片 / 网页预览 / 无模板的 zenuml',
  !modes.includes('code') && !modes.includes('image') && !modes.includes('html')
  && !modes.includes('zenuml'));
check('③ 公式（katex）与脑图（markmap）在列 —— 这两类最需要"屏外内容也出图"',
  modes.includes('katex') && modes.includes('markmap'));

// ── ④ 用**真实实现**跑收敛决策 ──
const tmpDir = path.join(__dirname, '.chart-dl-sim');
fs.mkdirSync(tmpDir, { recursive: true });
const tmpFile = path.join(tmpDir, 'host.ts');
// 取到 @Component 之前的部分（imports + DlJob + DL_* 常量 + DlFit），去掉那两条 import。
// ⚠️ 标记必须锚**整行**：DlFit 的注释里也提到了 @Component，按首次出现切会切进注释中间
//    （实测报 Unterminated block comment）。
const head = hostEts.substring(0, hostEts.search(/^@Component\s*$/m));
fs.writeFileSync(tmpFile, head.replace(/^import .*;\s*$/gm, ''));

(async () => {
  const mod = await import('file://' + tmpFile.replace(/\\/g, '/') + '?t=' + Date.now());
  const DlFit = mod.DlFit;
  check('④ 真实实现可执行：DlFit 两个入口都在（surfaceWidthOf / zoomFor）',
    typeof DlFit.surfaceWidthOf === 'function' && typeof DlFit.zoomFor === 'function');

  // 表面宽度：画布宽原样、异常值走上下限、取不到走兜底
  check('④ 表面宽 = 画布宽（360 → 360）', DlFit.surfaceWidthOf(360) === 360);
  check('④ 画布尺寸取不到 → 兜底 360（不是 0，0 会让表面塌成看不见）',
    DlFit.surfaceWidthOf(0) === 360 && DlFit.surfaceWidthOf(-5) === 360);
  check('④ 画布异常小 → 抬到 160（表面太窄渲染库会自己缩，出图更糊）',
    DlFit.surfaceWidthOf(50) === 160);
  check('④ 画布异常大 → 压到 2048（绝不开一块荒唐大的表面：设备像素按 3.5 倍算就是 7000+ 像素宽）',
    DlFit.surfaceWidthOf(9999) === 2048);

  // 缩放倍率：装得下必须原样（1），装不下按两轴取小者、且同一个倍率
  check('④ 内容装得下 → 倍率 1（不许无缘无故缩图）',
    DlFit.zoomFor(360, 360, 600) === 1 && DlFit.zoomFor(360, 200, 100) === 1);
  check('④ 误差 2vp 以内不算溢出（渲染库的取整抖动不该触发缩放）',
    DlFit.zoomFor(360, 362, 600) === 1 && DlFit.zoomFor(360, 358, 600) === 1);
  check('④ 超宽公式：360 画布装 1440 宽 → 0.25（整幅缩进画面，横纵同倍）',
    DlFit.zoomFor(360, 1440, 120) === 0.25);
  check('④ 超高长图：8000 高 → 0.512（4096 是表面高度上限，必须与之同口径）',
    DlFit.zoomFor(360, 360, 8000) === 0.512);
  check('④ 又宽又高 → 取两轴更狠的那个（0.25 < 0.512）',
    DlFit.zoomFor(360, 1440, 8000) === 0.25);
  check('④ 极端超宽有下限保护（50000 宽 → 0.1，不会缩成一条线）',
    DlFit.zoomFor(360, 50000, 100) === 0.1);
  check('④ 入参异常（0 / 负数）→ 不缩放，交给上游兜底',
    DlFit.zoomFor(0, 100, 100) === 1 && DlFit.zoomFor(360, 0, 100) === 1
    && DlFit.zoomFor(360, 100, 0) === 1);
  check('④ 倍率口径与宿主一致：<0.995 才下发（否则每次渲染都白跑一遍收敛）',
    hostEts.includes('if (z < 1)') && hostEts.includes('const z: number = DlFit.zoomFor('));

  // ── ⑤ 导出 / 打印"全图片化"（2026-10-16）：图表一律用生成的图片 ──
  // 目标：导出 HTML 里公式 / 图表全部内嵌池子烘的 PNG，图齐时**一个渲染库都不带**
  //（用户实测量级：17.8MB = 62 张图 4.3MB + 渲染库 11.6MB）。
  const runtimeEts = readEts('service/ChartRuntimeService.ets');
  const exportEts = readEts('service/ExportService.ets');
  const printEts = readEts('service/PrintService.ets');
  const poolEts = readEts('components/ChartRenderPool.ets');
  const mdHtmlEts = fs.readFileSync(path.join(ETS, 'markdown', 'MdToHtml.ets'), 'utf8').replace(/\r\n/g, '\n');
  const mdViewEts = fs.readFileSync(path.join(ETS, 'markdown', 'MdView.ets'), 'utf8').replace(/\r\n/g, '\n');

  check('⑤ 缺图判定泛化到全部图种（missingShots / waitShots / fileStillNeeded）',
    runtimeEts.includes('static missingShots(') && runtimeEts.includes('static async waitShots(')
    && runtimeEts.includes('static fileStillNeeded('));
  check('⑤ 旧的"只查 PlantUML"版本已移除（kernelNeeded 函数不在）',
    !runtimeEts.includes('static kernelNeeded(') && !runtimeEts.includes('static async waitForShots('));
  check('⑤ 导出：先发失败重试信号、再等（上限 45s）、超时按缺口裁库',
    exportEts.includes("AppStorage.setOrCreate('chartRetryTick'")
    && exportEts.includes('waitShots(ctx, parsed.blocks, dark, chartBg, 45000')
    && exportEts.includes('fileStillNeeded(ctx, parsed.blocks, dark, chartBg'));
  check('⑤ 打印：同一套等待 + 裁剪（45s，浅色口径）',
    printEts.includes("AppStorage.setOrCreate('chartRetryTick'")
    && printEts.includes("waitShots(ctx, parsed.blocks, false, '', 45000")
    && printEts.includes("fileStillNeeded(ctx, parsed.blocks, false, '"));
  check('⑤ 内联语义修正：inline=[] 也必须走内联分支（零库全图化不能掉进 CDN 回退）',
    mdHtmlEts.includes('if (inline !== null) {')
    && !/if \(inline !== null && inline\.length > 0\)/.test(mdHtmlEts));

  // ➎.2 池子失败重试链：导出 → AppStorage → Reader → 池子（清失败集重跑一轮）
  check('⑤ 池子有失败重试入口（retryTick → failed.clear + pump）',
    poolEts.includes("@Watch('onRetryTick')") && poolEts.includes('this.failed.clear()'));
  check('⑤ Reader 桥接（@StorageProp chartRetryTick → poolRetryTick → 池子 retryTick）',
    readerEts.includes("@StorageProp('chartRetryTick')")
    && readerEts.includes('this.poolRetryTick = this.poolRetryTick + 1')
    && readerEts.includes('retryTick: this.poolRetryTick'));

  // ➎.3 串图闸门（跨页面串图的治本 + 作废）
  check('⑤ 串图闸门：模板页切换窗口丢弃旧页面的尺寸报告（pageLoading）',
    webEts.includes('private pageLoading: boolean = false;')
    // 闸门现在都带"6 秒保险丝"（Date.now() - pageLoadAt < 6000），断言按实际写法判，
    // 否则这条永远红着——真出事时反而看不见
    && (webEts.match(/if \(this\.pageLoading[ )]/g) || []).length >= 2
    && webEts.includes('this.pageLoading = false;\n        this.webReady = true;'));
  check('⑤ 键盐升到 v29（payload 索引也纳入盐 + .dim 改由像素反推）',
    cacheEts.includes("static readonly SALT: string = 'v29';")
    && cacheEts.includes('ChartCache.SALT')
    && cacheEts.includes('private static idxKeyOf('));
  check('⑤ payload 索引带盐（否则升键后索引还指着旧图，作废形同虚设）',
    (cacheEts.match(/ChartCache\.idxKeyOf\(mode, payload, dark\)/g) || []).length >= 2
    && !/hashOf\(mode \+ '\|' \+ \(dark \? 'd' : 'l'\)/.test(cacheEts));
  check('⑤ .dim 由落盘像素 ÷ 密度反推（不再用滞后的回传高度折算）',
    /wOut = Math\.round\(info3\.size\.width \/ dens\)/.test(cacheEts)
    && /hOut = Math\.round\(info3\.size\.height \/ dens\)/.test(cacheEts)
    && !cacheEts.includes('wOut = Math.round(w * (info2.size.width'));

  // ➎.3b 烘焙几何口径（用户实测状态图 / C4 / 韦恩图被挤成窄条，而"单独下载"是好的）
  // 根因是池子的表面宽度用 '100%'：转场 / 首帧里父容器量到极小值，mermaid 就按那个
  // 宽度重排。下载链路一直是对的，因为它把表面钉死了 —— 所以池子必须复用同一套 DlFit。
  check('⑤ 池子按下载链路同一套钉死表面宽（DlFit.surfaceWidthOf，不用 100%）',
    poolEts.includes('DlFit.surfaceWidthOf(this.hostWidth)')
    && poolEts.includes('virtualWidth: this.surfaceW,'));
  check('⑤ 超宽内容等比缩进表面（dlZoom + layoutTick 重排，两轴同倍率不拉伸）',
    poolEts.includes('DlFit.zoomFor(this.surfaceW, this.lastW, this.lastH)')
    && poolEts.includes('dlZoom: this.dlZoom,') && poolEts.includes('layoutTick: this.layoutTick,'));
  check('⑤ 池子按下载排版烘图（fit:true）', poolEts.includes('fit: true,'));
  check('⑤ 快照逻辑宽度有兜底（模板不回传时用组件实测宽）',
    webEts.includes('private areaW: number = 0;')
    && webEts.includes('this.lastPostW > 0 ? this.lastPostW : this.areaW'));
  check('⑤ 导出嵌图与"有图判定"同一取键口径（lightShotKeys 共用）',
    cacheEts.includes('private static lightShotKeys(')
    && (cacheEts.match(/ChartCache\.lightShotKeys\(/g) || []).length >= 2);
  check('⑤ 块级公式全透底：不烘图、导出也不用快照（正文与网页都现场渲染 KaTeX）',
    !/ChartCache\.pngEmbed\(ctx, 'katex'/.test(mdHtmlEts)
    && mdHtmlEts.includes("} else if (block.kind === MdBlockKind.Math && rich) {")
    && !/if \(this\.chartImagePath\('katex'\)\.length > 0\)/.test(mdViewEts)
    && (() => {
      const at = readerEts.indexOf('if (b.kind === MdBlockKind.Math) {');
      const seg = at >= 0 ? readerEts.substring(at, at + 700) : '';
      return seg.includes('continue;') && !seg.includes("mode = 'katex'");
    })());
  check('⑤ 导出嵌图仍按逻辑尺寸定宽（embedStyle 用在图表分支）',
    mdHtmlEts.includes('private static embedStyle(embed: string)')
    && mdHtmlEts.includes('MdToHtml.embedStyle(pngEmbed)'));
  check('⑤ 公式卡片画布与图表卡片同样圆角（圆角加在图片本身，不只加在 Scroll 视口）',
    /Image\(this\.chartImagePath\(mode\)\)\s*\n\s*\.objectFit\(ImageFit\.Contain\)\s*\n\s*\.borderRadius/.test(
      mdViewEts.substring(mdViewEts.indexOf('blockImage(mode: string)'),
        mdViewEts.indexOf('blockImage(mode: string)') + 1200)));

  // ➎.4 图源扩展：wavedrom/abc 回归用图；salt/ditaa/nwdiag 进池但正文保持实时卡
  check('⑤ pngSkip 只剩 html（wavedrom/abc 回归"快照优先"）',
    /const pngSkip: boolean = langLower === 'html';/.test(mdHtmlEts));
  const csAt = readerEts.indexOf('private collectChartTasks(');
  const ceAt = readerEts.indexOf('顶栏 / 底栏的收起与展开', csAt);
  const collectBody = (csAt >= 0 && ceAt > csAt) ? readerEts.substring(csAt, ceAt) : '';
  check('⑤ 池子任务不再跳过 salt/ditaa/nwdiag（导出 / 打印要有图）',
    collectBody.length > 0 && !/mode === 'salt'/.test(collectBody));
  check('⑤ 正文对三类保持实时卡（isLiveCardOnly 名单 + 用图分支引用）',
    mdViewEts.includes('function isLiveCardOnly(')
    && mdViewEts.includes('!isLiveCardOnly(this.block.lang)'));

  // ➎.5 行内公式的 katex 依赖（用户实测"行内公式没有正常渲染"的修复）
  // 行内公式在导出侧没有图片路径（只有 .kxi 容器现场渲染）——凡是"要不要带 katex
  // 库"的判定都必须把"文档里有行内公式"算进去，否则"块级公式全有快照 → 零库导出"
  // 会把行内公式整片饿死成 LaTeX 源码。
  check('⑤ 行内公式的 katex 依赖四处接入（收集×2 / 裁库 / runner+CDN）',
    mdHtmlEts.includes('static blockHasInlineMath(') && mdHtmlEts.includes('static hasInlineMath(')
    && runtimeEts.includes('MdToHtml.hasInlineMath(blocks)')
    && exportEts.includes('MdToHtml.blockHasInlineMath(b)')
    && printEts.includes('MdToHtml.blockHasInlineMath(b)')
    && (mdHtmlEts.match(/MdToHtml\.blockHasInlineMath\(b\)/g) || []).length >= 2);

  console.log(fails === 0 ? 'CHART DOWNLOAD OK' : 'CHART DOWNLOAD FAILED: ' + fails);
  process.exit(fails === 0 ? 0 : 1);
})().catch((e) => {
  console.log('  FAIL  执行真实实现时抛错：' + (e && e.message ? e.message : e));
  console.log('CHART DOWNLOAD FAILED: 1');
  process.exit(1);
});
