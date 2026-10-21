// 只读核验：每个 struct 里若引用了 this.uiFontKey / this.cardFont / this.uiFontScale /
// this.uiFontWeightDelta，就必须在该 struct 内声明这个成员。
// （组件文件本地只判定界符，漏声明成员只有用户构建才会炸。）
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets');
const bad = [];
let checked = 0;

function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { walk(p); continue; }
    if (!e.name.endsWith('.ets')) { continue; }
    const src = fs.readFileSync(p, 'utf8');
    if (src.indexOf('uiFontKey') < 0 && src.indexOf('cardFont') < 0
      && src.indexOf('uiFontScale') < 0 && src.indexOf('uiFontWeightDelta') < 0) {
      continue;
    }
    const lines = src.split(/\r?\n/);
    // 切 struct 块：以 `struct X {` 开头，按花括号配平找结尾
    for (let i = 0; i < lines.length; i++) {
      const m = /^\s*(?:export\s+)?struct\s+(\w+)/.exec(lines[i]);
      if (m === null) { continue; }
      let depth = 0;
      let started = false;
      let j = i;
      const body = [];
      for (; j < lines.length; j++) {
        depth += (lines[j].match(/\{/g) || []).length - (lines[j].match(/\}/g) || []).length;
        if (lines[j].indexOf('{') >= 0) { started = true; }
        if (started) {
          const t = lines[j].trim();
          // 注释里举的例子（"各页写 this.uiFontScale" 这种）不算引用
          if (!(t.startsWith('//') || t.startsWith('*') || t.startsWith('/*'))) {
            body.push(lines[j]);
          }
        }
        if (started && depth === 0) { break; }
      }
      const text = body.join('\n');
      for (const member of ['uiFontKey', 'cardFont', 'uiFontScale', 'uiFontWeightDelta']) {
        const used = new RegExp('this\\.' + member, '').test(text);
        if (!used) { continue; }
        checked++;
        // 声明可能夹着第二个装饰器（@StorageLink(...) @Watch('x') \n uiFontKey: string = ''），
        // 所以只认「成员名 : 类型」这一处，不去猜装饰器的排布
        const declared = new RegExp(member + '\\s*:\\s*(string|number|boolean)\\s*(=|;)').test(text);
        if (!declared) {
          bad.push(path.relative(path.join(__dirname, '..'), p) + '  struct ' + m[1]
            + '  第 ' + (i + 1) + ' 行：引用 this.' + member + ' 但没有声明该成员');
        }
      }
      i = j;
    }
  }
}

walk(ROOT);
console.log('扫描 this.uiFontKey / this.cardFont 引用 ' + checked + ' 处');
if (bad.length === 0) {
  console.log('UI-FONT MEMBERS OK — 每个引用处都声明了成员');
} else {
  for (const b of bad) { console.log('MISSING  ' + b); }
  process.exitCode = 1;
}
