// 单独定位 viz-standalone 渲染问题
const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

(async () => {
  const viz = fs.readFileSync(path.join(__dirname, 'runtimes', 'viz-standalone.js'), 'utf8');
  const html = `<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>
  <div id="gv"></div>
  <script>${viz}</script>
  <script>
  (async () => {
    const out = document.getElementById('gv');
    try {
      window.__log = [];
      __log.push('Viz type: ' + typeof Viz);
      const v = await Viz.instance();
      __log.push('instance ok: ' + typeof v.renderString);
      const svg = await v.renderString('digraph G { a -> b }', { format: 'svg' });
      __log.push('render ok, len=' + svg.length);
      out.innerHTML = svg;
    } catch (e) {
      __log.push('ERR: ' + (e && (e.stack || e.message || String(e))));
    }
  })();
  </script></body></html>`;
  fs.writeFileSync(path.join(__dirname, 'viz-test.html'), html);
  const browser = await chromium.launch({ channel: 'msedge' });
  const page = await browser.newPage();
  page.on('pageerror', e => console.log('pageerror:', e.message));
  await page.goto('file:///' + path.join(__dirname, 'viz-test.html').replace(/\\/g, '/'));
  await page.waitForTimeout(2500);
  const log = await page.evaluate(() => window.__log || ['no log']);
  console.log('LOG:', JSON.stringify(log, null, 1));
  const hasSvg = await page.evaluate(() => document.querySelector('#gv svg') !== null);
  console.log('hasSvg:', hasSvg);
  await browser.close();
})().catch(e => { console.error('FAIL', e); process.exit(1); });
