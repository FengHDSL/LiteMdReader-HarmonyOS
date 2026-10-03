// 终极共存测试验证
const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const browser = await chromium.launch({ channel: 'msedge' });
  const page = await browser.newPage();
  const errs = [];
  page.on('pageerror', e => errs.push('pageerror: ' + (e.stack || e.message).slice(0, 250)));
  page.on('console', m => { if (m.type() === 'error') errs.push('console: ' + m.text().slice(0, 150)); });
  await page.goto('file:///' + path.join(__dirname, 'ultimate-test.html').replace(/\\/g, '/'));
  await page.waitForTimeout(12000);
  const stat = await page.evaluate(() => {
    const q = s => document.querySelector(s);
    const hasSvg = s => q(s) ? q(s).querySelector('svg') !== null : 'no-el';
    return {
      markmap: hasSvg('.markmap'),
      mermaid: hasSvg('.mermaid'),
      katex: q('.ktx') ? q('.ktx').children.length > 0 : 'no-el',
      echarts: q('.ech') ? q('.ech').querySelector('canvas') !== null : 'no-el',
      abc: hasSvg('.abc'),
      gv: hasSvg('.gv'),
      flowchart: q('.flowchart') ? q('.flowchart').querySelector('svg') !== null : 'no-el'
    };
  });
  console.log('STAT:', JSON.stringify(stat, null, 1));
  console.log('ERRORS:', errs.length); errs.slice(0, 6).forEach(e => console.log(' -', e));
  await page.screenshot({ path: path.join(__dirname, 'shot-ultimate.png'), fullPage: true });
  await browser.close();
})().catch(e => { console.error('FAIL', e.message); process.exit(1); });
