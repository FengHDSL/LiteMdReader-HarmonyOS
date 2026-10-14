/** 澄笺 · ditaa 导出渲染：逻辑与 render/ditaa.html 同源（导出固定浅色底）。 */
(function(){
function esc(s){
    return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  /** 从一段文本里挑出颜色码 cXXX（ditaa 约定：字母 = 色调，首位为填充） */
  function colorOf(text){
    var m=String(text).match(/\bc([A-Z]{2,4})\b/);
    if(!m){ return null; }
    var code=m[1];
    var fill=HUES[code.charAt(0)]||HUES.W;
    var stroke=STROKES[code.charAt(0)]||STROKES.W;
    return { code:code, fill:fill, stroke:stroke };
  }

  /**
   * ASCII 图元解析：找出所有「+ 为四角、- 为上下边、| 为左右边」的矩形。
   * ditaa 的图就是这些方框 + 框内文字 + 框外文字。
   */
  function findBoxes(lines){
    var rows=lines.length;
    var cols=0;
    for(var r=0;r<rows;r++){ cols=Math.max(cols, lines[r].length); }
    var grid=[];
    for(var r2=0;r2<rows;r2++){
      var row=lines[r2];
      var arr=[];
      for(var c2=0;c2<cols;c2++){ arr.push(c2<row.length? row.charAt(c2) : ' '); }
      grid.push(arr);
    }
    var at=function(r,c){
      if(r<0||c<0||r>=rows||c>=cols){ return ' '; }
      return grid[r][c];
    };
    var boxes=[];
    var used=[];
    for(var r3=0;r3<rows;r3++){ used.push(new Array(cols).fill(false)); }
    for(var r4=0;r4<rows;r4++){
      for(var c4=0;c4<cols;c4++){
        if(at(r4,c4)!=='+'){ continue; }
        // 向右找同行的另一个 +，中间必须是 - 或 +
        var c5=c4+1;
        var okH=true;
        var right=-1;
        while(c5<cols){
          var ch=at(r4,c5);
          if(ch==='+'){ right=c5; break; }
          if(ch!=='-'){ okH=false; break; }
          c5++;
        }
        if(!okH||right<0||right-c4<2){ continue; }
        // 向下找同列的下边
        var r5=r4+1;
        var bottom=-1;
        while(r5<rows){
          var chL=at(r5,c4);
          if(chL==='+' && at(r5,right)==='+'){ bottom=r5; break; }
          if(chL!=='|' && chL!=='+'){ break; }
          r5++;
        }
        if(bottom<0||bottom-r4<2){ continue; }
        // 底边也要是 - 或 +
        var okBottom=true;
        for(var c6=c4+1;c6<right;c6++){
          var cb=at(bottom,c6);
          if(cb!=='-'&&cb!=='+'){ okBottom=false; break; }
        }
        if(!okBottom){ continue; }
        // 记录（避免重复：已被更大框覆盖的跳过）
        var dup=false;
        for(var b=0;b<boxes.length;b++){
          var q=boxes[b];
          if(q.r1<=r4&&q.r2>=bottom&&q.c1<=c4&&q.c2>=right){ dup=true; break; }
        }
        if(dup){ continue; }
        boxes.push({ r1:r4, c1:c4, r2:bottom, c2:right });
      }
    }
    return { boxes:boxes, grid:grid, rows:rows, cols:cols };
  }

  /** ASCII 图 → SVG */
  function toSvg(src, dark){
    var lines=String(src||'').replace(/\r\n?/g,'\n').split('\n');
    while(lines.length>0 && lines[lines.length-1].replace(/\s+/g,'').length===0){ lines.pop(); }
    while(lines.length>0 && lines[0].replace(/\s+/g,'').length===0){ lines.shift(); }
    if(lines.length===0){ return '<div class="err">ditaa 内容为空</div>'; }
    var info=findBoxes(lines);
    var grid=info.grid, rows=info.rows;
    var fs=13, lh=17, pad=14;
    var W=info.cols*fs*0.62+pad*2;
    var H=rows*lh+pad*2;
    var fg=dark? '#ECEFF4' : '#1B1F27';
    var svg=['<svg xmlns="http://www.w3.org/2000/svg" width="'+Math.ceil(W)+'" height="'+Math.ceil(H)+'" viewBox="0 0 '+Math.ceil(W)+' '+Math.ceil(H)+'">'];
    svg.push('<style>text{font:13px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre;}</style>');

    var consumed=[];
    for(var r=0;r<rows;r++){ consumed.push(new Array(info.cols).fill(false)); }

    // 先画方框（大在前，小的后画覆盖）
    var sorted=info.boxes.slice().sort(function(a,b){
      return (b.r2-b.r1)*(b.c2-b.c1)-(a.r2-a.r1)*(a.c2-a.c1);
    });
    var textsInside=[];
    for(var b=0;b<sorted.length;b++){
      var q=sorted[b];
      // 收集框内文字行与颜色码
      var innerLines=[];
      var allText='';
      for(var rr=q.r1+1;rr<q.r2;rr++){
        var buf='';
        for(var cc=q.c1+1;cc<q.c2;cc++){
          buf+=grid[rr][cc];
          consumed[rr][cc]=true;
        }
        allText+=buf+'\n';
        innerLines.push(buf.replace(/\s+$/,''));
      }
      var col=colorOf(allText);
      var x=(q.c1)*fs*0.62+pad, y=q.r1*lh+pad;
      var w=(q.c2-q.c1+1)*fs*0.62, h=(q.r2-q.r1+1)*lh;
      svg.push('<rect x="'+x.toFixed(1)+'" y="'+y.toFixed(1)+'" width="'+w.toFixed(1)
        +'" height="'+h.toFixed(1)+'" rx="4" fill="'+(col?col.fill:'none')
        +'" stroke="'+(col?col.stroke:'#8a8a8a')+'" stroke-width="1.2"/>');
      // 框内文字（去掉颜色码本身）
      for(var il=0;il<innerLines.length;il++){
        var tx=innerLines[il].replace(/\bc[A-Z]{2,4}\b/g,'')
          .replace(/^[|+\-\s]+/,'').replace(/[|+\-\s]+$/,'');
        if(tx.replace(/\s+/g,'').length===0){ continue; }
        var ly=(q.r1+1+il)*lh+pad-4;
        svg.push('<text x="'+(x+6).toFixed(1)+'" y="'+ly.toFixed(1)+'" fill="'+fg+'">'+esc(tx)+'</text>');
      }
      for(var rq=q.r1;rq<=q.r2;rq++){
        for(var cq=q.c1;cq<=q.c2;cq++){ consumed[rq][cq]=true; }
      }
    }

    // 再画框外文字（逐行、跳过已消费列）
    for(var r2=0;r2<rows;r2++){
      var out='';
      var started=false;
      for(var c2=0;c2<info.cols;c2++){
        if(consumed[r2][c2]){ out+=' '; continue; }
        out+=grid[r2][c2];
      }
      var text=out.replace(/\bc[A-Z]{2,4}\b/g,'').replace(/\s+$/,'');
      // 纯框图字符（+ - | 与空格）组成的行不当作正文：那是没被识别成方框的边框
      if(text.replace(/[\s+\-|]/g,'').length===0){ continue; }
      svg.push('<text x="'+pad+'" y="'+((r2+1)*lh+pad-4).toFixed(1)+'" fill="'+fg+'">'+esc(text)+'</text>');
    }

    svg.push('</svg>');
    return svg.join('');
  }

  function report(){
    try{
      var app=document.getElementById('app');
      if(window.__fit){
        // 撑满模式（放大 / 导出抓图）：整页高度按滚动高度反映（抓全图）
        var h=Math.max(app.scrollHeight, document.body.scrollHeight,
                       document.documentElement.scrollHeight, document.documentElement.offsetHeight);
        if(window.arkHost&&window.arkHost.postHeight){window.arkHost.postHeight(h);}
      } else {
        // 卡片模式：高度 = 内容实际布局高度（app.offsetHeight）；整页钉死该高度、禁止滚动。
        // ⚠️ 内容未就绪（app 还空着）时不 pin、不上报小高度——否则宿主立刻截图会裁成一条。
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
  // **宿主入口**：renderPayload 走统一协议，转发到本模板的绘制函数 toSvg(src, dark)。
  // ⚠️ 与 salt.html 同款事故：换协议必须连入口一起补，否则真机报 "
window.__chengjianRender = window.__chengjianRender || {};
window.__chengjianRender.ditaa = function(src){ return toSvg(src, false); };
})();
