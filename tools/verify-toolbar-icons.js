// 工具栏图标资源校验（改工具栏 / 加按钮后跑一遍）。
//  ① SNIPPETS 里引用的每个 $r('app.media.xxx') 都必须真的存在对应 SVG；
//  ② 图标必须是**纯直线填充路径**：出现 stroke / fill 属性 → Image.fillColor() 换不了色，
//     深色模式下就会是死色（工程里现有 SVG 全部遵守这条）；
//  ③ 路径命令只允许 M L H V Z（含小写相对形式）——不用弧线/贝塞尔，避免 ArkUI
//     SVG 解析器在低端设备上画不出来；
//  ④ viewBox 必须是 24×24 一族，坐标不能越界（越界会被裁掉一角）；
//  ⑤ 展开面板的分组不能有空组漏掉按钮：每个 SNIPPETS 项的 group 都要被面板渲染。
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const EDITOR = path.join(ROOT, 'entry/src/main/ets/pages/Editor.ets');
const MEDIA = path.join(ROOT, 'entry/src/main/resources/base/media');

const src = fs.readFileSync(EDITOR, 'utf8').replace(/\r\n/g, '\n');
let fails = 0;
function check(name, ok, extra) {
  if (!ok) { fails++; console.log('  FAIL  ' + name + (extra ? '  ' + extra : '')); }
}

// ── 抓 SNIPPETS 数组里的条目 ──
const start = src.indexOf('const SNIPPETS: MdSnippet[] = [');
const end = src.indexOf('];', start);
check('SNIPPETS array found', start > 0 && end > start);
const body = src.slice(start, end);
const entries = [];
const entryRe = /\{\s*key:\s*'([^']+)'[^}]*?icon:\s*\$r\('app\.media\.([a-z0-9_]+)'\)[^}]*?group:\s*'([^']*)'[^}]*?core:\s*(true|false)/g;
let m;
while ((m = entryRe.exec(body)) !== null) {
  entries.push({ key: m[1], icon: m[2], group: m[3], core: m[4] === 'true' });
}
console.log('SNIPPETS 条目: ' + entries.length + '，图标引用: ' +
  new Set(entries.map(e => e.icon)).size + ' 个');
check('每个片段都有 icon/group/core', entries.length > 0 &&
  (src.slice(start, end).match(/key: '/g) || []).length === entries.length,
  'entries=' + entries.length);

// ── ① 资源文件存在 ──
for (const e of entries) {
  const p = path.join(MEDIA, e.icon + '.svg');
  check('① asset exists: ' + e.icon, fs.existsSync(p));
}

// ── ②③④ SVG 本体 ──
const ALLOWED = 'MmLlHhVvZz';
for (const e of entries) {
  const p = path.join(MEDIA, e.icon + '.svg');
  if (!fs.existsSync(p)) { continue; }
  const svg = fs.readFileSync(p, 'utf8');
  check('② no stroke attr: ' + e.icon, !/stroke\s*=/.test(svg));
  check('② no hard-coded fill: ' + e.icon, !/fill\s*=/.test(svg));
  check('④ viewBox 24: ' + e.icon, /viewBox="0 0 24 24"/.test(svg));
  const dRe = /d="([^"]+)"/g;
  let d;
  while ((d = dRe.exec(svg)) !== null) {
    const cmds = d[1].match(/[A-Za-z]/g) || [];
    const bad = cmds.filter(c => ALLOWED.indexOf(c) < 0);
    check('③ straight-line cmds only: ' + e.icon, bad.length === 0, '出现 ' + bad.join(','));
    const nums = (d[1].match(/-?\d+(\.\d+)?/g) || []).map(Number);
    const oob = nums.filter(n => n < -0.01 || n > 24.01);
    check('④ coords inside 0..24: ' + e.icon, oob.length === 0, '越界 ' + oob.join(','));
  }
  // 至少一个闭合子路径，否则填充会怪
  check('② has closed subpath: ' + e.icon, /Z|Z"/.test(svg) || /z/.test(svg));
}

// ── ⑤ 分组覆盖 ──
// 面板里每组的判据是 `it.group === 'xxx'`，所以比对**组名**而不是中文标题
const groups = new Set(entries.map(e => e.group));
const panelGroups = (src.match(/it\.group === '([a-z]+)'/g) || [])
  .map(s => /'([a-z]+)'/.exec(s)[1]);
console.log('分组: ' + [...groups].join(',') + ' | 面板渲染的组: ' + panelGroups.join(','));
for (const g of groups) {
  check('⑤ group rendered in panel: ' + g, panelGroups.includes(g));
}
const coreCount = entries.filter(e => e.core).length;
console.log('收起常驻胶囊的常用按钮: ' + coreCount + ' 个');
check('⑤ 收起态有常用按钮但不爆量', coreCount >= 5 && coreCount <= 10, 'core=' + coreCount);

// ── 展开钮图标必须是已存在的资源 ──
for (const n of ['chevron_up', 'chevron_down_l']) {
  check('toggle icon present: ' + n, fs.existsSync(path.join(MEDIA, n + '.svg')));
}
// $r() 必须字面量：出现拼接或三元就是回归。
// ⚠️ 先剥掉注释再查 —— 代码里写着"不要这么写"的反例说明，会被这条检查当成违规
const codeOnly = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^[ \t]*\/\/.*$/gm, '');
check('no $r() string concatenation', !/\$r\('app\.media\.'\s*\+/.test(codeOnly));
check('no $r() with ternary', !/\$r\([^)]*\?/.test(codeOnly));

console.log(fails === 0 ? 'TOOLBAR ICONS OK' : 'TOOLBAR ICONS FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
