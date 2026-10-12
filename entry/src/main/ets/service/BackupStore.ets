import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker, storageStatistics } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import preferences from '@ohos.data.preferences';
import { DocStore } from './DocStore';
import { ReadingLog } from './ReadingLog';
import { WritingLog } from './WritingLog';
import { TabStore } from './TabStore';
import { FontStore } from './FontStore';
import { SettingsMirror } from './SettingsMirror';
import { L10n } from './L10n';
import { applyAppColorMode, applySystemBarTheme } from './AppWindow';
import { ReaderThemeMode } from '../theme/DesignTokens';

/**
 * 备份 / 恢复（zip）
 * ===============
 *
 * 备份内容（**全量**：用户要求"备份整个应用的所有数据"）：
 *   · filesDir 顶层**全部条目**——docs（正文与图片）/ shelf.json（书架与文件夹）/
 *     annotations（批注与学习卡）/ handwrite（手写）/ ai（对话与配置）/ drafts /
 *     versions / review*.json / reading-log.json / writing-log.json / tabs.json /
 *     settings.json（设置镜像）/ 壁纸与阅读背景图 …，新增数据文件自动纳入；
 *   · preferences 里的 WebDAV 配置——那部分**不在 filesDir**，打包前先 dump 成
 *     `webdav_config.json`（见 WEBDAV_SNAPSHOT），恢复时走 preferences API 写回。
 *
 * 恢复为什么不能"直接解压到 filesDir"（1.1.x 的老写法，实测数据没进来）：
 *   ① `zlib.decompressFile` 对"目标已存在同名文件"没有任何覆盖承诺，本机有数据时
 *      整批被跳过，看上去成功了，重启后还是老数据；
 *   ② 就算解压成功，运行中的进程手里还握着**恢复前**的内存缓存（DocStore 的索引、
 *      阅读/写作日志、标签页），下一次 persist 就把刚导入的文件盖回去了；
 *   ③ 设置存在 preferences（沙箱外），直接拷 XML 文件会被**已打开的实例**在下次
 *      flush 时冲掉。
 * 现在：解压到暂存目录 → 校验 → 同名先删再拷 → 走 API/内存重载 → 当场生效，不要求重启。
 *
 * 两个实现要点：
 * 1. **zlib 只能读写沙箱路径，不能直接写 picker 返回的 uri**，
 *    所以流程是「先压到 cacheDir → 再拷到用户选的位置」。
 * 2. 导出/导入都走系统文件选择器（DocumentViewPicker），
 *    **不需要任何存储权限**，用户选什么我们才碰什么。
 */
export class BackupStore {
  /** WebDAV 配置在包里的文件名（preferences 不在 filesDir，只能另存一份才能进 zip） */
  static readonly WEBDAV_SNAPSHOT: string = 'webdav_config.json';
  /** 必须与 WebDavStore.PREF_NAME / KEY_CONFIG 一致（那边改动要同步这里） */
  private static readonly WEBDAV_PREF_NAME: string = 'webdav';
  private static readonly WEBDAV_PREF_KEY: string = 'config';
  /** 解压暂存目录名（cacheDir 下，恢复完就删） */
  private static readonly STAGE: string = 'restore_stage';

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
   * 把全部数据打包成 zip：filesDir 顶层**全部条目**（docs / 批注 / 手写 / AI 会话 /
   * 草稿 / 版本 / 各日志 / 壁纸 / 书架索引 / 设置镜像，新增数据文件自动纳入）
   * + preferences 里的 WebDAV 配置快照。
   * 返回错误文案；空串 = 打包成功。本地导出与 WebDAV 完整备份共用。
   */
  static async packToZip(ctx: common.UIAbilityContext, outPath: string): Promise<string> {
    // 打包前先把两份"活在内存 / 沙箱外"的状态落成文件，包里才有它们：
    //   · settings.json —— 设置镜像（PersistentStorage 的键全在这里，恢复时回填 AppStorage）
    //   · webdav_config.json —— WebDAV 账号配置（存在 preferences 目录，不在 filesDir）
    SettingsMirror.save(ctx);
    BackupStore.dumpWebDavConfig(ctx);
    // ⚠️ **分类结构必须保留**（用户实测：多目录直接 compressFiles 会被拍平到 zip 根，
    // 导入后 docs/ 批注等全部散架、数据恢复不进来）。做法：先把 filesDir 全部内容
    // 复制到暂存目录的 data/ 子目录下，再对这一个文件夹整体压缩——内部目录结构
    // （docs / annotations / shelf.json …）原样进包，与示例数据包的布局一致。
    const stage: string = ctx.cacheDir + '/bk_stage';
    try {
      fs.rmdirSync(stage);
    } catch (err) {
      // 没有上一次的残留
    }
    try {
      fs.mkdirSync(stage, true);
    } catch (err) {
      return '创建暂存目录出错';
    }
    try {
      await BackupStore.copyInto(ctx.filesDir, stage + '/data');
    } catch (err) {
      return '收集数据失败：' + (err as Error).message;
    }
    let dataEntries: string[] = [];
    try {
      dataEntries = await fs.listFile(stage + '/data');
    } catch (err) {
      dataEntries = [];
    }
    if (dataEntries.length === 0) {
      try {
        fs.rmdirSync(stage);
      } catch (err) {
        // 占缓存而已
      }
      return '还没有可备份的数据';
    }
    try {
      try {
        fs.unlinkSync(outPath);
      } catch (err) {
        // 上次残留，忽略
      }
      const zipOptions: zlib.Options = {};
      await zlib.compressFiles([stage + '/data'], outPath, zipOptions);
      return '';
    } catch (err) {
      return '打包失败：' + (err as Error).message;
    } finally {
      try {
        fs.rmdirSync(stage);
      } catch (err) {
        // 删不掉只是占缓存
      }
    }
  }

  /**
   * 把 WebDAV 配置（preferences 里的一段 JSON）写进 filesDir，让它能进备份包。
   * 没配置过时删掉旧副本 —— 否则恢复会把用户已经清掉的配置又带回来。
   */
  private static dumpWebDavConfig(ctx: common.UIAbilityContext): void {
    const target: string = ctx.filesDir + '/' + BackupStore.WEBDAV_SNAPSHOT;
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(ctx, { name: BackupStore.WEBDAV_PREF_NAME });
      const raw: string = store.getSync(BackupStore.WEBDAV_PREF_KEY, '') as string;
      if (raw.length === 0) {
        try {
          if (fs.accessSync(target)) {
            fs.unlinkSync(target);
          }
        } catch (err) {
          // 本来就没有
        }
        return;
      }
      const file: fs.File = fs.openSync(target,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, raw);
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      // 配置快照失败不影响数据本体备份
    }
  }

  /** 恢复时反过来：包里的 JSON 写回 preferences（走 API，运行中的实例不会把它冲掉），再删中转文件。 */
  private static applyWebDavConfig(ctx: common.UIAbilityContext): void {
    const src: string = ctx.filesDir + '/' + BackupStore.WEBDAV_SNAPSHOT;
    try {
      if (!fs.accessSync(src)) {
        return;
      }
      const raw: string = fs.readTextSync(src, { encoding: 'utf-8' });
      if (raw.length > 0) {
        const store: preferences.Preferences =
          preferences.getPreferencesSync(ctx, { name: BackupStore.WEBDAV_PREF_NAME });
        store.putSync(BackupStore.WEBDAV_PREF_KEY, raw);
        store.flush();
      }
      fs.unlinkSync(src);
    } catch (err) {
      // 配置恢复失败不影响数据本体
    }
  }

  /**
   * 把 from 目录里的内容覆盖拷贝进 to 目录：同名先删（目录递归删）再拷，目录递归。
   * 返回实际写入的**文件**数（目录不计）。
   */
  private static async copyInto(from: string, to: string): Promise<number> {
    const names: string[] = await fs.listFile(from);
    let count: number = 0;
    for (let k = 0; k < names.length; k++) {
      const src: string = from + '/' + names[k];
      const dst: string = to + '/' + names[k];
      let isDir: boolean = false;
      try {
        isDir = fs.statSync(src).isDirectory();
      } catch (err) {
        continue;
      }
      try {
        if (fs.accessSync(dst)) {
          if (isDir) {
            fs.rmdirSync(dst);
          } else {
            fs.unlinkSync(dst);
          }
        }
      } catch (err) {
        // 目标本来不存在
      }
      if (isDir) {
        try {
          fs.mkdirSync(dst, true);
        } catch (err) {
          // 已存在
        }
        count += await BackupStore.copyInto(src, dst);
      } else {
        fs.copyFileSync(src, dst);
        count++;
      }
    }
    return count;
  }

  /**
   * 从本地 zip 路径恢复。**五步**（少任何一步都会出现"导入成功但数据没进来"）：
   *   ① 解压到 cacheDir 暂存目录（不直接解压进 filesDir：decompressFile 对已存在
   *      文件没有覆盖承诺，本机有数据时可能整批跳过）；
   *   ② 校验包内容像澄笺备份，不像就直接报错，别把用户的数据目录搞坏；
   *   ③ 覆盖拷贝进 filesDir（同名先删再拷，行为完全确定）；
   *   ④ 回填运行中的进程：settings.json → AppStorage（持久化键会写穿 preferences）、
   *      WebDAV 配置 → preferences API、语言 → 刷新计数、字体 → registerFont、
   *      深浅色 → applyAppColorMode，这些就是"必须重启应用"的那批；
   *   ⑤ 重载各内存缓存（DocStore / 阅读日志 / 写作日志 / 标签页）——不重载的话下一次
   *      persist 会把恢复前的内存状态写回刚导入的文件。
   * 返回给用户看的结果文案。「文件备份导入」与「WebDAV 恢复」共用。
   */
  static async restoreFromPath(ctx: common.UIAbilityContext, zipPath: string): Promise<string> {
    const stage: string = ctx.cacheDir + '/' + BackupStore.STAGE;
    try {
      fs.rmdirSync(stage);
    } catch (err) {
      // 没有上一次的残留
    }
    try {
      fs.mkdirSync(stage, true);
    } catch (err) {
      return '恢复失败：创建临时目录出错';
    }
    try {
      await zlib.decompressFile(zipPath, stage);
    } catch (err) {
      return '恢复失败：备份包读不出来（' + (err as Error).message + '）';
    }
    // 兼容两种包布局：① 分类布局（shelf.json / docs / annotations … 在根，示例数据包即此）
    // ② data/ 前缀布局（新版导出用单文件夹压缩，包内多一层 data/）
    let src: string = stage;
    let entries: string[] = [];
    try {
      entries = await fs.listFile(stage);
    } catch (err) {
      entries = [];
    }
    if (entries.length === 1 && entries[0] === 'data') {
      src = stage + '/data';
      try {
        entries = await fs.listFile(src);
      } catch (err) {
        entries = [];
      }
    }
    if (entries.length === 0) {
      return '恢复失败：备份包是空的';
    }
    if (entries.indexOf('shelf.json') < 0 && entries.indexOf('settings.json') < 0
      && entries.indexOf('docs') < 0 && entries.indexOf('annotations') < 0) {
      return '恢复失败：这不是澄笺的备份包（没找到书架索引或数据目录）';
    }
    let files: number = 0;
    try {
      files = await BackupStore.copyInto(src, ctx.filesDir);
    } catch (err) {
      return '恢复失败：写入数据目录出错（' + (err as Error).message + '）';
    }
    try {
      fs.rmdirSync(stage);
    } catch (err) {
      // 删不掉只是占缓存
    }
    // 老备份（1.1.x）里塞的是 preferences 的**原始 XML 目录**：那种恢复方式不可靠
    // （进程里那些实例还开着，下次 flush 就冲掉了），现在改走 settings.json 回填
    // AppStorage + WebDAV 配置走 preferences API。这里把残留清掉，免得它留在数据目录里
    // 被下一次备份反复打包（既占空间，又把凭据多复制一份）。
    try {
      const legacy: string = ctx.filesDir + '/pref_snapshot';
      if (fs.accessSync(legacy)) {
        fs.rmdirSync(legacy);
      }
    } catch (err) {
      // 本来就没有
    }
    SettingsMirror.forceRestore(ctx);
    BackupStore.applyWebDavConfig(ctx);
    L10n.reapply();
    DocStore.reload(ctx);
    ReadingLog.reload(ctx);
    WritingLog.reload(ctx);
    TabStore.reload(ctx);
    // 用户字体：恢复进来的字体文件还没注册到字体模块，注册一次（否则正文按回退字体显示）
    FontStore.invalidateCache();
    FontStore.registerAll(ctx);
    // 深浅色模式是 ability 级设置，恢复后要立刻重设（不然恢复了深色主题仍是浅色界面）
    const mode: number | undefined = AppStorage.get<number>('readerThemeMode');
    const themeMode: number = mode === undefined || mode === null ? ReaderThemeMode.System : mode;
    applyAppColorMode(themeMode);
    const sysDark: boolean | undefined = AppStorage.get<boolean>('systemDark');
    applySystemBarTheme(themeMode === ReaderThemeMode.Dark
      || (themeMode === ReaderThemeMode.System && sysDark === true));
    SettingsMirror.bumpTick();
    return '已恢复 ' + files + ' 项数据，书架、设置与语言立即生效';
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
      // **备份文件名：澄笺_年月日_时分秒**（用户要求）：澄笺_20261012_193045.zip
      const now: Date = new Date();
      const pad = (v: number): string => {
        return v < 10 ? '0' + v : '' + v;
      };
      const stamp: string = now.getFullYear() + pad(now.getMonth() + 1) + pad(now.getDate())
        + '_' + pad(now.getHours()) + pad(now.getMinutes()) + pad(now.getSeconds());
      options.newFileNames = ['澄笺_' + stamp + '.zip'];
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
    return failed === 0 ? L10n.t('已清空应用数据') : L10n.t('已清空（') + failed + ' 项未能删除）';
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
    return kb > 0 ? L10n.t('已清除缓存 ') + kb + ' KB' : L10n.t('缓存已经是最干净的状态');
  }
}
