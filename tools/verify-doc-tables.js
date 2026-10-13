#!/usr/bin/env node
/**
 * 内置文档的**表格列数一致性**检查（提交前自查）
 * ============================================
 *
 * 三篇内置文档（README / chengjian / capabilities）里的表格全靠本应用的解析器排版：
 * 一行里多一个或少一个 `|`，那一列就和表头对不上，手机上是整张表塌版而不是报错，
 * 所以人眼很容易漏过。这次改 capabilities.md 的支持矩阵那一格（注音说明）时，
 * 顺手把"每行列数 = 表头列数"和"单元格别写成整墙"两条量化了。
 *
 * 只读文件，不改任何东西。围栏里的内容不算表格（代码块里的 | 是正文）。
 * 列数按**未转义**的竖线切（跟解析器 splitRow 同一条规则）：`\|` 是单元格里的内容，
 * 不是分列——文档里正有一行拿它当示例，按字面 split 会把这条好行判成塌版。
 *
 * 用法：node tools/verify-doc-tables.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const RAW = path.join(__dirname, '..', 'entry', 'src', 'main', 'resources', 'rawfile');
const DOCS = ['README.md', 'chengjian.md', 'capabilities.md'];
/** 单元格超过这个字数就提个醒：同表其它格子普遍在 100 字以内，整墙说明该拆到正文里去 */
const CELL_WARN = 200;

/** 按未转义的竖线切单元格（解析器同款规则） */
function cellsOf(l) {
  const parts = [];
  let cur = '';
  for (let k = 0; k < l.length; k++) {
    const c = l.charAt(k);
    if (c !== '|') { cur += c; continue; }
    if (l.charAt(k - 1) === '\\') { cur += '|'; continue; }   // \| 是内容里的竖线
    parts.push(cur);
    cur = '';
  }
  parts.push(cur);
  if (parts.length > 1 && parts[0].trim().length === 0) { parts.shift(); }
  if (parts.length > 1 && parts[parts.length - 1].trim().length === 0) { parts.pop(); }
  return parts.map((s) => s.trim());
}

let bad = 0;
for (const doc of DOCS) {
  const lines = fs.readFileSync(path.join(RAW, doc), 'utf8').replace(/\r\n/g, '\n').split('\n');
  let inFence = false;
  let rows = [];
  let tables = 0;
  const flush = () => {
    if (rows.length < 2) { rows = []; return; }
    tables++;
    const header = rows[0];
    for (const r of rows) {
      if (r.cells.length !== header.cells.length) {
        bad++;
        console.log('  FAIL  ' + doc + ':' + r.line + ' 有 ' + r.cells.length
          + ' 列，表头（' + header.line + '）是 ' + header.cells.length + ' 列');
      }
      r.cells.forEach((c, i) => {
        if (c.length > CELL_WARN) {
          bad++;
          console.log('  FAIL  ' + doc + ':' + r.line + ' 第 ' + (i + 1) + ' 列写了 '
            + c.length + ' 字（同表普遍 <120），手机上会挤成竖排');
        }
      });
    }
    rows = [];
  };
  lines.forEach((l, i) => {
    const t = l.trim();
    if (t.startsWith('```')) { inFence = !inFence; if (!inFence) { flush(); } return; }
    if (inFence) { return; }
    if (t.startsWith('|')) {
      rows.push({ line: i + 1, cells: cellsOf(l) });
    } else if (rows.length) {
      flush();
    }
  });
  flush();
  console.log('  ' + doc + '：表格 ' + tables + ' 张'
    + (bad === 0 ? '，列数与格长都过关' : ''));
}
console.log(bad === 0 ? 'DOC TABLES OK' : 'DOC TABLES FAILED: ' + bad);
process.exit(bad === 0 ? 0 : 1);
