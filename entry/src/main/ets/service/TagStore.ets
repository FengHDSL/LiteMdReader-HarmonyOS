import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 澄笺 · 标签顺序（TagStore）
 * =========================
 *
 * 标签本身存在各文档的 `DocMeta.tags` 里（一本书可以带多个标签），**没有独立表**；
 * 所以「标签的顺序」只能单独记一份：这里用 AppStorage 键 `tagOrder`（JSON 字符串数组）
 * 记录用户拖动排序后的次序，读取时按它排序、库里没记录的标签按出现顺序排在后面。
 *
 * 持久化：`EntryAbility` 里 `PersistentStorage.persistProp('tagOrder', '[]')`
 * + `SettingsMirror.KEYS` 登记（镜像落盘，换机 / 重装后恢复同一套顺序）。
 */
const TAG_ORDER_KEY: string = 'tagOrder';

export class TagStore {
  /** 已保存的标签顺序（读不到就是空数组） */
  static order(): string[] {
    const raw: string | undefined = AppStorage.get<string>(TAG_ORDER_KEY);
    if (raw === undefined || raw === null || raw.length === 0) {
      return [];
    }
    try {
      const parsed: string[] = JSON.parse(raw) as string[];
      if (parsed === null || parsed === undefined) {
        return [];
      }
      return parsed;
    } catch (err) {
      return [];
    }
  }

  /** 保存顺序（写 AppStorage，由 PersistentStorage / SettingsMirror 负责落盘） */
  static save(list: string[]): void {
    try {
      AppStorage.setOrCreate(TAG_ORDER_KEY, JSON.stringify(list));
    } catch (err) {
      hilog.warn(0x0000, 'TagStore', 'save tag order failed');
    }
  }

  /**
   * 把「现有标签集合」按保存过的顺序排好：
   * 先按 tagOrder 里出现过的次序，剩下的（新标签）按传入集合的原始顺序接在后面。
   * 已删除的标签不会出现在结果里（以传入集合为准）。
   */
  static ordered(existing: string[]): string[] {
    const saved: string[] = TagStore.order();
    const out: string[] = [];
    for (let k = 0; k < saved.length; k++) {
      const tag: string = saved[k];
      if (existing.indexOf(tag) >= 0 && out.indexOf(tag) < 0) {
        out.push(tag);
      }
    }
    for (let k = 0; k < existing.length; k++) {
      if (out.indexOf(existing[k]) < 0) {
        out.push(existing[k]);
      }
    }
    return out;
  }

  /** 拖动排序：把 from 位置的标签移到 to 位置，返回新数组（同时落库） */
  static move(list: string[], from: number, to: number): string[] {
    const next: string[] = list.slice();
    if (from < 0 || from >= next.length) {
      return next;
    }
    const item: string = next[from];
    next.splice(from, 1);
    let target: number = to;
    if (target < 0) {
      target = 0;
    }
    if (target > next.length) {
      target = next.length;
    }
    next.splice(target, 0, item);
    TagStore.save(next);
    return next;
  }
}
