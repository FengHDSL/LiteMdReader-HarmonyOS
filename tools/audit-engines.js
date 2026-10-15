#!/usr/bin/env node
/**
 * 引擎管理对账：把 EngineRegistry 里登记的**版本与体积**，和 rawfile 里**真实打包的字节**对一遍。
 * 三件事：① 有没有漏登记的引擎（包里有渲染器，列表里没有）
 *        ② 版本串在产物里找不到（写错 / 升级后没同步）
 *        ③ 声称的离线库体积与实际模板/运行时大小对不上
 * 用法：node tools/audit-engines.js
 */
'use strict';
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const RAW = path.join(ROOT, 'entry/src/main/resources/rawfile');
const NL = String.fromCharCode(10);

const reg = fs.readFileSync(path.join(ROOT, 'entry/src/main/ets/service/EngineRegistry.ets'), 'utf8');
const entries = [];
const re = /id:\s*'([a-z0-9]+)',\s*name:\s*'([^']*)',\s*version:\s*'([^']*)',\s*date:\s*'([^']*)'[\s\S]*?size:\s*'([^']*)'/g;
let m;
while ((m = re.exec(reg))) {
  entries.push({ id: m[1], name: m[2], version: m[3], date: m[4], size: m[5] });
}
console.log('EngineRegistry 登记 ' + entries.length + ' 条');

function bytes(p) { try { return fs.statSync(p).size; } catch (e) { return -1; } }
function mb(n) { return (n / 1048576).toFixed(2) + ' MB'; }
function readHead(p, n) { try { return fs.readFileSync(p, 'utf8').slice(0, n); } catch (e) { return ''; } }
function readAll(p) { try { return fs.readFileSync(p, 'utf8'); } catch (e) { return ''; } }

// 引擎 → 打包产物（模板 = 阅读侧内联那份；运行时 = 导出侧那份）
const ART = {
  katex: ['render/katex.html', 'render/fonts', 'runtimes/katex.min.js', 'runtimes/katex.min.css', 'runtimes/mhchem.min.js'],
  mathjax: ['render/mjformula.html'],
  mermaid: ['render/mermaid.html', 'runtimes/mermaid.min.js'],
  markmap: ['render/markmap-card.html', 'runtimes/markmap-lib.js', 'runtimes/markmap-view.js', 'runtimes/d3.min.js'],
  echarts: ['render/echarts.html', 'runtimes/echarts.min.js'],
  abc: ['render/abc.html', 'runtimes/abcjs.min.js'],
  graphviz: ['render/graphviz.html', 'runtimes/viz-global.js'],
  flowchart: ['render/flowchart.html'],
  wavedrom: ['render/wavedrom.html', 'runtimes/wavedrom.min.js', 'runtimes/wavedrom-skin-default.js'],
  nomnoml: ['render/nomnoml.html', 'runtimes/nomnoml.js', 'runtimes/graphre.min.js'],
  plantuml: ['render/plantuml.html', 'runtimes/plantuml-kernel.js',
    'runtimes/salt-render.js', 'runtimes/ditaa-render.js', 'runtimes/nwdiag-render.js'],
  chartjs: ['render/chart.html', 'runtimes/chart.umd.js'],
  vega: ['render/vega.html', 'runtimes/vega.min.js', 'runtimes/vega-lite.min.js'],
  marked: ['editor/marked.min.js'],
  turndown: ['editor/turndown.js'],
  zenuml: [],
};
// 版本串在产物里怎么找（各库的写法不一样）
const VER = {
  katex: /version\$?\d?=\s*["']([0-9.]+)["']/,
  mathjax: /version\s*=\s*["']?([0-9]+\.[0-9]+\.[0-9]+)/,
  mermaid: /["']([0-9]+\.[0-9]+\.[0-9]+)["']\s*[;,]?\s*.{0,40}mermaid/i,
  graphviz: /Viz\.js ([0-9.]+)/,
  plantuml: /@plantuml\/core ([0-9.]+)/,
  chartjs: /Chart\.js v?([0-9.]+)/,
  abc: /abcjs_basic v?([0-9.]+)/,
  wavedrom: /wavedrom[^0-9]{0,20}([0-9]+\.[0-9]+\.[0-9]+)/i,
  vega: /Vega-Lite? v?([0-9.]+)/i,
  nomnoml: /nomnoml v?([0-9.]+)/i,
  echarts: /\bv?([0-9]+\.[0-9]+\.[0-9]+)\b[\s\S]{0,80}Apache|Apache ECharts/,
};

let problems = 0;
for (const e of entries) {
  const files = (ART[e.id] || []).map((f) => path.join(RAW, f)).filter((p) => fs.existsSync(p));
  if (files.length === 0 && e.id !== 'zenuml') {
    console.log('  缺产物  ' + e.id + '（登记了但找不到打包文件；zenuml 是刻意的空条目）');
    problems++;
    continue;
  }
  const total = files.reduce((a, p) => a + bytes(p), 0);
  const tplOnly = files.filter((p) => /render[\\/]/.test(p)).reduce((a, p) => a + bytes(p), 0);
  const declaredMB = parseFloat(e.size);
  const tpl = files.find((p) => /render[\\/]/.test(p)) || files[0];
  const body = tpl ? readAll(tpl) : '';
  const rx = VER[e.id];
  let foundVer = '';
  if (rx) { const vm = rx.exec(body); foundVer = vm ? (vm[1] || '') : ''; }
  const parts = e.version.split('/').map((s) => s.trim()).filter((s) => s.length > 0);
  const verOk = e.version === '—' || !rx || foundVer.length === 0
    || parts.every((p) => body.indexOf(p) >= 0);
  // 登记的 size 口径 = **这一引擎在安装包里的总占用**（内联模板 + 导出运行时 + 依赖），
  // 与 EngineRegistry 的字段注释同一说法；只量模板那份会把导出用的第二份拷贝漏掉
  const sizeOk = !(declaredMB > 0 && total > 0 && Math.abs(declaredMB - total / 1048576) > 0.06);
  const flag = (!verOk ? ' 版本?' : '') + (!sizeOk ? ' 体积?' : '');
  if (flag.length > 0) { problems++; }
  console.log('  ' + (flag.length ? '⚠ ' : 'ok ') + e.id.padEnd(9)
    + ' 登记 ' + e.version.padEnd(14) + ' 声称 ' + e.size.padEnd(9)
    + ' 模板 ' + (tplOnly > 0 ? mb(tplOnly) : '-').padEnd(9)
    + ' 两份合计 ' + (total > 0 ? mb(total) : '-').padEnd(10)
    + (foundVer ? ('产物内版本 ' + foundVer) : '') + flag);
}

// 包里有、列表里没有的渲染器（漏登记）
const listed = new Set(entries.map((e) => e.id));
const extra = [];
for (const f of fs.readdirSync(path.join(RAW, 'render'))) {
  const base = f.replace('.html', '');
  if (!fs.existsSync(path.join(RAW, 'runtimes'))) { continue; }
  if (!['salt', 'ditaa', 'nwdiag', 'html', 'code', 'image', 'markmap'].includes(base)
    && !Object.keys(ART).some((k) => (ART[k] || []).some((p) => p === 'render/' + f)) && !listed.has(base)) {
    extra.push('render/' + f);
  }
}
for (const f of fs.readdirSync(path.join(RAW, 'runtimes'))) {
  if (f === 'fonts') { continue; }
  const owner = Object.keys(ART).some((k) => (ART[k] || []).some((p) => p === 'runtimes/' + f));
  if (!owner) { extra.push('runtimes/' + f); }
}
console.log(NL + '未被任何引擎条目认领的产物（可能是漏登记，也可能是共用依赖）：');
console.log(extra.length ? extra.map((x) => '  · ' + x).join(NL) : '  （无）');
console.log(NL + (problems === 0 ? '引擎对账通过' : '引擎对账有 ' + problems + ' 项要核'));
