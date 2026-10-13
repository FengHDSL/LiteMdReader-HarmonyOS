// Validate rawfile/chengjian.md's math against the app's own KaTeX build and
// the app's own parser rules (MdParser): inline `$` must not start with a space,
// and a line ending in a single `$` with an ODD dollar count triggers
// mergeCrossLineDollar() and can swallow the following lines.
const fs = require('fs');
const path = require('path');
const vm = require('vm');

/**
 * **按 app 的真实加载方式取 KaTeX**，而不是 `require()`。
 *
 * 阅读页用 render/katex.html（里面 KaTeX 与 mhchem 两份 UMD 都已内联）；导出页则按
 * ChartRuntimeService.filesForLang('katex') 的顺序把 rawfile/runtimes 下的
 * katex.min.js → katex.min.css → **mhchem.min.js** 拼进 HTML。
 * mhchem 是"注册到当时已存在的 katex 对象上"的扩展，所以**必须先 katex 后 mhchem**。
 * 这里照同样的顺序、在同一个沙箱里跑，测的就是产品真正会用的那套。
 *
 * ⚠️ 不用 `require()`：Node 的模块环境会让 mhchem 那段 UMD 去找 `require('katex')`
 * （包里没这个模块名），注册悄悄失败，然后每一条化学式都报 "Undefined control sequence"
 * ——那是工具的假警报（浏览器里实测同一份 katex.html 渲染 `\ce{}` 是无错的）。
 */
function loadKatexLikeApp() {
  const dir = path.join(__dirname, '../entry/src/main/resources/rawfile');
  const sandbox = { console };
  sandbox.window = sandbox;
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(dir, 'runtimes/katex.min.js'), 'utf8'),
    sandbox, { filename: 'katex.min.js' });
  const mhchemPath = path.join(dir, 'runtimes/mhchem.min.js');
  if (!fs.existsSync(mhchemPath)) {
    throw new Error('缺 rawfile/runtimes/mhchem.min.js —— 导出的化学式会全红');
  }
  vm.runInContext(fs.readFileSync(mhchemPath, 'utf8'), sandbox, { filename: 'mhchem.min.js' });
  const k = sandbox.katex;
  if (k === undefined || typeof k.renderToString !== 'function') {
    throw new Error('KaTeX 没能挂到沙箱全局：这份 bundle 的加载方式又变了');
  }
  return k;
}

const katex = loadKatexLikeApp();

/** 阅读页那份模板也必须带着 mhchem（重新生成模板时最容易把它弄丢） */
const readerTemplate = fs.readFileSync(
  path.join(__dirname, '../entry/src/main/resources/rawfile/render/katex.html'), 'utf8');
const templateHasMhchem = readerTemplate.split('require("katex")').length >= 2
  || readerTemplate.indexOf('mhchem') >= 0;
if (!templateHasMhchem) {
  console.log('DOC MATH FAILED: render/katex.html 里没有 mhchem —— 阅读页的化学式会全红');
  process.exit(1);
}

/** 导出侧的内联清单也要带上 mhchem（ExportService / PrintService 都读这张表） */
const runtimeSvc = fs.readFileSync(
  path.join(__dirname, '../entry/src/main/ets/service/ChartRuntimeService.ets'), 'utf8');
const katexFiles = (/lang === 'katex'\)\s*\{[\s\S]{0,400}?return \[([^\]]*)\]/.exec(runtimeSvc) || ['', ''])[1];
if (katexFiles.indexOf('mhchem.min.js') < 0) {
  console.log('DOC MATH FAILED: filesForLang("katex") 没列 mhchem.min.js —— 导出的网页化学式会全红');
  process.exit(1);
}
if (katexFiles.indexOf('katex.min.js') > katexFiles.indexOf('mhchem.min.js')) {
  console.log('DOC MATH FAILED: mhchem 排在 katex 之前 —— 它注册不到 katex 对象上');
  process.exit(1);
}

/**
 * 先确认 mhchem 真的在（\ce 能渲染）：否则后面每一条化学式都会报"未知控制序列"，
 * 把工具故障伪装成文档故障。
 */
const mhchemProbe = (() => {
  try {
    const h = katex.renderToString('\\ce{H2O}', {
      displayMode: false, throwOnError: true, output: 'html'
    });
    return h.indexOf('katex-error') < 0;
  } catch (e) {
    // 别把原因咽掉：这条探针失败通常是工具环境问题，不是文档问题
    console.log('mhchem 探针异常：' + String(e.message).slice(0, 120));
    return false;
  }
})();
if (!mhchemProbe) {
  console.log('DOC MATH FAILED: mhchem(\\ce) 没注册 —— 先修 runtimes/katex.min.js 的拼接，再谈文档');
  process.exit(1);
}

const file = path.join(__dirname, '../entry/src/main/resources/rawfile/chengjian.md');
const lines = fs.readFileSync(file, 'utf8').replace(/\r\n?/g, '\n').split('\n');

const problems = [];
const display = [];
const inline = [];

let inFence = false;
let fenceCh = '';
let inBlockMath = false;
let buf = [];

for (let i = 0; i < lines.length; i++) {
  const raw = lines[i];
  const t = raw.trim();

  if (inFence) {
    if (t.startsWith(fenceCh)) { inFence = false; fenceCh = ''; }
    continue;
  }
  if (t.startsWith('```') || t.startsWith('~~~')) {
    if (inBlockMath) { problems.push(`L${i + 1}: fence opened inside an unclosed $$ block`); inBlockMath = false; buf = []; }
    inFence = true; fenceCh = t.startsWith('~~~') ? '~~~' : '```';
    continue;
  }

  if (t === '$$') {
    if (inBlockMath) {
      display.push({ line: i + 1, src: buf.join('\n') });
      buf = []; inBlockMath = false;
    } else {
      inBlockMath = true; buf = [];
    }
    continue;
  }
  if (inBlockMath) { buf.push(raw); continue; }

  // --- inline scanning (single $...$ only) ---
  // Backtick code spans win over `$` in MdParser (inline code handled at
  // MdParser.ets:1084, math at :1128), so blank them out before counting.
  const noCode = raw.replace(/`[^`]*`/g, ' ');
  let dollars = 0;
  for (const ch of noCode) if (ch === '$') dollars++;
  const stripped = noCode.replace(/\$\$[^$]*\$\$/g, ' ');   // drop same-line $$..$$
  const re = /\$([^$]+)\$/g;
  let m;
  while ((m = re.exec(stripped)) !== null) {
    inline.push({ line: i + 1, src: m[1] });
    if (/^\s/.test(m[1]) || /\s$/.test(m[1])) {
      problems.push(`L${i + 1}: inline math has a leading/trailing space (parser will skip it): $${m[1]}$`);
    }
  }
  const noWs = noCode.replace(/\s+$/, '');
  if (dollars % 2 === 1 && noWs.endsWith('$') && !noWs.endsWith('$$')) {
    problems.push(`L${i + 1}: odd $ count and ends with a single $ -> mergeCrossLineDollar may swallow following lines: ${raw}`);
  }
  if (dollars % 2 === 1) {
    problems.push(`L${i + 1}: unbalanced $ (${dollars}) in: ${raw}`);
  }
}
if (inBlockMath) problems.push('EOF: unclosed $$ block');

function render(list, mode) {
  for (const f of list) {
    try {
      // 选项与 katex.html 的 __render 对齐（displayMode 按块/行内、output:'html'、
      // throwOnError 这里设 true 好让校验器报错；**不加 strict:'error'**——app 没设，
      // 而且 mhchem 的 `[点燃]` 这类中文反应条件在 strict:'error' 下会被判成
      // "Unicode in math mode"，那是校验器自己在发明 app 并不存在的限制）。
      katex.renderToString(f.src, {
        displayMode: mode === 'display', throwOnError: true, output: 'html',
      });
    } catch (e) {
      problems.push(`KaTeX FAIL [${mode}] L${f.line}: ${f.src.replace(/\n/g, ' ').slice(0, 90)}\n    -> ${e.message}`);
    }
  }
}
render(display, 'display');
render(inline, 'inline');

console.log(`blocks=${display.length} inline=${inline.length} formulas checked`);
if (problems.length === 0) console.log('DOC MATH OK');
else { console.log('\n' + problems.length + ' PROBLEM(S):'); problems.forEach(p => console.log('  - ' + p)); }
process.exit(problems.length ? 1 : 0);
