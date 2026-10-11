// Run the demo doc's fireworks <script> against a stub canvas/DOM with a
// controllable clock, and check the touch paths actually do something.
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const md = fs.readFileSync(
  path.join(__dirname, '../entry/src/main/resources/rawfile/chengjian.md'), 'utf8')
  .replace(/\r\n?/g, '\n');

const blocks = [...md.matchAll(/```html\n([\s\S]*?)\n```/g)].map(m => m[1]);
if (blocks.length !== 1) throw new Error('expected 1 html block, got ' + blocks.length);
const scripts = [...blocks[0].matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
if (scripts.length !== 1) throw new Error('expected 1 script, got ' + scripts.length);
const js = scripts[0];

function ctxStub() {
  const calls = { fillRect: 0, fill: 0, stroke: 0, clearRect: 0, gradient: 0 };
  return {
    calls,
    setTransform() {}, clearRect() { calls.clearRect++; }, fillRect() { calls.fillRect++; },
    beginPath() {}, closePath() {}, moveTo() {}, lineTo() {}, arc() {},
    fill() { calls.fill++; }, stroke() { calls.stroke++; },
    createRadialGradient() { calls.gradient++; return { addColorStop() {} }; },
    measureText(s) { return { width: String(s).length * 6 }; },
    fillText() {},
  };
}

function boot(cw, ch, dpr) {
  let now = 1000;
  const node = id => ({
    id, style: {}, innerText: '', lis: {},
    addEventListener(t, fn) { this.lis[t] = fn; },
  });
  const cv = Object.assign(node('fxCanvas'), {
    clientWidth: cw, clientHeight: ch, width: 0, height: 0,
    getBoundingClientRect() { return { left: 0, top: 0, width: this.clientWidth, height: this.clientHeight }; },
    getContext() { return this.__ctx || (this.__ctx = ctxStub()); },
  });
  const els = { fxCanvas: cv, fxRoot: node('fxRoot'), fxShots: node('fxShots'),
    fxParts: node('fxParts'), fxCombo: node('fxCombo') };
  let rafQueue = [];
  const doc = {
    body: { contains: n => n === cv },
    getElementById: id => (els[id] || null),
    addEventListener(t, fn) { (this.__l || (this.__l = {}))[t] = fn; },
  };
  const sandbox = {
    console, Math, String, Object, Array, Number, JSON, Promise, Date: { now: () => now },
    document: doc, __winL: {}, __advance: ms => { now += ms; },
    requestAnimationFrame(fn) { rafQueue.push(fn); return 1; },
    cancelAnimationFrame() { rafQueue = []; },
    ResizeObserver: function () { return { observe() {} }; },
  };
  const c = vm.createContext(sandbox);
  vm.runInContext('var window=this;window.addEventListener=function(t,f){this.__winL[t]=f;};' +
    'window.devicePixelRatio=' + dpr + ';', c);
  vm.runInContext(js, c);
  return {
    cv, els, doc, sandbox,
    pump(n) {
      for (let k = 0; k < n; k++) {
        const q = rafQueue; rafQueue = [];
        if (q.length === 0) return false;
        q.forEach(f => f());
      }
      return true;
    },
    len: () => rafQueue.length,
    tap: (x, y) => cv.lis.pointerdown({ clientX: x, clientY: y, preventDefault() {} }),
    move: (x, y) => cv.lis.pointermove({ clientX: x, clientY: y, preventDefault() {} }),
    up: () => sandbox.__winL.pointerup(),
  };
}

let fails = 0;
const check = (n, c, extra) => {
  if (c) console.log('  PASS  ' + n);
  else { fails++; console.log('  FAIL  ' + n + ' -> ' + JSON.stringify(extra)); }
};
const num = el => Number(el.innerText || '0');

const g = boot(360, 270, 2);
console.log('[canvas 360x270 @2x]');
check('backing store = css size x dpr', g.cv.width === 720 && g.cv.height === 540,
  [g.cv.width, g.cv.height]);
check('handlers wired', typeof g.cv.lis.pointerdown === 'function'
  && typeof g.cv.lis.pointermove === 'function'
  && typeof g.sandbox.__winL.pointerup === 'function'
  && typeof g.doc.__l.keydown === 'function');

g.pump(12);   // HUD is throttled to every 8 frames — let it tick before reading
check('boot launched a rocket', num(g.els.fxShots) >= 1, g.els.fxShots.innerText);

g.pump(20);
check('rocket trail drawn', g.cv.__ctx.calls.stroke > 0 || g.cv.__ctx.calls.fill > 0,
  g.cv.__ctx.calls);

// tap -> new shot + eventual particle burst
const before = num(g.els.fxShots);
g.tap(180, 90);
g.pump(12);
check('tap increments shot counter', num(g.els.fxShots) === before + 1,
  [before, g.els.fxShots.innerText]);
g.pump(90);
check('particles spawned after apex', num(g.els.fxParts) > 20, g.els.fxParts.innerText);
check('glow gradients used', g.cv.__ctx.calls.gradient > 0, g.cv.__ctx.calls.gradient);

// drag emits a light band
const p0 = num(g.els.fxParts);
for (let x = 60; x < 300; x += 12) g.move(x, 120);
g.pump(2);
check('drag emits trail particles', num(g.els.fxParts) > p0, [p0, g.els.fxParts.innerText]);
g.up();
const p1 = num(g.els.fxParts);
for (let x = 60; x < 300; x += 12) g.move(x, 200);
check('after pointerup, moving does not paint', num(g.els.fxParts) <= p1 + 3, [p1, g.els.fxParts.innerText]);

// combo from rapid taps
for (let k = 0; k < 4; k++) { g.tap(90 + k * 40, 70 + k * 10); g.pump(3); }
check('rapid taps build a combo', /x[2-9]/.test(g.els.fxCombo.innerText), g.els.fxCombo.innerText);

// idle auto-show after 3s
g.sandbox.__advance(3400);
const s2 = num(g.els.fxShots);
g.pump(140);
check('auto-performs when idle', num(g.els.fxShots) > s2, [s2, g.els.fxShots.innerText]);

// particle cap holds under sustained spam
for (let k = 0; k < 60; k++) { g.tap(40 + (k * 37) % 300, 50 + (k * 23) % 150); g.pump(6); }
check('particle count stays capped', num(g.els.fxParts) <= 1500, g.els.fxParts.innerText);

// resize re-fits
g.cv.clientWidth = 700; g.cv.clientHeight = 525;
g.sandbox.__winL.resize();
g.pump(10);
check('re-fit on resize', g.cv.width === 1400 && g.cv.height === 1050, [g.cv.width, g.cv.height]);

// detached -> loop stops
g.doc.body.contains = () => false;
g.pump(1);
check('loop stops when canvas detaches', g.len() === 0, g.len());

// tiny canvas must not divide-by-zero or throw
try {
  const t = boot(120, 90, 1);
  t.pump(200);
  t.tap(60, 40);
  t.pump(200);
  check('tiny canvas survives', true);
} catch (e) { check('tiny canvas survives', false, String(e)); }

console.log('\n' + (fails === 0 ? 'FIREWORKS OK' : fails + ' FAILED'));
process.exit(fails ? 1 : 0);
