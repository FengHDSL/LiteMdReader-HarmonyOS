// Playwright 验证导出 HTML 的图表渲染
const { chromium } = require('playwright');
const path = require('path');

(async () => {
  const browser = await chromium.launch({ channel: 'msedge' });
  const page = await browser.newPage({ viewport: { width: 900, height: 1200 } });
  const errors = [];
  page.on('pageerror', e => errors.push('pageerror: ' + (e.stack || e.message)));
  page.on('console', m => {
    if (m.type() === 'error') { errors.push('console: ' + m.text()); }
  });
  await page.goto('file:///' + path.join(__dirname, 'test-export.html').replace(/\\/g, '/'));
  await page.waitForTimeout(9000); // 等渲染（viz wasm 编译较慢）
  const stat = await page.evaluate(() => {
    const r = { chartErrors: window.__chartErrors || [] };
    const hasSvg = (sel, tag) => {
      const el = document.querySelector(sel);
      return el ? (el.querySelector(tag) !== null || el.children.length > 0) : 'no-el';
    };
    r.markmap = hasSvg('.markmap', 'svg');
    r.mermaid = hasSvg('.mermaid', 'svg');
    r.gv = hasSvg('.gv', 'svg');
    r.abc = hasSvg('.abc', 'svg');
    const ktx = document.querySelector('.ktx');
    r.katex = ktx ? ktx.children.length > 0 : 'no-el';
    const ech = document.querySelector('.ech');
    r.echarts = ech ? ech.querySelector('canvas') !== null : 'no-el';
    return r;
  });
  console.log('STAT:', JSON.stringify(stat, null, 1));
  console.log('ERRORS:', errors.length, errors.slice(0, 5));
  await page.screenshot({ path: path.join(__dirname, 'shot-export.png'), fullPage: true });
  await browser.close();
  console.log('screenshot saved');
})().catch(e => { console.error('FAIL', e); process.exit(1); });
