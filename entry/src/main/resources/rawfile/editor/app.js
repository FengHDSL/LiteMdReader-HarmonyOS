/* 澄笺 · Web 编辑器核心（WYSIWYG / IR 双模式，块级模型 + 原比例渲染） */
(function () {
  'use strict';
  marked.setOptions({ breaks: true, gfm: true });

  // ── LaTeX 数学（$…$ 行内 / $$…$$ 块级，KaTeX 渲染）──
  // 渲染为 contenteditable=false 的孤岛（data-tex 存源码），退出编辑经
  // turndown 还原为 $…$ / $$…$$——WYSIWYG 往返不丢数学源码。
  function escapeAttr(s) {
    return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
  }
  const mathInlineExt = {
    name: 'mathInline', level: 'inline',
    start(src) { const i = src.indexOf('$'); return i < 0 ? undefined : i; },
    tokenizer(src) {
      // 开 $ 后不接空白；闭 $ 前不接空白、后不接数字（避开 "$5 和 $10" 这类误判）
      const m = /^\$(?!\s)((?:\\.|[^$\\])+?)\$(?!\d)/.exec(src);
      if (m) { return { type: 'mathInline', raw: m[0], tex: m[1].trim() }; }
      return undefined;
    },
    renderer(token) {
      return '<span class="edit-math" contenteditable="false" data-tex="'
        + escapeAttr(token.tex) + '"></span>';
    }
  };
  const mathBlockExt = {
    name: 'mathBlock', level: 'block',
    start(src) { const i = src.indexOf('$$'); return i < 0 ? undefined : i; },
    tokenizer(src) {
      const m = /^\$\$([\s\S]+?)\$\$(?:\n+|$)/.exec(src);
      if (m) { return { type: 'mathBlock', raw: m[0], tex: m[1].trim() }; }
      return undefined;
    },
    renderer(token) {
      return '<div class="edit-math" contenteditable="false" data-display="1" data-tex="'
        + escapeAttr(token.tex) + '"></div>';
    }
  };
  marked.use({ extensions: [mathInlineExt, mathBlockExt] });

  /** 块渲染后把 .edit-math 孤岛用 KaTeX 画出来（渲染失败回落原文，绝不空白）。 */
  function renderMathIn(root) {
    try {
      if (!window.katex || !root) { return; }
      const els = root.querySelectorAll('.edit-math');
      for (let k = 0; k < els.length; k++) {
        const el = els[k];
        const tex = el.getAttribute('data-tex') || '';
        try {
          katex.render(tex, el, {
            displayMode: el.getAttribute('data-display') === '1', throwOnError: false
          });
        } catch (e) {
          el.textContent = tex;
        }
      }
    } catch (e) { /* 忽略 */ }
  }

  const turndownSvc = new TurndownService({ headingStyle: 'atx', codeBlockStyle: 'fenced' });
  turndownSvc.keep(['table']);
  // 数学孤岛 → LaTeX 源码（WYSIWYG → Markdown 往返的关键）
  turndownSvc.addRule('editMath', {
    filter: function (node) {
      return node.nodeType === 1 && node.classList && node.classList.contains('edit-math');
    },
    replacement: function (content, node) {
      const tex = node.getAttribute('data-tex') || '';
      return node.getAttribute('data-display') === '1'
        ? '\n$$\n' + tex + '\n$$\n'
        : '$' + tex + '$';
    }
  });

  const editorEl = document.getElementById('editor');
  let blocks = [];            // { raw, html, editing }
  let mode = 1;               // 1 WYSIWYG  2 IR
  let caretIdx = -1;          // 正在编辑的块下标
  let undoStack = [];
  let redoStack = [];
  let pushTimer = null;

  function md8(s) { /* 占位 */ return s; }
  // 模式切换的黑色提示气泡已按用户要求删除（切模式本身有视觉反馈，无需气泡）

  function snapshot() {
    undoStack.push(blocks.map(b => b.raw).join('\n\n'));
    if (undoStack.length > 60) undoStack.shift();
    redoStack = [];
  }

  function schedulePush() {
    clearTimeout(pushTimer);
    pushTimer = setTimeout(flushNow, 500);
  }

  function blocksToMd() {
    return blocks.map(b => b.raw).join('\n\n');
  }

  function flushNow() {
    clearTimeout(pushTimer);
    pushTimer = null;
    if (window.arkHost && window.arkHost.mdChanged) {
      window.arkHost.mdChanged(blocksToMd());
    }
  }

  function renderBlockHtml(raw) {
    try {
      return marked.parse(raw);
    } catch (e) {
      return '<p>' + raw.replace(/</g, '&lt;') + '</p>';
    }
  }

  function isRichEditable(raw) {
    const t = raw.trim();
    // 复杂块（代码 / 表格 / 图表 / 数学）走源码编辑，其余可富文本
    return !t.startsWith('```') && !t.startsWith('|') && !t.startsWith('$$')
      && !t.startsWith('```mermaid');
  }

  function makeBlockEl(b, i) {
    const div = document.createElement('div');
    div.className = 'block plain';
    div.dataset.idx = String(i);
    if (b.editing) {
      div.classList.add('editing');
    }
    if (b.editing && mode === 1 && isRichEditable(b.raw)) {
      // WYSIWYG：渲染态 contenteditable（工具条 execCommand 直接生效）
      div.contentEditable = 'true';
      div.innerHTML = b.html;
    } else if (b.editing) {
      // IR：源码 textarea
      div.innerHTML = '';
      const ta = document.createElement('textarea');
      ta.className = 'src';
      ta.value = b.raw;
      ta.rows = Math.max(3, b.raw.split('\n').length + 1);
      div.appendChild(ta);
      setTimeout(() => {
        ta.focus();
        try { ta.selectionStart = ta.selectionEnd = ta.value.length; } catch (e) { /* 忽略 */ }
      }, 30);
      ta.addEventListener('input', () => {
        b.raw = ta.value;
        autoGrow(ta);
        schedulePush();
      });
      ta.addEventListener('keydown', (e) => {
        handleKey(e, i, ta);
      });
    } else {
      div.innerHTML = b.html;
      if (b.html.length < 4) {
        div.classList.add('editing');
        div.innerHTML = '<span style="color:var(--tx2)">空块 · 点击工具栏开始</span>';
      }
    }
    if (!b.editing) {
      div.addEventListener('click', () => {
        startEdit(i);
      });
    }
    // 数学孤岛 → KaTeX 渲染（源码 textarea 分支无孤岛，自动跳过）
    renderMathIn(div);
    return div;
  }

  function autoGrow(ta) {
    ta.style.height = 'auto';
    ta.style.height = (ta.scrollHeight + 2) + 'px';
  }

  function renderAll(keepScroll) {
    const st = editorEl.scrollTop;
    editorEl.innerHTML = '';
    blocks.forEach((b, i) => {
      editorEl.appendChild(makeBlockEl(b, i));
    });
    const end = document.createElement('div');
    end.style.height = '40px';
    editorEl.appendChild(end);
    if (keepScroll) {
      editorEl.scrollTop = st;
    }
  }

  function startEdit(i) {
    if (i < 0 || i >= blocks.length) {
      return;
    }
    snapshot();
    commitCaret(false);
    blocks[i].editing = true;
    caretIdx = i;
    renderAll();
    // WYSIWYG 富文本块：光标落块尾
    if (mode === 1) {
      const el = editorEl.querySelector('.block[data-idx="' + i + '"]');
      if (el && el.contentEditable === 'true') {
        el.focus();
        const sel = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(el);
        range.collapse(false);
        sel.removeAllRanges();
        sel.addRange(range);
      }
    }
  }

  function commitCaret(push) {
    const i = caretIdx;
    if (i < 0 || i >= blocks.length || !blocks[i].editing) {
      return;
    }
    const el = editorEl.querySelector('.block[data-idx="' + i + '"]');
    if (mode === 1 && el && el.contentEditable === 'true') {
      blocks[i].raw = turndownSvc.turndown(el.innerHTML);
    }
    blocks[i].editing = false;
    caretIdx = -1;
    if (push) {
      schedulePush();
    }
  }

  function handleKey(e, i, ta) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      // 回车：按光标拆块（vditor IR 同款）
      const pos = ta.selectionStart;
      const before = ta.value.substring(0, pos);
      const after = ta.value.substring(pos);
      snapshot();
      blocks[i].raw = before.replace(/\n+$/, '');
      blocks[i].editing = false;
      const nb = { raw: after, html: '', editing: true };
      blocks.splice(i + 1, 0, nb);
      caretIdx = i + 1;
      renderAll();
      const el = editorEl.querySelector('.block[data-idx="' + (i + 1) + '"] textarea');
      if (el) { el.focus(); el.selectionStart = 0; el.selectionEnd = 0; }
      schedulePush();
    } else if (e.key === 'Backspace' && ta.selectionStart === 0 && ta.selectionEnd === 0) {
      if (i > 0) {
        e.preventDefault();
        snapshot();
        const prev = blocks[i - 1];
        prev.raw = prev.raw + '\n' + ta.value;
        prev.editing = prev.raw.length >= 0;
        blocks.splice(i, 1);
        caretIdx = i - 1;
        renderAll();
        const el = editorEl.querySelector('.block[data-idx="' + (i - 1) + '"] textarea');
        if (el) {
          el.focus();
          el.selectionStart = el.selectionEnd = prev.raw.length;
        }
        schedulePush();
      }
    }
  }

  // ── 工具条动作 ──
  function activeTa() {
    const el = editorEl.querySelector('.block.editing textarea.src');
    return el || null;
  }

  function activeEditable() {
    const el = editorEl.querySelector('.block[contenteditable="true"]');
    return el || null;
  }

  function wrapSel(before, after) {
    const ta = activeTa();
    if (ta) {
      const s = ta.selectionStart, e = ta.selectionEnd;
      const sel = ta.value.substring(s, e) || '文本';
      ta.setRangeText(before + sel + after, s, e, 'select');
      ta.selectionStart = s + before.length;
      ta.selectionEnd = s + before.length + sel.length;
      ta.dispatchEvent(new Event('input'));
      return;
    }
    const ed = activeEditable();
    if (ed) {
      document.execCommand('insertText', false, before + (window.getSelection().toString() || '文本') + after);
    }
  }

  function linePrefix(prefix) {
    const ta = activeTa();
    if (ta) {
      const s = ta.value.lastIndexOf('\n', ta.selectionStart - 1) + 1;
      ta.setRangeText(prefix, s, s, 'end');
      ta.dispatchEvent(new Event('input'));
      return;
    }
    const ed = activeEditable();
    if (ed) {
      document.execCommand('formatBlock', false, prefix);
    }
  }

  const ACTIONS = {
    undo: () => {
      if (undoStack.length === 0) { return; }
      redoStack.push(blocksToMd());
      setMarkdown(undoStack.pop(), mode, true);
    },
    redo: () => {
      if (redoStack.length === 0) { return; }
      undoStack.push(blocksToMd());
      setMarkdown(redoStack.pop(), mode, true);
    },
    h1: () => linePrefix('# '),
    h2: () => linePrefix('## '),
    h3: () => linePrefix('### '),
    bold: () => wrapSel('**', '**'),
    italic: () => wrapSel('*', '*'),
    strike: () => wrapSel('~~', '~~'),
    quote: () => linePrefix('> '),
    ol: () => linePrefix('1. '),
    ul: () => linePrefix('- '),
    task: () => linePrefix('- [ ] '),
    hr: () => {
      const ta = activeTa();
      if (ta) {
        const s = ta.selectionStart;
        ta.setRangeText('\n---\n', s, s, 'end');
        ta.dispatchEvent(new Event('input'));
      }
    },
    code: () => wrapSel('\n```\n', '\n```\n'),
    table: () => {
      const ta = activeTa();
      const tpl = '\n| 列1 | 列2 | 列3 |\n| --- | --- | --- |\n| 内容 | 内容 | 内容 |\n';
      if (ta) {
        const s = ta.selectionStart;
        ta.setRangeText(tpl, s, s, 'end');
        ta.dispatchEvent(new Event('input'));
      }
    },
    link: () => wrapSel('[', '](https://example.com)')
  };

  // （页面内 #bar 工具栏与 #toast 气泡已按用户要求删除：格式走宿主原生工具层，
  //   模式切换无气泡。setBarVisible 保留为空实现，宿主旧调用不会报错。）
  window.setBarVisible = function (v) { /* 已删除页面内工具栏 */ };

  // ── 宿主桥 ──
  window.setMarkdown = function (md, m) {
    mode = (m === 2) ? 2 : 1;
    undoStack = [];
    redoStack = [];
    blocks = [];
    const tokens = marked.lexer(md || '');
    tokens.forEach((t) => {
      if (t.type === 'space') { return; }
      blocks.push({ raw: t.raw.replace(/\n+$/, ''), html: '', editing: false });
    });
    if (blocks.length === 0) {
      blocks.push({ raw: '', html: '', editing: false });
    }
    blocks.forEach((b) => { b.html = renderBlockHtml(b.raw); });
    renderAll(false);
  };

  window.exportToHost = function () {
    commitCaret(false);
    if (window.arkHost && window.arkHost.mdChanged) {
      window.arkHost.mdChanged(blocksToMd());
    }
  };

  window.flushNow = function () {
    commitCaret(true);
    flushNow();
  };

  /**
   * 主题下发（原生侧调）：把 app 当前主题的 CSS 变量推给编辑表面。
   * 此前配色固定深色（#11161d），与 app 主题割裂——浅色主题下整块编辑区
   * 变成"深色网页"（用户实测"界面也不一样"）。变量字典由 Editor.ets 构造，
   * 键为 CSS 自定义属性名（--bg/--tx/--press…），值是 8 位 hex 或 RGB 三元组。
   */
  window.setTheme = function (vars) {
    try {
      var root = document.documentElement;
      for (var k in vars) {
        if (Object.prototype.hasOwnProperty.call(vars, k) && vars[k]) {
          root.style.setProperty(k, vars[k]);
        }
      }
    } catch (e) { /* 主题失败不影响编辑 */ }
  };

  /**
   * **原生工具条桥**（用户要求"使用 app 原生的样式"）：
   * 工具条由 ArkTS 原生渲染，页面自带的 #bar 被隐藏（setBarVisible(false)）；
   * 这里把原生命令直达 ACTIONS，并**恢复失焦前的选区**——点击原生按钮会让
   * Web 失焦，不恢复的话加粗/列表等操作会落在错误位置甚至没有选区。
   */
  var lastEditRange = null;
  document.addEventListener('selectionchange', function () {
    try {
      var sel = window.getSelection();
      if (sel && sel.rangeCount > 0) {
        var r = sel.getRangeAt(0);
        var ed = activeEditable();
        if (ed && ed.contains(r.commonAncestorContainer)) {
          lastEditRange = r.cloneRange();
        }
      }
    } catch (e) { /* 忽略 */ }
  });

  window.execCmd = function (a) {
    try {
      var ta = activeTa();
      if (ta) {
        // IR 模式（textarea）：失焦后 selectionStart/End 仍有值，focus 后恢复
        var s = ta.selectionStart;
        var e = ta.selectionEnd;
        ta.focus();
        ta.selectionStart = s;
        ta.selectionEnd = e;
      } else {
        var ed = activeEditable();
        if (ed) {
          ed.focus();
          if (lastEditRange) {
            var sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(lastEditRange);
          }
        }
      }
      if (ACTIONS[a]) {
        ACTIONS[a]();
        commitCaret(true);
      }
    } catch (e) { /* 命令失败静默 */ }
  };

  window.addEventListener('beforeunload', flushNow);
})();
