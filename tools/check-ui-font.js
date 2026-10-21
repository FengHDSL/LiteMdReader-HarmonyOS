/**
 * 界面字体 / 字号 / 字重的**进度表**（只读统计，不改任何源码）
 * =========================================================
 *
 * ArkUI 没有应用级字体钩子（Theme 只有 colors，fontFamily / fontSize / fontWeight 都不是
 * 通用属性），所以这三项都只能一处一处挂。这个脚本把每个 .ets 里带文字组件的数量与
 * 三项覆盖面摆出来：字体 = `.fontFamily(`，字号 = 走 `HwFont.sx(`，字重 = 走 `HwFont.bump(`。
 * 当清单与进度用，**不是门禁**（正则读不懂属性链，数字是估算）。
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
let totalSz = 0;
let totalSzOk = 0;
let totalWt = 0;
let totalWtOk = 0;

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
    let sizeNodes = 0;
    let sizeScaled = 0;
    let weightNodes = 0;
    let weightBumped = 0;
    for (let i = 0; i < lines.length; i++) {
      const raw = lines[i];
      const t = raw.trim();
      if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) {
        continue;
      }
      // Text( 起始节点（含 Text() { 带子节点的写法）；带文字的组件不止 Text：
      // Button / TextInput / TextArea / Marquee 也各自有 fontFamily，一并算进清单
      if (/^(Text|Button|TextInput|TextArea|Marquee)\s*\(/.test(t)) {
        textNodes++;
        // 往后扫属性链（最多 12 行），见到 fontFamily 就算已挂
        for (let k = i; k < Math.min(i + 12, lines.length); k++) {
          const l = lines[k];
          if (k > i && /^\s*(Text|TextInput|TextArea|Button|Marquee|Row|Column|Stack|List|Scroll|Grid|if |ForEach)\b/.test(l)) {
            break;
          }
          if (l.indexOf('fontFamily') >= 0) {
            withFont++;
            break;
          }
        }
      }
    }
    const sz = countStyle(lines, /^\s*\.fontSize\(/, /HwFont\.sx\(/);
    sizeNodes = sz.n;
    sizeScaled = sz.ok;
    const wt = countStyle(lines, /^\s*\.fontWeight\(/, /HwFont\.bump\(/);
    weightNodes = wt.n;
    weightBumped = wt.ok;
    if (textNodes > 0) {
      rows.push({ f: path.relative(path.join(__dirname, '..'), p), n: textNodes, has: withFont,
        sz: sizeNodes, szOk: sizeScaled, wt: weightNodes, wtOk: weightBumped });
      totalText += textNodes;
      totalHas += withFont;
      totalSz += sizeNodes;
      totalSzOk += sizeScaled;
      totalWt += weightNodes;
      totalWtOk += weightBumped;
    }
  }
}

// 字号 / 字重的覆盖面：整文件行级统计（这两项是"改写现有那一行"，不需要读属性链）
function countStyle(lines, callRe, doneRe) {
  let n = 0;
  let ok = 0;
  for (const raw of lines) {
    const t = raw.trim();
    if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) {
      continue;
    }
    if (callRe.test(t)) {
      n++;
      if (doneRe.test(t)) {
        ok++;
      }
    }
  }
  return { n: n, ok: ok };
}

walk(ROOT);
rows.sort((a, b) => (b.n - b.has) - (a.n - a.has));
for (const r of rows) {
  const todo = r.n - r.has;
  console.log((todo === 0 ? '  完成  ' : todo > 20 ? '  很多  ' : '  待挂  ')
    + r.f + '  字体 ' + r.has + '/' + r.n
    + '  字号 ' + r.szOk + '/' + r.sz + '  字重 ' + r.wtOk + '/' + r.wt
    + '  待=' + todo);
}
console.log('');
console.log('字体：' + totalText + ' 个带文字组件，已挂 ' + totalHas + '，待挂 ' + (totalText - totalHas)
  + '；字号：已改 ' + totalSzOk + '/' + totalSz + '；字重：已改 ' + totalWtOk + '/' + totalWt
  + '（估算：正则读不懂属性链，实际以逐处为准）');
