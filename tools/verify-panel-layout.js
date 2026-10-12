#!/usr/bin/env node
/**
 * 展开面板排版的离线校验（**只读源码，不改源码**）
 * ==============================================
 *
 * 把 Editor.ets 里 SNIPPETS 的 label / group / 有无 icon 原样解析出来，
 * 再用与 ArkTS 端**同一套算式**（estTextVp / groupCellVp / groupLayout）
 * 重算一遍宽度与切行，检查用户提的三条硬性要求：
 *
 *   ① 同组每颗按钮宽度一致（= 最长那颗），所以列必须对齐、字不被裁；
 *   ② 一行放得下才放，放不下自动换行（任何屏宽下都不溢出）；
 *   ③ 每个按钮都有可读的长按气泡文案。
 *
 * 直接 `node tools/verify-panel-layout.js`，全部通过退出码 0。
 */
'use strict';

const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets', 'pages', 'Editor.ets');
const body = fs.readFileSync(SRC, 'utf8');

let failures = 0;
function check(label, ok, extra) {
  if (!ok) {
    failures++;
    console.log('FAIL ' + label + (extra === undefined ? '' : ' :: ' + extra));
  } else {
    console.log('ok   ' + label);
  }
}

// ── 解析 SNIPPETS ──────────────────────────────────────────────
// 每条占一行，按字段名取值；icon 只关心"有没有"（符号组刻意不配图标）。
const items = [];
for (const line of body.split(/\r?\n/)) {
  if (!/^\s*\{ key:/.test(line)) {
    continue;
  }
  const key = line.match(/key:\s*'([^']*)'/);
  const label = line.match(/label:\s*'([^']*)'/);
  const group = line.match(/group:\s*'([^']*)'/);
  const tip = line.match(/tip:\s*'([^']*)'/);
  const before = line.match(/before:\s*'((?:[^'\\]|\\.)*)'/);
  const after = line.match(/after:\s*'((?:[^'\\]|\\.)*)'/);
  const holder = line.match(/holder:\s*'([^']*)'/);
  if (!key || !label || !group) {
    console.log('FAIL 解析字段不全: ' + line.trim().slice(0, 60));
    failures++;
    continue;
  }
  items.push({
    key: key[1],
    label: label[1],
    group: group[1],
    hasIcon: /icon:\s*\$r\(/.test(line),
    tip: tip ? tip[1] : '',
    before: before ? before[1] : '',
    after: after ? after[1] : '',
    holder: holder ? holder[1] : '',
  });
}
check('解析条目数 = 源码 { key: 行数',
  items.length === (body.match(/^\s*\{ key:/gm) || []).length,
  'parsed=' + items.length);

const GROUPS = ['fmt', 'chart', 'symcn', 'symben'];
const byGroup = {};
for (const g of GROUPS) {
  byGroup[g] = items.filter((it) => it.group === g);
  check('组 ' + g + ' 有条目', byGroup[g].length > 0, 'n=' + byGroup[g].length);
}
check('没有游离分组', items.every((it) => GROUPS.indexOf(it.group) >= 0),
  items.filter((it) => GROUPS.indexOf(it.group) < 0).map((it) => it.key).join(','));

// ── 与 ArkTS 同源的算式 ────────────────────────────────────────
function estTextVp(text, fp) {
  let em = 0;
  for (let i = 0; i < text.length; i++) {
    em += text.charCodeAt(i) > 0x2e80 ? 1 : 0.55;
  }
  return em * fp;
}

// 与 groupCellVp 保持一致：图标 15 + 间隙 6 + 内边距 16 + 余量 6
function needVp(it) {
  const fp = it.hasIcon ? 13 : 15;
  return estTextVp(it.label, fp) + (it.hasIcon ? 21 : 0) + 16 + 6;
}

function groupCellVp(list) {
  let w = 0;
  for (const it of list) {
    const n = needVp(it);
    if (n > w) {
      w = n;
    }
  }
  return Math.round(w);
}

function chunkRows(list, size) {
  const rows = [];
  for (let i = 0; i < list.length; i += size) {
    rows.push(list.slice(i, i + size));
  }
  return rows;
}

function groupLayout(list, rootWidth) {
  const cellVp = groupCellVp(list);
  const gap = 6;
  const avail = Math.max(140, rootWidth - 64);
  let cols = Math.floor((avail + gap) / (cellVp + gap));
  if (cols < 1) cols = 1;
  if (cols > 5) cols = 5;
  return { cellVp: cellVp, cols: cols, rows: chunkRows(list, cols), avail: avail, gap: gap };
}

// ── ① 宽度一致 + 不裁字 ────────────────────────────────────────
for (const g of GROUPS) {
  const cell = groupCellVp(byGroup[g]);
  const short = byGroup[g].filter((it) => needVp(it) > cell);
  check(g + '：cellVp 覆盖最长标签（无裁字）', short.length === 0,
    'cell=' + cell + ' 不足=' + short.map((it) => it.key).join(','));
  // cellVp 必须**恰好**等于需求最大的那颗（再大就是白浪费横向空间）。
  // 注意不能用 label.length 找"最长"：半角字符（如 ..）字数一样但视觉窄一半。
  const maxNeed = Math.max(...byGroup[g].map((it) => needVp(it)));
  const longest = byGroup[g].find((it) => needVp(it) === maxNeed);
  check(g + '：cellVp 紧贴最长标签「' + longest.label + '」（无多余宽度）',
    cell === Math.round(maxNeed), 'cell=' + cell + ' need=' + maxNeed.toFixed(1));
  console.log('     ' + g + ' cellVp=' + cell + ' 由「' + longest.label + '」决定，共 '
    + byGroup[g].length + ' 颗');
}

// ── ② 各屏宽下都不溢出、不缺条目 ───────────────────────────────
const WIDTHS = [320, 360, 384, 412, 450, 520, 600, 760, 1024, 1440];
for (const w of WIDTHS) {
  for (const g of GROUPS) {
    const L = groupLayout(byGroup[g], w);
    const rowW = (r) => r.length * L.cellVp + (r.length - 1) * L.gap;
    const over = L.rows.filter((r) => rowW(r) > L.avail + 0.5);
    check('屏宽 ' + w + ' · ' + g + '：每行不溢出', over.length === 0,
      'cols=' + L.cols + ' cell=' + L.cellVp + ' avail=' + L.avail +
      ' 溢出行=' + over.map((r) => r.length).join(','));
    const total = L.rows.reduce((s, r) => s + r.length, 0);
    check('屏宽 ' + w + ' · ' + g + '：条目无丢失/重复', total === byGroup[g].length,
      total + ' vs ' + byGroup[g].length);
    check('屏宽 ' + w + ' · ' + g + '：列数在 1..5', L.cols >= 1 && L.cols <= 5, 'cols=' + L.cols);
  }
}

// 单列时最窄的格子也不能超过可用宽（否则一定被裁）
for (const g of GROUPS) {
  const cell = groupCellVp(byGroup[g]);
  check(g + '：最窄可用宽(140) 也放得下一列', cell <= 140, 'cell=' + cell);
}

// ── ③ 长按气泡文案 ─────────────────────────────────────────────
// 与 tipFor 一致：手写 tip 优先，符号组给"插入字符 X"，其余从 before/after/holder 推。
function tipFor(it) {
  if (it.tip.length > 0) return it.tip;
  if (it.group === 'symcn' || it.group === 'symben') return '插入字符 ' + it.label;
  const b = it.before.split('\\n').join('⏎');
  const a = it.after.split('\\n').join('⏎');
  if (it.holder.length === 0) return '插入 ' + b;
  if (a.length === 0) return '插入 ' + b + ' …';
  return '包裹选中文字：' + b + ' … ' + a;
}
const badTips = [];
for (const it of items) {
  const t = tipFor(it);
  if (t.replace(/插入|包裹选中文字：|…|⏎|\s/g, '').length === 0) {
    badTips.push(it.key);
  }
}
check('每个按钮的提示文案都有实质内容', badTips.length === 0, badTips.join(','));

// 气泡挂在宽度 = cellVp 的格子里，文案太长会被系统气泡折行；给个上限提醒
const longTips = items.filter((it) => estTextVp(tipFor(it), 12) > 200).map((it) => it.key + '=' + tipFor(it));
if (longTips.length > 0) {
  console.log('注意 提示文案偏长（气泡会折行，可接受）: ' + longTips.join(' | '));
}

// ── 手写的 tip 必须和实际插入内容对得上（防止说明与行为漂移）────
const mismatches = [];
for (const it of items) {
  if (it.tip.length === 0) continue;
  // tip 里必须出现该条目的 before/after/holder 片段或标签（**忽略大小写 + 去掉围栏反引号**：
  // 代码块语言名在源码里是 ```echarts，提示里写「ECharts 配置」是正常表述）
  const norm = (s) => s.replace(/\\n/g, '').replace(/`/g, '').trim().toLowerCase();
  const raw = (it.before + '|' + it.after + '|' + it.holder).replace(/\\n/g, '');
  const tipRaw = it.tip.replace(/\\n/g, '');
  const tipLow = tipRaw.toLowerCase();
  let hit = false;
  for (const seg of raw.split('|')) {
    const s = norm(seg);
    if (s.length >= 2 && tipLow.indexOf(s) >= 0) { hit = true; break; }
  }
  // 纯中文说明型 tip 允许不带片段原文，但必须提到按钮标签
  const labelInTip = tipLow.indexOf(it.label.toLowerCase()) >= 0;
  if (!hit && !labelInTip) {
    mismatches.push(it.key + ': ' + tipRaw);
  }
}
check('手写 tip 与插入内容/标签一致', mismatches.length === 0, mismatches.join(' | '));

// ── 排版概览：手机上每组分几行几列（行数直接决定面板要不要滑动）──
console.log('\n排版概览');
for (const w of [360, 412, 760]) {
  const parts = GROUPS.map((g) => {
    const L = groupLayout(byGroup[g], w);
    return g + ' ' + L.cols + '列×' + L.rows.length + '行';
  });
  console.log('  屏宽 ' + w + '：' + parts.join('  |  '));
}

console.log('\n失败: ' + failures);
process.exit(failures === 0 ? 0 : 1);
