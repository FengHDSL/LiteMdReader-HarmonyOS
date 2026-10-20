/* 澄笺官网交互：能力标签页 / 首屏示意界面 / 阅读界面示意 / 截图画廊 / 本地演示 */
(function () {
  'use strict';

  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };
  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined) n.textContent = text;
    return n;
  }
  function uid() { return 'n' + Math.random().toString(36).slice(2, 8); }

  /* ── 导航 ─────────────────────────────────────────── */
  var navToggle = $('#navToggle'), navLinks = $('#navLinks');
  if (navToggle && navLinks) {
    navToggle.addEventListener('click', function () {
      var open = navLinks.classList.toggle('open');
      navToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
      navToggle.setAttribute('aria-label', open ? '收起导航菜单' : '展开导航菜单');
    });
    navLinks.addEventListener('click', function (e) {
      if (e.target.tagName === 'A') {
        navLinks.classList.remove('open');
        navToggle.setAttribute('aria-expanded', 'false');
      }
    });
  }

  /* ── 滚动入场 ─────────────────────────────────────── */
  var rvs = $$('.rv');
  if (reduceMotion || !('IntersectionObserver' in window)) {
    rvs.forEach(function (n) { n.classList.add('in'); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) { en.target.classList.add('in'); io.unobserve(en.target); }
      });
    }, { rootMargin: '0px 0px -12% 0px', threshold: 0.05 });
    rvs.forEach(function (n) { io.observe(n); });
  }

  /* ── 能力标签页 ───────────────────────────────────── */
  var tabs = $$('[role=tab]');
  var panels = $$('[role=tabpanel]');
  function selectTab(idx, focus) {
    tabs.forEach(function (t, i) {
      t.setAttribute('aria-selected', i === idx ? 'true' : 'false');
      t.tabIndex = i === idx ? 0 : -1;
    });
    panels.forEach(function (p, i) { p.hidden = i !== idx; });
    if (focus) tabs[idx].focus();
  }
  tabs.forEach(function (t, i) {
    t.addEventListener('click', function () { selectTab(i, false); });
    t.addEventListener('keydown', function (e) {
      var d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
      if (d) { e.preventDefault(); selectTab((i + d + tabs.length) % tabs.length, true); }
      else if (e.key === 'Home') { e.preventDefault(); selectTab(0, true); }
      else if (e.key === 'End') { e.preventDefault(); selectTab(tabs.length - 1, true); }
    });
  });

  /* ── 卡片化渲染器：演示用简化版，只构造文本节点，不拼接用户输入 ── */
  var INLINE_RE = /(`[^`]+`)|(\*\*[\s\S]+?\*\*)|(~~[\s\S]+?~~)|(\*[\s\S]+?\*)|(\$[^$]+\$)|(\[[^\]]+\]\(([^)\s]*)\))/g;
  var SAFE_URL = /^(https?:|mailto:)/i;

  function inlineInto(str, host) {
    var re = new RegExp(INLINE_RE.source, 'g');
    var last = 0, m;
    while ((m = re.exec(str))) {
      if (m.index > last) host.appendChild(document.createTextNode(str.slice(last, m.index)));
      var tok = m[0];
      if (tok[0] === '`') host.appendChild(el('code', 'inline', tok.slice(1, -1)));
      else if (tok.indexOf('**') === 0) { var b = el('strong'); inlineInto(tok.slice(2, -2), b); host.appendChild(b); }
      else if (tok.indexOf('~~') === 0) host.appendChild(el('del', '', tok.slice(2, -2)));
      else if (tok[0] === '$') { var f = el('span', 'formula-inline'); f.appendChild(document.createTextNode(' ' + tok.slice(1, -1) + ' ')); host.appendChild(f); }
      else if (tok[0] === '[') {
        var label = tok.slice(1, tok.indexOf(']')), url = m[7] || '';
        if (SAFE_URL.test(url)) {
          var a = el('a', 'ext', label); a.href = url; a.target = '_blank'; a.rel = 'noopener noreferrer'; host.appendChild(a);
        } else {
          host.appendChild(el('span', 'nolink', label + '（演示不打开外链）'));
        }
      } else { var em = el('em'); inlineInto(tok.slice(1, -1), em); host.appendChild(em); }
      last = m.index + tok.length;
    }
    if (last < str.length) host.appendChild(document.createTextNode(str.slice(last)));
  }

  var KW = /^(const|let|var|function|return|if|else|for|while|import|export|from|class|new|await|async|interface|type|public|private|static|null|true|false|def|graph|flowchart|subgraph|style|end)$/;
  function codeInto(src, host, lang) {
    var re = /(\/\/[^\n]*$)|('[^'\n]*'|"[^"\n]*")|(\b\d+(?:\.\d+)?\b)|(\b[A-Za-z_][A-Za-z0-9_]*\b)/gm;
    var last = 0, m;
    while ((m = re.exec(src))) {
      if (m.index > last) host.appendChild(document.createTextNode(src.slice(last, m.index)));
      var t = m[0], cls = m[1] ? 'com' : m[2] ? 'str' : m[3] ? 'num' : (KW.test(t) ? 'kw' : null);
      host.appendChild(cls ? el('span', cls, t) : document.createTextNode(t));
      last = m.index + t.length;
    }
    if (last < src.length) host.appendChild(document.createTextNode(src.slice(last)));
  }

  function chartFromLines(lines) {
    var nodes = [];
    lines.forEach(function (ln) {
      var re = /([A-Za-z_][\w]*)\s*[\[(]\s*([^)\]]+?)\s*[\])]/g, m;
      while ((m = re.exec(ln))) {
        if (nodes.indexOf(m[2]) < 0 && m[2].length < 30) nodes.push(m[2]);
      }
    });
    if (!nodes.length) return null;
    var rowH = 44, w = 210, svgNS = 'http://www.w3.org/2000/svg';
    var svg = document.createElementNS(svgNS, 'svg');
    svg.setAttribute('viewBox', '0 0 ' + w + ' ' + (nodes.length * rowH + 8));
    svg.setAttribute('width', '100%');
    svg.setAttribute('height', String(nodes.length * rowH + 8));
    svg.setAttribute('role', 'img');
    svg.setAttribute('aria-label', '流程图示意：' + nodes.join('，')
      .replace(/\s+/g, ' '));
    nodes.forEach(function (label, i) {
      var y = i * rowH + 6;
      var rect = document.createElementNS(svgNS, 'rect');
      rect.setAttribute('x', '12'); rect.setAttribute('y', String(y));
      rect.setAttribute('width', String(w - 24)); rect.setAttribute('height', '28');
      rect.setAttribute('rx', '7');
      rect.setAttribute('fill', 'transparent');
      rect.setAttribute('stroke', 'currentColor');
      rect.setAttribute('stroke-opacity', '.45');
      svg.appendChild(rect);
      var tx = document.createElementNS(svgNS, 'text');
      tx.setAttribute('x', String(w / 2)); tx.setAttribute('y', String(y + 19));
      tx.setAttribute('text-anchor', 'middle');
      tx.setAttribute('font-size', '12'); tx.setAttribute('fill', 'currentColor');
      tx.textContent = label;
      svg.appendChild(tx);
      if (i < nodes.length - 1) {
        var arrow = document.createElementNS(svgNS, 'path');
        arrow.setAttribute('d', 'M' + (w / 2) + ' ' + (y + 28) + ' v' + 14);
        arrow.setAttribute('stroke', 'currentColor');
        arrow.setAttribute('stroke-opacity', '.45');
        arrow.setAttribute('fill', 'none');
        svg.appendChild(arrow);
        var head = document.createElementNS(svgNS, 'path');
        head.setAttribute('d', 'M' + (w / 2 - 3) + ' ' + (y + 40) + ' l3 4 l3 -4 z');
        head.setAttribute('fill', 'currentColor');
        head.setAttribute('fill-opacity', '.45');
        svg.appendChild(head);
      }
    });
    return svg;
  }

  function renderMarkdown(md, root) {
    var lines = md.replace(/\r\n/g, '\n').split('\n');
    var i = 0, blocks = 0, headings = [];
    root.textContent = '';
    function add(node) { root.appendChild(node); blocks++; }

    while (i < lines.length) {
      var line = lines[i];
      if (!line.trim()) { i++; continue; }

      var fence = line.match(/^\s*```\s*([A-Za-z0-9+#-]*)\s*$/);
      if (fence) {
        var lang = (fence[1] || 'text').toLowerCase(), body = [];
        i++;
        while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) { body.push(lines[i]); i++; }
        i++;
        if (lang === 'mermaid' || lang === 'flowchart' || lang === 'graph') {
          var fig = el('div', 'fig card');
          var fh = el('div', 'fh');
          fh.appendChild(el('b', '', '图表'));
          fh.appendChild(el('span', '', 'mermaid · 随包离线渲染'));
          fig.appendChild(fh);
          var g = chartFromLines(body);
          if (g) { fig.appendChild(g); }
          var note = el('div', 'fh');
          note.style.marginTop = '8px';
          note.appendChild(el('span', '', '示意：真机由离线引擎绘制，可全屏放大与缩放'));
          fig.appendChild(note);
          add(fig);
        } else {
          var wrap = el('div', 'card');
          var head = el('div', 'code-head');
          head.appendChild(el('span', 'lang', lang));
          var raw = body.join('\n');
          var btn = el('button', '', '复制');
          btn.type = 'button';
          btn.addEventListener('click', function () {
            var done = function () { btn.textContent = '已复制'; btn.setAttribute('data-copied', '1'); setTimeout(function () { btn.textContent = '复制'; btn.removeAttribute('data-copied'); }, 1600); };
            if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(raw).then(done, done);
            else done();
          });
          head.appendChild(btn);
          wrap.appendChild(head);
          var pre = el('pre');
          var code = el('code');
          codeInto(raw, code, lang);
          pre.appendChild(code);
          wrap.appendChild(pre);
          add(wrap);
        }
        continue;
      }

      if (/^\s*\$\$(.+?)\$\$\s*$/.test(line)) {
        var fig1 = el('div', 'fig card');
        var fh1 = el('div', 'fh');
        fh1.appendChild(el('b', '', '公式'));
        fh1.appendChild(el('span', '', 'KaTeX · 随包离线渲染'));
        fig1.appendChild(fh1);
        fig1.appendChild(el('div', 'formula', line.replace(/^\s*\$\$(.+?)\$\$\s*$/, '$1').trim()));
        add(fig1);
        i++;
        continue;
      }

      if (/^\s*\$\$\s*$/.test(line)) {
        var fbody = [];
        i++;
        while (i < lines.length && !/^\s*\$\$\s*$/.test(lines[i])) { fbody.push(lines[i]); i++; }
        i++;
        var ffig = el('div', 'fig card');
        var ffh = el('div', 'fh');
        ffh.appendChild(el('b', '', '公式'));
        ffh.appendChild(el('span', '', 'KaTeX · 随包离线渲染'));
        ffig.appendChild(ffh);
        var fbox = el('div', 'formula', fbody.join(' ').trim());
        ffig.appendChild(fbox);
        add(ffig);
        continue;
      }

      var h = line.match(/^(#{1,6})\s+(.*)$/);
      if (h) {
        var lvl = Math.min(4, Math.max(2, h[1].length === 1 ? 2 : h[1].length));
        var node = el('h' + lvl, '', h[2]);
        node.id = uid();
        headings.push({ lvl: lvl, text: h[2], node: node });
        add(node);
        i++;
        continue;
      }

      if (/^\s*([-*_])\s*(\1\s*){2,}$/.test(line)) { add(el('hr')); i++; continue; }

      var call = line.match(/^\s*>\s*\[!(\w+)\]\s*(.*)$/);
      if (call) {
        var kind = call[1].toUpperCase(), cbody = [call[2]];
        i++;
        while (i < lines.length && /^\s*>\s?/.test(lines[i]) && !/^\s*>\s*\[!\w+\]/.test(lines[i])) {
          cbody.push(lines[i].replace(/^\s*>\s?/, '')); i++;
        }
        var card = el('div', 'callout card ' + kind.toLowerCase());
        card.appendChild(el('span', 'badge', kind));
        var ctext = el('div');
        inlineInto(cbody.filter(function (s) { return s.trim(); }).join(' '), ctext);
        card.appendChild(ctext);
        add(card);
        continue;
      }

      if (/^\s*>/.test(line)) {
        var qb = [];
        while (i < lines.length && /^\s*>/.test(lines[i])) { qb.push(lines[i].replace(/^\s*>\s?/, '')); i++; }
        var q = el('blockquote');
        inlineInto(qb.join(' '), q);
        add(q);
        continue;
      }

      if (line.indexOf('|') >= 0 && i + 1 < lines.length && /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(lines[i + 1])) {
        var rows = [];
        while (i < lines.length && lines[i].indexOf('|') >= 0) { rows.push(lines[i]); i++; }
        var cells = function (r) {
          return r.replace(/^\s*\|/, '').replace(/\|\s*$/, '').split('|').map(function (c) { return c.trim(); });
        };
        var table = el('table');
        var thead = el('thead');
        var trh = el('tr');
        cells(rows[0]).forEach(function (c) { trh.appendChild(el('th', '', c)); });
        thead.appendChild(trh);
        table.appendChild(thead);
        var tb = el('tbody');
        rows.slice(2).forEach(function (r) {
          var tr = el('tr');
          cells(r).forEach(function (c) { var td = el('td'); inlineInto(c, td); tr.appendChild(td); });
          tb.appendChild(tr);
        });
        table.appendChild(tb);
        var tc = el('div', 'card tbl');
        tc.appendChild(table);
        add(tc);
        continue;
      }

      if (/^\s*\[\^[^\]]+\]:/.test(line)) {
        var fn = el('div', 'foot');
        inlineInto(line.replace(/^\s*(\[[^\]]+\]):\s*/, '$1 '), fn);
        add(fn);
        i++;
        continue;
      }

      var lm = line.match(/^\s*([-*+]|\d+\.)\s+/);
      if (lm) {
        var ordered = /\d/.test(lm[1]);
        var list = el(ordered ? 'ol' : 'ul');
        while (i < lines.length && /^\s*([-*+]|\d+\.)\s+/.test(lines[i])) {
          var item = lines[i].replace(/^\s*([-*+]|\d+\.)\s+/, '');
          var task = item.match(/^\[( |x|X)\]\s+(.*)$/);
          var li = task ? el('li', 'task') : el('li');
          if (task) {
            li.setAttribute('data-done', task[1] === ' ' ? '0' : '1');
            li.appendChild(el('i'));
            inlineInto(task[2], li);
          } else {
            inlineInto(item, li);
          }
          list.appendChild(li);
          i++;
          while (i < lines.length && /^\s{2,}\S/.test(lines[i]) && !/^\s*([-*+]|\d+\.)\s+/.test(lines[i])) {
            list.lastChild.appendChild(document.createTextNode(' ' + lines[i].trim()));
            i++;
          }
        }
        add(list);
        continue;
      }

      var para = [];
      while (i < lines.length && lines[i].trim() && !/^(#{1,6}\s|>|\s*```|\s*([-*+]|\d+\.)\s|\s*\$\$|\|)/.test(lines[i])
        && !/^\s*([-*_])\s*(\1\s*){2,}$/.test(lines[i])) {
        para.push(lines[i]); i++;
      }
      var p = el('p');
      inlineInto(para.join(' '), p);
      add(p);
    }
    return { blocks: blocks, headings: headings };
  }

  /* ── 首屏示意界面：AI 助手 ───────────────────────── */
  var EXAMPLES = [
    {
      topic: '词汇速记手册',
      ask: '把《英语核心词汇笔记》整理成一篇带表格的速记手册，存进书架。',
      att: '上下文：《英语核心词汇笔记》.md（本机沙箱读取）',
      refs: [['协议', '生成文档'], ['落盘', '书架 · 英语四级核心词汇速记手册']],
      done: '已生成文档并存入书架 · 全程只连接你配置的接口'
    },
    {
      topic: '图表修正',
      ask: '这段 mermaid 流程图渲染不出来，帮我改成能出图的写法，顺便讲讲错在哪。',
      att: '附件：粘贴的代码块（1.2 KB）',
      refs: [['回复', '代码块 + 说明'], ['浮层', '图表可全屏放大']],
      done: '回复完成 · 代码块与图表沿用阅读页同一套卡片'
    },
    {
      topic: '两篇合并',
      ask: '把附件里两篇笔记合并成一篇，按主题重排并加一个目录。',
      att: '附件：2 个文件 · 812 KB（按块读取，自动分批发送）',
      refs: [['附件', '精读示范.md'], ['附件', '生词本.md'], ['输出', '合并稿']],
      done: '合并稿已就绪 · 对话记录只存在本机'
    }
  ];
  var PIPE = ['读取输入', '深度思考', '组织回复', '写入结果'];
  var exBar = $('#exBar'), exTopics = $('#exTopics'), exAsk = $('#exAsk'),
    exSteps = $('#exSteps'), exRefs = $('#exRefs'), exDone = $('#exDone'), exDoneText = $('#exDoneText');
  var timers = [];

  function clearTimers() { timers.forEach(clearTimeout); timers = []; }

  function runExample(idx) {
    clearTimers();
    var ex = EXAMPLES[idx];
    $$('#exBar .ex', exBar).forEach(function (b, i) { b.setAttribute('aria-pressed', i === idx ? 'true' : 'false'); });
    $$('li button', exTopics).forEach(function (b, i) { b.setAttribute('aria-pressed', i === idx ? 'true' : 'false'); });

    exAsk.textContent = '';
    exAsk.appendChild(document.createTextNode(ex.ask));
    exAsk.appendChild(el('span', 'att', ex.att));

    exSteps.textContent = '';
    var marks = [
      ['附件与上下文', ex.att.replace(/^[^：]*：/, '')],
      ['思考强度：高（可调）', '多协议接口由你在「设置 → 助手设置」里配置'],
      ['卡片化排版', ex.refs.map(function (r) { return r[1]; }).join(' · ')],
      ['完成', ex.done]
    ];
    var lis = marks.map(function (m, i) {
      var li = el('li');
      li.appendChild(el('span', 'mark'));
      var box = el('div');
      box.appendChild(el('b', '', PIPE[i]));
      box.appendChild(el('em', '', m[1]));
      li.appendChild(box);
      exSteps.appendChild(li);
      return li;
    });
    exRefs.textContent = '';
    exRefs.appendChild(el('span', '', '本轮结果：'));
    ex.refs.forEach(function (r) { exRefs.appendChild(el('span', 'r', r[0] + ' · ' + r[1])); });
    exDone.hidden = true;

    if (reduceMotion) {
      lis.forEach(function (li) { li.classList.add('on'); });
      exDoneText.textContent = ex.done;
      exDone.hidden = false;
      return;
    }
    lis.forEach(function (li, i) { timers.push(setTimeout(function () { li.classList.add('on'); }, 260 + i * 520)); });
    timers.push(setTimeout(function () {
      exDoneText.textContent = ex.done;
      exDone.hidden = false;
    }, 260 + lis.length * 520));
  }

  if (exBar && exTopics) {
    EXAMPLES.forEach(function (ex, i) {
      var b = el('button', 'ex', ex.topic);
      b.type = 'button';
      b.setAttribute('aria-pressed', i === 0 ? 'true' : 'false');
      b.title = ex.ask;
      b.addEventListener('click', function () { runExample(i); });
      exBar.appendChild(b);
      var tli = el('li');
      var t = el('button', '', ex.topic);
      t.type = 'button';
      t.setAttribute('aria-pressed', i === 0 ? 'true' : 'false');
      t.addEventListener('click', function () { runExample(i); });
      tli.appendChild(t);
      exTopics.appendChild(tli);
    });
    runExample(0);
  }

  /* ── 真实调色板展示（取自应用源码） ──────────────── */
  var PALETTES = [
    ['浅色 · 素纸', '#F3F6FB', '#1B1F27', '#2F63E8'],
    ['深色 · 夜墨', '#15181E', '#ECEFF4', '#8AA8FF'],
    ['羊皮纸', '#F6EEDD', '#43342A', '#A8683A'],
    ['护眼绿', '#E8F0E2', '#24382C', '#2E7D4F'],
    ['羊皮纸（深色孪生）', '#1A1611', '#F2E4D4', '#C08A4A'],
    ['护眼绿（深色孪生）', '#141A14', '#DCE9DA', '#5FBF8A']
  ];
  var THEME_COLORS = [
    ['澄光', '#3D6B99'], ['宣纸', '#A97C3F'], ['砚青', '#3F7D8C'], ['竹影', '#4E8E5F'], ['霞笺', '#C4703F']
  ];
  var pv = $('#paletteView');
  if (pv) {
    PALETTES.forEach(function (p) {
      var row = el('div');
      row.style.cssText = 'display:flex;align-items:center;gap:10px;font-size:.84rem;color:var(--muted)';
      ['纸底', '正文', '强调'].forEach(function (lab, k) {
        var sw = el('span');
        sw.style.cssText = 'width:22px;height:22px;border-radius:6px;flex:none;border:1px solid rgba(236,236,230,.2);background:' + p[k + 1];
        sw.title = lab + ' ' + p[k + 1];
        row.appendChild(sw);
      });
      row.appendChild(el('span', '', p[0]));
      var hex = el('span', '');
      hex.style.cssText = 'margin-left:auto;font-family:var(--mono);font-size:.74rem;color:var(--faint)';
      hex.textContent = p[1] + ' / ' + p[3];
      row.appendChild(hex);
      pv.appendChild(row);
    });
  }

  /* ── 体验区：阅读界面示意 ───────────────────────── */
  var DOCS = [
    {
      name: '精读示范 · The Economics of Attention',
      file: '经济学人精读示范.md',
      md: [
        '## 注意力的经济学',
        '内容供给远超注意力预算时，**稀缺的不是信息，而是阅读它的时间**。',
        '一段长文的价值，往往取决于它能不能被反复找回——这正是批注与进度记忆要解决的问题。',
        '',
        '> [!NOTE] 读法提示',
        '> 本篇默认设为只读，编辑入口自动上锁；划选任意一句可试荧光笔与学习卡。',
        '',
        '## 三个观察',
        '### 1. 注意力是稀缺资源',
        '- 信息的生产成本下降，*消费*它的成本却没有',
        '- 平台的竞争对象不是别的平台，而是睡眠',
        '',
        '### 2. 深度阅读依赖结构',
        '目录、脚注与引用卡把线性正文变成可以跳转的空间。',
        '',
        '### 3. 工具应当退到文本后面',
        '1. 字号、行高、版心可调',
        '2. 主题色只做薄染，不压过正文',
        '3. 渲染不产生网络请求',
        '',
        '| 指标 | 2019 | 2024 | 变化 |',
        '| --- | ---: | ---: | ---: |',
        '| 日均长文阅读（篇） | 1.2 | 0.7 | −42% |',
        '| 单篇平均完成度 | 31% | 24% | −7pt |',
        '',
        '> 我们真正拥有的，只有正在读的这一页。[^1]',
        '',
        '- [x] 标注生词 12 个',
        '- [x] 整理进学习卡',
        '- [ ] 写一段自己的批注',
        '',
        '[^1]: 脚注卡片自带标号与缩进，点击可从注释侧栏跳回原文。'
      ].join('\n')
    },
    {
      name: '功能演示 · 图表与公式',
      file: '澄笺示例 · 全功能演示.md',
      md: [
        '## 图表与公式',
        'mermaid、ECharts、Graphviz、markmap、PlantUML 与 KaTeX 公式**全部随包离线内联**，',
        '后台预渲染成图片缓存，翻到即见，导出时直接复用。',
        '',
        '```mermaid',
        'flowchart TD',
        'A[Markdown 源码] --> B[解析成块]',
        'B --> C[卡片化排版]',
        'C --> D[图表与公式离线渲染]',
        'D --> E[阅读页 / 编辑器预览 / 导出]',
        '```',
        '',
        '$$ \\int_{0}^{\\infty} e^{-x^2}\\,dx = {\\sqrt{\\pi} \\over 2} $$',
        '',
        '## 代码块',
        '```ts',
        'const blocks = parse(text); // 128 个块',
        'return blocks.filter((b) => b.kind === "chart");',
        '```',
        '',
        '> [!TIP] 行内元素',
        '> 行内代码 `NavPathStack`、链接 [项目主页](https://github.com/FengHDSL/LiteMdReader-HarmonyOS)、',
        '> 公式 $E = mc^2$ 与注音都在同一套 Span 管线里排布。',
        '',
        '---',
        '',
        '## 任务与提醒',
        '- [ ] 检查深色模式下的图表配色',
        '- [x] 关闭浅色模式下折线图不显示的问题',
        '',
        '> [!WARNING] 重文档提醒',
        '> 公式 + 图表超过 20 张时首次打开可能掉帧，属正常现象，每篇只提示一次。'
      ].join('\n')
    },
    {
      name: '英语学习笔记 · abandon',
      file: '英语核心词汇笔记.md',
      md: [
        '## abandon',
        '**abandon** /əˈbændən/ *v.* ① 放弃，中止；② 抛弃，遗弃',
        '',
        '> [!NOTE] 中文备注',
        '> 分手时别学电视剧：**abandon your post** 是弃职，**abandon yourself to** 是沉溺。',
        '',
        '### 例句',
        '- The study was **abandoned** midway for lack of funding.  因缺乏资金，研究中途搁置。',
        '- He abandoned himself to despair.  他陷入绝望。',
        '',
        '### 同族词',
        '| 词形 | 含义 | 学习卡 |',
        '| --- | --- | --- |',
        '| abandonment | n. 遗弃 | 已掌握 |',
        '| abounding | adj. 丰富的 | 待复习 |',
        '',
        '- [x] 第一次：记得',
        '- [ ] 第二次：模糊（明日再来）',
        '- [ ] 第三次：记得即算掌握',
        '',
        '> 划选生词点「学习卡」，按 SM-2 曲线排期；累计三次「记得」才算掌握。'
      ].join('\n')
    }
  ];

  var frame = $('#frame'), fDoc = $('#fDoc'), fToc = $('#fToc'), fScroll = $('#fScroll'),
    fBar = $('#fBar'), fPct = $('#fPct'), fDocName = $('#fDocName'), docBar = $('#docBar'),
    capsule = $('#capsule'), annotList = $('#annotList'), annotEmpty = $('#annotEmpty');

  function loadDoc(idx) {
    var doc = DOCS[idx];
    var res = renderMarkdown(doc.md, fDoc);
    fDocName.textContent = doc.name;
    fToc.textContent = '';
    res.headings.forEach(function (h) {
      var li = el('li');
      var b = el('button', '', h.text);
      b.type = 'button';
      b.setAttribute('data-lvl', String(h.lvl));
      b.addEventListener('click', function () {
        h.node.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'start' });
      });
      li.appendChild(b);
      fToc.appendChild(li);
    });
    $$('.opt', docBar).forEach(function (b, i) { b.setAttribute('aria-pressed', i === idx ? 'true' : 'false'); });
    annotList.textContent = '';
    annotEmpty.hidden = false;
    fScroll.scrollTop = 0;
    updateProgress();
    hideCapsule();
  }

  function updateProgress() {
    var max = fScroll.scrollHeight - fScroll.clientHeight;
    var pct = max > 4 ? Math.round((fScroll.scrollTop / max) * 100) : 100;
    fBar.style.width = pct + '%';
    fPct.textContent = pct + '%';
  }
  if (fScroll) {
    fScroll.addEventListener('scroll', updateProgress, { passive: true });
    fScroll.addEventListener('mouseup', onSelect);
    fScroll.addEventListener('keyup', function (e) {
      if (e.shiftKey) onSelect();
    });
  }

  if (docBar) {
    DOCS.forEach(function (doc, i) {
      var b = el('button', 'opt', doc.name.split(' · ')[1] || doc.name);
      b.type = 'button';
      b.setAttribute('aria-pressed', i === 0 ? 'true' : 'false');
      b.title = doc.file;
      b.addEventListener('click', function () { loadDoc(i); });
      docBar.appendChild(b);
    });
    loadDoc(0);
  }

  var PEN = [['红', 'rgba(255,90,90,.42)', '#D95B5B'], ['绿', 'rgba(0,224,138,.42)', '#009E5F'],
    ['蓝', 'rgba(0,180,255,.42)', '#007FB8'], ['黄', 'rgba(255,224,102,.42)', '#C9A83C']];

  function hideCapsule() { if (capsule) capsule.classList.remove('on'); }

  function onSelect() {
    if (!capsule) return;
    var sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) { hideCapsule(); return; }
    var range = sel.getRangeAt(0);
    if (!fDoc.contains(range.commonAncestorContainer)) { hideCapsule(); return; }
    var text = sel.toString().trim();
    if (text.length < 2) { hideCapsule(); return; }
    var r = range.getBoundingClientRect(), host = fScroll.getBoundingClientRect();
    var top = r.top - host.top + fScroll.scrollTop - 42;
    var left = Math.min(Math.max(8, r.left - host.left + r.width / 2 - 84), host.width - 176);
    capsule.style.top = Math.max(4, top) + 'px';
    capsule.style.left = left + 'px';
    capsule.classList.add('on');
    capsule.setAttribute('data-text', text);
  }

  function currentMode() { return frame.getAttribute('data-mode'); }

  function addHighlight(idx) {
    var sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) return;
    var range = sel.getRangeAt(0);
    if (!fDoc.contains(range.commonAncestorContainer)) return;
    var text = sel.toString().trim();
    var mark;
    try {
      mark = el('mark', 'hl');
      range.surroundContents(mark);
    } catch (err) {
      hideCapsule();
      return;
    }
    var dark = currentMode() === 'dark';
    mark.style.backgroundColor = dark ? PEN[idx][2] : PEN[idx][1];
    pushAnnotation(mark, text, idx);
    sel.removeAllRanges();
    hideCapsule();
  }

  function pushAnnotation(mark, text, colorIdx) {
    annotEmpty.hidden = true;
    var item = el('div', 'annot');
    var dot = el('span', 'dot');
    dot.style.background = PEN[colorIdx][1];
    item.appendChild(dot);
    item.appendChild(el('span', '', (text.length > 26 ? text.slice(0, 26) + '…' : text) + ' · ' + PEN[colorIdx][0] + '荧光笔'));
    var jump = el('button', '', '跳回');
    jump.type = 'button';
    jump.addEventListener('click', function () {
      mark.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'center' });
      mark.style.outline = '2px solid currentColor';
      setTimeout(function () { mark.style.outline = ''; }, 900);
    });
    var del = el('button', '', '删除');
    del.type = 'button';
    del.addEventListener('click', function () {
      var parent = mark.parentNode;
      if (parent) { while (mark.firstChild) parent.insertBefore(mark.firstChild, mark); parent.removeChild(mark); }
      item.remove();
      if (!annotList.children.length) annotEmpty.hidden = false;
    });
    item.appendChild(jump);
    item.appendChild(del);
    annotList.appendChild(item);
  }

  if (capsule) {
    $$('.pen', capsule).forEach(function (b) {
      b.addEventListener('click', function () { addHighlight(Number(b.getAttribute('data-pen'))); });
    });
    var noteBtn = $('.note-btn', capsule);
    if (noteBtn) {
      noteBtn.addEventListener('click', function () {
        var t = capsule.getAttribute('data-text') || '';
        if (!t) return;
        var sel = window.getSelection();
        var mark;
        try {
          mark = el('mark', 'hl');
          sel.getRangeAt(0).surroundContents(mark);
        } catch (e) { hideCapsule(); return; }
        mark.style.borderBottom = '2px solid #B94848';
        pushAnnotation(mark, t, 0);
        annotList.lastChild.querySelector('span:nth-child(2)').textContent = t.slice(0, 26) + ' · 文字批注';
        sel.removeAllRanges();
        hideCapsule();
      });
    }
    document.addEventListener('click', function (e) {
      if (capsule && !capsule.contains(e.target)) hideCapsule();
    });
  }

  /* 控制项 */
  var ctrl = $('#ctrl');
  if (ctrl && frame) {
    ctrl.addEventListener('submit', function (e) { e.preventDefault(); });
    $$('.opt', ctrl).forEach(function (b) {
      if (b.hasAttribute('data-device') || b.hasAttribute('data-mode')) {
        b.addEventListener('click', function () {
          var group = b.parentNode;
          $$('.opt', group).forEach(function (o) { o.setAttribute('aria-pressed', 'false'); });
          b.setAttribute('aria-pressed', 'true');
          if (b.hasAttribute('data-device')) frame.setAttribute('data-device', b.getAttribute('data-device'));
          else frame.setAttribute('data-mode', b.getAttribute('data-mode'));
          hideCapsule();
          setTimeout(updateProgress, 380);
        });
      }
    });
    var sw = $('#swatches');
    THEME_COLORS.forEach(function (t, i) {
      var b = el('button', 'sw');
      b.type = 'button';
      b.style.background = t[1];
      b.title = t[0] + ' ' + t[1];
      b.setAttribute('aria-label', '主题色 ' + t[0]);
      b.setAttribute('aria-pressed', i === 0 ? 'true' : 'false');
      b.addEventListener('click', function () {
        $$('.sw', sw).forEach(function (o) { o.setAttribute('aria-pressed', 'false'); });
        b.setAttribute('aria-pressed', 'true');
        frame.style.setProperty('--f-accent', t[1]);
      });
      sw.appendChild(b);
    });
    var resetAccent = el('button', 'opt', '跟随主题');
    resetAccent.type = 'button';
    resetAccent.setAttribute('aria-pressed', 'false');
    resetAccent.style.marginTop = '6px';
    resetAccent.addEventListener('click', function () {
      frame.style.removeProperty('--f-accent');
      $$('.sw', sw).forEach(function (o) { o.setAttribute('aria-pressed', 'false'); });
    });
    sw.parentNode.appendChild(resetAccent);

    var fs = $('#fs'), ms = $('#ms'), fsOut = $('#fsOut'), msOut = $('#msOut');
    fs.addEventListener('input', function () {
      frame.style.setProperty('--f-size', fs.value + 'px');
      fsOut.textContent = fs.value + 'px';
    });
    ms.addEventListener('input', function () {
      frame.style.setProperty('--f-measure', ms.value + 'px');
      msOut.textContent = ms.value + 'px';
    });
  }

  /* ── 截图画廊 ─────────────────────────────────────── */
  var SHOTS = [
    ['assets/phone-shelf.png', 'phone', '书架 · 封面网格', '三列封面、继续阅读与底部悬浮胶囊'],
    ['assets/phone-reading.png', 'phone', '阅读 · 选区胶囊', '四种荧光色、批注与学习卡入口'],
    ['assets/phone-editor.png', 'phone', '编辑 · 分段预览', '点哪段改哪段，下方实时渲染'],
    ['assets/phone-search.png', 'phone', '复习 · 记忆确认', '评分后的内容确认页与三灯状态'],
    ['assets/phone-studio.png', 'phone', '注释侧栏 · 筛选', '分类固定在顶部，卡片可删可跳'],
    ['assets/phone-review.png', 'phone', '文房 · 学习统计', '阅读时长、批注速记与今日笺'],
    ['assets/phone-log.png', 'phone', '写作日志 · 热力图', '累计字数与一年写作轨迹'],
    ['assets/phone-ai.png', 'phone', 'AI 助手 · 对话', '深度思考耗时与回复中的卡片'],
    ['assets/tab-shelf.png', 'tab', '平板横屏 · 书架', '宽屏下的封面墙与统计'],
    ['assets/tab-reading.png', 'tab', '平板横屏 · 三栏精读', '目录 / 正文 / 批注两侧常驻可拖宽'],
    ['assets/tab-ai.png', 'tab', '平板横屏 · AI 生成', '生成带表格的词汇手册'],
    ['assets/phone-widget.png', 'desk', '桌面卡片 2×2', '最近文档与阅读进度直达继续阅读']
  ];
  var gal = $('#gal'), lb = $('#lightbox'), lbImg = $('#lbImg'), lbTitle = $('#lbTitle');
  var shown = [];

  function buildGallery(filter) {
    gal.textContent = '';
    shown = [];
    SHOTS.forEach(function (s, i) {
      if (filter !== 'all' && s[1] !== filter) return;
      shown.push(i);
      var fig = el('figure');
      fig.setAttribute('data-w', s[1]);
      fig.setAttribute('tabindex', '0');
      fig.setAttribute('role', 'button');
      fig.setAttribute('aria-label', '放大查看：' + s[2] + ' —— ' + s[3]);
      var img = el('img');
      img.src = s[0];
      img.alt = s[2] + '：' + s[3];
      img.loading = 'lazy';
      img.decoding = 'async';
      img.width = s[1] === 'tab' ? 1400 : 880;
      img.height = s[1] === 'tab' ? 933 : 1564;
      fig.appendChild(img);
      var cap = el('figcaption');
      cap.appendChild(el('b', '', s[2]));
      cap.appendChild(el('span', '', s[3]));
      fig.appendChild(cap);
      fig.addEventListener('click', function () { openLightbox(i); });
      fig.addEventListener('keydown', function (e) {
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openLightbox(i); }
      });
      gal.appendChild(fig);
    });
  }

  var lbPos = -1;
  function openLightbox(i) {
    var pos = shown.indexOf(i);
    lbPos = pos < 0 ? 0 : pos;
    paintLightbox();
    if (!lb.open) lb.showModal();
  }
  function paintLightbox() {
    var s = SHOTS[shown[lbPos]];
    lbImg.src = s[0];
    lbImg.alt = s[2] + '：' + s[3];
    lbTitle.textContent = s[2] + ' · ' + s[3] + '（' + (lbPos + 1) + ' / ' + shown.length + '）';
  }
  if (gal) {
    buildGallery('all');
    $$('#galFilters .ex').forEach(function (b) {
      b.addEventListener('click', function () {
        $$('#galFilters .ex').forEach(function (o) { o.setAttribute('aria-pressed', 'false'); });
        b.setAttribute('aria-pressed', 'true');
        buildGallery(b.getAttribute('data-gal'));
      });
    });
    $('#lbClose').addEventListener('click', function () { lb.close(); });
    $('#lbPrev').addEventListener('click', function () { lbPos = (lbPos - 1 + shown.length) % shown.length; paintLightbox(); });
    $('#lbNext').addEventListener('click', function () { lbPos = (lbPos + 1) % shown.length; paintLightbox(); });
    lb.addEventListener('click', function (e) { if (e.target === lb) lb.close(); });
  }

  /* ── 本地交互演示（对话框） ─────────────────────── */
  var pg = $('#playground'), pgIn = $('#pgInput'), pgOut = $('#pgOutput'), pgStat = $('#pgStat'), pgPresets = $('#pgPresets');
  var PRESETS = [
    ['提示块与表格', [
      '## 提示块与表格',
      '> [!IMPORTANT] 卡片化',
      '> 提示块有 NOTE / TIP / IMPORTANT / WARNING / CAUTION 五种，各带徽标色。',
      '',
      '| 语法 | 变成什么卡 |',
      '| --- | --- |',
      '| `> [!TIP]` | 提示卡（带徽标） |',
      '| `- [x] 任务` | 可勾选的任务项 |',
      '| `- [x] 任务` | 可勾选的任务项 |'
    ].join('\n')],
    ['图表与公式', [
      '## 图表与公式',
      '```mermaid',
      'flowchart TD',
      'A[Markdown] --> B[解析成块]',
      'B --> C[卡片化排版]',
      'C --> D[离线渲染成图]',
      '```',
      '',
      '$$ a^2 + b^2 = c^2 $$',
      '',
      '> 真机里 mermaid 与 KaTeX 由随包离线引擎绘制成图，可全屏放大与缩放。'
    ].join('\n')],
    ['代码与任务', [
      '## 代码与任务',
      '```ts',
      'const blocks = parse(text); // 每块一张卡',
      'return blocks.filter((b) => b.kind !== "raw");',
      '```',
      '',
      '- [x] 版本历史：自动快照 1 / 5 / 10 分钟',
      '- [ ] 差异对比与一键恢复',
      '',
      '行内代码 `docs/images/` 与链接 [项目主页](https://github.com/FengHDSL/LiteMdReader-HarmonyOS)。'
    ].join('\n')]
  ];
  function renderPg() {
    var res = renderMarkdown(pgIn.value, pgOut);
    pgStat.textContent = '解析出 ' + res.blocks + ' 个块 · ' + res.headings.length + ' 个标题 · ' +
      pgIn.value.length + ' 字符';
  }
  if (pg && pgIn) {
    PRESETS.forEach(function (p, i) {
      var b = el('button', 'ex', p[0]);
      b.type = 'button';
      b.setAttribute('aria-pressed', i === 0 ? 'true' : 'false');
      b.addEventListener('click', function () {
        $$('.ex', pgPresets).forEach(function (o) { o.setAttribute('aria-pressed', 'false'); });
        b.setAttribute('aria-pressed', 'true');
        pgIn.value = p[1];
        renderPg();
      });
      pgPresets.appendChild(b);
    });
    pgIn.value = PRESETS[0][1];
    pgIn.addEventListener('input', renderPg);
    $('#openPlayground').addEventListener('click', function () {
      if (!pg.open) pg.showModal();
      renderPg();
      setTimeout(function () { pgIn.focus(); }, 30);
    });
    $('#pgClose').addEventListener('click', function () { pg.close(); });
    pg.addEventListener('click', function (e) { if (e.target === pg) pg.close(); });
  }
})();
