const fs = require('fs');

let content = fs.readFileSync('C:/Users/panda/LiteMdReader/entry/src/main/ets/pages/Index.ets', 'utf-8');

// The file uses CRLF (\r\n). Match accordingly.
const oldText = [
    '    const uris: string[] = [];',
    '    const EXTENSIONS: string[] = [\'.md\', \'.markdown\', \'.txt\'];',
    '',
    '    for (let k = 0; k < records.length; k++) {',
    '      const rec = records[k];',
    '      let uri: string = \'\';',
    '',
    '      // ① 标准 UDMF FileUri 类型',
    '      try {',
    '        if (rec.getType() === \'general.file-uri\') {',
    '          const fr = rec as object as uniformDataStruct.FileUri;',
    '          uri = fr.oriUri;',
    '        }',
    '      } catch (_) { /* 忽略 */ }',
    '',
    '      // ② 若类型不匹配，尝试通用提取 oriUri',
    '      if (uri.length === 0) {',
    '        try {',
    '          const fr = rec as object as uniformDataStruct.FileUri;',
    '          if (fr.oriUri !== undefined && fr.oriUri !== null) {',
    '            uri = fr.oriUri;',
    '          }',
    '        } catch (_) { /* 忽略 */ }',
    '      }',
    '',
    '      if (uri.length === 0) {',
    '        continue;',
    '      }',
    '',
    '      // 从 URI 中提取文件名，兼容 content://、file:// 及 Windows 反斜杠路径',
    '      let fileName: string = uri.split(\'?\')[0].split(\'#\')[0];',
    '      // 统一处理正反斜杠',
    '      fileName = fileName.replace(/\\\\/g, \'/\');',
    '      fileName = fileName.split(\'/\').pop() ?? \'\';',
    '      // URI 解码（处理 %20、%2F 等编码）',
    '      try {',
    '        fileName = decodeURI(fileName);',
    '      } catch (_) { /* 不解码也不影响后缀判断 */ }',
    '',
    '      const lower: string = fileName.toLowerCase();',
    '      // 有文件名时检查扩展名；无文件名时仍尝试导入（可能是临时文件路径）',
    '      if (fileName.length === 0 || EXTENSIONS.some(ext => lower.endsWith(ext))) {',
    '        uris.push(uri);',
    '      }',
    '    }',
    '    if (uris.length === 0) {'
].join('\r\n');

const newText = [
    '    const uris: string[] = [];',
    '    for (let k = 0; k < records.length; k++) {',
    '      const rec = records[k];',
    '      let found: string = \'\';',
    '      try {',
    '        const types: string[] = rec.getTypes();',
    '        if (types.includes(uniformTypeDescriptor.UniformDataType.FILE_URI)) {',
    '          const fileUriUds = rec.getEntry(uniformTypeDescriptor.UniformDataType.FILE_URI) as uniformDataStruct.FileUri;',
    '          if (fileUriUds.oriUri !== undefined && fileUriUds.oriUri !== null && fileUriUds.oriUri.length > 0) {',
    '            found = fileUriUds.oriUri;',
    '          }',
    '        }',
    '      } catch (_) { /* 忽略 */ }',
    '      if (found.length > 0) {',
    '        uris.push(found);',
    '      }',
    '    }',
    '    if (uris.length === 0) {'
].join('\r\n');

const idx = content.indexOf(oldText);
if (idx < 0) {
    console.log('ERROR: old text not found');
    console.log('Looking for:', JSON.stringify(oldText.substring(0, 80)));
    const ui = content.indexOf('const uris: string[]');
    if (ui >= 0) console.log('Actual at', ui, ':', JSON.stringify(content.substring(ui, ui+300)));
    process.exit(1);
}

console.log('Found oldText at index:', idx);
content = content.replace(oldText, newText);

const verify = content.indexOf('const uris: string[]');
console.log('After replacement, uris at', verify, ':', JSON.stringify(content.substring(verify, verify+200)));

fs.writeFileSync('C:/Users/panda/LiteMdReader/entry/src/main/ets/pages/Index.ets', content, 'utf-8');
console.log('SUCCESS: Replacement done.');
