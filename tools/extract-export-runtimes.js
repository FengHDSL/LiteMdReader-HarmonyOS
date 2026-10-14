'use strict';
// 从阅读页模板里**逐字抽出**导出要用的渲染库，落成 rawfile/runtimes + tools/runtimes 两份。
//
// 为什么方向是"模板 → runtimes"而不是反过来下载 npm：
// 导出与阅读页必须是**同一份字节**，否则就会出现"阅读页画得对、导出的网页画错/画不出"
// （这类分裂已经发生过：runtimes/mermaid.min.js 停在 10.9 而模板已是 11.17）。
// 抽完之后 tools/check-inline-libs.js 会拿这份 runtimes 去模板里找全文，
// 标 [FULL] 才算数——升级任一侧都会被它抓到。
//
// 用法：node tools/extract-export-runtimes.js
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const RENDER = path.join(ROOT, 'entry/src/main/resources/rawfile/render');
const RAW_RUN = path.join(ROOT, 'entry/src/main/resources/rawfile/runtimes');
const TOOL_RUN = path.join(ROOT, 'tools/runtimes');

/** 模板里的 <script> 段（按出现顺序）。 */
function segs(file) {
  const doc = fs.readFileSync(path.join(RENDER, file), 'utf8');
  const re = /<script[^>]*>([\s\S]*?)<\/script>/g;
  const out = [];
  let m;
  while ((m = re.exec(doc)) !== null) { out.push(m[1]); }
  return out;
}

// 每项：{ 目标文件名, 来源模板, 段序号, 认库的头部特征 }
const JOBS = [
  { name: 'graphre.min.js', from: 'nomnoml.html', idx: 0, expect: '!function(e,r){' },
  { name: 'nomnoml.js', from: 'nomnoml.html', idx: 1, expect: '(function (global, factory)' },
  { name: 'chart.umd.js', from: 'chart.html', idx: 0, expect: '/*!\n * Chart.js v' },
];

for (const j of JOBS) {
  const list = segs(j.from);
  const body = list[j.idx];
  if (body === undefined) {
    console.error('FAIL  ' + j.from + ' 第 ' + (j.idx + 1) + ' 段不存在（模板结构变了，先核对再抽）');
    process.exit(1);
  }
  if (body.indexOf(j.expect) !== 0) {
    console.error('FAIL  ' + j.from + ' 第 ' + (j.idx + 1) + ' 段不再是 ' + j.name
      + '（头部实际是 ' + JSON.stringify(body.slice(0, 40)) + '）——别硬抽，先看清模板改成什么样了');
    process.exit(1);
  }
  // ⚠️ **一个字节都不许动**：check-inline-libs.js 是拿这份 runtimes 去模板里找**全文**，
  // 首尾多一个换行就变成 [HEAD-ONLY]，那正是"两份拷贝悄悄漂移"的开始。
  const text = body;
  for (const dir of [RAW_RUN, TOOL_RUN]) {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, j.name), text);
  }
  console.log('  out  ' + j.name + '  ' + (text.length / 1024 | 0) + 'KB  ← ' + j.from
    + ' 第 ' + (j.idx + 1) + ' 段（rawfile/runtimes 与 tools/runtimes 各一份）');
}
console.log('下一步：node tools/check-inline-libs.js —— 三行都该是 [FULL]');
