#!/usr/bin/env node
/**
 * ArkTS 文件的**语法前检查**（提交前自查，不用等真机构建）
 * =====================================================
 *
 * 起因：给 HeadingHit 补 missHeading() 时重复声明了一份，把整个模块的编译打断，
 * 而本机没有 hvigor / Java，唯一的反馈渠道是用户在 DevEco 里点构建 —— 等构建失败
 * 再改，一轮就是几十分钟。所以能在提交前自己拦住的，就别等编译器。
 *
 * 两道检查按文件类型分开：
 *  ① **纯逻辑文件**（不含 ArkUI 声明式语法）：直接用 SDK 自带的 TypeScript 解析，
 *     要求 0 条 parse 诊断。ets-loader 用的就是这份 typescript，判定口径与编译器一致。
 *  ② **组件文件**（有 struct / @Component / @Builder）：TS 天生读不懂 UI 语法
 *     （MdView.ets 在今天的改动**之前**就有 148 条 parse 诊断），错误数只能随代码量涨，
 *     不是信号。这类改查**定界符配平**：括号/方括号/花括号在跳过字符串、模板串、
 *     注释、正则字面量之后必须各自归零。
 *
 * 用法：node tools/check-ets-syntax.js
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const SRC = path.join(ROOT, 'entry', 'src', 'main');
const TS_MOD =
  'C:/Users/panda/AppData/Local/OpenHarmony/Sdk/26.0.0/ets/build-tools/ets-loader/node_modules/typescript';

let ts;
try {
  ts = require(TS_MOD);
} catch (e) {
  console.log('找不到 SDK 自带的 typescript（' + TS_MOD + '），① 无法执行');
  process.exit(1);
}

function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { walk(p, out); }
    else if (e.name.endsWith('.ets')) { out.push(p); }
  }
  return out;
}

/** 组件文件：UI 声明式语法 TS 读不懂 */
function isComponentFile(src) {
  return /\bstruct\s+[A-Za-z_$]/.test(src) || /@Component\b/.test(src)
    || /@CustomDialog\b/.test(src) || /@Extend\b/.test(src) || /@Builder\b/.test(src);
}

/**
 * 定界符配平：跳过单双引号串、反引号模板串（含 ${} 内插递归）、行注释与块注释、
 * 以及正则字面量（按前一非空白字符判断斜杠是除法还是正则开头）。
 */
function balance(src) {
  const stack = [];
  const pairs = { ')': '(', ']': '[', '}': '{' };
  let prev = '';                     // 前一个有意义的字符（判正则用）
  for (let i = 0; i < src.length; i++) {
    const c = src.charAt(i);
    const nx = i + 1 < src.length ? src.charAt(i + 1) : '';
    if (c === '/' && nx === '/') {
      while (i < src.length && src.charAt(i) !== '\n') { i++; }
      continue;
    }
    if (c === '/' && nx === '*') {
      i += 2;
      while (i < src.length && !(src.charAt(i) === '*' && src.charAt(i + 1) === '/')) { i++; }
      i++;
      continue;
    }
    if (c === '"' || c === '\'' || c === '`') {
      i = skipString(src, i, c);
      prev = c;
      continue;
    }
    if (c === '/' && prev !== '' && '(,=:[!&|?{};+-*%<>~^'.indexOf(prev) >= 0) {
      i = skipRegex(src, i);
      prev = '/';
      continue;
    }
    if (c === '(' || c === '[' || c === '{') { stack.push(c); }
    else if (c === ')' || c === ']' || c === '}') {
      if (stack.pop() !== pairs[c]) {
        return { ok: false, why: '第 ' + (src.slice(0, i).split('\n').length) + ' 行的 ' + c + ' 没有对应开括号' };
      }
    }
    if (c !== ' ' && c !== '\t' && c !== '\n' && c !== '\r') { prev = c; }
  }
  if (stack.length !== 0) {
    return { ok: false, why: '还有 ' + stack.length + ' 个开括号没闭合（最内是 ' + stack[stack.length - 1] + '）' };
  }
  return { ok: true };
}

function skipString(src, i, quote) {
  i++;
  while (i < src.length) {
    const c = src.charAt(i);
    if (c === '\\') { i += 2; continue; }
    if (quote === '`' && c === '$' && src.charAt(i + 1) === '{') {
      let depth = 1;
      i += 2;
      while (i < src.length && depth > 0) {
        const d = src.charAt(i);
        if (d === '{') { depth++; }
        else if (d === '}') { depth--; }
        else if (d === '"' || d === '\'' || d === '`') { i = skipString(src, i, d); }
        i++;
      }
      continue;
    }
    if (c === quote) { return i; }
    i++;
  }
  return i;
}

function skipRegex(src, i) {
  i++;
  let inClass = false;
  while (i < src.length) {
    const c = src.charAt(i);
    if (c === '\\') { i += 2; continue; }
    if (c === '[') { inClass = true; }
    else if (c === ']') { inClass = false; }
    else if (c === '/' && !inClass) { return i; }
    else if (c === '\n') { return i; }          // 跨行不成正则，退回按普通字符处理
    i++;
  }
  return i;
}

function parseErrors(file, src) {
  const sf = ts.createSourceFile(file, src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  return sf.parseDiagnostics || [];
}

const files = walk(SRC, []);
let bad = 0;
let logic = 0;
let comp = 0;
for (const file of files) {
  const src = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
  const rel = path.relative(SRC, file).replace(/\\/g, '/');
  if (isComponentFile(src)) {
    comp++;
    const b = balance(src);
    if (!b.ok) { bad++; console.log('  配平 FAIL  ' + rel + '  ' + b.why); }
    continue;
  }
  logic++;
  const d = parseErrors(file, src);
  if (d.length > 0) {
    bad++;
    const first = d.slice(0, 3).map((x) => 'L' + (src.slice(0, x.start).split('\n').length)
      + ': ' + ts.flattenDiagnosticMessageText(x.messageText, ' '));
    console.log('  语法 FAIL  ' + rel + '  ×' + d.length + ' —— ' + first.join(' | '));
  }
}
const verdict = bad === 0 ? 'ETS SYNTAX OK' : 'ETS SYNTAX FAILED: ' + bad;
console.log(verdict + ' — ' + logic + ' 个逻辑文件 TS 解析零诊断，'
  + comp + ' 个组件文件定界符配平');
process.exit(bad === 0 ? 0 : 1);
