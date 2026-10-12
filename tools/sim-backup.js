#!/usr/bin/env node
/**
 * 备份打包/恢复的**路径公式仿真**（只读源码 + 在临时目录里跑，不动仓库代码）
 * ==========================================================================
 *
 * 起因（真机事故）：导出提示「N 项读不出来」、导入后书架空空。根因是 zip 里每个文件
 * 都躺在 `<类别>/` 下，而类别文件夹没人创建 → copyFileSync ENOENT → 所有**单文件类别**
 * （shelf.json / settings.json / 日志 / tabs / review / 壁纸 / 手写 / fonts.json / 卡片快照）
 * 整批没进包。文档正文进了包，但书架索引没有，看上去就是「什么都没有」。
 *
 * 这里把 BackupStore 的**同一套路径公式**（从源码里读出来的类别表 + copyTree 语义）
 * 在临时假沙箱上跑一遍：造数据 → 打包到 <stage>/backup → 恢复进一个**全新的空沙箱**
 * → 逐文件比对。zip 压缩/解压这一步省略（compressFiles 传单个目录会原样保留内部结构，
 * 已由旧版真机验证），比对的就是「进了包的相对路径」与「恢复后的相对路径」。
 *
 * 用法：node tools/sim-backup.js
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const SRC = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets', 'service', 'BackupStore.ets');
const src = fs.readFileSync(SRC, 'utf8').replace(/\r\n/g, '\n');

let fails = 0;
function check(label, ok, extra) {
  if (!ok) { fails++; console.log('  FAIL  ' + label + (extra ? '  ' + extra : '')); }
  else { console.log('  ok    ' + label); }
}

// ── 从源码里解析类别表（与 tools/verify-backup.js 同款做法，但独立实现，互为对照）──
function methodBody(s, sig) {
  const at = s.indexOf(sig);
  if (at < 0) { return null; }
  const open = s.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < s.length; i++) {
    if (s[i] === '{') { depth++; }
    else if (s[i] === '}') { depth--; if (depth === 0) { return s.slice(open, i + 1); } }
  }
  return null;
}
const alias = { 'f': 'files' };
for (const m of src.matchAll(/static readonly ([A-Za-z_][A-Za-z0-9_]*): string = '([^']*)'/g)) {
  alias['BackupStore.' + m[1]] = m[2];
}
const SKIP = /SKIP: string\[\] = \[([^\]]*)\]/.exec(src)[1].match(/'([^']*)'/g).map((x) => x.slice(1, -1));
const cats = [];
for (const m of methodBody(src, 'private static categories()')
  .matchAll(/list\.push\(\{([\s\S]*?)\} as BackupCategory\)/g)) {
  const lit = m[1];
  const id = /id:\s*'([^']*)'/.exec(lit)[1];
  const root = /root:\s*([A-Za-z_.]+)\s*,/.exec(lit)[1];
  const srcs = [.../sources:\s*\[([^\]]*)\]/.exec(lit)[1]
    .matchAll(/'([^']*)'|([A-Za-z_][A-Za-z0-9_.]*)/g)]
    .map((x) => (x[1] !== undefined ? x[1] : x[2]))
    .map((x) => (alias[x] !== undefined ? alias[x] : x));
  cats.push({ id: id, root: alias[root] !== undefined ? alias[root] : root, sources: srcs });
}
console.log('从源码解析到 ' + cats.length + ' 类：' + cats.map((c) => c.id).join(' '));
console.log('SKIP = ' + JSON.stringify(SKIP));

// ── 从 DocStore 源码里解析「内置演示文档的死副本」名单（同样不手抄文件名）──
// 死副本 = update() 写进 docs/<rawfile 名> 的覆盖正文 + 首启释放的内置插图；
// readText() 对 builtin 一律回头读 rawfile，所以沙箱这几份永远不会被读到。
const DOC_SRC =
  path.join(__dirname, '..', 'entry', 'src', 'main', 'ets', 'service', 'DocStore.ets');
const docSrc = fs.readFileSync(DOC_SRC, 'utf8').replace(/\r\n/g, '\n');
const BUILTIN_RAW = [...docSrc.matchAll(/raw:\s*'([^']*)'/g)].map((m) => m[1]);
const BUILTIN_IMAGE = /BUILTIN_IMAGE: string = '([^']*)'/.exec(docSrc)[1];
// 用户自建的文档正好叫 README.md 时它就**不是**死副本（isUserDocFile 那条），
// 仿真里用这个数组模拟书架索引里的非内置文档
let USER_DOC_FILES = [];
function builtinResidue(sb) {
  const out = BUILTIN_RAW.filter((r) => !USER_DOC_FILES.includes(r))
    .map((r) => sb.files + '/docs/' + r);
  out.push(sb.files + '/docs/images/' + BUILTIN_IMAGE);
  return out;
}
console.log('内置死副本名单（BUILTINS 反推）= ' + JSON.stringify(BUILTIN_RAW)
  + ' + images/' + BUILTIN_IMAGE);

// ── copyTree / 打包 / 恢复 的端口（与 ArkTS 版逐行对应）──
const stat = { files: 0, bytes: 0, failed: 0 };
// 关掉它就还原事故现场的写法（不建父目录），用来证明诊断没跑偏
let FIX_PARENT = true;
function listNames(dir) {
  try { return fs.readdirSync(dir); } catch (e) { return []; }
}
function ensureDir(dir) {
  try { fs.mkdirSync(dir, { recursive: true }); } catch (e) { /* 已存在 */ }
}
function parentOf(p) {
  const at = p.lastIndexOf('/');
  return at > 0 ? p.substring(0, at) : p;
}
function isDir(p) {
  try { return fs.statSync(p).isDirectory(); } catch (e) { return false; }
}
function exists(p) {
  try { fs.accessSync(p); return true; } catch (e) { return false; }
}
function matchPattern(name, pattern) {
  const star = pattern.indexOf('*');
  if (star < 0) { return name === pattern; }
  const head = pattern.substring(0, star);
  const tail = pattern.substring(star + 1);
  if (name.length < head.length + tail.length) { return false; }
  return name.substring(0, head.length) === head
    && name.substring(name.length - tail.length) === tail;
}
function resolveSource(rootDir, pattern) {
  if (pattern.indexOf('*') < 0) {
    return exists(rootDir + '/' + pattern) ? [pattern] : [];
  }
  return listNames(rootDir).filter((n) => matchPattern(n, pattern));
}
function copyTree(s, d, ignores) {
  if (ignores.includes(s) || ignores.includes(d)) { return; }   // 内置死副本：一个字节都不碰
  let folder = false;
  let size = 0;
  try { const st = fs.statSync(s); folder = st.isDirectory(); size = st.size; }
  catch (e) { stat.failed++; return; }
  if (folder) {
    const names = listNames(s);
    if (names.length === 0) { return; }          // 空目录不进包
    ensureDir(d);
    for (const n of names) { copyTree(s + '/' + n, d + '/' + n, ignores); }
    return;
  }
  if (FIX_PARENT) { ensureDir(parentOf(d)); }        // ← 事故修复点
  try { if (exists(d)) { fs.unlinkSync(d); } } catch (e) { /* 本来不存在 */ }
  try { fs.copyFileSync(s, d); stat.files++; stat.bytes += size; }
  catch (e) { stat.failed++; }
}
function expandSources(root, sources) {
  const out = [];
  for (const s of sources) { for (const h of resolveSource(root, s)) { out.push(h); } }
  return out;
}
function claimedNames(filesDir) {
  const claimed = [];
  for (const c of cats) {
    if (c.root !== 'files' || c.id === 'extra') { continue; }
    for (const s of c.sources) {
      for (const h of resolveSource(filesDir, s)) { if (!claimed.includes(h)) { claimed.push(h); } }
    }
  }
  return claimed;
}
function leftoverNames(filesDir) {
  const claimed = claimedNames(filesDir);
  return listNames(filesDir).filter((n) => !claimed.includes(n) && !SKIP.includes(n));
}
function rootDir(root, sb) {
  return root === 'cache' ? sb.cache : (root === 'app' ? sb.app : sb.files);
}
function pack(sb, top) {
  ensureDir(top);
  const leftover = leftoverNames(sb.files);
  const ignores = builtinResidue(sb);
  for (const c of cats) {
    if (c.root === 'pref') {
      if (sb.pref.length > 0) {                   // dumpWebDavSnapshot：自己会建目录
        ensureDir(top + '/' + c.id);
        fs.writeFileSync(top + '/' + c.id + '/' + alias['BackupStore.WEBDAV_SNAPSHOT'], sb.pref);
        stat.files++; stat.bytes += sb.pref.length;
      }
      continue;
    }
    const srcRoot = rootDir(c.root, sb);
    const names = c.id === 'extra' ? leftover : expandSources(srcRoot, c.sources);
    for (const n of names) { copyTree(srcRoot + '/' + n, top + '/' + c.id + '/' + n, ignores); }
  }
}
function copyCategoryInto(srcDir, dstRoot, ignores) {
  for (const n of listNames(srcDir)) {
    copyTree(srcDir + '/' + n, dstRoot + '/' + n, ignores);
  }
}
function findPackageRoot(stage) {
  let root = stage;
  for (let depth = 0; depth < 4; depth++) {
    if (exists(root + '/manifest.json')) { return root; }
    const names = listNames(root);
    if (names.length !== 1) { return root; }
    const only = root + '/' + names[0];
    if (!isDir(only) || cats.some((c) => c.id === names[0])) { return root; }
    root = only;
  }
  return root;
}
function idCollides(cat) {
  return cat.sources.some((s) => s === cat.id || s.indexOf(cat.id + '/') === 0);
}
function isCategorized(root, names) {
  if (exists(root + '/manifest.json')) { return true; }
  for (const n of names) {
    const cat = cats.find((c) => c.id === n);
    if (cat === undefined || !isDir(root + '/' + n)) { continue; }
    if (!idCollides(cat)) { return true; }
    for (const s of cat.sources) {
      const at = s.indexOf('/');
      const first = at < 0 ? s : s.substring(0, at);
      if (first.length > 0 && first.indexOf('*') < 0 && exists(root + '/' + n + '/' + first)) {
        return true;
      }
    }
  }
  return false;
}
function restore(stage, sb2) {
  const root = findPackageRoot(stage);
  const names = listNames(root);
  const categorized = isCategorized(root, names);
  // 导入侧不排除内置死副本：判定"是不是死副本"要看书架索引，而索引正是这个包要恢复的
  // 东西。用恢复前的本机索引判定，就会把源机器上叫 README.md 的**用户文档**跳过 → 丢数据。
  const ignores = [];
  for (const entry of names) {
    const s = root + '/' + entry;
    if (entry === 'manifest.json') { continue; }
    const cat = categorized ? cats.find((c) => c.id === entry) : undefined;
    if (cat !== undefined && isDir(s)) {
      if (cat.root === 'pref') {
        const p = s + '/' + alias['BackupStore.WEBDAV_SNAPSHOT'];
        if (exists(p)) { sb2.pref = fs.readFileSync(p, 'utf8'); stat.files++; }
        continue;
      }
      copyCategoryInto(s, rootDir(cat.root, sb2), ignores);
      continue;
    }
    if (SKIP.includes(entry)) { continue; }
    if (entry === alias['BackupStore.WEBDAV_SNAPSHOT']) {
      sb2.pref = fs.readFileSync(s, 'utf8'); stat.files++; continue;
    }
    copyTree(s, sb2.files + '/' + entry, ignores);
  }
  return categorized;
}

// ── 假沙箱：造数据 → 打包 → 恢复进一个**全新的空沙箱** → 逐文件比对 ──
function scenario(fixParent) {
  FIX_PARENT = fixParent;
  stat.files = 0; stat.bytes = 0; stat.failed = 0;

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sim-bk-'));
  const P = (x) => path.join(tmp, x).split(path.sep).join('/');
  function mkSandbox(tag) {
    const sb = { files: P(tag + '/files'), cache: P(tag + '/cache'), app: P(tag + '/app'), pref: '' };
    ensureDir(sb.files); ensureDir(sb.cache); ensureDir(sb.app);
    return sb;
  }
  function w(p, text) { ensureDir(parentOf(p)); fs.writeFileSync(p, text === undefined ? 'x' : text); }

  const A = mkSandbox('A');
  w(A.files + '/docs/笔记.md', '# 标题\n正文');
  w(A.files + '/docs/子目录/嵌套.md', 'nested');
  w(A.files + '/docs/images/a.png', 'PNG');
  // 内置演示文档的**死副本**：沙箱里真实存在（update() 无条件写盘），但 readText()
  // 对 builtin 一律回头读 rawfile，所以永远读不到它们 —— 用户看到的"包里一堆我根本
  // 没有的文件，甚至是演示的文件（英语单词那些）"就是这几份
  for (const r of BUILTIN_RAW) { w(A.files + '/docs/' + r, 'DEMO'); }
  w(A.files + '/docs/images/' + BUILTIN_IMAGE, 'ICON');
  w(A.files + '/shelf.json', '{"docs":[]}');
  w(A.files + '/annotations/1.json', '[]');
  w(A.files + '/sketch.handwrite', 'strokes');
  w(A.files + '/ai/config.json', '{}');
  w(A.files + '/ai/sessions/s1.json', '{}');
  ensureDir(A.files + '/drafts');                    // 空目录：不该进包
  w(A.files + '/versions/v1.json', '{}');
  w(A.files + '/fonts/my.ttf', 'FONT');
  w(A.files + '/fonts.json', '[]');
  w(A.files + '/wallpaper_light_1699.img', 'IMG');
  w(A.files + '/wallpaper_dark_1700.img', 'IMG');
  w(A.files + '/reader_bg.img', 'IMG');
  w(A.files + '/reader_bg_1701.img', 'IMG');
  w(A.files + '/reading-log.json', '[]');
  w(A.files + '/writing-log.json', '[]');
  w(A.files + '/tabs.json', '[]');
  w(A.files + '/review.json', '{}');
  w(A.files + '/review_stats.json', '{}');
  w(A.files + '/settings.json', '{"at":1}');
  w(A.files + '/image_hidden.json', '[]');
  w(A.files + '/以后新加的数据.json', 'NEW');        // 只能靠 extra 兜底
  w(A.files + '/webdav_config.json', 'LEGACY');     // SKIP：老版中转文件
  w(A.files + '/pref_snapshot/webdav.xml', 'XML');  // SKIP：老版 preferences 目录
  w(A.cache + '/charts/c1.png', 'PNG');
  ensureDir(A.cache + '/export');                    // 空目录
  w(A.cache + '/litemd_backup.zip', 'ZIP');         // 例外名单：临时包
  w(A.app + '/form_snapshot.json', '{}');
  w(A.app + '/form_ids.json', '[]');                // 例外名单：本机卡片 ID
  A.pref = '{"url":"https://dav.example.com"}';

  const stage = P('stage');
  const top = stage + '/backup';
  pack(A, top);
  fs.writeFileSync(top + '/manifest.json', '{"app":"澄笺"}');
  const afterPack = { files: stat.files, bytes: stat.bytes, failed: stat.failed };

  const emptyDirs = [];
  (function scan(dir) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = dir + '/' + e.name;
      if (e.isDirectory()) {
        if (fs.readdirSync(p).length === 0) { emptyDirs.push(p.replace(top, '')); }
        else { scan(p); }
      }
    }
  })(top);

  const B = mkSandbox('B');
  restore(stage, B);

  function tree(dir, base, out) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = dir + '/' + e.name;
      const rel = (base === '' ? '' : base + '/') + e.name;
      if (e.isDirectory()) { tree(p, rel, out); } else { out.push(rel); }
    }
    return out;
  }
  const want = [].concat(
    tree(A.files, '', []).map((x) => 'files/' + x),
    tree(A.cache, '', []).map((x) => 'cache/' + x),
    tree(A.app, '', []).map((x) => 'app/' + x));
  const got = [].concat(
    tree(B.files, '', []).map((x) => 'files/' + x),
    tree(B.cache, '', []).map((x) => 'cache/' + x),
    tree(B.app, '', []).map((x) => 'app/' + x));
  // 例外名单：本机专属 / 临时文件 / 内置死副本，本来就不该跟着备份走
  const EXEMPT = ['files/webdav_config.json', 'files/pref_snapshot/webdav.xml',
    'cache/litemd_backup.zip', 'app/form_ids.json',
    'files/docs/images/' + BUILTIN_IMAGE]
    .concat(BUILTIN_RAW.map((r) => 'files/docs/' + r));
  const expected = want.filter((x) => !EXEMPT.includes(x));

  // 老包 A：1.1.x 平铺 + 外面套一层 data/
  const legacy = P('legacy');
  w(legacy + '/data/shelf.json', '{"old":true}');
  w(legacy + '/data/docs/旧文档.md', 'OLD');
  w(legacy + '/data/annotations/a.json', '[]');
  const C = mkSandbox('C');
  const legacyCategorized = restore(legacy, C);

  // 老包 B：平铺在根（没有 data/ 那一层）
  const flat = P('flat');
  w(flat + '/shelf.json', '{"old":true}');
  w(flat + '/docs/旧文档.md', 'OLD');
  const D = mkSandbox('D');
  restore(flat, D);

  // 新包但 manifest 丢了：仍须认出是分类布局（否则 docs/docs 会被摊平到 filesDir 根）
  const bare = P('bare');
  w(bare + '/backup/shelf/shelf.json', '{"new":true}');
  w(bare + '/backup/docs/docs/笔记.md', 'NEW');
  w(bare + '/backup/settings/settings.json', '{"at":2}');
  const E = mkSandbox('E');
  const bareCategorized = restore(bare, E);

  // 老包（新版之前导出的）里夹着内置死副本：导入**必须**照原样写回 ——
  // 在源机器上它可能是一篇同名的用户文档，导入时还没有那份索引可查
  const oldish = P('oldish');
  w(oldish + '/backup/manifest.json', '{"app":"澄笺"}');
  w(oldish + '/backup/shelf/shelf.json', '{"docs":[]}');
  w(oldish + '/backup/docs/docs/' + BUILTIN_RAW[0], 'MAYBE-USER-DOC');
  const F = mkSandbox('F');
  restore(oldish, F);

  const out = {
    tmp: tmp, pack: afterPack, failed: stat.failed, emptyDirs: emptyDirs,
    missing: expected.filter((x) => !got.includes(x)),
    surprise: got.filter((x) => !expected.includes(x)),
    got: got, A: A,
    // 包内实际躺着的东西（相对 top）：用来断言"哪些文件根本没进包"
    packed: tree(top, '', []),
    contentOk: fs.readFileSync(B.files + '/docs/笔记.md', 'utf8') === '# 标题\n正文'
      && fs.readFileSync(B.files + '/docs/子目录/嵌套.md', 'utf8') === 'nested'
      && fs.readFileSync(B.cache + '/charts/c1.png', 'utf8') === 'PNG',
    prefOk: B.pref === A.pref,
    // 老包：shelf.json 回到 filesDir 根、文档回到 docs/ 下，且没有被摊平到根
    legacyOk: exists(C.files + '/shelf.json') && exists(C.files + '/docs/旧文档.md')
      && exists(C.files + '/annotations/a.json') && !exists(C.files + '/旧文档.md'),
    legacyCategorized: legacyCategorized,
    flatOk: exists(D.files + '/shelf.json') && exists(D.files + '/docs/旧文档.md')
      && !exists(D.files + '/旧文档.md'),
    bareCategorized: bareCategorized,
    bareOk: exists(E.files + '/shelf.json') && exists(E.files + '/docs/笔记.md')
      && exists(E.files + '/settings.json'),
    oldishOk: exists(F.files + '/docs/' + BUILTIN_RAW[0])
      && fs.readFileSync(F.files + '/docs/' + BUILTIN_RAW[0], 'utf8') === 'MAYBE-USER-DOC'
  };
  fs.rmSync(tmp, { recursive: true, force: true });
  return out;
}

const R = scenario(true);
console.log('打包：' + R.pack.files + ' 个文件 / ' + R.pack.bytes + ' 字节 / 失败 ' + R.pack.failed
  + '；恢复后累计失败 ' + R.failed);

check('包里没有空目录（zlib：待压缩的文件夹不能为空，否则整包解不开）',
  R.emptyDirs.length === 0, R.emptyDirs.join(', '));
check('打包与恢复全程 0 失败（失败就是界面上的「N 项读不出来」）',
  R.pack.failed === 0 && R.failed === 0, '打包失败 ' + R.pack.failed + ' / 恢复失败 ' + R.failed);
check('该进包的每一个文件都恢复到了对应位置', R.missing.length === 0,
  '缺 ' + R.missing.length + '：' + R.missing.slice(0, 12).join(', '));
check('没有多恢复出任何东西（例外名单里的本机文件不会被带过来）', R.surprise.length === 0,
  '多 ' + R.surprise.join(', '));
check('书架索引 shelf.json 进包且恢复回来了（事故现场就是它没进包）',
  R.got.includes('files/shelf.json'));
check('设置镜像 settings.json 恢复回来了', R.got.includes('files/settings.json'));
check('壁纸与阅读背景（带时间戳的通配文件名）恢复回来了',
  R.got.includes('files/wallpaper_light_1699.img') && R.got.includes('files/reader_bg_1701.img'));
check('没人认领的新数据文件靠 extra 兜底也回来了',
  R.got.includes('files/以后新加的数据.json'));
check('桌面卡片快照进包、本机卡片 ID 不进包',
  R.got.includes('app/form_snapshot.json') && !R.got.includes('app/form_ids.json'));
check('缓存里的图表进包、临时 zip 不进包',
  R.got.includes('cache/charts/c1.png') && !R.got.includes('cache/litemd_backup.zip'));
check('网盘凭据走 preferences 通道回来了', R.prefOk);
check('恢复出来的文件内容与原文件一致', R.contentOk);
check('老版平铺包（套一层 data/）按 filesDir 顶层恢复，docs 里的文档不被摊平到根',
  R.legacyOk && R.legacyCategorized === false);
check('老版平铺包（直接躺在根）同样能恢复', R.flatOk);
check('新包丢了 manifest 也认得出是分类布局，且按类别写回正确位置',
  R.bareCategorized === true && R.bareOk);

// ── 内置演示文档的死副本：不进包、也不写回（用户反馈"包里一堆我根本没有的文件"）──
// 包内路径 = <类别>/<沙箱相对路径>，所以文档在包里是 docs/docs/… 这种双层写法
const residuePacked = R.packed.filter((x) =>
  BUILTIN_RAW.some((r) => x === 'docs/docs/' + r) || x === 'docs/docs/images/' + BUILTIN_IMAGE);
const residueRestored = R.got.filter((x) =>
  BUILTIN_RAW.some((r) => x === 'files/docs/' + r) || x === 'files/docs/images/' + BUILTIN_IMAGE);
check('内置演示文档的死副本一个都没进包（应用永不读它们，进包只会让用户认不出来）',
  residuePacked.length === 0, residuePacked.join(', '));
check('死副本没进包 → 恢复出来的新沙箱里也就没有它们',
  residueRestored.length === 0, residueRestored.join(', '));
check('老包里夹着的同名文件导入时照原样写回（导入侧不排除：它可能是用户文档）',
  R.oldishOk);
check('用户自己的文档与图片照常进包（排除名单没有误伤）',
  R.packed.includes('docs/docs/笔记.md') && R.packed.includes('docs/docs/子目录/嵌套.md')
  && R.packed.includes('docs/docs/images/a.png'));

// 用户自建的文档正好叫 README.md：那是**用户数据**，必须进包（isUserDocFile 那条分支）
USER_DOC_FILES = [BUILTIN_RAW[0]];
const R3 = scenario(true);
check('用户自建的同名文档不算死副本，照样进包（误排就是丢数据）',
  R3.packed.includes('docs/docs/' + BUILTIN_RAW[0])
  && !R3.packed.includes('docs/docs/' + BUILTIN_RAW[1]),
  R3.packed.filter((x) => x.indexOf('docs/') === 0).join(', '));
USER_DOC_FILES = [];

// ── 反向证明：把「建父目录」那一步去掉，事故就复现（单文件类别整批丢） ──
const BUG = scenario(false);
check('反证：不建父目录就会复现事故（拷贝失败 + 书架索引丢失）',
  BUG.pack.failed > 0 && !BUG.got.includes('files/shelf.json'),
  '失败 ' + BUG.pack.failed + ' 项，shelf.json ' + (BUG.got.includes('files/shelf.json') ? '还在' : '没了'));
console.log('        反证场景：打包失败 ' + BUG.pack.failed + ' 项，丢 '
  + BUG.missing.length + ' 个文件（含 ' + BUG.missing.slice(0, 6).join(', ') + '）');

console.log(fails === 0 ? 'SIM OK' : 'SIM FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
