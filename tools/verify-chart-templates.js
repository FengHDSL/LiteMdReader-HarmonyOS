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
// 卡片模式的限高：纵向长的图（状态图 141×894 这类）必须被 contain 进框内，
// 否则宿主按 3500+px 的高度钉卡片，"全图"与"大小合适"两头都丢（用户实测）。
// 规则与正文图片路径 chartCardMaxHeight（340～600，随卡宽）保持一致。
{
  const mm = fs.readFileSync(path.join(ROOT, 'entry/src/main/resources/rawfile/render/mermaid.html'), 'utf8');
  const capped = /maxHeight='clamp\(340px, 100vw, 600px\)'/.test(mm);
  if (capped) { console.log('  ok    mermaid 卡片模式有纵向限高（与 chartCardMaxHeight 同区间）'); }
  else { fails++; console.log('  FAIL  mermaid 卡片模式丢了纵向限高：长图会把卡片撑到几千 vp'); }
}

console.log('清单 → ' + OUT);
console.log(fails === 0 ? 'CHART TEMPLATES OK' : 'CHART TEMPLATES FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
