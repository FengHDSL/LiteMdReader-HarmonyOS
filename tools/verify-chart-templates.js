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
  if (/['"]v23\|['"]/.test(salt)) {
    console.log('  ok    缓存键盐已随主题升级（旧主题烘出的灰框 PNG 不会留在机上）');
  } else {
    fails++;
    console.log('  FAIL  改了 mermaid 主题 / PlantUML 内核 / ZenUML 引擎但没升 ChartCache 键盐 → 卡片读旧图、放大才更新');
  }
}

// zenuml.html（6.56MB）与 mermaid-zenuml 插件（3.14MB）**已删除**：插件与随包
// mermaid 11.17.2 内部约定错位、真机必报 Syntax error，改用 ZenumlBridge 纯文本转译。
// 这条断言防止它们被误加回包里（体积一夜翻倍的元凶就是这一对）。
{
  const zuPath = path.join(ROOT, 'entry/src/main/resources/rawfile/render/zenuml.html');
  const zuRt = path.join(ROOT, 'entry/src/main/resources/rawfile/runtimes/mermaid-zenuml.min.js');
  if (fs.existsSync(zuPath) || fs.existsSync(zuRt)) {
    fails++;
    console.log('  FAIL  zenuml 插件资产又回包里了（zenuml.html / mermaid-zenuml.min.js 应已删除，'
      + 'zenuml 走 ZenumlBridge 纯文本转译）');
  } else {
    console.log('  ok    zenuml 插件资产已移除（不再随包；转译链路在 ZenumlBridge）');
  }
}

console.log('清单 → ' + OUT);
// ════ 模板脚本语法体检（2026-10-14 真实事故：mermaid.html 里一条 // 行注释把整条
// mermaid.initialize(...) 连同 }); 一起吃光 → 脚本语法错误 → **mermaid 全图种不可用**。
// 这类事故只要把每个 <script> 丢给 vm.Script 编译一次就能当场抓住，成本近乎为零。）════
(function syntaxSweep() {
  const vm = require('vm');
  const dir = path.join(ROOT, 'entry/src/main/resources/rawfile/render');
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.html'));
  let bad = 0;
  for (const f of files) {
    const html = fs.readFileSync(path.join(dir, f), 'utf8');
    const blocks = html.match(/<script>[\s\S]*?<\/script>/g) || [];
    blocks.forEach((b, idx) => {
      const code = b.replace(/^<script>/, '').replace(/<\/script>$/, '');
      try {
        new vm.Script(code, { filename: f + '#script' + (idx + 1) });
      } catch (e) {
        bad++;
        fails++;
        console.log('  FAIL  ' + f + ' 第 ' + (idx + 1) + ' 段脚本语法错误：' + String(e.message).split('\n')[0]);
      }
    });
  }
  if (bad === 0) {
    console.log('  ok    全部 ' + files.length + ' 个渲染模板的脚本段语法可编译（防"注释吃行"这类整页崩）');
  }
})();

// PlantUML 两条硬约束（都是真机/真导出实测踩出来的，别再退回去）：
//   ① 内核必须是**普通脚本**：它是全部模板里唯一一页 module，真机上整族画不出
//      （2026-10-14 事故：桌面浏览器全正常，手机上用例/活动/组件/部署/mindmap/WBS/
//       甘特/JSON/YAML/Archimate/ER 全退回显示源码）。
//   ② 导出用的内核运行时两份拷贝必须逐字一致（tools/gen-plantuml-template.js 一次写两份，
//      漂移了就是"阅读页能画、导出画不出"这种最难查的分裂）。
{
  const tpl = fs.readFileSync(path.join(ROOT, 'entry/src/main/resources/rawfile/render/plantuml.html'), 'utf8');
  // 只看真正的开标签，注释里提一句 "type=module" 不算
  const moduleTag = /<script[^>]*\stype=["']module["']/i.test(tpl);
  if (!moduleTag) {
    console.log('  ok    plantuml.html 内核是普通脚本（module 版在真机上整族画不出）');
  } else {
    fails++;
    console.log('  FAIL  plantuml.html 又用回 type="module" 了 → 真机 PlantUML 全族失效，跑 node tools/gen-plantuml-template.js');
  }
  const a = path.join(ROOT, 'entry/src/main/resources/rawfile/runtimes/plantuml-kernel.js');
  const b = path.join(ROOT, 'tools/runtimes/plantuml-kernel.js');
  if (!fs.existsSync(a) || !fs.existsSync(b)) {
    fails++;
    console.log('  FAIL  内核运行时缺一份（rawfile/runtimes 或 tools/runtimes）→ 导出会没有 PlantUML');
  } else {
    const sa = fs.readFileSync(a), sb = fs.readFileSync(b);
    if (sa.length === sb.length && sa.equals(sb)) {
      console.log('  ok    导出内核运行时两份拷贝一致（' + (sa.length / 1048576).toFixed(2) + 'MB）');
    } else {
      fails++;
      console.log('  FAIL  导出内核运行时两份拷贝不一致 → 重跑 tools/gen-plantuml-template.js');
    }
  }
}

console.log(fails === 0 ? 'CHART TEMPLATES OK' : 'CHART TEMPLATES FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
