import re

with open('C:/Users/panda/LiteMdReader/entry/src/main/ets/pages/Index.ets', 'r', encoding='utf-8') as f:
    content = f.read()

# The EXACT text we want to replace (copied from the file)
old_start = '    const uris: string[] = [];\n    const EXTENSIONS: string[]'
old_end = "this.toast('请拖入 .md 或 .txt 文件到新建卡片');\n      return;"

# Find the exact position
start_idx = content.find(old_start)
end_idx = content.find(old_end, start_idx)

if start_idx < 0:
    print('ERROR: Could not find old_start')
    print('Searching near first occurrence of const uris...')
    idx = content.find('const uris: string[]')
    print('Found at:', idx)
    print(content[idx:idx+200])
    exit(1)

if end_idx < 0:
    print('ERROR: Could not find old_end')
    exit(1)

# Find end of the old_end line
end_of_line = content.find('\n', end_idx)
if end_of_line < 0:
    end_of_line = end_idx + len(old_end)

# Extract what we're replacing
old_text = content[start_idx:end_of_line + 1]

new_text = '''    const uris: string[] = [];
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
'''

content = content.replace(old_text, new_text, 1)

with open('C:/Users/panda/LiteMdReader/entry/src/main/ets/pages/Index.ets', 'w', encoding='utf-8') as f:
    f.write(content)

print('SUCCESS: Replacement completed')
print('Replaced', len(old_text), 'chars with', len(new_text), 'chars')
