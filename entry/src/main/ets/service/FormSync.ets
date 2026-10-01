/**
 * 澄笺 · 桌面卡片数据同步（应用进程侧 + 卡片进程共用）
 * =====================================================
 *
 * 卡片数据（最近阅读 3 篇）的**唯一构建源**，两个进程都用它：
 *   · 卡片进程：EntryFormAbility 在 onAddForm / onUpdateForm 时调用 buildData。
 *   · 应用进程：Reader 进度落盘 / 应用退后台时**主动推送**（formProvider.updateForm），
 *     读完卡片立即更新——原来只靠卡片 30 分钟定时刷新，体验是"明明有阅读记录，
 *     卡片却一直不显示"。
 *
 * **卡片 ID 登记**：提供方侧拿不到「已添加卡片列表」（FormInfo 上没有 formId），
 * 标准做法是 onAddForm 时从 want 参数（FormParam.IDENTITY_KEY）取出 formId
 * 存进 `<filesDir>/form_ids.json`，onRemoveForm 移除；推送时按存档逐个 updateForm。
 */
import { formBindingData, formProvider } from '@kit.FormKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { DocMeta, DocStore } from './DocStore';

const TAG: string = 'FormSync';

/** 两次主动推送的最小间隔：阅读滚动会频繁触发进度落盘，不能每次都推 */
const PUSH_MIN_INTERVAL_MS: number = 30000;

interface RecentDoc {
  name: string;
  percent: number;
  builtin: boolean;
}

interface FormIdFile {
  ids: string[];
}

let lastPushAt: number = 0;

export class FormSync {
  private static idsPath(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/form_ids.json';
  }

  /** 已登记的卡片 ID（文件损坏按空处理）。 */
  static savedFormIds(ctx: common.UIAbilityContext): string[] {
    try {
      const path: string = FormSync.idsPath(ctx);
      if (!fs.accessSync(path)) {
        return [];
      }
      const text: string = fs.readTextSync(path, { encoding: 'utf-8' });
      if (text.length === 0) {
        return [];
      }
      const parsed: FormIdFile = JSON.parse(text) as FormIdFile;
      if (parsed === null || parsed === undefined || parsed.ids === undefined) {
        return [];
      }
      return parsed.ids;
    } catch (err) {
      return [];
    }
  }

  private static saveFormIds(ctx: common.UIAbilityContext, ids: string[]): void {
    const file: fs.File = fs.openSync(FormSync.idsPath(ctx),
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify({ ids: ids } as FormIdFile));
    } finally {
      try {
        fs.closeSync(file);
      } catch (closeErr) {
        // 关闭失败无副作用
      }
    }
  }

  /** 卡片添加时登记 ID（onAddForm 调用；重复添加是幂等的）。 */
  static rememberFormId(ctx: common.UIAbilityContext, formId: string): void {
    if (formId.length === 0) {
      return;
    }
    try {
      const ids: string[] = FormSync.savedFormIds(ctx);
      if (ids.indexOf(formId) >= 0) {
        return;
      }
      ids.push(formId);
      FormSync.saveFormIds(ctx, ids);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'rememberFormId failed: %{public}s', (err as Error).message);
    }
  }

  /** 卡片移除时去登记（onRemoveForm 调用）。 */
  static forgetFormId(ctx: common.UIAbilityContext, formId: string): void {
    if (formId.length === 0) {
      return;
    }
    try {
      const ids: string[] = FormSync.savedFormIds(ctx);
      const kept: string[] = [];
      for (let k = 0; k < ids.length; k++) {
        if (ids[k] !== formId) {
          kept.push(ids[k]);
        }
      }
      if (kept.length !== ids.length) {
        FormSync.saveFormIds(ctx, kept);
      }
    } catch (err) {
      hilog.warn(0x0000, TAG, 'forgetFormId failed: %{public}s', (err as Error).message);
    }
  }

  /** 取最近阅读的 3 篇（按 lastOpen 倒序，滤掉没读过的；内置教程也算）。 */
  static recentDocs(ctx: common.UIAbilityContext): RecentDoc[] {
    const out: RecentDoc[] = [];
    try {
      const list: DocMeta[] = DocStore.list(ctx);
      const read: DocMeta[] = [];
      for (let k = 0; k < list.length; k++) {
        const d: DocMeta = list[k];
        if (d.lastOpen > 0) {
          // 内置教程也算：应用刚装好时用户最先读的就是内置教程
          read.push(d);
        }
      }
      read.sort((a: DocMeta, b: DocMeta) => b.lastOpen - a.lastOpen);
      for (let k = 0; k < read.length && k < 3; k++) {
        out.push({
          name: read[k].name,
          percent: Math.round((read[k].progressRatio > 0 ? read[k].progressRatio : 0) * 100),
          builtin: read[k].builtin
        });
      }
    } catch (err) {
      hilog.warn(0x0000, TAG, 'recentDocs failed: %{public}s', (err as Error).message);
    }
    return out;
  }

  /** 组装卡片数据：三个槽位，空槽给占位文案 */
  static buildData(ctx: common.UIAbilityContext): formBindingData.FormBindingData {
    const recents: RecentDoc[] = FormSync.recentDocs(ctx);
    hilog.info(0x0000, TAG, 'buildData: recents=%{public}d docs=%{public}d', recents.length, DocStore.list(ctx).length);
    const names: string[] = ['暂无阅读记录', '', ''];
    const percents: string[] = ['去书架挑一篇吧', '', ''];
    for (let k = 0; k < recents.length; k++) {
      names[k] = recents[k].name;
      percents[k] = recents[k].percent > 0 ? '已读 ' + recents[k].percent + '%' : '刚开始读';
    }
    const data: Record<string, string> = {
      'recent1': names[0],
      'recent2': names[1],
      'recent3': names[2],
      'percent1': percents[0],
      'percent2': percents[1],
      'percent3': percents[2],
      // 布尔标志走字符串 '1'/'0'（formBindingData 对布尔的支持不稳，统一字符串最稳）
      'has1': recents.length > 0 ? '1' : '0',
      'has2': recents.length > 1 ? '1' : '0',
      'has3': recents.length > 2 ? '1' : '0',
      'builtin1': recents.length > 0 && recents[0].builtin ? '1' : '0',
      'builtin2': recents.length > 1 && recents[1].builtin ? '1' : '0',
      'builtin3': recents.length > 2 && recents[2].builtin ? '1' : '0'
    };
    return formBindingData.createFormBindingData(data);
  }

  /**
   * 应用进程侧**主动推送**最近阅读到所有已登记的卡片（节流）。
   * 异步执行、失败静默——卡片还有 30 分钟定时刷新兜底，推送失败不影响阅读。
   *
   * @param force true = 跳过节流（如退后台前的最后一次推送）
   */
  static pushRecents(ctx: common.UIAbilityContext, force: boolean = false): void {
    const now: number = Date.now();
    if (!force && now - lastPushAt < PUSH_MIN_INTERVAL_MS) {
      return;
    }
    lastPushAt = now;
    const ids: string[] = FormSync.savedFormIds(ctx);
    hilog.info(0x0000, TAG, 'pushRecents: %{public}d registered form(s)', ids.length);
    if (ids.length === 0) {
      hilog.warn(0x0000, TAG, 'pushRecents: form_ids.json 为空——桌面卡片未登记，等待 onUpdateForm 自愈或重新添加卡片');
      return;
    }
    const data: formBindingData.FormBindingData = FormSync.buildData(ctx);
    for (let k = 0; k < ids.length; k++) {
      formProvider.updateForm(ids[k], data).catch((err: Error) => {
        hilog.warn(0x0000, TAG, 'updateForm %{public}s failed: %{public}s', ids[k], err.message);
      });
    }
  }
}
