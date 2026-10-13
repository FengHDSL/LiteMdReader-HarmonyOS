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
const rows = out => (out.match(/<tr(\s|>)/g) || []).length;

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

// 4) 指定高亮行（围栏元数据 js{1,3-5}）：模板必须给对应 <tr> 加 class，
//    且宿主没给 hl 时一行都不亮（放大浮层此前整个丢高亮）
const out4 = render({ src: 'a\nb\nc\nd\ne', html: 'a\nb\nc\nd\ne', hl: '1,3,4' });
const hlRows = [...out4.inner.matchAll(/<tr([^>]*)>/g)].map(m => (m[1].includes('hl') ? 1 : 0));
check('hl 命中的行加 class（1、3、4 亮）', hlRows.join('') === '10110', hlRows);
const out5 = render({ src: 'a\nb', html: 'a\nb' });
check('没给 hl 时一行都不亮', !out5.inner.includes('class="hl"'), out5.inner);

// 5) 宿主侧管道：payload 里得真的带上 hl，否则模板永远收不到（这类"分支没人走"的坑栽过）
const root = path.join(__dirname, '..');
const web = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/DiagramWeb.ets'), 'utf8');
const reader = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Reader.ets'), 'utf8');
const view = fs.readFileSync(path.join(root, 'entry/src/main/ets/markdown/MdView.ets'), 'utf8');
check('DiagramWeb 声明 hlLines 并入 payload', /@Prop @Watch\('onPayloadChanged'\) hlLines/.test(web)
  && /hl: this\.hlLines/.test(web));
check('Reader 按 geoKey 取块的 hlLines 并传给浮层',
  /private codeHlCsv\(geoKey: string\): string/.test(reader)
  && /this\.enlargeHlCsv = mode === 'code' \? this\.codeHlCsv\(geoKey\)/.test(reader)
  && /hlLines: this\.enlargeHlCsv/.test(reader));
check('源码视图切换时清掉 hl（别拿上一块的高亮乱染）', /this\.enlargeHlCsv = '';/.test(reader));
check('正文卡片用行底色而不是叠一层 Column（叠层会盖住行号）',
  !/position\(\{ x: 0, y: 0 \}\)[\s\S]{0,200}#26F59E0B/.test(view)
  && /this\.lineHighlighted\(lineIndex\)[\s\S]{0,80}hlLineBg\(\)/.test(view));

console.log('\n' + (fails === 0 ? 'CODE.HTML CONTRACT OK' : fails + ' FAILED'));
process.exit(fails ? 1 : 0);
