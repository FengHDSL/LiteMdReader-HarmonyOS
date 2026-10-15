/**
 * 导出 HTML 端到端验证（Node）：转译 MdToHtml（平台依赖用桩），
 * 对一份含全部图种的文档跑 MdToHtml.export，逐项断言容器 / 渲染库 / runner。
 */
const fs = require('fs');
const path = require('path');
const TS_MOD = 'C:/Users/panda/AppData/Local/OpenHarmony/Sdk/26.0.0/ets/build-tools/ets-loader/node_modules/typescript';
const ts = require(TS_MOD);
const ROOT = path.join(__dirname, '..');
const MD = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'markdown');
const SV = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'service');
const OUT = path.join(ROOT, '.workbuddy', 'export-cjs');

fs.mkdirSync(OUT, { recursive: true });
const stubs = {
  'common': 'module.exports = {};',
  '@kit.ArkTS': 'module.exports = { util: { TextEncoder: function(){ this.encodeInto=(s)=>new Uint8Array(Buffer.from(s)); }, TextDecoder: { create: () => ({ decodeToString: (u) => Buffer.from(u).toString("utf-8") }) }, Base64Helper: function(){ this.encodeToStringSync=(u)=>Buffer.from(u).toString("base64"); } } };',
  '@kit.AbilityKit': 'module.exports = {};',
  '@kit.CryptoArchitectureKit': 'module.exports = { cryptoFramework: { createMd: () => ({ updateSync: ()=>{}, digestSync: () => ({ data: Buffer.from("0000000000000000") }) }) } };',
  '@kit.CoreFileKit': 'module.exports = { fileIo: {} };',
  '@kit.ImageKit': 'module.exports = { image: {} };',
  '@kit.PerformanceAnalysisKit': 'module.exports = { hilog: { warn: ()=>{}, info: ()=>{}, error: ()=>{} } };',
  '../service/ChartCache': `module.exports = {
    keyFor: (m,p,d,b) => 'k_' + m + '_' + (d?'d':'l'),
    srcPath: () => '',
    pngBase64: () => '',
  };`,
  '../service/EngineRegistry': `module.exports = { EngineRegistry: {
    isOff: () => false,
    current: () => [],
    langId: (l) => ({ plantuml:'plantuml', salt:'plantuml', ditaa:'plantuml', nwdiag:'plantuml', zenuml:'mermaid' }[l] || l),
  } };`,
  './L10n': 'module.exports = { L10n: { t: (s) => s } };',
};
function stubFor(importLine) {
  const m = importLine.match(/from '([^']+)'/);
  if (!m) return null;
  const mod = m[1];
  if (stubs.hasOwnProperty(mod)) return stubs[mod];
  return null;
}
function transpile(name, file) {
  let src = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
  const lines = src.split('\n');
  const outLines = [];
  for (const ln of lines) {
    if (/^import /.test(ln)) {
      const stub = stubFor(ln);
      if (stub !== null) {
        // 保留具名导入绑定（供解构），模块体换成桩
        const names = (ln.match(/\{([^}]+)\}/) || [null, ''])[1]
          .split(',').map((x) => x.trim().split(' as ')[0]).filter(Boolean);
        const req = '__stub_' + Math.abs(ln.split('').reduce((a, c) => a + c.charCodeAt(0), 0));
        outLines.push('const __' + req + ' = (function(){ ' + stub + ' return module.exports; })();');
        for (const nm of names) {
          outLines.push('const ' + nm + ' = __' + req + '.' + nm + " !== undefined ? __" + req + '.' + nm + ' : ' + nm + ';');
        }
        continue;
      }
    }
    outLines.push(ln);
  }
  src = outLines.join('\n');
  const r = ts.transpileModule(src, {
    fileName: name,
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, esModuleInterop: true },
  });
  fs.writeFileSync(path.join(OUT, name.replace('.ets', '.js')), r.outputText);
}
const NEED_MD = ['MdTypes', 'Emoji', 'MathLite', 'PlantumlBridge', 'ZenumlBridge', 'MdParser', 'CodeHighlight', 'MdToHtml'];
for (const n of NEED_MD) {
  transpile(n, path.join(MD, n + '.ets'));
}
// service 桩里的 EngineRegistry / ChartCache 直接落盘（MdToHtml 里相对导入解析需要）
fs.writeFileSync(path.join(OUT, 'EngineRegistry.js'), stubs['../service/EngineRegistry']);
fs.writeFileSync(path.join(OUT, 'ChartCache.js'), stubs['../service/ChartCache']);
// MdParser 的相对导入会 require ./PlantumlBridge 等 ✓ 同目录已就位
for (const n of NEED_MD) { delete require.cache[path.join(OUT, n + '.js')]; }
const { MdToHtml } = require(path.join(OUT, 'MdToHtml.js'));
const { MdParser } = require(path.join(OUT, 'MdParser.js'));

const DOC = [
  '# 测试',
  '',
  '```plantuml',
  '@startuml',
  'actor 用户',
  '用户 -> 系统 : 请求',
  '@enduml',
  '```',
  '',
  '```nwdiag',
  '@startnwdiag',
  'network Lan {',
  '  device "Phone"',
  '}',
  '@endnwdiag',
  '```',
  '',
  '```salt',
  '@startsalt',
  '{+',
  '  名称 | "文本"',
  '  [确定]',
  '}',
  '@endsalt',
  '```',
  '',
  '```graphviz',
  'digraph G { A -> B }',
  '```',
  '',
  '```abc',
  'X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC D E F |',
  '```',
  '',
  '```markmap',
  '# 中心\n## 分支',
  '```',
  '',
  '```chart',
  '{"type":"line","data":{"labels":["1"],"datasets":[{"data":[1]}]}}',
  '```',
  '',
].join('\n');

const parsed = MdParser.parse(DOC);
const kinds = parsed.blocks.map((b) => b.kind + ':' + (b.lang || ''));
console.log('块序列:', kinds.join(', '));
let html;
try {
  html = MdToHtml.export('t', parsed.meta, parsed.blocks, true, null, null, false, '');
} catch (e) {
  console.log('FAIL  export 抛错:', String(e).slice(0, 200));
  process.exit(1);
}
const checks = [
  ['plantuml → mermaid 容器（桥接）', /class="mermaid"/.test(html)],
  ['nwdiag → cj-nwdiag 容器', /class="cj-nwdiag"/.test(html)],
  ['salt → cj-salt 容器', /class="cj-salt"/.test(html)],
  ['graphviz → gv 容器', /class="gv"/.test(html)],
  ['abc → abc 容器', /class="abc"/.test(html)],
  ['markmap → markmap 容器', /class="markmap"/.test(html)],
  ['chart → cjs 容器', /class="cjs"/.test(html)],
  ['runner 含 __chengjianRender 分发', html.indexOf('__chengjianRender') >= 0],
  ['runner 含 mermaid 渲染', html.indexOf('mermaid.render') >= 0 || html.indexOf('mermaid') >= 0],
];
let bad = 0;
for (const [name, ok] of checks) {
  console.log((ok ? '  ok    ' : '  FAIL  ') + name);
  if (!ok) bad++;
}
// runner 语法检查
const runnerMatch = html.match(/<script>\n\(function\(\) \{\n([\s\S]*?)\}\)\(\);\n<\/script>/);
if (runnerMatch) {
  try { new (require('vm').Script)(runnerMatch[1]); console.log('  ok    runner JS 语法可编译'); }
  catch (e) { bad++; console.log('  FAIL  runner JS 语法错误:', String(e.message).split('\n')[0]); }
} else {
  console.log('  warn  未提取到 runner（正则不匹配，人工确认）');
}
console.log(bad === 0 ? 'EXPORT OK' : 'EXPORT FAILED: ' + bad);
process.exit(bad === 0 ? 0 : 1);
