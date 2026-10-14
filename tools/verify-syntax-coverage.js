#!/usr/bin/env node
/**
 * 语法覆盖实测：把**真解析器**跑在 Node 里，逐条验"这语法到底渲染成什么"
 * ======================================================================
 *
 * 为什么值得单开一个工具：之前的 sim-*.js 都是**算法端口**——把 ArkTS 里的判定抄一份到
 * JS，靠"源码同步检查"约束别抄歪。抄对了能验逻辑，但验不出一件事：**真代码里那条分支
 * 根本没被走到**。这一轮就栽在这上面——`{1,3-5}` 指定行高亮的解析代码明明在
 * MdParser.ets:747，可 `fenceLang()`（2409）早就把 `{}` 剥掉、只留第一个空格前的词，
 * hlLines 那段永远拿到不含花括号的 lang，于是这个语法实际上是**不支持**的，
 * 而所有端口检查全绿。
 *
 * 所以现在直接用 SDK 自带的 typescript 把 markdown 目录下的纯逻辑 .ets 转成 CommonJS，
 * require 真 MdParser.parse() 跑探针。判的是真代码，不存在端口跑偏。
 * 只处理无平台依赖的那几个文件（MdTypes / Emoji / MathLite / PlantumlBridge / MdParser），
 * 一旦哪天它们 import 了 @kit.*，这里会直接报错提示，不会静默降级成假绿灯。
 *
 * tier: 'claim' = 能力矩阵里我们说有 ✅，失败就是真缺口
 *       'known' = 已按"尽力子集 / 如实标注"降级，失败只报不动作项
 *
 * 用法：node tools/verify-syntax-coverage.js
 */
'use strict';

const fs = require('fs');
const path = require('path');
const TS_MOD =
  'C:/Users/panda/AppData/Local/OpenHarmony/Sdk/26.0.0/ets/build-tools/ets-loader/node_modules/typescript';
const ts = require(TS_MOD);

const ROOT = path.join(__dirname, '..');
const MD = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'markdown');
const OUT = path.join(ROOT, '.workbuddy', 'parser-cjs');
const NEED = ['MdTypes', 'Emoji', 'MathLite', 'PlantumlBridge', 'ZenumlBridge', 'MdParser'];

function build() {
  fs.mkdirSync(OUT, { recursive: true });
  for (const n of NEED) {
    const file = path.join(MD, n + '.ets');
    const src = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
    if (/^import .*@(kit|ohos)\./m.test(src)) {
      console.log('FAIL  ' + n + '.ets 现在 import 了平台模块，本工具的转译范围（纯逻辑文件）不再成立，'
        + '需要补 stub 才能继续 —— 别把它当绿灯');
      process.exit(1);
    }
    const r = ts.transpileModule(src, {
      fileName: n + '.ets',
      compilerOptions: {
        target: ts.ScriptTarget.ES2021,
        module: ts.ModuleKind.CommonJS,
        esModuleInterop: true,
        alwaysStrict: false,
      },
    });
    if ((r.diagnostics || []).length > 0) {
      console.log('FAIL  ' + n + ' 转译诊断：' + r.diagnostics.map((d) =>
        ts.flattenDiagnosticMessageText(d.messageText, ' ')).join(' | '));
      process.exit(1);
    }
    fs.writeFileSync(path.join(OUT, n + '.js'), r.outputText);
  }
}
build();
for (const n of NEED) { delete require.cache[path.join(OUT, n + '.js')]; }
const { MdParser, } = require(path.join(OUT, 'MdParser.js'));
const { PlantumlBridge, } = require(path.join(OUT, 'PlantumlBridge.js'));
const { ZenumlBridge, } = require(path.join(OUT, 'ZenumlBridge.js'));
const { MdBlockKind, MdInlineKind, MdCalloutKind, MdTaskState, } = require(path.join(OUT, 'MdTypes.js'));

// ── 取产物的几个小工具 ──
function allInlines(res) {
  const out = [];
  const push = (arr) => {
    for (const x of arr || []) {
      if (Array.isArray(x)) { push(x); continue; }   // 表格单元格里装的是一段片段数组
      if (x && typeof x === 'object' && x.kind !== undefined) { out.push(x); }
    }
  };
  for (const b of res.blocks) {
    push(b.inlines);
    for (const r of b.rows || []) { push(r.cells); }
  }
  return out;
}
function withKind(res, kind) {
  return allInlines(res).filter((x) => x.kind === kind);
}
/** 带某个样式标志位的片段（bold / italic / strike / code 都是标志位，kind 仍是 Plain）。 */
function withFlag(res, flag) {
  return allInlines(res).filter((x) => x[flag] === true);
}
function blocks(res, kind) {
  return res.blocks.filter((b) => b.kind === kind);
}
/** 行内片段的拼接文本（判断"渲染出来的正文"只用它）。
 *  ⚠️ 不要用 block.plain —— 那是**源码原文**，转义符、`:tada:`、`<span style>` 都还在原样里，
 *  拿它断言会把已经生效的语法误判成没生效（这一版工具就错过三次）。 */
function flatText(res) {
  const parts = [];
  for (const x of allInlines(res)) { parts.push(x.text || ''); }
  return parts.join('');
}

let fails = 0;
let knownFails = 0;
const gaps = [];
function probe(sec, label, src, tier, want) {
  let res = null;
  let err = '';
  try {
    res = MdParser.parse(src);
  } catch (e) {
    err = e.message;
  }
  if (err.length > 0) {
    fails++;
    console.log('  抛错  ' + sec + ' ' + label + ' —— ' + err);
    gaps.push(sec + ' ' + label + '（解析器抛错）');
    return;
  }
  const r = want(res);
  const ok = r === true;
  if (ok) {
    console.log('  ok    ' + sec + ' ' + label);
    return;
  }
  const why = typeof r === 'string' ? r : '判定未通过';
  if (tier === 'known') {
    knownFails++;
    console.log('  已标注 ' + sec + ' ' + label + ' —— ' + why);
    return;
  }
  fails++;
  console.log('  FAIL  ' + sec + ' ' + label + ' —— ' + why);
  gaps.push(sec + ' ' + label + '：' + why);
}

const K = MdBlockKind;
const I = MdInlineKind;
const C = MdCalloutKind;
const T = MdTaskState;
const txt = (arr) => arr.map((x) => x.text).join('');

// ════ §1 行内文本排版 ════
probe('§1.1', '粗体 / 斜体 / 删除线 / 行内代码',
  '**粗体**、`行内代码`、*斜体*、***粗斜体***、~~删除线~~\n', 'claim', (res) => {
    // 粗斜体这些**叠加样式**是标志位（kind 仍是 Plain），只有行内代码是独立 kind
    const all = allInlines(res);
    const need = [['bold', '粗体'], ['italic', '斜体'], ['strike', '删除']];
    for (const [flag, sub] of need) {
      if (!all.some((x) => x[flag] === true && (x.text || '').indexOf(sub) >= 0)) { return '缺 ' + flag; }
    }
    if (withKind(res, I.Code).length === 0) { return '缺行内代码 kind'; }
    const both = all.filter((x) => x.bold === true && x.italic === true);
    return both.length > 0 ? true : '***粗斜体*** 没有同时置上两个标志位';
  });
probe('§1.1', '斜体里套粗体（改三连定界符不能弄坏常规嵌套）',
  '**粗 *斜粗* 粗** 与 *斜 **粗斜** 斜*\n', 'claim', (res) => {
    const all = allInlines(res);
    const both = all.filter((x) => x.bold === true && x.italic === true);
    if (both.length === 0) { return '嵌套的 *** 层没同时置上两个标志位'; }
    if (all.some((x) => /^\*/.test(x.text) || /\*$/.test(x.text))) {
      return '漏出字面星号：' + JSON.stringify(all.map((x) => x.text));
    }
    return true;
  });
probe('§1.2', '高亮 ==文字==', '==这段文字需要高亮显示==\n', 'claim',
  (res) => withKind(res, I.Mark).length > 0 || '没有 Mark 片段');
probe('§1.3', '上标 ^x^ 与下标 ~x~', 'H~2~O、x^2^、E=mc^2^\n', 'claim', (res) => {
  if (withKind(res, I.Sub).length === 0) { return '没有 Sub（下标）'; }
  if (withKind(res, I.Sup).length === 0) { return '没有 Sup（上标）'; }
  return true;
});
probe('§1.4', 'Emoji 短代码 :tada:', ':tada: :rocket: :bulb: :white_check_mark:\n', 'claim',
  (res) => flatText(res).indexOf('🎉') >= 0 || '短代码没换成字符');
probe('§1.5', '<kbd> 键帽', '<kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>P</kbd>\n', 'claim',
  (res) => withKind(res, I.Key).length === 3 ? true : 'Key 片段 ' + withKind(res, I.Key).length + ' 个（期望 3）');
probe('§1.6', '<ruby> 带 <rp> 的完整写法',
  '<ruby>markdown<rp>(</rp><rt>mā kè dāng</rt><rp>)</rp></ruby> 是一种轻量标记语言。\n', 'claim', (res) => {
    const ruby = withKind(res, I.Ruby);
    if (ruby.length === 0) { return '没有 Ruby 注音片段'; }
    if (txt(ruby) !== 'mā kè dāng') { return '注音内容是 "' + txt(ruby) + '"，应为读音本身'; }
    if (flatText(res).indexOf('<rp>') >= 0 || flatText(res).indexOf('rp>') >= 0) { return '<rp> 漏成正文'; }
    return true;
  });
probe('§1.7', '反斜杠转义 \\* \\_ \\# \\` \\\\',
  '\\* 不是斜体 \\* · \\_ 不是下划线 \\_ · \\# 不是标题 \\# · \\` 反引号 \\` · \\\\ 反斜杠\n', 'claim', (res) => {
    if (blocks(res, K.Heading).length > 0) { return '\\# 被判成标题'; }
    const t = flatText(res);
    if (t.indexOf('* 不是斜体 *') < 0) { return '转义的 * 没还原："' + t.slice(0, 40) + '"'; }
    if (t.indexOf('` 反引号 `') < 0) { return '转义的反引号没还原："' + t.slice(0, 60) + '"'; }
    return true;
  });

// 下划线 `_` 的**词边界**判定（用户报"下划线异常，没有区分斜体"）。
// CommonMark 的 flanking 按 **Unicode** 字母/数字算，旧实现只量 ASCII(a-zA-Z0-9_)，
// 于是中文里的下划线全变斜体：`这是_一_个测试` 被排成斜体"一"。
// 这几条钉住三件事：中文词内不算强调、ASCII 词内不算强调、真正的 `_x_` 仍要算。
probe('§1.7', '中文词内的下划线不转斜体（这是_一_个测试 按字面输出）',
  '中文下划线：这是_一_个测试\n', 'claim', (res) => {
    const it = withFlag(res, 'italic');
    if (it.length > 0) { return '被排成斜体：' + JSON.stringify(it.map((x) => x.text)); }
    if (flatText(res).indexOf('这是_一_个测试') < 0) { return '字面下划线丢了：' + flatText(res); }
    return true;
  });
probe('§1.7', '中英混排词内的下划线不转斜体（Markdown_语法 / user_name_ / _name_x）',
  '用 Markdown_语法 写，字段 user_name_ 与 _name_x 都要原样\n', 'claim', (res) => {
    const it = withFlag(res, 'italic');
    return it.length === 0 ? true : '被排成斜体：' + JSON.stringify(it.map((x) => x.text));
  });
probe('§1.7', '真正的下划线强调仍然生效（_斜体_ / __粗体__ / 词后空格 _README_）',
  '_斜体_ 与 __粗体__ 与 见 _README_ 文件\n', 'claim', (res) => {
    const ital = withFlag(res, 'italic').map((x) => x.text);
    const bold = withFlag(res, 'bold').map((x) => x.text);
    if (ital.indexOf('斜体') < 0) { return '_斜体_ 没成斜体：' + JSON.stringify(ital); }
    if (bold.indexOf('粗体') < 0) { return '__粗体__ 没成粗体：' + JSON.stringify(bold); }
    if (ital.indexOf('README') < 0) { return '_README_ 没成斜体：' + JSON.stringify(ital); }
    return true;
  });
probe('§1.7', '星号可以做词内强调（这是*一*个测试 仍是斜体，与下划线不同规则）',
  '星号中文：这是*一*个测试\n', 'claim', (res) => {
    const it = withFlag(res, 'italic').map((x) => x.text);
    return it.indexOf('一') >= 0 ? true : 'CommonMark 允许 * 词内强调，这里丢了：' + JSON.stringify(it);
  });

// ════ §2 块级结构 ════
probe('§2.1', '三级嵌套引用',
  '> 一级引用\n> > 二级嵌套引用\n> > > 三级嵌套引用，内部仍可写 **粗体** 与 `代码`\n', 'claim', (res) => {
    const q = blocks(res, K.Quote);
    const depths = q.map((b) => b.indent);
    return (depths.indexOf(2) >= 0) ? true : '引用层级 ' + JSON.stringify(depths) + '，最深应为 2';
  });
probe('§2.2', '五级混排嵌套列表',
  '1. 一级有序项\n   1. 二级有序项\n      - 三级无序项\n        - 四级无序项\n          - 五级\n2. 另一个一级项\n   - 混排无序\n',
  'claim', (res) => {
    const it = blocks(res, K.ListItem);
    const lv = it.map((b) => b.indent);
    return lv.indexOf(4) >= 0 ? true : '层级只到 ' + Math.max.apply(null, lv) + '（期望出现 4）';
  });
probe('§2.3', '任务列表（含子任务勾选态）',
  '- [x] 已完成项\n- [ ] 未完成项\n- [ ] 带子任务的项\n  - [x] 子任务 A\n  - [ ] 子任务 B\n', 'claim', (res) => {
    const it = blocks(res, K.ListItem);
    const done = it.filter((b) => b.task === T.Done).length;
    const todo = it.filter((b) => b.task === T.Todo).length;
    return (done === 2 && todo === 3) ? true : '勾选 ' + done + ' / 未勾 ' + todo + '（期望 2/3）';
  });
probe('§2.4', '定义列表（术语 + 多条 : 定义）',
  'Markdown\n:   轻量级标记语言。\n:   2004 年发布。\n\nCommonMark\n:   标准化规范。\n', 'claim', (res) => {
    const it = blocks(res, K.ListItem).filter((b) => b.marker.length === 0);
    if (it.length !== 3) { return '空 marker 的定义项 ' + it.length + ' 条（期望 3）'; }
    return true;
  });
probe('§2.5', '脚注引用 + 定义', '扩展能力丰富[^note1]，另一种[^note2]。\n\n[^note1]: 第一条。\n[^note2]: 第二条含 **粗体**。\n',
  'claim', (res) => {
    const ref = withKind(res, I.FootnoteRef);
    if (ref.length !== 2) { return '脚注引用 ' + ref.length + ' 个（期望 2）'; }
    return res.notes.length === 2 ? true : '底部脚注 ' + res.notes.length + ' 条（期望 2）';
  });
probe('§2.5', '行内脚注 ^[...]', '行内脚注也可以这样写^[这是行内脚注，Pandoc 支持]。\n', 'known', (res) =>
  withKind(res, I.FootnoteRef).length > 0 ? true : '行内脚注没识别（按普通文本显示）');
probe('§2.6', '缩写 *[HTML]: 全称', '*[HTML]: HyperText Markup Language\n\nHTML 文档由 CSS 控制样式。\n', 'claim', (res) => {
  const t = flatText(res);
  return t.indexOf('HyperText') >= 0 ? true : '正文里没有展开全称："' + t.trim() + '"';
});
probe('§2.7', '尖括号自动链接 <https://…> / <mailto:…> / 邮箱',
  '看 <https://a.com> 与 <http://x.cn/p?q=1#f>；邮箱 <mailto:hi@example.com> 和 <a@b.com>。\n', 'claim', (res) => {
    const links = withKind(res, I.Link);
    if (links.length !== 4) { return '自动链接 ' + links.length + ' 个（期望 4）'; }
    const bad = links.filter((x) => /<>/.test(x.href) || x.href.endsWith('>') || x.href.startsWith('>'));
    if (bad.length > 0) { return 'href 里带尖括号（点了打不开）：' + JSON.stringify(bad.map((x) => x.href)); }
    if (links[0].text !== 'https://a.com') { return '链接文字含收尾符：' + JSON.stringify(links[0].text); }
    const mail = links.filter((x) => x.href.indexOf('mailto:') === 0);
    return mail.length === 2 ? true : 'mailto 前缀缺（' + JSON.stringify(links.map((x) => x.href)) + '）';
  });
probe('§2.7', '裸 URL 自动链接（后面紧跟中文标点也要正确收尾）',
  '参考 https://commonmark.org 与 www 无关；再看 http://a.com/x(y) 收尾。\n', 'claim', (res) => {
    const links = withKind(res, I.Link);
    return links.length >= 1 && links[0].href === 'https://commonmark.org' ? true
      : 'href=' + JSON.stringify(links.map((x) => x.href));
  });
probe('§2.7', '不是链接的尖括号内容不许变身（<b>、<img …>、<not a link>）',
  '假的 <not a link> 与 <b>粗</b> 还有 <img src="a.png" alt="x">\n', 'claim', (res) => {
    const links = withKind(res, I.Link);
    return links.length === 0 ? true : '被误判成链接：' + JSON.stringify(links.map((x) => x.href));
  });

// ════ §3 表格 ════
probe('§3.1', '对齐语法 + 单元格内联 + 转义管道',
  '| 能力 | 语法 | 支持度 | 示例 |\n|:-----|:----:|-----:|------|\n| 左对齐 | `:---` | ✅ | **粗体** |\n| 转义管道 | `a \\| b` | ✅ | [规范](https://x.com) |\n',
  'claim', (res) => {
    const tb = blocks(res, K.Table);
    if (tb.length !== 1) { return '表格 ' + tb.length + ' 张（期望 1）'; }
    const rows = tb[0].rows;
    if (tb[0].aligns.length !== 4) { return '列对齐 ' + tb[0].aligns.length + ' 项（期望 4）'; }
    if (rows.length !== 3) { return '行数 ' + rows.length + '（期望 3）'; }
    const cellText = (r, c) => (r.cells[c] || []).map((x) => x.text).join('');
    if (rows[0].cells.length !== 4 || rows[1].cells.length !== 4) {
      return '表头 / 首行数据列数 ' + rows[0].cells.length + ' / ' + rows[1].cells.length;
    }
    if (cellText(rows[1], 3).indexOf('粗体') < 0) { return '单元格里的 **粗体** 丢了'; }
    if (rows[2].cells.length !== 4) {
      return '`a \\| b` 里的转义管道被当列分隔符，那一行裂成 ' + rows[2].cells.length + ' 格（应 4 格）';
    }
    if (cellText(rows[2], 1).indexOf('a | b') < 0) {
      return '单元格里没还原出字面竖线："' + cellText(rows[2], 1) + '"';
    }
    return true;
  });
probe('§13', '表格里用 HTML 实体 &#124; 表示竖线',
  '| a | b |\n|---|---|\n| `x &#124; y` | 尾 |\n', 'known', (res) => {
    const tb = blocks(res, K.Table);
    return (tb.length === 1 && tb[0].rows[1].cells.length === 2) ? true
      : '&#124; 没当竖线处理，列被裂开';
  });
probe('§3.2', 'HTML 表格 colspan / rowspan / colgroup',
  '<table>\n  <colgroup><col style="width:40%"></colgroup>\n  <thead><tr><th colspan="2">合并表头</th><th>单列</th></tr></thead>\n  <tbody><tr><td rowspan="2">纵向合并<br>（rowspan=2）</td><td>A</td></tr></tbody>\n</table>\n',
  'claim', (res) => {
    const ch = blocks(res, K.Chart);
    if (ch.length !== 1 || ch[0].lang !== 'html') { return '没走块级 HTML（block kinds=' + JSON.stringify(res.blocks.map((b) => b.kind)) + ')'; }
    const src = ch[0].codeLines.join('\n');
    if (src.indexOf('colspan="2"') < 0 || src.indexOf('rowspan="2"') < 0) { return '合并单元格属性被吃掉'; }
    return true;
  });

// ════ §4 代码块 ════
probe('§4.1', '带语言标识的围栏', '```python\nprint("hi")  # 注释\n```\n', 'claim', (res) => {
  const c = blocks(res, K.Code);
  return c.length === 1 && c[0].lang === 'python' ? true : 'lang="' + (c[0] ? c[0].lang : '?') + '"';
});
probe('§4.2', 'diff 差异块', '```diff\n+ 新增行\n- 删除行\n@@ -1,3 +1,4 @@\n```\n', 'claim', (res) => {
  const c = blocks(res, K.Code);
  return c.length === 1 && c[0].lang === 'diff' ? true : 'lang="' + (c[0] ? c[0].lang : '?') + '"';
});
probe('§4.3', '指定行高亮 ```js{1,3-5}（不带空格，VitePress / Shiki 写法）',
  '```js{1,3-5}\nlet a=1;\nmd.use(a);\nmd.use(b);\nmd.use(c);\nmd.use(d);\n```\n', 'claim', (res) => {
    const c = blocks(res, K.Code);
    if (c.length !== 1) { return '代码块 ' + c.length + ' 个'; }
    if (c[0].lang !== 'js') { return 'lang 被污染成 "' + c[0].lang + '"（语法高亮会整块失效）'; }
    const hl = c[0].hlLines || [];
    return hl.join(',') === '1,3,4,5' ? true : 'hlLines=' + JSON.stringify(hl) + '，应为 [1,3,4,5]';
  });
probe('§4.3', '指定行高亮 ```js {1,3}（带空格）', '```js {1,3}\nlet a=1;\nlet b=2;\nlet c=3;\n```\n', 'claim', (res) => {
  const c = blocks(res, K.Code);
  if (c.length !== 1 || c[0].lang !== 'js') { return 'lang="' + (c[0] ? c[0].lang : '?') + '"'; }
  const hl = c[0].hlLines || [];
  return hl.join(',') === '1,3' ? true : 'hlLines=' + JSON.stringify(hl);
});
probe('§4.3', '指定行高亮 hl_lines="1 3"（Python-Markdown 写法）',
  '```python hl_lines="1 3"\nx = 1\ny = 2\nz = 3\n```\n', 'claim', (res) => {
    const c = blocks(res, K.Code);
    if (c.length !== 1 || c[0].lang !== 'python') { return 'lang="' + (c[0] ? c[0].lang : '?') + '"'; }
    const hl = c[0].hlLines || [];
    return hl.join(',') === '1,3' ? true : 'hlLines=' + JSON.stringify(hl);
  });
probe('§4.3', '行内注释标记 // [!code highlight]', '```js\nconst a = 1; // [!code highlight]\nconst b = 2;\n```\n', 'known', (res) => {
  const c = blocks(res, K.Code);
  const hl = (c[0] || {}).hlLines || [];
  return hl.length > 0 ? true : '注释式行高亮不识别';
});
probe('§4.4', '代码组 ::: code-group',
  '::: code-group\n\n```bash [npm]\nnpm i x\n```\n\n```bash [pnpm]\npnpm add x\n```\n\n:::\n', 'claim', (res) => {
    const g = blocks(res, K.CodeGroup);
    if (g.length !== 1) { return 'CodeGroup ' + g.length + ' 个（期望 1）'; }
    const codes = g[0].groupCodes || [];
    if (codes.length !== 2) { return '组内代码段 ' + codes.length + ' 段（期望 2）'; }
    return (codes[0].label === 'npm' && codes[0].lang === 'bash') ? true
      : '页签名/语言没拿到：' + JSON.stringify(codes[0]);
  });
probe('§4.5', '段落 + 空行 + 缩进 是代码（不能当段落的惰性续行）',
  '段落文字。\n\n    indented();\n    code();\n\n普通段落。\n', 'claim', (res) => {
    const c = blocks(res, K.Code);
    if (c.length !== 1) { return '代码块 ' + c.length + ' 个（期望 1）'; }
    if (c[0].code.indexOf('\n') < 0) { return '两行缩进被并成一行：' + JSON.stringify(c[0].code); }
    return blocks(res, K.Paragraph).length === 2 ? true
      : '段落数 ' + blocks(res, K.Paragraph).length + '（期望 2：前后各一）';
  });
probe('§4.5', '紧跟段落的缩进行仍是惰性续行（CommonMark）',
  '段落第一行\n    这是续行，不是代码\n', 'claim', (res) =>
    blocks(res, K.Code).length === 0 && blocks(res, K.Paragraph).length === 1 ? true
      : '缩进续行被误收成代码块');
probe('§2.2', '松散嵌套列表（父项后空行，子项缩进 8 空格）不失层级',
  '- 父项\n\n        - 子项\n- 另一个父项\n', 'claim', (res) => {
    const it = blocks(res, K.ListItem);
    if (it.length !== 3) { return '列表项 ' + it.length + ' 个（期望 3）'; }
    return it.some((b) => b.indent >= 1) ? true : '嵌套层级被缩进代码分支吞掉，层级=' + JSON.stringify(it.map((b) => b.indent));
  });

// ════ §5 数学 ════
probe('§5.1', '行内公式 $...$', '质能方程 $E = mc^2$；条件概率 $P(A \\mid B)$。\n', 'claim', (res) =>
  withKind(res, I.MathInline).length >= 2 ? true : 'MathInline 片段不足');
probe('§5.2 / §5.4', '块级公式（含 aligned / pmatrix / cases）',
  '$$\n\\begin{aligned}\na &= b \\\\\nc &= d\n\\end{aligned}\n$$\n\n$$\nA=\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}\n$$\n', 'claim', (res) =>
    blocks(res, K.Math).length === 2 ? true : 'Math 块 ' + blocks(res, K.Math).length + ' 个（期望 2）');
probe('§5.7', '化学方程式 \\ce{}（mhchem）', '$$\\ce{2H2 + O2 ->[点燃] 2H2O}$$\n', 'claim', (res) =>
  blocks(res, K.Math).length === 1 ? true : '化学式块没识别为 Math');

// ════ §6 图表引擎 ════
const CHARTS = [
  ['mermaid', '6.17 packet', '```mermaid\npacket-beta\n0-7: "版本"\n```\n'],
  ['mermaid', '6.18 kanban', '```mermaid\nkanban\n  Todo\n    Write table\n```\n'],
  ['mermaid', '6.19 architecture', '```mermaid\narchitecture-beta\n  group api(cloud)[API]\n```\n'],
  ['graphviz', '6.22 dot', '```graphviz\ndigraph G { a -> b }\n```\n'],
  ['nomnoml', '6.26', '```nomnoml\n[A] -> [B]\n```\n'],
  ['echarts', '6.27', '```echarts\n{"series":[]}\n```\n'],
  ['wavedrom', '6.23', '```wavedrom\n{signal:[{name:"clk",wave:"p..."}]}\n```\n'],
  ['abc', '6.24', '```abc\nX:1\nK:G\nG3D|G3D|\n```\n'],
  ['markmap', '6.25', '```markmap\n# root\n## child\n```\n'],
  ['vega', '6.26 Vega-Lite（vega-lite / vl 别名）', '```vega-lite\n{"data":{"values":[{"a":1}]},"mark":"bar"}\n```\n'],
  ['plantuml', '6.21 PlantUML 时序图（离线内核原生渲染，源码不桥）', '```plantuml\n@startuml\nA -> B : hi\n@enduml\n```\n'],
  ['mermaid', '5.30 ZenUML 写在 mermaid 围栏里 → 转译成 mermaid 时序图（不再走外部插件，'
   + '插件与随包 mermaid 11.17.2 约定错位会画 Syntax error）',
   '```mermaid\nzenuml\n    title Flow\n    User->App: open()\n```\n'],
  ['mermaid', '5.30 ZenUML 直接把语言名当围栏（```zenuml）同样转译',
   '```zenuml\nzenuml\n    Alice->Bob: hi\n```\n'],
  ['mermaid', '5.30 反向检查：普通 mermaid 块不许被认成 zenuml',
   '```mermaid\ngraph TD\n  A[开始] --> B[结束]\n```\n'],
  ['mermaid', '5.30 反向检查：注释行开头 + 正文里出现 zenuml 字样不算 zenuml',
   '```mermaid\n%% zenuml 的说明\ngraph TD\n  A[zenuml 字样在标签里] --> B[结束]\n```\n'],
];
for (const [lang, sec, src] of CHARTS) {
  probe('§6 ' + sec, lang + ' 进图表通道', src, 'claim', (res) => {
    const ch = blocks(res, K.Chart);
    return (ch.length === 1 && ch[0].lang === lang) ? true
      : '没进 Chart（kind 序列 ' + JSON.stringify(res.blocks.map((b) => b.kind)) + '）';
  });
}
// PlantUML 路由（2026-10-14 起）：**阅读侧**交给离线内核 @plantuml/core（lang=plantuml + 原文），
// 内核没有渲染器的六个图种才分流；**导出侧**才用 PlantumlBridge 桥成 mermaid。
// 所以这里两层都要钉：路由层判"落到哪条通道、源码有没有被改写"，桥层判"桥成哪种图 /
// 桥不动的有没有硬转"（状态图曾被塞进 sequenceDiagram → mermaid 报 Parse error，用户实测）。
const PUML_ROUTE = [
  ['@startuml\nclass Foo {\n  +bar()\n}\nFoo <|-- Bar\n@enduml\n', 'chart:plantuml',
   '类图交给离线内核（源码原样，不再在解析层改写成 mermaid）'],
  ['@startuml\nstart\n:写文档;\nstop\n@enduml\n', 'chart:plantuml',
   '活动图交给离线内核（内核实测画得出，以前只会留源码）'],
  ['@startuml\nactor 用户\n(查看文档) as U1\n用户 --> U1\n@enduml\n', 'chart:plantuml',
   '用例图交给离线内核'],
  ['@startmindmap\n* A\n** B\n@endmindmap\n', 'chart:plantuml', '脑图 @startmindmap 进内核'],
  ['@startwbs\n* A\n** B\n@endwbs\n', 'chart:plantuml', 'WBS @startwbs 进内核'],
  ['@startgantt\n[T] lasts 2 days\n@endgantt\n', 'chart:plantuml', '甘特 @startgantt 进内核'],
  ['@startjson\n{"a":1}\n@endjson\n', 'chart:plantuml', 'JSON 可视化 @startjson 进内核'],
  ['@startyaml\na: 1\n@endyaml\n', 'chart:plantuml', 'YAML 可视化 @startyaml 进内核'],
  ['@startmath\nE = mc^2\n@endmath\n', 'math',
   '数学公式内核没有渲染器 → 转块级公式（KaTeX 链路）'],
  ['@starttimeline\n2004 : born\n2014 : commonmark\n@endtimeline\n', 'chart:mermaid',
   '时间线内核没有渲染器 → 桥成 mermaid timeline'],
  ['@startfiles\n* entry\n  * src\n    * main\n      * ets\n      * resources\n@endfiles\n', 'code:filetree',
   '文件树内核没有渲染器 → 制表符树（代码块，离线也能看）'],
  ['@startsalt\n{+[OK]|[Cancel]}\n@endsalt\n', 'chart:salt',
   '盐图 → render/salt.html 画 HTML 线框（内核无渲染器，不再留源码）'],
  ['@startnwdiag\nnetwork L {\n  device [address = "10.0.0.1"]\n}\n@endnwdiag\n', 'chart:nwdiag',
   'nwdiag → render/nwdiag.html 直排网络分组（不再桥 mermaid：真机只画出一个"1"）'],
  ['@startditaa\n+--+\n| X |\n+--+\n@endditaa\n', 'chart:ditaa',
   'ditaa → render/ditaa.html 画 SVG 方框'],
];
for (const [body, want, title] of PUML_ROUTE) {
  probe('§6.21', title, '```plantuml\n' + body + '```', 'claim', (res) => {
    const kindSeq = JSON.stringify(res.blocks.map((b) => b.kind));
    if (want === 'math') {
      const m = blocks(res, K.Math);
      return (m.length === 1 && m[0].code.indexOf('E = mc^2') >= 0) ? true
        : '没转成公式块（kind 序列 ' + kindSeq + '）';
    }
    if (want === 'chart:mermaid') {
      const ch = blocks(res, K.Chart);
      return (ch.length === 1 && ch[0].lang === 'mermaid'
        && ch[0].code.split('\n')[0].trim() === 'timeline') ? true
        : '桥成了 ' + (ch[0] ? ch[0].lang + '/' + ch[0].code.split('\n')[0] : '无') + '，期望 mermaid/timeline';
    }
    if (want === 'code:filetree') {
      const cd = blocks(res, K.Code);
      const tree = cd.length === 1 ? cd[0].code : '';
      // 期望形状（缩进写法 + 单星号，用户文档 6.20 原样）：层级全在制表符里
      const shape = ['entry', '└── src', '    └── main', '        ├── ets', '        └── resources'].join('\n');
      return (cd.length === 1 && cd[0].lang === 'filetree' && tree === shape) ? true
        : '没转成制表符树（kind 序列 ' + kindSeq + '）：\n' + tree;
    }
    if (want === 'code:plantuml') {
      const cd = blocks(res, K.Code);
      return (cd.length === 1 && cd[0].lang === 'plantuml') ? true
        : '没留成源码代码块（kind 序列 ' + kindSeq + '，lang=' + (cd[0] ? cd[0].lang : '?') + '）';
    }
    const ch = blocks(res, K.Chart);
    return (ch.length === 1 && ch[0].lang === want.split(':')[1]
      && ch[0].code.indexOf(body.split('\n')[0]) >= 0) ? true
      : '期望 Chart/' + want.split(':')[1] + ' + 原文，实际 '
        + (ch[0] ? ch[0].lang + '：' + ch[0].code.split('\n')[0] : '没有图表块（' + kindSeq + '）');
  });
}
// ZenUML 转译（2026-10-14 起）：插件路线废弃，改纯文本译成 mermaid 时序图。
// 断言"首行是 sequenceDiagram"且"消息被译出来"——只判 lang 会漏掉"转成空图"。
const ZENUML_ROUTE = [
  ['```mermaid\nzenuml\n  title 登录\n  Alice -> Bob: 请求\n  Bob -> Alice: 回复\n```\n',
   'Alice->>Bob: 请求', 'ZenUML 消息 → mermaid 时序消息'],
  ['```mermaid\nzenuml\n  Alice.login() {\n    Bob.verify()\n    return ok\n  }\n```\n',
   'Bob: verify()', 'ZenUML 调用块 → 发起者到被调者的消息'],
  ['```mermaid\nzenuml\n  A -> B: hi\n  if (cache hit) {\n    B -> A: 命中\n  }\n```\n',
   'alt cache hit', 'ZenUML if → mermaid alt（sequenceDiagram 没有 if 关键字）'],
];
for (const [src, needle, title] of ZENUML_ROUTE) {
  probe('§5.30', title, src, 'claim', (res) => {
    const ch = blocks(res, K.Chart);
    if (ch.length !== 1 || ch[0].lang !== 'mermaid') {
      return '没转成 mermaid 图表块（' + JSON.stringify(res.blocks.map((b) => b.kind)) + '）';
    }
    const first = ch[0].code.split('\n')[0].trim();
    if (first !== 'sequenceDiagram') {
      return '首行不是 sequenceDiagram，实际 ' + first;
    }
    return ch[0].code.indexOf(needle) >= 0 ? true : '译文里找不到「' + needle + '」：\n' + ch[0].code;
  });
}

// ZenUML 转译桥：判"翻出来的 mermaid 形状对不对"。这些形状每一条都对应一个真踩过的坑：
// 标识符只认 ASCII 时中文参与者整条不匹配（→ 空串 → 退回代码块）；
// 虚线箭头 `-->` 被贪心标识符吞成 `App-` 幻影参与者；
// 花括号容器不补 end / mermaid 没有的 group 只丢开头 → 孤儿 end → mermaid 语法错。
// 产物能否真被 mermaid 画出来，另用 .workbuddy/check-zen-mermaid.js 在浏览器里逐例验。
const ZENUML = [
  ['zenuml\n    title 流程\n    @Actor 读者\n    读者->App.open()\n    App-->读者: 渲染完成',
   ['actor 读者', '读者->>App: open()', 'App-->>读者: 渲染完成'],
   '中文参与者能翻（@Actor → actor，--> 走虚线 -->>）'],
  ['zenuml\n    User->App.login()\n    group 批量导入\n      App->Store.import(files)\n    end',
   ['User->>App: login()', 'App->>Store: import()'],
   'mermaid 没有的 group：整块连 end 一起丢（产物里不许出现 end）'],
  ['zenuml\n    A->B: hi\n    if (有公式) {\n      B->C: katex\n    }',
   ['alt 有公式', 'B->>C: katex', 'end'],
   'if{} → alt，`}` 必须补 end（否则孤儿 alt 不闭合，mermaid 直接语法错）'],
  ['zenuml\n    Alice->Bob.check() {\n      Bob->Db: query\n      return rows\n    }\n    return ok',
   ['Alice->>Bob: check()', 'Bob-->>Alice: rows', 'Bob-->>Alice: ok'],
   '调用块的 return 回给**发起者**（以前 callerOf 找不到调用方，两条 return 都写成 Bob-->>Bob）'],
  ['zenuml\n    A->B: hi\n    end', ['A->>B: hi'],
   '孤立 end 不许透传（没有开过容器就没有 end）'],
];
for (const [body, need, title] of ZENUML) {
  probe('§5.30', title, '', 'claim', () => {
    const got = ZenumlBridge.toMermaid(body);
    if (got.length === 0) { return '桥出了空（等于退回代码块）'; }
    const miss = need.filter((s) => got.indexOf(s) < 0);
    if (miss.length > 0) { return '缺 ' + JSON.stringify(miss) + '，实际：\n' + got; }
    if (title.indexOf('不许出现 end') >= 0 || title.indexOf('整块连 end 一起丢') >= 0) {
      const orphan = got.split('\n').some((l) => l.trim() === 'end');
      if (orphan && need.indexOf('end') < 0) { return '出现孤儿 end：\n' + got; }
    }
    return true;
  });
}

const PUML_BRIDGE = [
  ['@startuml\n[*] --> 草稿\n草稿 --> 已发布 : 发布\n@enduml\n', 'stateDiagram-v2',
   '导出：状态图桥成 stateDiagram-v2（不能塞进 sequenceDiagram）'],
  ['@startuml\nclass Foo {\n  +bar()\n}\nclass Baz {\n  +qux()\n}\nFoo <|-- Baz\n@enduml\n', 'classDiagram',
   '导出：类图桥成 classDiagram（成员与继承不丢）'],
  ['@startuml\ninterface Runnable {\n  +run()\n}\nclass Task implements Runnable\n@enduml\n', 'classDiagram',
   '导出：带体 interface 降级成 <<interface>> 构造型（mermaid 不吃 `interface X {`）'],
  ['@startuml\nA -> B : hi\n== 阶段 ==\nB -> A : yo\n@enduml\n', 'sequenceDiagram',
   '导出：时序图 == 分隔线降级成注释（mermaid 序列图没有分隔线语法）'],
];
for (const [body, want, title] of PUML_BRIDGE) {
  probe('§6.21', title, '', 'claim', () => {
    const code = PlantumlBridge.toMermaid(body);
    if (code.length === 0) { return '桥出了空（等于导出退化成代码块）'; }
    const head = code.split('\n')[0].trim();
    return head === want ? true : '桥成了 ' + head + '，期望 ' + want + '：\n' + code;
  });
}
const PUML_NOBRIDGE = [
  ['活动图', '@startuml\nstart\n:写文档;\nstop\n@enduml\n'],
  ['用例图', '@startuml\nactor 用户\n(查看文档) as U1\n用户 --> U1\n@enduml\n'],
  ['组件图', '@startuml\n[MdParser] --> [MdView] : 块列表\n@enduml\n'],
];
for (const [name, body] of PUML_NOBRIDGE) {
  probe('§6.21', name + '导出侧不硬转（桥不动就留源码，不出坏图）', '', 'claim', () => {
    return PlantumlBridge.toMermaid(body).length === 0 ? true
      : '被硬桥成：\n' + PlantumlBridge.toMermaid(body);
  });
}

// ════ §7 容器与折叠 ════
probe('§7.1', 'GFM Alerts 五连',
  '> [!NOTE]\n> 蓝\n\n> [!TIP]\n> 绿\n\n> [!IMPORTANT]\n> 紫\n\n> [!WARNING]\n> 黄\n\n> [!CAUTION]\n> 红\n', 'claim', (res) => {
    const co = blocks(res, K.Callout).map((b) => b.callout);
    const want = [C.Note, C.Tip, C.Important, C.Warning, C.Caution];
    return co.join(',') === want.join(',') ? true : 'callout 序列 ' + JSON.stringify(co);
  });
probe('§7.2', '冒号容器 ::: tip / warning / danger / info',
  '::: tip 提示\n正文 A\n:::\n\n::: warning 注意\n正文 B\n:::\n\n::: danger 危险\n正文 C\n:::\n\n::: info 信息\n正文 D\n:::\n',
  'claim', (res) => {
    const co = blocks(res, K.Callout).length;
    const stray = flatText(res).indexOf(':::') >= 0;
    return (co >= 1 && !stray) ? true : '容器产出 callout=' + co + '，残留 :::=' + stray;
  });
probe('§7.2', '冒号容器 ::: details（折叠）', '::: details 点击展开\n清单内容\n:::\n', 'claim', (res) =>
  blocks(res, K.Details).length === 1 ? true : 'Details ' + blocks(res, K.Details).length + ' 个（期望 1）');
probe('§7.3', '原生 <details open> 带属性 summary',
  '<details open>\n<summary><b>默认展开</b></summary>\n\n正文一行。\n\n</details>\n', 'claim', (res) => {
    const d = blocks(res, K.Details);
    if (d.length !== 1) { return 'Details ' + d.length + ' 个（期望 1）'; }
    if (d[0].open !== true) { return 'open 属性没记下（导出与阅读页都不会默认展开）'; }
    if (d[0].code.indexOf('正文一行') < 0) { return '正文被拆到面板外：' + JSON.stringify(d[0].code); }
    if (flatText(res).indexOf('</details>') >= 0) { return '收尾标签漏成正文'; }
    return true;
  });
probe('§7.3', '原生 <details>（无属性）照旧可折叠',
  '<details>\n<summary>要点</summary>\n\n内容 A\n\n</details>\n', 'claim', (res) => {
    const d = blocks(res, K.Details);
    return (d.length === 1 && d[0].open !== true) ? true : 'Details ' + JSON.stringify(d.map((x) => x.open));
  });
probe('§7.4', 'pymdownx.tabbed 的 +++ 分组',
  'div.tabbed-set\n\n+++ Tab 一\n\n内容 A\n\n+++ Tab 二\n\n内容 B\n', 'known', (res) =>
    flatText(res).indexOf('+++') < 0 ? true : '+++ 语法不识别，按普通文本显示');

// ════ §8 原生 HTML ════
probe('§8.1', 'span style 彩色文本',
  '<span style="color:#e11d48;font-weight:700">红色强调</span> · <mark>原生高亮</mark> · <small>小号字</small>\n',
  'claim', (res) => {
    const c = withKind(res, I.Color);
    if (c.length === 0) { return '没有 Color 片段'; }
    if (c[0].color !== '#FFE11D48' && String(c[0].color).toUpperCase().indexOf('E11D48') < 0) {
      return '颜色解析成 "' + c[0].color + '"';
    }
    return true;
  });
probe('§8.1', '渐变背景标签（无 padding 能力，需降级不破版）',
  '<span style="background:linear-gradient(90deg,#a78bfa,#f472b6);padding:2px 8px;border-radius:4px;color:#fff">渐变标签</span>\n',
  'claim', (res) => {
    const t = flatText(res);
    return t.indexOf('渐变标签') >= 0 && t.indexOf('linear-gradient') < 0 && t.indexOf('<span') < 0
      ? true : '渐变标签退化异常："' + t.trim().slice(0, 50) + '"';
  });
probe('§8.2', 'div + progress 徽章进度条',
  '<div>\n  渲染完成度： <progress value="78" max="100"></progress> 78%\n</div>\n', 'claim', (res) => {
    const ch = blocks(res, K.Chart);
    return (ch.length === 1 && ch[0].lang === 'html' && ch[0].codeLines.join('\n').indexOf('progress') >= 0)
      ? true : '没走块级 HTML';
  });
probe('§8.3', '内嵌 SVG', '<svg width="220" height="70"><rect x="2" fill="#f8fafc"/></svg>\n', 'claim', (res) => {
  const ch = blocks(res, K.Chart);
  return (ch.length === 1 && ch[0].lang === 'html') ? true : 'SVG 没走块级 HTML';
});
probe('§8.4', 'audio / video 放行，iframe 摘除',
  '<audio controls>\n  <source src="demo.mp3" type="audio/mpeg">\n</audio>\n\n<video controls width="260"><source src="a.mp4"></video>\n\n<iframe src="https://x.com" width="280"></iframe>\n',
  'claim', (res) => {
    const html = blocks(res, K.Chart).map((b) => b.codeLines.join('\n')).join('\n');
    if (html.indexOf('<audio') < 0 || html.indexOf('<video') < 0) { return '音视频被吃掉'; }
    return html.indexOf('<iframe') < 0 ? true : 'iframe 没摘除';
  });
probe('§8.5', 'figure / figcaption 图注',
  '<figure>\n  <img src="https://x.com/a.png" alt="Logo" width="120">\n  <figcaption>图 1：带编号的图注</figcaption>\n</figure>\n',
  'claim', (res) => {
    const ch = blocks(res, K.Chart);
    return (ch.length === 1 && ch[0].codeLines.join('\n').indexOf('figcaption') >= 0) ? true : '图注没走块级 HTML';
  });
probe('§8.6', 'div style 自定义卡片里嵌 ol/code',
  '<div style="padding:12px;border-left:4px solid #6366f1;background:#f8fafc">\n  <b>自定义卡片</b>\n  <ol><li>支持 <code>属性</code></li></ol>\n</div>\n',
  'claim', (res) => blocks(res, K.Chart).length === 1 ? true : '没走块级 HTML');

// ════ §9 元信息与交叉引用 ════
probe('§9.1', 'YAML Front Matter 收进 meta',
  '---\ntitle: "总谱"\nauthor: "Yuanbao"\ntags: [markdown, mermaid]\n---\n\n# 正文\n', 'claim', (res) =>
    res.meta.length >= 3 ? true : 'meta ' + res.meta.length + ' 项（期望 ≥3）');
probe('§9.2', '自动目录 [TOC]（单独一行 → 可点跳转的条目列表）',
  '[TOC]\n\n# 甲\n\n## 甲之一\n\n# 乙\n', 'claim', (res) => {
    if (flatText(res).indexOf('[TOC]') >= 0) { return '[TOC] 还留在正文里'; }
    const it = blocks(res, K.ListItem);
    const links = withKind(res, I.Link).filter((x) => x.href.startsWith('#'));
    if (it.length !== 3) { return '目录条目 ' + it.length + ' 条（期望 3：甲 / 甲之一 / 乙）'; }
    if (links.length !== 3) { return '可点锚点链接 ' + links.length + ' 条'; }
    const lv = it.map((b) => b.indent);
    return lv.join(',') === '0,1,0' ? true : '层级按标题层级走：实际 ' + lv.join(',');
  });
probe('§9.2', '正文里的其它 [TOC] 字样不误伤（行内有别的内容就不展开）',
  '这一行 [TOC] 只是举例，不该变成目录\n\n# 标题\n', 'claim', (res) => {
    const it = blocks(res, K.ListItem);
    return (it.length === 0 && flatText(res).indexOf('[TOC]') >= 0) ? true
      : '误展开：条目 ' + it.length + ' 条，正文 "' + flatText(res) + '"';
  });
probe('§9.3', '显式锚点 <a id> + 站内跳转',
  '<a id="anchor-demo"></a>\n\n**这里埋了锚点**，用 [跳转到锚点](#anchor-demo) 可以跳。\n\n## 目标标题 {#t2}\n',
  'claim', (res) => {
    const links = withKind(res, I.Link).map((x) => x.href);
    const h = blocks(res, K.Heading);
    const anchored = h.filter((b) => (b.anchor || '').length > 0).length;
    return (links.indexOf('#anchor-demo') >= 0 && anchored === 1) ? true
      : '站内链接 ' + JSON.stringify(links) + '，带 id 的标题 ' + anchored + ' 个';
  });
probe('§3.6', '插入线 ++文字++（markdown-it-ins）', '++这段文字被插入++ 与 ==高亮== 与 `+ +` 共存\n', 'claim', (res) => {
  const u = withKind(res, I.Under);
  if (u.length !== 1 || u[0].text !== '这段文字被插入') { return '没收成 Under：' + JSON.stringify(u.map((x) => x.text)); }
  if (withKind(res, I.Mark).length !== 1) { return '把 ==高亮== 弄坏了'; }
  const t = flatText(res);
  return t.indexOf('+ +') >= 0 ? true : '行内代码里的加号被误吞：' + t;
});
probe('§3.10', '图片尺寸 `![a](x.png =120x60)`（imsize）', '![logo](a.png =120x60)\n\n![b](b.png "标题")\n', 'claim', (res) => {
  const imgs = allInlines(res).filter((x) => x.kind === I.Image);
  if (imgs.length !== 2) { return '图片数 ' + imgs.length; }
  if (imgs[0].w !== 120 || imgs[0].h !== 60) { return 'imsize 没落地：' + JSON.stringify([imgs[0].w, imgs[0].h]); }
  if (imgs[1].w !== undefined || imgs[1].h !== undefined) { return '普通图片被误加了尺寸'; }
  return imgs[1].href === 'b.png' ? true : '带 title 的地址解析坏了：' + imgs[1].href;
});
probe('§3.15', '双花括号锚点 `## 标题 {{#id}}`（Typora / VS Code 写法）',
  '## 甲节 {{#sec-a}}\n\n[跳过去](#sec-a)\n', 'claim', (res) => {
    const h = blocks(res, K.Heading);
    if (h.length !== 1 || (h[0].anchor || '') !== 'sec-a') { return 'anchor=' + (h[0] ? h[0].anchor : '无'); }
    if (flatText(res).indexOf('{{#') >= 0) { return '双花括号还留在正文里'; }
    return withKind(res, I.Link).some((x) => x.href === '#sec-a') ? true : '站内跳转链接丢了';
  });
probe('§9.4', 'Pandoc 属性块：标题多属性 / 围栏 div / 行内 span / 图片属性',
  '## 背景 {#bg .unnumbered}\n\n::: {#note1 .tip}\n正文 A\n:::\n\n'
  + '普通 [重点]{.bold color=#2F63E8} 结尾\n\n![示意](flow.png){#fig:flow width=60%}\n', 'claim', (res) => {
    const hs = blocks(res, K.Heading);
    const co = blocks(res, K.Callout);
    const t = flatText(res);
    if (hs.length !== 1 || (hs[0].anchor || '') !== 'bg') { return '标题属性块没吃掉：anchor=' + (hs[0] ? hs[0].anchor : '无'); }
    if (co.length !== 1 || (co[0].anchor || '') !== 'note1') { return '围栏 div 的 id 没落地'; }
    if (t.indexOf('{#bg') >= 0 || t.indexOf('{#note1') >= 0 || t.indexOf('{.bold') >= 0 || t.indexOf('{#fig:flow') >= 0) {
      return '花括号仍显示在正文：' + t.trim().slice(0, 70);
    }
    const hit = allInlines(res).find((x) => x.text === '重点');
    if (!hit || hit.bold !== true || (hit.color || '').toUpperCase() !== '#2F63E8') {
      return '[文字]{属性} 没变成带样式的片段：' + JSON.stringify(hit);
    }
    if (hit.kind !== I.Color) { return '有色值却没走 Color 通道（导出侧按 kind 分派，Plain 上的 color 会被丢掉）'; }
    return true;
  });
probe('§9.4', 'Pandoc 图表编号组件已按用户要求移除：{#fig:x} 只吃花括号，@fig:x 与图注保持原样',
  '![示意](flow.png){#fig:flow width=60%}\n\n如图 @fig:flow 所示。\n', 'claim', (res) => {
    const t = flatText(res);
    if (t.indexOf('{#fig:flow') >= 0) {
      return '花括号没被吃掉："' + t.trim().slice(0, 60) + '"';
    }
    return (t.indexOf('@fig:flow') >= 0 && t.indexOf('示意') >= 0)
      ? true : '标记被改写了："' + t.trim().slice(0, 60) + '"';
  });
probe('§9.4', '不是属性块的花括号不误吞（`# 集合 { x }`、`[文字] { 三个词 }`）',
  '# 集合 { x }\n\n这里有 [文字] { 三个词 } 收尾。\n', 'claim', (res) => {
    const t = flatText(res);
    return (t.indexOf('{ x }') >= 0 && t.indexOf('{ 三个词 }') >= 0)
      ? true : '普通花括号被吃掉了：' + t.trim();
  });

// ════ §10 MDX ════
// MDX 子集（2026-10-14 起）：import 丢弃；<Chart> 转真图表；<Tabs>/<TabItem> 转标签组；
// 认不出的组件保留名字并渲染其内容。JSX 本体的"运行组件"仍需构建期编译，这里只做
// 能静态翻译的那部分（别再退回"整段按源码显示"）。
probe('§10', 'MDX：<Chart data={[...]} type="bar" /> 转成 chart 图表块',
  '```mdx\nimport { Chart } from "./Chart"\n\n# 用 MDX 写文档\n\n<Chart data={[1, 2, 3]} type="bar" />\n```\n',
  'claim', (res) => {
    const ch = blocks(res, K.Chart);
    if (ch.length !== 1 || ch[0].lang !== 'chart') {
      return '没转成 chart（kind 序列 ' + JSON.stringify(res.blocks.map((b) => b.kind)) + '）';
    }
    if (ch[0].code.indexOf('"type":"bar"') < 0 || ch[0].code.indexOf('"data":[1,2,3]') < 0) {
      return 'chart 配置不对：' + ch[0].code;
    }
    const hs = blocks(res, K.Heading);
    return hs.length === 1 ? true : '正文标题没保留';
  });
probe('§10', 'MDX：<Tabs>/<TabItem> 转标签组（CodeGroup），import 不显示',
  '```mdx\nimport Tabs from "@theme/Tabs"\n\n<Tabs>\n  <TabItem value="js">JS 内容</TabItem>\n  <TabItem value="py">Python 内容</TabItem>\n</Tabs>\n```\n',
  'claim', (res) => {
    const cg = blocks(res, K.CodeGroup);
    if (cg.length !== 1) {
      return '没转成标签组（kind 序列 ' + JSON.stringify(res.blocks.map((b) => b.kind)) + '）';
    }
    const t = flatText(res);
    if (t.indexOf('import') >= 0) {
      return 'import 行没被丢弃';
    }
    return cg[0].groupCodes.length === 2 ? true : '页签数量不对：' + cg[0].groupCodes.length;
  });
probe('§10', 'MDX：认不出的组件保留组件名 + 渲染其内容（不静默吞掉）',
  '```mdx\n<MyCard title="x">卡片正文</MyCard>\n```\n', 'claim', (res) => {
    const t = flatText(res);
    return (t.indexOf('MyCard') >= 0 && t.indexOf('卡片正文') >= 0)
      ? true : '组件内容/名字丢了："' + t.trim().slice(0, 60) + '"';
  });

// ════ §13 常见坑 ════
probe('§13', '段内两空格硬换行', '第一行  \n第二行\n', 'known', (res) =>
  /第一行\n第二行/.test(flatText(res)) ? true : '硬换行被并成空格（矩阵已标 ❌）');

// ════ 导出侧同步（真解析器管不到 MdToHtml，这里按源码字节核）════
(function exportSync() {
  const html = fs.readFileSync(path.join(MD, 'MdToHtml.ets'), 'utf8').replace(/\r\n/g, '\n');
  const probes2 = [
    ['指定行高亮导出侧有 .hl 行底', /hl\.indexOf\(k \+ 1\) >= 0/.test(html) && /\.hl \{[^}]*rgba\(245,158,11/.test(html)],
    ['代码族解析仍走 resolveFamily（改 codeBlock 签名时别把高亮链路带断）',
      /resolveFamily\(lang\)/.test(html)],
    ['折叠面板导出侧仍是能开合的 <details>（漏掉这条分支的话整块内容凭空消失）',
      /block\.kind === MdBlockKind\.Details/.test(html) && /'<details' \+ \(block\.open === true \? ' open' : ''\)/.test(html)],
    ['代码组导出侧按段退化（静态网页没页签脚本，但一段都不能丢）',
      /block\.kind === MdBlockKind\.CodeGroup/.test(html) && /grouplabel/.test(html)],
  ];
  for (const [label, ok] of probes2) {
    if (ok) { console.log('  ok    导出侧 ' + label); }
    else {
      fails++;
      console.log('  FAIL  导出侧 ' + label);
      gaps.push('导出侧 ' + label);
    }
  }
})();

probe('§13', 'HTML 字符实体解码（&amp; &lt; &#124; &#8212;）',
  'A &amp; B、&lt;tag&gt;、竖线 &#124; 与长破折号 &#8212;、命名 &mdash;\n', 'claim', (res) => {
    const t = flatText(res);
    const want = ['A & B', '<tag>', '|', '—'];
    for (const w of want) {
      if (t.indexOf(w) < 0) { return '"' + w + '" 没解出来，实际是 "' + t + '"'; }
    }
    return t.indexOf('&amp;') < 0 ? true : '&amp; 原样留着';
  });
probe('§13', '正文里孤立的 & 不被误吞（AT&T、R&D）', 'AT&T 与 R&D 还有 &xyz 不是实体\n', 'claim', (res) =>
  flatText(res) === 'AT&T 与 R&D 还有 &xyz 不是实体' ? true : '实际：' + JSON.stringify(flatText(res)));
probe('§13', '行内代码里的实体保持字面', '写 HTML 时用 `&amp;` 表示 &\n', 'claim', (res) => {
  const code = withKind(res, I.Code);
  return (code.length === 1 && code[0].text === '&amp;') ? true
    : '行内代码被解码成 "' + (code[0] ? code[0].text : '?') + '"';
});

probe('§6.22', '别名围栏也进图表通道（```dot / ```gv = graphviz，```chartjs = chart，```puml = 离线内核）',
  '```dot\ndigraph G { a -> b }\n```\n\n```gv\ndigraph H { c -> d }\n```\n\n```chartjs\n{"type":"bar"}\n```\n\n```puml\n@startuml\nA -> B : hi\n@enduml\n```\n',
  'claim', (res) => {
    const ch = blocks(res, K.Chart).map((b) => b.lang);
    const want = ['graphviz', 'graphviz', 'chart', 'plantuml'];
    return ch.join(',') === want.join(',') ? true : '图表通道拿到 ' + JSON.stringify(ch) + '，期望 ' + JSON.stringify(want);
  });

probe('§8.1', 'span 的 font-weight 与背景色（不只认字色）',
  '<span style="color:#e11d48;font-weight:700">红色强调</span> · '
  + '<span style="background-color:#eef1f6;color:#1b1f27">浅底深字的徽章</span>\n', 'claim', (res) => {
    const all = allInlines(res);
    const red = all.filter((x) => (x.color === undefined ? '' : x.color).toUpperCase().indexOf('E11D48') >= 0);
    if (red.length === 0) { return '红色没认出来'; }
    if (!red.every((x) => x.bold === true)) { return 'font-weight:700 没落到 bold 上'; }
    const badge = all.filter((x) => (x.bg === undefined ? '' : x.bg).toUpperCase().indexOf('EEF1F6') >= 0);
    if (badge.length === 0) { return 'background-color 没登记为底色'; }
    const wrong = badge.filter((x) => (x.color === undefined ? '' : x.color).toUpperCase().indexOf('EEF1F6') >= 0);
    if (wrong.length > 0) { return '把 background-color 当成文字颜色了（旧 bug）'; }
    const dark = badge.filter((x) => (x.color === undefined ? '' : x.color).toUpperCase().indexOf('1B1F27') >= 0);
    return dark.length === badge.length ? true : '底色那块自己的文字颜色丢了';
  });
probe('§8.1', '渐变背景降成第一个色标的实心近似底（不再"没底"→ 白字白底看不见）',
  '<span style="background:linear-gradient(90deg,#a78bfa,#f472b6);color:#fff">渐变标签</span>\n', 'claim', (res) => {
    const all = allInlines(res);
    const withBg = all.filter((x) => (x.bg === undefined ? '' : x.bg).length > 0);
    // 政策改过来的那一条：以前"渐变画不出来就干脆没底"，可这类写法几乎总把字色设成白色，
    // 底一丢 = 白字白底整块看不见（用户实测 8.1「渐变标签」消失）。现在取首个色标兜底。
    if (withBg.length === 0) { return '渐变没兜底：白字白底会整块看不见'; }
    if ((withBg[0].bg || '').toUpperCase() !== '#A78BFA') { return '没取第一个色标：' + withBg[0].bg; }
    return true;
  });
probe('§8.1', 'url() 背景仍然丢（画不出也不瞎兜一个色）',
  '<span style="background:url(a.png);color:#123456">图片底</span>\n', 'claim', (res) => {
    const withBg = allInlines(res).filter((x) => (x.bg === undefined ? '' : x.bg).length > 0);
    return withBg.length === 0 ? true : 'url() 被当成色值兜底了：' + JSON.stringify(withBg.map((x) => x.bg));
  });
probe('§8.1', '<small> 与 font-size:em/% 走相对字号通道',
  '<small>小号字</small> <span style="font-size:1.4em">大字</span> <span style="font-size:12px">像素</span>\n',
  'claim', (res) => {
    const all = allInlines(res);
    const small = all.find((x) => x.text === '小号字');
    const big = all.find((x) => x.text === '大字');
    const px = all.find((x) => x.text === '像素');
    if (!small || small.size !== 0.82) { return '<small> 没拿到相对字号：' + JSON.stringify(small); }
    if (!big || big.size !== 1.4) { return 'font-size:1.4em 没落地：' + JSON.stringify(big); }
    // px 刻意不接：写死像素会让这段在用户放大字号后与正文脱节
    if (!px || px.size !== undefined) { return 'px 字号不该被接受：' + JSON.stringify(px); }
    return true;
  });
probe('§7.3', '折叠面板正文连空行按原样收，行号能对上原文（勾选要写回这一行）',
  '<details>\n<summary>清单</summary>\n\n- [x] 甲\n- [ ] 乙\n\n</details>\n', 'claim', (res) => {
    const d = blocks(res, K.Details);
    if (d.length !== 1) { return '没收成 Details'; }
    const b = d[0];
    if ((b.codeLines || []).length !== 4) { return '正文行数 ' + ((b.codeLines || []).length) + '（空行被丢了）'; }
    // 行号口径与 DocStore 的 lines[] 一致：**0 起**（orig() 给的就是 0 起）
    if (b.bodyStart === undefined || b.bodyStart !== 2) { return 'bodyStart=' + b.bodyStart + '，对不上原文行号'; }
    return true;
  });

console.log('');
console.log(gaps.length === 0
  ? 'COVERAGE OK — 真解析器逐条实测通过（known 档 ' + knownFails + ' 条为已标注降级）'
  : 'COVERAGE GAPS: ' + fails + ' 条 claim 档失败');
if (fails > 0) {
  console.log('真缺口清单：');
  for (const g of gaps) { console.log('  · ' + g); }
}
process.exit(fails === 0 ? 0 : 1);
