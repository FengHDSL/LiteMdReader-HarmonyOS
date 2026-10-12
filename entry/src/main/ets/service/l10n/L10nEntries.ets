/**
 * 澄笺 · 语言词典的公共数据结构
 * ==========================
 *
 * 键 = 简体原文，值 = 目标语言译文。用「原文当键」有两个好处：
 *   ① 迁移可以一页一页来 —— 没登记的句子自动回退简体原文，界面不会出现空白；
 *   ② 代码里看到的文案与词典里的键一一对应，改文案时漏译会被 tools/verify-l10n.js 查出来
 *      （它同时检查：占位符 %1/%2 是否各语言一致、澄笺与拼音有没有被误翻译）。
 *
 * 单独抽出这个文件是为了避免循环引用：词典文件 import 这里，L10n 再 import 词典。
 */

/** 一条翻译。 */
export interface L10nEntry {
  k: string;
  v: string;
}

/** 把条目数组转成查询用的 Map（重复键以**后写的**为准，方便 override 表）。 */
export function toL10nMap(list: L10nEntry[]): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  for (let i = 0; i < list.length; i++) {
    m.set(list[i].k, list[i].v);
  }
  return m;
}
