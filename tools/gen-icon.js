/**
 * 澄笺 · 应用图标生成器
 * ======================
 * 纯 Node 生成 PNG（zlib + 手写 PNG chunk），无需任何图像库。
 * 2x 超采样抗锯齿。设计：
 *   背景：暖纸渐变 + 左上冷光斑 + 右下暖光斑（「澄」的通透感）
 *   前景：一张带折角的纸笺 + 金色题头线 + 三行墨线 + 一道斜向澄光
 * 运行：node tools/gen-icon.js
 */
const zlib = require('zlib');
const fs = require('fs');
const path = require('path');

const SIZE = 1024;      // 输出尺寸
const SS = 2;           // 超采样倍数
const N = SIZE * SS;    // 渲染尺寸

// ── PNG 编码 ──
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(buf) {
  let c = 0xFFFFFFFF;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}
function encodePNG(w, h, rgba) {
  const sig = Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  const stride = w * 4;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (stride + 1)] = 0;
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}

// ── 颜色工具（r,g,b 0-255，a 0-1）──
function mix(c1, c2, t) {
  return [c1[0] + (c2[0] - c1[0]) * t, c1[1] + (c2[1] - c1[1]) * t, c1[2] + (c2[2] - c1[2]) * t];
}
function clamp01(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
// 圆角矩形 SDF（有符号距离，正=外）
function sdfRoundRect(px, py, cx, cy, hw, hh, r) {
  const dx = Math.abs(px - cx) - (hw - r);
  const dy = Math.abs(py - cy) - (hh - r);
  const ax = Math.max(dx, 0), ay = Math.max(dy, 0);
  return Math.sqrt(ax * ax + ay * ay) + Math.min(Math.max(dx, dy), 0) - r;
}
function cov(dist) { return clamp01(0.5 - dist); } // 1px 抗锯齿

// ── 背景：暖纸渐变 + 光斑 ──
function drawBackground() {
  const rgba = Buffer.alloc(SIZE * SIZE * 4);
  const top = [246, 239, 224], bot = [230, 221, 198];
  for (let y = 0; y < SIZE; y++) {
    for (let x = 0; x < SIZE; x++) {
      const t = y / SIZE;
      let c = mix(top, bot, t);
      // 左上冷光斑（青蓝）
      const dCool = Math.hypot(x - SIZE * 0.22, y - SIZE * 0.20) / (SIZE * 0.55);
      c = mix(c, [196, 216, 236], 0.5 * Math.exp(-dCool * dCool * 2.2));
      // 右下暖光斑
      const dWarm = Math.hypot(x - SIZE * 0.82, y - SIZE * 0.85) / (SIZE * 0.6);
      c = mix(c, [240, 214, 160], 0.45 * Math.exp(-dWarm * dWarm * 2.0));
      const i = (y * SIZE + x) * 4;
      rgba[i] = Math.round(c[0]); rgba[i + 1] = Math.round(c[1]); rgba[i + 2] = Math.round(c[2]); rgba[i + 3] = 255;
    }
  }
  return rgba;
}

function drawForeground() {
// ── 前景：纸笺 + 折角 + 墨线 + 澄光 ──
  const n = N; // 渲染分辨率
  const rgba = Buffer.alloc(n * n * 4); // 按超采样分辨率分配，否则写越界
  // 纸笺几何（在 1024 坐标系定义，渲染时乘 SS）
  const sheet = { cx: 512, cy: 545, hw: 265, hh: 355, r: 52 };
  const fold = 96; // 折角大小
  const sheetTop = sheet.cy - sheet.hh, sheetRight = sheet.cx + sheet.hw;
  const sheetColTop = [255, 254, 249], sheetColBot = [247, 240, 224];
  const foldCol = [232, 220, 194];
  const ink = [74, 66, 56], inkBlue = [58, 84, 122], gold = [176, 132, 58];
  // 墨线：[cy, 半宽, 半长, 颜色]
  const lines = [
    [395, 15, 92, gold],
    [470, 11, 172, ink],
    [555, 11, 172, ink],
    [640, 11, 118, ink]
  ];
  for (let y = 0; y < n; y++) {
    for (let x = 0; x < n; x++) {
      const px = x / SS, py = y / SS;
      let r = 0, g = 0, b = 0, a = 0;
      // 纸笺覆盖度
      let d = sdfRoundRect(px, py, sheet.cx, sheet.cy, sheet.hw, sheet.hh, sheet.r);
      // 折角裁切：右上角沿对角线（(cutX, sheetTop) → (sheetRight, cutY)）切掉
      const cutX = sheetRight - fold, cutY = sheetTop + fold;
      const diag = (px - cutX) - (py - sheetTop);
      let cov0 = cov(d);
      if (py < cutY && diag > 0) {
        cov0 = 0;
      }
      if (cov0 > 0) {
        // 纸面：竖向微渐变 + 边缘轻微加深
        const ty = (py - (sheet.cy - sheet.hh)) / (sheet.hh * 2);
        let sc = mix(sheetColTop, sheetColBot, clamp01(ty));
        const edge = clamp01((-d) / 26);
        sc = mix(sc, [226, 214, 186], 0.35 * (1 - edge));
        r = sc[0]; g = sc[1]; b = sc[2]; a = cov0;
        // 折角翻盖：对角线内侧的三角（fold 回折进来）
        const inFlap = px >= cutX && py >= sheetTop && py <= cutY && ((px - cutX) <= (cutY - py));
        if (inFlap) {
          const fc = mix(foldCol, [214, 200, 172], clamp01((cutY - py) / fold));
          r = fc[0]; g = fc[1]; b = fc[2];
        }
        // 澄光斜带（纸笺上的一条透明光）
        const streakD = ((px - 330) * 0.55 + (py - 300) * -1);
        const streak = Math.exp(-(streakD * streakD) / (2 * 90 * 90));
        const s = 0.30 * streak;
        r = r + (255 - r) * s; g = g + (255 - g) * s; b = b + (250 - b) * s;
      }
      // 墨线（画在纸上）
      for (let li = 0; li < lines.length; li++) {
        const L = lines[li];
        const ld = sdfRoundRect(px, py, sheet.cx - 12, L[0], L[2], L[1], L[1]);
        const lc = cov(ld) * (a > 0 ? a : 0) * 0.92;
        if (lc > 0) {
          r = mix([r, g, b], L[3], lc)[0];
          g = mix([r, g, b], L[3], lc)[1];
          b = mix([r, g, b], L[3], lc)[2];
        }
      }
      // 澄光小圆点（纸笺左上）
      const dotD = Math.hypot(px - 372, py - 300) / 16;
      const dot = clamp01(0.5 - dotD) * (a > 0 ? 1 : 0);
      if (dot > 0) {
        r = mix([r, g, b], [255, 243, 214], dot)[0];
        g = mix([r, g, b], [255, 243, 214], dot)[1];
        b = mix([r, g, b], [255, 243, 214], dot)[2];
      }
      const i = (y * n + x) * 4;
      rgba[i] = Math.round(clamp01(r / 255) * 255);
      rgba[i + 1] = Math.round(clamp01(g / 255) * 255);
      rgba[i + 2] = Math.round(clamp01(b / 255) * 255);
      rgba[i + 3] = Math.round(clamp01(a) * 255);
    }
  }
  return downsample(rgba, n, SIZE);
}

function downsample(src, n, out) {
  const dst = Buffer.alloc(out * out * 4);
  const f = n / out;
  for (let y = 0; y < out; y++) {
    for (let x = 0; x < out; x++) {
      let r = 0, g = 0, b = 0, a = 0, cnt = 0;
      for (let sy = Math.floor(y * f); sy < Math.floor((y + 1) * f); sy++) {
        for (let sx = Math.floor(x * f); sx < Math.floor((x + 1) * f); sx++) {
          const i = (sy * n + sx) * 4;
          const wa = src[i + 3] / 255;
          // 预乘平均，避免透明边缘发黑
          r += src[i] * wa; g += src[i + 1] * wa; b += src[i + 2] * wa; a += src[i + 3];
          cnt++;
        }
      }
      const i = (y * out + x) * 4;
      const avgA = a / cnt;
      dst[i] = avgA > 0 ? Math.round(r / cnt / (avgA / 255)) : 0;
      dst[i + 1] = avgA > 0 ? Math.round(g / cnt / (avgA / 255)) : 0;
      dst[i + 2] = avgA > 0 ? Math.round(b / cnt / (avgA / 255)) : 0;
      dst[i + 3] = Math.round(avgA);
    }
  }
  return dst;
}

const outDir = path.join(__dirname, '..');
const targets = [
  path.join(outDir, 'AppScope/resources/base/media'),
  path.join(outDir, 'entry/src/main/resources/base/media')
];
const fg = encodePNG(SIZE, SIZE, drawForeground());
const bg = encodePNG(SIZE, SIZE, drawBackground());
for (const dir of targets) {
  fs.writeFileSync(path.join(dir, 'foreground.png'), fg);
  fs.writeFileSync(path.join(dir, 'background.png'), bg);
}
// startIcon：前景合成到背景上的整图（启动页图标）
const start = Buffer.alloc(SIZE * SIZE * 4);
for (let i = 0; i < start.length; i += 4) {
  const fa = fg[i + 3] / 255;
  start[i] = Math.round(bg[i] * (1 - fa) + fg[i] * fa);
  start[i + 1] = Math.round(bg[i + 1] * (1 - fa) + fg[i + 1] * fa);
  start[i + 2] = Math.round(bg[i + 2] * (1 - fa) + fg[i + 2] * fa);
  start[i + 3] = 255;
}
fs.writeFileSync(path.join(outDir, 'entry/src/main/resources/base/media/startIcon.png'), encodePNG(SIZE, SIZE, start));
console.log('icons written:', targets.join(' | '), 'fg', fg.length, 'bg', bg.length);
