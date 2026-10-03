// data-b64 版导出 HTML 生成与验证（与 ArkTS MdToHtml 结构一致）
const fs = require('fs');
const path = require('path');
const R = p => fs.readFileSync(path.join(__dirname, 'runtimes', p), 'utf8');
const B64 = t => Buffer.from(t, 'utf-8').toString('base64');

// 库内联（</script> 转义，与 ExportService 内联逻辑一致）
const libFiles = ['d3.min.js', 'markmap-lib.js', 'markmap-view.js',
  'mermaid.min.js', 'echarts.min.js', 'katex.min.js', 'abcjs.min.js'];
let headLibs = '';
for (const f of libFiles) {
  headLibs += '<script>\n' + R(f).split('</script>').join('<\\/script') + '\n</script>\n';
}
// katex css + 字体 data-uri（与 ExportService 替换逻辑一致）
let katexCss = R('katex.min.css');
const fonts = ['KaTeX_AMS-Regular.woff2', 'KaTeX_Caligraphic-Bold.woff2', 'KaTeX_Caligraphic-Regular.woff2',
  'KaTeX_Fraktur-Bold.woff2', 'KaTeX_Fraktur-Regular.woff2', 'KaTeX_Main-Bold.woff2',
  'KaTeX_Main-BoldItalic.woff2', 'KaTeX_Main-Italic.woff2', 'KaTeX_Main-Regular.woff2',
  'KaTeX_Math-BoldItalic.woff2', 'KaTeX_Math-Italic.woff2', 'KaTeX_SansSerif-Bold.woff2',
  'KaTeX_SansSerif-Italic.woff2', 'KaTeX_SansSerif-Regular.woff2', 'KaTeX_Script-Regular.woff2',
  'KaTeX_Typewriter-Regular.woff2'];
for (const f of fonts) {
  const b = fs.readFileSync(path.join(__dirname, 'runtimes', 'fonts', f)).toString('base64');
  katexCss = katexCss.split('fonts/' + f + ')').join('data:font/woff2;base64,' + b + ')');
}
const headCss = '<style>\n' + katexCss + '\n</style>\n';

const cc = (cls, code) => '<div class="' + cls + '" data-b64="' + B64(code) + '"></div>';

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
  });
})();
</script>
`;

const html = `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"/>
<style>body { margin: 0 auto; max-width: 820px; padding: 24px; font-family: sans-serif; }
.markmap { width: 100%; height: 420px; } .mermaid,.ktx,.abc { width: 100%; overflow-x: auto; text-align: center; }</style>
` + headCss + headLibs + `
</head><body>
<h1>data-b64 图表渲染测试</h1>
<h2>markmap</h2>` + cc('markmap', '# 手写脑图\n## 分支一\n### 细节 1\n## 分支二\n- 要点 A') + `
<h2>mermaid</h2>` + cc('mermaid', 'graph TD\n  A[开始] --> B{判断}\n  B -->|是| C[执行]\n  B -->|否| D[结束]') + `
<h2>katex</h2>` + cc('ktx', 'E = mc^2') + `
<h2>echarts</h2>` + cc('ech', '{"xAxis":{"type":"category","data":["一","二","三","四"]},"yAxis":{"type":"value"},"series":[{"data":[150,230,224,218],"type":"bar"}]}') + `
<h2>abc</h2>` + cc('abc', 'X:1\nT:Scale\nM:4/4\nK:C\nCDEF GABc|') + `
` + runner + `
</body></html>`;

fs.writeFileSync(path.join(__dirname, 'test-export.html'), html);
console.log('written test-export.html, size =', (html.length / 1024).toFixed(0), 'KB');
