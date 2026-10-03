// flowchart→mermaid 转换器验证（与 ArkTS flowchartToMermaid 同逻辑）
const fs = require('fs');
const path = require('path');
const R = p => fs.readFileSync(path.join(__dirname, 'runtimes', p), 'utf8');
const B64 = t => Buffer.from(t, 'utf-8').toString('base64');

function flowchartToMermaid(code) {
  const lines = code.split('\n');
  const types = {}; const texts = {}; const edges = []; const used = [];
  for (const t0 of lines) {
    const t = t0.trim();
    const arrow = t.indexOf('=>');
    if (arrow <= 0) continue;
    const id = t.substring(0, arrow).trim();
    const rest = t.substring(arrow + 2).trim();
    const colon = rest.indexOf(':');
    const type = (colon >= 0 ? rest.substring(0, colon) : rest).trim().toLowerCase();
    const text = (colon >= 0 ? rest.substring(colon + 1).trim() : '').replace(/"/g, '');
    types[id] = type; texts[id] = text;
  }
  const fcNode = id => {
    const type = types[id] !== undefined ? types[id] : 'operation';
    const text = texts[id] !== undefined && texts[id].length > 0 ? texts[id] : id;
    const clean = text.replace(/\|/g, '/');
    if (type === 'start' || type === 'end') return id + '(["' + clean + '"])';
    if (type === 'condition') return id + '{"' + clean + '"}';
    if (type === 'subroutine') return id + '[["' + clean + '"]]';
    if (type === 'inputoutput') return id + '[/"' + clean + '"/]';
    return id + '["' + clean + '"]';
  };
  for (const t0 of lines) {
    const t = t0.trim();
    if (t.length === 0 || t.indexOf('->') <= 0) continue;
    const parts = t.split('->');
    for (let i = 0; i + 1 < parts.length; i++) {
      let from = parts[i].trim(); let to = parts[i + 1].trim(); let label = '';
      const pm = from.match(/^([A-Za-z0-9_]+)\(([^)]*)\)$/);
      if (pm) { from = pm[1]; label = pm[2].trim(); }
      const tc = to.indexOf(':');
      if (tc > 0) { label = to.substring(tc + 1).trim(); to = to.substring(0, tc).trim(); }
      const tm = to.match(/^([A-Za-z0-9_]+)\(([^)]*)\)$/);
      if (tm) { to = tm[1]; if (label.length === 0) label = tm[2].trim(); }
      if (!from || !to) continue;
      if (types[from] === undefined) { types[from] = 'operation'; texts[from] = from; }
      if (types[to] === undefined) { types[to] = 'operation'; texts[to] = to; }
      if (!used.includes(from)) used.push(from);
      if (!used.includes(to)) used.push(to);
      edges.push(label.length > 0
        ? fcNode(from) + ' -->|' + label.replace(/\|/g, '/') + '| ' + fcNode(to)
        : fcNode(from) + ' --> ' + fcNode(to));
    }
  }
  let out = 'flowchart TD';
  for (const id of used) out += '\n  ' + fcNode(id);
  for (const e of edges) out += '\n  ' + e;
  return out;
}

const fcCode = `st=>start: 开始
e=>end: 结束
op=>operation: 处理数据
cond=>condition: 是否合法？
sub=>subroutine: 子流程
io=>inputoutput: 输出结果
st->op->cond
cond(yes)->io
cond(no)->sub
sub->op`;
const converted = flowchartToMermaid(fcCode);
console.log('converted:\n' + converted);

const cc = (cls, code) => '<div class="' + cls + '" data-b64="' + B64(code) + '"></div>';
const html = `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"/>
<style>body{margin:0 auto;max-width:820px;padding:24px;font-family:sans-serif}
.mermaid{width:100%;overflow-x:auto}</style>
<script>${R('mermaid.min.js').split('</script>').join('<\\/script')}</script>
</head><body>
<h1>flowchart → mermaid 转换渲染</h1>
${cc('mermaid', converted)}
<script>
mermaid.initialize({ startOnLoad: false });
window.addEventListener("load", async function() {
  document.querySelectorAll(".mermaid").forEach(async function(el, i) {
    try {
      var r = await mermaid.render("mmd" + i, b64u(el.dataset.b64));
      el.innerHTML = r.svg;
    } catch (e) { console.error("mermaid failed", e); }
  });
});
function b64u(b64) { var bin = atob(b64); var u = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) { u[i] = bin.charCodeAt(i); } return new TextDecoder().decode(u); }
</script>
</body></html>`;
fs.writeFileSync(path.join(__dirname, 'fc-test.html'), html);
console.log('written fc-test.html');
