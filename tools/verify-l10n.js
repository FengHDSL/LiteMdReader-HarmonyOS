#!/usr/bin/env node
/**
 * 应用语言（L10n）离线校验 —— **只读代码与词典，不改**
 * =================================================
 *
 * ① 代码里每个 `this.s('…') / s1 / s2 / L10n.t / f1 / f2` 的字面量键，
 *    必须在**必读**词典（EN_US / ZH_HANT / JA_JP / KO_KR）里有对应条目；
 *    ZH_TW / EN_GB 是地区用词 override，允许只登记差异条目。
 * ② 键必须是**单个字面量**，不能是 `'A' + 'B'` 拼出来的 —— 拼接键没法进词典查表。
 * ③ 占位符 %1 / %2 必须在译文里出现同一组（少一个就是漏参数，多一个就是编错了）。
 * ④ 词典值不能为空串（空串会让界面出现空白，L10n.t 也会把它当"没译"回退）。
 * ⑤ 品牌名不翻译：键里出现几次「澄笺」，译文里就得出现几次；也不能凭空多出 澄笺。
 * ⑥ 繁体表里不该残留简体字（一份常见简体字黑名单，抓繁简混排）。
 * ⑦ en-GB 的值里不该再有 color / gray 这类美式拼写（拼写差异必须写进 override 表）。
 *
 * 用法：node tools/verify-l10n.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const ETS = path.join(ROOT, 'entry', 'src', 'main', 'ets');
const L10N_DIR = path.join(ETS, 'service', 'l10n');

let fails = 0;
function check(label, ok, extra) {
  if (!ok) { fails++; console.log('  FAIL  ' + label + (extra ? '  ' + extra : '')); }
}

/** 解析词典文件里的 { k: '…', v: '…' } 条目（值可能换行写在下一行）。 */
function readDict(file) {
  const p = path.join(L10N_DIR, file);
  if (!fs.existsSync(p)) { check('词典文件存在: ' + file, false); return new Map(); }
  const src = fs.readFileSync(p, 'utf8').replace(/\r\n/g, '\n');
  const map = new Map();
  const re = /\{\s*k:\s*'([^']*)'\s*,\s*\n?\s*v:\s*'([^']*)'\s*\}/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    map.set(m[1], m[2]);
  }
  const kCount = (src.match(/\bk:/g) || []).length;
  check('① 条目都被解析到: ' + file, kCount === map.size, 'parsed=' + map.size + ' k:=' + kCount);
  return map;
}

const EN_US = readDict('DictEn.ets');
const EN_GB = readDict('DictEnGb.ets');
const ZH_HANT = readDict('DictZhHant.ets');
const ZH_TW = readDict('DictZhTw.ets');
const JA_JP = readDict('DictJa.ets');
const KO_KR = readDict('DictKo.ets');

const REQUIRED = [
  ['en-US', EN_US], ['zh-Hant', ZH_HANT], ['ja-JP', JA_JP], ['ko-KR', KO_KR]
];
console.log('词典条目: EN_US=' + EN_US.size + ' EN_GB=' + EN_GB.size + ' ZH_HANT=' + ZH_HANT.size
  + ' ZH_TW=' + ZH_TW.size + ' JA=' + JA_JP.size + ' KO=' + KO_KR.size);

/** 收集 .ets 源码里用到的键。 */
function walk(dir, out) {
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name);
    const st = fs.statSync(p);
    if (st.isDirectory()) {
      if (name === 'l10n') { continue; }        // 词典本身不算调用点
      walk(p, out);
    } else if (name.endsWith('.ets')) {
      out.push(p);
    }
  }
  return out;
}

const files = walk(ETS, []);
const used = [];          // { key, file, line }
const badConcat = [];
for (const f of files) {
  const src = fs.readFileSync(f, 'utf8').replace(/\r\n/g, '\n');
  const lines = src.split('\n');
  const re = /(?:this|\bL10n)\.(?:s|t|s1|f1|s2|f2)\(\s*((?:'[^']*'\s*\+?\s*)*)/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    const arg = m[1];
    const parts = arg.match(/'([^']*)'/g) || [];
    if (parts.length === 0) { continue; }             // 变量键（运行时才知道），跳过
    if (parts.length > 1) {
      badConcat.push(path.relative(ROOT, f) + ' → ' + arg.trim());
      continue;
    }
    const key = parts[0].slice(1, -1);
    if (key.length === 0) { continue; }
    const line = src.slice(0, m.index).split('\n').length;
    used.push({ key: key, file: path.relative(ROOT, f), line: line });
  }
}
console.log('调用点取到字面量键: ' + used.length + '（去重 ' + new Set(used.map((u) => u.key)).size + ' 个）');

check('② 键必须是单个字面量（不能 ' + "'A' + 'B'" + ' 拼）', badConcat.length === 0,
  badConcat.slice(0, 6).join(' | '));

const uniqKeys = [...new Set(used.map((u) => u.key))];
const missing = {};
for (const [name, map] of REQUIRED) {
  missing[name] = uniqKeys.filter((k) => !map.has(k));
  check('① ' + name + ' 覆盖全部用得到的键', missing[name].length === 0,
    missing[name].length + ' 个缺：' + missing[name].slice(0, 8).map((k) => k.slice(0, 24)).join(' / '));
}

/** override 表只登记差异，但登记的键必须存在于基础表（否则会漂移出孤儿条目）。 */
for (const [over, base, label] of [[EN_GB, EN_US, '⑤b EN_GB'], [ZH_TW, ZH_HANT, '⑤c ZH_TW']]) {
  const orphans = [...over.keys()].filter((k) => !base.has(k) && !uniqKeys.includes(k));
  check(label + ' 的键都能命中基础表或被代码用到', orphans.length === 0, orphans.slice(0, 5).join(' / '));
}

function placeholders(s) {
  const out = [];
  const re = /%(\d)/g;
  let m;
  while ((m = re.exec(s)) !== null) { out.push(m[1]); }
  return out.sort().join(',');
}

// ③④⑤ 逐词典检查值
for (const [name, map] of [['EN_US', EN_US], ['EN_GB', EN_GB], ['ZH_HANT', ZH_HANT],
  ['ZH_TW', ZH_TW], ['JA_JP', JA_JP], ['KO_KR', KO_KR]]) {
  const empties = [];
  const phBad = [];
  const brandBad = [];
  for (const [k, v] of map) {
    if (v.trim().length === 0) { empties.push(k); }
    // 前后空白必须与键一致：拼接文案（如 '版本 ' + name）依赖它，多一个空格就是排版 bug
    if ((/^\s/.test(k) !== /^\s/.test(v)) || (/\s$/.test(k) !== /\s$/.test(v))) {
      phBad.push('空白不一致: ' + k + ' → [' + v + ']');
    }
    if (placeholders(k) !== placeholders(v)) { phBad.push(k + ' → ' + v); }
    const want = (k.match(/澄笺/g) || []).length;
    const got = (v.match(/澄笺/g) || []).length;
    if (want !== got) { brandBad.push(k + '(' + want + ') → ' + v + '(' + got + ')'); }
  }
  check('④ ' + name + ' 无空值', empties.length === 0, empties.slice(0, 4).join(' / '));
  check('③ ' + name + ' 占位符一致', phBad.length === 0, phBad.slice(0, 4).join(' | '));
  check('⑤ ' + name + ' 「澄笺」不被翻译/不凭空增加', brandBad.length === 0, brandBad.slice(0, 3).join(' | '));
}

// ⑥ 繁体表里残留简体字（常见字黑名单，抓繁简混排）
const SIMP = '设关闭纹纸图选则显档语总归复运变数级简体强颜护贵当实让从会这为对后与单据买卖证告诉别';
for (const [name, map] of [['ZH_HANT', ZH_HANT], ['ZH_TW', ZH_TW]]) {
  const hits = [];
  for (const [k, v] of map) {
    const bad = [...new Set(v.split('').filter((ch) => SIMP.includes(ch)))];
    if (bad.length > 0) { hits.push(k.slice(0, 12) + ' 残留「' + bad.join('') + '」'); }
  }
  check('⑥ ' + name + ' 无简体字残留', hits.length === 0, hits.slice(0, 6).join(' / '));
}

// ⑦ en-GB 必须用英式拼写
{
  const hits = [];
  for (const [k, v] of EN_GB) {
    if (/color|gray|center|organiz|customiz/i.test(v)) { hits.push(k.slice(0, 12) + ' → ' + v.slice(0, 40)); }
  }
  check('⑦ en-GB 无美式拼写', hits.length === 0, hits.slice(0, 4).join(' | '));
  // 基础表里凡是含 color/gray 的键，都必须被 override 表覆盖，否则界面会混拼写
  const need = [...EN_US.entries()].filter(([, v]) => /color|gray/i.test(v)).map(([k]) => k);
  const notOver = need.filter((k) => !EN_GB.has(k));
  check('⑦ 含 color/gray 的键都有英式 override', notOver.length === 0,
    notOver.length + ' 个：' + notOver.slice(0, 4).join(' / '));
}

// ⑧ L10n.IDS 里的语言都得有落地方案（system 与 zh-CN 除外）
{
  const src = fs.readFileSync(path.join(ETS, 'service', 'L10n.ets'), 'utf8');
  const ids = (src.match(/IDS:\s*string\[\]\s*=\s*\[([\s\S]*?)\]/) || ['', ''])[1]
    .match(/'[^']+'/g) || [];
  const list = ids.map((x) => x.replace(/'/g, ''));
  const known = ['system', 'zh-CN', 'zh-HK', 'zh-TW', 'en-US', 'en-GB', 'ja-JP', 'ko-KR'];
  check('⑧ IDS 全在已知语言集合里', list.every((x) => known.includes(x)), list.join(','));
  check('⑧ IDS 覆盖 8 个选择项', list.length === 8, 'n=' + list.length);
}

console.log(fails === 0 ? 'L10N OK' : 'L10N FAILED: ' + fails);
if (fails === 0 ? 0 : 1) {
  for (const [name, map] of REQUIRED) {
    if (missing[name].length > 0) {
      console.log('\n' + name + ' 缺的键（' + missing[name].length + '）：');
      for (const k of missing[name]) { console.log("  { k: '" + k + "', v: '' },"); }
    }
  }
}
process.exit(fails === 0 ? 0 : 1);
