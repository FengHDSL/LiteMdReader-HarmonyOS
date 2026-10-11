// Generate tools/fx-preview.html from the dino block currently inside
// chengjian.md, so what you review in a browser is byte-identical to what ships
// in the demo doc. Re-run after editing the doc block.
const fs = require('fs');
const path = require('path');

const doc = path.join(__dirname, '../entry/src/main/resources/rawfile/chengjian.md');
const out = path.join(__dirname, 'fx-preview.html');

const md = fs.readFileSync(doc, 'utf8').replace(/\r\n?/g, '\n');
const m = md.match(/```html\n([\s\S]*?)\n```/);
if (!m) throw new Error('no ```html block found in chengjian.md');
const game = m[1];

// Guard against a corrupted block (a past splice left a stray `$$` inside it and
// it rendered as literal text under the card).
if (!/^<style>/.test(game)) throw new Error('block does not start with <style>');
if (!/<\/script>$/.test(game.trim())) throw new Error('block does not end with </script>');
if (game.includes('$$') || /\$\{/.test(game)) throw new Error('stray `$` in block — splice escaping bug');
if ((game.match(/<script>/g) || []).length !== 1) throw new Error('expected exactly 1 <script>');

fs.writeFileSync(out, `<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>指尖烟花 · 预览</title>
<style>
  body { margin:0; padding:22px 16px 40px; background:#EDF1F8; color:#1B1F27;
         font:14px/1.7 "HarmonyOS Sans SC","PingFang SC",system-ui,sans-serif; }
  h1 { font-size:17px; margin:0 0 4px; }
  .sub { color:#5B7396; font-size:12.5px; margin-bottom:16px; }
  .bar { display:flex; gap:8px; flex-wrap:wrap; align-items:center; margin-bottom:14px; }
  .bar span { font-size:12.5px; color:#5B7396; }
  .bar button { font:12.5px inherit; padding:5px 11px; border-radius:999px; cursor:pointer;
                border:1px solid rgba(18,50,79,.16); background:#fff; color:#2A3F5F; }
  .bar button[aria-pressed="true"] { background:#2A3F5F; color:#fff; border-color:#2A3F5F; }
  /* 卡片宽度决定画布宽度 —— 用外框模拟手机正文里的卡片，验证自适应不拉伸 */
  #frame { width:380px; max-width:100%; margin:0 auto; transition:width .18s ease; }
  #frame.wide { width:100%; }
  @media (prefers-color-scheme: dark) { body { background:#171B24; color:#ECEFF4; }
    .sub,.bar span { color:#93A3BF; } .bar button { background:#232A38; color:#D6E0F2; border-color:#38445C; } }
</style>
</head><body>
<h1>✦ 指尖烟花 · 演示文档同款</h1>
<div class="sub">下面这块就是 chengjian.md 里那段 html 代码块的内容，一字未改。
换宽度是看它在不同卡片宽下会不会被拉伸。</div>
<div class="bar">
  <span>卡片宽度</span>
  <button data-w="300">300</button>
  <button data-w="360">360</button>
  <button data-w="380" aria-pressed="true">380</button>
  <button data-w="480">480</button>
  <button data-w="700">700</button>
  <button data-w="full" class="wide">铺满</button>
</div>
<div id="frame">
${game.split('\n').map(l => l ? '  ' + l : l).join('\n')}
</div>
<script>
(function () {
  var frame = document.getElementById('frame');
  var btns = document.querySelectorAll('.bar button');
  for (var i = 0; i < btns.length; i++) {
    btns[i].addEventListener('click', function () {
      for (var k = 0; k < btns.length; k++) { btns[k].setAttribute('aria-pressed', 'false'); }
      this.setAttribute('aria-pressed', 'true');
      frame.classList.toggle('wide', this.dataset.w === 'full');
      if (this.dataset.w !== 'full') { frame.style.width = this.dataset.w + 'px'; }
    });
  }
})();
</script>
</body></html>
`);
console.log('wrote ' + out + ' (' + game.split('\n').length + ' lines of game code)');
