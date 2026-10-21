// 只读核验：找出**没走 L10n 的中文字面量**（切语言时永远停在中文）。
// 用法：node tools/find-raw-cn.js [目录过滤关键字，可省略]
//
// 口径：逐字符扫描（不是逐行），找到每个含汉字的字符串字面量，
// 再看它前面的**上一个非空白 token**：若是 `L10n.t(`、`this.s(`、`.s(`，视为已包裹；
// 其余（含作为 @Builder 参数传入的情况，如 `this.exportRow('打印', …)`）一律报出。
// 跳过整行注释与块注释；跳过字典/nl 资源目录。
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets');
const CJK = /[\u4e00-\u9fff]/;
const SKIP_DIR = /(^|[\\/])(l10n|resources)([\\/]|$)/;

function walk(dir, out) {
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name);
    const st = fs.statSync(p);
    if (st.isDirectory()) {
      walk(p, out);
    } else if (name.endsWith('.ets')) {
      out.push(p);
    }
  }
}

/** 把注释替换成等长空格，保持下标与行号不变。 */
function stripComments(src) {
  let out = '';
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    if (c === '/' && src[i + 1] === '/') {
      while (i < n && src[i] !== '\n') { out += ' '; i++; }
    } else if (c === '/' && src[i + 1] === '*') {
      out += '  ';
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) {
        out += src[i] === '\n' ? '\n' : ' ';
        i++;
      }
      if (i < n) { out += '  '; i += 2; }
    } else {
      out += c;
      i++;
    }
  }
  return out;
}

const files = [];
walk(ROOT, files);
const hits = [];
const wrapped = [];
for (const f of files) {
  if (SKIP_DIR.test(f)) {
    continue;
  }
  const src = stripComments(fs.readFileSync(f, 'utf8'));
  const lineStarts = [0];
  for (let i = 0; i < src.length; i++) {
    if (src[i] === '\n') { lineStarts.push(i + 1); }
  }
  const lineOf = (pos) => {
    let lo = 0;
    let hi = lineStarts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (lineStarts[mid] <= pos) { lo = mid; } else { hi = mid - 1; }
    }
    return lo + 1;
  };
  let i = 0;
  while (i < src.length) {
    const q = src[i];
    if (q !== '\'' && q !== '"' && q !== '`') { i++; continue; }
    // 跳过模板字符串里的 ${} 简单处理：整段当一个字面量
    let j = i + 1;
    while (j < src.length) {
      if (src[j] === '\\') { j += 2; continue; }
      if (src[j] === q) { break; }
      j++;
    }
    const literal = src.slice(i + 1, j);
    if (CJK.test(literal)) {
      // 往前找上一个非空白 token 的结尾
      let k = i - 1;
      while (k >= 0 && /\s/.test(src[k])) { k--; }
      const before = src.slice(Math.max(0, k - 12), k + 1);
      const isWrapped = /\bL10n\.t\($/.test(before) || /\bthis\.s\($/.test(before) || /\.s\($/.test(before);
      const row = path.relative(ROOT, f) + ':' + lineOf(i) + '  ' + (q + literal + q).slice(0, 70);
      if (isWrapped) { wrapped.push(row); } else { hits.push(row); }
    }
    i = j + 1;
  }
}
for (const h of hits) {
  console.log(h);
}
console.log('未包裹 ' + hits.length + ' 处；已包裹 ' + wrapped.length + ' 处（含不校验的模板串）');
