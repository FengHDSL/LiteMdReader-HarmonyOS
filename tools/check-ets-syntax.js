#!/usr/bin/env node
/**
 * ArkTS 文件的**语法前检查**（提交前自查，不用等真机构建）
 * =====================================================
 *
 * 起因：给 HeadingHit 补 missHeading() 时重复声明了一份，把整个模块的编译打断，
 * 而本机没有 hvigor / Java，唯一的反馈渠道是用户在 DevEco 里点构建 —— 等构建失败
 * 再改，一轮就是几十分钟。所以能在提交前自己拦住的，就别等编译器。
 *
 * 三道检查按文件类型分开：
 *  ① **纯逻辑文件**（不含 ArkUI 声明式语法）：直接用 SDK 自带的 TypeScript 解析，
 *     要求 0 条 parse 诊断。ets-loader 用的就是这份 typescript，判定口径与编译器一致。
 *  ② 同一批逻辑文件再做**真类型检查**（createProgram + getPreEmitDiagnostics）：
 *     重复声明、对象字面量缺字段这类错误 ① 看不见（语法完全合法），必须走完语义分析。
 *     模块解析按 ets-loader 的口径补齐：`@kit.X` → SDK/ets/kits、`@ohos.x`/`@arkts.x` →
 *     SDK/ets/api|arkts、相对导入补 `.ets` 后缀，并把 `ets-loader/declarations/*.d.ts`
 *     当全局声明带上（否则 AppStorage / setTimeout 全是"找不到名字"）。
 *     实测口径：当前树 42 条诊断全部落在两类环境噪音里（见 NOISE_CODES），
 *     而 ab823a0 那次真正打断构建的改动被原样复现成 3 条（TS2393 ×2 + TS2741 ×1）。
 *  ③ **组件文件**（有 struct / @Component / @Builder）：TS 天生读不懂 UI 语法
 *     （MdView.ets 在今天的改动**之前**就有 148 条 parse 诊断），错误数只能随代码量涨，
 *     不是信号。这类改查**定界符配平**：括号/方括号/花括号在跳过字符串、模板串、
 *     注释、正则字面量之后必须各自归零。
 *
 * 用法：node tools/check-ets-syntax.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

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
    || /@ComponentV2\b/.test(src) || /@ObservedV2\b/.test(src)
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

/** ets-loader 用的就是这份 SDK，kit 声明跟着 TS_MOD 走，避免两处版本号各写各的 */
const SDK_ETS = path.resolve(TS_MOD, '..', '..', '..', '..').replace(/\\/g, '/');

/**
 * 环境噪音：不是代码写错，是本机 SDK 与真机构成的差异，放行。
 *  · 2307 —— `@kit.ShareKit` / `@kit.UIDesignKit` 只存在于 HarmonyOS SDK，
 *    OpenHarmony SDK 的 ets/kits 里就没有这两个文件（真机构建由华为侧 SDK 提供）。
 *  · 28040 —— "Function may throw exceptions"：OpenHarmony 改版 TS 对带 @throws 标注的
 *    平台接口一律报这一条，DevEco 构建里它是 WARN（用户那次的 WARN:108 就包含这些），
 *    不影响编译产物，也不构成我们需要拦的错。
 */
const NOISE_CODES = new Set([2307, 28040]);

function sdkRoots() {
  return [SDK_ETS + '/kits', SDK_ETS + '/api', SDK_ETS + '/arkts'];
}

/** 相对导入补后缀：ArkTS 工程里 `./MdParser` 指的是 `MdParser.ets` */
function resolveLocal(base) {
  for (const ext of ['.ets', '.d.ets', '.ts', '.d.ts']) {
    if (fs.existsSync(base + ext)) { return base + ext; }
  }
  for (const ext of ['.ets', '.ts']) {
    if (fs.existsSync(path.join(base, 'index' + ext))) { return path.join(base, 'index' + ext); }
  }
  return undefined;
}

function resolveModule(moduleName, containingFile) {
  if (/^@(kit|ohos|arkts)[./]/.test(moduleName)) {
    for (const root of sdkRoots()) {
      for (const ext of ['.d.ts', '.d.ets']) {
        const p = path.join(root, moduleName + ext).replace(/\\/g, '/');
        if (fs.existsSync(p)) {
          return { resolvedFileName: p, extension: ext, isExternalLibraryImport: true };
        }
      }
    }
    return undefined;
  }
  if (moduleName.startsWith('.') || path.isAbsolute(moduleName)) {
    const dir = path.isAbsolute(moduleName) ? path.dirname(moduleName) : path.dirname(containingFile);
    const hit = resolveLocal(path.resolve(dir, moduleName).replace(/\\/g, '/'));
    if (hit !== undefined) {
      return { resolvedFileName: hit, extension: path.extname(hit), isExternalLibraryImport: false };
    }
  }
  return undefined;
}

/**
 * ② 类型检查。返回**非噪音**诊断列表（rel / line / code / msg）。
 * 组件文件不送检，但它们会被逻辑文件 import 进来 —— 只用于取类型，诊断按 checked 过滤掉。
 */
function typecheck(logicFiles) {
  const options = {
    target: ts.ScriptTarget.ES2021,
    module: ts.ModuleKind.CommonJS,
    moduleResolution: ts.ModuleResolutionKind.NodeJs,
    lib: ['lib.es2021.d.ts'],
    types: [],
    typeRoots: [],
    skipLibCheck: true,
    alwaysStrict: true,
    experimentalDecorators: true,
    noEmit: true,
  };
  const host = ts.createCompilerHost(options, true);
  // 这份 SDK 打包的是 typescript 4.9.5：program 只认 host.resolveModuleNames（复数、数组式），
  // 5.0 才有的 resolveModuleNameLiterals 在这里永远不会被调用；而 4.9 的 createCompilerHost
  // 又不再自带 resolveModuleName，所以必须自己挂上。
  host.resolveModuleNames = function (names, containingFile, reused, redirected, opts) {
    return names.map((name) => {
      const mine = resolveModule(name, containingFile);
      if (mine !== undefined) { return mine; }
      return ts.resolveModuleName(name, containingFile, opts, host).resolvedModule;
    });
  };
  const origGetSourceFile = host.getSourceFile;
  host.getSourceFile = function (fileName, langVersion, onError, shouldCreate) {
    const sf = origGetSourceFile.call(host, fileName, langVersion, onError, shouldCreate);
    if (sf !== undefined || !fileName.endsWith('.ets')) { return sf; }
    return ts.createSourceFile(fileName, fs.readFileSync(fileName, 'utf8').replace(/\r\n/g, '\n'),
      langVersion, true, ts.ScriptKind.TS);
  };
  const declDir = SDK_ETS + '/build-tools/ets-loader/declarations';
  const globals = fs.existsSync(declDir)
    ? fs.readdirSync(declDir).filter((f) => f.endsWith('.d.ts')).map((f) => declDir + '/' + f)
    : [];
  const checked = new Set(logicFiles.map((f) => f.replace(/\\/g, '/')));
  const program = ts.createProgram({ rootNames: Array.from(checked).concat(globals), options, host });
  const out = [];
  for (const d of ts.getPreEmitDiagnostics(program)) {
    if (d.file === undefined || NOISE_CODES.has(d.code)) { continue; }
    const fn = d.file.fileName.replace(/\\/g, '/');
    if (!checked.has(fn)) { continue; }
    out.push({
      rel: path.relative(SRC, fn).replace(/\\/g, '/'),
      line: d.file.getLineAndCharacterOfPosition(d.start || 0).line + 1,
      code: 'TS' + d.code,
      msg: ts.flattenDiagnosticMessageText(d.messageText, ' ').split('\n')[0],
    });
  }
  return out;
}

const files = walk(SRC, []);
let bad = 0;
let logic = 0;
let comp = 0;
const logicFiles = [];
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
  logicFiles.push(file);
  const d = parseErrors(file, src);
  if (d.length > 0) {
    bad++;
    const first = d.slice(0, 3).map((x) => 'L' + (src.slice(0, x.start).split('\n').length)
      + ': ' + ts.flattenDiagnosticMessageText(x.messageText, ' '));
    console.log('  语法 FAIL  ' + rel + '  ×' + d.length + ' —— ' + first.join(' | '));
  }
}
let typeBad = 0;
try {
  const t = typecheck(logicFiles);
  typeBad = t.length;
  for (const x of t.slice(0, 20)) {
    console.log('  类型 FAIL  ' + x.rel + ':' + x.line + '  ' + x.code + ' ' + x.msg);
  }
  if (t.length > 20) { console.log('  …… 另有 ' + (t.length - 20) + ' 条类型诊断'); }
} catch (e) {
  console.log('  类型检查未能运行：' + e.message);
  process.exit(1);
}
bad += typeBad;
const verdict = bad === 0 ? 'ETS SYNTAX OK' : 'ETS SYNTAX FAILED: ' + bad;
console.log(verdict + ' — ' + logic + ' 个逻辑文件 TS 解析零诊断、类型检查 '
  + (typeBad === 0 ? '零诊断' : typeBad + ' 条诊断') + '，'
  + comp + ' 个组件文件定界符配平');
process.exit(bad === 0 ? 0 : 1);
