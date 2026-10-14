/** 澄笺 · salt（盐图）导出渲染：逻辑与 render/salt.html 同源（勿两处改不一致）。 */
(function(){
function esc(s){
    return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  /**
   * salt 单元格 → 线框控件。
   *   [文字]   → 按钮        [x]/[ ] → 勾选框
   *   (x)/( )  → 单选        "文字"  → 输入框
   *   * 文字   → 列表项      其余    → 普通标签
   */
  function cell(txt){
    // salt 里允许夹 HTML 标签（`<b>标题` 这类）：它们不代表控件，先剥掉、只留文字
    //（用户文档里就有 `<b>Markdown Viewer`，不剥会原样显示标签本身）
    var plain=String(txt).replace(/<\/?[A-Za-z][^>]*>/g,'');
    // 同一格里可能并排多个控件（`[登录]  [注册]`）：拆出来逐个转，最多 6 个防死循环
    var parts=plain.split(/\s{2,}/);
    if(parts.length>1 && parts.length<=6){
      var multi='';
      for(var pi=0;pi<parts.length;pi++){
        if(parts[pi].replace(/^\s+|\s+$/g,'').length===0){ continue; }
        multi+=cell(parts[pi]);
      }
      return multi;
    }
    var s=plain.replace(/^\s+|\s+$/g,'');
    if(s.length===0){ return '<span class="salt-cell"></span>'; }
    var m=s.match(/^\[(.*?)\]\s*(.*)$/);
    if(m){
      var mark=m[1].trim();
      var rest=m[2].replace(/^\s+|\s+$/g,'');
      var label=rest.length? ' '+esc(rest) : '';
      if(mark==='' || mark==='x' || mark==='X' || mark===' '){
        var on=(mark==='x'||mark==='X');
        return '<span class="salt-check"><span class="salt-mark">'+(on?'✓':'')+'</span>'+label+'</span>';
      }
      return '<span class="salt-btn">'+esc(mark)+'</span>'+label;
    }
    m=s.match(/^\((.*?)\)\s*(.*)$/);
    if(m){
      var rmark=m[1].trim();
      var rrest=m[2].replace(/^\s+|\s+$/g,'');
      var rlab=rrest.length? ' '+esc(rrest) : '';
      var ron=(rmark==='x'||rmark==='X'||rmark==='o'||rmark==='O');
      return '<span class="salt-check"><span class="salt-mark radio">'+(ron?'●':'')+'</span>'+rlab+'</span>';
    }
    m=s.match(/^"(.*?)"\s*(.*)$/);
    if(m){
      var val=m[1];
      var tail=m[2].replace(/^\s+|\s+$/g,'');
      return '<span class="salt-input">'+esc(val)+'</span>'+(tail.length? ' '+esc(tail):'');
    }
    m=s.match(/^\*\s+(.*)$/);
    if(m){ return '<span class="salt-cell"><span class="salt-bullet">•</span>'+esc(m[1])+'</span>'; }
    return '<span class="salt-cell">'+esc(s)+'</span>';
  }

  function isSep(l){
    var t=l.replace(/\s+/g,'');
    return t.length>0 && /^-+$|^=+$/.test(t);
  }

  /** salt 源码 → HTML 线框 */
  function render(src){
    var raw=String(src||'').replace(/\r\n?/g,'\n').split('\n');
    var out='';
    var stack=[];       // 打开的 box：{title, nb, rows}
    var cur=null;

    function flushBox(){
      if(!cur){ return ''; }
      var html='<div class="salt-box'+(cur.nb?' nb':'')+'">';
      if(cur.title.length){ html+='<div class="salt-title">'+esc(cur.title)+'</div>'; }
      if(cur.tabs.length){
        html+='<div class="salt-tabs">';
        for(var t=0;t<cur.tabs.length;t++){
          html+='<span class="salt-tab'+(t===0?' on':'')+'">'+esc(cur.tabs[t])+'</span>';
        }
        html+='</div>';
      }
      html+=cur.body;
      html+='</div>';
      return html;
    }

    for(var k=0;k<raw.length;k++){
      var line=raw[k].replace(/\t/g,'  ');
      var t=line.replace(/^\s+|\s+$/g,'');
      if(t.length===0){ continue; }
      if(/^@start/i.test(t)||/^@end/i.test(t)){ continue; }
      if(/^\/\//.test(t)){ continue; }
      // 开 box：{  /  {+  /  {-  /  {^"标题"  /  {#
      var open=t.match(/^\{([+\-#*]?)(?:\^"([^"]*)")?/);
      if(open){
        var body=flushBox();
        if(body.length){ out+=body; }
        cur={ nb:(open[1]==='-'), title:(open[2]||''), tabs:[], body:'' };
        stack.push(cur);
        continue;
      }
      // 关 box
      if(t==='}'){
        var b2=flushBox();
        if(b2.length){ out+=b2; }
        stack.pop();
        cur=stack.length? stack[stack.length-1] : null;
        continue;
      }
      if(!cur){ cur={ nb:true, title:'', tabs:[], body:'' }; stack.push(cur); }
      // 页签：{|"A"|"B"} 形态
      var tbs=t.match(/^\{\|\s*(.*)\}$/);
      if(tbs){
        var parts=tbs[1].split('|');
        for(var q=0;q<parts.length;q++){
          var nm=parts[q].replace(/"/g,'').replace(/^\s+|\s+$/g,'');
          if(nm.length){ cur.tabs.push(nm); }
        }
        continue;
      }
      if(isSep(t)){
        cur.body+='<div class="salt-sep"></div>';
        continue;
      }
      // 一行：竖线分格
      var cells=t.split('|');
      var row='<div class="salt-row">';
      for(var c=0;c<cells.length;c++){
        row+=cell(cells[c]);
      }
      row+='</div>';
      cur.body+=row;
    }
    var last=flushBox();
    if(last.length){ out+=last; }
    return out;
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
  // **宿主入口**：renderPayload 走统一协议，转发到本模板的绘制函数 render(src)。
  // ⚠️ 上次补标准协议时只换了 renderPayload、忘了定义这个入口，
  // 真机报 "
window.__chengjianRender = window.__chengjianRender || {};
window.__chengjianRender.salt = function(src){ return render(src); };
})();
