/**
 * LiteMdReader · 阅读标签页（多开）
 * ===================================
 *
 * 移植自参考项目的多标签页：同时打开多篇文档、点标签切换、
 * 再次打开已打开的文档聚焦既有标签、重启后恢复上次标签列表与激活项。
 *
 * 设计取舍：
 *  - 标签状态放在**模块级单例 + 落盘 tabs.json**，而不是页面 @State——
 *    阅读页会被路由反复压栈/销毁，页面实例不持有跨会话状态；
 *    每个标签的滚动位置复用 DocStore 的进度存储（本来就是按文档记的），
 *    不在标签里再存一份。
 *  - `pendingAnchor` 是一次性消费的待跳转锚点：内部链接 `[文字](doc.md#锚点)`
 *    打开文档后定位到锚点，用掉即清，避免下次切换又跳回去。
 *  - 手机没有「中键」与「右键」，关闭走标签上的 × 与长按菜单。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

/** 一个打开的标签 */
export interface ReaderTab {
  /** 文档名（唯一标识） */
  name: string;
  /** 待跳转锚点（一次性消费），空串表示无 */
  anchor: string;
}

/** tabs.json 的反序列化结构 */
interface TabFile {
  tabs: ReaderTab[];
  active: string;
}

export class TabStore {
  private static tabs: ReaderTab[] = [];
  private static active: string = '';
  private static path: string = '';
  private static ready: boolean = false;

  /** 必须在任何其它方法之前调用；重复调用安全。 */
  static init(ctx: common.UIAbilityContext): void {
    if (TabStore.ready) {
      return;
    }
    TabStore.path = ctx.filesDir + '/tabs.json';
    try {
      if (fs.accessSync(TabStore.path)) {
        const text: string = fs.readTextSync(TabStore.path, { encoding: 'utf-8' });
        if (text.length > 0) {
          const parsed: TabFile = JSON.parse(text) as TabFile;
          if (parsed !== null && parsed !== undefined && parsed.tabs !== undefined) {
            TabStore.tabs = parsed.tabs;
            TabStore.active = parsed.active !== undefined ? parsed.active : '';
          }
        }
      }
    } catch (err) {
      // 文件损坏按空标签处理，不影响阅读
      TabStore.tabs = [];
      TabStore.active = '';
    }
    // 落盘记录里的文档可能已被删除，加载时清掉
    const kept: ReaderTab[] = [];
    for (let k = 0; k < TabStore.tabs.length; k++) {
      const tab: ReaderTab = TabStore.tabs[k];
      if (tab.name !== undefined && tab.name.length > 0) {
        kept.push(tab);
      }
    }
    TabStore.tabs = kept;
    if (TabStore.activeName().length === 0 && TabStore.tabs.length > 0) {
      TabStore.active = TabStore.tabs[0].name;
    }
    TabStore.ready = true;
  }

  /** 标签列表（副本语义：调用方修改不影响内部状态）。 */
  static list(): ReaderTab[] {
    const out: ReaderTab[] = [];
    for (let k = 0; k < TabStore.tabs.length; k++) {
      out.push(TabStore.tabs[k]);
    }
    return out;
  }

  static activeName(): string {
    for (let k = 0; k < TabStore.tabs.length; k++) {
      if (TabStore.tabs[k].name === TabStore.active) {
        return TabStore.active;
      }
    }
    if (TabStore.tabs.length > 0) {
      return TabStore.tabs[0].name;
    }
    return '';
  }

  static isOpen(name: string): boolean {
    for (let k = 0; k < TabStore.tabs.length; k++) {
      if (TabStore.tabs[k].name === name) {
        return true;
      }
    }
    return false;
  }

  /**
   * 打开文档：已打开则聚焦既有标签（不重复开），未打开则新建并激活。
   * anchor 非空时写入待跳转锚点（聚焦既有标签也会更新）。
   */
  static open(name: string, anchor: string): void {
    if (name.length === 0) {
      return;
    }
    for (let k = 0; k < TabStore.tabs.length; k++) {
      if (TabStore.tabs[k].name === name) {
        TabStore.tabs[k].anchor = anchor.length > 0 ? anchor : TabStore.tabs[k].anchor;
        TabStore.active = name;
        TabStore.persist();
        return;
      }
    }
    const tab: ReaderTab = { name: name, anchor: anchor };
    TabStore.tabs.push(tab);
    TabStore.active = name;
    // 标签数量上限：超出时从最旧的挤掉（第一位通常是激活项，从第二位开始找）
    while (TabStore.tabs.length > 12) {
      let victim: number = 0;
      for (let k = 0; k < TabStore.tabs.length; k++) {
        if (TabStore.tabs[k].name !== TabStore.active) {
          victim = k;
          break;
        }
      }
      TabStore.tabs.splice(victim, 1);
    }
    TabStore.persist();
  }

  static activate(name: string): void {
    if (TabStore.isOpen(name)) {
      TabStore.active = name;
      TabStore.persist();
    }
  }

  /** 取出并清空该文档的待跳转锚点（一次性）。 */
  static consumeAnchor(name: string): string {
    for (let k = 0; k < TabStore.tabs.length; k++) {
      if (TabStore.tabs[k].name === name) {
        const anchor: string = TabStore.tabs[k].anchor;
        TabStore.tabs[k].anchor = '';
        if (anchor.length > 0) {
          TabStore.persist();
        }
        return anchor;
      }
    }
    return '';
  }

  /**
   * 关闭一个标签。
   * 返回下一个激活的文档名；全部关完返回空串。激活项被关时自动落到相邻标签。
   */
  static close(name: string): string {
    const index: number = TabStore.indexOf(name);
    if (index < 0) {
      return TabStore.activeName();
    }
    TabStore.tabs.splice(index, 1);
    if (TabStore.active === name) {
      if (TabStore.tabs.length === 0) {
        TabStore.active = '';
      } else {
        const next: number = index < TabStore.tabs.length ? index : TabStore.tabs.length - 1;
        TabStore.active = TabStore.tabs[next].name;
      }
    }
    TabStore.persist();
    return TabStore.activeName();
  }

  /** 关闭除指定标签外的全部，指定标签成为激活项。 */
  static closeOthers(name: string): void {
    const kept: ReaderTab[] = [];
    for (let k = 0; k < TabStore.tabs.length; k++) {
      if (TabStore.tabs[k].name === name) {
        kept.push(TabStore.tabs[k]);
      }
    }
    if (kept.length === 0) {
      return;
    }
    TabStore.tabs = kept;
    TabStore.active = name;
    TabStore.persist();
  }

  /** 关闭全部标签。 */
  static closeAll(): void {
    TabStore.tabs = [];
    TabStore.active = '';
    TabStore.persist();
  }

  private static indexOf(name: string): number {
    for (let k = 0; k < TabStore.tabs.length; k++) {
      if (TabStore.tabs[k].name === name) {
        return k;
      }
    }
    return -1;
  }

  private static persist(): void {
    try {
      const file: TabFile = { tabs: TabStore.tabs, active: TabStore.active };
      const f: fs.File = fs.openSync(TabStore.path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, JSON.stringify(file));
      } finally {
        try {
          fs.closeSync(f);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
    } catch (err) {
      // 落盘失败只丢标签恢复，不影响阅读
    }
  }
}
