/**
 * 澄笺 · 编辑版本历史（快照存储）
 * ================================
 *
 * 每篇文档的编辑快照落在 `<filesDir>/versions/<文档名>.json`：
 *   { list: [{ ts, chars, content }, ...] }  —— 新快照在前。
 *
 * 策略：
 *   · 与最新快照内容完全相同的不重复存；
 *   · 上限 50 份，超出从最旧的开始丢（正文都是小文件，50 份可控）；
 *   · 手动保存 / 自动保存（间隔可在版本历史面板里设置）都走 snapshot()。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export interface VersionSnapshot {
  /** 快照时间（ms） */
  ts: number;
  /** 正文字符数 */
  chars: number;
  content: string;
}

interface VersionFile {
  list: VersionSnapshot[];
}

const MAX_VERSIONS: number = 50;

export class VersionStore {
  private static dirPath(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/versions';
  }

  private static filePath(ctx: common.UIAbilityContext, docName: string): string {
    return VersionStore.dirPath(ctx) + '/' + docName + '.json';
  }

  /** 全部快照（新的在前）。无记录返回空数组。 */
  static list(ctx: common.UIAbilityContext, docName: string): VersionSnapshot[] {
    try {
      const path: string = VersionStore.filePath(ctx, docName);
      if (!fs.accessSync(path)) {
        return [];
      }
      const text: string = fs.readTextSync(path, { encoding: 'utf-8' });
      if (text.length === 0) {
        return [];
      }
      const parsed: VersionFile = JSON.parse(text) as VersionFile;
      if (parsed === null || parsed === undefined || parsed.list === undefined) {
        return [];
      }
      return parsed.list;
    } catch (err) {
      hilog.warn(0x0000, 'VersionStore', 'list failed: %{public}s', (err as Error).message);
      return [];
    }
  }

  /**
   * 记一份快照。与最新快照相同则跳过（返回 false）；
   * 超过上限时丢掉最旧的。失败静默（历史丢了不影响正文）。
   */
  static snapshot(ctx: common.UIAbilityContext, docName: string, content: string): boolean {
    if (docName.length === 0 || content.length === 0) {
      return false;
    }
    try {
      try {
        if (!fs.accessSync(VersionStore.dirPath(ctx))) {
          fs.mkdirSync(VersionStore.dirPath(ctx), true);
        }
      } catch (dirErr) {
        // 目录已存在
      }
      const list: VersionSnapshot[] = VersionStore.list(ctx, docName);
      if (list.length > 0 && list[0].content === content) {
        return false;
      }
      const snap: VersionSnapshot = {
        ts: Date.now(),
        chars: content.length,
        content: content
      };
      list.unshift(snap);
      while (list.length > MAX_VERSIONS) {
        list.pop();
      }
      const file: fs.File = fs.openSync(VersionStore.filePath(ctx, docName),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify({ list: list } as VersionFile));
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
      return true;
    } catch (err) {
      hilog.warn(0x0000, 'VersionStore', 'snapshot failed: %{public}s', (err as Error).message);
      return false;
    }
  }
}
