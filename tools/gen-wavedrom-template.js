// Build entry/src/main/resources/rawfile/render/wavedrom.html by inlining the
// offline WaveDrom build + its two skins, following the exact convention of the
// other render templates (arkHost.postHeight, window.renderPayload/__exportBg/refit).
// Re-run after replacing anything under runtimes/.
const fs = require('fs');
const path = require('path');

const RAW = path.join(__dirname, '../entry/src/main/resources/rawfile');
const read = f => fs.readFileSync(path.join(RAW, 'runtimes', f), 'utf8').replace(/\r\n/g, '\n');

const wd = read('wavedrom.min.js');
const skinDefault = read('wavedrom-skin-default.js');

for (const [n, s] of [['wavedrom.min.js', wd], ['skin default', skinDefault]]) {
  if (s.length < 1000) throw new Error(n + ' looks truncated (' + s.length + ' bytes)');
  if (/<\/script/i.test(s)) throw new Error(n + ' contains a literal </script — would break inlining');
}

const head = `<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,minimum-scale=0.05,maximum-scale=10,user-scalable=yes">
<title>数字波形</title>
<style>
  html,body{margin:0;padding:0;background:transparent;}
  body.dark{color:#ECEFF4;}
  #app{padding:8px 10px;box-sizing:border-box;overflow:hidden;}
  #app svg,#app canvas{max-width:100%;}
  .err{color:#D93B3B;font:13px sans-serif;white-space:pre-wrap;}
</style>
<!-- WaveDrom 3.7.0 (MIT, https://github.com/wavedrom/wavedrom) + 官方 default 皮肤，
     全部内联：模板离线可用，不产生任何网络请求。皮肤必须先于主库载入
     （主库读全局 WaveSkin）。
     ⚠️ 只带 default 一套：皮肤的白底板 + 黑描边是配套的，换 dark 皮肤只会变成
     "白底上铺浅色描边"= 波形糊掉、深色卡片里还嵌一块白斑（用户实测"深色模式背景异常"）。
     所以深浅主题统一用浅色波形面板；reg / assign 路径缺底板，由 ensureWhitePanel 补齐。 -->
<script>${skinDefault}</script>
<script>${wd}</script>
</head>
<body>
<div id="app"></div>
<script>
  // RenderWaveForm(index, source, outputPrefix) 的定位方式是
  // document.getElementById(outputPrefix + index)，所以容器 id 必须是
  // WaveDrom_Display_0（实测传 'app' 会报 childNodes of null）。
  var WD_PREFIX = 'WaveDrom_Display_';
  var WD_SLOT = WD_PREFIX + '0';
  // WaveJSON 里裸写键名很常见（signal:[{name:clk,wave:p...}]），
  // 与 echarts 模板同一套修复：把左花括号或逗号后的裸标识符补成带引号的键。
  // ⚠️ 只补键名，**不补值** —— 值也要裸写就得靠真正的 JS 字面量解析（等于 eval），
  // 这里不做，解析失败时给出可执行的错误提示。
  function fix(x) {
    return x.replace(/([{,]\\s*)([A-Za-z_][A-Za-z0-9_]*)\\s*:/g, '$1"$2":');
  }

  window.__render = function (src, dark, fit) {
    var app = document.getElementById('app');
    // ⚠️ 放大浮层里**不能靠 #app 裁掉溢出**：基础 CSS 的 #app{overflow:hidden} 会把
    // 超出画布的那段波形直接切掉，文档宽度也就永远等于视口宽 —— 结果是右侧
    // 怎么滑都滑不到（用户实测"有地方滑不到、被遮挡"）。浮层改成溢出可见 +
    // body 收到 max-content，让**文档本身变宽**，横向才滑得到尽头。
    // 卡片模式维持 hidden + 等比缩放到 100% 宽（波形完整、只是小，点开放大看细节）。
    app.style.overflow = fit ? 'visible' : 'hidden';
    document.body.style.width = fit ? 'max-content' : '';
    app.innerHTML = '<div id="' + WD_SLOT + '"></div>';
    var obj = null;
    try { obj = JSON.parse(fix(String(src))); }
    catch (e1) {
      try { obj = JSON.parse(String(src)); }
      catch (e2) {
        app.innerHTML = '<div class="err">WaveJSON 解析失败：' + e2.message
          + String.fromCharCode(10)
          + '请写合法 JSON：键名的引号可以省略，但字符串值必须加引号'
          + '（例如 wave:"p...." 而不是 wave:p....）。'
          + 'wavedrom.org 上那种 InputJSON_0 = {{…}} 的 JS 写法需要先整理成 JSON。</div>';
        report();
        return;
      }
    }
    // WaveDrom 一共三种图：波形 signal、逻辑门 assign、寄存器位段 reg
    if (!obj || (!obj.signal && !obj.assign && !obj.reg)) {
      app.innerHTML = '<div class="err">顶层缺少数组：WaveJSON 应为 signal（波形）'
        + '/ assign（逻辑门）/ reg（寄存器位段）三者之一。</div>';
      report();
      return;
    }
    // 皮肤：**深浅主题都用 default（浅色）**。default 皮肤的白底板 + 黑描边是配套的，
    // 换 dark 皮肤等于"白底 + 浅色描边"，波形直接糊掉，深色卡片里还会嵌出一块白斑
    // （用户实测"深色模式背景异常"）。这里只内联了 default 一套，WaveDrom 取不到别的
    // 皮肤，行为恒定；reg / assign 没底板的问题见 ensureWhitePanel。
    try {
      window.WaveDrom.RenderWaveForm(0, obj, WD_PREFIX);
    } catch (e) {
      app.innerHTML = '<div class="err">' + (e && e.message ? e.message : e) + '</div>';
      report();
      return;
    }
    var sv = document.getElementById(WD_SLOT);
    sv = sv ? sv.querySelector('svg') : null;
    if (sv) {
      // 波形常常比手机卡片宽：卡片模式等比缩到不溢出（max-width 由基础 CSS 给），
      // 放大浮层里放开宽度，让用户看全时间轴。
      sv.style.maxWidth = fit ? 'none' : '100%';
      sv.style.height = 'auto';
      ensureWhitePanel(sv);
    }
    report();
    setTimeout(report, 120);
  };

  // 补一块不透明白底板 —— **只有 signal 路径自带**（皮肤生成器画了
  // rect{fill:white} 覆盖整张画布），reg（寄存器位段）与 assign（逻辑门）两条
  // 路径**不画**：它们的分隔线、位段框和文字是库里硬编码的黑描边黑字
  // （g[stroke:black] + text 默认 fill=black），底板却是透明的。结果深色卡片里
  // 等于"黑底写黑字"，位段图整块糊掉（用户实测"寄存器位段图背景显示异常"）。
  // 这里给缺底板的 SVG 补一块，三种图统一成"浅色波形面板"——与深浅主题都固定
  // 用 default 皮肤的既有策略一致（比反色描边可靠：反色要改皮肤里几十个类，
  // 且官方 dark 皮肤实测同样是白底）。
  function ensureWhitePanel(svgEl) {
    try {
      var W = 0, H = 0;
      var vb = (svgEl.getAttribute('viewBox') || '').split(/[\\s,]+/).filter(function (x) { return x.length > 0; });
      if (vb.length === 4) { W = parseFloat(vb[2]); H = parseFloat(vb[3]); }
      if (!(W > 0) || !(H > 0)) {
        W = parseFloat(svgEl.getAttribute('width')) || 0;
        H = parseFloat(svgEl.getAttribute('height')) || 0;
      }
      if (!(W > 0) || !(H > 0)) { return; }
      var rects = svgEl.getElementsByTagName('rect');
      for (var i = 0; i < rects.length; i++) {
        var r = rects[i];
        // 注意：这里**刻意不用正则** —— 本函数整体嵌在 JS 模板字符串里，
        // \\s \\b 这类转义会先被模板字符串吃掉一层，生成的页面里就成了哑正则
        // （实测漏判 signal 已有底板、又铺了一层）。小写子串判断等价且免疫。
        var f = ((r.getAttribute('fill') || '') + ' ' + (r.getAttribute('style') || ''))
          .toLowerCase().replace(/[^a-z0-9:;#]/g, '');
        var isWhite = f.indexOf('#fff') >= 0 || f.indexOf('#ffffff') >= 0 || f.indexOf('white') >= 0;
        var w = parseFloat(r.getAttribute('width')) || 0;
        var h = parseFloat(r.getAttribute('height')) || 0;
        // 已经有一块覆盖整张画布的白底（signal 路径）→ 不重复铺
        if (isWhite && w >= W * 0.9 && h >= H * 0.9) { return; }
      }
      var bg = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      bg.setAttribute('x', '0');
      bg.setAttribute('y', '0');
      bg.setAttribute('width', String(W));
      bg.setAttribute('height', String(H));
      bg.setAttribute('fill', '#ffffff');
      svgEl.insertBefore(bg, svgEl.firstChild);
    } catch (e) {}
  }
</script>
`;

const tail = `<script>
  function report() {
    try {
      var app = document.getElementById('app');
      if (window.__fit) {
        // 撑满模式（放大 / 导出抓图）：整页高度按滚动高度反映（抓全图）
        var h = Math.max(app.scrollHeight, document.body.scrollHeight,
                         document.documentElement.scrollHeight, document.documentElement.offsetHeight);
        if (window.arkHost && window.arkHost.postHeight) { window.arkHost.postHeight(h); }
      } else {
        // 卡片模式：高度 = 内容实际布局高度，并把整页钉死为该值。
        // ⚠️ 内容未渲染完成（app 还空着）时不 pin、不上报小高度 —— 否则首轮回传
        // 小值会让宿主立刻截图，把成品波形裁成一条（与 graphviz 模板同一教训）。
        if (app.offsetHeight <= 60) { return; }
        var h2 = Math.max(app.offsetHeight, 40);
        document.documentElement.style.height = h2 + 'px';
        document.body.style.height = h2 + 'px';
        document.documentElement.style.overflow = 'hidden';
        document.body.style.overflow = 'hidden';
        if (window.arkHost && window.arkHost.postHeight) { window.arkHost.postHeight(h2); }
      }
    } catch (e) {}
  }

  window.renderPayload = function (json) {
    try {
      var o = (typeof json === 'string') ? JSON.parse(json) : json;
      if (o.dark) { document.body.classList.add('dark'); }
      if (o.vw && o.vw > 0) { document.body.style.width = o.vw + 'px'; document.body.style.margin = '0'; }
      if (o.bg) { document.documentElement.style.background = o.bg; document.body.style.background = o.bg; }
      window.__fit = !!o.fit;
      window.__render(o.src, o.dark, !!o.fit);
      setTimeout(report, 60); setTimeout(report, 300);
    } catch (e) {
      document.getElementById('app').innerHTML = '<div class="err">' + e.message + '</div>';
      report();
    }
  };

  // **导出图片用**：临时把所有背景置为透明（PNG 要透明底），导出完再还原
  window.__exportBg = function (on) {
    try {
      var els = [document.documentElement, document.body];
      var app = document.getElementById('app');
      if (app) { els.push(app); }
      for (var i = 0; i < els.length; i++) {
        var e = els[i];
        if (!e) { continue; }
        if (on) {
          if (e.__prevBg === undefined) { e.__prevBg = e.style.background || ''; e.__prevBgc = e.style.backgroundColor || ''; }
          e.style.background = '#ff00ff'; e.style.backgroundColor = '#ff00ff';
        } else if (e.__prevBg !== undefined) {
          e.style.background = e.__prevBg; e.style.backgroundColor = e.__prevBgc;
        }
      }
      var svgs = document.querySelectorAll('svg');
      for (var k = 0; k < svgs.length; k++) {
        var sv = svgs[k];
        if (on) {
          if (sv.__prevBg === undefined) { sv.__prevBg = sv.style.background || ''; }
          sv.style.background = '#ff00ff';
        } else if (sv.__prevBg !== undefined) {
          sv.style.background = sv.__prevBg;
        }
      }
    } catch (e) {}
  };

  window.refit = function () {
    try {
      var sv = document.querySelector('#app svg');
      if (sv) {
        if (window.__fit) { sv.style.width = '100%'; sv.style.maxWidth = 'none'; }
        else { sv.style.maxWidth = '100%'; }
        sv.style.height = 'auto';
      }
    } catch (e) {}
    report();
  };

  if (typeof ResizeObserver !== 'undefined') {
    new ResizeObserver(function () { report(); }).observe(document.getElementById('app'));
  }
  window.addEventListener('load', report);
</script>
</body></html>
`;

const out = head + tail;
const dest = path.join(RAW, 'render', 'wavedrom.html');
fs.writeFileSync(dest, out);
console.log('wrote ' + dest + ' (' + (out.length / 1024).toFixed(0) + ' KB)');
