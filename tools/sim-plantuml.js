#!/usr/bin/env node
/**
 * PlantUML → Mermaid 桥的**行为仿真**
 * =================================
 *
 * PlantUML 是 Java，离线内嵌不现实，所以 ```plantuml 走"翻成 mermaid 时序图"这条路。
 * 这条路上有两个坑这次都真踩过：
 *  ① `bridgeable()` 从来没被任何地方调用 —— 类图 / 活动图也被硬塞进 sequenceDiagram，
 *     用户看到的是一整张 mermaid 解析错误卡（比直接看源码更没用）；
 *  ② 一行 PlantUML 专有指令（skinparam、!theme…）原样透传给 mermaid，会让**整图**报错。
 *
 * 这里按 PlantumlBridge 的规则端口一份 JS，喂真实样例与反例，① 里另钉"端口所依据的
 * 源码规则还在原地"的同步检查。改 ArkTS 版要同步这里。
 *
 * 用法：node tools/sim-plantuml.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ETS = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets', 'markdown');
const bridgeSrc = fs.readFileSync(path.join(ETS, 'PlantumlBridge.ets'), 'utf8').replace(/\r\n/g, '\n');
const parserSrc = fs.readFileSync(path.join(ETS, 'MdParser.ets'), 'utf8').replace(/\r\n/g, '\n');

let fails = 0;
function check(label, ok, extra) {
  if (!ok) { fails++; console.log('  FAIL  ' + label + (extra ? '  ' + extra : '')); }
  else { console.log('  ok    ' + label); }
}

// ── ① 源码同步 ──
check('① 不桥的图种要回落成代码块（MdParser 真的在问 bridgeable）',
  /PlantumlBridge\.bridgeable\(pumlSrc\)/.test(parserSrc)
  && /if \(PlantumlBridge\.bridgeable/.test(parserSrc));
check('① 认不出的行降格成 mermaid 注释，不再原样透传',
  /out\.push\('    %% ' \+ raw\)/.test(bridgeSrc));
check('① 外观与预处理指令（skinparam / !theme / style / hide…）直接丢弃',
  /isPlantumlCosmetic/.test(bridgeSrc)
  && /startsWith\('skinparam'\)/.test(bridgeSrc) && /lower\.startsWith\('!'\)/.test(bridgeSrc));
check('① 箭头两种写法都收（带空格 A -> B 与紧凑 A->B）',
  /const spaced:/.test(bridgeSrc) && /const tight:/.test(bridgeSrc));

// ── 端口 ──
const DECL_KEYS = 'actor|participant|database|boundary|entity|collections|queue|control|agent|artifact';
function isCosmetic(l) {
  const s = l.toLowerCase();
  if (s.startsWith('skinparam') || s.startsWith('style') || s.startsWith('hide')
    || s.startsWith('show') || s.startsWith('remove') || s.startsWith('legend')
    || s.startsWith('endlegend') || s.startsWith('caption')) { return true; }
  return s.startsWith('!');
}
function unquote(s) {
  return (s.length >= 2 && s.charAt(0) === '"' && s.charAt(s.length - 1) === '"')
    ? s.substring(1, s.length - 1) : s;
}
function arrowOf(line) {
  const spaced = line.match(/^(\S+)\s+(-{1,2}>{1,2}[+-]?|\.{1,2}>{1,2})\s+([^:\s]+)\s*(?::\s*(.*))?$/);
  if (spaced) { return spaced; }
  return line.match(/^([^\s:>-]+)(-{1,2}>{1,2}[+-]?|\.>{1,2})([^\s:]+)\s*(?::\s*(.*))?$/);
}
const SEQ_LINE = '^(' + DECL_KEYS + '\\s+\\S'
  + '|\\S+\\s*-{1,2}>+\\S*'
  + '|\\S+\\s*\\.{1,2}>+\\S*'
  + '|note\\s+(over|left of|right of)\\b'
  + '|(activate|deactivate)\\s+\\S'
  + '|autonumber\\b|title\\s+\\S'
  + '|==.*=='
  + '|(alt|else|end|loop|opt|par|and|break|critical|group)\\b)';
const NOT_SEQ = '^\\s*(class|interface|enum|abstract|annotation|object|usecase|actor\\s+\\w+\\s*[\\[{]'
  + '|state|component|node|artifact|database\\s+\\w+\\s*[\\[{]|folder|rectangle|queue\\s+\\w+\\s*[\\[{]'
  + '|package|frame|salt|json|yaml|mindmap|gantt|wire|board)\\b';
function bridgeable(src) {
  const head = src.trim().toLowerCase();
  if (!head.startsWith('@startuml') && !head.startsWith('@startsequence')) { return false; }
  if (/@startmindmap|@startsalt|@startgantt|@startjson|@startyaml/i.test(src)) { return false; }
  const seqRe = new RegExp(SEQ_LINE, 'i');
  const notRe = new RegExp(NOT_SEQ, 'i');
  let sawMessage = false;
  for (const line of src.replace(/\r\n?/g, '\n').split('\n')) {
    const l = line.trim();
    if (l.length === 0 || l.toLowerCase() === '@startuml' || l.toLowerCase() === '@enduml'
      || isCosmetic(l) || l.startsWith("'") || l.startsWith("/'")) { continue; }
    if (notRe.test(l)) { return false; }
    if (!seqRe.test(l)) { return false; }
    if (/^\S+\s*-{1,2}>+/.test(l)) { sawMessage = true; }
  }
  return sawMessage;
}
function mapName(s, from, to) {
  const bare = unquote(s.trim());
  for (let k = 0; k < from.length; k++) { if (from[k] === bare) { return to[k]; } }
  return bare;
}
function toMermaid(src) {
  const out = ['sequenceDiagram'];
  const lines = src.replace(/\r\n?/g, '\n').split('\n');
  const aliasFrom = []; const aliasTo = [];
  let autoId = 0;
  for (const line of lines) {
    const raw = line.replace(/\t/g, '  ').trim();
    if (raw.length === 0 || raw.toLowerCase() === '@startuml' || raw.toLowerCase() === '@enduml'
      || raw.startsWith("/'") || (raw.startsWith("'") && !raw.startsWith("''"))) { continue; }
    if (isCosmetic(raw)) { continue; }
    const decl = raw.match(new RegExp('^(' + DECL_KEYS + ')\\s+(.+)$', 'i'));
    if (decl) {
      const rest = decl[2].trim();
      const asAt = rest.toLowerCase().indexOf(' as ');
      let show = rest; let id = rest;
      if (asAt >= 0) { show = rest.substring(0, asAt).trim(); id = rest.substring(asAt + 4).trim(); }
      const bare = unquote(show);
      if (id.indexOf(' ') >= 0) {
        autoId++;
        aliasFrom.push(unquote(id)); aliasTo.push('p' + autoId);
        id = 'p' + autoId;
      }
      if (bare !== id) { aliasFrom.push(bare); aliasTo.push(id); }
      out.push('    participant ' + id + ' as ' + bare);
      continue;
    }
    if (/^autonumber\b/i.test(raw) || /^title\s/i.test(raw)) { out.push('    ' + raw); continue; }
    if (raw.startsWith('==') && raw.endsWith('==')) { out.push('    ' + raw); continue; }
    const note = raw.match(/^note\s+(over|right of|left of)\s+(.+?)(?::\s*(.*))?$/i);
    if (note) {
      const pos = note[1].toLowerCase();
      const who = note[2].split(',').map((p) => mapName(p.trim(), aliasFrom, aliasTo)).join(', ');
      const txt = note[3] === undefined ? '' : note[3];
      const key = pos === 'over' ? 'Note over' : (pos === 'right of' ? 'Note right of' : 'Note left of');
      out.push('    ' + key + ' ' + who + (txt.length > 0 ? ': ' + txt : ''));
      continue;
    }
    const ar = arrowOf(raw);
    if (ar) {
      // 激活简写挂在目标上（A -> B++ / B --> A--），也可挂在箭头上（A ->+ B）
      let to = ar[3];
      let act = '';
      if (to.endsWith('++')) { act = 'activate'; to = to.substring(0, to.length - 2); }
      else if (to.endsWith('--') && to.length > 2) { act = 'deactivate'; to = to.substring(0, to.length - 2); }
      const from = mapName(ar[1], aliasFrom, aliasTo);
      const mappedTo = mapName(to, aliasFrom, aliasTo);
      const body = ar[2].replace(/[+-]$/, '');
      if (act === '' && ar[2].endsWith('+')) { act = 'activate'; }
      else if (act === '' && body !== ar[2] && ar[2].endsWith('-')) { act = 'deactivate'; }
      const mAr = (body.indexOf('--') >= 0 || body.charAt(0) === '.') ? '-->>' : '->>';
      const txt = ar[4] === undefined ? '' : ar[4];
      out.push('    ' + from + ' ' + mAr + ' ' + mappedTo
        + (txt.length > 0 ? ': ' + txt : '')
        + (act === '' ? '' : '\n    ' + act + ' ' + mappedTo));
      continue;
    }
    if (/^(activate|deactivate)\b/i.test(raw)) {
      const verb = raw.substring(0, raw.indexOf(' ')).toLowerCase();
      out.push('    ' + verb + ' ' + mapName(raw.substring(verb.length).trim(), aliasFrom, aliasTo));
      continue;
    }
    if (/^(alt|else|end|loop|opt|par|and|break|critical|repeat)\b/i.test(raw)) {
      out.push('    ' + raw); continue;
    }
    out.push('    %% ' + raw);
  }
  return out.join('\n');
}

// ── ② 用户文档 6.21 的真实样例 ──
const userSample = [
  '@startuml', 'actor 作者', 'participant "Markdown 引擎" as E', 'database "插件注册表" as R',
  '作者 -> E: 提交源码', 'E -> R: 查询已注册插件', 'R --> E: 返回插件列表',
  'E -> E: 依次执行插件', 'E --> 作者: 输出 HTML', '@enduml'
].join('\n');
check('② 用户文档的时序图判为可桥', bridgeable(userSample));
const m2 = toMermaid(userSample);
check('② 中文参与者与带引号别名都被正确处理（引号剥掉、名字映射回 id）',
  m2.includes('participant E as Markdown 引擎')
  && m2.includes('participant R as 插件注册表')
  && m2.includes('participant 作者 as 作者')
  && m2.indexOf('"') < 0, JSON.stringify(m2.split('\n').slice(1, 5)));
check('② -> 译成实线 ->>、--> 译成虚线 -->>，自环保留',
  m2.includes('作者 ->> E: 提交源码') && m2.includes('R -->> E: 返回插件列表')
  && m2.includes('E ->> E: 依次执行插件'), m2);
check('② 输出第一行是 sequenceDiagram，且没有残留 @startuml/@enduml',
  m2.split('\n')[0] === 'sequenceDiagram' && m2.indexOf('@start') < 0 && m2.indexOf('@end') < 0);

// ── ③ 其它写法 ──
const tight = toMermaid('@startuml\nA->B: 紧凑写法\nB-->A: 回来\n@enduml');
check('③ 不带空格的紧凑箭头也认', tight.includes('A ->> B: 紧凑写法')
  && tight.includes('B -->> A: 回来'), tight);
const notes = toMermaid('@startuml\nparticipant A\nparticipant B\nnote over A, B: 跨两个\nnote right of A: 侧边\n@enduml');
check('③ note over A, B 与 note right of 都翻成 mermaid 写法',
  notes.includes('Note over A, B: 跨两个') && notes.includes('Note right of A: 侧边'), notes);
const act = toMermaid('@startuml\nparticipant A\nA -> B++\nB --> A--\nactivate C\ndeactivate C\n@enduml');
check('③ 激活/停用（含箭头尾部 ++/-- 简写）翻成 activate / deactivate',
  act.includes('A ->> B') && act.includes('\n    activate B')
  && act.includes('\n    deactivate A') && act.includes('activate C') && act.includes('deactivate C'), act);
const junk = toMermaid('@startuml\nparticipant A\nA -> A: x\nskinparam BackgroundColor white\n!theme plain\nstyle A #ccc\nhide footbox\n自定义一行看不懂的\n@enduml');
check('④ 外观/预处理指令不进 mermaid（否则整图报错）',
  junk.indexOf('skinparam') < 0 && junk.indexOf('!theme') < 0
  && junk.indexOf('style A') < 0 && junk.indexOf('hide footbox') < 0, junk);
check('④ 真不认识的一行降格成注释而不是原样透传',
  junk.includes('    %% 自定义一行看不懂的'), junk);

// ── ⑤ 不该桥的图种 ──
const classDiagram = '@startuml\nclass Foo {\n  +int id\n}\nclass Bar\nFoo <|-- Bar\n@enduml';
const useCase = '@startuml\n:作者: --> (写文档)\n"usecase 阅读" as (读)\n@enduml';
const activity = '@startuml\nstart\n:解析源码;\nstop\n@enduml';
const stateDiagram = '@startuml\nstate 草稿 --> 已发布\n@enduml';
check('⑤ 类图 / 活动图 / 状态图判为不可桥（回落到代码块看源码）',
  !bridgeable(classDiagram) && !bridgeable(activity) && !bridgeable(stateDiagram));
check('⑤ 用例图判为不可桥', !bridgeable(useCase));
check('⑤ 纯时序图（只有箭头没有声明行）仍可桥',
  bridgeable('@startuml\nA -> B: hi\n@enduml'));

console.log(fails === 0 ? 'PLANTUML BRIDGE OK' : 'PLANTUML BRIDGE FAILED: ' + fails);
process.exit(fails === 0 ? 0 : 1);
