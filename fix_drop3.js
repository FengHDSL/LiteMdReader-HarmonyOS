const fs = require('fs');

let content = fs.readFileSync('C:/Users/panda/LiteMdReader/entry/src/main/ets/pages/Index.ets', 'utf-8');

// Find the section to replace
const marker1 = '    const uris: string[] = [];\n    for (let k = 0; k < records.length; k++) {';
const marker2 = '    if (uris.length === 0) {';

const startIdx = content.indexOf(marker1);
const endIdx = content.indexOf(marker2, startIdx);

if (startIdx < 0) {
    console.log('ERROR: marker1 not found');
    const idx = content.indexOf('const uris: string[]');
    if (idx >= 0) console.log('Found uris at idx:', idx, '\n' + content.substring(idx, idx+200));
    process.exit(1);
}
if (endIdx < 0) {
    console.log('ERROR: marker2 not found');
    process.exit(1);
}

// Find the end of the for loop block (the line before 'if (uris.length === 0)')
// Go back from endIdx until we find '}' on its own line (closing the for loop)
const blockEnd = content.lastIndexOf('\n    }\n', endIdx - 1);
if (blockEnd < 0) {
    console.log('ERROR: could not find block end');
    process.exit(1);
}

const oldText = content.substring(startIdx, endIdx); // includes up to the 'if' line

const newText = `    const uris: string[] = [];
    for (let k = 0; k < records.length; k++) {
      const rec = records[k];
      let found: string = '';
      try {
        const types: string[] = rec.getTypes();
        if (types.includes(uniformTypeDescriptor.UniformDataType.FILE_URI)) {
          const fileUriUds = rec.getEntry(uniformTypeDescriptor.UniformDataType.FILE_URI) as uniformDataStruct.FileUri;
          if (fileUriUds.oriUri !== undefined && fileUriUds.oriUri !== null && fileUriUds.oriUri.length > 0) {
            found = fileUriUds.oriUri;
          }
        }
      } catch (_) { /* 忽略 */ }
      if (found.length > 0) {
        uris.push(found);
      }
    }
    if (uris.length === 0) {`;

// Verify
const verifyIdx = content.indexOf(oldText);
if (verifyIdx < 0) {
    console.log('ERROR: oldText not found');
    console.log('oldText:', JSON.stringify(oldText.substring(0, 100)));
    console.log('Searching...');
    const idx = content.indexOf('const uris: string[]');
    console.log('Actual at idx:', idx, ':', JSON.stringify(content.substring(idx, idx+150)));
    process.exit(1);
}

content = content.replace(oldText, newText);
fs.writeFileSync('C:/Users/panda/LiteMdReader/entry/src/main/ets/pages/Index.ets', content, 'utf-8');
console.log('SUCCESS: Replacement done. Replaced ' + oldText.length + ' chars.');
