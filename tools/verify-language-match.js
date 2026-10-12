// 跟随系统的解析规则是用户明确要求（不在内置 7 种里 → 简体中文），
// 这里把 L10n.ets 里 match() 的**源码原样抽出来**在 Node 里跑，避免"注释说一套代码做一套"。
const fs = require('fs');
const src = fs.readFileSync('entry/src/main/ets/service/L10n.ets', 'utf8').replace(/\r\n/g, '\n');
const start = src.indexOf('static match(tag: string): string {');
if (start < 0) { throw new Error('没找到 match()，改名了就要同步改这个检查'); }
const braceAt = src.indexOf('{', start);
let depth = 0, end = -1;
for (let i = braceAt; i < src.length; i++) {
  if (src[i] === '{') { depth++; } else if (src[i] === '}') { depth--; if (depth === 0) { end = i + 1; break; } }
}
let body = src.slice(braceAt + 1, end - 1);
// 去掉 ArkTS 类型标注，并把 L10n. 前缀换成注入的对象（只影响这段纯函数）
body = body.replace(/:\s*string/g, '').split('L10n.').join('ENV.');
const fn = new Function('tag', 'ENV', body);
const ENV = { ZH_CN: 'zh-CN', SYSTEM: 'system' };

const cases = [
  ['zh-Hans-CN', 'zh-CN'], ['zh-CN', 'zh-CN'], ['zh-Hans', 'zh-CN'], ['zh-SG', 'zh-CN'],
  ['zh-Hant-HK', 'zh-HK'], ['zh-HK', 'zh-HK'], ['zh-Hant-MO', 'zh-HK'],
  ['zh-Hant-TW', 'zh-TW'], ['zh-TW', 'zh-TW'], ['zh-Hant', 'zh-TW'],
  ['en', 'en-US'], ['en-US', 'en-US'], ['en-Latn-US', 'en-US'], ['en-GB', 'en-GB'],
  ['en-AU', 'en-GB'], ['en-IE', 'en-GB'], ['en-NZ', 'en-GB'],
  ['ja-JP', 'ja-JP'], ['ja', 'ja-JP'], ['ko-KR', 'ko-KR'], ['ko', 'ko-KR'],
  ['fr-FR', 'zh-CN'], ['de', 'zh-CN'], ['ru', 'zh-CN'], ['es-MX', 'zh-CN'], ['', 'zh-CN'],
  ['zh_Latn_CN', 'zh-CN']
];
let bad = 0;
for (const [tag, want] of cases) {
  const got = fn(tag, ENV);
  const ok = got === want;
  if (!ok) { bad++; }
  console.log((ok ? 'ok   ' : 'FAIL ') + (tag === '' ? '(空)' : tag).padEnd(14) + '→ ' + got + (ok ? '' : '  期望 ' + want));
}
console.log(bad === 0 ? 'MATCH OK' : 'MATCH FAILED: ' + bad);
process.exit(bad === 0 ? 0 : 1);
