/**
 * 引擎管理（disabledEngines）接线与逻辑校验
 * ==========================================
 *
 * ① 锚点断言：所有登记点 / 门控点必须出现在源码里（缺一处 = 功能缺口）；
 * ② 纯函数逻辑自测：把 EngineRegistry 的判定函数转成等价 JS 跑用例
 *    （与 tools/check-inline-libs.js 同一思路：直抽 ArkTS 源的短函数逐字转录，
 *    源码存在性由 ① 的锚点保证）。
 *
 * 运行：node tools/latex-check/check-engine-gating.js
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');

let failed = 0;
function expectFile(file, anchors) {
  const src = read(file);
  for (const a of anchors) {
    if (src.indexOf(a) < 0) {
      console.error('MISS [' + file + ']: ' + a);
      failed++;
    }
  }
}

// ── ① 锚点断言 ──
expectFile('entry/src/main/ets/service/EngineRegistry.ets', [
  "static readonly KEY: string = 'disabledEngines'",
  'static isOff(id: string, list: string)',
  'static withToggled(list: string, id: string, off: boolean)',
  "if (l === 'flowchart')",
  'static isLangOff(lang: string)',
  'static nameOf(id: string)',
  'static countOff(list: string)',
  "id: 'katex'", "id: 'mathjax'", "id: 'mermaid'", "id: 'markmap'", "id: 'echarts'",
  "id: 'abc'", "id: 'graphviz'", "id: 'flowchart'", "id: 'marked'", "id: 'turndown'"
]);

expectFile('entry/src/main/ets/pages/SettingsEngines.ets', [
  "@StorageLink('disabledEngines') disabled: string = '';",
  'EngineRegistry.withToggled(this.disabled, id, !on)',
  'EngineRegistry.countOff(this.disabled) > 0',
  'enableAll()',
  'shellTitle: ',
  'ForEach(ENGINE_LIST'
]);

expectFile('entry/src/main/ets/pages/Settings.ets', [
  "name: '引擎管理'",
  "route: 'pages/SettingsEngines'",
  "route === 'pages/SettingsEngines'"
]);

expectFile('entry/src/main/ets/pages/Index.ets', [
  "import { SettingsEngines } from './SettingsEngines';",
  "name === 'pages/SettingsEngines'"
]);

expectFile('entry/src/main/ets/entryability/EntryAbility.ets', [
  "PersistentStorage.persistProp('disabledEngines', '');"
]);

expectFile('entry/src/main/ets/service/SettingsMirror.ets', [
  "'disabledEngines',"
]);

expectFile('entry/src/main/ets/service/WebDavStore.ets', [
  "'disabledEngines'"
]);

expectFile('entry/src/main/ets/markdown/MdView.ets', [
  "@StorageProp('disabledEngines') engineOffList: string = '';",
  'private blockEngineId()',
  'private blockEngineOff()',
  'engineOffCard()',
  'if (this.blockEngineOff()) {',
  "EngineRegistry.isOff('mathjax', this.engineOffList)",
  "EngineRegistry.isOff('katex', this.engineOffList)"
]);

expectFile('entry/src/main/ets/markdown/FormulaTasks.ets', [
  "EngineRegistry.isOff('mathjax', EngineRegistry.current())"
]);

expectFile('entry/src/main/ets/pages/Reader.ets', [
  "@StorageProp('disabledEngines') @Watch('onEnginesChanged') disabledEngineList: string = '';",
  'onEnginesChanged(): void {',
  'private collectChartTasks(dark: boolean)',
  'EngineRegistry.isOff(EngineRegistry.langId(mode), this.disabledEngineList)',
  "+ '_e' + this.disabledEngineList" // 图表/公式条目 key 后缀
]);

expectFile('entry/src/main/ets/pages/AiChat.ets', [
  "@StorageProp('disabledEngines') @Watch('onEnginesChanged') disabledEngineList: string = '';",
  'onEnginesChanged(): void {',
  "'_e' + this.disabledEngineList"
]);

expectFile('entry/src/main/ets/pages/Editor.ets', [
  "@StorageProp('disabledEngines') @Watch('onEnginesChanged') disabledEngineList: string = '';",
  'onEnginesChanged(): void {',
  'private webModeBlocked()',
  "EngineRegistry.isOff('marked', off) || EngineRegistry.isOff('turndown', off)",
  'this.webModeBlocked() && item.m >= 1 ? 0.4 : 1',
  'if (this.previewMode >= 1 && this.webModeBlocked()) {'
]);

expectFile('entry/src/main/ets/markdown/MdToHtml.ets', [
  'static engineOffForLang(lang: string)',
  "EngineRegistry.isOff('flowchart', EngineRegistry.current())",
  "EngineRegistry.isOff('mermaid', EngineRegistry.current())",
  'if (MdToHtml.engineOffForLang(langLower)) {',
  "EngineRegistry.isOff('katex', EngineRegistry.current())",
  'if (MdToHtml.engineOffForLang(lang)) {'
]);

expectFile('entry/src/main/ets/service/ChartRuntimeService.ets', [
  'import { InlineRuntime, MdToHtml } from \'../markdown/MdToHtml\';',
  'if (MdToHtml.engineOffForLang(lang)) {'
]);

// ── ② 纯函数逻辑自测（逐字转录自 EngineRegistry.ets / MdToHtml.engineOffForLang）──
class EngineRegistry {
  static isOff(id, list) {
    if (list.length === 0) { return false; }
    return (',' + list + ',').indexOf(',' + id + ',') >= 0;
  }
  static withToggled(list, id, off) {
    const ids = list.length === 0 ? [] : list.split(',');
    const out = [];
    for (let k = 0; k < ids.length; k++) {
      const it = ids[k].trim();
      if (it.length > 0 && it !== id) { out.push(it); }
    }
    if (off) { out.push(id); }
    return out.join(',');
  }
  static langId(lang) {
    const l = lang.trim().toLowerCase();
    if (l === 'katex') { return 'katex'; }
    if (l === 'mermaid') { return 'mermaid'; }
    if (l === 'markmap') { return 'markmap'; }
    if (l === 'echarts') { return 'echarts'; }
    if (l === 'abc') { return 'abc'; }
    if (l === 'graphviz') { return 'graphviz'; }
    if (l === 'flowchart') { return 'flowchart'; }
    return '';
  }
  static isLangOff(lang, cur) {
    return EngineRegistry.isOff(EngineRegistry.langId(lang), cur);
  }
  static countOff(list) {
    if (list.length === 0) { return 0; }
    const ids = list.split(',');
    let n = 0;
    for (let k = 0; k < ids.length; k++) {
      if (ids[k].trim().length > 0) { n++; }
    }
    return n;
  }
  // MdToHtml.engineOffForLang（current() 由测试桩注入）
  static engineOffForLang(lang, cur) {
    const l = lang.trim().toLowerCase();
    if (l === 'flowchart') {
      return EngineRegistry.isOff('flowchart', cur) || EngineRegistry.isOff('mermaid', cur);
    }
    return EngineRegistry.isOff(EngineRegistry.langId(l), cur);
  }
}

let tFailed = 0;
function t(name, actual, expected) {
  const ok = actual === expected;
  if (!ok) { console.error('TEST FAIL: ' + name + ' → got [' + actual + '] want [' + expected + ']'); tFailed++; failed++; }
}

const cur = 'mermaid,katex';
t('isOff 空串恒 false', EngineRegistry.isOff('katex', ''), false);
t('isOff 命中', EngineRegistry.isOff('katex', cur), true);
t('isOff 未命中', EngineRegistry.isOff('mathjax', cur), false);
t('isOff 前后缀不误伤（eta 不算 katex）', EngineRegistry.isOff('eta', cur), false);
t('isOff 空 id 恒 false', EngineRegistry.isOff('', cur), false);
t('withToggled 开→关', EngineRegistry.withToggled(cur, 'abc', true), 'mermaid,katex,abc');
t('withToggled 关→开', EngineRegistry.withToggled(cur, 'katex', false), 'mermaid');
t('withToggled 已关再关仍只一份（集合语义，挪到尾部）', EngineRegistry.withToggled(cur, 'mermaid', true), 'katex,mermaid');
t('withToggled 从空开→关', EngineRegistry.withToggled('', 'katex', true), 'katex');
t('countOff', EngineRegistry.countOff(cur), 2);
t('countOff 空串', EngineRegistry.countOff(''), 0);
t('langId html → 空', EngineRegistry.langId('HTML'), '');
t('langId 大小写', EngineRegistry.langId(' Mermaid '), 'mermaid');
t('isLangOff html 恒 false', EngineRegistry.isLangOff('html', cur), false);
t('engineOffForLang mermaid 关', EngineRegistry.engineOffForLang('mermaid', cur), true);
t('engineOffForLang katex 关', EngineRegistry.engineOffForLang('katex', cur), true);
t('engineOffForLang echarts 开', EngineRegistry.engineOffForLang('echarts', cur), false);
t('flowchart 关仅因 flowchart', EngineRegistry.engineOffForLang('flowchart', 'flowchart'), true);
t('flowchart 关仅因 mermaid', EngineRegistry.engineOffForLang('flowchart', 'mermaid'), true);
t('flowchart 开（两者都在）', EngineRegistry.engineOffForLang('flowchart', 'echarts'), false);

// ── 汇总 ──
if (failed > 0) {
  console.error('\nFAILED: ' + failed + ' 处缺口');
  process.exit(1);
}
console.log('OK: 全部锚点断言与 21 条逻辑用例通过');
