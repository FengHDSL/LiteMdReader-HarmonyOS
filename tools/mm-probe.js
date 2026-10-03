// 探测 markmap 0.18 的正确调用 API
const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

(async () => {
  const lib = fs.readFileSync(path.join(__dirname, 'runtimes', 'markmap-lib.js'), 'utf8');
  const view = fs.readFileSync(path.join(__dirname, 'runtimes', 'markmap-view.js'), 'utf8');
  const d3 = fs.readFileSync(path.join(__dirname, 'runtimes', 'd3.min.js'), 'utf8');
  const html = `<!DOCTYPE html><html><head><meta charset="utf-8">
  <style>.markmap{width:600px;height:400px}</style>
  <script>${d3}</script><script>${lib}</script><script>${view}</script></head><body>
  <div class="markmap"><script type="text/template"># 根\n## 子1\n## 子2</script></div>
  <script>
  window.__info = [];
  (async () => {
    __info.push('markmap keys: ' + Object.keys(window.markmap || {}).join(','));
    try {
      const t = new markmap.Transformer();
      const r = await t.transform('# 根\\n## 子1\\n## 子2');
      __info.push('transform ok, type=' + (typeof r) + ', keys=' + (r ? Object.keys(r).join(',') : 'null'));
      const root = r.root || r;
      __info.push('root children=' + (root.children ? root.children.length : 'none'));
      const el = document.querySelector('.markmap');
      el.innerHTML = '';
      markmap.Markmap.create(el, null, root);
      __info.push('created, svg=' + (el.querySelector('svg') !== null));
    } catch (e) {
      __info.push('ERR: ' + (e.stack || e.message));
    }
  })();
  </script></body></html>`;
  fs.writeFileSync(path.join(__dirname, 'mm-probe.html'), html);
  const browser = await chromium.launch({ channel: 'msedge' });
  const page = await browser.newPage();
  page.on('pageerror', e => console.log('pageerror:', e.message));
  await page.goto('file:///' + path.join(__dirname, 'mm-probe.html').replace(/\\/g, '/'));
  await page.waitForTimeout(1500);
  const info = await page.evaluate(() => window.__info);
  console.log(JSON.stringify(info, null, 1));
  await browser.close();
})().catch(e => { console.error('FAIL', e); process.exit(1); });
