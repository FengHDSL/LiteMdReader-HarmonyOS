// 二分测试 runner
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ channel: 'msedge' });
  const page = await browser.newPage();
  page.on('pageerror', e => console.log('  pageerror:', e.message.slice(0, 100)));
  await page.goto('file:///C:/Users/panda/LiteMdReader/tools/bisect.html');
  await page.waitForTimeout(8000);
  const r = await page.evaluate(() => ({
    log: window.__log, svg: document.querySelector('#gv-0 svg') !== null
  }));
  console.log('  result:', JSON.stringify(r));
  await browser.close();
})().catch(e => { console.error('  FAIL', e.message); });
