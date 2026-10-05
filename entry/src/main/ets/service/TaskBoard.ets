/**
 * 任务板（TaskBoard）—— **跨文档**收集所有 Markdown 里的任务清单。
 *
 * 为什么需要：任务清单散落在各篇文档里（会议记录、读书笔记、周报），
 * 想知道"还有什么没做完"就得一篇篇翻。这里一次扫全，按文档归组给出。
 *
 * 实现约束：
 * 1. 聚合只读；**勾选写回**由 `toggle()` 单独负责（只改 `[ ]`/`[x]` 三个字符，
 *    不动行数，块 id 与批注坐标都不漂移），内置 / 只读文档一律拒绝写盘；
 *    **内置文档整个跳过、不进列表**（用户要求）；
 * 2. 性能保护：单文件超过 512KB 跳过、总量超过 800 条截断 —— 文档多了也不至于卡住书架；
 * 3. 跳过文件夹（文件夹没有正文）。
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DocStore, DocMeta } from './DocStore';

/** 一条任务 */
export interface TaskItem {
  /** 所属文档名 */
  docName: string;
  /** 行号（从 1 开始） */
  line: number;
  /** 任务正文（已去掉复选框标记） */
  text: string;
  /** 是否已完成 */
  done: boolean;
  /** 是否内置文档（内置文档正文在 rawfile，勾选无法写盘） */
  builtin: boolean;
  /** 是否被用户设为只读（勾选不写盘） */
  readOnly: boolean;
}

/** 聚合结果 */
export interface TaskBoardResult {
  items: TaskItem[];
  open: number;
  done: number;
  /** 参与统计的文档数（含正文里没有任务的文档也不计） */
  docs: number;
  /** 是否因为总量上限被截断 */
  truncated: boolean;
}

/** 复选框行：`- [ ] xxx` / `* [x] xxx` / `+ [X] xxx` */
const BOX_RE: RegExp = /^\s*[-*+]\s*\[([ xX])\]\s*(.*)$/;
/** 单文件跳过阈值（512KB） */
const MAX_FILE_CHARS: number = 512 * 1024;
/** 总量上限 */
const MAX_ITEMS: number = 800;

export class TaskBoard {
  /**
   * 扫描全部文档，收集任务清单。
   * @param onlyOpen 只收集未完成的（默认 true —— 任务板关心"还剩什么"）
   */
  static collect(ctx: common.UIAbilityContext, onlyOpen: boolean = true): TaskBoardResult {
    DocStore.init(ctx);
    const items: TaskItem[] = [];
    let open: number = 0;
    let done: number = 0;
    let docs: number = 0;
    let truncated: boolean = false;

    const list: DocMeta[] = DocStore.list(ctx);
    for (let k = 0; k < list.length && !truncated; k++) {
      const meta: DocMeta = list[k];
      // **内置文档不进任务板**（用户要求）：示例文档里的任务不是用户的待办，
      // 列出来只会添乱（勾选也不写盘）。
      if (meta.builtin) {
        continue;
      }
      let content: string = '';
      try {
        content = DocStore.readText(ctx, meta);
      } catch (err) {
        continue;
      }
      if (content.length > MAX_FILE_CHARS) {
        continue;
      }
      const lines: string[] = content.replace(/\r\n?/g, '\n').split('\n');
      let hitThisDoc: boolean = false;
      for (let i = 0; i < lines.length; i++) {
        const m: RegExpMatchArray | null = lines[i].match(BOX_RE);
        if (m === null) {
          continue;
        }
        const isDone: boolean = m[1] !== ' ';
        if (isDone) {
          done++;
        } else {
          open++;
        }
        if (!onlyOpen || !isDone) {
          if (items.length >= MAX_ITEMS) {
            truncated = true;
            break;
          }
          hitThisDoc = true;
          items.push({
            // ⚠️ 必须用 **name**（显示名，中文）而不是 fileName（磁盘文件名，英文）——
            // 用 fileName 会导致列表显示英文名、点击时按英文名查不到文档（"文件不存在"）。
            docName: meta.name, line: i + 1, text: m[2].trim(), done: isDone,
            builtin: meta.builtin, readOnly: DocStore.isReadOnly(ctx, meta.name)
          } as TaskItem);
        }
      }
      if (hitThisDoc) {
        docs++;
      }
    }

    return {
      items: items, open: open, done: done, docs: docs, truncated: truncated
    } as TaskBoardResult;
  }

  /** 一句话摘要（进度条式表述，便于放在书架横幅上）。 */
  static summary(r: TaskBoardResult): string {
    const total: number = r.open + r.done;
    if (total === 0) {
      return '还没有任务清单';
    }
    const pct: number = Math.round(r.done * 100 / total);
    return '待办 ' + r.open + ' · 已完成 ' + r.done + '（' + pct + '%）';
  }

  /**
   * 勾选 / 取消勾选某条任务并**写回原文**（用户要求：面板里勾了，文件里也跟着变）。
   *
   * 只改 `- [ ]` ↔ `- [x]` 那三个字符、不动行数 —— 块 id 与批注坐标都不漂移
   * （与阅读页正文里点勾选框是同一套改写逻辑）。
   *
   * 写盘判据：
   *  · 内置文档：正文在 rawfile，`update` 写的覆盖文件不会被 `readText` 读到
   *    （内置始终读包内），勾选等于白改 → 直接拒绝并说明；
   *  · 只读文档：与阅读页一致，勾选不写盘。
   *
   * @returns 空串 = 成功；非空 = 可直接展示给用户的失败原因。
   */
  static toggle(ctx: common.UIAbilityContext, docName: string, line: number): string {
    DocStore.init(ctx);
    const meta: DocMeta | undefined = DocStore.find(ctx, docName);
    if (meta === undefined) {
      return '找不到文档《' + docName + '》';
    }
    if (meta.builtin) {
      return '内置文档是只读的，勾选只在本次浏览内有效';
    }
    if (DocStore.isReadOnly(ctx, docName)) {
      return '《' + docName + '》被设为只读，勾选不会写盘';
    }
    let text: string = '';
    try {
      text = DocStore.readText(ctx, meta);
    } catch (err) {
      return '读取失败：' + DocStore.describeError(err as BusinessError);
    }
    const lines: string[] = text.replace(/\r\n?/g, '\n').split('\n');
    const i: number = line - 1;
    if (i < 0 || i >= lines.length) {
      return '无法定位原文第 ' + line + ' 行';
    }
    const raw: string = lines[i];
    const m: RegExpMatchArray | null = raw.match(BOX_RE);
    if (m === null) {
      return '这一行已经不是任务项（可能刚被编辑过）';
    }
    const at: number = raw.indexOf('[');
    if (at < 0) {
      return '无法定位勾选框';
    }
    lines[i] = raw.substring(0, at) + (m[1] === ' ' ? '[x]' : '[ ]') + raw.substring(at + 3);
    try {
      if (!DocStore.update(ctx, docName, lines.join('\n'))) {
        return '写回失败：文档已不存在';
      }
    } catch (err) {
      return '写回失败：' + DocStore.describeError(err as BusinessError);
    }
    return '';
  }
}
