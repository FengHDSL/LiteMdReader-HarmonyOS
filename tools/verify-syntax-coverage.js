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
const NEED = ['MdTypes', 'Emoji', 'MathLite', 'PlantumlBridge', 'MdParser'];

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
  ['mermaid', '6.21 PlantUML 时序图（语法桥转成 mermaid）', '```plantuml\n@startuml\nA -> B : hi\n@enduml\n```\n'],
];
for (const [lang, sec, src] of CHARTS) {
  probe('§6 ' + sec, lang + ' 进图表通道', src, 'claim', (res) => {
    const ch = blocks(res, K.Chart);
    return (ch.length === 1 && ch[0].lang === lang) ? true
      : '没进 Chart（kind 序列 ' + JSON.stringify(res.blocks.map((b) => b.kind)) + '）';
  });
}
probe('§6.21', 'PlantUML 类图不硬转（留源码，不出坏图）',
  '```plantuml\n@startuml\nclass Foo {\n  +bar()\n}\n@enduml\n```\n', 'claim', (res) => {
    const ch = blocks(res, K.Chart);
    return ch.length === 0 ? true : '类图被塞进 mermaid（会是一张报错卡）';
  });

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
probe('§9.4', 'Pandoc 图表编号 @fig: 与文献 [@key]',
  '![示意](flow.png){#fig:flow width=60%}\n\n如图 @fig:flow 所示，受[@gruber2004]影响。\n', 'known', (res) => {
    const t = flatText(res);
    return (t.indexOf('{#fig:flow') < 0 && t.indexOf('@fig:flow') >= 0)
      ? true : 'pandoc 标记退化异常："' + t.trim().slice(0, 60) + '"';
  });

// ════ §10 MDX ════
probe('§10', 'MDX 围栏按代码显示（不假装能跑组件）',
  '```mdx\nimport { Chart } from "./Chart"\n\n<Tabs>\n  <TabItem value="js">JS</TabItem>\n</Tabs>\n```\n', 'known',
  (res) => {
    const c = blocks(res, K.Code);
    return (c.length === 1 && c[0].lang === 'mdx') ? true : 'mdx 围栏产物异常';
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

probe('§6.22', '别名围栏也进图表通道（```dot / ```gv = graphviz，```chartjs = chart，```puml = 桥）',
  '```dot\ndigraph G { a -> b }\n```\n\n```gv\ndigraph H { c -> d }\n```\n\n```chartjs\n{"type":"bar"}\n```\n\n```puml\n@startuml\nA -> B : hi\n@enduml\n```\n',
  'claim', (res) => {
    const ch = blocks(res, K.Chart).map((b) => b.lang);
    const want = ['graphviz', 'graphviz', 'chart', 'mermaid'];
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
probe('§8.1', '渐变背景画不出来就不兜底（宁缺底不渲成黑块）',
  '<span style="background:linear-gradient(90deg,#a78bfa,#f472b6);color:#fff">渐变标签</span>\n', 'claim', (res) => {
    const all = allInlines(res);
    const withBg = all.filter((x) => (x.bg === undefined ? '' : x.bg).length > 0);
    if (withBg.length > 0) { return '渐变被当成实心色登记了：' + JSON.stringify(withBg.map((x) => x.bg)); }
    const white = all.filter((x) => (x.color === undefined ? '' : x.color).toUpperCase().indexOf('FFFFFF') >= 0);
    return white.length > 0 ? true : '字色也一起丢了：' + JSON.stringify(all.map((x) => x.color));
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
