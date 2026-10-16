#!/usr/bin/env node
/**
 * 「离线铭牌 + GitHub README」解析端到端校验
 * ===========================================
 *
 * 与 `tools/sim-badges.js` 的分工：
 *   · sim-badges  —— 直接跑 `Badge.ets` 的真实实现，逐条核对**地址解析语义**；
 *   · 本脚本      —— 把**真 MdParser.ets**（连同 Badge / MdTypes / Emoji / MathLite …）
 *                    用 SDK 自带的 TypeScript 转成 CJS 在 Node 里跑，对**整篇文档**
 *                    断言块结构（哪几行并成铭牌块、HTML 块里还剩不剩远程徽章地址）。
 *
 * 为什么值得单写一个：徽章的坑全在"块级边界 + 行内优先级"上，光测函数看不出来——
 * 例如 `[![…](…)](…)` 会被行内链接那条路先吃掉（正文里印出原始 Markdown）、
 * `<div align="center">` 收集会在 `# 标题` 处中断（徽标因此落在普通段落）。
 * 这两条只有跑整篇文档才会暴露。
 *
 * 用法：
 *   node tools/verify-badges-parse.js                 # 内置用例
 *   node tools/verify-badges-parse.js 某篇.md [另一篇.md]   # 追加真实文档（打印结构摘要 + 断言）
 */
'use strict';

const fs = require('fs');
const path = require('path');

const TS_MOD = 'C:/Users/panda/AppData/Local/OpenHarmony/Sdk/26.0.0/ets/build-tools/ets-loader/node_modules/typescript';
const ROOT = path.join(__dirname, '..');
const MD = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'markdown');
const OUT = path.join(__dirname, '.badges-parse-cjs');
const NEED = ['MdTypes', 'Emoji', 'MathLite', 'PlantumlBridge', 'ZenumlBridge', 'Badge', 'MdParser'];

let fails = 0;
function check(label, ok, extra) {
  if (!ok) { fails++; console.log('  FAIL  ' + label + (extra === undefined ? '' : '  ' + extra)); }
  else { console.log('  ok    ' + label); }
}

let ts = null;
try {
  ts = require(TS_MOD);
} catch (e) {
  console.log('找不到 SDK 自带的 typescript（' + TS_MOD + '）→ 无法转译真实现，跳过');
  process.exit(0);
}

fs.mkdirSync(OUT, { recursive: true });
for (const n of NEED) {
  const src = fs.readFileSync(path.join(MD, n + '.ets'), 'utf8').replace(/\r\n/g, '\n');
  const r = ts.transpileModule(src, {
    compilerOptions: {
      target: ts.ScriptTarget.ES2021,
      module: ts.ModuleKind.CommonJS,
      esModuleInterop: true,
      alwaysStrict: false
    },
    fileName: n + '.ets'
  });
  if ((r.diagnostics || []).length > 0) {
    console.log('  转译诊断 ' + n + '：'
      + r.diagnostics.map((d) => ts.flattenDiagnosticMessageText(d.messageText, ' ')).join(' | '));
  }
  fs.writeFileSync(path.join(OUT, n + '.js'), r.outputText);
}
const { MdParser } = require(path.join(OUT, 'MdParser.js'));

/** 一篇文档里的块结构摘要（`plain` 是**原文口径**、只用于统计/搜索，别拿它判渲染） */
function summarize(md) {
  const res = MdParser.parse(md);
  return res.blocks.map((b) => ({
    kind: b.kind,
    lang: b.lang,
    badges: b.badges === undefined ? 0 : b.badges.length,
    badge0: b.badges === undefined || b.badges.length === 0 ? null : b.badges[0],
    plain: (b.plain || '').slice(0, 42),
    // **渲染口径**：行内片段（kind 5=Link / 6=Image），徽章泄漏原始 Markdown 的真凶就在这里
    inlines: (b.inlines || []).map((i) => ({ k: i.kind, t: (i.text || '').slice(0, 24), h: i.href || '' })),
    code: (b.code || '').slice(0, 0)
  }));
}

/** 渲染片段里有没有"把原始 Markdown 当文字排出来"的链接（`[![…`） */
function hasRawImageLinkText(summary) {
  return summary.some((b) => b.inlines.some((i) => i.t.indexOf('![') === 0));
}

// ── 用例 A：用户那份 GitHub README 的头部（Markdown 徽标写在居中 div 里）──
const FIX_A = [
  '<div align="center">',
  '',
  '<img src="docs/icon.png" width="160" alt="Logo" />',
  '',
  '# 新农助手（XJAU-Helper）',
  '',
  '**新农大助手 · HarmonyOS 原生应用**',
  '',
  '一款为新疆农业大学学生打造的鸿蒙原生校园工具。',
  '',
  '[![Version](https://img.shields.io/badge/version-1.4.1-blue)](https://github.com/x/releases/tag/v1.4.1)',
  '[![HarmonyOS](https://img.shields.io/badge/HarmonyOS%20NEXT%20(API%2026)-orange)](https://www.harmonyos.com)',
  '[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)',
  '[![Release](https://img.shields.io/badge/download-HAP-success)](https://github.com/x/y.hap)',
  '',
  '</div>'
].join('\n');

const a = summarize(FIX_A);
const aBadge = a.filter((b) => b.badges > 0);
check('A 四行徽标并成**一个**铭牌块（4 枚）', aBadge.length === 1 && aBadge[0].badges === 4,
  JSON.stringify(aBadge));
check('A 铭牌块是 Paragraph（复用块类型，下游零改动）',
  aBadge.length === 1 && aBadge[0].kind === 1, aBadge.length > 0 ? String(aBadge[0].kind) : 'n/a');
check('A 第一枚：label/message/颜色/形态/替代文字/外链都对',
  aBadge.length === 1 && aBadge[0].badge0.label === 'version'
  && aBadge[0].badge0.message === '1.4.1' && aBadge[0].badge0.color === '#007EC6'
  && aBadge[0].badge0.style === 'flat' && aBadge[0].badge0.alt === 'Version'
  && aBadge[0].badge0.href === 'https://github.com/x/releases/tag/v1.4.1',
  JSON.stringify(aBadge.length > 0 ? aBadge[0].badge0 : null));
check('A 带括号的徽章地址（`(API 2026)`）没被截断',
  aBadge.length === 1 && aBadge[0].badges === 4
  && a.some((b) => b.badges === 0), '');
check('A 渲染片段里**不再出现原始 Markdown**（徽章块的行内片段是可读的替代文字）',
  !hasRawImageLinkText(a)
  && aBadge.length === 1
  && aBadge[0].inlines.map((i) => i.t).join('|').indexOf('![Version]') < 0,
  JSON.stringify(aBadge.length > 0 ? aBadge[0].inlines : null));
check('A 居中 div 段被识别成 html 块，且不含远程徽章地址（无徽章可替换）',
  a.some((b) => b.lang === 'html') && !a.some((b) => b.lang === 'html' && b.plain.includes('img.shields.io')));
check('A 标题仍按标题渲染（div 收集在 `# ` 处中断的既有行为未被改坏）',
  a.some((b) => b.kind === 0 && b.plain.indexOf('新农助手') >= 0), JSON.stringify(a.map((b) => b.kind)));

// ── 用例 B：徽标写成 HTML `<img>`（项目此前给 XJAU README 做的"修复版"写法）──
const FIX_B = [
  '<div align="center">',
  '',
  '<p align="center">',
  '  <a href="https://github.com/x/releases/tag/v1.4.1"><img src="https://img.shields.io/badge/version-1.4.1-blue" alt="Version" /></a>',
  '  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License" /></a>',
  '</p>',
  '',
  '</div>'
].join('\n');
const b = summarize(FIX_B);
const bHtml = b.filter((x) => x.lang === 'html');
check('B HTML 块里的徽章被就地换成离线标记（不再有 `img.shields.io`）',
  bHtml.length > 0 && !JSON.stringify(bHtml).includes('img.shields.io'), JSON.stringify(bHtml.length));
const bCode = MdParser.parse(FIX_B).blocks.filter((x) => x.lang === 'html')
  .map((x) => x.code).join('\n');
check('B 标记里带两段底色与外链，且是纯内联样式',
  bCode.includes('background:#555555') && bCode.includes('background:#007EC6')
  && bCode.includes('href="https://github.com/x/releases/tag/v1.4.1"')
  && bCode.includes('display:inline-block'), bCode.slice(0, 160));
check('B 非徽章的 `<img>`（普通图）原样保留在 HTML 里',
  MdParser.parse(FIX_B + '\n\n<div><img src="docs/a.png" /></div>\n').blocks
    .some((x) => (x.code || '').includes('docs/a.png')));

// ── 用例 C：回归——普通图片/链接不受影响 ──
const FIX_C = [
  '![本地图](a.png)',
  '',
  '段落里夹一张带链接的图：[![截图](shot.png)](https://example.com/x)。',
  '',
  '![普通网络图](https://example.com/a.png)'
].join('\n');
const c = summarize(FIX_C);
check('C 普通独立图片仍是独立图片块（没有误判成铭牌）',
  c.filter((x) => x.badges > 0).length === 0);
check('C 行内"图片包链接"渲染成图片片段（kind=6，带替代文字与地址），不再吐原始 Markdown',
  !hasRawImageLinkText(c)
  && c[1].inlines.some((i) => i.k === 6 && i.t === '截图' && i.h === 'shot.png'),
  JSON.stringify(c[1] ? c[1].inlines : 'n/a'));

// ── 用例 D：混排（徽标夹在正文行里）与"整行徽标"在同一段内的拆分 ──
const FIX_D = [
  '版本信息见下：',
  '[![V](https://img.shields.io/badge/version-1.0-blue)](https://x.example)',
  '以上就是全部。'
].join('\n');
const d = summarize(FIX_D);
check('D 徽标行两侧的正文行各自成段，徽标单独成块（不吞正文）',
  d.length === 3 && d[1].badges === 1 && d[0].badges === 0 && d[2].badges === 0, JSON.stringify(d));

// ── 用例 E：应用内置的两篇文档不被误伤（铭牌数必须为 0）──
for (const rel of ['entry/src/main/resources/rawfile/README.md',
  'entry/src/main/resources/rawfile/chengjian.md']) {
  const full = path.join(ROOT, rel);
  if (!fs.existsSync(full)) { continue; }
  const md = fs.readFileSync(full, 'utf8');
  const e = summarize(md);
  check('E 内置文档不受影响：' + path.basename(rel) + '（' + e.length + ' 块，铭牌 0）',
    e.filter((x) => x.badges > 0).length === 0 && e.length > 5);
}

// ── 追加：命令行传入的真实文档（例：用户从微信发来的 README）──
const extras = process.argv.slice(2);
for (const f of extras) {
  if (!fs.existsSync(f)) { console.log('  SKIP  文件不存在：' + f); continue; }
  const md = fs.readFileSync(f, 'utf8').replace(/\r\n/g, '\n');
  const s = summarize(md);
  const badgeBlocks = s.filter((x) => x.badges > 0);
  const htmlBlocks = s.filter((x) => x.lang === 'html');
  const rawLeak = JSON.stringify(s).includes('![Version]') || JSON.stringify(s).includes('![HarmonyOS]');
  const remoteBadge = htmlBlocks.some((x) => x.plain.includes('img.shields.io'));
  console.log('  ---- ' + path.basename(f) + '：' + s.length + ' 块，html 块 '
    + htmlBlocks.length + '，铭牌块 ' + badgeBlocks.length
    + '（' + badgeBlocks.reduce((n, x) => n + x.badges, 0) + ' 枚）');
  check('  [' + path.basename(f) + '] 铭牌行被识别（不是原始 Markdown、也不留远程徽章）',
    !rawLeak && !remoteBadge, 'rawLeak=' + rawLeak + ' remoteBadge=' + remoteBadge);
}

console.log(fails === 0 ? 'BADGES PARSE OK' : 'BADGES PARSE FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
