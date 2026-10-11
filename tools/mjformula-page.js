// mjformula.html 的页面逻辑（由 gen-mjformula.js 与 MathJax 库一起拼装进模板）。
// 职责：把 TeX 源码排版（MathJax tex2svg）→ SVG → canvas 光栅化 → PNG dataURL，
// 经 javaScriptProxy 的 postPng 回调把结果交给 ArkTS 落盘。
// 全链路只用 Web 标准能力（不依赖任何系统截图 / 渲染 API）。
// ⚠️ 与 gen-mjformula.js 拼装进 render/mjformula.html，改这里后要重新生成。

// b64 → UTF-8 字符串（与项目其它模板的 b64u 同款）
function b64u(b64) {
  var bin = atob(b64);
  var u = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) { u[i] = bin.charCodeAt(i); }
  return new TextDecoder().decode(u);
}

window.__mjReady = false;
MathJax.startup.promise.then(function () {
  window.__mjReady = true;
  try {
    if (window.arkHost && window.arkHost.postReady) { window.arkHost.postReady(); }
  } catch (e) { /* 桥未挂载（测试环境）：忽略 */ }
});

/**
 * 渲染单个公式。
 * @param id       任务键（回传时原样带回，供 ArkTS 做归属校验）
 * @param b64tex   TeX 源码（base64(UTF-8)，规避引号/换行转义问题）
 * @param display  0=行内 1=块级
 * @param fontPx   渲染字号（CSS px；等于正文 vp 字号，图与原文字号一致）
 * @param colorHex 字形颜色（深色主题浅墨，否则深墨；MathJax 字形 fill=currentColor）
 * 结果异步经 arkHost.postPng(JSON) 回传：{id, ok, png, w, h, err}
 */
window.tex2png = function (id, b64tex, display, fontPx, colorHex) {
  var result = function (o) {
    try {
      if (window.arkHost && window.arkHost.postPng) {
        window.arkHost.postPng(JSON.stringify(o));
      }
    } catch (e) { /* 桥异常：丢弃（ArkTS 侧有超时兜底） */ }
  };
  try {
    if (!window.__mjReady) { result({ id: id, ok: false, err: 'not ready' }); return; }
    var tex = b64u(b64tex);
    var holder = document.getElementById('mhold');
    holder.style.fontSize = (fontPx > 0 ? fontPx : 16) + 'px';
    // MathJax v4：同步 tex2svg 遇到需按需加载的扩展（\color / newcommand 等）会
    // 抛 "an asynchronous action is required" —— 统一走 tex2svgPromise（组件自带
    // autoload，promise 链自然等待）；v3 无此 API 时退回同步路径。
    if (typeof MathJax.tex2svgPromise === 'function') {
      MathJax.tex2svgPromise(tex, { display: !!display }).then(function (node) {
        rasterize(node, id, result, colorHex);
      }, function (e) {
        result({ id: id, ok: false, err: String(e) });
      });
    } else {
      rasterize(MathJax.tex2svg(tex, { display: !!display }), id, result, colorHex);
    }
  } catch (e) {
    result({ id: id, ok: false, err: String(e) });
  }
};

/** node → 量尺寸 → SVG 序列化 → canvas 光栅化 → result（tex2png 的共用尾段）。 */
function rasterize(node, id, result, colorHex) {
  try {
    var holder = document.getElementById('mhold');
    holder.innerHTML = '';
    holder.appendChild(node);
    var svg = holder.querySelector('svg');
    var rect = svg.getBoundingClientRect();
    var w = Math.max(1, Math.ceil(rect.width));
    var h = Math.max(1, Math.ceil(rect.height));
    // 固化尺寸为 px（ex 单位在图片加载器里没有字体上下文）
    svg.setAttribute('width', w);
    svg.setAttribute('height', h);
    svg.removeAttribute('style');
    svg.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
    // 字形颜色：MathJax 用 fill="currentColor"，给 svg 元素设 color 即可
    // （img 上下文的 currentColor 取 svg 自身 color；缺省为黑，深色主题会看不见）
    if (colorHex && /^#[0-9a-fA-F]{6}$/.test(colorHex)) {
      svg.style.color = colorHex;
    }
    var xml = new XMLSerializer().serializeToString(svg);
    // 光栅化：SVG → Image → canvas → PNG（在浏览器内完成，字体渲染完全可控）
    var dpr = Math.min(3, window.devicePixelRatio || 2);
    var cv = document.createElement('canvas');
    cv.width = Math.ceil(w * dpr);
    cv.height = Math.ceil(h * dpr);
    var ctx = cv.getContext('2d');
    var img = new Image();
    img.onload = function () {
      try {
        ctx.drawImage(img, 0, 0, cv.width, cv.height);
        result({ id: id, ok: true, png: cv.toDataURL('image/png'), w: w, h: h });
      } catch (e) {
        result({ id: id, ok: false, err: String(e) });
      }
    };
    img.onerror = function () {
      result({ id: id, ok: false, err: 'svg rasterize img fail' });
    };
    img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(xml);
  } catch (e) {
    result({ id: id, ok: false, err: String(e) });
  }
}
