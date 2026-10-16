'use strict';
/**
 * 本地 ArkTS 校验的一个洞：组件文件（@Component / @Builder 那一堆页面）只做定界符
 * 配平，不做类型检查 —— 于是「改了 @Builder 的签名、漏改某个调用点」这种**参数个数**
 * 错误要等 hvigor 编译才炸（2026-10-16 真实回归：moreTile 去掉 fixedW 参数，
 * tabMenuPanel 里还有 4 处传 4 个实参，用户直接拿到 BUILD FAILED）。
 *
 * 这个门补的就是这一条：扫每个 .ets 里**本文件定义的** @Builder / private 方法，
 * 数清必填参数个数，再检查同文件内所有 `this.name(` 调用的顶层实参个数。
 * 只报"多了"（少了会被 TS 正常报，且默认参数场景多传才是真错）。
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const ETS = path.join(ROOT, 'entry', 'src', 'main', 'ets');
const FILES = [];
(function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { walk(p); } else if (e.name.endsWith('.ets')) { FILES.push(p); }
  }
})(ETS);

/** 从 openIdx（指向 '(' 之后）扫到配对的 ')'，返回顶层实参个数。 */
function countArgs(src, openIdx) {
  let d = 1, args = 1, inS = null, i = openIdx;
  let sawAny = false;
  while (i < src.length && d > 0) {
    const c = src[i];
    if (inS !== null) {
      if (c === '\\') { i += 2; continue; }
      if (c === inS) { inS = null; }
    } else if (c === '\'' || c === '"' || c === '`') {
      inS = c; sawAny = true;
    } else if (c === '(' || c === '[' || c === '{') {
      d++; sawAny = true;
    } else if (c === ')' || c === ']' || c === '}') {
      d--; if (d === 0) break;
    } else if (c === ',') {
      if (d === 1) { args++; } sawAny = true;
    } else if (!/\s/.test(c)) {
      sawAny = true;
    }
    i++;
  }
  return sawAny ? args : 0;
}

/** 参数总数（含带默认值的）：调用方**多传**要和这个比，不是和必填数比
 * （`showRefresh: boolean = false` 是可选但**允许传**的，比必填数会误报）。 */
function totalParams(paramList) {
  if (paramList.trim().length === 0) { return 0; }
  let d = 0, cur = '', parts = [];
  for (const c of paramList) {
    if (c === '(' || c === '[' || c === '{') d++;
    else if (c === ')' || c === ']' || c === '}') d--;
    if (c === ',' && d === 0) { parts.push(cur); cur = ''; } else { cur += c; }
  }
  parts.push(cur);
  let n = 0;
  for (const p of parts) {
    if (p.trim().length > 0) { n++; }
  }
  return n;
}

let fails = 0;
/** 从 '(' 之后扫到配对 ')'，返回参数原文（支持 `cb: () => void` 这种带括号的签名）。 */
function readParams(src, openIdx) {
  let d = 1, i = openIdx, inS = null;
  while (i < src.length && d > 0) {
    const c = src[i];
    if (inS !== null) {
      if (c === '\\') { i += 2; continue; }
      if (c === inS) { inS = null; }
    } else if (c === '\'' || c === '"' || c === '`') {
      inS = c;
    } else if (c === '(' || c === '[' || c === '{') {
      d++;
    } else if (c === ')' || c === ']' || c === '}') {
      d--; if (d === 0) break;
    }
    i++;
  }
  return src.substring(openIdx, i);
}

for (const f of FILES) {
  const src = fs.readFileSync(f, 'utf8').replace(/\r\n/g, '\n');
  const defs = new Map();
  const defRe = /(?:@Builder\s*\n\s*)?(?:private\s+|static\s+)?([A-Za-z_$][\w$]*)\s*\(/g;
  let m;
  while ((m = defRe.exec(src)) !== null) {
    const name = m[1];
    if (/\b(if|for|while|switch|catch|return|function)\b/.test(name)) { continue; }
    // 只认真正的方法/构造定义：参数表后面必须紧跟 `)` + 空白 + `{`
    const after = src.substring(defRe.lastIndex);
    const closeIdx = src.indexOf(')', m.index + m[0].length);
    if (closeIdx < 0) { continue; }
    if (!/^\s*\{/.test(src.substring(closeIdx + 1, closeIdx + 40))) { continue; }
    const params = readParams(src, m.index + m[0].length);
    if (params.includes(';') || params.length > 400) { continue; }
    if (!defs.has(name)) { defs.set(name, totalParams(params)); }
    void after;
  }
  for (const [name, need] of defs) {
    const callRe = new RegExp('this\\.' + name.replace(/\$/g, '\\$') + '\\(', 'g');
    let c;
    while ((c = callRe.exec(src)) !== null) {
      const got = countArgs(src, c.index + c[0].length);
      if (got > need) {
        fails++;
        const line = src.substring(0, c.index).split('\n').length;
        console.log('  FAIL  ' + path.relative(ROOT, f) + ':' + line
          + '  this.' + name + '( 传了 ' + got + ' 个实参，签名只要 ' + need + ' 个');
      }
    }
  }
}
console.log(fails === 0
  ? 'BUILDER ARITY OK — ' + FILES.length + ' 个 .ets 的 this.xxx() 调用参数个数与签名一致'
  : 'BUILDER ARITY FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
