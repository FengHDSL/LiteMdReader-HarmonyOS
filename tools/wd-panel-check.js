// WaveDrom 底板检查：把**真实模板字节**跑起来，验证三种图（signal / assign / reg）
// 都拿到一块覆盖整张画布的不透明白底，且 signal 不会被重复铺一层。
// 输出 .workbuddy/charttest/wd-panel.html，用 file:// 打开后读 #result。
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const TPL = path.join(ROOT, 'entry/src/main/resources/rawfile/render/wavedrom.html');
const OUT = path.join(ROOT, '.workbuddy/charttest/wd-panel.html');

const CASES = {
  reg: '{"reg":[{"name":"opcode","bits":8,"attr":"OP"},{"name":"addr","bits":16},{"bits":4,"attr":"R"},{"bits":4,"attr":"F"}],"config":{"bits":32}}',
  regCompact: '{"reg":[{"name":"v","bits":32,"type":"0"}],"config":{"bits":32,"compact":true}}',
  signal: '{"signal":[{"name":"clk","wave":"p...."},{"name":"dat","wave":"321x","data":["A","BB","CC"]}]}',
  assign: '{"assign":[["&","A","B","=","C"],["|","C","D","=","F"]]}'
};

const DRIVER = String.raw`
<script>
(function () {
  var C = __CASES__;
  var r = {};
  function probe(k) {
    var app = document.getElementById('app');
    var sv = app ? app.querySelector('svg') : null;
    if (!sv) { r[k] = { svg: false }; return; }
    // viewBox 优先：卡片模式下 svg 可能被 CSS 缩放，但属性值仍是用户单位基准
    var vb = (sv.getAttribute('viewBox') || '').split(/[\s,]+/).filter(Boolean);
    var W = vb.length === 4 ? (parseFloat(vb[2]) || 0) : 0;
    var H = vb.length === 4 ? (parseFloat(vb[3]) || 0) : 0;
    if (!(W > 0) || !(H > 0)) {
      W = parseFloat(sv.getAttribute('width')) || 0;
      H = parseFloat(sv.getAttribute('height')) || 0;
    }
    var err = app.querySelector('.err');
    var full = [].filter.call(sv.getElementsByTagName('rect'), function (e) {
      var f = (e.getAttribute('fill') || '') + ' ' + (e.getAttribute('style') || '');
      return /white|#fff/i.test(f)
        && parseFloat(e.getAttribute('width')) >= W * 0.9
        && parseFloat(e.getAttribute('height')) >= H * 0.9;
    });
    r[k] = {
      size: W + 'x' + H,
      whitePanelCount: full.length,
      firstTag: sv.firstElementChild ? sv.firstElementChild.tagName : null,
      rects: sv.getElementsByTagName('rect').length,
      lines: sv.getElementsByTagName('line').length,
      texts: sv.getElementsByTagName('text').length,
      err: err ? (err.textContent || '').slice(0, 90) : ''
    };
  }
  var ks = Object.keys(C), i = 0;
  function step() {
    if (i >= ks.length) {
      document.getElementById('result').textContent = JSON.stringify(r, null, 1);
      return;
    }
    window.__render(C[ks[i]], false, false);
    setTimeout(function () { probe(ks[i]); i += 1; step(); }, 220);
  }
  var d = document.createElement('div');
  d.id = 'result';
  d.style.cssText = 'position:fixed;left:0;bottom:0;right:0;max-height:45vh;overflow:auto;'
    + 'background:#fff;color:#000;font:11px/1.4 monospace;white-space:pre;z-index:99999';
  document.body.appendChild(d);
  step();
})();
</` + `script>
`;

fs.mkdirSync(path.dirname(OUT), { recursive: true });
const html = fs.readFileSync(TPL, 'utf8').replace(/\r\n/g, '\n')
  .replace('</body>', DRIVER.replace('__CASES__', JSON.stringify(CASES)) + '</body>');
fs.writeFileSync(OUT, html);
console.log('wrote ' + OUT);
console.log('open: file:///' + OUT.replace(/\\/g, '/'));
