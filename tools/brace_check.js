// 花括号/圆括号配平自检（忽略字符串与注释中的定界符）
// 用法：node tools/brace_check.js [文件路径...]（不给路径则检查默认列表）
//
// 踩坑记录：字符串模式必须**记录起始引号**，只在遇到同种引号时才结束。
// 早期版本用 `c === "'" || c === '"'` 收尾 —— 遇到单引号串里嵌双引号的内容
// （如 '... "xxx" ...'）会提前退出字符串模式，把后面的引号当代码，
// 结果误报「不平衡」（Index.ets 就被误报过 brace:4/paren:1）。
const fs = require('fs');

function check(path) {
  const s = fs.readFileSync(path, 'utf8');
  let brace = 0, paren = 0, bracket = 0;
  let i = 0, line = 1;
  let mode = 'code';   // code | line | block | str
  let quote = '';      // str 模式下的起始引号
  while (i < s.length) {
    const c = s[i], n = s[i + 1];
    if (c === '\n') line++;
    if (mode === 'code') {
      if (c === '/' && n === '/') { mode = 'line'; i += 2; continue; }
      if (c === '/' && n === '*') { mode = 'block'; i += 2; continue; }
      if (c === "'" || c === '"' || c === '`') { mode = 'str'; quote = c; i++; continue; }
      if (c === '{') brace++;
      else if (c === '}') brace--;
      else if (c === '(') paren++;
      else if (c === ')') paren--;
      else if (c === '[') bracket++;
      else if (c === ']') bracket--;
    } else if (mode === 'line') {
      if (c === '\n') mode = 'code';
    } else if (mode === 'block') {
      if (c === '*' && n === '/') { mode = 'code'; i += 2; continue; }
    } else if (mode === 'str') {
      if (c === '\\') { i += 2; continue; }
      if (c === quote) { mode = 'code'; quote = ''; }
    }
    i++;
  }
  const ok = brace === 0 && paren === 0 && bracket === 0 && mode === 'code';
  console.log(path.split('/').pop(), '=> brace:', brace, 'paren:', paren, 'bracket:', bracket,
    mode === 'code' ? '' : ('（结束时仍在 ' + mode + ' 模式）'),
    ok ? 'OK' : ('MISMATCH near line ' + line));
}

let targets = process.argv.slice(2);
if (targets.length === 0) {
  // 不带参数时检查几个大页面（相对本脚本所在仓库根目录解析，便于他人直接跑）
  const root = require('path').resolve(__dirname, '..') + '/entry/src/main/ets/';
  targets = [
    root + 'pages/Index.ets',
    root + 'pages/Reader.ets',
    root + 'pages/Editor.ets',
    root + 'components/DocCover.ets',
    root + 'material/ImmersiveCard.ets',
    root + 'theme/GenWallpaper.ets'
  ];
}
targets.forEach(check);
