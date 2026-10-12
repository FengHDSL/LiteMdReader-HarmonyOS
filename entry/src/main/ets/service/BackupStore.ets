import { bundleManager, common } from '@kit.AbilityKit';
import { fileIo as fs, picker, storageStatistics } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import preferences from '@ohos.data.preferences';
import { DocStore } from './DocStore';
import { ReadingLog } from './ReadingLog';
import { WritingLog } from './WritingLog';
import { TabStore } from './TabStore';
import { FontStore } from './FontStore';
import { ChartCache } from './ChartCache';
import { WallpaperStore } from './WallpaperStore';
import { SettingsMirror } from './SettingsMirror';
import { L10n } from './L10n';
import { applyAppColorMode, applySystemBarTheme } from './AppWindow';
import { ReaderThemeMode } from '../theme/DesignTokens';

/** 一次拷贝的结果统计（导出算规模、导入写汇报都用它） */
interface CopyStat {
  files: number;
  bytes: number;
  failed: number;
}

/**
 * 备份包里的一个**数据类别** = zip 内的一个文件夹 ↔ 沙箱里的一个真实位置。
 * 导出按这张表收集，导入按同一张表写回，两边永远同一口径。
 */
interface BackupCategory {
  /** 类别 id，同时就是 zip 里的文件夹名（纯 ASCII：跨设备解压不会因为编码变形） */
  id: string;
  /** 中文名，写进 manifest.json 给人看 */
  label: string;
  /** 落点根：ROOT_FILES / ROOT_CACHE / ROOT_APP / ROOT_PREF */
  root: string;
  /** 该类别在落点根下的相对路径，允许一个 `*` 通配（壁纸那类带时间戳的文件名） */
  sources: string[];
  /** 本次导出/导入实际写入的文件数与字节数 */
  files: number;
  bytes: number;
}

/** manifest.json 里一个类别的记录（给人看，也用于导入自检） */
interface ManifestCategory {
  id: string;
  label: string;
  target: string;
  files: number;
  bytes: number;
}

/** 备份包清单：zip 根目录的 manifest.json */
interface BackupManifest {
  app: string;
  format: number;
  exportedAt: number;
  exportedText: string;
  versionName: string;
  totalFiles: number;
  totalBytes: number;
  categories: ManifestCategory[];
}

/**
 * 备份 / 恢复（zip）
 * ==================
 *
 * **包内布局：按数据类别分文件夹，另附一份 manifest.json 清单**（用户要求：
 * 「压缩包要对文件做好文件夹分类，导入系统识别对应文件夹里的对应文件」）：
 *
 * ```
 * backup/
 *   manifest.json          清单：格式版本、导出时间、应用版本、每类的落点/文件数/字节数
 *   docs/                  → filesDir/docs/            文档正文与本地图片
 *   shelf/shelf.json       → filesDir/shelf.json       书架索引（文件夹归组、阅读进度）
 *   annotations/           → filesDir/annotations/     批注与学习卡
 *   handwrite/             → filesDir/sketch.handwrite 手写笔迹
 *   ai/                    → filesDir/ai/              AI 接口配置与会话历史
 *   drafts/                → filesDir/drafts/          编辑草稿
 *   versions/              → filesDir/versions/        版本快照
 *   fonts/                 → filesDir/fonts/ + fonts.json      用户字体
 *   wallpaper/             → filesDir/wallpaper*.img + reader_bg*.img  壁纸与阅读背景
 *   logs/                  → filesDir/reading-log.json + writing-log.json
 *   tabs/tabs.json         → filesDir/tabs.json        阅读标签页
 *   review/                → filesDir/review.json + review_stats.json  复习数据与统计
 *   settings/              → filesDir/settings.json + image_hidden.json 设置快照
 *   webdav/                → preferences(webdav/config) 网盘账号配置（沙箱外，走 API 写回）
 *   form/                  → 应用级 filesDir/form_snapshot.json  桌面卡片快照
 *   cache/                 → cacheDir/charts/ + cacheDir/export/ 图表与导出缓存
 *   extra/                 → filesDir/<原名>           兜底：以后新增的数据文件自动纳入
 * ```
 *
 * 规则只有一条，因此天然可逆：**zip 里的路径 = `<类别文件夹>/<沙箱内相对路径>`**。
 * 导出把每个来源原样搬进类别文件夹，导入把类别文件夹里的内容原样搬回落点根，
 * 不需要额外的映射表就能对上号（`fonts/fonts/x.ttf` 回到 `filesDir/fonts/x.ttf`）。
 *
 * 为什么分类而不是一股脑压 filesDir（旧做法）：
 *   · filesDir / cacheDir / 应用级 filesDir / preferences 是**四个不同的落点**，
 *     旧做法只覆盖 filesDir，缓存与网盘凭据永远备不上、也恢复不回来；
 *   · 分类后 manifest 里每类多少文件一目了然，导入结果能按类别汇报；
 *   · 老包（1.1.x：整目录平铺、或外面套一层 `data/`）导入时自动识别，见 findPackageRoot。
 *
 * 恢复为什么不能「直接解压进沙箱」（1.1.x 的老写法，实测数据没进来）：
 *   ① `zlib.decompressFile` 对「目标已存在同名文件」没有任何覆盖承诺，本机有数据时
 *      整批被跳过，看上去成功了，重启后还是老数据；
 *   ② 就算解压成功，运行中的进程手里还握着**恢复前**的内存缓存（书架索引、
 *      阅读/写作日志、标签页、图表缓存），下一次 persist 就把刚导入的文件盖回去；
 *   ③ 设置存在 preferences（沙箱外），直接拷 XML 文件会被**已打开的实例**在下次
 *      flush 时冲掉。
 * 现在：解压到暂存目录 → 认清单/认类别文件夹 → 同名先删再拷到各自的落点 →
 *       走 API 与内存重载 → 当场生效，不要求重启。
 *
 * 三个实现要点：
 * 1. **zlib 只能读写沙箱路径，不能直接写 picker 返回的 uri**，
 *    所以流程是「先压到 cacheDir → 再拷到用户选的位置」。
 * 2. **compressFiles 只传一个目录**：实测传多个目录会被拍平到 zip 根，
 *    内部分类结构全散架，所以先把内容收集到 `<stage>/backup/` 再整体压这一个目录。
 * 3. **导入只覆盖、不删除**：同名文件先删再拷，目录只合并——导入不会顺手删掉本机
 *    多出来的数据。误删不可逆，多留一个文件只是占空间。
 */
export class BackupStore {
  /** 包格式版本：2 = 分类文件夹 + manifest.json；1 = 旧版整目录平铺 */
  static readonly FORMAT: number = 2;
  /** zip 根的清单文件名 */
  static readonly MANIFEST: string = 'manifest.json';
  /** WebDAV 配置在包里的文件名（它活在 preferences，不在任何 filesDir 里） */
  static readonly WEBDAV_SNAPSHOT: string = 'webdav_config.json';

  /** 必须与 WebDavStore.PREF_NAME / KEY_CONFIG 一致（那边改动要同步这里） */
  private static readonly WEBDAV_PREF_NAME: string = 'webdav';
  private static readonly WEBDAV_PREF_KEY: string = 'config';
  /** 打包用的暂存目录名（cacheDir 下） */
  private static readonly PACK_STAGE: string = 'bk_stage';
  /** 解压用的暂存目录名（cacheDir 下，恢复完就删） */
  private static readonly STAGE: string = 'restore_stage';
  /** 暂存目录里那层唯一的顶层文件夹：compressFiles 传单个目录才保得住内部结构 */
  private static readonly TOP: string = 'backup';

  /** 落点根：HAP 级 filesDir（绝大多数数据） */
  private static readonly ROOT_FILES: string = 'files';
  /** 落点根：cacheDir（图表缓存、导出中转） */
  private static readonly ROOT_CACHE: string = 'cache';
  /** 落点根：应用级 filesDir（桌面卡片跨进程数据，见 FormSync 头注释） */
  private static readonly ROOT_APP: string = 'app';
  /** 落点根：preferences（沙箱外，只能走 API 读写） */
  private static readonly ROOT_PREF: string = 'pref';

  /** filesDir 顶层里**不进备份**的条目：中转文件与老版本的 preferences XML 目录 */
  private static readonly SKIP: string[] = ['webdav_config.json', 'pref_snapshot'];

  /** 最近一次打包的结果摘要（exportZip 用它汇报「导出多少个文件、几类数据」） */
  private static lastPackText: string = '';

  /**
   * 类别表：**唯一口径**。加一类数据只要在这里加一行，导出与导入同时生效。
   * 顺序就是 manifest 与导入汇报里的顺序（按用户关心的程度排）。
   */
  private static categories(): BackupCategory[] {
    const f: string = BackupStore.ROOT_FILES;
    const list: BackupCategory[] = [];
    list.push({ id: 'docs', label: '文档与图片', root: f, sources: ['docs'], files: 0, bytes: 0 } as BackupCategory);
    list.push({ id: 'shelf', label: '书架索引', root: f, sources: ['shelf.json'], files: 0, bytes: 0 } as BackupCategory);
    list.push({
      id: 'annotations', label: '批注与学习卡', root: f, files: 0, bytes: 0,
      sources: ['annotations']
    } as BackupCategory);
    list.push({
      id: 'handwrite', label: '手写笔迹', root: f, files: 0, bytes: 0,
      sources: ['sketch.handwrite']
    } as BackupCategory);
    list.push({ id: 'ai', label: 'AI 配置与会话', root: f, sources: ['ai'], files: 0, bytes: 0 } as BackupCategory);
    list.push({ id: 'drafts', label: '编辑草稿', root: f, sources: ['drafts'], files: 0, bytes: 0 } as BackupCategory);
    list.push({
      id: 'versions', label: '版本快照', root: f, files: 0, bytes: 0,
      sources: ['versions']
    } as BackupCategory);
    list.push({
      id: 'fonts', label: '用户字体', root: f, files: 0, bytes: 0,
      sources: ['fonts', 'fonts.json']
    } as BackupCategory);
    list.push({
      id: 'wallpaper', label: '壁纸与阅读背景', root: f, files: 0, bytes: 0,
      sources: ['wallpaper.img', 'wallpaper_*.img', 'reader_bg.img', 'reader_bg_*.img']
    } as BackupCategory);
    list.push({
      id: 'logs', label: '阅读与写作日志', root: f, files: 0, bytes: 0,
      sources: ['reading-log.json', 'writing-log.json']
    } as BackupCategory);
    list.push({ id: 'tabs', label: '阅读标签页', root: f, sources: ['tabs.json'], files: 0, bytes: 0 } as BackupCategory);
    list.push({
      id: 'review', label: '复习数据与统计', root: f, files: 0, bytes: 0,
      sources: ['review.json', 'review_stats.json']
    } as BackupCategory);
    list.push({
      id: 'settings', label: '设置快照', root: f, files: 0, bytes: 0,
      sources: ['settings.json', 'image_hidden.json']
    } as BackupCategory);
    // preferences 不在任何 filesDir 里：导出时直接从 preferences 读出来写进包，
    // 导入时走 preferences API 写回（拷 XML 文件会被运行中的实例下次 flush 冲掉）
    list.push({
      id: 'webdav', label: '网盘账号配置', root: BackupStore.ROOT_PREF, files: 0, bytes: 0,
      sources: [BackupStore.WEBDAV_SNAPSHOT]
    } as BackupCategory);
    list.push({
      id: 'form', label: '桌面卡片快照', root: BackupStore.ROOT_APP, files: 0, bytes: 0,
      sources: ['form_snapshot.json']
    } as BackupCategory);
    list.push({
      id: 'cache', label: '图表与导出缓存', root: BackupStore.ROOT_CACHE, files: 0, bytes: 0,
      sources: ['charts', 'export']
    } as BackupCategory);
    // 兜底：filesDir 顶层里没被上面任何类别认领的条目。**以后新增数据文件自动纳入**，
    // 不用再改这张表（也不会因为忘了改表而"备份少一项"）
    list.push({ id: 'extra', label: '其他数据文件', root: f, sources: ['*'], files: 0, bytes: 0 } as BackupCategory);
    return list;
  }

  /** 类别 id → 类别；没有返回 null（zip 里的未知文件夹靠它识别） */
  private static categoryById(list: BackupCategory[], id: string): BackupCategory | null {
    for (let k = 0; k < list.length; k++) {
      if (list[k].id === id) {
        return list[k];
      }
    }
    return null;
  }

  /** 落点根 → 沙箱绝对路径 */
  private static rootDir(root: string, ctx: common.UIAbilityContext): string {
    if (root === BackupStore.ROOT_CACHE) {
      return ctx.cacheDir;
    }
    if (root === BackupStore.ROOT_APP) {
      // 应用级 filesDir（…/base/files）与 HAP 级（…/haps/entry/files）不是同一个路径，
      // 桌面卡片数据只在应用级目录里，两个进程才都读得到（详见 FormSync 头注释）
      try {
        return ctx.getApplicationContext().filesDir;
      } catch (err) {
        return ctx.filesDir;
      }
    }
    return ctx.filesDir;
  }

  /** manifest 里给人看的落点说明 */
  private static targetOf(cat: BackupCategory): string {
    if (cat.root === BackupStore.ROOT_PREF) {
      return 'preferences:' + BackupStore.WEBDAV_PREF_NAME + '/' + BackupStore.WEBDAV_PREF_KEY;
    }
    const prefix: string = cat.root === BackupStore.ROOT_CACHE ? 'cacheDir/'
      : (cat.root === BackupStore.ROOT_APP ? '应用级 filesDir/' : 'filesDir/');
    return prefix + cat.sources.join(', ');
  }

  /** 单层目录列举；读不到就当空目录（**不抛**：一个坏目录不该中断整包备份） */
  private static listNames(dir: string): string[] {
    try {
      return fs.listFileSync(dir);
    } catch (err) {
      return [];
    }
  }

  private static isDir(path: string): boolean {
    try {
      return fs.statSync(path).isDirectory();
    } catch (err) {
      return false;
    }
  }

  private static exists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (err) {
      return false;
    }
  }

  /** 删掉一个路径（目录连内容一起删，文件直接删）；不存在就算了 */
  private static clean(path: string): void {
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      if (fs.statSync(path).isDirectory()) {
        fs.rmdirSync(path);
      } else {
        fs.unlinkSync(path);
      }
    } catch (err) {
      // 删不掉只是占缓存
    }
  }

  /** 文件名匹配：pattern 里最多一个 `*`（如 `wallpaper_*.img`）；没有 `*` 就是全等 */
  private static matchPattern(name: string, pattern: string): boolean {
    const star: number = pattern.indexOf('*');
    if (star < 0) {
      return name === pattern;
    }
    const head: string = pattern.substring(0, star);
    const tail: string = pattern.substring(star + 1);
    if (name.length < head.length + tail.length) {
      return false;
    }
    return name.substring(0, head.length) === head
      && name.substring(name.length - tail.length) === tail;
  }

  /** 把一个来源模式展成实际存在的**相对路径**列表（通配只在落点根的顶层展开） */
  private static resolveSource(rootDir: string, pattern: string): string[] {
    const out: string[] = [];
    if (pattern.indexOf('*') < 0) {
      if (BackupStore.exists(rootDir + '/' + pattern)) {
        out.push(pattern);
      }
      return out;
    }
    const names: string[] = BackupStore.listNames(rootDir);
    for (let k = 0; k < names.length; k++) {
      if (BackupStore.matchPattern(names[k], pattern)) {
        out.push(names[k]);
      }
    }
    return out;
  }

  /** filesDir 顶层里已被各类别认领的名字（算 extra 兜底类要用） */
  private static claimedNames(list: BackupCategory[], filesDir: string): string[] {
    const claimed: string[] = [];
    for (let k = 0; k < list.length; k++) {
      const cat: BackupCategory = list[k];
      if (cat.root !== BackupStore.ROOT_FILES || cat.id === 'extra') {
        continue;
      }
      for (let s = 0; s < cat.sources.length; s++) {
        const hit: string[] = BackupStore.resolveSource(filesDir, cat.sources[s]);
        for (let h = 0; h < hit.length; h++) {
          if (claimed.indexOf(hit[h]) < 0) {
            claimed.push(hit[h]);
          }
        }
      }
    }
    return claimed;
  }

  /** filesDir 顶层里没人认领、也不在跳过名单里的条目 → 归 extra 类 */
  private static leftoverNames(list: BackupCategory[], filesDir: string): string[] {
    const claimed: string[] = BackupStore.claimedNames(list, filesDir);
    const names: string[] = BackupStore.listNames(filesDir);
    const out: string[] = [];
    for (let k = 0; k < names.length; k++) {
      if (claimed.indexOf(names[k]) >= 0 || BackupStore.SKIP.indexOf(names[k]) >= 0) {
        continue;
      }
      out.push(names[k]);
    }
    return out;
  }

  /**
   * 递归覆盖拷贝：src（文件或目录）→ dst。
   * **文件同名先删再拷**（行为确定，不依赖 copyFileSync 的覆盖语义）；
   * **目录只合并、不整目录删**（见文件头要点 3）。
   * ⚠️ 逐条目容错：单个文件被框架占用（preferences 的持久层之类）或权限异常时
   *    记一笔 failed 继续，绝不让一个文件中断整包（用户实测过"收集数据失败"）。
   *
   * 两条容易踩死整包的细节（都实测踩过）：
   *  · **拷文件前必须先把 dst 的父目录建出来**。zip 里每个文件都躺在 `<类别>/` 下，
   *    而类别文件夹此前没人创建 → 单文件类别（shelf.json / settings.json / 两份日志 /
   *    tabs.json / review*.json / 壁纸 / 手写 / 字体索引 / 卡片快照）拷贝**全部失败**，
   *    导入后文档正文虽在、书架索引却没了，看上去就是"什么都没有"。
   *  · **空目录绝不进包**。SDK 对 compressFiles 的原文警告：待压缩的文件夹不能为空，
   *    否则 decompressFile 解这个包时会报错——一个空的 drafts/ 就能让整个备份解不开。
   */
  private static copyTree(src: string, dst: string, stat: CopyStat): void {
    // 用两个原始类型把 statSync 的结果带出 try（不在 try 外用可空对象，避免严格空检查歧义）
    let isFolder: boolean = false;
    let size: number = 0;
    try {
      const st: fs.Stat = fs.statSync(src);
      isFolder = st.isDirectory();
      size = st.size;
    } catch (err) {
      stat.failed++;
      return;
    }
    if (isFolder) {
      const names: string[] = BackupStore.listNames(src);
      if (names.length === 0) {
        return;                      // 空目录：连建都不建（见上面的第二条）
      }
      BackupStore.ensureDir(dst);
      for (let k = 0; k < names.length; k++) {
        BackupStore.copyTree(src + '/' + names[k], dst + '/' + names[k], stat);
      }
      return;
    }
    BackupStore.ensureDir(BackupStore.parentOf(dst));
    try {
      if (fs.accessSync(dst)) {
        fs.unlinkSync(dst);
      }
    } catch (err) {
      // 目标本来不存在
    }
    try {
      fs.copyFileSync(src, dst);
      stat.files++;
      stat.bytes += size;
    } catch (err) {
      stat.failed++;
    }
  }

  /** 建目录（连父级一起建）；已存在或建不出来都不抛 */
  private static ensureDir(dir: string): void {
    try {
      fs.mkdirSync(dir, true);
    } catch (err) {
      // 已存在
    }
  }

  /** 取父目录（沙箱路径统一正斜杠，不引 path 模块） */
  private static parentOf(p: string): string {
    const at: number = p.lastIndexOf('/');
    return at > 0 ? p.substring(0, at) : p;
  }

  /** 把一个类别文件夹里的内容按相对路径写回落点根（zip 路径去掉类别名就是沙箱路径） */
  private static copyCategoryInto(srcDir: string, dstRoot: string, stat: CopyStat): void {
    const names: string[] = BackupStore.listNames(srcDir);
    for (let k = 0; k < names.length; k++) {
      BackupStore.copyTree(srcDir + '/' + names[k], dstRoot + '/' + names[k], stat);
    }
  }

  /**
   * 导出：按类别表把**全部用户数据**收集进 `<stage>/backup/`，写 manifest，压成一个 zip。
   * 覆盖 filesDir + cacheDir + 应用级 filesDir + preferences 四个落点。
   * 返回错误文案；空串 = 打包成功。本地导出与 WebDAV 完整备份共用。
   */
  static async packToZip(ctx: common.UIAbilityContext, outPath: string): Promise<string> {
    // 设置镜像先落地：PersistentStorage 的键只有写成 settings.json 才进得了包
    SettingsMirror.save(ctx);

    const stage: string = ctx.cacheDir + '/' + BackupStore.PACK_STAGE;
    BackupStore.clean(stage);
    const top: string = stage + '/' + BackupStore.TOP;
    try {
      fs.mkdirSync(top, true);
    } catch (err) {
      return '创建暂存目录出错';
    }

    const cats: BackupCategory[] = BackupStore.categories();
    const leftover: string[] = BackupStore.leftoverNames(cats, ctx.filesDir);
    const stat: CopyStat = { files: 0, bytes: 0, failed: 0 } as CopyStat;
    const used: BackupCategory[] = [];

    for (let k = 0; k < cats.length; k++) {
      const cat: BackupCategory = cats[k];
      const beforeFiles: number = stat.files;
      const beforeBytes: number = stat.bytes;
      if (cat.root === BackupStore.ROOT_PREF) {
        // 网盘凭据：从 preferences 直接写进包，不在 filesDir 里留中转副本
        const bytes: number = BackupStore.dumpWebDavSnapshot(ctx, top + '/' + cat.id);
        if (bytes > 0) {
          stat.files++;
          stat.bytes += bytes;
        }
      } else {
        const srcRoot: string = BackupStore.rootDir(cat.root, ctx);
        const names: string[] = cat.id === 'extra'
          ? leftover : BackupStore.expandSources(srcRoot, cat.sources);
        for (let n = 0; n < names.length; n++) {
          BackupStore.copyTree(srcRoot + '/' + names[n], top + '/' + cat.id + '/' + names[n], stat);
        }
      }
      cat.files = stat.files - beforeFiles;
      cat.bytes = stat.bytes - beforeBytes;
      if (cat.files > 0) {
        used.push(cat);
      }
    }

    if (stat.files === 0) {
      BackupStore.clean(stage);
      return '还没有可备份的数据';
    }

    BackupStore.writeManifest(top, used, stat);
    try {
      BackupStore.clean(outPath);
      const zipOptions: zlib.Options = {};
      await zlib.compressFiles([top], outPath, zipOptions);
    } catch (err) {
      BackupStore.clean(stage);
      return '打包失败：' + (err as Error).message;
    }
    BackupStore.clean(stage);
    BackupStore.lastPackText = BackupStore.packSummary(stat, used);
    return '';
  }

  /** 把一个类别的全部来源模式展成实际存在的相对路径列表 */
  private static expandSources(srcRoot: string, sources: string[]): string[] {
    const names: string[] = [];
    for (let s = 0; s < sources.length; s++) {
      const hit: string[] = BackupStore.resolveSource(srcRoot, sources[s]);
      for (let h = 0; h < hit.length; h++) {
        names.push(hit[h]);
      }
    }
    return names;
  }

  /** 导出结果的一句话摘要（「42 个文件 · 1.30 MB · 16 类数据」） */
  private static packSummary(stat: CopyStat, used: BackupCategory[]): string {
    const kb: number = stat.bytes / 1024;
    const size: string = kb < 1024 ? Math.max(1, Math.round(kb)) + ' KB'
      : (kb / 1024).toFixed(2) + ' MB';
    let text: string = stat.files + ' 个文件 · ' + size + ' · ' + used.length + ' 类数据';
    if (stat.failed > 0) {
      // 说清是"没拷进包"而不是"读不出来"（多半是写目标失败），并且明确备份不完整
      text += '（注意：有 ' + stat.failed + ' 项没能拷进包里，这份备份不完整）';
    }
    return text;
  }

  /** 写出 manifest.json（清单：格式版本、导出时间、应用版本、每类落点与规模） */
  private static writeManifest(top: string, used: BackupCategory[], stat: CopyStat): void {
    const cats: ManifestCategory[] = [];
    for (let k = 0; k < used.length; k++) {
      cats.push({
        id: used[k].id,
        label: used[k].label,
        target: BackupStore.targetOf(used[k]),
        files: used[k].files,
        bytes: used[k].bytes
      } as ManifestCategory);
    }
    const now: Date = new Date();
    const manifest: BackupManifest = {
      app: '澄笺',
      format: BackupStore.FORMAT,
      exportedAt: now.getTime(),
      exportedText: BackupStore.stampText(now),
      versionName: BackupStore.versionName(),
      totalFiles: stat.files,
      totalBytes: stat.bytes,
      categories: cats
    } as BackupManifest;
    try {
      const file: fs.File = fs.openSync(top + '/' + BackupStore.MANIFEST,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(manifest, null, 2));
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      // 清单写不进去也照样能恢复（导入还认类别文件夹名），只是少了规模信息
    }
  }

  /** `2026-10-12 19:30:45` */
  private static stampText(d: Date): string {
    return BackupStore.datePart(d) + ' ' + BackupStore.timePart(d);
  }

  private static datePart(d: Date): string {
    const pad = (v: number): string => {
      return v < 10 ? '0' + v : '' + v;
    };
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
  }

  private static timePart(d: Date): string {
    const pad = (v: number): string => {
      return v < 10 ? '0' + v : '' + v;
    };
    return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
  }

  /** 备份文件名用的时间戳：`20261012_193045`（秒级，多次备份不重名） */
  private static fileNameStamp(d: Date): string {
    return BackupStore.datePart(d).split('-').join('') + '_'
      + BackupStore.timePart(d).split(':').join('');
  }

  private static versionName(): string {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName !== undefined && info.versionName !== null ? info.versionName : '';
    } catch (err) {
      return '';
    }
  }

  /**
   * 把 WebDAV 配置（preferences 里的一段 JSON）写进包内的 `webdav/` 文件夹。
   * 没配置过就什么都不写——包里没这个文件，恢复时就不会动本机的网盘配置。
   * 返回写入的字节数，0 = 没写。
   */
  private static dumpWebDavSnapshot(ctx: common.UIAbilityContext, dir: string): number {
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(ctx, { name: BackupStore.WEBDAV_PREF_NAME });
      const raw: string = store.getSync(BackupStore.WEBDAV_PREF_KEY, '') as string;
      if (raw.length === 0) {
        return 0;
      }
      try {
        fs.mkdirSync(dir, true);
      } catch (err) {
        // 已存在
      }
      const file: fs.File = fs.openSync(dir + '/' + BackupStore.WEBDAV_SNAPSHOT,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, raw);
      } finally {
        fs.closeSync(file);
      }
      return raw.length;
    } catch (err) {
      // 配置快照失败不影响数据本体备份
      return 0;
    }
  }

  /**
   * 把包里的 `webdav_config.json` 写回 preferences（走 API，运行中的实例不会把它冲掉）。
   * 返回是否真的写了配置。
   */
  private static applyWebDavSnapshot(ctx: common.UIAbilityContext, path: string): boolean {
    try {
      if (!BackupStore.exists(path)) {
        return false;
      }
      const raw: string = fs.readTextSync(path, { encoding: 'utf-8' });
      if (raw.length === 0) {
        return false;
      }
      const store: preferences.Preferences =
        preferences.getPreferencesSync(ctx, { name: BackupStore.WEBDAV_PREF_NAME });
      store.putSync(BackupStore.WEBDAV_PREF_KEY, raw);
      store.flush();
      return true;
    } catch (err) {
      // 配置恢复失败不影响数据本体
      return false;
    }
  }

  /**
   * 从本地 zip 路径恢复。**六步**（少任何一步都会出现"导入成功但数据没进来"）：
   *   ① 解压到 cacheDir 暂存目录（不直接解压进沙箱：decompressFile 对已存在文件
   *      没有覆盖承诺，本机有数据时可能整批跳过）；
   *   ② 找到包根、**校验像不像澄笺的备份**（认 manifest.json / 认类别文件夹 /
   *      认老包的 shelf.json），不像就直接报错，别把用户的数据目录搞坏；
   *      同时判定包是**分类布局**（新版）还是**平铺布局**（1.1.x），见 isCategorized；
   *   ③ 按类别把每个文件夹写回它**本来的落点**（filesDir / cacheDir / 应用级
   *      filesDir / preferences），同名先删再拷；
   *   ④ 回填运行中的进程：settings.json → AppStorage（持久化键会写穿 preferences）、
   *      WebDAV 配置 → preferences API、语言 → 刷新计数、字体 → registerFont、
   *      壁纸路径 → 按恢复进来的文件重指、深浅色 → applyAppColorMode，
   *      这些就是原来"必须重启应用"的那批（见 reapplyLive）；
   *   ⑤ 重载各内存缓存（书架 / 阅读日志 / 写作日志 / 标签页 / 图表缓存）——
   *      不重载的话下一次 persist 会把恢复前的内存状态写回刚导入的文件；
   *   ⑥ 清掉暂存目录与老包残留。
   * 返回给用户看的结果文案。「文件备份导入」与「WebDAV 恢复」共用。
   */
  static async restoreFromPath(ctx: common.UIAbilityContext, zipPath: string): Promise<string> {
    const stage: string = ctx.cacheDir + '/' + BackupStore.STAGE;
    BackupStore.clean(stage);
    try {
      fs.mkdirSync(stage, true);
    } catch (err) {
      return '恢复失败：创建临时目录出错';
    }
    // 解压报错也**可能已经解出来一部分**：老包里夹了空文件夹时 zlib 会整体报错
    // （见 copyTree 的第二条），这时暂存目录里往往已经有能用的数据——接着恢复，
    // 别把能救的东西一起丢掉。
    let unzipErr: string = '';
    try {
      await zlib.decompressFile(zipPath, stage);
    } catch (err) {
      unzipErr = (err as Error).message;
    }

    const cats: BackupCategory[] = BackupStore.categories();
    const root: string = BackupStore.findPackageRoot(stage, cats);
    const names: string[] = BackupStore.listNames(root);
    if (names.length === 0) {
      BackupStore.clean(stage);
      return unzipErr.length > 0
        ? '恢复失败：备份包读不出来（' + unzipErr + '）' : '恢复失败：备份包是空的';
    }
    if (!BackupStore.looksLikeOurs(root, names, cats)) {
      BackupStore.clean(stage);
      return '恢复失败：这不是澄笺的备份包（没找到清单，也没有任何已知数据类别）';
    }

    const stat: CopyStat = { files: 0, bytes: 0, failed: 0 } as CopyStat;
    const done: string[] = [];
    let webdavDone: boolean = false;
    // 先判定包的布局：**分类布局**（新版）才按类别文件夹写回，**平铺布局**（1.1.x）
    // 直接按 filesDir 顶层写回。判错了后果很实在——老包里的 `docs/` 会被当成新版的
    // `docs` 类别夹，里面的文档被倒进 filesDir 根，而真正的文档目录一个也没恢复。
    const categorized: boolean = BackupStore.isCategorized(root, names, cats);

    for (let k = 0; k < names.length; k++) {
      const entry: string = names[k];
      const src: string = root + '/' + entry;
      if (entry === BackupStore.MANIFEST) {
        continue;
      }
      const cat: BackupCategory | null = categorized ? BackupStore.categoryById(cats, entry) : null;
      if (cat !== null && BackupStore.isDir(src)) {
        const before: number = stat.files;
        if (cat.root === BackupStore.ROOT_PREF) {
          if (BackupStore.applyWebDavSnapshot(ctx, src + '/' + BackupStore.WEBDAV_SNAPSHOT)) {
            stat.files++;
            webdavDone = true;
            done.push(cat.label);
          }
          continue;
        }
        BackupStore.copyCategoryInto(src, BackupStore.rootDir(cat.root, ctx), stat);
        if (stat.files > before) {
          done.push(cat.label);
        }
        continue;
      }
      // 平铺布局（或分类布局里出现的未知条目）：老版包的 shelf.json / settings.json /
      // docs 直接躺在根，一律按 filesDir 顶层处理
      if (BackupStore.SKIP.indexOf(entry) >= 0) {
        continue;
      }
      if (!webdavDone && entry === BackupStore.WEBDAV_SNAPSHOT) {
        if (BackupStore.applyWebDavSnapshot(ctx, src)) {
          stat.files++;
          webdavDone = true;
          done.push('网盘账号配置');
        }
        continue;
      }
      const before: number = stat.files;
      BackupStore.copyTree(src, ctx.filesDir + '/' + entry, stat);
      if (stat.files > before && done.indexOf(entry) < 0) {
        done.push(entry);
      }
    }

    BackupStore.clean(stage);
    // 老包残留：① 1.1.x 塞进来的 preferences 原始 XML 目录（那种恢复方式不可靠，
    // 现在走 settings.json + preferences API）；② 老版把网盘凭据中转在 filesDir 里。
    // 都清掉，免得留在数据目录里被下一次备份反复打包（占空间 + 凭据多复制一份）。
    BackupStore.clean(ctx.filesDir + '/pref_snapshot');
    BackupStore.clean(ctx.filesDir + '/' + BackupStore.WEBDAV_SNAPSHOT);

    BackupStore.reapplyLive(ctx);

    if (stat.files === 0) {
      return '恢复完成，但包里没有可用数据';
    }
    let text: string = '已导入 ' + stat.files + ' 个文件（' + BackupStore.briefLabels(done) + '），'
      + '书架、设置与语言立即生效';
    if (stat.failed > 0) {
      text += '；' + stat.failed + ' 项写入失败';
    }
    if (unzipErr.length > 0) {
      text += '；压缩包解压时报错（' + unzipErr + '），已按解出来的部分恢复';
    }
    return text;
  }

  /**
   * 找包根：新版包外面套一层 `backup/`，老版可能套 `data/`，别的工具打的包也可能套
   * 一层自己的目录名。规则：**没有 manifest.json、顶层只有一个目录、且那目录不是
   * 已知类别名**，就往下钻一层（最多 4 层，防死循环）。
   */
  private static findPackageRoot(stage: string, cats: BackupCategory[]): string {
    let root: string = stage;
    for (let depth = 0; depth < 4; depth++) {
      if (BackupStore.exists(root + '/' + BackupStore.MANIFEST)) {
        return root;
      }
      const names: string[] = BackupStore.listNames(root);
      if (names.length !== 1) {
        return root;
      }
      const only: string = root + '/' + names[0];
      if (!BackupStore.isDir(only) || BackupStore.categoryById(cats, names[0]) !== null) {
        return root;
      }
      root = only;
    }
    return root;
  }

  /**
   * 像不像澄笺的备份包：有清单、或有任一已知类别文件夹、或有老包那几个标志性文件。
   * 都不满足就拒绝导入——否则用户选错一个 zip，里面的东西会被一股脑倒进数据目录。
   */
  private static looksLikeOurs(root: string, names: string[], cats: BackupCategory[]): boolean {
    if (BackupStore.exists(root + '/' + BackupStore.MANIFEST)) {
      return true;
    }
    for (let k = 0; k < names.length; k++) {
      if (BackupStore.categoryById(cats, names[k]) !== null) {
        return true;
      }
      if (names[k] === 'shelf.json' || names[k] === 'settings.json' || names[k] === 'tabs.json') {
        return true;
      }
    }
    return false;
  }

  /**
   * 这个包是不是**分类布局**（新版）。两条判据，任一成立即算：
   *   ① 根上有 manifest.json（正常导出的包一定有）；
   *   ② 根上有一个「只可能属于分类布局」的类别文件夹。
   *
   * 为什么不能只看"文件夹名是不是类别 id"：`docs`、`annotations`、`ai`、`drafts`、
   * `versions`、`fonts` 这六类的 id 与它们在 filesDir 下的真实目录**同名**，老版平铺包
   * 里也有这些目录，光看名字分不清是"类别夹"还是"真实数据目录"。所以：
   *   · 不撞名的类别（shelf / settings / logs / tabs / review / wallpaper / handwrite /
   *     form / cache / webdav / extra）出现即为分类布局；
   *   · 撞名的类别要看**双层路径**——新版包里是 `docs/docs/…`（类别夹 + 沙箱相对路径），
   *     老版包里 `docs/` 下面直接就是文档，不会有第二层 `docs/`。
   */
  private static isCategorized(root: string, names: string[], cats: BackupCategory[]): boolean {
    if (BackupStore.exists(root + '/' + BackupStore.MANIFEST)) {
      return true;
    }
    for (let k = 0; k < names.length; k++) {
      const cat: BackupCategory | null = BackupStore.categoryById(cats, names[k]);
      if (cat === null || !BackupStore.isDir(root + '/' + names[k])) {
        continue;
      }
      if (!BackupStore.idCollides(cat)) {
        return true;
      }
      for (let s = 0; s < cat.sources.length; s++) {
        const at: number = cat.sources[s].indexOf('/');
        const first: string = at < 0 ? cat.sources[s] : cat.sources[s].substring(0, at);
        if (first.length > 0 && first.indexOf('*') < 0
          && BackupStore.exists(root + '/' + names[k] + '/' + first)) {
          return true;
        }
      }
    }
    return false;
  }

  /** 类别 id 是否与它在落点根下的真实路径同名（同名就会与老版平铺包撞车） */
  private static idCollides(cat: BackupCategory): boolean {
    for (let s = 0; s < cat.sources.length; s++) {
      if (cat.sources[s] === cat.id || cat.sources[s].indexOf(cat.id + '/') === 0) {
        return true;
      }
    }
    return false;
  }

  /** 导入结果里的类别摘要：最多列 6 类，多的用「等 N 类」收尾 */
  private static briefLabels(done: string[]): string {
    if (done.length === 0) {
      return '0 类';
    }
    const shown: string[] = [];
    for (let k = 0; k < done.length && k < 6; k++) {
      shown.push(done[k]);
    }
    const text: string = shown.join('、');
    return done.length > 6 ? text + ' 等 ' + done.length + ' 类' : text;
  }

  /**
   * 把恢复进来的状态**当场**回填到运行中的进程（这就是原来"必须重启应用"的那批）。
   * 顺序有讲究：设置先回填 AppStorage，后面几项才能按恢复后的设置生效。
   */
  private static reapplyLive(ctx: common.UIAbilityContext): void {
    SettingsMirror.forceRestore(ctx);
    L10n.reapply();
    DocStore.reload(ctx);
    ReadingLog.reload(ctx);
    WritingLog.reload(ctx);
    TabStore.reload(ctx);
    // 用户字体：恢复进来的字体文件还没注册到字体模块，注册一次（否则正文按回退字体显示）
    FontStore.invalidateCache();
    FontStore.registerAll(ctx);
    // 图表缓存：内存 memo 里记的是恢复前的路径与尺寸，清掉让它按磁盘重建
    ChartCache.invalidate();
    // 壁纸与阅读背景：设置里存的是**绝对路径**，换机恢复后文件路径变了要重指一次
    WallpaperStore.relink(ctx);
    WallpaperStore.validate(ctx);
    WallpaperStore.validateReaderBg(ctx);
    // 深浅色模式是 ability 级设置，恢复后要立刻重设（不然恢复了深色主题仍是浅色界面）
    const mode: number | undefined = AppStorage.get<number>('readerThemeMode');
    const themeMode: number = mode === undefined || mode === null ? ReaderThemeMode.System : mode;
    applyAppColorMode(themeMode);
    const sysDark: boolean | undefined = AppStorage.get<boolean>('systemDark');
    applySystemBarTheme(themeMode === ReaderThemeMode.Dark
      || (themeMode === ReaderThemeMode.System && sysDark === true));
    SettingsMirror.bumpTick();
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
      options.newFileNames = ['澄笺_' + BackupStore.fileNameStamp(new Date()) + '.zip'];
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
      const summary: string = BackupStore.lastPackText;
      return summary.length > 0 ? '备份已导出：' + summary : '备份已导出（zip）';
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
   * 图表缓存与导出中转都在这里，清完下次渲染自动重建。
   */
  static async clearCache(ctx: common.UIAbilityContext): Promise<string> {
    const names: string[] = BackupStore.listNames(ctx.cacheDir);
    if (names.length === 0) {
      return L10n.t('缓存已经是最干净的状态');
    }
    let freed: number = 0;
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
    ChartCache.invalidate();
    const kb: number = Math.round(freed / 1024);
    return kb > 0 ? L10n.t('已清除缓存 ') + kb + ' KB' : L10n.t('缓存已经是最干净的状态');
  }

  /**
   * **应用初始化**（用户要求：点击后清空应用全部数据，效果等同卸载重装）。
   *
   * 清空范围：
   *   ① filesDir 下全部内容（文档 / 批注 / AI 配置与会话 / 草稿 / 版本 / 设置镜像 / 壁纸 …）；
   *   ② cacheDir 下全部内容（缓存与临时包）；
   *   ③ 应用级 filesDir 里的桌面卡片数据（form_ids / form_snapshot）；
   *   ④ 各类 Preferences（WebDAV 配置等；设置类键由调用方用 PersistentStorage.deleteProp 清）；
   *   ⑤ 持久化键（由调用方清，见 SettingsData.wipeAllData）。
   * 调用方最后 `terminateSelf()` 让应用退出——下次启动即全新安装的初始状态。
   */
  static async wipeAll(ctx: common.UIAbilityContext): Promise<string> {
    let failed: number = 0;
    // ① + ② 两个目录下逐个删（目录递归删；文件 unlink）
    const dirs: string[] = [ctx.filesDir, ctx.cacheDir];
    for (let d = 0; d < dirs.length; d++) {
      const names: string[] = BackupStore.listNames(dirs[d]);
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
    // ③ 桌面卡片数据（只删这两个文件：应用级目录不归我们独占，不整目录清）
    const appDir: string = BackupStore.rootDir(BackupStore.ROOT_APP, ctx);
    const formFiles: string[] = ['form_ids.json', 'form_snapshot.json'];
    for (let k = 0; k < formFiles.length; k++) {
      BackupStore.clean(appDir + '/' + formFiles[k]);
    }
    // ④ Preferences（WebDAV 连接配置等）
    try {
      await preferences.deletePreferences(ctx, { name: 'webdav' });
    } catch (err) {
      // 删不到就不管（下次启动仍是默认空配置）
    }
    ChartCache.invalidate();
    return failed === 0 ? L10n.t('已清空应用数据') : L10n.t('已清空（') + failed + ' 项未能删除）';
  }
}
