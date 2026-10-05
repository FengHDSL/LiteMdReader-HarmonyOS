/**
 * 澄笺 · 编辑页草稿（EditorDraft）
 * ================================
 *
 * 「还有未保存的修改」弹窗里新增的「直接离开」用（用户要求）：
 *   不写入文档正文，但把当前内容**存一份草稿**；下次打开同一篇文档时
 *   自动恢复并提示 —— 走人的路要顺，内容不能丢。
 *
 * 存储：`<filesDir>/drafts/<文档名>.md`，一篇一个文件（与 VersionStore 的
 * 按文档名落盘同一套惯例，中文文档名沙箱内没有问题）。
 *
 * 生命周期：
 *   · 写入：弹窗点「直接离开」时（save 由调用方负责传当前内容）；
 *   · 恢复：Editor.loadExisting 读完正文后比对，不同才恢复（相同 = 上次
 *     离开后没再改过文档，静默清掉即可）；
 *   · 清除：保存成功（草稿已无意义）或弹窗点「不保存」（明确丢弃）时。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export class EditorDraft {
  private static dirPath(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/drafts';
  }

  private static filePath(ctx: common.UIAbilityContext, docName: string): string {
    return EditorDraft.dirPath(ctx) + '/' + docName + '.md';
  }

  /** 存草稿（覆盖式，一篇文档只保留最新一份）。 */
  static save(ctx: common.UIAbilityContext, docName: string, content: string): boolean {
    if (docName.length === 0) {
      return false;
    }
    try {
      try {
        if (!fs.accessSync(EditorDraft.dirPath(ctx))) {
          fs.mkdirSync(EditorDraft.dirPath(ctx), true);
        }
      } catch (dirErr) {
        // 目录已存在
      }
      const stat: fs.Stat = fs.statSync(EditorDraft.dirPath(ctx));
      if (!stat.isDirectory()) {
        return false;
      }
      const file: fs.File = fs.openSync(EditorDraft.filePath(ctx, docName),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, content);
      fs.closeSync(file);
      return true;
    } catch (err) {
      hilog.error(0x0000, 'EditorDraft', 'save failed: %{public}s',
        (err as Error).message);
      return false;
    }
  }

  /** 读草稿；没有或读失败返回空串。 */
  static load(ctx: common.UIAbilityContext, docName: string): string {
    if (docName.length === 0) {
      return '';
    }
    try {
      const path: string = EditorDraft.filePath(ctx, docName);
      if (!fs.accessSync(path)) {
        return '';
      }
      return fs.readTextSync(path, { encoding: 'utf-8' });
    } catch (err) {
      return '';
    }
  }

  /** 清除草稿（保存成功 / 明确丢弃后调用；文件不存在时静默）。 */
  static clear(ctx: common.UIAbilityContext, docName: string): void {
    if (docName.length === 0) {
      return;
    }
    try {
      const path: string = EditorDraft.filePath(ctx, docName);
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (err) {
      // 清不掉也不影响主流程
    }
  }
}
