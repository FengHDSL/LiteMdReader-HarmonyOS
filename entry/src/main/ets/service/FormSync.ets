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
 * 存进 form_ids.json，onRemoveForm 移除；推送时按存档逐个 updateForm。
 *
 * **⚠️ 跨进程目录铁律**：form_ids / form_snapshot 必须放在
 * **ApplicationContext.filesDir（应用级目录）**。UIAbilityContext.filesDir 是
 * HAP 级目录（…/haps/entry/files），ApplicationContext.filesDir 是应用级目录
 * （…/base/files）——两者不是同一个路径！之前卡片进程用 ApplicationContext、
 * 应用进程用 UIAbilityContext，读写落在两个目录，卡片永远读不到应用写入的
 * 数据（真机表现为「暂无阅读记录」）。ApplicationContext 在两个进程里都拿得到
 * 且指向同一目录，FormSync 的所有文件统一放这。
 *
 * **快照机制**：应用进程把最近阅读 3 篇写成 form_snapshot.json（小文件、
 * 不受节流限制），卡片进程 buildData 只读这份快照，不再依赖卡片进程里
 * DocStore 的初始化时序；快照缺失时回落 DocStore 现算（应用首装首次添加卡片）。
 */
import { formBindingData, formProvider } from '@kit.FormKit';
import { ReviewCard, ReviewCardStore } from './ReviewCard';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { DocMeta, DocStore } from './DocStore';
import { L10n } from './L10n';

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

/** form_snapshot.json 的落盘结构（应用进程写、卡片进程读） */
interface FormSnapshot {
  savedAt: number;
  docs: RecentDoc[];
}

/** 学习卡桌面卡片的快照（今日到期卡的 front/back + 当前索引） */
interface StudySnapshot {
  savedAt: number;
  items: StudyItem[];
  index: number;
}

/** 今日到期的单张学习卡（front=题面，back=批注/答案） */
interface StudyItem {
  front: string;
  back: string;
}

let lastPushAt: number = 0;

export class FormSync {
  /**
   * 跨进程统一目录（应用级）。两个进程调它拿到的一定是同一路径——
   * 详见文件头「跨进程目录铁律」。
   */
  private static appFilesDir(ctx: common.UIAbilityContext): string {
    try {
      const appCtx: common.ApplicationContext = ctx.getApplicationContext();
      return appCtx.filesDir;
    } catch (err) {
      return ctx.filesDir;
    }
  }

  private static idsPath(ctx: common.UIAbilityContext): string {
    return FormSync.appFilesDir(ctx) + '/form_ids.json';
  }

  private static snapshotPath(ctx: common.UIAbilityContext): string {
    return FormSync.appFilesDir(ctx) + '/form_snapshot.json';
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

  /**
   * 应用进程**写快照**（最近阅读 3 篇，不受节流限制——写小文件远比推送便宜）。
   * 卡片进程 buildData 只读这份快照，绕开卡片进程里 DocStore 初始化的不确定性。
   */
  static writeSnapshot(ctx: common.UIAbilityContext, recents: RecentDoc[]): void {
    try {
      const file: fs.File = fs.openSync(FormSync.snapshotPath(ctx),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        const snap: FormSnapshot = { savedAt: Date.now(), docs: recents };
        fs.writeSync(file.fd, JSON.stringify(snap));
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
    } catch (err) {
      hilog.warn(0x0000, TAG, 'writeSnapshot failed: %{public}s', (err as Error).message);
    }
  }

  /** 读快照；文件不存在 / 损坏 / 无 docs 时返回 null（调用方回落 DocStore 现算）。 */
  private static readSnapshot(ctx: common.UIAbilityContext): RecentDoc[] | null {
    try {
      const path: string = FormSync.snapshotPath(ctx);
      if (!fs.accessSync(path)) {
        return null;
      }
      const text: string = fs.readTextSync(path, { encoding: 'utf-8' });
      if (text.length === 0) {
        return null;
      }
      const parsed: FormSnapshot = JSON.parse(text) as FormSnapshot;
      if (parsed === null || parsed === undefined || parsed.docs === undefined || parsed.docs === null) {
        return null;
      }
      return parsed.docs;
    } catch (err) {
      return null;
    }
  }

  /** 组装卡片数据：三个槽位，空槽给占位文案；同时携带 2×2 卡片（单文档）的键 */
  static buildData(ctx: common.UIAbilityContext): formBindingData.FormBindingData {
    // 数据源优先级：快照（应用进程落盘，卡片进程零依赖可读）→ DocStore 现算
    let recents: RecentDoc[] | null = FormSync.readSnapshot(ctx);
    const fromSnapshot: boolean = recents !== null;
    if (recents === null) {
      recents = FormSync.recentDocs(ctx);
    }
    hilog.info(0x0000, TAG, 'buildData: recents=%{public}d source=%{public}s',
      recents.length, fromSnapshot ? 'snapshot' : 'docstore');
    const names: string[] = ['暂无阅读记录', '', ''];
    const percents: string[] = ['去书架挑一篇吧', '', ''];
    for (let k = 0; k < recents.length; k++) {
      names[k] = recents[k].name;
      percents[k] = recents[k].percent > 0 ? L10n.t('已读 ') + recents[k].percent + '%' : L10n.t('刚开始读');
    }
    // 2×2 卡片（最近阅读一篇 + 新建文档按钮）：与 2×4 共用一次 recentDocs
    const hasRecent: string = recents.length > 0 ? '1' : '0';
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
      'builtin3': recents.length > 2 && recents[2].builtin ? '1' : '0',
      // ── 2×2 卡片键 ──
      'recentName': hasRecent === '1' ? recents[0].name : L10n.t('暂无阅读记录'),
      'recentPercent': hasRecent === '1' ? percents[0] : L10n.t('去书架挑一篇吧'),
      'hasRecent': hasRecent,
      // 卡片点击路由参数：要打开的文档名（postCardAction params 用）
      'docName': hasRecent === '1' ? recents[0].name : ''
    };
    // **学习卡键并入**（背诵卡 / 记忆卡桌面卡片共用一次推送）
    FormSync.studyKeys(ctx, data);
    return formBindingData.createFormBindingData(data);
  }

  /** 学习卡快照路径（应用级目录，两进程一致） */
  private static studyPath(ctx: common.UIAbilityContext): string {
    return FormSync.appFilesDir(ctx) + '/form_snapshot_study.json';
  }

  /** **应用进程**组装学习卡快照：今日到期卡（due 升序，front/back 截 80 字） */
  static writeStudySnapshot(ctx: common.UIAbilityContext): void {
    try {
      const cards: ReviewCard[] = ReviewCardStore.load(ctx);
      const due: ReviewCard[] = ReviewCardStore.dueToday(cards);
      const items: StudyItem[] = [];
      for (let k = 0; k < due.length && k < 30; k++) {
        const f: string = due[k].front.length > 80 ? due[k].front.substring(0, 80) + '…' : due[k].front;
        const b: string = due[k].back.length > 80 ? due[k].back.substring(0, 80) + '…' : due[k].back;
        items.push({ front: f, back: b });
      }
      const file: fs.File = fs.openSync(FormSync.studyPath(ctx),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        const snap: StudySnapshot = { savedAt: Date.now(), items: items, index: 0 };
        fs.writeSync(file.fd, JSON.stringify(snap));
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          // 忽略
        }
      }
    } catch (err) {
      hilog.warn(0x0000, TAG, 'writeStudySnapshot failed: %{public}s', (err as Error).message);
    }
  }

  /** 读学习卡快照；不存在/损坏/为空返回 null */
  private static readStudySnapshot(ctx: common.UIAbilityContext): StudySnapshot | null {
    try {
      const path: string = FormSync.studyPath(ctx);
      if (!fs.accessSync(path)) {
        return null;
      }
      const text: string = fs.readTextSync(path, { encoding: 'utf-8' });
      if (text.length === 0) {
        return null;
      }
      const parsed: StudySnapshot = JSON.parse(text) as StudySnapshot;
      if (parsed === null || parsed === undefined || parsed.items === undefined || parsed.items === null) {
        return null;
      }
      return parsed;
    } catch (err) {
      return null;
    }
  }

  /**
   * **学习卡键组装**（背诵卡 / 记忆卡共用）：
   * 剩余个数 = 今日到期数；当前内容 = items[index]（背诵卡只读 front，记忆卡 front+back）。
   * 直接并入 buildData 的键集——一次 updateForm 同时刷新两类卡片。
   */
  private static studyKeys(ctx: common.UIAbilityContext, data: Record<string, string>): void {
    const snap: StudySnapshot | null = FormSync.readStudySnapshot(ctx);
    if (snap === null || snap.items.length === 0) {
      data['studyHas'] = '0';
      data['studyRemain'] = '0';
      data['studyFront'] = L10n.t('今天没有待背的学习卡');
      data['studyBack'] = '';
      return;
    }
    data['studyHas'] = '1';
    data['studyRemain'] = String(snap.items.length);
    const cur: StudyItem = snap.items[snap.index % snap.items.length];
    data['studyFront'] = cur.front;
    data['studyBack'] = cur.back;
  }

  /** **应用进程侧推送学习卡数据**（复习数据变化 / 评分后调用）：重写快照并全量 updateForm */
  static pushStudy(ctx: common.UIAbilityContext): void {
    FormSync.writeStudySnapshot(ctx);
    const data: formBindingData.FormBindingData = FormSync.buildData(ctx);
    const ids: string[] = FormSync.savedFormIds(ctx);
    for (let k = 0; k < ids.length; k++) {
      try {
        formProvider.updateForm(ids[k], data);
      } catch (err) {
        // 单卡片失败不影响其它
      }
    }
  }

  /** **卡片进程「下一个」**：索引 +1（循环）→ 重写快照 → 返回新数据 */
  static studyNext(ctx: common.UIAbilityContext): formBindingData.FormBindingData {
    const snap: StudySnapshot | null = FormSync.readStudySnapshot(ctx);
    if (snap !== null && snap.items.length > 0) {
      snap.index = (snap.index + 1) % snap.items.length;
      try {
        const file: fs.File = fs.openSync(FormSync.studyPath(ctx),
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, JSON.stringify(snap));
        } finally {
          try {
            fs.closeSync(file);
          } catch (closeErr) {
            // 忽略
          }
        }
      } catch (err) {
        hilog.warn(0x0000, TAG, 'studyNext save failed: %{public}s', (err as Error).message);
      }
    }
    return FormSync.buildData(ctx);
  }

  /**
   * 应用进程侧**主动推送**最近阅读到所有已登记的卡片（节流）。
   * 异步执行、失败静默——卡片还有 30 分钟定时刷新兜底，推送失败不影响阅读。
   *
   * @param force true = 跳过节流（如退后台前的最后一次推送）
   */
  static pushRecents(ctx: common.UIAbilityContext, force: boolean = false): void {
    // 快照先落盘（不受节流限制）：即使推送被节流跳过，卡片下次刷新也能读到新数据
    const recents: RecentDoc[] = FormSync.recentDocs(ctx);
    FormSync.writeSnapshot(ctx, recents);
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
