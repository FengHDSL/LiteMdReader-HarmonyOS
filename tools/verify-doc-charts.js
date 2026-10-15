// Extract every chart fence from the builtin docs and check it is renderable.
// Stage 1 (this file, Node): JSON syntax for wavedrom/echarts, plus a manifest.
// Stage 2 (browser): feed the manifest to each render template — see verify-doc-charts-browser.
const fs = require('fs');
const path = require('path');

const RAW = path.join(__dirname, '../entry/src/main/resources/rawfile');
const DOCS = ['chengjian.md', 'README.md'];
const JSON_LANGS = ['wavedrom', 'echarts', 'chart'];
const fenceRe = /^```([A-Za-z0-9_-]*)[ \t]*$/;

// Same repair the templates apply (keys only, never values).
const fix = s => s.replace(/([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:/g, '$1"$2":');

const problems = [];
const manifest = {};
for (const doc of DOCS) {
  const lines = fs.readFileSync(path.join(RAW, doc), 'utf8').replace(/\r\n?/g, '\n').split('\n');
  let i = 0;
  while (i < lines.length) {
    const m = fenceRe.exec(lines[i].trim());
    if (!m) { i++; continue; }
    const lang = m[1].toLowerCase();
    const openLen = (lines[i].trim().match(/^[`~]+/) || [''])[0].length;
    const body = [];
    let j = i + 1;
    while (j < lines.length) {
      const t = lines[j].trim();
      const mm = fenceRe.exec(t);
      if (mm && (t.match(/^[`~]+/) || [''])[0].length >= openLen && t[0] === lines[i].trim()[0]) break;
      body.push(lines[j]); j++;
    }
    if (j >= lines.length) { problems.push(doc + ': unclosed fence opened at line ' + (i + 1)); i = j; continue; }
    if (lang) {
      (manifest[lang] = manifest[lang] || []).push({ doc, line: i + 1, src: body.join('\n') });
    }
    if (JSON_LANGS.includes(lang)) {
      const src = body.join('\n');
      try { JSON.parse(src); }
      catch (e1) {
        try { JSON.parse(fix(src)); problems.push(doc + ':' + (i + 1) + ' [' + lang +
          '] 键名缺引号（模板会自动补，但建议写全）'); }
        catch (e2) { problems.push(doc + ':' + (i + 1) + ' [' + lang + '] JSON 无效: ' + e2.message); }
      }
      if (lang === 'wavedrom') {
        try {
          const o = JSON.parse(fix(src));
          if (!(o.signal || o.assign || o.reg)) problems.push(doc + ':' + (i + 1) + ' [wavedrom] 顶层缺 signal/assign/reg');
        } catch (e) { /* already reported */ }
      }
      // chart.js 的颜色字符串**直接进 canvas**（CSS 语义 #RRGGBBAA），
      // 写成应用内部的 #AARRGGBB 会变颜色（#FF2F63E8 = 粉红，不是蓝）——
      // 用户实测"数据可视化卡片颜色不对"，示例里就踩过这个。
      if (lang === 'chart') {
        const bad = (src.match(/#[0-9a-fA-F]{8}(?!['"]?[0-9a-fA-F])/g) || []);
        if (bad.length) {
          problems.push(doc + ':' + (i + 1) + ' [chart] 8 位十六进制色值 ' + bad.join(', ') +
            '（canvas 按 CSS 的 #RRGGBBAA 解析，应用的 #AARRGGBB 会变颜色）');
        }
      }
    }
    i = j + 1;
  }
}

fs.writeFileSync(path.join(__dirname, '../.workbuddy/doc-charts.json'), JSON.stringify(manifest));
const counts = Object.keys(manifest).map(k => k + '=' + manifest[k].length).join(' ');
console.log('blocks found:', counts);
console.log(problems.length ? '\nPROBLEMS:\n  - ' + problems.join('\n  - ') : 'ALL DOC CHART BLOCKS PARSE');
process.exit(problems.length ? 1 : 0);
