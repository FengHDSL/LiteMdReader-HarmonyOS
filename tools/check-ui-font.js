/**
 * 界面字体逐点挂点的**进度表**（只读统计，不改任何源码）
 * ===================================================
 *
 * ArkUI 没有应用级字体钩子（Theme 只有 colors，fontFamily 不是通用属性），
 * 所以「界面字体」只能一处一处给 Text 挂 `.fontFamily(HwFont.resolve(this.uiFontKey))`。
 * 这个脚本把每个 .ets 里 Text( 的数量与已有 fontFamily 的数量摆出来，
 * 当作啃这 854 处的清单与进度；估算值，不作为门禁（正则读不懂属性链）。
 *
 * 用法：node tools/check-ui-font.js
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets');
const SKIP_MARKS = ['//', '*', 'Text(', '  ']; // 注释里的 Text( 不计：靠行首判断
const rows = [];
let totalText = 0;
let totalHas = 0;

function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      walk(p);
      continue;
    }
    if (!e.name.endsWith('.ets')) {
      continue;
    }
    const lines = fs.readFileSync(p, 'utf8').split(/\r?\n/);
    let textNodes = 0;
    let withFont = 0;
    for (let i = 0; i < lines.length; i++) {
      const raw = lines[i];
      const t = raw.trim();
      if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) {
        continue;
      }
      // Text( 起始节点（含 Text() { 带子节点的写法）
      if (/^Text\s*\(/.test(t)) {
        textNodes++;
        // 往后扫属性链（最多 12 行），见到 fontFamily 就算已挂
        for (let k = i; k < Math.min(i + 12, lines.length); k++) {
          const l = lines[k];
          if (k > i && /^\s*(Text|Button|Row|Column|Stack|List|Scroll|if |ForEach)\b/.test(l)) {
            break;
          }
          if (l.indexOf('fontFamily') >= 0) {
            withFont++;
            break;
          }
        }
      }
    }
    if (textNodes > 0) {
      rows.push({ f: path.relative(path.join(__dirname, '..'), p), n: textNodes, has: withFont });
      totalText += textNodes;
      totalHas += withFont;
    }
  }
}

walk(ROOT);
rows.sort((a, b) => (b.n - b.has) - (a.n - a.has));
for (const r of rows) {
  const todo = r.n - r.has;
  console.log((todo === 0 ? '  完成  ' : todo > 20 ? '  很多  ' : '  待挂  ')
    + r.f + '  Text=' + r.n + ' 已挂=' + r.has + ' 待=' + todo);
}
console.log('');
console.log('合计 Text 节点 ' + totalText + ' / 已挂 fontFamily ' + totalHas
  + ' / 待挂 ' + (totalText - totalHas) + '（估算：正则读不懂属性链，实际以逐处为准）');
