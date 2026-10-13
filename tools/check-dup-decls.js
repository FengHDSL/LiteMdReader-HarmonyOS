#!/usr/bin/env node
/**
 * 顶层重复声明扫描（ArkTS 会直接 BUILD FAILED，本机没 hvigor 时至少能自查）
 * ======================================================================
 *
 * 触发原因：给 HeadingHit 补 missHeading() 时没注意文件里已经有一份，
 * 重复声明把整个模块的编译打断（hvigor 00305015 Rollup + Duplicate function）。
 * 编译器能查的东西没必要建规，但**没有编译器可跑时**这条就是唯一的拦截点。
 *
 * 查四类：模块级 function / interface / const·let、类内 static 方法、类内 readonly 字段。
 * 用法：node tools/check-dup-decls.js [文件…]（不传参则扫全部 ets）
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', 'entry', 'src', 'main');

function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { walk(p, out); }
    else if (e.name.endsWith('.ets')) { out.push(p); }
  }
  return out;
}

const targets = process.argv.length > 2
  ? process.argv.slice(2).map((f) => path.resolve(f))
  : walk(ROOT, []);

let problems = 0;
for (const file of targets) {
  const src = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
  const lines = src.split('\n');
  const seen = new Map();            // 模块级名字 -> 首次出现的行号
  let statics = new Map();           // **类内** static 成员 -> 行号（每遇到一个新 class 就重开）
  const note = (map, key, lineNo, text) => {
    if (map.has(key)) {
      problems++;
      console.log('  DUP  ' + path.relative(ROOT, file) + ':' + lineNo
        + '  ' + key + '（首次在第 ' + map.get(key) + ' 行）');
      console.log('       ' + text.trim().slice(0, 90));
    } else {
      map.set(key, lineNo);
    }
  };
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    const no = i + 1;
    if (/^\s*(\/\/|\*|\/\*)/.test(l)) { continue; }
    let m = /^(?:export\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)/.exec(l);
    if (m) {
      note(seen, 'class ' + m[1], no, l);
      statics = new Map();           // 静态成员的重名只在**同一个类**里才算冲突
      continue;
    }
    m = /^(?:export\s+)?function\s+([A-Za-z_$][\w$]*)/.exec(l);
    if (m) { note(seen, 'function ' + m[1], no, l); continue; }
    m = /^(?:export\s+)?(interface|enum|type)\s+([A-Za-z_$][\w$]*)/.exec(l);
    if (m) { note(seen, m[1] + ' ' + m[2], no, l); continue; }
    m = /^(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)/.exec(l);
    if (m) { note(seen, 'module-var ' + m[1], no, l); continue; }
    // 类成员：只查缩进的 static 声明（实例成员允许与父类重名，不管）
    m = /^\s{2,}(?:private\s+|public\s+)?static\s+(?:readonly\s+)?([A-Za-z_$][\w$]*)\s*[(:]/.exec(l);
    if (m) { note(statics, 'static ' + m[1], no, l); continue; }
  }
}
console.log(problems === 0
  ? 'DUP DECLS OK — ' + targets.length + ' 个文件无重复顶层声明'
  : 'DUP DECLS FAILED: ' + problems);
process.exit(problems === 0 ? 0 : 1);
