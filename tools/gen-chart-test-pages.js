// Build self-contained test pages by taking the ACTUAL render template bytes and
// appending a driver that feeds it every chart block from the builtin docs.
// No network/ports: open the generated file directly and read #result.
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const RAW = path.join(ROOT, 'entry/src/main/resources/rawfile');
const OUT = path.join(ROOT, '.workbuddy/charttest');
const manifest = JSON.parse(fs.readFileSync(path.join(ROOT, '.workbuddy/doc-charts.json'), 'utf8'));

const LANGS = ['wavedrom', 'mermaid', 'graphviz', 'echarts'];
fs.mkdirSync(OUT, { recursive: true });

for (const lang of LANGS) {
  const tplPath = path.join(RAW, 'render', lang + '.html');
  if (!fs.existsSync(tplPath)) { console.error('missing template ' + lang); continue; }
  let html = fs.readFileSync(tplPath, 'utf8').replace(/\r\n/g, '\n');
  const blocks = manifest[lang] || [];
  const driver = `
<div id="result" style="position:fixed;left:0;bottom:0;right:0;max-height:40vh;overflow:auto;
     background:#fff;color:#000;font:11px/1.4 monospace;z-index:9999"></div>
<script>
(function () {
  var BLOCKS = ${JSON.stringify(blocks.map(b => ({ doc: b.doc, line: b.line, src: b.src })))};
  var app = document.getElementById('app');
  var out = [];
  function snapshot(label, src) {
    var svg = app.querySelector('svg'), canvas = app.querySelector('canvas');
    var err = app.querySelector('.err');
    var box = svg || canvas;
    var r = box ? box.getBoundingClientRect() : { width: 0, height: 0 };
    out.push({
      case: label,
      ok: !!(svg || canvas) && !err && r.width > 8 && r.height > 8,
      svg: !!svg, canvas: !!canvas,
      w: Math.round(r.width), h: Math.round(r.height),
      texts: svg ? svg.querySelectorAll('text').length : 0,
      err: err ? (err.textContent || '').slice(0, 120) : ''
    });
  }
  function run(i) {
    if (i >= BLOCKS.length) {
      var txt = JSON.stringify(out, null, 1);
      document.getElementById('result').textContent = txt;
      document.title = 'DONE ' + out.filter(function (o) { return o.ok; }).length + '/' + out.length;
      window.__done = true;
      return;
    }
    var b = BLOCKS[i];
    app.innerHTML = '';
    document.documentElement.style.height = '';
    document.body.style.height = '';
    try {
      window.renderPayload(JSON.stringify({ src: b.src, dark: false, fit: false, vw: 0, inline: false }));
    } catch (e) {
      out.push({ case: b.doc + ':' + b.line, ok: false, err: 'threw: ' + (e && e.message) });
    }
    setTimeout(function () { snapshot(b.doc + ':' + b.line, b.src); run(i + 1); }, 1400);
  }
  if (document.readyState === 'complete') { run(0); } else { window.addEventListener('load', function () { run(0); }); }
})();
</script>
`;
  const at = html.lastIndexOf('</body>');
  html = at >= 0 ? html.slice(0, at) + driver + html.slice(at) : html + driver;
  fs.writeFileSync(path.join(OUT, lang + '.html'), html);
  console.log(lang + ': ' + blocks.length + ' blocks -> .workbuddy/charttest/' + lang + '.html');
}
