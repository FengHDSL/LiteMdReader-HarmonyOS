'use strict';
// 代码高亮实测：把**真 CodeHighlight.ets** 转成 CJS 跑一遍（与 tools/verify-syntax-coverage.js
// 同一套 SDK typescript 转译），逐语言验三件事：这语言认不认得（family 不为 None）、
// 注释能不能上色、关键字能不能上色。补语言表之后必须跑它，别凭关键字表写对了就当通过。
const fs = require('fs');
const path = require('path');
const TS_MOD =
  'C:/Users/panda/AppData/Local/OpenHarmony/Sdk/26.0.0/ets/build-tools/ets-loader/node_modules/typescript';
const ts = require(TS_MOD);
const ROOT = path.join(__dirname, '..');
const OUT = path.join(ROOT, '.workbuddy', 'hl-cjs');
fs.mkdirSync(OUT, { recursive: true });

let src = fs.readFileSync(path.join(ROOT, 'entry/src/main/ets/markdown/CodeHighlight.ets'), 'utf8')
  .replace(/\r\n/g, '\n');
// 这个文件只在 catch 的类型标注里用到 BusinessError，转译成 CJS 前把平台 import 摘掉
src = src.replace(/^import .*@kit\.BasicServicesKit.*\n/m, '');
const r = ts.transpileModule(src, {
  fileName: 'CodeHighlight.ets',
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, esModuleInterop: true, alwaysStrict: false },
});
if ((r.diagnostics || []).length > 0) {
  console.log('转译诊断：' + r.diagnostics.map((d) => ts.flattenDiagnosticMessageText(d.messageText, ' ')).join(' | '));
  process.exit(1);
}
fs.writeFileSync(path.join(OUT, 'CodeHighlight.js'), r.outputText);
const H = require(path.join(OUT, 'CodeHighlight.js'));
const { CodeHighlighter, CodeFamily, newCodeState, resolveFamily } = H;

const KW = 1, STR = 2, COMMENT = 3, TAG = 6;
function kinds(lang, line) {
  const fam = resolveFamily(lang);
  if (fam === CodeFamily.None) { return null; }
  const st = newCodeState();
  return CodeHighlighter.highlightLine(line, fam, st, lang).map((t) => t.kind + ':' + t.text);
}
function has(lang, line, kind) {
  const ks = kinds(lang, line);
  if (ks === null) { return 'family=None'; }
  return ks.some((x) => x.startsWith(kind + ':'));
}

// [语言, 注释行(可省), 代码行, 期望命中的 token 类型]
const CASES = [
  ['java', '// x', 'public class Foo {', KW],
  ['kotlin', '// x', 'fun main() {}', KW],
  ['kts', '// x', 'val a = 1', KW],
  ['swift', '// x', 'let x = 1', KW],
  ['go', '// x', 'func main() {}', KW],
  ['golang', '// x', 'import "fmt"', KW],
  ['rust', '// x', 'fn main() {}', KW],
  ['php', '// x', 'function f() {}', KW],
  ['cs', '// x', 'namespace N {}', KW],
  ['c#', '// x', 'using System;', KW],
  ['c', '// x', 'int main(void) { return 0; }', KW],
  ['cpp', '// x', 'template <typename T> class A {}', KW],
  ['hpp', '// x', 'struct S {}', KW],
  ['dart', '// x', 'void main() {}', KW],
  ['scala', '// x', 'object A extends App {}', KW],
  ['groovy', '// x', 'def x = 1', KW],
  ['objc', '// x', 'interface Foo : NSObject', KW],
  ['sol', '// x', 'contract A {}', KW],
  ['solidity', '// x', 'pragma solidity ^0.8.0;', KW],
  ['proto', '// x', 'message Foo {}', KW],
  ['thrift', '// x', 'struct Foo {}', KW],
  ['arkts', '// x', 'let a: number = 1', KW],
  ['ets', '// x', 'class A {}', KW],
  ['cangjie', '// x', 'func main() {}', KW],
  ['rb', '# x', 'def foo', KW],
  ['ruby', '# x', 'class Foo', KW],
  ['perl', '# x', 'my $x = 1;', KW],
  ['r', '# x', 'f <- function(x) x', KW],
  ['julia', '# x', 'function f(x) x end', KW],
  ['elixir', '# x', 'defmodule M do', KW],
  ['graphql', '# x', 'type Query {', KW],
  ['dockerfile', '# x', 'FROM alpine:3', KW],
  ['makefile', '# x', 'include other.mk', KW],
  ['cmake', '# x', 'set(FOO bar)', KW],
  ['py', '# x', 'def f(): pass', KW],
  ['python3', '# x', 'import os', KW],
  ['sh', '# x', 'if [ -f x ]; then echo hi; fi', KW],
  ['bash', '# x', 'for f in *; do echo $f; done', KW],
  ['powershell', '# x', 'function Get-Thing { }', KW],
  ['ps1', '# x', '$a = 1', null],
  ['bat', null, 'echo hello', KW],
  ['sql', '-- x', 'SELECT * FROM t WHERE a = 1', KW],
  ['tsql', '-- x', 'BEGIN TRANSACTION', KW],
  ['plsql', '-- x', 'DECLARE x INT;', KW],
  ['sqlite', '-- x', 'CREATE TABLE a (b INT)', KW],
  ['json', null, '{"a": "b"}', STR],
  ['jsonc', null, '{"a": 1}', STR],
  ['yaml', '# x', 'key: value', 7],
  ['yml', '# x', '- a', null],
  ['toml', '# x', 'key = 1', 7],
  ['properties', '# x', 'a.b = 1', null],
  ['env', '# x', 'A=1', null],
  ['gitignore', '# x', '*.log', null],
  ['html', '<!-- x -->', '<div class="a">t</div>', TAG],
  ['xml', '<!-- x -->', '<a b="1"/>', TAG],
  ['plist', null, '<dict><key>a</key></dict>', TAG],
  ['rss', null, '<channel><title>x</title></channel>', TAG],
  ['svg', null, '<svg width="10"/>', TAG],
  ['css', '/* x */', 'a { color: red !important; }', KW],
  ['scss', '/* x */', 'a { b: 1; }', null],
  ['sass', '/* x */', 'a\n  b: 1', null],
  ['less', '/* x */', 'a { b: 1; }', null],
  ['vue', null, '<template><div/></template>', TAG],
  ['svelte', null, '<div>x</div>', TAG],
  ['astro', null, '<div>x</div>', TAG],
  ['diff', null, '+added line', 8],
  ['udiff', null, '@@ -1,2 +1,2 @@', 10],
  ['text', null, 'plain text', null],
];

let fails = 0, checked = 0;
for (const c of CASES) {
  const lang = c[0], comment = c[1], code = c[2], want = c[3];
  const fam = resolveFamily(lang);
  if (lang === 'text') {
    if (fam !== CodeFamily.None) { console.log('  FAIL  ' + lang + ' 应当不配色（纯文本）'); fails++; }
    continue;
  }
  if (fam === CodeFamily.None) { console.log('  FAIL  ' + lang + ' 未被识别（family=None）'); fails++; continue; }
  if (want !== null) {
    checked++;
    const ok = has(lang, code, want);
    if (ok !== true) { console.log('  FAIL  ' + lang + ' 代码行没出到期望 token（' + ok + '）：' + code); fails++; }
  }
  if (comment !== null) {
    checked++;
    const ok = has(lang, comment, COMMENT);
    if (ok !== true) { console.log('  FAIL  ' + lang + ' 注释没上色（' + ok + '）：' + comment); fails++; }
  }
}
console.log(fails === 0
  ? 'HIGHLIGHT OK — ' + CASES.length + ' 个语言用例、' + checked + ' 项断言全部通过'
  : 'HIGHLIGHT FAIL — ' + fails + ' 项不通过');
process.exit(fails === 0 ? 0 : 1);
