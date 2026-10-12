#!/usr/bin/env node
/**
 * 图标几何校验（**只读资源，不改资源**）
 * =====================================
 *
 * 圆滑风格的图标全用"填充路径"画（stroke/fill 属性会让 Image.fillColor() 失效），
 * 于是一个笔画 = 一条闭合子路径。多条子路径叠在一起时，SVG 默认的 **nonzero**
 * 填充规则会把**绕向相反**的重叠区抵消成空洞——图标上表现为"被咬了一口"。
 *
 * 本工具在本地把每条子路径栅格化，然后按下面三条判据检查：
 *   ① 绕向相反的两条子路径若**部分重叠**（既不分离，也不是"内圈完整嵌在外圈里"
 *      的故意挖孔），nonzero 会把重叠区抵消掉；只要这块区域在最终图像里真的没墨，
 *      就是肉眼可见的缺口 → FAIL；
 *   ② 每条子路径自己必须闭合（末点回到起点）；
 *   ③ 整套图标必须有墨（ink 比例过低说明这枚图标实际是空的/被抵消光了）。
 *
 * 用法：node tools/verify-icon-geometry.js [tb_xxx ...]
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const MEDIA = path.join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'media');
const GRID = 96;          // 栅格分辨率（96×96 对 24vp 画布 = 每格 0.25vp）

let fails = 0;
function check(label, ok, extra) {
  if (!ok) { fails++; console.log('  FAIL  ' + label + (extra ? '  ' + extra : '')); }
}

/** 把 path d 拆成子路径折线（M/L/H/V/Q/Z，二次贝塞尔按 12 段展开）。 */
function flatten(d) {
  const toks = d.match(/[A-Za-z]|-?\d+(?:\.\d+)?/g) || [];
  const polys = [];
  let cur = null;
  let x = 0, y = 0, sx = 0, sy = 0;
  let i = 0;
  const isNum = () => i < toks.length && !/[A-Za-z]/.test(toks[i]);
  const num = () => Number(toks[i++]);
  const closePoly = () => {
    if (cur && cur.length > 2) {
      cur.push([sx, sy]);
      polys.push(cur);
    }
    cur = null;
  };
  const push = (px, py) => { if (!cur) cur = []; cur.push([px, py]); x = px; y = py; };
  while (i < toks.length) {
    const t = toks[i];
    if (!/[A-Za-z]/.test(t)) { check('裸数字（解析失败）: ' + t, false); i++; continue; }
    const cmd = t;
    const rel = cmd === cmd.toLowerCase();
    const dx = () => (rel ? x + num() : num());
    const dy = () => (rel ? y + num() : num());
    i++;
    switch (cmd.toUpperCase()) {
      case 'M': {
        closePoly();
        const px = dx(), py = dy();
        sx = px; sy = py; x = px; y = py;   // 当前位置必须跟着动，否则紧随其后的
        cur = [[px, py]];                    // Q 会以 (0,0) 当起点，贝塞尔整段画歪
        while (isNum()) push(dx(), dy());
        break;
      }
      case 'L': while (isNum()) push(dx(), dy()); break;
      case 'H': while (isNum()) push(dx(), y); break;
      case 'V': while (isNum()) push(x, dy()); break;
      case 'Q':
        while (isNum()) {
          const cx = dx(), cy = dy(), ex = dx(), ey = dy();
          const ox = x, oy = y;
          const STEPS = 12;
          for (let s = 1; s <= STEPS; s++) {
            const u = s / STEPS;
            push((1 - u) * (1 - u) * ox + 2 * (1 - u) * u * cx + u * u * ex,
              (1 - u) * (1 - u) * oy + 2 * (1 - u) * u * cy + u * u * ey);
          }
        }
        break;
      case 'Z': closePoly(); break;
      default: check('未支持命令 ' + cmd, false); break;
    }
  }
  closePoly();
  return polys;
}

function shoelace(poly) {
  let s = 0;
  for (let k = 0; k < poly.length - 1; k++) {
    s += poly[k][0] * poly[k + 1][1] - poly[k + 1][0] * poly[k][1];
  }
  return s;
}

/** 子路径自己的覆盖图（偶奇规则：一条闭合曲线内部 = 实心）。 */
function cover(poly) {
  const mask = new Uint8Array(GRID * GRID);
  for (let row = 0; row < GRID; row++) {
    const py = (row + 0.5) / GRID * 24;
    let inside = false;
    for (let col = 0; col < GRID; col++) {
      const px = (col + 0.5) / GRID * 24;
      let cross = 0;
      for (let k = 0; k < poly.length - 1; k++) {
        const ay = poly[k][1], by = poly[k + 1][1];
        const ax = poly[k][0], bx = poly[k + 1][0];
        if ((ay > py) !== (by > py)) {
          const xAt = ax + (py - ay) / (by - ay) * (bx - ax);
          if (px < xAt) cross++;
        }
      }
      inside = (cross % 2) === 1;
      mask[row * GRID + col] = inside ? 1 : 0;
    }
  }
  return mask;
}

const area = (m) => m.reduce((s, v) => s + v, 0);

/** 整条路径按 nonzero（SVG 默认填充规则）栅格化——这就是 ArkUI 实际渲染出来的样子。 */
function nonzeroMask(polys) {
  const m = new Uint8Array(GRID * GRID);
  for (let row = 0; row < GRID; row++) {
    const py = (row + 0.5) / GRID * 24;
    for (let col = 0; col < GRID; col++) {
      const px = (col + 0.5) / GRID * 24;
      let w = 0;
      for (const poly of polys) {
        for (let k = 0; k < poly.length - 1; k++) {
          const ax = poly[k][0], ay = poly[k][1], bx = poly[k + 1][0], by = poly[k + 1][1];
          if (ay <= py) { if (by > py && (bx - ax) * (py - ay) - (px - ax) * (by - ay) > 0) w++; }
          else if (by <= py && (bx - ax) * (py - ay) - (px - ax) * (by - ay) < 0) w--;
        }
      }
      m[row * GRID + col] = w !== 0 ? 1 : 0;
    }
  }
  return m;
}

function analyse(file) {
  const svg = fs.readFileSync(path.join(MEDIA, file + '.svg'), 'utf8');
  const ds = (svg.match(/d="([^"]+)"/g) || []).map((s) => s.slice(3, -1));
  const polys = ds.reduce((acc, d) => acc.concat(flatten(d)), []);
  const masks = polys.map(cover);
  const signs = polys.map((p) => Math.sign(shoelace(p)));
  if (process.env.DEBUG_POLY === '1') {
    polys.forEach((p, i) => {
      const xs = p.map((v) => v[0]), ys = p.map((v) => v[1]);
      console.log('    p' + i + ' verts=' + p.length
        + ' x=' + Math.min(...xs).toFixed(2) + '..' + Math.max(...xs).toFixed(2)
        + ' y=' + Math.min(...ys).toFixed(2) + '..' + Math.max(...ys).toFixed(2)
        + ' area=' + area(masks[i]) + ' sign=' + signs[i]);
    });
  }
  const final = nonzeroMask(polys);
  check(file + ' ② 每条子路径都闭合', polys.every((p) => {
    const a = p[0], b = p[p.length - 1];
    return Math.abs(a[0] - b[0]) < 0.01 && Math.abs(a[1] - b[1]) < 0.01;
  }));
  // ① 反向子路径**部分重叠**（既不分离、也不是"内圈完整嵌在外圈里"的故意挖孔）时，
  //    nonzero 会把重叠区抵消掉。只要这块重叠区在最终图像里真的没墨，就是肉眼可见的缺口。
  for (let a = 0; a < polys.length; a++) {
    for (let b = a + 1; b < polys.length; b++) {
      if (signs[a] === signs[b]) { continue; }            // 同绕向：重叠只会并成实心
      const areaA = area(masks[a]), areaB = area(masks[b]);
      let ov = 0, bitten = 0;
      for (let k = 0; k < final.length; k++) {
        if (masks[a][k] && masks[b][k]) { ov++; if (final[k] === 0) bitten++; }
      }
      if (ov === 0 || ov === areaA || ov === areaB) { continue; }   // 分离 / 故意挖孔
      check(file + ' ① 反向重叠区被抵消成空洞: p' + a + '/p' + b, bitten === 0,
        'overlap=' + ov + ' 无墨=' + bitten);
    }
  }
  const inkPct = area(final) / (GRID * GRID) * 100;
  check(file + ' ③ 有足够墨迹（>=5%）', inkPct >= 5, 'ink=' + inkPct.toFixed(1) + '%');
  return inkPct;
}

const args = process.argv.slice(2);
const files = (args.length > 0 ? args : fs.readdirSync(MEDIA).filter((f) => /^tb_.*\.svg$/.test(f)).map((f) => f.slice(0, -4)))
  .map((f) => f.replace(/^tb_/, 'tb_').replace(/\.svg$/, ''));
const report = [];
for (const f of files) {
  if (!fs.existsSync(path.join(MEDIA, f + '.svg'))) { check('文件存在: ' + f, false); continue; }
  report.push([f, analyse(f)]);
}
for (const [f, ink] of report) { console.log('  ' + f.padEnd(22) + ' ink=' + ink.toFixed(1) + '%'); }
console.log(fails === 0 ? 'ICON GEOMETRY OK' : 'ICON GEOMETRY FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
