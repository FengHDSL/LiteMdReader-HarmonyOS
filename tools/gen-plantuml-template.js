'use strict';
// 生成 entry/src/main/resources/rawfile/render/plantuml.html（PlantUML 离线内核模板）
//
// 引擎：npm `@plantuml/core`（MIT）—— 官方 PlantUML 用 TeaVM 编译成 JS，
// **不需要 Java、不需要服务端、不需要联网**。2026-10-14 用用户文档里的 20 个
// PlantUML 图种逐个实测（.workbuddy/build-puml2-probe.js 量的 viewBox/节点数/填充色）：
//   · 内核原生出图 14 个：时序 / 用例 / 类 / 活动 / 组件 / 部署 / 状态 / 脑图 /
//     WBS / 甘特 / JSON / YAML / Archimate / ER
//   · 内核**没有渲染器** 6 个：时间线、网络图(nwdiag)、盐图(salt)、Ditaa、
//     数学公式(math)、文件树(files) —— 这六个由解析层分流到别的路径，
//     **不会**进到这个模板（分流规则见 MdParser.pumlRouteOf，
//     判定探针见 tools/verify-syntax-coverage.js §6.21）。
//
// 打进这一页的四个文件（都取自 npm 包原文，放在 .workbuddy/puml/package/）：
//   plantuml.js   3.9MB 引擎（结尾 `export{C as render,D as renderToString}` → 改挂全局）
//   viz-global.js 1.45MB Graphviz 布局（README 要求先于引擎加载；实测换了它，
//                 用例/类/组件/部署/状态/Archimate/ER 的排版才是官方 dot 的样子）
//   themes.js     326KB → globalThis.PLANTUML_THEMES，`!theme xxx` 才有主题可取
//   openiconic.js  51KB → window.PLANTUML_OPENICONIC，`<&star/>` 这类图标才有矢量形状
//   emoji.js 1.88MB **不打包**：`<:name:>` 表情精灵会画成空框，能力矩阵里如实标注。
//
// 用法：
//   node tools/gen-plantuml-template.js            （从 .workbuddy/puml/package 重建）
//   node tools/upgrade-libs.js plantuml            （取 $UP 里的新包文件 → 重建 → 对账）
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const PKG = process.argv[2] || path.join(ROOT, '.workbuddy/puml/package');
const SRC = path.join(PKG, 'plantuml.js');
const OUT = path.join(ROOT, 'entry/src/main/resources/rawfile/render/plantuml.html');

let lib = fs.readFileSync(SRC, 'utf8');
// 内联进 <script> 的正文里出现 </script 会提前结束标签，一律转义掉（实测四个包都没有，
// 但这是版本升级后的保险，转义后的字符串在 JS 里语义不变）
const safe = (s) => s.replace(/<\/(script)/gi, '<\\/$1');
const themes = safe(fs.readFileSync(path.join(PKG, 'themes.js'), 'utf8'));
const openiconic = safe(fs.readFileSync(path.join(PKG, 'openiconic.js'), 'utf8'));
const viz = safe(fs.readFileSync(path.join(PKG, 'viz-global.js'), 'utf8'));
lib = safe(lib);
const m = /export\s*\{([^}]*)\};?\s*$/.exec(lib);
if (m === null) {
  console.error('找不到结尾的 export 行，plantuml.js 结构变了，先核对再改模板');
  process.exit(1);
}
const pairs = m[1].split(',').map((x) => x.trim()).filter((x) => x.length > 0).map((x) => x.split(/\s+as\s+/));
const globals = pairs.map((p) => 'globalThis.' + (p[1] === 'render' ? 'plantumlRender' : 'plantumlRenderToString')
  + ' = ' + p[0] + ';').join(' ');
lib = lib.slice(0, m.index) + globals + String.fromCharCode(10);

const page = `<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,minimum-scale=0.05,maximum-scale=10,user-scalable=yes">
<style>
  html,body{margin:0;padding:0;background:transparent;}
  body.dark{color:#ECEFF4;}
  #app{padding:8px 10px;box-sizing:border-box;overflow:hidden;}
  #app svg{max-width:100%;}
  .err{color:#D93B3B;font:13px sans-serif;white-space:pre-wrap;}
</style>
</head>
<body>
<div id="app"></div>
<!-- ⚠️ 这一页由 tools/gen-plantuml-template.js 从 npm @plantuml/core 原文生成，
     升级走 tools/upgrade-libs.js 的 plantuml()，别手改。
     viz-global = Viz.js 3.24.0（随 @plantuml/core 一起发；
     与 runtimes/viz-global.js（3.31.0，给 dot 围栏与导出用）是两份不同拷贝，互不替代）。 -->
<script>${viz}</script>
<script>${themes}</script>
<script>${openiconic}</script>
<!-- ⚠️ **必须是普通脚本，不能用 type="module"**：包里唯一的 ESM 语法只有结尾那行
     export{…}（上面已改写成挂全局），除此之外没有任何 import / import.meta / 顶层 await
     （全文只有两处 "import" 字样，都在字符串常量里："Cannot import"、"!import"）。
     用 module 的代价实测到了：这是**全部模板里唯一一页 module**，真机上 PlantUML 一整族
     （用例/活动/组件/部署/mindmap/WBS/甘特/JSON/YAML/Archimate/ER）画不出、退回显示源码，
     而 mermaid / graphviz / abc / salt / nwdiag 这些普通脚本页都正常。
     外面再套一层 IIFE：3.9MB 的顶层 let/const 不少，直接进全局有跟宿主脚本撞名的风险
     （撞了就是 SyntaxError，整页白屏），套起来后它们全是函数作用域，只往外挂两个函数。
     "use strict" 保住 module 本来的严格语义。 -->
<script>"use strict";(function () {
${lib}
})();</script>
<script>
  // 引擎现在是同步执行（不再是 module 的"解析完才跑"），全局早已就位；
  // 这里仍留一轮轮询，兜住极端情况下脚本被推迟执行的场景
  function whenReady(fn) {
    if (window.plantumlRenderToString) { fn(); return; }
    var tries = 0;
    var t = setInterval(function () {
      tries++;
      if (window.plantumlRenderToString) { clearInterval(t); fn(); }
      else if (tries > 400) { clearInterval(t); fail('PlantUML 引擎未就绪'); }
    }, 25);
  }
  function friendly(msg) {
    var s = String(msg);
    if (s === 'UNSUPPORTED') { return '这个 PlantUML 图种离线内核没有渲染器（盐图 / nwdiag / ditaa 一类）'; }
    if (/Unsupported diagram type/i.test(s)) { return '这个 PlantUML 图种离线内核没有渲染器'; }
    if (/java\\.lang\\.|RuntimeException|teavm/i.test(s)) { return '内核渲染失败：' + s.replace(/^java[\\w.]*: ?/, ''); }
    return s;
  }
  function fail(msg) {
    var app = document.getElementById('app');
    app.innerHTML = '<div class="err">' + friendly(msg).replace(/[&<>]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]; }) + '</div>';
    report();
  }
  window.__render = function (src, dark) {
    var app = document.getElementById('app');
    app.innerHTML = '';
    whenReady(function () {
      var done = false;
      plantumlRenderToString(src.split(String.fromCharCode(10)), function (out) {
        if (done) { return; } done = true;
        var svg = typeof out === 'string' ? out : (out && out.svg ? out.svg : String(out));
        if (!/<svg/i.test(svg)) { fail('没有画出图（引擎返回空内容）'); return; }
        // 内核把「这个图种本构建不支持」也画成一张 SVG 错误卡。正常路径下这类图种
        // 在解析层就被分流走了（MdParser.pumlRouteOf），走到这里说明是**新图种**或
        // 源码本身有错 —— 错误卡留着，但换成中文提示，别让读者看 Java 异常。
        if (/Diagram not supported by this release|is not recognized|Unsupported diagram/i.test(svg)) {
          fail('UNSUPPORTED');
          return;
        }
        app.innerHTML = svg;
        var sv = app.querySelector('svg');
        if (sv) {
          sv.style.maxWidth = '100%';
          sv.style.height = 'auto';
          sv.removeAttribute('width');
        }
        report();
      }, function (e) {
        if (done) { return; } done = true;
        fail((e && e.message) ? e.message : e);
      }, dark ? { dark: true } : undefined);
      setTimeout(function () { if (!done) { done = true; fail('渲染超时'); } }, 15000);
    });
  };
  function report(){
    try{
      var app=document.getElementById('app');
      if(window.__fit){
        var h=Math.max(app.scrollHeight, document.body.scrollHeight,
          document.documentElement.scrollHeight, document.documentElement.offsetHeight);
        if(window.arkHost&&window.arkHost.postHeight){window.arkHost.postHeight(h);}
      } else {
        if(app.offsetHeight<=60){return;}
        var h2=Math.max(app.offsetHeight,40);
        document.documentElement.style.height=h2+'px';
        document.body.style.height=h2+'px';
        document.documentElement.style.overflow='hidden';
        document.body.style.overflow='hidden';
        if(window.arkHost&&window.arkHost.postHeight){window.arkHost.postHeight(h2);}
      }
    }catch(e){}
  }
  window.renderPayload=function(json){
    try{
      var o=(typeof json==='string')?JSON.parse(json):json;
      if(o.dark){document.body.classList.add('dark');}else{document.body.classList.remove('dark');}
      if(o.vw&&o.vw>0){document.body.style.width=o.vw+'px';document.body.style.margin='0';}
      if(o.bg){document.documentElement.style.background=o.bg;document.body.style.background=o.bg;}
      window.__fit=!!o.fit;
      window.__render(o.src, o.dark);
      setTimeout(report,120); setTimeout(report,600);
    }catch(e){
      document.getElementById('app').innerHTML='<div class="err">'+e.message+'</div>';
      report();
    }
  };
  window.__exportBg=function(on){
    try{
      var els=[document.documentElement,document.body];
      var app=document.getElementById('app');
      if(app){els.push(app);}
      for(var i=0;i<els.length;i++){var e=els[i];if(!e){continue;}
        if(on){ if(e.__prevBg===undefined){e.__prevBg=e.style.background||'';e.__prevBgc=e.style.backgroundColor||'';}
          e.style.background='#ff00ff'; e.style.backgroundColor='#ff00ff'; }
        else if(e.__prevBg!==undefined){ e.style.background=e.__prevBg; e.style.backgroundColor=e.__prevBgc; }}
    }catch(e){}
  };
  window.refit=function(){ report(); };
  if(typeof ResizeObserver!=='undefined'){new ResizeObserver(function(){report();}).observe(document.getElementById('app'));}
  window.addEventListener('load',report);
</script>
</body></html>`;
fs.writeFileSync(OUT, page);
console.log('模板 -> ' + OUT + '  ' + (page.length / 1048576).toFixed(2) + 'MB');

// ── 导出用运行时：内核的**单文件普通脚本**版 ──
// 用户拍板"导出必带 PlantUML 内核"：导出的 HTML 不带内核就画不出那 11 类
// （用例 / 活动 / 组件 / 部署 / mindmap / WBS / 甘特 / JSON / YAML / Archimate / ER），
// 只能靠阅读页烘好的快照 PNG（没滚到、清了缓存、引擎关着 → 就退成代码块）。
// 四个包拼成一个文件、按依赖顺序排列（viz 必须最先，README 要求），
// 引擎那段单独套一层 IIFE 并把 "use strict" 放在**函数内**：
// 放在文件头会把 viz / themes / openiconic 这三个没为严格模式写过的外层包一起拽进严格语义。
const kernel = '/*! PlantUML 离线内核（@plantuml/core 1.2026.8，MIT）\n'
  + '    = viz-global 3.24.0 + themes.js + openiconic.js + 引擎（结尾 export 改挂全局）。\n'
  + '    由 tools/gen-plantuml-template.js 与 render/plantuml.html 同源生成，勿手改。\n'
  + '    导出 HTML 内联用：window.plantumlRenderToString(lines, onSuccess, onError, {dark}) */\n'
  + viz.trim() + '\n'
  + themes.trim() + '\n'
  + openiconic.trim() + '\n'
  + '(function () { "use strict";\n' + lib + '\n})();\n';
const RUN_OUT = path.join(ROOT, 'entry/src/main/resources/rawfile/runtimes/plantuml-kernel.js');
const TOOL_OUT = path.join(ROOT, 'tools/runtimes/plantuml-kernel.js');
fs.writeFileSync(RUN_OUT, kernel);
fs.writeFileSync(TOOL_OUT, kernel);
console.log('运行时 -> ' + RUN_OUT + '  ' + (kernel.length / 1048576).toFixed(2) + 'MB（镜像一份到 tools/runtimes）');
