// Splice tools/fx-block.html into the ```html fence of chengjian.md.
// Pipeline: edit the block -> `node tools/splice-fx.js` -> verify-fx.js + gen-fx-preview.js.
// Uses plain concatenation only: String.replace treats `$` in the replacement as an
// escape (`$$` -> `$`), which once left a stray `$$` inside the doc block.
const fs = require('fs');
const path = require('path');

const doc = path.join(__dirname, '../entry/src/main/resources/rawfile/chengjian.md');
const blockPath = path.join(__dirname, 'fx-block.html');

const md = fs.readFileSync(doc, 'utf8');
const nl = md.includes('\r\n') ? '\r\n' : '\n';
let block = fs.readFileSync(blockPath, 'utf8').replace(/\r\n/g, '\n');
if (!block.endsWith('\n')) { block += '\n'; }
block = block.split('\n').join(nl);

const open = '```html' + nl + '<style>' + nl + '  .fx {';
const start = md.indexOf(open);
if (start < 0) { throw new Error('fx fence not found — has the block been renamed in the doc?'); }
const bodyStart = start + ('```html' + nl).length;
const end = md.indexOf(nl + '```', bodyStart);
if (end < 0) { throw new Error('closing fence not found'); }
const removed = md.slice(bodyStart, end);
if (!removed.includes('fxCanvas')) { throw new Error('refusing to replace a block that is not the fx demo'); }

fs.writeFileSync(doc, md.slice(0, bodyStart) + block + md.slice(end));
console.log('spliced ' + removed.length + ' -> ' + block.length + ' chars');
