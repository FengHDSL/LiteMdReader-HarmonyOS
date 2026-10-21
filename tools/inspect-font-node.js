// 只读核验：对指定文件里每个**尚未套 HwFont.sx**（或 bump）的 .fontSize( / .fontWeight( 节点，
// 判断它属于界面文字（该挂）还是正文 / 代码 / 公式 / 图标（故意不挂）。
// 用法：node tools/inspect-font-node.js <file.ets> [fontSize|fontWeight]
const fs = require('fs');
const file = process.argv[2];
const attr = process.argv[3] === 'fontWeight' || process.argv[3] === 'lineHeight'
  ? process.argv[3] : 'fontSize';
const wrap = attr === 'fontSize' || attr === 'lineHeight' ? 'HwFont.sx(' : 'HwFont.bump(';
const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);

function owner(start) {
  // 从属性行往上找节点起始（Text(...) / Button(...) / SymbolGlyph(...) 等）
  for (let i = start; i >= 0; i--) {
    const m = lines[i].match(/^\s*([A-Za-z_][\w.]*|this\.[A-Za-z_]\w*)\s*\(/);
    if (m) {
      return { name: m[1], line: i + 1 };
    }
    // 撞到更外层属性 / 收尾大括号就停：说明这是 builder 传参而不是直接节点
    if (/^\s*[{})]/.test(lines[i])) {
      break;
    }
  }
  return { name: '?', line: -1 };
}

function chain(idx) {
  // 从属性行往下取同一节点（缩进相同或更深）的属性行，直到缩进回退
  const ind = lines[idx].match(/^\s*/)[0].length;
  let out = [];
  for (let i = idx + 1; i < lines.length; i++) {
    const l = lines[i];
    if (l.trim().length === 0) { continue; }
    const cur = l.match(/^\s*/)[0].length;
    if (cur < ind) { break; }
    if (cur === ind && !/^\s*\./.test(l)) { break; }
    out.push(l);
    if (out.length > 14) { break; }
  }
  return out.join('\n');
}

const rows = [];
for (let i = 0; i < lines.length; i++) {
  const l = lines[i];
  if (!new RegExp('^\\s*\\.' + attr + '\\(').test(l) || l.indexOf(wrap) >= 0) { continue; }
  const o = owner(i);
  const up = lines.slice(Math.max(0, i - 3), i).join('\n');
  const down = chain(i);
  const win = up + '\n' + lines[i] + '\n' + down;
  let kind = 'chrome?';
  if (/SymbolGlyph/.test(o.name)) { kind = 'skip:icon'; }
  else if (/bodyFamily|bodySize|this\.fontSize|mono|Monospace|codeFont|pieceSize/.test(win)) { kind = 'skip:content'; }
  else if (/resolve\(this\.uiFontKey\)/.test(win)) { kind = 'HOOK'; }
  rows.push({ line: i + 1, node: o.name, kind, size: l.trim().slice(0, 52) });
}
const order = { 'HOOK': 0, 'chrome?': 1, 'skip:content': 2, 'skip:icon': 3 };
rows.sort((a, b) => order[a.kind] - order[b.kind] || a.line - b.line);
for (const r of rows) {
  console.log((r.kind + '        ').slice(0, 14) + String(r.line).padStart(6) + '  ' + (r.node + '      ').slice(0, 14) + r.size);
}
console.log('合计 ' + rows.length + ' 处未套 ' + wrap + '：HOOK ' +
  rows.filter(r => r.kind === 'HOOK').length + '、待判 ' + rows.filter(r => r.kind === 'chrome?').length +
  '、跳过 ' + rows.filter(r => r.kind !== 'HOOK' && r.kind !== 'chrome?').length);
