/**
 * 澄笺 · 离线渲染模板生成器
 * =========================
 * 把 rawfile/render/lib 下的开源库（KaTeX / Mermaid / ECharts / abcjs / viz.js /
 * Raphael+flowchart / Lute）内联进各自的 HTML 模板，输出到 rawfile/render/。
 * ArkUI 的 Web 组件加载这些模板，DiagramWeb 通过 runJavaScript 注入源码、
 * javaScriptProxy(arkHost.postHeight) 回传渲染高度。
 * 运行：node tools/gen-render-templates.js
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const LIB = path.join(ROOT, 'entry/src/main/resources/rawfile/render/lib');
const OUT = path.join(ROOT, 'entry/src/main/resources/rawfile/render');

function read(f) { return fs.readFileSync(path.join(LIB, f), 'utf8'); }
function write(f, s) { fs.writeFileSync(path.join(OUT, f), s); console.log(f, (s.length / 1024).toFixed(0) + 'KB'); }

const BASE_CSS = `
  html,body{margin:0;padding:0;background:transparent;}
  body.dark{color:#ECEFF4;}
  #app{padding:8px 10px;box-sizing:border-box;overflow:hidden;}
  #app svg,#app canvas{max-width:100%;}
  .err{color:#D93B3B;font:13px sans-serif;white-space:pre-wrap;}
`;

const HOST = `
  function report(){
    try{
      var app=document.getElementById('app');
      var h=Math.max(app.scrollHeight, document.body.scrollHeight);
      if(window.arkHost&&window.arkHost.postHeight){window.arkHost.postHeight(h);}
    }catch(e){}
  }
  window.renderPayload=function(json){
    try{
      var o=(typeof json==='string')?JSON.parse(json):json;
      if(o.dark){document.body.classList.add('dark');}
      if(o.vw&&o.vw>0){document.body.style.width=o.vw+'px';document.body.style.margin='0';}
      window.__fit=!!o.fit;
      window.__render(o.src, o.dark, !!o.fit);
      setTimeout(report,60); setTimeout(report,300);
    }catch(e){
      document.getElementById('app').innerHTML='<div class="err">'+e.message+'</div>';
      report();
    }
  };
  if(typeof ResizeObserver!=='undefined'){new ResizeObserver(function(){report();}).observe(document.getElementById('app'));}
  window.addEventListener('load',report);
`;

function page(libs, bodyHtml) {
  return '<!DOCTYPE html>\n<html><head>\n<meta charset="utf-8">\n' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">\n' +
    '<style>' + BASE_CSS + '</style>\n' + libs + '\n</head>\n<body>\n' +
    '<div id="app"></div>\n' + bodyHtml + '\n<script>' + HOST + '</script>\n</body></html>\n';
}

// ── KaTeX（块级公式） ──
write('katex.html', page(
  '<style>' + read('katex.min.css') + '</style>\n<script>' + read('katex.min.js') + '</script>',
  `<script>
  window.__render=function(src,dark){
    var app=document.getElementById('app');
    app.innerHTML='';
    katex.render(src,app,{displayMode:true,throwOnError:false,output:'html'});
  };
  </script>`)
);

// ── Mermaid（流程图/时序图/甘特图，真实 mermaid） ──
write('mermaid.html', page(
  '<script>' + read('mermaid.min.js') + '</script>',
  `<script>
  var seq=0;
  window.__render=function(src,dark){
    mermaid.initialize({startOnLoad:false,securityLevel:'loose',theme:dark?'dark':'neutral',flowchart:{useMaxWidth:false},sequence:{useMaxWidth:false},gantt:{useMaxWidth:false}});
    var app=document.getElementById('app');
    app.innerHTML='';
    mermaid.render('mmd'+(seq++),src).then(function(r){
      app.innerHTML=r.svg;
      var sv=app.querySelector('svg');
      if(sv){ if(window.__fit){sv.style.width='100%';sv.style.maxWidth='none';} else {sv.style.maxWidth='100%';} sv.style.height='auto'; }
      report();
    }).catch(function(e){
      app.innerHTML='<div class="err">'+(e&&e.message?e.message:e)+'</div>';report();
    });
  };
  </script>`)
);

// ── ECharts（echarts JSON，真实 echarts） ──
write('echarts.html', page(
  '<script>' + read('echarts.min.js') + '</script>',
  `<script>
  window.__render=function(src,dark){
    var app=document.getElementById('app');
    app.style.height='280px';
    var fix=function(x){return x.replace(/([{,]\\s*)([A-Za-z_][A-Za-z0-9_]*)\\s*:/g,'$1"$2":');};
    var opt;
    try{
      opt=(typeof src==='string')?JSON.parse(fix(src)):src;
    }catch(e1){
      opt=JSON.parse(fix(src));
    }
    var chart=echarts.init(app,dark?'dark':null,{renderer:'canvas'});
    chart.setOption(opt);
    setTimeout(function(){chart.resize();report();},80);
  };
  </script>`)
);

// ── abcjs（五线谱） ──
write('abc.html', page(
  '<script>' + read('abcjs-basic-min.js') + '</script>',
  `<script>
  window.__render=function(src,dark){
    var app=document.getElementById('app');
    app.innerHTML='';
    ABCJS.renderAbc(app,src,{responsive:'resize',foreground:dark?'#ECEFF4':'#1B1F27'});
    report();
  };
  </script>`)
);

// ── Graphviz（viz.js） ──
write('graphviz.html', page(
  '<script>' + read('viz.js') + '</script>',
  `<script>
  window.__render=function(src,dark){
    var app=document.getElementById('app');
    try{
      app.innerHTML=Viz(src,{format:'svg',engine:'dot'});
      var sv=app.querySelector('svg'); if(sv){sv.style.maxWidth='100%';}
      report();
    }catch(e){
      app.innerHTML='<div class="err">'+e.message+'</div>';report();
    }
  };
  </script>`)
);

// ── flowchart.js（经典 st=>start 语法，依赖 Raphael） ──
write('flowchart.html', page(
  '<script>' + read('raphael.min.js') + '</script>\n<script>' + read('flowchart.min.js') + '</script>',
  `<script>
  window.__render=function(src,dark){
    var app=document.getElementById('app');
    app.innerHTML='';
    var chart=flowchart.parse(src);
    chart.drawSVG('app',{});
    report();
  };
  </script>`)
);

// ── Markmap（脑图，彩色分支交互样式） ──
write('markmap.html', page(
  '<script>' + read('d3.min.js') + '</script>\n<script>' + read('markmap-lib.min.js') + '</script>\n<script>' + read('markmap-view.min.js') + '</script>',
  `<script>
  window.__render=function(src,dark,fit){
    var app=document.getElementById('app');
    app.innerHTML='<svg id="mmsvg" style="width:100%;height:100%"></svg>';
    app.style.height=fit?'80vh':'440px';
    var root=new markmap.Transformer().transform(src).root;
    markmap.Markmap.create(document.getElementById('mmsvg'),{autoFit:true,duration:200,initialExpandLevel:-1},root);
    setTimeout(report,100); setTimeout(report,400);
  };
  </script>`)
);

// ── Lute（Markdown → HTML，供导出使用） ──
write('lute.html', page(
  '<script>' + read('lute.min.js') + '</script>',
  `<script>
  var luteInstance=Lute.New();
  window.renderLute=function(json){
    var o=(typeof json==='string')?JSON.parse(json):json;
    return luteInstance.MarkdownStr('chengjian', o.md);
  };
  </script>`)
);

console.log('render templates generated.');
