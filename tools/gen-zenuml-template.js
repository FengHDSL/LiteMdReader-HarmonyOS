'use strict';
// 生成 entry/src/main/resources/rawfile/render/zenuml.html（ZenUML 模板）
//
// 做法：**以 render/mermaid.html 为底**，在引擎段之后插入
//   ① @mermaid-js/mermaid-zenuml 1.0.1 的 UMD（3.14MB，自带 React + @zenuml/core）
//   ② 一行注册 `mermaid.registerExternalDiagrams([globalThis['mermaid-zenuml']])`
// 宿主逻辑（renderPayload / postHeight / __exportBg / refit）**整份沿用 mermaid.html**，
// 不另写一遍 —— 两条渲染链各自演化正是"库资源分支漂移"那类坑的来源。
//
// 为什么单独成页而不是塞进 mermaid.html：zenuml 插件自带一份 React，
// 3.14MB 让所有 mermaid 卡片一起背不值；只有 `zenuml` 首行的块才加载这一页。
//
// ⚠️ mermaid.html 的宿主逻辑改过之后要重跑本脚本，否则 zenuml.html 停在旧宿主上
//    （verify-chart-templates.js 里有一条对齐检查钉住这一点）。
//
// 用法：node tools/gen-zenuml-template.js [插件min.js路径]
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const BASE = path.join(ROOT, 'entry/src/main/resources/rawfile/render/mermaid.html');
const PLUGIN = process.argv[2]
  || path.join(ROOT, '.workbuddy/zenuml/package/dist/mermaid-zenuml.min.js');
const OUT = path.join(ROOT, 'entry/src/main/resources/rawfile/render/zenuml.html');

const doc = fs.readFileSync(BASE, 'utf8');
let zu = fs.readFileSync(PLUGIN, 'utf8');
// 内联正文里出现 </script 会提前结束标签（实测这份没有，留着当升级保险）
zu = zu.replace(/<\/(script)/gi, '<\\/$1');
if (!/globalThis\["mermaid-zenuml"\]/.test(zu.slice(-600))) {
  console.error('插件结尾没有挂 globalThis["mermaid-zenuml"]，UMD 形态变了，先核对再拼模板');
  process.exit(1);
}

const openTag = '<script>';
const first = doc.indexOf(openTag);
if (first < 0) {
  console.error('mermaid.html 里找不到引擎段 <script>');
  process.exit(1);
}
const engineEnd = doc.indexOf('</script>', first);
if (engineEnd < 0) {
  console.error('引擎段没有收尾');
  process.exit(1);
}

const insert = '</script>\n'
  + '<!-- ZenUML 插件：@mermaid-js/mermaid-zenuml 1.0.1（MIT），自带 React 与 @zenuml/core。\n'
  + '     由 tools/gen-zenuml-template.js 从 render/mermaid.html 派生，别手改这一页。 -->\n'
  + '<script>' + zu + '</script>\n'
  + '<script>\n'
  + '  // 注册进 mermaid 的外部图种通道（实测 11.17.2 有 registerExternalDiagrams）。\n'
  + '  // 注册失败不拦渲染：其它 mermaid 图种照画，zenuml 块会报 "No diagram type detected"。\n'
  + '  try {\n'
  + '    if (globalThis.mermaid && globalThis["mermaid-zenuml"]) {\n'
  + '      globalThis.mermaid.registerExternalDiagrams([globalThis["mermaid-zenuml"]]);\n'
  + '    }\n'
  + '  } catch (e) { console.error("zenuml register failed", e); }\n'
  + '</script>\n';

const page = doc.slice(0, engineEnd) + insert + doc.slice(engineEnd + '</script>'.length + 1);
fs.writeFileSync(OUT, page);
console.log('模板 -> ' + OUT + '  ' + (page.length / 1048576).toFixed(2) + 'MB'
  + '（底 ' + (doc.length / 1048576).toFixed(2) + 'MB + 插件 ' + (zu.length / 1048576).toFixed(2) + 'MB）');
