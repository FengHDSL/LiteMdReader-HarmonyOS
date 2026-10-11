// Verify render/code.html's new contract: when the host supplies pre-highlighted
// per-line HTML (p.html) it must be used verbatim, row-for-row with p.src; when
// absent it must fall back to escaped plain text (no HTML injection).
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const html = fs.readFileSync(
  path.join(__dirname, '../entry/src/main/resources/rawfile/render/code.html'), 'utf8');
const js = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]).join('\n');

function render(p) {
  let inner = '';
  const app = { get innerHTML() { return inner; }, set innerHTML(v) { inner = v; }, style: {} };
  const body = { style: {}, className: '' };
  const sandbox = {
    console, setTimeout: () => {}, Math, String, Object, Array, JSON, Number,
    document: {
      getElementById: id => (id === 'app' ? app : null),
      body,
      addEventListener: () => {},
      scrollHeight: 100,
    },
    arkHost: { postHeight: () => {} },
    addEventListener: () => {},
  };
  const ctx = vm.createContext(sandbox);
  vm.runInContext('var window=this;', ctx);
  vm.runInContext(js, ctx);
  sandbox.renderPayload(p);
  return { inner, body };
}

let fails = 0;
const check = (n, c, extra) => {
  if (c) console.log('  PASS  ' + n);
  else { fails++; console.log('  FAIL  ' + n + ' -> ' + JSON.stringify(extra)); }
};
const rows = out => (out.match(/<tr>/g) || []).length;

// 1) highlighted path
const src = 'def f(x):\n    return x + 1   # add\n';
const rich = '<span style="color:#CF222E">def</span> f(x):\n    <span style="color:#CF222E">return</span> x + 1   <span style="color:#6A737D"># add</span>\n';
const out1 = render({ src, dark: true, html: rich });
check('row count matches source lines', rows(out1.inner) === 3, rows(out1.inner));
check('highlight spans passed through', out1.inner.includes('color:#CF222E'), out1.inner.slice(0, 160));
check('dark class applied', out1.body.className === 'dark', out1.body.className);
check('empty trailing line still gets a row', out1.inner.includes('&nbsp;'), out1.inner.slice(-120));

// 2) plain fallback must escape
const out2 = render({ src: '<img src=x onerror=alert(1)>\n&co\n', dark: false });
check('no raw tag injected when html absent', !out2.inner.includes('<img src=x'), out2.inner.slice(0, 200));
check('angle brackets escaped', out2.inner.includes('&lt;img'), out2.inner.slice(0, 200));
check('ampersand escaped', out2.inner.includes('&amp;co'), out2.inner.slice(0, 200));

// 3) html present but shorter than src -> must not crash / must still cover all rows
const out3 = render({ src: 'a\nb\nc\nd\n', html: 'x\ny' });
check('short html still yields one row per source line', rows(out3.inner) === 5, rows(out3.inner));

console.log('\n' + (fails === 0 ? 'CODE.HTML CONTRACT OK' : fails + ' FAILED'));
process.exit(fails ? 1 : 0);
