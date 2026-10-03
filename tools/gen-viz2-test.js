// viz.js 2.x 与 mermaid/echarts 共存测试
const fs = require('fs');
const path = require('path');
const R = p => fs.readFileSync(path.join(__dirname, 'runtimes', p), 'utf8');
const html = `<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>
<div class="gv" id="gv-0"></div>
<script type="text/plain" id="gv-src-0">digraph G { rankdir=LR; a -> b -> c; }</script>
<script>${R('mermaid.min.js')}</script>
<script>${R('echarts.min.js')}</script>
<script>${R('viz2.js')}</script>
<script>${R('viz2-full.render.js')}</script>
<script>
(async () => {
  window.__log = [];
  try {
    __log.push('Viz: ' + typeof Viz);
    const v = new Viz();
    const svg = await v.renderString(document.getElementById('gv-src-0').textContent, { format: 'svg' });
    __log.push('render ok len=' + svg.length);
    document.getElementById('gv-0').innerHTML = svg;
  } catch (e) { __log.push('ERR: ' + (e.stack || e.message)); }
})();
</script></body></html>`;
fs.writeFileSync(path.join(__dirname, 'viz2-test.html'), html);
console.log('written', html.length);
