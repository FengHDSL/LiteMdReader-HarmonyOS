import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';

/**
 * 备份 / 恢复（zip）
 * ===============
 *
 * 备份内容（白名单，只备份「用户数据」，不含缓存与渲染资源）：
 *   · docs/          —— 用户文档与文档内图片
 *   · shelf.json     —— 书架索引（文件夹、顺序）
 *   · annotations/   —— 批注
 *   · handwrite/     —— 手写笔迹
 *
 * 两个实现要点：
 * 1. **zlib 只能读写沙箱路径，不能直接写 picker 返回的 uri**，
 *    所以流程是「先压到 cacheDir → 再拷到用户选的位置」。
 * 2. 导出/导入都走系统文件选择器（DocumentViewPicker），
 *    **不需要任何存储权限**，用户选什么我们才碰什么。
 */
export class BackupStore {
  /** 备份白名单（相对 filesDir） */
  private static readonly ITEMS: string[] = ['docs', 'shelf.json', 'annotations', 'handwrite'];

  /** 沙箱里存在的数据项 */
  private static existItems(ctx: common.UIAbilityContext): string[] {
    const out: string[] = [];
    for (let k = 0; k < BackupStore.ITEMS.length; k++) {
      const p: string = ctx.filesDir + '/' + BackupStore.ITEMS[k];
      try {
        if (fs.accessSync(p)) {
          out.push(p);
        }
      } catch (err) {
        // 不存在就跳过
      }
    }
    return out;
  }

  /** 把沙箱文件拷到 picker 返回的 uri（覆盖写）。 */
  private static copyToUri(srcPath: string, uri: string): void {
    const src = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
    const dst = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      const buf = new ArrayBuffer(64 * 1024);
      let read: number = fs.readSync(src.fd, buf);
      while (read > 0) {
        fs.writeSync(dst.fd, buf, { length: read });
        read = fs.readSync(src.fd, buf);
      }
    } finally {
      fs.closeSync(src);
      fs.closeSync(dst);
    }
  }

  /** 把 uri 指向的文件拷进沙箱。 */
  private static copyFromUri(uri: string, dstPath: string): void {
    const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const dst = fs.openSync(dstPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      const buf = new ArrayBuffer(64 * 1024);
      let read: number = fs.readSync(src.fd, buf);
      while (read > 0) {
        fs.writeSync(dst.fd, buf, { length: read });
        read = fs.readSync(src.fd, buf);
      }
    } finally {
      fs.closeSync(src);
      fs.closeSync(dst);
    }
  }

  /**
   * 导出 zip。返回给用户看的提示文案（空串 = 用户取消了选择）。
   */
  static async exportZip(ctx: common.UIAbilityContext): Promise<string> {
    const items: string[] = BackupStore.existItems(ctx);
    if (items.length === 0) {
      return '还没有可备份的数据';
    }
    let uri: string = '';
    try {
      const options = new picker.DocumentSaveOptions();
      // **备份文件名带日期**（用户要求）：澄笺备份_2026-10-01.zip
      const now: Date = new Date();
      const pad = (v: number): string => {
        return v < 10 ? '0' + v : '' + v;
      };
      const stamp: string = now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate());
      options.newFileNames = ['澄笺备份_' + stamp + '.zip'];
      const viewPicker = new picker.DocumentViewPicker(ctx);
      const uris: string[] = await viewPicker.save(options);
      if (uris === undefined || uris === null || uris.length === 0) {
        return '';
      }
      uri = uris[0];
    } catch (err) {
      return '打开保存位置失败';
    }

    const tmp: string = ctx.cacheDir + '/litemd_backup.zip';
    try {
      try {
        fs.unlinkSync(tmp);
      } catch (err) {
        // 上次残留，忽略
      }
      const zipOptions: zlib.Options = {};
      await zlib.compressFiles(items, tmp, zipOptions);
      BackupStore.copyToUri(tmp, uri);
      return '备份已导出（zip）';
    } catch (err) {
      return '导出失败：' + (err as Error).message;
    }
  }

  /**
   * 从 zip 恢复。返回提示文案（空串 = 用户取消）。
   * 注意：会**覆盖**同名数据，导入前请确认已备份当前数据。
   */
  static async importZip(ctx: common.UIAbilityContext): Promise<string> {
    let uri: string = '';
    try {
      const options = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = ['.zip'];
      const viewPicker = new picker.DocumentViewPicker(ctx);
      const uris: string[] = await viewPicker.select(options);
      if (uris === undefined || uris === null || uris.length === 0) {
        return '';
      }
      uri = uris[0];
    } catch (err) {
      return '打开文件失败';
    }

    const tmp: string = ctx.cacheDir + '/litemd_import.zip';
    try {
      BackupStore.copyFromUri(uri, tmp);
      await zlib.decompressFile(tmp, ctx.filesDir);
      return '已导入备份，请返回书架查看（如未刷新请重进应用）';
    } catch (err) {
      return '导入失败：' + (err as Error).message;
    }
  }

  /**
   * 清除应用缓存（cacheDir 全清，不动用户数据）。返回释放的字节数文案。
   *
   * ⚠️ fs **没有** `listFileSync`（目录列举只有异步版），所以这里用 await fs.listFile。
   */
  static async clearCache(ctx: common.UIAbilityContext): Promise<string> {
    let freed: number = 0;
    let names: string[] = [];
    try {
      names = await fs.listFile(ctx.cacheDir);
    } catch (err) {
      return '缓存目录不可读';
    }
    for (let k = 0; k < names.length; k++) {
      const p: string = ctx.cacheDir + '/' + names[k];
      try {
        const stat = fs.statSync(p);
        if (stat.isDirectory()) {
          fs.rmdirSync(p);
        } else {
          freed += stat.size;
          fs.unlinkSync(p);
        }
      } catch (err) {
        // 单个删除失败不影响整体
      }
    }
    const kb: number = Math.round(freed / 1024);
    return kb > 0 ? '已清除缓存 ' + kb + ' KB' : '缓存已经是最干净的状态';
  }
}
