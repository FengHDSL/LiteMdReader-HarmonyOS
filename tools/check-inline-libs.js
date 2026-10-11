// 内联库一致性验证器：
// 对 rawfile/render/*.html 里内联的每个开源库，与 tools/runtimes/ 的源文件比对，
// 确认"html 内联文本 == 源库文件全文"——这决定升级时能否用「精确文本替换法」
// （只换库文本、不动其它手工修改，比如 katex.html 的 normalize/renderBg 逻辑）。
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const RENDER = path.join(ROOT, 'entry/src/main/resources/rawfile/render');
const RUN = path.join(__dirname, 'runtimes');

const libs = fs.readdirSync(RUN)
  .filter(f => (f.endsWith('.js') || f.endsWith('.css')))
  .map(f => ({ name: f, text: fs.readFileSync(path.join(RUN, f), 'utf8') }));

let problems = 0;
for (const html of fs.readdirSync(RENDER).filter(f => f.endsWith('.html'))) {
  const doc = fs.readFileSync(path.join(RENDER, html), 'utf8');
  const hits = [];
  for (const lib of libs) {
    const head = lib.text.slice(0, 240);
    if (doc.indexOf(head) >= 0) {
      const full = doc.indexOf(lib.text) >= 0;
      hits.push(lib.name + (full ? ' [FULL]' : ' [HEAD-ONLY!]'));
      if (!full) { problems++; }
    }
  }
  console.log(html.padEnd(18), '←', hits.length > 0 ? hits.join(', ') : '(no lib matched)');
}
console.log(problems === 0 ? '\nALL FULL MATCH — 文本替换法可用' : '\n有 ' + problems + ' 处仅头部匹配，需人工核对');
