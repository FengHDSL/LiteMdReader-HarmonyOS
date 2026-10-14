// 工具栏「图表快捷插入」的模板校验。
//
// 从 Editor.ets 的 SNIPPETS 里抽出每个 chart 按钮实际会插入的内容，
//  ① 先做语法级检查（echarts / wavedrom 必须是合法 JSON —— 模板里裸写键名可以，
//     用渲染模板同一套 fix() 补引号后再判）；
//  ② 再产出清单交给 gen-chart-test-pages.js，用**真实渲染模板**在浏览器里逐个渲染，
//     证明"点按钮插进去的东西真能画出图"（插进去渲染不出来，比没有按钮更糟）。
//
// 用法：
//   node tools/verify-chart-templates.js
//   node tools/gen-chart-test-pages.js .workbuddy/chart-templates.json
//   然后按输出提示用浏览器打开 .workbuddy/charttest/*.html 读 #result
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const EDITOR = path.join(ROOT, 'entry/src/main/ets/pages/Editor.ets');
const OUT = path.join(ROOT, '.workbuddy/chart-templates.json');

function decodeLit(s) {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c !== '\\') { out += c; continue; }
    const n = s[++i];
    if (n === 'n') { out += '\n'; }
    else if (n === 't') { out += '\t'; }
    else if (n === 'r') { out += '\r'; }
    else if (n === '0') { out += '\0'; }
    else { out += n; }
  }
  return out;
}
// 允许 \\ 转义的字符串字面量
function field(line, name) {
  const re = new RegExp(name + ":\\s*'((?:[^'\\\\]|\\\\.)*)'");
  const m = re.exec(line);
  return m === null ? null : decodeLit(m[1]);
}

const src = fs.readFileSync(EDITOR, 'utf8').replace(/\r\n/g, '\n');
const start = src.indexOf('const SNIPPETS: MdSnippet[] = [');
const end = src.indexOf('];', start);
if (start < 0 || end < start) { console.error('找不到 SNIPPETS 数组'); process.exit(1); }

const manifest = {};
let fails = 0;
const JSON_LANGS = ['echarts', 'wavedrom'];
const fix = s => s.replace(/([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:/g, '$1"$2":');

for (const line of src.slice(start, end).split('\n')) {
  if (!line.trim().startsWith('{ key:')) { continue; }
  const key = field(line, 'key');
  const before = field(line, 'before');
  const holder = field(line, 'holder');
  if (key === null || before === null || holder === null || !key.startsWith('chart-')) { continue; }
  const lang = /^```([A-Za-z0-9_-]+)/.exec(before.replace(/^\n+/, ''));
  if (lang === null) {
    console.log('  FAIL  ' + key + '：before 里找不到围栏语言名');
    fails++; continue;
  }
  const tag = lang[1].toLowerCase();
  console.log('  ' + key + ' → ```' + tag + '  (' + holder.length + ' 字符)');
  (manifest[tag] = manifest[tag] || []).push({ doc: 'toolbar:' + key, line: 0, src: holder });
  if (JSON_LANGS.indexOf(tag) >= 0) {
    try { JSON.parse(holder); }
    catch (e1) {
      try { JSON.parse(fix(holder)); console.log('    （靠补键名引号才可解析）'); }
      catch (e2) { console.log('  FAIL  ' + key + ' JSON 非法: ' + e2.message); fails++; }
    }
  }
  // 占位内容不能自带围栏结束符，否则插入时提前闭合
  if (/^(```|~~~)/m.test(holder)) {
    console.log('  FAIL  ' + key + '：模板里含围栏结束符，会提前闭合代码块');
    fails++;
  }
}

const langs = Object.keys(manifest);
console.log('抽出 ' + langs.length + ' 种图表模板: ' + langs.join(', '));
if (langs.length < 7) { console.log('  FAIL  图表模板种类偏少（工具栏应有 8 种）'); fails++; }

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, JSON.stringify(manifest, null, 1));
// 卡片模式：必须**按 viewBox 同比缩放**并限高，不能再用 CSS max-height 直接夹 svg。
// 上一版那么写把 architecture-beta 挤坏了——它的 viewBox 带负原点（-283 -166 647 463），
// mermaid 又给了 width="100%"，两条叠加内容就跑出可视区（用户实测"卡片显示错误、放大后正常"，
// 放大走 fit 那条支路所以看不出来）。限高区间沿用正文图片路径 chartCardMaxHeight（340~600）。
{
  const mm = fs.readFileSync(path.join(ROOT, 'entry/src/main/resources/rawfile/render/mermaid.html'), 'utf8');
  const scaled = /Math\.min\(capW\/vb\.width, capH\/vb\.height\)/.test(mm)
    && /sv\.viewBox && sv\.viewBox\.baseVal/.test(mm);
  const noClampHack = !/maxHeight='clamp\(/.test(mm);
  // 窄图不跟 capH 一起缩（stateDiagram 100×412 / classDiagram 165×336 实测会被削成
  // 一条 87px 宽的细带、字更糊）——这条规则丢了就会退回那个体验。
  const narrowKeep = /vb\.width<=capW && vb\.height<=capH\*2/.test(mm);
  if (scaled && noClampHack && narrowKeep) {
    console.log('  ok    mermaid 卡片按 viewBox 同比缩放（限高 340~600，窄图保持自然尺寸）');
  } else {
    fails++;
    console.log('  FAIL  mermaid 卡片缩放规则被改动（同比缩放 / 不用 clamp 夹高 / 窄图不缩：'
      + [scaled, noClampHack, narrowKeep].join(', ') + '）');
  }
}
// 公式模板：svg/canvas 规则里**不能**出现 height:auto。
// KaTeX 的箭头是 `<svg width="400em" height="0.522em" viewBox="0 0 400000 522">`——超宽、
// 靠 height 属性与 max-width 裁切。height:auto 会按 viewBox 比例把它算成 0.05px，
// \ce 与 \xrightarrow 直接消失（用户实测"化学方程式箭头不显示了"，
// 就是给全部图表模板统一加 height:auto 那条改动串进了 katex.html）。
{
  const kx = fs.readFileSync(path.join(ROOT, 'entry/src/main/resources/rawfile/render/katex.html'), 'utf8');
  const cssOnly = kx.replace(/<script[\s\S]*?<\/script>/g, '');
  const bad = /#app svg[^}]*height:\s*auto/.test(cssOnly);
  if (bad) {
    fails++;
    console.log('  FAIL  katex.html 的 svg 规则带 height:auto：化学箭头会被压成 0.05px');
  } else {
    console.log('  ok    katex.html 未给公式 svg 加 height:auto（化学箭头留得住）');
  }
}

// 浅色主题必须是 default：neutral 下时序图参与者框是 rgb(238,238,238) 灰框黑字，
// 只有 default 才是 #ECECFF 淡紫（浏览器实测四种图种 × 三种配置；用户对比别家渲染
// 说"图表家族大多数没有颜色，全是黑白"，量的就是这一条）。改这里必须同时升 ChartCache 键盐。
{
  const mm = fs.readFileSync(path.join(ROOT, 'entry/src/main/resources/rawfile/render/mermaid.html'), 'utf8');
  const init = /theme:dark\?'dark':'default'/.test(mm);
  if (init) {
    console.log('  ok    mermaid 浅色主题 = default（时序图参与者淡紫，与导出网页同口径）');
  } else {
    fails++;
    console.log('  FAIL  mermaid 浅色主题不是 default：neutral 会把参与者框画成灰框黑字');
  }
  const salt = fs.readFileSync(path.join(ROOT, 'entry/src/main/ets/service/ChartCache.ets'), 'utf8');
  if (/['"]v20\|['"]/.test(salt)) {
    console.log('  ok    缓存键盐已随主题升级（旧主题烘出的灰框 PNG 不会留在机上）');
  } else {
    fails++;
    console.log('  FAIL  改了 mermaid 主题但没升 ChartCache 键盐 → 卡片读旧图、放大才更新');
  }
}

console.log('清单 → ' + OUT);
console.log(fails === 0 ? 'CHART TEMPLATES OK' : 'CHART TEMPLATES FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
