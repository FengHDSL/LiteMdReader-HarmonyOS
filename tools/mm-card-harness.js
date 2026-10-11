// Scratch harness: runs markmap-card.html's app <script> blocks against a stubbed
// DOM + markmap to verify the enlarge (fit=true) and inline-card (fit=false) paths.
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const html = fs.readFileSync(
  path.join(__dirname, '../entry/src/main/resources/rawfile/render/markmap-card.html'), 'utf8');
const bodyStart = html.indexOf('<body>');
const scripts = [...html.slice(bodyStart).matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
if (scripts.length !== 2) throw new Error('expected 2 app scripts, got ' + scripts.length);
const appJs = scripts.join('\n');

function el(name) {
  const e = {
    name, style: {}, innerHTML: '', rect: { height: 0 },
    clientWidth: 390, clientHeight: 800,
    classList: { add() {}, remove() {} },
    getBoundingClientRect() { return { height: this.rect.height, width: this.rect.width || 390 }; },
    getBBox() { return { height: 500, width: 900 }; },
  };
  return e;
}

function setup() {
  const app = el('app'); app.rect = { height: 800 };
  const svg = el('svg'); svg.rect = { height: 784 };
  const body = el('body');
  const de = el('html');
  const log = { posted: [], rescale: [], create: [], fitCount: 0 };
  let pendingFit = null;

  const markmap = {};
  markmap.Transformer = function () {};
  markmap.Transformer.prototype.transform = function (src) { return { root: { src } }; };
  markmap.Markmap = {
    create(node, opts, root) {
      log.create.push(opts);
      const mm = {
        svg: { node: () => svg },
        zoom: {},
        fit() {
          log.fitCount++;
          return new Promise(res => { pendingFit = res; });
        },
        rescale(k) { log.rescale.push(k); return Promise.resolve(); },
      };
      log.mm = mm;
      return mm;
    },
  };

  const sandbox = {
    console, setTimeout, clearTimeout, JSON, Math, Promise, Object, Array, Number, String,
    document: {
      documentElement: de, body,
      getElementById: id => (id === 'app' ? app : id === 'mmsvg' ? svg : null),
      querySelector: sel => (sel === '#app svg' ? svg : null),
      addEventListener: () => {},
    },
    markmap,
    arkHost: { postHeight: h => log.posted.push(h), postWidth: () => {} },
    ResizeObserver: function (cb) { log.roCb = cb; return { observe: () => {} }; },
    addEventListener: () => {},
  };
  const ctx = vm.createContext(sandbox);
  vm.runInContext('var window=this;', ctx);
  vm.runInContext(appJs, ctx);
  return {
    sandbox, app, svg, body, de, log,
    flushFit: () => { const f = pendingFit; pendingFit = null; if (f) f(); },
  };
}

const sleep = ms => new Promise(r => setTimeout(r, ms));
let fails = 0;
const check = (name, cond, extra) => {
  if (cond) console.log('  PASS  ' + name);
  else { fails++; console.log('  FAIL  ' + name + '  -> ' + JSON.stringify(extra)); }
};

(async () => {
  const s = setup();
  const w = s.sandbox;
  w.renderPayload(JSON.stringify({ src: '# a', dark: false, fit: true, vw: 0, inline: false }));
  s.flushFit();
  await sleep(420);              // past the 320ms refitCanvas
  s.flushFit();
  await sleep(60);

  console.log('[enlarge overlay: fit=true]');
  check('#app fills viewport (100vh)', s.app.style.height === '100vh', s.app.style.height);
  check('html height 100%', s.de.style.height === '100%', s.de.style.height);
  check('body overflow hidden', s.body.style.overflow === 'hidden', s.body.style.overflow);
  check('svg height left at 100% (no bbox override)', s.svg.style.height === undefined, s.svg.style.height);
  check('autoFit enabled', s.log.create.length > 0 && s.log.create.every(o => o.autoFit === true), s.log.create);
  check('canvas refit ran', s.log.fitCount >= 1, s.log.fitCount);

  console.log('[zoom is engine-level, not page-level]');
  // ± 与双指捏合现在都走 WebviewController.zoom()（整页等比），页面里不该
  // 再留任何一份缩放实现 —— 留着就会出现"只有横向变长"和两套比例打架
  check('template defines no __mmZoom', w.__mmZoom === undefined, typeof w.__mmZoom);
  check('template never calls rescale()', s.log.rescale.length === 0, s.log.rescale);

  console.log('[refit re-fits the canvas]');
  const before = s.log.fitCount;
  w.refit();
  s.flushFit();
  await sleep(40);
  check('refit() triggers a fit', s.log.fitCount > before, [before, s.log.fitCount]);

  console.log('[container resize re-fits]');
  const before2 = s.log.fitCount;
  s.app.clientWidth = 800; s.app.clientHeight = 400;   // simulate rotate
  s.log.roCb();
  s.flushFit();
  await sleep(40);
  check('resize triggers another fit', s.log.fitCount > before2, [before2, s.log.fitCount]);

  console.log('[inline card: fit=false regression guard]');
  const c = setup();
  c.sandbox.renderPayload(JSON.stringify({ src: '# a', dark: false, fit: false, vw: 0, inline: false }));
  await sleep(560);
  check('#app height auto', c.app.style.height === '', c.app.style.height);
  check('html height cleared', c.de.style.height === '', c.de.style.height);
  check('svg height from bbox = 516px', c.svg.style.height === '516px', c.svg.style.height);
  check('autoFit off', c.log.create.every(o => o.autoFit === false), c.log.create);
  check('height posted to host', c.log.posted.length > 0, c.log.posted);

  console.log('\n' + (fails === 0 ? 'ALL PASS' : fails + ' FAILED'));
  process.exit(fails ? 1 : 0);
})();
