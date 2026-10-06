const fs = require('fs');

let content = fs.readFileSync('C:/Users/panda/LiteMdReader/entry/src/main/ets/pages/Index.ets', 'utf-8');

// Find the section to replace
const marker1 = '    const uris: string[] = [];\n    const EXTENSIONS: string[]';
const marker2 = "this.toast('请拖入 .md 或 .txt 文件到新建卡片');\n      return;";

const startIdx = content.indexOf(marker1);
const endIdx = content.indexOf(marker2, startIdx);

if (startIdx < 0) {
    console.log('ERROR: marker1 not found');
    const idx = content.indexOf('const uris: string[]');
    if (idx >= 0) console.log('Found at idx:', idx, '\n' + content.substring(idx, idx+300));
    process.exit(1);
}
if (endIdx < 0) {
    console.log('ERROR: marker2 not found');
    process.exit(1);
}

const endOfLine = content.indexOf('\n', endIdx);
const oldText = content.substring(startIdx, endOfLine + 1);

const newText = `    const uris: string[] = [];
    for (let k = 0; k < records.length; k++) {
      const rec = records[k];
      let found: string = '';
      try {
        const fr = rec as object as uniformDataStruct.FileUri;
        if (typeof fr.oriUri === 'string' && fr.oriUri.length > 0) {
          found = fr.oriUri;
        }
      } catch (_) { /* 忽略 */ }
      if (found.length > 0) {
        uris.push(found);
      }
    }
    if (uris.length === 0) {
      this.toast('请拖入 .md 或 .txt 文件到新建卡片');
      return;
    }
`;

// Verify oldText exists
const verifyIdx = content.indexOf(oldText);
if (verifyIdx < 0) {
    console.log('ERROR: oldText not found in content');
    console.log('oldText start:', JSON.stringify(oldText.substring(0, 80)));
    console.log('oldText end:', JSON.stringify(oldText.substring(oldText.length-80)));
    process.exit(1);
}

content = content.replace(oldText, newText);
fs.writeFileSync('C:/Users/panda/LiteMdReader/entry/src/main/ets/pages/Index.ets', content, 'utf-8');
console.log('SUCCESS: Replacement done. Replaced ' + oldText.length + ' chars.');
