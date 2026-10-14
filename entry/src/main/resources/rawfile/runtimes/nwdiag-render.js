/** 澄笺 · nwdiag（网络图）导出渲染：逻辑与 render/nwdiag.html 同源。 */
(function(){
function esc(s){
    return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }
  function unq(s){
    var t=String(s).replace(/^\s+|\s+$/g,'');
    if(t.length>=2 && ((t.charAt(0)==='"'&&t.charAt(t.length-1)==='"')||(t.charAt(0)==="'"&&t.charAt(t.length-1)==="'"))){ t=t.slice(1,-1); }
    return t;
  }

  /**
   * nwdiag 源码 → HTML（网络分组卡片 + 设备行）。
   * 支持两种写法：带 `nwdiag { … }` 外层（独立工具写法）与直接 `network x { … }`。
   */
  function render(src){
    var lines=String(src||'').replace(/\r\n?/g,'\n').split('\n');
    var nets=[];         // {name, attrs:[], devs:[{name, addr}]}
    var curNet=null;     // 当前网络
    for(var k=0;k<lines.length;k++){
      var t=lines[k].replace(/\t/g,'  ').replace(/^\s+|\s+$/g,'');
      if(t.length===0){ continue; }
      if(/^@(start|end)/i.test(t)){ continue; }
      if(/^\/\//.test(t) || /^#/.test(t)){ continue; }
      // 外层包裹 `nwdiag {` / `nwdiag{`
      if(/^nwdiag\s*\{?$/i.test(t)){ continue; }
      // 网络声明
      var nm=t.match(/^network\s*([^\s{]*)\s*\{?$/i);
      if(nm){
        curNet={ name:(nm[1]&&nm[1].length?nm[1]:('net'+(nets.length+1))), attrs:[], devs:[] };
        nets.push(curNet);
        continue;
      }
      // 网段地址 / 描述（网络级）
      var at=t.match(/^(address|description)\s*=\s*(.+?);?$/i);
      if(at && curNet){
        curNet.attrs.push(unq(at[2]));
        continue;
      }
      // 设备行（关键字写法）：`device "Phone"` / `server DB` / `node api1`
      // —— 不少文档这么写（用户文档里就是 `device "Phone"`），名字可带引号。
      var kw=t.match(/^(device|node|server|host|router|switch|firewall)\s+("?)([^"\s]+)\2\s*;?$/i);
      if(kw && curNet){
        curNet.devs.push({ name: kw[3], addr: '' });
        continue;
      }
      // 设备行：`web01 [address = "x", description = "y"];` / `web01;`
      var dv=t.match(/^([A-Za-z_][\w.\-]*)\s*(?:\[(.*?)\])?\s*;?$/);
      if(dv && curNet){
        if(/^[A-Za-z_]+\s*=/.test(t)){ continue; }   // 其它属性行跳过
        var attrs=dv[2]||'';
        var am=attrs.match(/address\s*=\s*"([^"]*)"/i) || attrs.match(/address\s*=\s*([^,\]]+)/i);
        curNet.devs.push({ name:dv[1], addr: am? am[1].replace(/^\s+|\s+$/g,'') : '' });
        continue;
      }
      if(t==='}' || t==='};'){ curNet=null; continue; }
      // 认不出的行：忽略（如 group 属性）
    }
    if(nets.length===0){
      return '<div class="err">nwdiag：没解析出 network 块。支持两种写法：① network dmz { address = "10.0.0.0/24" web01 [address = "10.0.0.1"]; } ② network Lan { device "Phone" device "Tablet" }</div>';
    }
    // 统计设备出现在几个网络里（>1 时标"多网络"）
    var devCount={};
    for(var a=0;a<nets.length;a++){
      for(var b=0;b<nets[a].devs.length;b++){
        var n=nets[a].devs[b].name;
        devCount[n]=(devCount[n]||0)+1;
      }
    }
    var html='';
    for(var i=0;i<nets.length;i++){
      var net=nets[i];
      html+='<div class="nw-net">';
      html+='<div class="nw-head"><span class="nw-name">'+esc(net.name)+'</span>';
      for(var m=0;m<net.attrs.length;m++){
        html+='<span class="nw-addr">'+esc(net.attrs[m])+'</span>';
      }
      html+='</div>';
      if(net.devs.length===0){
        html+='<div class="nw-empty">（该网络没有设备）</div>';
      }
      for(var d=0;d<net.devs.length;d++){
        var dev=net.devs[d];
        html+='<div class="nw-dev"><span class="nw-devname">'+esc(dev.name)+'</span>';
        if(dev.addr.length){ html+='<span class="nw-devaddr">'+esc(dev.addr)+'</span>'; }
        if(devCount[dev.name]>1){ html+='<span class="nw-shared">多网络</span>'; }
        html+='</div>';
      }
      html+='</div>';
    }
    return html;
  }

  function report(){
    try{
      var app=document.getElementById('app');
      if(window.__fit){
        var h=Math.max(app.scrollHeight, document.body.scrollHeight,
                       document.documentElement.scrollHeight, document.documentElement.offsetHeight);
        if(window.arkHost&&window.arkHost.postHeight){window.arkHost.postHeight(h);}
      } else {
        // 卡片模式：按内容高度钉死整页并禁滚动（宿主据此裁切快照）
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

  // **宿主入口**（与 salt/ditaa 同款协议；改协议时入口与转发必须成对改）
  
window.__chengjianRender = window.__chengjianRender || {};
window.__chengjianRender.nwdiag = function(src){ return render(src); };
})();
