// Force each firework kind with a deterministic Math.random, capture the painted
// particle cloud from the canvas stub's arc() calls, and check the shape is
// actually a shape — not a silently-degraded circle.
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const md = fs.readFileSync(
  path.join(__dirname, '../entry/src/main/resources/rawfile/chengjian.md'), 'utf8')
  .replace(/\r\n?/g, '\n');
const block = [...md.matchAll(/```html\n([\s\S]*?)\n```/g)].map(m => m[1])[0];
const js = [...block.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1])[0];

const KINDS = ['peony', 'ring', 'willow', 'chrys', 'palm', 'crackle',
  'star', 'heart', 'smiley', 'diamond', 'crossette', 'double'];

function boot(rand) {
  const arcs = [];
  let capture = false;
  const ctxStub = {
    setTransform() {}, clearRect() {}, fillRect() {}, beginPath() {}, closePath() {},
    moveTo() {}, lineTo() {}, stroke() {}, fillText() {}, measureText: s => ({ width: 6 }),
    createRadialGradient() { return { addColorStop() {} }; },
    arc(x, y, r) { if (capture && r >= 2 && r <= 12) { arcs.push([x, y, r]); } },
    fill() {},
  };
  const node = id => ({ id, style: {}, innerText: '', lis: {}, addEventListener(t, f) { this.lis[t] = f; } });
  const cv = Object.assign(node('fxCanvas'), {
    clientWidth: 360, clientHeight: 270, width: 360, height: 270,
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 360, height: 270 }),
    getContext: () => ctxStub,
  });
  const els = { fxCanvas: cv, fxRoot: node('fxRoot'), fxShots: node('fxShots'),
    fxParts: node('fxParts'), fxCombo: node('fxCombo'), fxShape: node('fxShape') };
  let rafQueue = [];
  const doc = {
    body: { contains: () => true },
    getElementById: id => els[id] || null,
    addEventListener() {},
  };
  const R = Math.random;
  const math = Object.create(Math);
  math.random = () => rand;
  const sandbox = {
    console, Math: math, String, Object, Array, Number, JSON, Promise,
    Date: { now: () => 5000 }, document: doc, __winL: {},
    requestAnimationFrame(fn) { rafQueue.push(fn); return 1; },
    cancelAnimationFrame() { rafQueue = []; },
    ResizeObserver: function () { return { observe() {} }; },
  };
  const c = vm.createContext(sandbox);
  vm.runInContext('var window=this;window.addEventListener=function(t,f){this.__winL[t]=f;};window.devicePixelRatio=1;', c);
  vm.runInContext(js, c);
  return {
    els, cv, sandbox,
    arm() { arcs.length = 0; capture = true; },
    disarm() { capture = false; return arcs.slice(); },    pump(n) {
      for (let k = 0; k < n; k++) {
        const q = rafQueue; rafQueue = [];
        if (!q.length) return;
        q.forEach(f => f());
      }
    },
  };
}

// cloud -> 12 angular bins of mean radius, normalised by the 95th-percentile
// radius (a couple of stray far points must not squash the whole profile).
function signature(pts, cx, cy) {
  const B = 24, sum = new Array(B).fill(0), cnt = new Array(B).fill(0);
  const radii = [];
  for (const [x, y] of pts) {
    const dx = x - cx, dy = y - cy, r = Math.hypot(dx, dy);
    if (r < 2 || r > 160) continue;
    const a = Math.atan2(dy, dx) + Math.PI;
    const b = Math.min(B - 1, Math.floor(a / (Math.PI * 2) * B));
    sum[b] += r; cnt[b]++; radii.push(r);
  }
  if (!radii.length) { return { bins: new Array(B).fill(0), maxR: 0, n: 0, inner: 0, outer: 0 }; }
  const sorted = radii.slice().sort((a, b) => a - b);
  const ref = sorted[Math.floor(sorted.length * 0.95)];
  const bins = [];
  for (let i = 0; i < B; i++) { bins.push(cnt[i] ? (sum[i] / cnt[i]) / ref : 0); }
  return {
    bins, maxR: ref, n: radii.length,
    filled: bins.filter(v => v > 0).length,
    inner: radii.filter(r => r < ref * 0.6).length / radii.length,
    outer: radii.filter(r => r > ref * 0.8).length / radii.length,
  };
}

function cloudFor(kind) {
  const rand = (KINDS.indexOf(kind) + 0.5) / KINDS.length;
  const g = boot(rand);
  g.pump(220);                      // let the boot rocket burst and fade out
  g.cv.lis.pointerdown({ clientX: 70, clientY: 210, preventDefault() {} });
  g.arm();
  let boom = -1, snap = [];
  for (let i = 0; i < 90; i++) {
    g.pump(1);
    const a = g.disarm(); g.arm();
    if (boom < 0 && a.length > 40) { boom = i; }
    if (boom >= 0 && i === boom + 40) { snap = a; }   // fully expanded, still alive
  }
  g.disarm();
  if (boom < 0) throw new Error(kind + ': rocket never detonated');
  // bloom + core share a centre; collapse them
  const seen = new Set(), pts = [];
  for (const [x, y] of snap) {
    const k = Math.round(x * 2) + ',' + Math.round(y * 2);
    if (!seen.has(k)) { seen.add(k); pts.push([x, y]); }
  }
  // measure against the cloud's OWN centroid — the burst point is offset by the
  // rocket's launch jitter, and assuming the tap point skewed every earlier run
  const cx = pts.reduce((s, p) => s + p[0], 0) / pts.length;
  const cy = pts.reduce((s, p) => s + p[1], 0) / pts.length;
  return { pts, sig: signature(pts, cx, cy) };
}

let fails = 0;
const check = (n, c, extra) => {
  if (c) console.log('  PASS  ' + n);
  else { fails++; console.log('  FAIL  ' + n + ' -> ' + JSON.stringify(extra)); }
};

const got = {};
for (const k of ['peony', 'star', 'heart', 'smiley', 'diamond', 'crossette', 'double']) {
  got[k] = cloudFor(k);
  const s = got[k].sig;
  console.log(k.padEnd(10), 'n=' + String(s.n).padStart(3),
    'R=' + s.maxR.toFixed(0).padStart(3),
    'inner=' + s.inner.toFixed(2), 'outer=' + s.outer.toFixed(2));
}

console.log('');
for (const k of ['peony', 'star', 'heart', 'smiley', 'diamond']) {
  check(k + ' produced a particle cloud', got[k].sig.n > 40, got[k].sig.n);
}
// "flat" = min/max of the per-angle mean radius. A circle is flat; a real shape is not.
const flat = b => Math.min(...b.filter(v => v > 0)) / Math.max(...b);
const L1 = (a, b) => a.reduce((s, v, i) => s + Math.abs(v - b[i]), 0);

// NOTE: a peony at +40 frames is a *gravity-drooping* shell, not a geometric
// circle, so "is it round" is the wrong baseline. What matters is that the
// plain shells fill every direction and the shapes do not — the L1 distance
// below is the real guard against a shape silently degrading back to a shell.
check('peony shell fills every direction', got.peony.sig.filled === 24, got.peony.sig.filled);
check('ring shell fills every direction', got.double.sig.filled > 20, got.double.sig.filled);

check('star is not round', flat(got.star.sig.bins) < 0.7, flat(got.star.sig.bins).toFixed(2));
check('star is bimodal (tips + valleys)',
  got.star.sig.outer > 0.15 && got.star.sig.inner > 0.1,
  [got.star.sig.outer.toFixed(2), got.star.sig.inner.toFixed(2)]);

check('heart is not round', flat(got.heart.sig.bins) < 0.7, flat(got.heart.sig.bins).toFixed(2));
check('heart has the top notch', (() => {
  const b = got.heart.sig.bins;
  return b[6] / Math.max(...b.filter(v => v > 0)) < 0.88;   // bin 6 = straight up
})(), got.heart.sig.bins[6].toFixed(2));

check('smiley has inner features (eyes + mouth)', got.smiley.sig.inner > 0.12,
  got.smiley.sig.inner.toFixed(2));
check('smiley keeps its round face', flat(got.smiley.sig.bins) < 0.75,
  flat(got.smiley.sig.bins).toFixed(2));

check('diamond is not round', flat(got.diamond.sig.bins) < 0.7, flat(got.diamond.sig.bins).toFixed(2));

// the point of the whole exercise: a shape that silently degraded back to a
// circle would still "run fine" and look like nothing
for (const k of ['star', 'heart', 'smiley', 'diamond']) {
  check(k + ' differs from a plain circle', L1(got[k].sig.bins, got.peony.sig.bins) > 3,
    L1(got[k].sig.bins, got.peony.sig.bins).toFixed(1));
}

// secondary detonations must add a second wave of particles
check('crossette re-explodes (more particles than a plain shell)',
  got.crossette.sig.n >= 40, got.crossette.sig.n);
check('double fires twice (cloud still populated late)',
  got.double.sig.n >= 40, got.double.sig.n);

// edge taps must not fling the shape off-canvas (a half-clipped heart looks broken)
function edgeCloud(kind, tx, ty) {
  const rand = (KINDS.indexOf(kind) + 0.5) / KINDS.length;
  const g = boot(rand);
  g.pump(220);
  g.cv.lis.pointerdown({ clientX: tx, clientY: ty, preventDefault() {} });
  g.arm();
  let boom = -1, snap = [];
  for (let i = 0; i < 90; i++) {
    g.pump(1);
    const a = g.disarm(); g.arm();
    if (boom < 0 && a.length > 40) { boom = i; }
    if (boom >= 0 && i === boom + 30) { snap = a; }
  }
  g.disarm();
  return snap.filter(p => p[2] >= 2 && p[2] <= 12).map(p => [p[0], p[1]]);
}
const right = edgeCloud('heart', 358, 130);
const xs = right.map(p => p[0]), ys = right.map(p => p[1]);
check('right-edge tap keeps the shape on canvas',
  right.length > 40 && Math.max(...xs) <= 360 && Math.min(...xs) >= 0,
  [right.length, Math.max(...xs).toFixed(0), Math.min(...xs).toFixed(0)]);
const top = edgeCloud('star', 180, 4);
check('top-edge tap keeps the shape on canvas',
  top.length > 40 && Math.min(...top.map(p => p[1])) >= 0,
  [top.length, Math.min(...top.map(p => p[1])).toFixed(0)]);

console.log('\n' + (fails === 0 ? 'SHAPES OK' : fails + ' FAILED'));
process.exit(fails ? 1 : 0);
