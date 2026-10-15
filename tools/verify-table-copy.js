#!/usr/bin/env node
/**
 * 表格复制三格式实测：跑**真 TableTool.ets**（SDK typescript 转成 CJS，与
 * verify-syntax-coverage.js 同一套路），验「复制为 Markdown / CSV / TSV」三条出口：
 *  · Markdown：列对齐要还原、单元格里的竖线要重新转义、粘回去还能被解析回同一张表；
 *  · CSV / TSV：含分隔符或引号的单元格整体加引号、内部引号翻倍（RFC 4180），换行压成空格。
 * 用法：node tools/verify-table-copy.js
 */
'use strict';
const fs = require('fs');
const path = require('path');
const TS_MOD =
  'C:/Users/panda/AppData/Local/OpenHarmony/Sdk/26.0.0/ets/build-tools/ets-loader/node_modules/typescript';
const ts = require(TS_MOD);
const ROOT = path.join(__dirname, '..');
const OUT = path.join(ROOT, '.workbuddy', 'table-cjs');

fs.mkdirSync(OUT, { recursive: true });
const src = fs.readFileSync(path.join(ROOT, 'entry/src/main/ets/service/TableTool.ets'), 'utf8').replace(/\r\n/g, '\n');
const r = ts.transpileModule(src, {
  fileName: 'TableTool.ets',
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, esModuleInterop: true, alwaysStrict: false },
});
if ((r.diagnostics || []).length > 0) {
  console.log('FAIL 转译诊断：' + r.diagnostics.map((d) => ts.flattenDiagnosticMessageText(d.messageText, ' ')).join(' | '));
  process.exit(1);
}
fs.writeFileSync(path.join(OUT, 'TableTool.js'), r.outputText);
const { TableTool } = require(path.join(OUT, 'TableTool.js'));
const NL = String.fromCharCode(10);
const TAB = String.fromCharCode(9);

let fails = 0;
function ok(cond, label, got) {
  if (cond) { console.log('  ok    ' + label); return; }
  fails++;
  console.log('  FAIL  ' + label + (got === undefined ? '' : ' —— 实得 ' + JSON.stringify(got)));
}

const lines = [
  '| 名称 | 数量 | 备注 |',
  '| :--- | ---: | :---: |',
  '| 含,逗号 | 3 | 带**粗** |',
  '| 引号"x" | 4 | 竖线\\|分隔 |',
  '| 换行 | 5 | 第二格长文本 |',
];
const t = TableTool.parse(lines);
ok(t !== null && t.header.length === 3, '解析出 3 列表格', t === null ? null : t.header);
ok(t.align[0] === 'left' && t.align[1] === 'right' && t.align[2] === 'center', '三列对齐分别识别为 left/right/center', t.align);

const md = TableTool.toLines(t).join(NL);
ok(md.split(NL)[1].indexOf(':---') >= 0 && md.split(NL)[1].indexOf('---:') >= 0, 'Markdown 分隔行还原了列对齐', md.split(NL)[1]);
ok(md.indexOf('\\|') >= 0, '单元格里的裸竖线被重新转义成 \\|', md.split(NL)[3]);
const back = TableTool.parse(md.split(NL));
ok(back !== null && back.rows[1][2] === '竖线|分隔', '复制出的 Markdown 粘回去还是同一张表（竖线格没被切开）',
  back === null ? null : back.rows[1]);
ok(back !== null && back.align[1] === 'right', '往返后对齐样式没丢', back === null ? null : back.align);

const csv = TableTool.toDelimited(t, ',').split(NL);
ok(csv[0] === '名称,数量,备注', 'CSV 表头行', csv[0]);
ok(csv[1].indexOf('"含,逗号"') === 0, 'CSV：含逗号的单元格整体加引号', csv[1]);
ok(csv[2].indexOf('""') >= 0, 'CSV：内部引号翻倍', csv[2]);

const tsv = TableTool.toDelimited(t, TAB).split(NL);
ok(tsv.every((row) => row.split(TAB).length === 3), 'TSV 每行正好 3 个字段', tsv.map((x) => x.split(TAB).length));
ok(tsv[1].indexOf('含,逗号') >= 0 && tsv[1].indexOf('"') < 0, 'TSV 里逗号不需要转义', tsv[1]);

console.log(fails === 0 ? '\nTABLE COPY OK — Markdown / CSV / TSV 三条出口逐条实测通过'
  : '\nTABLE COPY FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
