// 渲染引擎批量升级器（2026-10 全库升级）：
//   · render/*.html 里内联的库 → 「整段替换」（只换库文本，保留模板其余手工逻辑）
//   · rawfile/runtimes + tools/runtimes 的源库文件 → 同步为新版
// 用法：node tools/upgrade-libs.js [katex|mermaid|echarts|abc|flowchart|raphael|marked|turndown|chartjs|vega|viz|mathjax|all]
// 新库文件先放进 $LOCALAPPDATA/Temp/upgrade（文件名见各函数里的 up(...)）。
// ⚠️ 不升级的：mathjax v4（要 API 适配）、flowchart.js 1.18（npm 不再发浏览器包）、
//    mermaid 12（实测把 requirementDiagram 跑挂）。理由都写在对应函数上方。
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const UP = path.join(process.env.LOCALAPPDATA, 'Temp', 'upgrade'); // Git Bash /tmp/upgrade 的真实路径
const RENDER = path.join(ROOT, 'entry/src/main/resources/rawfile/render');
const RAW_RUN = path.join(ROOT, 'entry/src/main/resources/rawfile/runtimes');
const TOOL_RUN = path.join(__dirname, 'runtimes');
const EDITOR = path.join(ROOT, 'entry/src/main/resources/rawfile/editor');

const read = (p) => fs.readFileSync(p, 'utf8');

/** 提取 html 中 >30KB 的 script/style 段（{tag, body, index}）。 */
function bigSegs(doc, minSize) {
  const segs = [];
  const re = /<(script|style)>([^]*?)<\/\1>/g;
  let m;
  while ((m = re.exec(doc)) !== null) {
    if (m[2].length > (minSize || 30000)) {
      segs.push({ tag: m[1], body: m[2], index: m.index });
    }
  }
  return segs;
}

/** 把 html 里"符合特征"的库段整段替换为新库文本。 */
function swapSegment(htmlFile, feature, newLibPath) {
  const p = path.join(RENDER, htmlFile);
  const doc = read(p);
  const segs = bigSegs(doc, feature.min || 30000);
  const hit = segs.find((s) => s.body.indexOf(feature.contains) >= 0);
  if (!hit) {
    console.log('  SKIP(未找到段)', htmlFile, feature.contains);
    return false;
  }
  const oldFull = '<' + hit.tag + '>' + hit.body + '</' + hit.tag + '>';
  const newLib = read(newLibPath);
  if (hit.body === newLib) {
    console.log('  SAME', htmlFile, '（已是新版）');
    return true;
  }
  const newFull = '<' + hit.tag + '>' + newLib + '</' + hit.tag + '>';
  const out = doc.split(oldFull).join(newFull);
  if (out === doc) {
    console.log('  FAIL(替换未生效)', htmlFile);
    return false;
  }
  fs.writeFileSync(p, out);
  console.log('  OK', htmlFile, (hit.body.length / 1024).toFixed(0) + 'KB →',
    (newLib.length / 1024).toFixed(0) + 'KB');
  return true;
}

/** 文件部署（不存在则创建），返回是否变了。 */
function deploy(src, dst, label) {
  const s = read(src);
  let old = '';
  try { old = read(dst); } catch (e) { old = ''; }
  if (old === s) { console.log('  SAME', label); return; }
  fs.writeFileSync(dst, s);
  console.log('  OK', label);
}

const TASK = process.argv[2] || 'all';
const up = (f) => path.join(UP, f);

function katex() {
  console.log('== KaTeX 0.19.0 ==');
  swapSegment('katex.html', { contains: 'katex', min: 200000 }, up('katex.min.js'));
  swapSegment('katex.html', { contains: '@font-face', min: 10000 }, up('katex.min.css'));
  deploy(up('katex.min.js'), path.join(RAW_RUN, 'katex.min.js'), 'rawfile katex.min.js');
  deploy(up('katex.min.css'), path.join(RAW_RUN, 'katex.min.css'), 'rawfile katex.min.css');
  deploy(up('katex.min.js'), path.join(TOOL_RUN, 'katex.min.js'), 'tools katex.min.js');
  deploy(up('katex.min.css'), path.join(TOOL_RUN, 'katex.min.css'), 'tools katex.min.css');
  // 字体：0.19.0 与 0.16.11 逐字节一致（已核验），无需动
}

function mermaid() {
  // ⚠️ 版本历史（别再只信下面这行旧注释）：10.9.3 →（v15）11.4.1 →（v16）11.17.2。
  // 更早确实从 12.1.0 回退过一次（用户实测 12 系在应用内渲染异常）。
  // 2026-10-14 再把 12.2.0 拉下来跑同一批 33 个样本：时序图参与者类型仍只认
  // actor/participant、C4 画法没变、反而把 requirementDiagram 跑挂 → 不升。
  // 再升级前必须重跑 .workbuddy/c4probe 那套样本，不能只看一两种图。
  console.log('== Mermaid 11.17.2 ==');
  swapSegment('mermaid.html', { contains: 'sequenceDiagram', min: 1000000 }, up('mermaid.min.js'));
  // flowchart（借 mermaid 渲染的导出链路）与 mermaid.html 共用
  deploy(up('mermaid.min.js'), path.join(RAW_RUN, 'mermaid.min.js'), 'rawfile mermaid.min.js');
  deploy(up('mermaid.min.js'), path.join(TOOL_RUN, 'mermaid.min.js'), 'tools mermaid.min.js');
}

function echarts() {
  console.log('== ECharts 6.1.0 ==');
  swapSegment('echarts.html', { contains: 'Apache Software Foundation', min: 500000 }, up('echarts.min.js'));
  deploy(up('echarts.min.js'), path.join(RAW_RUN, 'echarts.min.js'), 'rawfile echarts.min.js');
  deploy(up('echarts.min.js'), path.join(TOOL_RUN, 'echarts.min.js'), 'tools echarts.min.js');
}

function abc() {
  console.log('== abcjs 6.7.1 ==');
  swapSegment('abc.html', { contains: 'abcjs', min: 100000 }, up('abcjs-basic-min.js'));
  deploy(up('abcjs-basic-min.js'), path.join(RAW_RUN, 'abcjs.min.js'), 'rawfile abcjs.min.js');
  deploy(up('abcjs-basic-min.js'), path.join(TOOL_RUN, 'abcjs.min.js'), 'tools abcjs.min.js');
}

function flowchart() {
  // ⚠️ 1.18.0 **不再发布浏览器包**（npm tarball 里只有 src/ 与 index.js，没有
  // release/flowchart.min.js），要用得自己接 bundler。这是条借 raphael 画的老引擎，
  // 不值得为它引一套构建链 → 停在 1.17.1，升级前先确认新版是否重新附带 UMD。
  console.log('== flowchart.js 1.17.1（1.18.0 无浏览器包，暂不升）==');
  swapSegment('flowchart.html', { contains: 'flowchart.js, v', min: 20000 }, up('flowchart.min.js'));
  deploy(up('flowchart.min.js'), path.join(RAW_RUN, 'flowchart.min.js'), 'rawfile flowchart.min.js');
  deploy(up('flowchart.min.js'), path.join(TOOL_RUN, 'flowchart.min.js'), 'tools flowchart.min.js');
}

function raphael() {
  console.log('== Raphael 2.3.0 ==');
  swapSegment('flowchart.html', { contains: 'Raphael', min: 50000 }, up('raphael.min.js'));
  deploy(up('raphael.min.js'), path.join(RAW_RUN, 'raphael.min.js'), 'rawfile raphael.min.js');
  deploy(up('raphael.min.js'), path.join(TOOL_RUN, 'raphael.min.js'), 'tools raphael.min.js');
}

function viz() {
  console.log('== @viz-js/viz 3.31.0（Graphviz 16.1.0）==');
  // 模板内联的是 Viz.js 1.8.2（2.12MB）；替换为 3.x 的 UMD 全局版
  swapSegment('graphviz.html', { contains: 'Viz.js 1.8', min: 1000000 }, up('viz-global.js'));
  deploy(up('viz-global.js'), path.join(RAW_RUN, 'viz-global.js'), 'rawfile viz-global.js');
  deploy(up('viz-global.js'), path.join(TOOL_RUN, 'viz-global.js'), 'tools viz-global.js');
  // 清理已被替代的旧版双文件（2.1.2）
  for (const f of ['viz2.js', 'viz2-full.render.js']) {
    const p1 = path.join(RAW_RUN, f);
    const p2 = path.join(TOOL_RUN, f);
    try { fs.unlinkSync(p1); console.log('  DEL', 'rawfile/' + f); } catch (e) { /* 已无 */ }
    try { fs.unlinkSync(p2); console.log('  DEL', 'tools/' + f); } catch (e) { /* 已无 */ }
  }
}

function marked() {
  console.log('== marked 18.1.1 ==');
  deploy(up('marked.umd.js'), path.join(EDITOR, 'marked.min.js'), 'editor marked.min.js');
  deploy(up('marked.umd.js'), path.join(TOOL_RUN, 'marked.min.js'), 'tools marked.min.js');
}

function turndown() {
  console.log('== turndown 7.2.4 ==');
  deploy(up('turndown.js'), path.join(EDITOR, 'turndown.js'), 'editor turndown.js');
  deploy(up('turndown.js'), path.join(TOOL_RUN, 'turndown.js'), 'tools turndown.js');
}

/**
 * Chart.js：只存在于 render/chart.html 的内联段里（runtimes/ 一直没有它的副本，
 * 所以导出的网页里 chart 围栏画不出来 —— 那是待办 #51，本函数只负责升版本）。
 */
function chartjs() {
  console.log('== Chart.js 4.5.1 ==');
  swapSegment('chart.html', { contains: 'Chart.js v', min: 100000 }, up('chart.umd.js'));
}

/**
 * Vega-Lite（2026-10-14 新增引擎）：render/vega.html 里内联了**两段**库，
 * 顺序必须是 vega 在前（vega-lite 的 UMD 按全局 vega 取依赖），runtimes/ 同步两份。
 */
function vega() {
  console.log('== Vega 6.4.0 + Vega-Lite 6.5.0 ==');
  swapSegment('vega.html', { contains: 'vega', min: 300000 }, up('vega.min.js'));
  swapSegment('vega.html', { contains: 'vega-lite', min: 100000 }, up('vega-lite.min.js'));
  deploy(up('vega.min.js'), path.join(RAW_RUN, 'vega.min.js'), 'rawfile vega.min.js');
  deploy(up('vega-lite.min.js'), path.join(RAW_RUN, 'vega-lite.min.js'), 'rawfile vega-lite.min.js');
  deploy(up('vega.min.js'), path.join(TOOL_RUN, 'vega.min.js'), 'tools vega.min.js');
  deploy(up('vega-lite.min.js'), path.join(TOOL_RUN, 'vega-lite.min.js'), 'tools vega-lite.min.js');
}

if (TASK === 'katex' || TASK === 'all') { katex(); }
if (TASK === 'mermaid' || TASK === 'all') { mermaid(); }
if (TASK === 'echarts' || TASK === 'all') { echarts(); }
if (TASK === 'abc' || TASK === 'all') { abc(); }
if (TASK === 'flowchart' || TASK === 'all') { flowchart(); }
if (TASK === 'raphael' || TASK === 'all') { raphael(); }
if (TASK === 'viz' || TASK === 'all') { viz(); }
if (TASK === 'marked' || TASK === 'all') { marked(); }
if (TASK === 'turndown' || TASK === 'all') { turndown(); }
if (TASK === 'chartjs' || TASK === 'all') { chartjs(); }
if (TASK === 'vega' || TASK === 'all') { vega(); }
console.log('done.');
