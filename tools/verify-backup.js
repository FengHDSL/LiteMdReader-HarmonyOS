#!/usr/bin/env node
/**
 * 备份 / 恢复的不变量检查（**只读代码，不改代码**）
 * ==============================================
 *
 * 起因（两轮）：
 *  · 第一轮：导出备份 → 导入 → 重启应用 → 数据没进来。
 *  · 第二轮（用户要求「从底层完全重做」）：导出要含**全部**数据（缓存、文档、批注、
 *    设置、壁纸……），包内要**按文件夹分类**，导入要认得每个文件夹该回哪儿。
 * 每一轮的根因都在这里钉住，以后谁改这块代码，改坏了当场就会红。
 *
 * ① **包结构与落点**：类别表可解析、id 唯一且纯 ASCII、导出路径与导入路径互为逆运算、
 *    compressFiles 只传一个目录（多目录会被拍平）、解压落暂存目录而非沙箱、
 *    认不出的包直接拒绝（不许把别人的 zip 倒进数据目录）、**拷文件前先建父目录**、
 *    **空目录不进包**、**导入先判定包布局**（后三条都是真机事故：导出说"N 项读不出来"、
 *    导入后书架空空、老包的 docs/ 被摊平进数据目录根）。
 *    行为层面的端到端仿真见 tools/sim-backup.js（假沙箱打包→恢复→逐文件比对）。
 * ② **覆盖面**：从全部源码里反推出真实的写入位置（filesDir / cacheDir / 应用级
 *    filesDir / preferences），逐个对照类别表——**每一处都必须被显式类别覆盖**，
 *    或者写在 NOT_BACKED_UP 里并注明理由。新增数据文件而忘了进表 → 这里就红。
 *    反向也查：表里的来源必须真有代码在写（防改名 / 打错字留下空类别）。
 * ③ **恢复后必须重建内存状态**：DocStore / ReadingLog / WritingLog / TabStore 都带
 *    ready 门闩与内存副本，不重载的话下一次 persist 会把恢复前的状态盖回刚导入的文件；
 *    图表缓存、壁纸绝对路径、字体注册、深浅色、语言同理。
 * ④ **设置不许靠拷 preferences 的 XML 文件恢复**（运行中的实例下次 flush 就冲掉）：
 *    settings.json → SettingsMirror.forceRestore 回填 AppStorage（持久化键写穿
 *    preferences），WebDAV 配置走 preferences API → **不用重启**。
 * ⑤ 每一个 persistProp 键都必须在 SettingsMirror.KEYS 里，否则备份带不走这项设置。
 * ⑥ WebDAV：逐文件只传用户自己的文档 + 完整包复用同一条链路。
 * ⑦ 文案不许再骗用户"重启才生效"。
 *
 * 用法：node tools/verify-backup.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const SRC = path.join(ROOT, 'entry', 'src', 'main', 'ets');

let fails = 0;
function check(label, ok, extra) {
  if (!ok) { fails++; console.log('  FAIL  ' + label + (extra ? '  ' + extra : '')); }
  else { console.log('  ok    ' + label); }
}
function read(rel) {
  return fs.readFileSync(path.join(SRC, rel), 'utf8').replace(/\r\n/g, '\n');
}
function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { walk(p, out); } else if (e.name.endsWith('.ets')) { out.push(p); }
  }
  return out;
}
/** 取一个方法的函数体（从签名起做大括号配平） */
function methodBody(src, signature) {
  const at = src.indexOf(signature);
  if (at < 0) { return null; }
  const open = src.indexOf('{', at);
  if (open < 0) { return null; }
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') { depth++; }
    else if (src[i] === '}') { depth--; if (depth === 0) { return src.slice(open, i + 1); } }
  }
  return null;
}

const backup = read('service/BackupStore.ets');
const mirror = read('service/SettingsMirror.ets');
const webdav = read('service/WebDavStore.ets');
const ability = read('entryability/EntryAbility.ets');
const settingsData = read('pages/SettingsData.ets');

// ══════════════════ 解析类别表 ══════════════════

/**
 * 表里写的可能是常量（`root: BackupStore.ROOT_CACHE`）而不是字面量。
 * 别名表**从源码里的常量声明反推**，不手抄——常量改名 / 改值时不会静默漂移。
 */
function constAlias(src) {
  const alias = { 'f': 'files' };        // categories() 里的局部简写
  const re = /static readonly ([A-Za-z_][A-Za-z0-9_]*): string = '([^']*)'/g;
  let m;
  while ((m = re.exec(src)) !== null) { alias['BackupStore.' + m[1]] = m[2]; }
  return alias;
}

/** 从 categories() 里解析出 [{id,label,root,sources[]}] */
function parseTable(src) {
  const body = methodBody(src, 'private static categories()');
  if (body === null) { return null; }
  const alias = constAlias(src);
  const cats = [];
  const re = /list\.push\(\{([\s\S]*?)\} as BackupCategory\)/g;
  let m;
  while ((m = re.exec(body)) !== null) {
    const lit = m[1];
    const id = /id:\s*'([^']*)'/.exec(lit);
    const label = /label:\s*'([^']*)'/.exec(lit);
    const root = /root:\s*([A-Za-z_.]+)\s*,/.exec(lit);
    const srcs = /sources:\s*\[([^\]]*)\]/.exec(lit);
    if (id === null || root === null || srcs === null) { continue; }
    // 来源既可能写字面量（'docs'），也可能写常量（BackupStore.WEBDAV_SNAPSHOT）
    const sources = [...srcs[1].matchAll(/'([^']*)'|([A-Za-z_][A-Za-z0-9_.]*)/g)]
      .map((x) => (x[1] !== undefined ? x[1] : x[2]))
      .map((x) => alias[x] !== undefined ? alias[x] : x);
    cats.push({
      id: id[1],
      label: label === null ? '' : label[1],
      root: alias[root[1]] !== undefined ? alias[root[1]] : root[1],
      sources: sources
    });
  }
  return cats;
}

const cats = parseTable(backup);
check('① 类别表能解析（categories() 里的 list.push）', cats !== null && cats.length >= 16,
  cats === null ? '解析不出来' : '只解析到 ' + cats.length + ' 类');
if (cats === null) {
  console.log('BACKUP FAILED: 类别表解析不出来，后面的检查没意义');
  process.exit(1);
}
console.log('        类别表 ' + cats.length + ' 类：' + cats.map((c) => c.id).join(' '));

const ids = cats.map((c) => c.id);
check('① 类别 id 唯一', new Set(ids).size === ids.length,
  ids.filter((v, i) => ids.indexOf(v) !== i).join(', '));
check('① 类别 id 全是 ASCII（zip 里的文件夹名跨设备解压不会因为编码变形）',
  ids.every((v) => /^[\x20-\x7e]+$/.test(v)), ids.filter((v) => !/^[\x20-\x7e]+$/.test(v)).join(', '));
check('① 每类都有中文名与至少一个来源',
  cats.every((c) => c.label.length > 0 && c.sources.length > 0),
  cats.filter((c) => c.label.length === 0 || c.sources.length === 0).map((c) => c.id).join(', '));
check('① 有 extra 兜底类（以后新增数据文件自动纳入）',
  ids.includes('extra') && cats[ids.indexOf('extra')].sources.includes('*'));

// ── ① 包结构：导出与导入互为逆运算 ──
const packBody = methodBody(backup, 'static async packToZip(');
const restoreBody = methodBody(backup, 'static async restoreFromPath(');
check('① 导出路径 = <暂存>/<顶层文件夹>/<类别>/<沙箱相对路径>',
  packBody !== null && /top \+ '\/' \+ cat\.id \+ '\/' \+ names\[n\]/.test(packBody));
check('① 导入把类别文件夹里的内容按相对路径写回落点根',
  /private static copyCategoryInto\(srcDir: string, dstRoot: string/.test(backup)
  && /copyTree\(srcDir \+ '\/' \+ names\[k\], dstRoot \+ '\/' \+ names\[k\], stat\)/.test(backup));
check('① 导出与导入用同一张类别表（不许各写一份）',
  packBody !== null && restoreBody !== null
  && /BackupStore\.categories\(\)/.test(packBody) && /BackupStore\.categories\(\)/.test(restoreBody));
check('① compressFiles 只传一个目录（传多个会被拍平到 zip 根，分类结构全散）',
  /compressFiles\(\[top\], outPath/.test(backup) && !/compressFiles\(\[[^\]]*,/.test(backup));
check('① 解压落到 cacheDir 暂存目录，不直接解进沙箱',
  /decompressFile\(zipPath, stage\)/.test(backup) && !/decompressFile\([^)]*filesDir/.test(backup));
check('① 暂存目录每次先清空（免得残留被当成备份内容）',
  /BackupStore\.clean\(stage\)/.test(backup) && /fs\.mkdirSync\(stage, true\)/.test(backup));
check('① 会下钻包根（新版套 backup/、老版套 data/、别的工具套自己的目录名）',
  /private static findPackageRoot/.test(backup) && /depth < 4/.test(backup));
check('① 认不出的包直接拒绝（不许把别人的 zip 倒进数据目录）',
  /private static looksLikeOurs/.test(backup) && /这不是澄笺的备份包/.test(restoreBody));
check('① 导出写 manifest.json 清单，导入把它当成「这是澄笺的包」的凭据',
  /private static writeManifest/.test(backup)
  && /MANIFEST: string = 'manifest\.json'/.test(backup)
  && /exists\(root \+ '\/' \+ BackupStore\.MANIFEST\)/.test(backup));
check('① 目录只合并、文件同名先删再拷（导入不会删掉本机多出来的数据）',
  /fs\.unlinkSync\(dst\)/.test(backup) && !/rmdirSync\(dst\)/.test(backup));

// ── ① 两条实测踩死整包的细节（copyTree 里）──
// 真机事故：导出提示"N 项读不出来"、导入后书架空空——因为 zip 里文件躺在 <类别>/ 下，
// 而类别文件夹没人创建，copyFileSync 直接 ENOENT，shelf.json / settings.json /
// 两份日志 / tabs.json / review*.json / 壁纸 / 手写 / fonts.json / 卡片快照**全部**没进包。
const copyTreeBody = methodBody(backup, 'private static copyTree(');
check('① 拷文件前先建目标的父目录（不建 = 所有单文件类别整批拷贝失败）',
  copyTreeBody !== null
  && /BackupStore\.ensureDir\(BackupStore\.parentOf\(dst\)\)/.test(copyTreeBody)
  && copyTreeBody.indexOf('parentOf(dst)') < copyTreeBody.indexOf('copyFileSync'));
check('① 空目录不进包（SDK 原文：待压缩的文件夹不能为空，否则 decompressFile 会报错）',
  copyTreeBody !== null
  && /if \(names\.length === 0\) \{\s*return;/.test(copyTreeBody)
  && copyTreeBody.indexOf('listNames(src)') < copyTreeBody.indexOf('ensureDir(dst)'));
check('① 解压报错也接着救（老包夹空文件夹时 zlib 整体报错，暂存目录里往往已有可用数据）',
  restoreBody !== null && /let unzipErr: string = ''/.test(restoreBody)
  && /if \(names\.length === 0\) \{[\s\S]{0,220}备份包读不出来/.test(restoreBody));
// 真机事故二：老版平铺包里的 docs/ 被当成新版的 docs **类别夹**，文档被倒进 filesDir 根，
// 真正的文档目录一个也没恢复。docs/annotations/ai/drafts/versions/fonts 六类 id 与
// 沙箱里的真实目录同名，必须靠「不撞名的类别」或「双层路径 docs/docs/」来区分布局。
check('① 导入先判定包布局（分类 / 老版平铺），判定结果决定要不要按类别写回',
  /private static isCategorized/.test(backup)
  && /const categorized: boolean = BackupStore\.isCategorized\(root, names, cats\)/.test(restoreBody)
  && /categorized \? BackupStore\.categoryById\(cats, entry\) : null/.test(restoreBody));
check('① 撞名类别靠双层路径（docs/docs）区分新老包，不撞名的类别出现即为新包',
  /private static idCollides/.test(backup)
  && /exists\(root \+ '\/' \+ names\[k\] \+ '\/' \+ first\)/.test(backup));

// ══════════════════ ② 覆盖面：从源码反推真实写入位置 ══════════════════

/**
 * 刻意**不进备份**的位置，每条都要写清理由（不然这条名单会变成垃圾场）。
 * 键格式：`<落点>:<相对路径>`。
 */
const NOT_BACKED_UP = {
  'files:webdav_config.json': '老版本的中转文件；新版直接从 preferences 写进包，不再落 filesDir',
  'files:pref_snapshot': '1.1.x 的 preferences XML 目录，那种恢复方式不可靠，导入时还会主动清掉',
  'app:form_ids.json': '卡片 ID 是本机启动器分配的，导到别的机器只会让推送打到不存在的卡片',
  'cache:bk_stage': '打包自己的暂存目录',
  'cache:restore_stage': '解压自己的暂存目录',
  'cache:litemd_backup.zip': '导出用的临时包（再打进去就是套娃）',
  'cache:litemd_import.zip': '导入用的临时包',
  'cache:litemd_webdav_full.zip': 'WebDAV 上传用的临时包',
  'cache:litemd_webdav_restore.zip': 'WebDAV 下载回来的临时包'
};

const files = walk(SRC, []);
/** 从全部源码里收集 `<something>.filesDir + '/xxx'` 这类字面量写入位置 */
function collect(re, kind) {
  const out = new Map();
  for (const f of files) {
    const src = fs.readFileSync(f, 'utf8').replace(/\r\n/g, '\n');
    let m;
    while ((m = re.exec(src)) !== null) {
      let rel = m[1].replace(/\/+$/, '');
      if (rel.length === 0) { continue; }
      const key = kind + ':' + rel;
      if (!out.has(key)) {
        out.set(key, path.relative(SRC, f).replace(/\\/g, '/') + ':'
          + (src.slice(0, m.index).split('\n').length));
      }
    }
  }
  return out;
}
// HAP 级 filesDir（ctx.filesDir / this.context.filesDir / c.filesDir …）
const filesPaths = collect(/\.filesDir\s*\+\s*'\/([^']*)'/g, 'files');
// cacheDir
const cachePaths = collect(/\.cacheDir\s*\+\s*'\/([^']*)'/g, 'cache');
// 应用级 filesDir（FormSync 的 appFilesDir(ctx) + '/xxx'）
const appPaths = collect(/appFilesDir\(ctx\)\s*\+\s*'\/([^']*)'/g, 'app');
// BackupStore 自己按落点根拼的路径（rootDir(...) + '/xxx'）不会出现在上面，手工补：
// 它只写暂存目录，不属于用户数据。

/** BackupStore.SKIP：filesDir 顶层里 extra 兜底**不会**捞走的条目 */
const SKIP = (() => {
  const m = /SKIP: string\[\] = \[([^\]]*)\]/.exec(backup);
  return m === null ? [] : [...m[1].matchAll(/'([^']*)'/g)].map((x) => x[1]);
})();

/** 某个相对路径是否被类别表的显式来源覆盖（'*' 兜底不算） */
function coveredBy(kind, rel) {
  const top = rel.split('/')[0];
  for (const c of cats) {
    if (c.root !== kind) { continue; }
    for (const s of c.sources) {
      if (s === '*') { continue; }
      if (s === rel || rel.startsWith(s + '/')) { return c.id; }
      const star = s.indexOf('*');
      if (star >= 0) {
        const head = s.slice(0, star);
        const tail = s.slice(star + 1);
        // 源码里 `'/wallpaper_' + Date.now() + '.img'` 反推出来的是截断的前缀
        if (rel.startsWith(head) && (tail === '' || rel.endsWith(tail)
          || rel.length < head.length + tail.length)) { return c.id; }
      }
    }
    // extra 兜底 = leftoverNames()：filesDir 顶层、没人认领、且不在 SKIP 名单里
    if (c.id === 'extra' && kind === 'files' && top === rel && SKIP.indexOf(rel) < 0) {
      return 'extra(兜底)';
    }
  }
  return null;
}

const allPaths = new Map([...filesPaths, ...cachePaths, ...appPaths]);
console.log('        源码里反推出写入位置 ' + allPaths.size + ' 处（filesDir '
  + filesPaths.size + ' / cacheDir ' + cachePaths.size + ' / 应用级 ' + appPaths.size + '）');

const uncovered = [];
const onlyExtra = [];
const unexplained = [];
for (const [key, where] of allPaths) {
  const [kind, rel] = [key.slice(0, key.indexOf(':')), key.slice(key.indexOf(':') + 1)];
  const hit = coveredBy(kind, rel);
  if (hit !== null && hit !== 'extra(兜底)') { continue; }
  if (NOT_BACKED_UP[key] !== undefined) {
    if (hit !== null) { unexplained.push(key + '（既在例外名单又被类别覆盖）'); }
    continue;
  }
  if (hit === 'extra(兜底)') { onlyExtra.push(rel + ' ← ' + where); }
  else { uncovered.push(key + ' ← ' + where); }
}
check('② 每一处真实写入位置都被**显式**类别覆盖（或写进例外名单并注明理由）',
  uncovered.length === 0, uncovered.join(' | '));
check('② 例外名单里的位置确实没被类别表覆盖（防名单变垃圾场）',
  unexplained.length === 0, unexplained.join(' | '));
console.log('        只靠 extra 兜底的位置 ' + onlyExtra.length + ' 处'
  + (onlyExtra.length > 0 ? '：' + onlyExtra.join(' | ') : ''));

// 反向：表里的来源必须真有代码在写（防改名 / 打错字留下空类别）
const staleSources = [];
for (const c of cats) {
  if (c.root === 'pref') { continue; }
  for (const s of c.sources) {
    if (s === '*') { continue; }
    const head = s.indexOf('*') >= 0 ? s.slice(0, s.indexOf('*')) : s;
    let found = false;
    for (const [key] of allPaths) {
      const [kind, rel] = [key.slice(0, key.indexOf(':')), key.slice(key.indexOf(':') + 1)];
      if (kind !== c.root) { continue; }
      if (rel === head || rel.startsWith(head + '/') || head.startsWith(rel)) { found = true; break; }
    }
    if (!found) { staleSources.push(c.id + '/' + s); }
  }
}
check('② 表里每个来源都能在源码里找到写入点（防打错字 / 改名后成空类别）',
  staleSources.length === 0, staleSources.join(' | '));

check('② 缓存在备份范围内（用户要求：图表与导出缓存也要备）',
  ids.includes('cache') && cats[ids.indexOf('cache')].sources.includes('charts')
  && cats[ids.indexOf('cache')].sources.includes('export'));
check('② 网盘凭据有一个 preferences 落点的类别，且名/键与 WebDavStore 一致',
  cats.some((c) => c.root === 'pref')
  && /WEBDAV_PREF_NAME: string = 'webdav'/.test(backup)
  && /PREF_NAME: string = 'webdav'/.test(webdav)
  && /WEBDAV_PREF_KEY: string = 'config'/.test(backup)
  && /KEY_CONFIG: string = 'config'/.test(webdav));
check('② 凭据走 API 读写，不再把中转文件留在 filesDir',
  /store\.getSync\(BackupStore\.WEBDAV_PREF_KEY/.test(backup)
  && /store\.putSync\(BackupStore\.WEBDAV_PREF_KEY/.test(backup)
  && /clean\(ctx\.filesDir \+ '\/' \+ BackupStore\.WEBDAV_SNAPSHOT\)/.test(backup));
check('② 桌面卡片快照进包（应用级 filesDir，与 HAP 级不是同一个目录）',
  ids.includes('form') && cats[ids.indexOf('form')].sources.includes('form_snapshot.json')
  && /getApplicationContext\(\)\.filesDir/.test(backup));
check('② 打包前刷新设置镜像（让 settings.json 是当前值）',
  /SettingsMirror\.save\(ctx\)/.test(packBody));
check('② SKIP 名单挡住中转文件与老包残留',
  /SKIP: string\[\] = \['webdav_config\.json', 'pref_snapshot'\]/.test(backup));

// ══════════════════ ③ 恢复后重建内存状态 ══════════════════

const mustReload = ['DocStore', 'ReadingLog', 'WritingLog', 'TabStore'];
for (const s of mustReload) {
  check('③ 恢复后重建 ' + s + ' 的内存缓存',
    new RegExp(s + '\\.reload\\(ctx\\)').test(backup));
  check('③ ' + s + ' 提供了 reload()（清缓存后重读磁盘）',
    /static reload\(ctx: common\.UIAbilityContext\)/.test(read('service/' + s + '.ets')));
}
check('③ 恢复后清图表缓存的内存 memo（否则读不到新导入的 PNG / .dim）',
  /ChartCache\.invalidate\(\)/.test(backup) && /static invalidate\(\)/.test(read('service/ChartCache.ets')));
check('③ 恢复后按盘上实际文件重指壁纸路径（设置里存的是绝对路径）',
  /WallpaperStore\.relink\(ctx\)/.test(backup) && /static relink\(ctx: common\.UIAbilityContext\)/.test(read('service/WallpaperStore.ets')));
check('③ 恢复后注册随包进来的用户字体',
  /FontStore\.invalidateCache\(\)/.test(backup) && /FontStore\.registerAll\(ctx\)/.test(backup));
check('③ 恢复后立刻重设深浅色模式与系统栏（不必重启才换肤）',
  /applyAppColorMode\(themeMode\)/.test(backup) && /applySystemBarTheme/.test(backup));
check('③ 语言也即时生效（reapply 递增 languageTick）',
  /L10n\.reapply\(\)/.test(backup) && /static reapply\(\)/.test(read('service/L10n.ets')));

// ══════════════════ ④ 设置的恢复路径 ══════════════════

check('④ 不再把 preferences 的原始文件拷进包里',
  !/preferencesDir/.test(backup));
check('④ 恢复走 SettingsMirror.forceRestore 回填 AppStorage',
  /SettingsMirror\.forceRestore\(ctx\)/.test(backup) && /static forceRestore/.test(mirror));
check('④ forceRestore 不比时间戳（恢复要以包里那份为准）',
  /恢复备份是用户明确要|不比时间|无条件/.test(mirror));
check('④ 老备份里的 pref_snapshot 残留会被清掉（不再被反复打包）',
  /clean\(ctx\.filesDir \+ '\/pref_snapshot'\)/.test(backup));

// ══════════════════ ⑤ 每个持久化键都要能随备份走 ══════════════════

const persistKeys = [...new Set([...ability.matchAll(/persistProp\(\s*'([^']+)'/g)].map((m) => m[1]))];
const keysBlock = mirror.match(/KEYS: string\[\] = \[([\s\S]*?)\];/);
check('⑤ SettingsMirror.KEYS 能解析', keysBlock !== null);
const mirrored = new Set([...keysBlock[1].matchAll(/'([^']+)'/g)].map((m) => m[1]));
// 例外：**会话内**计数 / 状态，备份里带着反而有害（恢复后会跳到无意义的旧计数）。
// 只列真正注册过 persistProp 的键 —— 下面有一条检查会盯住这点，免得例外名单变垃圾场。
const SESSION_ONLY = {
  'languageTick': '语言刷新计数，会话内递增即可',
  'immersiveLightEnabled': 'EntryAbility 每次启动强制置回 true（材质不再暴露开关）'
};
const missing = persistKeys.filter((k) => !mirrored.has(k) && SESSION_ONLY[k] === undefined);
check('⑤ 每个 persistProp 键都在镜像里（或列在例外并注明理由）',
  missing.length === 0, '漏：' + missing.join(', '));
const badExempt = Object.keys(SESSION_ONLY).filter((k) => !persistKeys.includes(k));
check('⑤ 例外名单里的键确实都是持久化键（防例外名单变垃圾场）',
  badExempt.length === 0, badExempt.join(', '));
check('⑤ 设置镜像本身在类别表里（settings.json）',
  cats.some((c) => c.sources.includes('settings.json')));
console.log('        persistProp ' + persistKeys.length + ' 键 / 镜像 ' + mirrored.size + ' 键 / 例外 '
  + Object.keys(SESSION_ONLY).length);

// ══════════════════ ⑥ WebDAV 口径 ══════════════════

check('⑥ WebDAV 先逐文件（用户文档）后完整包',
  /docs\/' \+ DocStore\.sanitizeName/.test(webdav) && /packToZip/.test(webdav));
check('⑥ WebDAV 上传跳过内置文档（只传用户自己的）',
  /if \(metas\[k\]\.builtin\)/.test(webdav));
check('⑥ WebDAV 的配置快照来自设置镜像（不再另写一份键名单）',
  /SettingsMirror\.save\(ctx\)/.test(webdav) && !/const configKeys/.test(webdav));
check('⑥ WebDAV 恢复复用同一条恢复链路',
  /BackupStore\.restoreFromPath/.test(webdav));

// ══════════════════ ⑦ 文案 ══════════════════

check('⑦ 界面与返回值不再说"导入后重启应用生效"',
  !/导入后重启应用生效/.test(settingsData) && !/设置将重启应用后生效/.test(backup));
check('⑦ 恢复成功的回执写明即刻生效',
  /立即生效/.test(backup));
check('⑦ 界面文案说清了包内按文件夹分类 + manifest 清单',
  /manifest\.json/.test(settingsData) && /按文件夹分类/.test(settingsData));
check('⑦ 界面文案说清了缓存也在备份里',
  /图表与导出缓存/.test(settingsData));

console.log(fails === 0 ? 'BACKUP OK' : 'BACKUP FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
