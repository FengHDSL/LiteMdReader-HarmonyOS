const fs = require('fs');

let content = fs.readFileSync('C:/Users/panda/LiteMdReader/entry/src/main/ets/pages/Index.ets', 'utf-8');

// Debug: print all occurrences of the toast text
let idx = content.indexOf("请拖入 .md 或 .txt 文件到新建卡片");
console.log('Toast text found at:', idx);
if (idx >= 0) {
    // Print 200 chars before and after
    console.log('BEFORE:', JSON.stringify(content.substring(idx-100, idx)));
    console.log('AFTER:', JSON.stringify(content.substring(idx, idx+100)));
}
