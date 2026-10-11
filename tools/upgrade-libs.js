// 渲染引擎批量升级器（2026-10 全库升级）：
//   · render/*.html 里内联的库 → 「整段替换」（只换库文本，保留模板其余手工逻辑）
//   · rawfile/runtimes + tools/runtimes 的源库文件 → 同步为新版
// 用法：node tools/upgrade-libs.js [katex|mermaid|echarts|abc|flowchart|raphael|marked|turndown|viz|mathjax|all]
// ⚠️ 无法升级/需 API 适配的（mathjax v4 / viz v3）在脚本内单独处理或手动。
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
  // ⚠️ **已回退 12.1.0 → 10.9.3**（用户实测：流程图/状态图/类图/饼图在应用内
  // 渲染异常，不如 10.x；10.9.3 是 10.x 终版）。再升级前先过 check-mermaid-rollback.html。
  console.log('== Mermaid 10.9.3（自 12.1.0 回退）==');
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
  console.log('== flowchart.js 1.17.1 ==');
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
  console.log('== marked 18.1.0 ==');
  deploy(up('marked.umd.js'), path.join(EDITOR, 'marked.min.js'), 'editor marked.min.js');
  deploy(up('marked.umd.js'), path.join(TOOL_RUN, 'marked.min.js'), 'tools marked.min.js');
}

function turndown() {
  console.log('== turndown 7.2.4 ==');
  deploy(up('turndown.js'), path.join(EDITOR, 'turndown.js'), 'editor turndown.js');
  deploy(up('turndown.js'), path.join(TOOL_RUN, 'turndown.js'), 'tools turndown.js');
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
console.log('done.');
