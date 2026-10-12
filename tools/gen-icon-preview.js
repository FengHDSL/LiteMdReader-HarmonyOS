// 生成工具栏图标的**离线预览页**（不用编译、不用上机就能看整套图标）。
//
// 直接把 resources/base/media 下的真实 SVG 内联进一个页面，在浅色 / 深色两种底上
// 各排一遍，并放大到 15 / 22 / 34 px 三档（15 是工具栏实际尺寸，另两档看细节）。
// 深色那一栏用 CSS `fill` 给无 fill 属性的 path 染色 —— 这正好模拟 ArkUI 里
// Image.fillColor() 的行为，所以"深色下看不看得清"在这里就能提前判断。
//
// 用法：node tools/gen-icon-preview.js  然后浏览器打开 .workbuddy/icon-preview.html
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const MEDIA = path.join(ROOT, 'entry/src/main/resources/base/media');
const OUT = path.join(ROOT, '.workbuddy/icon-preview.html');

const names = fs.readdirSync(MEDIA)
  .filter(f => f.startsWith('tb_') && f.endsWith('.svg'))
  .map(f => f.slice(0, -4))
  .concat(['chevron_up_circle', 'chevron_down_circle'])
  .sort();

function bodyOf(file) {
  const svg = fs.readFileSync(path.join(MEDIA, file + '.svg'), 'utf8');
  const m = /<svg[^>]*>([\s\S]*)<\/svg>/.exec(svg);
  return m === null ? '' : m[1];
}
/**
 * 取每个文件自己的 viewBox。⚠️ 不能一律按 24×24 量：用户提供的 chevron_*.svg 是
 * 48×48 坐标系，硬套 24 会把整个图标算成"越界"（预览与几何检查都会误判）。
 */
function viewBoxOf(file) {
  const svg = fs.readFileSync(path.join(MEDIA, file + '.svg'), 'utf8');
  const m = /viewBox="([^"]+)"/.exec(svg);
  if (m !== null) { return m[1]; }
  const w = /width="(\d+)"/.exec(svg);
  const h = /height="(\d+)"/.exec(svg);
  if (w !== null && h !== null) { return '0 0 ' + w[1] + ' ' + h[1]; }
  return '0 0 24 24';
}
function cell(name, px) {
  return '<div class="cell"><svg viewBox="' + viewBoxOf(name) + '" width="' + px + '" height="' + px + '">'
    + bodyOf(name) + '</svg><span>' + name.replace(/^tb_/, '') + '</span></div>';
}

const groups = {};
for (const n of names) {
  const kind = n.startsWith('tb_chart_') ? '图表' : (n.startsWith('tb_') ? '格式' : '展开/收起');
  (groups[kind] = groups[kind] || []).push(n);
}

let html = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>澄笺 · 工具栏图标预览</title><style>'
  + 'body{margin:0;padding:22px;font:12px/1.5 -apple-system,"HarmonyOS Sans SC",sans-serif;background:#F3F4F7;color:#1B1F27}'
  + 'h2{font-size:14px;margin:22px 0 8px}'
  + '.band{padding:14px;border-radius:14px;margin-bottom:14px}'
  + '.light{background:#FFFDF9;border:1px solid #E3E4EA}'
  + '.dark{background:#101319;border:1px solid #262B36;color:#E6E9F0}'
  + '.dark svg path{fill:#7FA7FF}'
  + '.light svg path{fill:#1F63E8}'
  + '.row{display:flex;flex-wrap:wrap;gap:10px}'
  + '.cell{width:78px;display:flex;flex-direction:column;align-items:center;gap:4px}'
  + '.cell span{font-size:9px;opacity:.55;word-break:break-all;text-align:center}'
  + '</style></head><body>';
html += '<h1 style="font-size:17px;margin:0">工具栏图标预览（' + names.length + ' 枚，取自 media 真实文件）</h1>';
for (const kind of Object.keys(groups)) {
  html += '<h2>' + kind + ' · 实际 15px / 放大 22 · 34px</h2>';
  for (const tone of ['light', 'dark']) {
    html += '<div class="band ' + tone + '">';
    for (const px of [15, 22, 34]) {
      html += '<div style="margin-bottom:8px"><div style="opacity:.5;margin-bottom:4px">' + px + 'px · '
        + (tone === 'light' ? '浅色主题' : '深色主题（模拟 fillColor）') + '</div><div class="row">'
        + groups[kind].map(n => cell(n, px)).join('') + '</div></div>';
    }
    html += '</div>';
  }
}
html += '</body></html>';
fs.writeFileSync(OUT, html);
console.log('wrote ' + OUT + '  (' + (html.length / 1024).toFixed(0) + ' KB, ' + names.length + ' icons)');
console.log('open: file:///' + OUT.replace(/\\/g, '/'));
