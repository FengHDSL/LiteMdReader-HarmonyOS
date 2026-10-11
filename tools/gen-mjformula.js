// 生成 rawfile/render/mjformula.html（行内公式 PNG 生成模板）：
//   = MathJax tex-svg（内联，mathjax@3.2.2——3.x 线最终版；v4 的离线化需专项适配，
//     见 2026-10-10 日志：按需异步加载扩展 + SRE speech-worker 依赖，已评估暂缓）
//     + mjformula-page.js（页面逻辑）
// 源库归档在 tools/runtimes/tex-svg-full.js（mathjax@3.2.2，勿随意升级——
// 升级需重跑 tools/latex-check/mj-probe.html 桌面验证）。
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const LIB = path.join(__dirname, 'runtimes', 'tex-svg-full.js');
const PAGE = path.join(__dirname, 'mjformula-page.js');
const OUT = path.join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'render', 'mjformula.html');

const lib = fs.readFileSync(LIB, 'utf8').split('</script>').join('<\\/script>');
const page = fs.readFileSync(PAGE, 'utf8').split('</script>').join('<\\/script>');

const head = '<!DOCTYPE html>\n'
  + '<html>\n<head>\n<meta charset="utf-8">\n'
  // 固定布局视口：本页只作"排版引擎"，避免 1×1 宿主尺寸把 device-width 视口带偏
  + '<meta name="viewport" content="width=640, user-scalable=no">\n'
  + '<style>\n'
  + '  html,body{margin:0;padding:0;background:transparent;}\n'
  + '  #mhold{position:absolute;left:-9999px;top:0;}\n'
  + '</style>\n</head>\n<body>\n'
  + '<div id="mhold"></div>\n';

const html = head
  + '<script>\n' + lib + '\n</script>\n'
  + '<script>\n' + page + '\n</script>\n'
  + '</body>\n</html>\n';

fs.writeFileSync(OUT, html);
console.log('written:', OUT, 'bytes=', html.length);
