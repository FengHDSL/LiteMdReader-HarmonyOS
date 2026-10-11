// 跨行 $…$ 合并 + 行内 $$…$$ 的**方案镜像验证**：
// 用《LaTeX 渲染能力测试清单》原文件跑一遍拟实现的解析增强，
// 输出"合并了什么、识别出了什么公式"，人工核对后再落 ArkTS。
const fs = require('fs');

const FILE = process.argv[2] || 'C:/Users/panda/OneDrive/文档/WeChat/xwechat_files/wxid_qu99r8xvf7522_39ec/msg/file/2026-10/LaTeX 渲染能力测试清单.md';
const raw = fs.readFileSync(FILE, 'utf8').replace(/\r/g, '');
const lines = raw.split('\n');

// ── 拟实现：mergeCrossLineDollar（与 ArkTS 版逐行对应）──
const MAX_SPAN = 62;    // 首行到闭合行的最大行距
const MAX_BODY = 800;   // 公式内容最大字符数

function countDollar(s) {
  let n = 0;
  for (let k = 0; k < s.length; k++) {
    if (s.charAt(k) === '$') { n++; }
  }
  return n;
}

function mergeCrossLineDollar(lines) {
  const out = [];
  let i = 0;
  let merged = [];
  while (i < lines.length) {
    const tail = lines[i].replace(/\s+$/, '');
    // 首行：行尾单 $，且该行 $ 总数为奇数（有未闭合的 $ 才需要跨行合并；
    // 完整单行公式 $…$ 的 $ 数是偶数，绝不误并）
    if (tail.length >= 2 && tail.endsWith('$') && !tail.endsWith('$$')
      && countDollar(tail) % 2 === 1) {
      const probeEnd = Math.min(lines.length, i + MAX_SPAN);
      let j = i + 1;
      let found = -1;
      while (j < probeEnd) {
        const cj = lines[j].replace(/\s+$/, '');
        // 闭合行同样要求：行尾单 $ + 行内 $ 数为奇数（未闭合形态）
        if (cj.endsWith('$') && !cj.endsWith('$$')
          && countDollar(cj) % 2 === 1) { found = j; break; }
        j++;
      }
      if (found > i) {
        // 中间行（去空行）join，加上闭合行去尾 $ 的部分
        const parts = [];
        for (let k = i + 1; k < found; k++) {
          const t = lines[k].trim();
          if (t.length > 0) { parts.push(t); }
        }
        const closeTail = lines[found].replace(/\s+$/, '');
        const closeBody = closeTail.substring(0, closeTail.length - 1).trim();
        if (closeBody.length > 0) { parts.push(closeBody); }
        const content = parts.join(' ').trim();
        const ok = content.length > 0 && content.length <= MAX_BODY
          && content.indexOf('$') < 0
          && (content.indexOf('\\') >= 0 || content.indexOf('&') >= 0);
        if (ok) {
          out.push(tail + content + '$');
          merged.push({ from: i + 1, to: found + 1, line: tail + content + '$' });
          i = found + 1;
          continue;
        }
      }
    }
    out.push(lines[i]);
    i++;
  }
  return { lines: out, merged: merged };
}

// ── 拟实现：行内 $$…$$ 识别（模拟行内解析器的该分支）──
function scanInlineDollar(src) {
  const found = [];
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src.charAt(i);
    if (c === '$' && i + 1 < n && src.charAt(i + 1) === '$') {
      const closeD = src.indexOf('$$', i + 2);
      if (closeD > i + 2) {
        const content = src.substring(i + 2, closeD);
        if (content.trim().length > 0) {
          found.push({ kind: 'display-inline', content: content });
          i = closeD + 2;
          continue;
        }
      }
      i += 2;
      continue;
    }
    if (c === '$' && i + 1 < n && src.charAt(i + 1) !== '$' && src.charAt(i + 1) !== ' ') {
      let close = -1;
      for (let k = i + 1; k < n; k++) {
        if (src.charAt(k) === '$') {
          if (k > i + 1 && src.charAt(k - 1) !== ' ') { close = k; }
          break;
        }
      }
      if (close > i + 1) {
        const content = src.substring(i + 1, close);
        if (content.trim().length > 0 && content.indexOf('$') < 0) {
          found.push({ kind: 'inline', content: content });
          i = close + 1;
          continue;
        }
      }
    }
    i++;
  }
  return found;
}

// ── 跑合并 ──
const r = mergeCrossLineDollar(lines);
console.log('=== 合并命中 ' + r.merged.length + ' 处（预期 6 处矩阵）===');
for (const m of r.merged) {
  console.log('L' + m.from + '-' + m.to + ': ' + m.line.slice(0, 150));
}

// ── 对合并后的行扫 $$ 与 $ ──
console.log('\n=== 合并后各行行内公式识别（只列 $$ 与 含 \begin 的 $）===');
let dbg = 0;
for (let k = 0; k < r.lines.length; k++) {
  const src = r.lines[k];
  if (src.indexOf('$') < 0) { continue; }
  const hits = scanInlineDollar(src);
  for (const h of hits) {
    if (h.kind === 'display-inline' || h.content.indexOf('\\begin') >= 0) {
      dbg++;
      console.log('L' + (k + 1) + ' [' + h.kind + '] ' + h.content.slice(0, 130));
    }
  }
}
console.log('（共 ' + dbg + " 处，预期：6 矩阵 + 3 求和/乘积/有限求和 = 9 处）");

// ── 反向核查：原文件里"行尾单 $"但未合并的行（确认没有漏或误伤）──
console.log('\n=== 原文件中所有"行尾单 $"的行及其合并状态 ===');
let checked = 0;
for (let k = 0; k < lines.length; k++) {
  const t = lines[k].replace(/\s+$/, '');
  if (t.endsWith('$') && !t.endsWith('$$') && t.length >= 2) {
    checked++;
    const wasMerged = r.merged.some(m => m.from === k + 1);
    console.log('L' + (k + 1) + (wasMerged ? ' [已合并] ' : ' [未合并] ') + t.slice(0, 90));
  }
}
console.log('共 ' + checked + ' 行');
