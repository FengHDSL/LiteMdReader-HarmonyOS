// flowchart + graphviz + 全量库共存终极测试
const fs = require('fs');
const path = require('path');
const R = p => fs.readFileSync(path.join(__dirname, 'runtimes', p), 'utf8');
const B64 = t => Buffer.from(t, 'utf-8').toString('base64');

const libOrder = ['d3.min.js', 'markmap-lib.js', 'markmap-view.js', 'mermaid.min.js',
  'echarts.min.js', 'katex.min.js', 'abcjs.min.js', 'jquery.min.js', 'raphael.min.js',
  'flowchart.min.js', 'viz2.js', 'viz2-full.render.js'];
let headLibs = '';
for (const f of libOrder) {
  headLibs += '<script>\n' + R(f).split('</script>').join('<\\/script') + '\n</script>\n';
}
let katexCss = R('katex.min.css');
const cc = (cls, code, style) => '<div class="' + cls + '" data-b64="' + B64(code) + '"' + (style ? ' style="' + style + '"' : '') + '></div>';

const runner = `
<script>
(function() {
  function b64u(b64) { var bin = atob(b64); var u = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) { u[i] = bin.charCodeAt(i); } return new TextDecoder().decode(u); }
  function tryRun(fn) { try { fn(); } catch (e) { console.error("chart render failed", e); } }
  window.addEventListener("load", function() {
    if (window.markmap && markmap.Transformer && markmap.Markmap) {
      document.querySelectorAll(".markmap").forEach(async function(el) {
        try {
          var r = await new markmap.Transformer().transform(b64u(el.dataset.b64));
          el.innerHTML = "";
          var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
          el.appendChild(svg);
          markmap.Markmap.create(svg, null, r.root || r);
        } catch (e) { console.error("markmap render failed", e); }
      });
    }
    if (window.mermaid) {
      tryRun(function() { mermaid.initialize({ startOnLoad: false }); });
      document.querySelectorAll(".mermaid").forEach(async function(el, i) {
        try {
          var r = await mermaid.render("mmd" + i, b64u(el.dataset.b64));
          el.innerHTML = r.svg;
        } catch (e) { console.error("mermaid render failed", e); }
      });
    }
    if (window.katex) {
      document.querySelectorAll(".ktx").forEach(function(el) {
        tryRun(function() { katex.render(b64u(el.dataset.b64), el, { displayMode: true, throwOnError: false }); });
      });
    }
    if (window.echarts) {
      document.querySelectorAll(".ech").forEach(function(el) {
        tryRun(function() { var opt = (new Function("return (" + b64u(el.dataset.b64) + ")"))(); echarts.init(el).setOption(opt); });
      });
    }
    if (window.ABCJS) {
      document.querySelectorAll(".abc").forEach(function(el) {
        tryRun(function() { ABCJS.renderAbc(el, b64u(el.dataset.b64)); });
      });
    }
    if (window.Viz) {
      document.querySelectorAll(".gv").forEach(async function(el) {
        try {
          var svg = await new Viz().renderString(b64u(el.dataset.b64), { format: "svg" });
          el.innerHTML = svg;
        } catch (e) { console.error("graphviz render failed", e); }
      });
    }
    var renderFlowcharts = function() {
      document.querySelectorAll(".flowchart").forEach(function(el) {
        if (el.dataset.done) { return; }
        try {
          var chart = window.flowchart.parse(b64u(el.dataset.b64));
          el.innerHTML = "";
          var id = "fc" + Math.floor(Math.random() * 100000);
          var holder = document.createElement("div");
          holder.id = id;
          el.appendChild(holder);
          chart.drawSVG(id);
          el.dataset.done = "1";
        } catch (e) { console.error("flowchart render failed", e); }
      });
    };
    renderFlowcharts();
    setTimeout(renderFlowcharts, 300);
    setTimeout(renderFlowcharts, 1000);
  });
})();
</script>
`;

const html = `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"/>
<style>body { margin: 0 auto; max-width: 820px; padding: 24px; font-family: sans-serif; }
.markmap { width: 100%; height: 420px; } .mermaid,.ktx,.abc,.flowchart { width: 100%; overflow-x: auto; text-align: center; }
.gv { width: 100%; min-height: 200px; overflow-x: auto; }</style>
` + headLibs + `
</head><body>
<h1>终极共存测试</h1>
<h2>markmap</h2>` + cc('markmap', '# 脑图\n## 分支一\n## 分支二') + `
<h2>mermaid</h2>` + cc('mermaid', 'graph TD\n  A[开始] --> B{判断}\n  B -->|是| C[执行]') + `
<h2>katex</h2>` + cc('ktx', 'E = mc^2') + `
<h2>echarts</h2>` + cc('ech', '{"xAxis":{"type":"category","data":["一","二"]},"yAxis":{},"series":[{"data":[150,230],"type":"bar"}]}', 'width:100%;height:420px') + `
<h2>abc</h2>` + cc('abc', 'X:1\nT:Scale\nM:4/4\nK:C\nCDEF GABc|') + `
<h2>graphviz</h2>` + cc('gv', 'digraph G { rankdir=LR; a -> b -> c; }') + `
<h2>flowchart</h2>` + cc('flowchart', 'st=>start: 开始\ne=>end: 结束\nop=>operation: 处理\nst->op->e') + `
` + runner + `
</body></html>`;

fs.writeFileSync(path.join(__dirname, 'ultimate-test.html'), html);
console.log('written ultimate-test.html, size =', (html.length / 1024).toFixed(0), 'KB');
