// 合并导出：校验 MergeExport 的两条要害。
//  ① Front Matter 必须被剥干净——否则合并后各篇的 `---` 会散在正文里变成分隔线；
//  ② 篇间分隔线**绝不能**被解析成 Setext 标题（`文字\n---` 在 CommonMark 里是二级标题），
//     所以每篇之间必须隔着一个空行；同理标题行前也不能粘连上一篇的正文。
//  ③ 合并结果里每个围栏代码块都要仍然成对（跨篇粘连会把后面的块全带偏）。
//
// 这里按 MergeExport.ets 的实现原样重写（逻辑很短），若两边出现分歧本脚本会失真——
// 改动 MergeExport 时同步这里。语料用内置文档（真实含 Front Matter / 图表 / 公式）。
const fs = require('fs');
const path = require('path');

const RAW = path.join(__dirname, '../entry/src/main/resources/rawfile');
const DOCS = ['README.md', 'chengjian.md', 'capabilities.md'];

function stripFrontMatter(text) {
  const lines = text.replace(/\r\n?/g, '\n').split('\n');
  if (lines.length < 2 || lines[0].trim() !== '---') { return text; }
  for (let k = 1; k < lines.length; k++) {
    const t = lines[k].trim();
    if (t === '---' || t === '...') { return lines.slice(k + 1).join('\n'); }
  }
  return text;
}
function buildMarkdown(items, opts) {
  const parts = [];
  for (const it of items) {
    const body = stripFrontMatter(it.content).trim();
    if (body.length === 0 && !(opts.withTitle && it.name.length > 0)) { continue; }
    let seg = '';
    if (opts.withDivider && parts.length > 0) { seg += '---\n\n'; }
    if (opts.withTitle && it.name.length > 0) { seg += '# ' + it.name + '\n\n'; }
    parts.push(seg + body);
  }
  if (parts.length === 0) { return ''; }
  return parts.join('\n\n').trim() + '\n';
}

let fails = 0;
function check(name, ok, extra) {
  if (!ok) { fails++; console.log('  FAIL  ' + name + (extra ? '  ' + extra : '')); }
}

const items = DOCS.map(n => ({
  name: n.replace(/\.md$/, ''),
  content: fs.readFileSync(path.join(RAW, n), 'utf8').replace(/\r\n?/g, '\n')
}));

// 内置文档里确实有 Front Matter 才有意义（否则本项检查是空的）
const withFm = items.filter(i => /^---\s*\n/.test(i.content));
console.log('语料: ' + items.length + ' 篇，其中含 Front Matter: ' + withFm.length);

for (const opts of [
  { withTitle: true, withDivider: true },
  { withTitle: true, withDivider: false },
  { withTitle: false, withDivider: true },
  { withTitle: false, withDivider: false }
]) {
  const tag = 'title=' + opts.withTitle + ' divider=' + opts.withDivider;
  const merged = buildMarkdown(items, opts);
  const lines = merged.split('\n');

  // ② Setext 危险：`---` 上一行必须是空行（否则上一行变成二级标题）
  let badSetext = 0, firstLineBad = false;
  for (let k = 0; k < lines.length; k++) {
    if (lines[k].trim() === '---' || lines[k].trim() === '===') {
      if (k === 0) { firstLineBad = true; continue; }
      if (lines[k - 1].trim() !== '') { badSetext++; }
    }
  }
  check('② divider never acts as setext underline (' + tag + ')',
    badSetext === 0 && !firstLineBad, 'bad=' + badSetext + ' firstLine=' + firstLineBad);

  // ③ 围栏成对：整篇的 ``` / ~~~ 计数必须是偶数，且顺序闭合
  let open = null, unbalanced = 0, fences = 0;
  for (const line of lines) {
    const m = /^(`{3,}|~{3,})/.exec(line.trim());
    if (!m) { continue; }
    fences++;
    const mark = m[1][0];
    if (open === null) { open = mark; }
    else if (mark === open) { open = null; }
  }
  check('③ fences balanced (' + tag + ')', open === null && fences % 2 === 0,
    'open=' + open + ' fences=' + fences);

  // ④ 每篇正文都在（长度单调增长，说明没有互相吞掉）
  let expect = 0;
  for (const it of items) { expect += stripFrontMatter(it.content).trim().length; }
  check('④ content preserved (' + tag + ')',
    merged.length >= expect * 0.9, 'merged=' + merged.length + ' expect>=' + expect);

  // ⑤ 插入的标题必须**正好落在每篇段首**：数"开/关标题"两种结果的差值，
  //    语料本身就有若干一级标题，所以只能比差值、不能比绝对数量
  const withT = (buildMarkdown(items, { withTitle: true, withDivider: opts.withDivider })
    .match(/^# /gm) || []).length;
  const withoutT = (buildMarkdown(items, { withTitle: false, withDivider: opts.withDivider })
    .match(/^# /gm) || []).length;
  check('⑤ inserted titles == doc count (' + tag + ')',
    withT - withoutT === items.length, 'delta=' + (withT - withoutT));
  for (const it of items) {
    const seg = '# ' + it.name + '\n\n';
    check('⑤ title at section head: ' + it.name,
      !opts.withTitle || merged.includes(seg), 'missing ' + JSON.stringify(seg));
  }
}

// ① Front Matter：内置文档都没有 FM，所以用合成语料真正验一次
{
  const fm = ['---', 'title: 甲篇', 'tags:', '- a', '---', '', '# 正文甲', '', '内容 A'].join('\n');
  const plain = ['---', 'title: 乙篇', '---', '', '正文乙', '第二行'].join('\n');
  const merged = buildMarkdown(
    [{ name: '甲', content: fm }, { name: '乙', content: plain }],
    { withTitle: true, withDivider: true });
  check('① fm keys stripped', !/title:/.test(merged), JSON.stringify(merged.slice(0, 80)));
  check('① fm tag list stripped', !/^-\s+a$/m.test(merged));
  // 合并文本里只允许出现"我们插的分隔线"：数量 = 篇数 - 1
  const dividers = (merged.match(/^---$/gm) || []).length;
  check('① only the inserted dividers survive', dividers === 1, 'dividers=' + dividers);
  check('① bodies kept', merged.includes('内容 A') && merged.includes('正文乙'));
  // 没有闭合的 FM 不能误剥（否则整篇被吃掉）
  const broken = ['---', 'title: 没闭合', '', '正文还在'].join('\n');
  check('① unterminated front matter left alone',
    stripFrontMatter(broken) === broken);
}

// 单篇时不分隔（分隔线只出现在两篇之间）
const single = buildMarkdown([items[1]], { withTitle: true, withDivider: true });
check('single doc has no leading divider', !single.trimStart().startsWith('---'), single.slice(0, 30));

console.log(fails === 0 ? 'MERGE EXPORT OK' : 'MERGE EXPORT FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
