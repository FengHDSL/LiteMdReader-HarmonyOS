// 公式「保存公式」写回的逻辑校验。
//
// 覆盖 Reader.spliceMathBlock / spliceInlineMath 的两条要害：
//  ① **行段重取必须与 MdParser 逐行同构**——重取的 LaTeX 要和 block.code 对得上，
//     否则锚点校验误拒（合法写回被挡）或误放（写坏原文）；
//  ② 替换后的文档**重新解析要得到新 LaTeX**（单行/多行形态、$$ 与 \[ \] 两种定界符、
//     块内空行都要保住）。
//
// 语料 = 内置文档里真实存在的公式块（含 \begin 环境、_cases、\\ 换行、\tag）。
// MdParser 的抽取循环在此按原样重写；两处若有分歧，第 ① 步就会红。
const fs = require('fs');
const path = require('path');

const RAW = path.join(__dirname, '../entry/src/main/resources/rawfile');
const DOCS = ['chengjian.md'];
let fails = 0;
function check(name, ok, extra) {
  if (!ok) { fails++; console.log('  FAIL  ' + name + (extra ? '  ' + extra : '')); }
}

// ── MdParser 块级数学抽取（照抄 entry/src/main/ets/markdown/MdParser.ets 的两段）──
function parseMathBlocks(lines) {
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t.startsWith('\\[')) {
      const mathStart = i;
      const latexLines = [];
      let single = false;
      if (t.length > 4 && t.endsWith('\\]')) {
        latexLines.push(t.substring(2, t.length - 2).trim());
        single = true;
        i++;
      } else {
        latexLines.push(t.substring(2).trim());
        i++;
        while (i < lines.length) {
          const cur = lines[i].trim();
          if (cur.endsWith('\\]')) {
            const seg = cur.substring(0, cur.length - 2).trim();
            if (seg.length > 0) { latexLines.push(seg); }
            i++;
            break;
          }
          latexLines.push(cur);
          i++;
        }
      }
      const latex = latexLines.join('\n').trim();
      if (latex.length > 0) {
        out.push({ start: mathStart, end: single ? mathStart : i - 1, code: latex, single: single, delim: '\\[' });
      }
      continue;
    }
    if (t.startsWith('$$')) {
      const mathStart = i;
      const latexLines = [];
      let single = false;
      if (t.length > 4 && t.endsWith('$$')) {
        latexLines.push(t.substring(2, t.length - 2).trim());
        single = true;
        i++;
      } else {
        latexLines.push(t.substring(2).trim());
        i++;
        while (i < lines.length) {
          const cur = lines[i].trim();
          if (cur.endsWith('$$')) {
            const seg = cur.substring(0, cur.length - 2).trim();
            if (seg.length > 0) { latexLines.push(seg); }
            i++;
            break;
          }
          latexLines.push(cur);
          i++;
        }
      }
      const latex = latexLines.join('\n').trim();
      if (latex.length > 0) {
        out.push({ start: mathStart, end: single ? mathStart : i - 1, code: latex, single: single, delim: '$$' });
      }
      continue;
    }
  }
  return out;
}

// ── 被测：Reader.spliceMathBlock 的锚点重取 + 行段替换（与 ArkTS 同构）──
function reExtract(lines, blk) {
  const start = blk.start;
  const head = lines[start].trim();
  const delim = blk.delim;
  const close = delim === '$$' ? '$$' : '\\]';
  const single = head.length > delim.length + close.length && head.endsWith(close);
  const body = [];
  if (single) {
    body.push(head.substring(delim.length, head.length - close.length).trim());
  } else {
    body.push(head.substring(delim.length).trim());
    for (let k = start + 1; k < (single ? start : blk.end); k++) {
      body.push(lines[k].trim());
    }
    const tail = lines[blk.end].trim();
    const seg = tail.substring(0, tail.length - close.length).trim();
    if (seg.length > 0) { body.push(seg); }
  }
  return { latex: body.join('\n').trim(), single: single, close: close };
}
function spliceMath(lines, blk, newLatex) {
  const r = reExtract(lines, blk);
  if (r.latex !== blk.code) { return null; }
  const close = r.close;
  const replacement = r.single
    ? [blk.delim + newLatex + close]
    : [blk.delim].concat(newLatex.split('\n'), [close]);
  return lines.slice(0, blk.start).concat(replacement, lines.slice(blk.end + 1));
}

let total = 0;
for (const doc of DOCS) {
  const src = fs.readFileSync(path.join(RAW, doc), 'utf8').replace(/\r\n?/g, '\n');
  const lines = src.split('\n');
  const blocks = parseMathBlocks(lines);
  for (const blk of blocks) {
    total++;
    const id = doc + ':' + (blk.start + 1);
    // ① 锚点重取必须一致
    const r = reExtract(lines, blk);
    check('anchor re-extract ' + id, r.latex === blk.code,
      JSON.stringify(r.latex).slice(0, 60) + ' vs ' + JSON.stringify(blk.code).slice(0, 60));
    // ② 写回一个改过的 LaTeX，重新解析必须正好拿到它，且其余块不受扰动
    const marker = blk.code + ' %wb-check';
    const out = spliceMath(lines, blk, marker);
    check('splice produced file ' + id, out !== null);
    if (out === null) { continue; }
    const again = parseMathBlocks(out);
    const hit = again.filter(b => b.start >= 0).find(b => b.code === marker);
    check('round-trip new latex ' + id, hit !== undefined, 'got ' + again.length + ' blocks');
    if (hit !== undefined) {
      check('round-trip keeps line form ' + id, hit.single === blk.single,
        'was single=' + blk.single + ' now single=' + hit.single);
    }
    // ③ 其它块数量不变（写回不该多吃/少吃正文）
    check('block count stable ' + id, again.length === blocks.length,
      again.length + ' vs ' + blocks.length);
  }
}

// ── 行内公式写回：定位、空表、多处同串 ──
function spliceInline(lines, from, to, oldLatex, newLatex) {
  if (oldLatex.length === 0 || newLatex.indexOf('$') >= 0) { return null; }
  const forms = [['$' + oldLatex + '$', '$' + newLatex + '$'],
    ['\\(' + oldLatex + '\\)', '\\(' + newLatex + '\\)']];
  const lo = Math.max(0, from);
  const hi = Math.min(lines.length - 1, to);
  for (const f of forms) {
    let hitLine = -1;
    let hits = 0;
    for (let k = lo; k <= hi; k++) {
      let at = lines[k].indexOf(f[0]);
      while (at >= 0) { hits++; hitLine = k; at = lines[k].indexOf(f[0], at + f[0].length); }
    }
    if (hits === 0) { continue; }
    if (hits > 1) { return null; }
    const fixed = lines[hitLine].split(f[0]).join(f[1]);
    return lines.slice(0, hitLine).concat([fixed], lines.slice(hitLine + 1));
  }
  return null;
}
{
  const L = ['正文 $E=mc^2$ 结尾', '另一段 $a+b$ 与 $a+b$ 同行'];
  const ok = spliceInline(L, 0, 0, 'E=mc^2', 'E = mc^2');
  check('inline single hit replaced', ok !== null && ok[0] === '正文 $E = mc^2$ 结尾', ok && ok[0]);
  check('inline other line untouched', ok !== null && ok[1] === L[1]);
  check('inline duplicate refused', spliceInline(L, 1, 1, 'a+b', 'x') === null);
  check('inline missing refused', spliceInline(L, 0, 0, 'nope', 'x') === null);
  check('inline new-with-dollar refused', spliceInline(L, 0, 0, 'E=mc^2', '$x$') === null);
  const br = ['用 \\(\\alpha\\) 表示角'];
  const okbr = spliceInline(br, 0, 0, '\\alpha', '\\beta');
  check('inline \\(\\) form replaced', okbr !== null && okbr[0] === '用 \\(\\beta\\) 表示角', okbr && okbr[0]);
}

// ── 边界形态：块内空行、单行、\\[ \\] 多行 ──
{
  const L = ['$$', 'a', '', 'b', '$$', '正文'];
  const b = parseMathBlocks(L)[0];
  check('blank line inside preserved by parser', b.code === 'a\n\nb', JSON.stringify(b.code));
  const out = spliceMath(L, b, 'a\n\nb');
  check('blank line inside accepted by anchor', out !== null && out.join('\n') === L.join('\n'));

  const L2 = ['$$x^2$$', '正文'];
  const b2 = parseMathBlocks(L2)[0];
  check('single-line form detected', b2.single === true && b2.code === 'x^2');
  const o2 = spliceMath(L2, b2, 'y^2');
  check('single-line form preserved', o2 !== null && o2[0] === '$$y^2$$', o2 && o2[0]);

  const L3 = ['\\[', 'a_1', '\\]'];
  const b3 = parseMathBlocks(L3)[0];
  check('bracket form parsed', b3 !== undefined && b3.code === 'a_1');
  const o3 = spliceMath(L3, b3, 'a_2');
  check('bracket form round-trips', o3 !== null && parseMathBlocks(o3)[0].code === 'a_2',
    o3 && JSON.stringify(o3));

  // 行号漂移（文档被外部改过）必须拒绝，不能把新内容写进错位
  const L4 = ['插入一行', '$$', 'a', '$$'];
  const stale = { start: 0, end: 2, code: 'a', single: false, delim: '$$' };
  check('drifted line refused', spliceMath(L4, stale, 'b') === null);
}

console.log(fails === 0 ? 'MATH WRITE-BACK OK (' + total + ' doc formula blocks + edge cases)'
  : 'MATH WRITE-BACK FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
