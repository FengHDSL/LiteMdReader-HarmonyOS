/**
 * 校验（只读，不改源码）：@Component struct 里自定义的方法名，
 * 有没有撞上 ArkUI 属性方法（CustomComponent / CommonMethod 的成员）。
 * 撞上的话 DevEco 会报 10505001 "Property 'x' in type ... is not assignable
 * to the same property in base type 'CustomComponent'" —— 我们的 tsc 门禁看不到，
 * 因为 struct 的基类是编译器注入的。
 *
 * 用法：node .workbuddy/check-attr-collide.js [文件...]
 */
const fs = require('fs');
const path = require('path');

const SDK = 'C:/Users/panda/AppData/Local/OpenHarmony/Sdk/26.0.0/ets';
const COMMON = path.join(SDK, 'component/common.d.ts');

/** 属性方法名：从 SDK 的 common.d.ts 里扫（含各类 Options 成员，宁可误报也别漏） */
function attrNames() {
  const text = fs.readFileSync(COMMON, 'utf8');
  const out = new Set();
  const re = /^\s{2,8}([a-zA-Z_$][\w$]*)\s*[({]/gm;
  let m;
  while ((m = re.exec(text)) !== null) {
    out.add(m[1]);
  }
  // struct 基类自身的成员（不在 common.d.ts 里）
  ['size', 'position', 'opacity', 'scale', 'rotate', 'translate', 'clip', 'id',
    'key', 'onAttach', 'onDetach', 'getUniqueId', 'applyCustomProperty',
    'makeBinding', 'purgeV2PropByStateVar', 'setConstructorParam', 'build'].forEach(n => out.add(n));
  return out;
}

/** 每个 struct 里自定义的方法名 */
function structMethods(text) {
  const list = [];
  const re = /struct\s+([A-Za-z_$][\w$]*)\s*\{/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const name = m[1];
    let i = re.lastIndex;
    let depth = 1;
    let body = '';
    while (i < text.length && depth > 0) {
      const c = text[i];
      if (c === '{') depth++;
      else if (c === '}') depth--;
      if (depth > 0) body += c;
      i++;
    }
    const fre = /^\s{2}(?:private\s+|public\s+|protected\s+|static\s+)*([A-Za-z_$][\w$]*)\s*\(/gm;
    let f;
    while ((f = fre.exec(body)) !== null) {
      list.push([name, f[1]]);
    }
  }
  return list;
}

const attrs = attrNames();
const files = process.argv.slice(2);
let bad = 0;
for (const f of files) {
  const text = fs.readFileSync(f, 'utf8');
  for (const [struct, meth] of structMethods(text)) {
    if (meth === 'build' || meth === struct) {
      continue;                       // build() 是必须覆写的生命周期，struct 名是构造器
    }
    if (attrs.has(meth)) {
      console.log('COLLIDE  ' + path.basename(f) + '  struct ' + struct + '  方法 ' + meth + '()');
      bad++;
    }
  }
}
console.log(bad === 0 ? 'ATTR COLLIDE OK — ' + files.length + ' 个文件的 struct 方法名没撞上属性方法'
  : 'ATTR COLLIDE FAILED: ' + bad);
process.exit(bad === 0 ? 0 : 1);
