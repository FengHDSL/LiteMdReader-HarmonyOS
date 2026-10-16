#!/usr/bin/env node
/**
 * 「离线铭牌」（shields 徽章）解析与接入的校验
 * ============================================
 *
 * 与工程里其它 sim 的**关键区别**：本脚本不手抄一份端口去测，而是把
 * `Badge.ets` 与 `MdTypes.ets` 里的真实源码抽出来，补掉那条 `import`，
 * 存成 .ts 交给 Node 直接执行（Node 22 内置类型擦除）。因此这里测的就是
 * 应用里跑的那份实现，不存在"端口与实现漂移"。
 *
 * 徽章的语义细节（几段算 label/message/color、命名色的真实值）不是拍脑袋写的，
 * 是用 `tools/probe-shields.js` 逐条抓线上 SVG 实测校准的；本脚本把这些实测
 * 结论固化成用例，改动 Badge.ets 时先跑它。
 *
 * 用法：node tools/sim-badges.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const MD = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'markdown');
const read = (f) => fs.readFileSync(path.join(MD, f), 'utf8').replace(/\r\n/g, '\n');

const badgeEts = read('Badge.ets');
const typesEts = read('MdTypes.ets');
const parserEts = read('MdParser.ets');
const viewEts = read('MdView.ets');
const toHtmlEts = read('MdToHtml.ets');

let fails = 0;
function check(label, ok, extra) {
  if (!ok) { fails++; console.log('  FAIL  ' + label + (extra === undefined ? '' : '  ' + extra)); }
  else { console.log('  ok    ' + label); }
}

/** 取 `export interface X …` / `export class X …` 的整块（按花括号配平） */
function sliceBlock(src, headPattern) {
  const at = src.search(headPattern);
  if (at < 0) { return ''; }
  let depth = 0;
  let started = false;
  for (let k = at; k < src.length; k++) {
    const c = src.charAt(k);
    if (c === '{') { depth++; started = true; }
    else if (c === '}') {
      depth--;
      if (started && depth === 0) { return src.substring(at, k + 1); }
    }
  }
  return '';
}

// ── ① 源码同步：接入点都还在（改名 / 换函数会让本脚本与实现脱节）──
const MUST_BADGE_API = ['isBadgeUrl', 'parse', 'parseLine', 'toHtml', 'rewriteHtml', 'normalizeColor'];
const missingApi = MUST_BADGE_API.filter((f) => !new RegExp('static ' + f + '\\(').test(badgeEts));
check('① Badge.ets 的六个公开入口都在（改名会让校验与实现脱节）', missingApi.length === 0,
  missingApi.join(', '));
check('① 徽章命名色用的是**实测值**（shields 的 orange ≠ CSS orange）',
  badgeEts.includes("hex: '#EA7233'") && badgeEts.includes("hex: '#DD4343'")
  && badgeEts.includes("hex: '#67AC09'"));
check('① 解析器接上了铭牌识别：段落分支调 Badge.parseLine、块写入 block.badges',
  parserEts.includes('Badge.parseLine(para[bk])') && parserEts.includes('bb.badges = items'));
check('① HTML 块清洗后做徽章替换（阅读预览 / 导出 / EPUB 三处共用 block.code）',
  parserEts.includes('Badge.rewriteHtml(out)'));
check('① 行内"图片包链接"不再泄漏原始 Markdown（徽标显示成文本的真因）',
  parserEts.includes('Badge.parseImageOnly(link.label)'));
check('① 阅读页有铭牌芯片行，且排在独立图片卡之前',
  viewEts.includes('badgeRow()') && viewEts.includes('this.blockBadges().length > 0'));
check('① 导出链：段落徽章组与行内徽章都走本地绘制标记',
  toHtmlEts.includes('MdToHtml.badgeRow(badges)') && toHtmlEts.includes('Badge.parse(item.href)'));

// ── ② 用**真实实现**跑解析用例 ──
const tmpDir = path.join(__dirname, '.badge-sim');
fs.mkdirSync(tmpDir, { recursive: true });
const tmpFile = path.join(tmpDir, 'badge.ts');
const iface = sliceBlock(typesEts, /export interface MdBadge\b/);
const body = badgeEts.replace(/^import .*;\s*$/m, '');
fs.writeFileSync(tmpFile, iface + '\n' + body);

(async () => {
  const mod = await import('file://' + tmpFile.replace(/\\/g, '/') + '?t=' + Date.now());
  const Badge = mod.Badge;

  const P = (u) => Badge.parse(u);
  const H = 'https://img.shields.io';

  const cases = [
    // [地址, 期望 label, 期望 message, 期望 color]
    [H + '/badge/version-1.4.1-blue', 'version', '1.4.1', '#007EC6'],
    [H + '/badge/HarmonyOS%20NEXT%20(API%2026)-orange', '', 'HarmonyOS NEXT (API 26)', '#EA7233'],
    [H + '/badge/license-MIT-green', 'license', 'MIT', '#67AC09'],
    [H + '/badge/download-HAP-success', 'download', 'HAP', '#44BB00'],
    [H + '/badge/PRs-welcome-brightgreen.svg', 'PRs', 'welcome', '#44BB00'],
    [H + '/badge/hello_world__x-y--z-red', 'hello world_x', 'y-z', '#DD4343'],
    [H + '/badge/any_text-you_like-blue', 'any text', 'you like', '#007EC6'],
    [H + '/badge/coverage-95%25-orange', 'coverage', '95%', '#EA7233'],
    [H + '/badge/c-8A2BE2', '', 'c', '#8A2BE2'],
    [H + '/badge/c-rgb(255,99,71)', '', 'c', '#FF6347'],
    [H + '/badge/a--b--c-green', '', 'a-b-c', '#67AC09'],
    // 宽容：两段但第二段不是颜色（官方 404）→ 按 label: message + 默认色解读
    [H + '/badge/version-1.4.1', 'version', '1.4.1', '#44BB00']
  ];
  let bad = [];
  for (const c of cases) {
    const b = P(c[0]);
    const ok = b !== null && b.label === c[1] && b.message === c[2] && b.color === c[3];
    if (!ok) { bad.push(c[0] + ' → ' + JSON.stringify(b)); }
  }
  check('② 路径参数口径（label / message / color / 转义 / 命名色 / hex / rgb）',
    bad.length === 0, bad.join(' | '));

  const styleCase = P(H + '/badge/x-y-blue?style=for-the-badge');
  check('② ?style= 生效', styleCase !== null && styleCase.style === 'for-the-badge');
  const qCase = P(H + '/badge/x-y-blue?label=Z&color=red&labelColor=abcdef');
  check('② ?label= / ?color= / ?labelColor= 覆盖生效',
    qCase !== null && qCase.label === 'Z' && qCase.color === '#DD4343' && qCase.labelColor === '#ABCDEF',
    JSON.stringify(qCase));
  const v1 = P(H + '/static/v1?label=build&message=passing&color=green');
  check('② /static/v1 入口可用',
    v1 !== null && v1.label === 'build' && v1.message === 'passing' && v1.color === '#67AC09',
    JSON.stringify(v1));

  const negs = [
    H + '/badge/foo',                     // 1 段：官方 404
    H + '/badge/a-b-c-d',                 // 4 段：官方 404
    'https://example.com/badge/x-y-blue', // 非 shields 域名
    'docs/icon.png',
    'https://img.shields.io/github/v/release/a/b',  // 动态徽章要调 API，不认（回落远程图）
    'data:image/png;base64,AAAA'
  ];
  const wrong = negs.filter((u) => P(u) !== null);
  check('② 非静态徽章地址一律不认（回落到原远程图片路径，行为不变）',
    wrong.length === 0, wrong.join(' | '));

  // ── ③ 整行徽标识别（真实 README 的四枚铭牌）──
  const row1 = Badge.parseLine('[![Version](https://img.shields.io/badge/version-1.4.1-blue)](https://github.com/x/y/releases/tag/v1.4.1)');
  check('③ `[![alt](徽标)](链接)` 整行 → 一枚铭牌，且带上链接与替代文字',
    row1 !== null && row1.length === 1 && row1[0].alt === 'Version'
    && row1[0].href === 'https://github.com/x/y/releases/tag/v1.4.1'
    && row1[0].message === '1.4.1', JSON.stringify(row1));
  const row2 = Badge.parseLine('![License](https://img.shields.io/badge/license-MIT-green) ![Release](https://img.shields.io/badge/download-HAP-success)');
  check('③ 一行多枚（空格分隔）→ 两枚铭牌',
    row2 !== null && row2.length === 2 && row2[1].message === 'HAP', JSON.stringify(row2));
  const negLines = [
    '版本 ![v](https://img.shields.io/badge/version-1.4.1-blue) 已发布',  // 混了正文
    '[![图](docs/a.png)](https://github.com/x)',                        // 普通图片带链接
    '![图](https://example.com/a.png)',                                 // 普通网络图
    '- 列表项 ![v](https://img.shields.io/badge/version-1-blue)'        // 非纯徽标行
  ];
  const badLines = negLines.filter((l) => Badge.parseLine(l) !== null);
  check('③ 混了正文 / 普通图片的行不当作铭牌行（段落行为保持原样）',
    badLines.length === 0, badLines.join(' | '));

  // ── ④ 离线 HTML 标记 ──
  const two = Badge.toHtml(P(H + '/badge/version-1.4.1-blue'));
  check('④ 两段徽标：灰 label + 彩色 message + 白字，且**纯内联样式**',
    two.indexOf('background:#555555') > 0 && two.indexOf('background:#007EC6') > 0
    && two.indexOf('color:#fff') > 0 && two.indexOf('<img') < 0);
  const one = Badge.toHtml(P(H + '/badge/HarmonyOS%20NEXT%20(API%2026)-orange'));
  check('④ 单段徽标（label 为空）只出一段底色',
    one.split('background:#EA7233').length === 2 && one.indexOf('background:#555555') < 0, one);
  const ftb = Badge.toHtml(P(H + '/badge/build-passing-green?style=for-the-badge'));
  check('④ for-the-badge：大写 + 28 高 + 直角',
    ftb.indexOf('BUILD') > 0 && ftb.indexOf('height:28px') > 0 && ftb.indexOf('border-radius:0') > 0);
  const esc = Badge.toHtml(P(H + '/badge/a%3Cb%3E-c-red'));
  check('④ 徽章文字做 HTML 转义（`<` 不会破坏标记）',
    esc.indexOf('<b>') < 0 && esc.indexOf('&lt;') > 0 || esc.indexOf('a&lt;b&gt;') > 0, esc);

  // ── ⑤ HTML 块里的徽章就地替换 ──
  const html = '<p align="center">\n  <a href="https://github.com/x"><img src="https://img.shields.io/badge/version-1.4.1-blue" alt="Version" /></a>\n  <img src="docs/icon.png" width="160" />\n</p>';
  const rewritten = Badge.rewriteHtml(html);
  check('⑤ `<a><img src="徽标">` 被换成离线标记，外链保留',
    rewritten.indexOf('img.shields.io') < 0 && rewritten.indexOf('href="https://github.com/x"') > 0
    && rewritten.indexOf('background:#007EC6') > 0);
  check('⑤ 非徽章图片（本地相对路径）原样保留',
    rewritten.indexOf('<img src="docs/icon.png" width="160" />') > 0);
  check('⑤ 没有徽章的 HTML 走快路径、逐字节不变',
    Badge.rewriteHtml('<div><b>纯文本</b></div>') === '<div><b>纯文本</b></div>');

  // ── ⑥ 真实 README 头部端到端（端口：段落分支的"连续同性质行分组"）──
  const README = [
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
  ];
  /** 端口：MdParser 段落分支里的分组（仅这一段，其余仍由应用自身逻辑负责） */
  function groupBadgeRuns(para) {
    const rows = para.map((l) => Badge.parseLine(l));
    const out = [];
    let bs = 0;
    while (bs < para.length) {
      const isBadge = rows[bs] !== null;
      let be = bs;
      const items = [];
      while (be < para.length && (rows[be] !== null) === isBadge) {
        if (isBadge) { items.push(...rows[be]); }
        be++;
      }
      out.push(isBadge ? { kind: 'badges', n: items.length, first: items[0] } : { kind: 'para', text: para.slice(bs, be).join(' ') });
      bs = be;
    }
    return out;
  }
  const groups = groupBadgeRuns(README.slice(10, 14));
  check('⑥ README 头部的四行徽标并成**一个**铭牌组（4 枚，链接与替代文字齐备）',
    groups.length === 1 && groups[0].kind === 'badges' && groups[0].n === 4
    && groups[0].first.alt === 'Version', JSON.stringify(groups));
  const mixed = groupBadgeRuns(['版本说明文字。', '[![V](https://img.shields.io/badge/a-b-blue)](https://x)', '结尾一行。']);
  check('⑥ 徽标夹在正文里 → 拆成 段落 + 铭牌 + 段落（不吞正文）',
    mixed.length === 3 && mixed[0].kind === 'para' && mixed[1].kind === 'badges'
    && mixed[2].kind === 'para', JSON.stringify(mixed));

  console.log(fails === 0 ? 'BADGE SIM OK' : 'BADGE SIM FAILED: ' + fails);
  process.exit(fails === 0 ? 0 : 1);
})().catch((e) => {
  console.log('  FAIL  执行真实实现时抛错：' + (e && e.message ? e.message : e));
  console.log('BADGE SIM FAILED: 1');
  process.exit(1);
});
