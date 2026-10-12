#!/usr/bin/env node
/**
 * 备份 / 恢复的不变量检查（**只读代码，不改代码**）
 * ==============================================
 *
 * 起因：导出备份 → 导入 → 重启应用 → 数据没进来。根因有三条，每条都在这里钉住，
 * 以后谁改这块代码，改坏了当场就会红：
 *
 *  ① **解压不许直接落到 filesDir**。zlib.decompressFile 对"目标已存在同名文件"
 *     没有任何覆盖承诺，本机有数据时可能整批跳过 → 必须解到 cacheDir 暂存目录，
 *     再用 copyInto（同名先删再拷）覆盖进 filesDir。
 *  ② **恢复后必须重建内存缓存**。DocStore / ReadingLog / WritingLog / TabStore
 *     都带 ready 门闩与内存副本，不重载的话下一次 persist 会把恢复前的状态盖回
 *     刚导入的文件（"导入成功、重启回到老数据"就是这么来的）。
 *  ③ **设置不许靠拷 preferences 的 XML 文件恢复**。进程里那些 preferences 实例
 *     还活着，下次 flush 就把刚拷进去的文件冲掉了；改成 settings.json →
 *     SettingsMirror.forceRestore 回填 AppStorage（持久化键会写穿到 preferences），
 *     WebDAV 配置走 preferences API 写回 → **不用重启**。
 *
 * 另外钉住两条"全部数据"的口径：
 *  ④ 打包必须是 filesDir **顶层全部条目**（不许白名单过滤）+ WebDAV 配置快照；
 *  ⑤ 每一个 persistProp 键都必须在 SettingsMirror.KEYS 里，否则备份带不走这项设置
 *     （会话计数器一类的临时键在例外名单里注明原因）。
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

const backup = read('service/BackupStore.ets');
const mirror = read('service/SettingsMirror.ets');
const webdav = read('service/WebDavStore.ets');
const ability = read('entryability/EntryAbility.ets');
const settingsData = read('pages/SettingsData.ets');

// ── ① 解压落点 ──
check('① 恢复解压到暂存目录，不直接解进 filesDir',
  !/decompressFile\([^)]*filesDir/.test(backup) && /decompressFile\(zipPath, stage\)/.test(backup));
check('① 覆盖拷贝用 copyInto（同名先删再拷）',
  /private static async copyInto/.test(backup) && /await BackupStore\.copyInto\(stage, ctx\.filesDir\)/.test(backup));
check('① 暂存目录每次先清空（免得残留被当成备份内容）',
  /fs\.rmdirSync\(stage\)/.test(backup) && /fs\.mkdirSync\(stage, true\)/.test(backup));
check('① 恢复前校验包结构（不像澄笺备份就报错）',
  /shelf\.json/.test(backup) && /这不是澄笺的备份包/.test(backup));

// ── ② 内存缓存必须重载 ──
const mustReload = ['DocStore', 'ReadingLog', 'WritingLog', 'TabStore'];
for (const s of mustReload) {
  check('② 恢复后重建 ' + s + ' 的内存缓存',
    new RegExp(s + '\\.reload\\(ctx\\)').test(backup));
  const file = 'service/' + s + '.ets';
  check('② ' + s + ' 提供了 reload()（清缓存后重读磁盘）',
    /static reload\(ctx: common\.UIAbilityContext\)/.test(read(file)));
}
check('② 导入入口不再用 init() 假装重载',
  !/DocStore\.init\(ctx\);\s*\n\s*\}/.test(settingsData) || !/数据变了，重载书架索引/.test(settingsData));

// ── ③ 设置的恢复路径 ──
check('③ 不再把 preferences 的原始文件拷进包里',
  !/preferencesDir/.test(backup) || !/copyFileSync\(ctx\.preferencesDir/.test(backup));
check('③ 不再用原始文件覆盖 preferences（会被运行中的实例冲掉）',
  !/copyFileSync\(snap \+ '\/' \+ pnames\[k\], ctx\.preferencesDir/.test(backup));
check('③ 恢复走 SettingsMirror.forceRestore 回填 AppStorage',
  /SettingsMirror\.forceRestore\(ctx\)/.test(backup) && /static forceRestore/.test(mirror));
check('③ forceRestore 不比时间戳（恢复要以包里那份为准）',
  /恢复备份是用户明确要|不比时间|无条件/.test(mirror));
check('③ WebDAV 配置走 preferences API 写回',
  /applyWebDavConfig/.test(backup) && /putSync\(BackupStore\.WEBDAV_PREF_KEY/.test(backup));
check('③ 打包前把 WebDAV 配置 dump 成包内文件',
  /dumpWebDavConfig/.test(backup) && /store\.getSync\(BackupStore\.WEBDAV_PREF_KEY/.test(backup));
check('③ 语言也即时生效（reapply 递增 languageTick）',
  /L10n\.reapply\(\)/.test(backup) && /static reapply\(\)/.test(read('service/L10n.ets')));
check('③ 恢复后立刻重设深浅色模式与系统栏（不必重启才换肤）',
  /applyAppColorMode\(themeMode\)/.test(backup) && /applySystemBarTheme/.test(backup));
check('③ 恢复后注册随包进来的用户字体',
  /FontStore\.invalidateCache\(\)/.test(backup) && /FontStore\.registerAll\(ctx\)/.test(backup));
check('③ 老备份里的 pref_snapshot 残留会被清掉（不再被反复打包）',
  /'\/pref_snapshot'/.test(backup) || /pref_snapshot/.test(backup));

// ── ④ 全量口径 ──
check('④ 打包 = filesDir 顶层全部条目（无白名单过滤）',
  /await fs\.listFile\(ctx\.filesDir\)/.test(backup) && !/WHITELIST|允许名单|备份白名单/.test(backup));
check('④ 打包前刷新设置镜像（让 settings.json 是当前值）',
  /SettingsMirror\.save\(ctx\)/.test(backup));

// ── ⑤ 每个持久化键都要能随备份走 ──
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
console.log('        persistProp ' + persistKeys.length + ' 键 / 镜像 ' + mirrored.size + ' 键 / 例外 '
  + Object.keys(SESSION_ONLY).length);

// ── ⑥ WebDAV 口径 ──
check('⑥ WebDAV 先逐文件（用户文档）后完整包',
  /docs\/' \+ DocStore\.sanitizeName/.test(webdav) && /packToZip/.test(webdav));
check('⑥ WebDAV 上传跳过内置文档（只传用户自己的）',
  /if \(metas\[k\]\.builtin\)/.test(webdav));
check('⑥ WebDAV 的配置快照来自设置镜像（不再另写一份键名单）',
  /SettingsMirror\.save\(ctx\)/.test(webdav) && !/const configKeys/.test(webdav));
check('⑥ WebDAV 恢复复用同一条恢复链路',
  /BackupStore\.restoreFromPath/.test(webdav));

// ── ⑦ 文案不许再骗用户"重启才生效" ──
check('⑦ 界面与返回值不再说"导入后重启应用生效"',
  !/导入后重启应用生效/.test(settingsData) && !/设置将重启应用后生效/.test(backup));
check('⑦ 恢复成功的回执写明即刻生效',
  /立即生效/.test(backup));

console.log(fails === 0 ? 'BACKUP OK' : 'BACKUP FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
