import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker, storageStatistics } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import preferences from '@ohos.data.preferences';

/**
 * 备份 / 恢复（zip）
 * ===============
 *
 * 备份内容（1.1.1 起为**全量备份**，用户要求"备份整个应用的所有数据"）：
 *   · filesDir 顶层**全部条目**——docs / shelf.json / annotations / handwrite /
 *     drafts / fonts(+json) / review.json / review_stats.json / settings.json /
 *     tabs.json / 阅读背景图 / 壁纸 / 版本记录等，新增数据文件自动纳入；
 *   · preferences 快照——阅读设置等持久化键（导入后重启应用生效）。
 *
 * 两个实现要点：
 * 1. **zlib 只能读写沙箱路径，不能直接写 picker 返回的 uri**，
 *    所以流程是「先压到 cacheDir → 再拷到用户选的位置」。
 * 2. 导出/导入都走系统文件选择器（DocumentViewPicker），
 *    **不需要任何存储权限**，用户选什么我们才碰什么。
 */
export class BackupStore {
  /** 备份白名单（相对 filesDir） */
   /** 把沙箱文件拷到 picker 返回的 uri（覆盖写）。 */
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
   * 把全部数据打包成 zip：filesDir 顶层**全部条目**（docs / ai 会话 / 批注 /
   * 手写 / 壁纸 / 各 json 索引，新增数据文件自动纳入）+ preferences 设置快照。
   * 返回错误文案；空串 = 打包成功。本地导出与 WebDAV 完整备份共用。
   */
  static async packToZip(ctx: common.UIAbilityContext, outPath: string): Promise<string> {
    let items: string[] = [];
    try {
      const names: string[] = await fs.listFile(ctx.filesDir);
      for (let k = 0; k < names.length; k++) {
        items.push(ctx.filesDir + '/' + names[k]);
      }
    } catch (err) {
      return '读取数据目录失败';
    }
    if (items.length === 0) {
      return '还没有可备份的数据';
    }
    // **设置快照**：阅读设置等持久化键存在 preferences（filesDir 之外），
    // 拷一份进包里；导入时自动恢复（重启应用后生效）。
    const staging: string = ctx.cacheDir + '/pref_snapshot';
    try {
      fs.rmdirSync(staging);
    } catch (err) {
      // 无残留
    }
    try {
      const pnames: string[] = await fs.listFile(ctx.preferencesDir);
      if (pnames.length > 0) {
        fs.mkdirSync(staging, true);
        for (let k = 0; k < pnames.length; k++) {
          fs.copyFileSync(ctx.preferencesDir + '/' + pnames[k], staging + '/' + pnames[k]);
        }
        items.push(staging);
      }
    } catch (err) {
      // 设置快照失败不影响数据本体备份
    }
    try {
      try {
        fs.unlinkSync(outPath);
      } catch (err) {
        // 上次残留，忽略
      }
      const zipOptions: zlib.Options = {};
      await zlib.compressFiles(items, outPath, zipOptions);
      return '';
    } catch (err) {
      return '打包失败：' + (err as Error).message;
    }
  }

  /**
   * 从本地 zip 路径恢复：解压覆盖到 filesDir + 恢复 preferences 快照。
   * 返回给用户看的结果文案。「文件备份导入」与「WebDAV 恢复」共用。
   */
  static async restoreFromPath(ctx: common.UIAbilityContext, zipPath: string): Promise<string> {
    try {
      await zlib.decompressFile(zipPath, ctx.filesDir);
      // 恢复 preferences 快照（阅读设置等持久化键；**重启应用后全部生效**）
      const snap: string = ctx.filesDir + '/pref_snapshot';
      try {
        if (fs.accessSync(snap)) {
          const pnames: string[] = await fs.listFile(snap);
          for (let k = 0; k < pnames.length; k++) {
            fs.copyFileSync(snap + '/' + pnames[k], ctx.preferencesDir + '/' + pnames[k]);
          }
          fs.rmdirSync(snap);
          return '已恢复（设置将重启应用后生效），请返回书架查看';
        }
      } catch (err2) {
        // 偏好恢复失败不影响数据本体
      }
      return '已恢复，请返回书架查看（如未刷新请重进应用）';
    } catch (err) {
      return '恢复失败：' + (err as Error).message;
    }
  }

  /**
   * 导出 zip。返回给用户看的提示文案（空串 = 用户取消了选择）。
   */
  static async exportZip(ctx: common.UIAbilityContext): Promise<string> {
    // **先打包再让用户选位置**：打包失败（如无数据）提前暴露，不空跑一轮选择器
    const tmp: string = ctx.cacheDir + '/litemd_backup.zip';
    const packErr: string = await BackupStore.packToZip(ctx, tmp);
    if (packErr.length > 0) {
      return packErr;
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

    try {
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
    return BackupStore.importFromUri(ctx, uri);
  }

  /**
   * 从**给定的 uri** 导入备份（1.1.1：供应用关联 .zip 的「打开方式」直达）。
   * 不是澄笺备份结构的压缩包会在解压/校验时报错返回。
   */
  static async importFromUri(ctx: common.UIAbilityContext, uri: string): Promise<string> {
    const tmp: string = ctx.cacheDir + '/litemd_import.zip';
    try {
      BackupStore.copyFromUri(uri, tmp);
    } catch (err) {
      return '导入失败：' + (err as Error).message;
    }
    return BackupStore.restoreFromPath(ctx, tmp);
  }

  /** 缓存大小（系统统计的本应用 cacheSize），格式化 KB / MB。 */
  static async cacheSizeText(ctx: common.UIAbilityContext): Promise<string> {
    try {
      const stats: storageStatistics.BundleStats =
        await storageStatistics.getCurrentBundleStats();
      const bytes: number = stats.cacheSize as number;
      const mb: number = bytes / 1024 / 1024;
      return mb < 0.1 ? (bytes / 1024).toFixed(1) + ' KB' : mb.toFixed(2) + ' MB';
    } catch (err) {
      return '0 MB';
    }
  }

  /**
   * 清除应用缓存（cacheDir 全清，不动用户数据）。返回释放的字节数文案。
   *
   * ⚠️ fs **没有** `listFileSync`（目录列举只有异步版），所以这里用 await fs.listFile。
   */
  /**
   * **应用初始化**（用户要求：点击后清空应用全部数据，效果等同卸载重装）。
   *
   * 清空范围：
   *   ① filesDir 下全部内容（文档 / 批注 / AI 配置与会话 / 草稿 / 版本 / 设置镜像 / 壁纸 …）；
   *   ② cacheDir 下全部内容（缓存与临时包）；
   *   ③ 各类 Preferences（WebDAV 配置等；设置类键由调用方用 PersistentStorage.deleteProp 清）；
   *   ④ 持久化键（由调用方清，见 SettingsData.wipeAllData）。
   * 调用方最后 `terminateSelf()` 让应用退出——下次启动即全新安装的初始状态。
   */
  static async wipeAll(ctx: common.UIAbilityContext): Promise<string> {
    let failed: number = 0;
    // ① + ② 两个目录下逐个删（目录递归删；文件 unlink）
    const dirs: string[] = [ctx.filesDir, ctx.cacheDir];
    for (let d = 0; d < dirs.length; d++) {
      let names: string[] = [];
      try {
        names = await fs.listFile(dirs[d]);
      } catch (err) {
        continue;
      }
      for (let k = 0; k < names.length; k++) {
        const p: string = dirs[d] + '/' + names[k];
        try {
          const stat = fs.statSync(p);
          if (stat.isDirectory()) {
            fs.rmdirSync(p);
          } else {
            fs.unlinkSync(p);
          }
        } catch (err) {
          failed++;
        }
      }
    }
    // ③ Preferences（WebDAV 连接配置等）
    try {
      await preferences.deletePreferences(ctx, { name: 'webdav' });
    } catch (err) {
      // 删不到就不管（下次启动仍是默认空配置）
    }
    return failed === 0 ? '已清空应用数据' : '已清空（' + failed + ' 项未能删除）';
  }

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
