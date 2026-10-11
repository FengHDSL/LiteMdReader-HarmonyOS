// Validate rawfile/chengjian.md's math against the app's own KaTeX build and
// the app's own parser rules (MdParser): inline `$` must not start with a space,
// and a line ending in a single `$` with an ODD dollar count triggers
// mergeCrossLineDollar() and can swallow the following lines.
const fs = require('fs');
const path = require('path');
const katex = require('../entry/src/main/resources/rawfile/runtimes/katex.min.js');

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
      katex.renderToString(f.src, {
        displayMode: mode === 'display', throwOnError: true, output: 'html', strict: 'error',
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
