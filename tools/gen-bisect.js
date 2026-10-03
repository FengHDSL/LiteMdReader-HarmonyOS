// viz2 冲突二分：通过 LIBS 环境变量选择加载哪些库
const fs = require('fs');
const path = require('path');
const R = p => fs.readFileSync(path.join(__dirname, 'runtimes', p), 'utf8');
const which = (process.env.LIBS || 'all').split(',');
const has = k => which.includes(k) || which.includes('all');
const needExec = which.includes('exec');

const headLibs = [];
if (has('mermaid')) { headLibs.push(R('mermaid.min.js')); }
if (has('echarts')) { headLibs.push(R('echarts.min.js')); }
if (has('katex')) { headLibs.push(R('katex.min.js')); }
if (has('abcjs')) { headLibs.push(R('abcjs.min.js')); }
if (has('d3')) { headLibs.push(R('d3.min.js')); }
if (has('mmlib')) { headLibs.push(R('markmap-lib.js')); }
if (has('mmview')) { headLibs.push(R('markmap-view.js')); }

const bodyViz = has('viz2')
  ? '<script>' + R('viz2.js') + '</script><script>' + R('viz2-full.render.js') + '</script>'
  : (has('viz3')
    ? '<script>' + R('viz-standalone.js') + '</script>'
    : '');

const html = `<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>
<div class="gv" id="gv-0"></div>
<script type="text/plain" id="gv-src-0">digraph G { rankdir=LR; a -> b -> c; }</script>
${headLibs.map(s => '<script>' + s + '</script>').join('\n')}
${bodyViz}
<script>
(async () => {
  window.__log = [];
  const exec = true;
  try {
    if (exec) {
      if (window.mermaid) { mermaid.initialize({ startOnLoad: false }); await mermaid.run(); }
      if (window.katex) { katex.render('E=mc^2', document.body.appendChild(document.createElement('div')), { displayMode: true }); }
      if (window.echarts) { echarts.init(document.createElement('div')).setOption({ xAxis: { type: 'category', data: ['a'] }, yAxis: {}, series: [{ type: 'bar', data: [1] }] }); }
      if (window.d3 && window.markmap && markmap.Transformer && markmap.Markmap) {
        const r = await new markmap.Transformer().transform('# r\\n## a');
        markmap.Markmap.create(document.createElement('div'), null, r.root || r);
      }
      if (window.ABCJS) { ABCJS.renderAbc(document.createElement('div'), 'CDEF'); }
      __log.push('other renders done');
    }
    __log.push('Viz: ' + typeof Viz);
    const v = new Viz();
    const svg = await v.renderString(document.getElementById('gv-src-0').textContent, { format: 'svg' });
    __log.push('render ok len=' + svg.length);
    document.getElementById('gv-0').innerHTML = svg;
  } catch (e) { __log.push('ERR: ' + (e.stack || e.message).slice(0, 300)); }
})();
</script></body></html>`;
fs.writeFileSync(path.join(__dirname, 'bisect.html'), html);
console.log('LIBS=' + which.join(',') + ' size=' + (html.length / 1024).toFixed(0) + 'KB');
