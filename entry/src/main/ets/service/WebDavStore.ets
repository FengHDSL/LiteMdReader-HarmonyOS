/**
 * LiteMdReader · WebDAV 备份
 * ==========================
 *
 * 通过 WebDAV 把**全部文档 + 书架索引 + 阅读设置 + 完整备份包（zip）**备份到
 * 用户自己的网盘（坚果云、群晖、InfiniCloud 等任何支持 WebDAV 的服务）。
 *
 * 上传内容（两阶段）：
 *   ① 逐文件：docs/*.md + shelf.json + config.json —— 网盘端可直接翻看；
 *   ② **完整备份包** litemdreader_full.zip —— BackupStore.packToZip 打的全量包
 *     （含 AI 对话记录、批注、手写、壁纸、偏好设置等 filesDir 全部数据），
 *     恢复时整包下载解压，一个不漏。
 *
 * 三个设计决策：
 *
 * 1. **只用标准 HTTP 方法**（PUT / GET），不依赖任何私有 API——WebDAV 就是 HTTP，
 *   `@kit.NetworkKit` 的 http 模块足够。鉴权用 Basic（base64 of user:password）。
 *   http 枚举没有 MKCOL/PROPFIND，所以**不列目录、建目录交给服务端/用户**；
 *   完整包用**固定文件名**（每次覆盖），恢复时不需要 PROPFIND 也能定位。
 *
 * 2. **先逐文件后整包**。多数 WebDAV 服务对「上传到不存在的目录」返回 409，
 *   逐文件阶段就能把目录问题暴露给用户，不浪费整包的大流量。
 *
 * 3. **密码落盘在本地偏好里**。明文存储确实不理想，但 WebDAV 客户端普遍这么做
 *   （数据在应用沙箱内，其他应用读不到）；牺牲一点安全性换取「配置一次、一键备份」的体验。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import preferences from '@ohos.data.preferences';
import { DocMeta, DocStore } from './DocStore';
import { BackupStore } from './BackupStore';

/** 完整备份包在 WebDAV 上的文件名（固定名覆盖写，恢复时按名下载） */
const FULL_ZIP_NAME: string = 'litemdreader_full.zip';

/** 二进制下载结果（code = HTTP 状态码，-1 = 网络异常） */
export interface WebDavDownload {
  code: number;
  data: ArrayBuffer;
}

/** WebDAV 连接配置 */
export interface WebDavConfig {
  /** 服务器地址，如 https://dav.jianguoyun.com/dav/ */
  server: string;
  /** 账号 */
  user: string;
  /** 密码 / 应用密码 */
  password: string;
  /** 备份目录名（相对服务器路径），默认 litemdreader */
  dir: string;
  /** **自动备份间隔（天）**：0 = 关闭；1 / 3 / 7 = 每 N 天自动上传一次 */
  autoDays: number;
  /** 上次成功备份的时间戳（手动或自动，0 = 从未） */
  lastAutoAt: number;
}

/** 单次备份的结果 */
export interface WebDavResult {
  /** 空串 = 成功；否则为可读的错误说明 */
  error: string;
  /** 成功上传的文件数 */
  uploaded: number;
  /** 计划上传的文件总数 */
  total: number;
}

export class WebDavStore {
  private static readonly PREF_NAME: string = 'webdav';
  private static readonly KEY_CONFIG: string = 'config';

  /** 读取配置。没配置过返回全空的配置。 */
  static loadConfig(ctx: common.UIAbilityContext): WebDavConfig {
    const empty: WebDavConfig = {
      server: '', user: '', password: '', dir: 'litemdreader', autoDays: 0, lastAutoAt: 0
    };
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(ctx, { name: WebDavStore.PREF_NAME });
      const raw: string = store.getSync(WebDavStore.KEY_CONFIG, '') as string;
      if (raw.length === 0) {
        return empty;
      }
      const parsed: WebDavConfig = JSON.parse(raw) as WebDavConfig;
      // 老配置没有 autoDays / lastAutoAt 字段 → 兜底补 0（0 = 关闭 / 从未备份）
      if (parsed.autoDays === undefined || parsed.autoDays < 0) {
        parsed.autoDays = 0;
      }
      if (parsed.lastAutoAt === undefined || parsed.lastAutoAt < 0) {
        parsed.lastAutoAt = 0;
      }
      if (parsed.dir === undefined || parsed.dir.length === 0) {
        parsed.dir = 'litemdreader';
      }
      return parsed;
    } catch (err) {
      return empty;
    }
  }

  /** 设定自动备份间隔（天，0 = 关闭）并落盘。 */
  static setAutoDays(ctx: common.UIAbilityContext, days: number): void {
    const cfg: WebDavConfig = WebDavStore.loadConfig(ctx);
    cfg.autoDays = days < 0 ? 0 : days;
    WebDavStore.saveConfig(ctx, cfg);
  }

  /** 记一次「备份成功」的时间（手动 / 自动都调），用于下一次到期判定。 */
  static markBackedUp(ctx: common.UIAbilityContext): void {
    const cfg: WebDavConfig = WebDavStore.loadConfig(ctx);
    cfg.lastAutoAt = Date.now();
    WebDavStore.saveConfig(ctx, cfg);
  }

  /** 距离下一次自动备份还有多久（毫秒；未开启返回 -1，已到期返回 0）。 */
  static msToNextAuto(ctx: common.UIAbilityContext): number {
    const cfg: WebDavConfig = WebDavStore.loadConfig(ctx);
    if (cfg.autoDays <= 0) {
      return -1;
    }
    const base: number = cfg.lastAutoAt > 0 ? cfg.lastAutoAt : Date.now();
    const due: number = base + cfg.autoDays * 86400000;
    const left: number = due - Date.now();
    return left > 0 ? left : 0;
  }

  /**
   * **到点就自动备份一次**（应用启动后调用，用户要求：支持设定多久上传一次）。
   * 只在「已配置 + 开启了间隔 + 已到期」时执行；结果写 AppStorage 供设置页展示。
   * 全程不抛异常（失败只记状态）。
   */
  static maybeAutoBackup(ctx: common.UIAbilityContext): void {
    const cfg: WebDavConfig = WebDavStore.loadConfig(ctx);
    if (!WebDavStore.isConfigured(cfg) || cfg.autoDays <= 0) {
      return;
    }
    const base: number = cfg.lastAutoAt > 0 ? cfg.lastAutoAt : 0;
    // 从未备份过 → 立即做一次；有记录 → 到期才做
    if (base > 0 && Date.now() - base < cfg.autoDays * 86400000) {
      return;
    }
    WebDavStore.backupAll(ctx, cfg, (_done: number, _total: number, _label: string) => {
      // 自动备份进度不打扰用户
    }).then((r: WebDavResult) => {
      if (r.error.length === 0) {
        WebDavStore.markBackedUp(ctx);
        AppStorage.setOrCreate('webdavAutoStatus', '自动备份完成 · ' + WebDavStore.stamp());
      } else {
        AppStorage.setOrCreate('webdavAutoStatus', '自动备份失败：' + r.error);
      }
    }).catch((err: BusinessError) => {
      const msg: string = err.message !== undefined ? err.message : '';
      AppStorage.setOrCreate('webdavAutoStatus', '自动备份失败：' + msg);
    });
  }

  /** 当前时间 → 'MM-DD HH:mm'（状态文案用）。 */
  private static stamp(): string {
    const d: Date = new Date();
    const pad = (v: number): string => {
      return v < 10 ? '0' + v : '' + v;
    };
    return pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  static saveConfig(ctx: common.UIAbilityContext, cfg: WebDavConfig): void {
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(ctx, { name: WebDavStore.PREF_NAME });
      store.putSync(WebDavStore.KEY_CONFIG, JSON.stringify(cfg));
      store.flush();
    } catch (err) {
      // 配置写失败只影响下次启动时的回填，不阻断当前操作
    }
  }

  /** 配置是否齐备（服务器与账号至少要有）。 */
  static isConfigured(cfg: WebDavConfig): boolean {
    return cfg.server.trim().length > 0 && cfg.user.trim().length > 0;
  }

  /** Basic 鉴权头。 */
  private static authHeader(cfg: WebDavConfig): string {
    const encoder = new util.TextEncoder();
    const bytes: Uint8Array = encoder.encodeInto(cfg.user.trim() + ':' + cfg.password);
    return 'Basic ' + new util.Base64Helper().encodeToStringSync(bytes);
  }

  /** 拼文件在 WebDAV 上的完整地址。 */
  private static urlOf(cfg: WebDavConfig, fileName: string): string {
    let base: string = cfg.server.trim();
    while (base.length > 0 && base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    let dir: string = cfg.dir.trim();
    while (dir.length > 0 && dir.startsWith('/')) {
      dir = dir.substring(1);
    }
    while (dir.length > 0 && dir.endsWith('/')) {
      dir = dir.substring(0, dir.length - 1);
    }
    if (dir.length === 0) {
      return base + '/' + fileName;
    }
    return base + '/' + dir + '/' + fileName;
  }

  /** 发一个 WebDAV 请求，返回状态码；网络异常返回 -1。 */
  private static request(url: string, method: http.RequestMethod, cfg: WebDavConfig,
                         body: string): Promise<number> {
    return new Promise<number>((resolve: (v: number) => void, reject: (e: string) => void) => {
      const req: http.HttpRequest = http.createHttp();
      const options: http.HttpRequestOptions = {
        method: method,
        header: {
          'Authorization': WebDavStore.authHeader(cfg),
          'Content-Type': 'application/octet-stream'
        },
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000
      };
      req.request(url, options).then((resp: http.HttpResponse) => {
        const code: number = resp.responseCode as number;
        req.destroy();
        resolve(code);
      }).catch((err: BusinessError) => {
        req.destroy();
        resolve(-1);
      });
    });
  }

  /** 一次性把沙箱文件读进内存（完整 zip 包用）。 */
  private static readFileBytes(path: string): ArrayBuffer {
    const size: number = fs.statSync(path).size;
    const buf: ArrayBuffer = new ArrayBuffer(size);
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const read: number = fs.readSync(file.fd, buf, { length: size });
      return read >= size ? buf : buf.slice(0, Math.max(read, 0));
    } finally {
      fs.closeSync(file);
    }
  }

  /** 一次性把内存数据写成沙箱文件（下载的恢复包落 cache 用）。 */
  private static writeFileBytes(path: string, data: ArrayBuffer): void {
    const file: fs.File = fs.openSync(path,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, data, { length: data.byteLength });
    } finally {
      fs.closeSync(file);
    }
  }

  /** PUT 二进制（完整 zip 包）。返回状态码；网络异常返回 -1。大包放宽读超时。 */
  private static uploadBinary(url: string, cfg: WebDavConfig, data: ArrayBuffer): Promise<number> {
    return new Promise<number>((resolve: (v: number) => void) => {
      const req: http.HttpRequest = http.createHttp();
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.PUT,
        header: {
          'Authorization': WebDavStore.authHeader(cfg),
          'Content-Type': 'application/octet-stream'
        },
        extraData: data,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 180000
      };
      req.request(url, options).then((resp: http.HttpResponse) => {
        const code: number = resp.responseCode as number;
        req.destroy();
        resolve(code);
      }).catch(() => {
        req.destroy();
        resolve(-1);
      });
    });
  }

  /** GET 二进制（下载完整 zip 包）。 */
  private static downloadBinary(url: string, cfg: WebDavConfig): Promise<WebDavDownload> {
    return new Promise<WebDavDownload>((resolve: (v: WebDavDownload) => void) => {
      const req: http.HttpRequest = http.createHttp();
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: {
          'Authorization': WebDavStore.authHeader(cfg)
        },
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 180000
      };
      req.request(url, options).then((resp: http.HttpResponse) => {
        const code: number = resp.responseCode as number;
        const data: ArrayBuffer = resp.result instanceof ArrayBuffer ? resp.result : new ArrayBuffer(0);
        req.destroy();
        resolve({ code: code, data: data });
      }).catch(() => {
        req.destroy();
        resolve({ code: -1, data: new ArrayBuffer(0) });
      });
    });
  }

  /**
   * 一键备份：全部文档 + 书架索引 + 阅读设置 + **完整备份包（zip）**。
   * onProgress 会按文件回调，用于设置页显示进度。
   */
  static async backupAll(ctx: common.UIAbilityContext, cfg: WebDavConfig,
                         onProgress: (done: number, total: number, label: string) => void)
    : Promise<WebDavResult> {
    const result: WebDavResult = { error: '', uploaded: 0, total: 0 };

    // ① 收集要上传的内容：文档 + 索引 + 设置快照
    const metas: DocMeta[] = DocStore.list(ctx);
    const items: string[] = [];
    const names: string[] = [];

    for (let k = 0; k < metas.length; k++) {
      const content: string = DocStore.readText(ctx, metas[k]);
      items.push(content);
      names.push('docs/' + DocStore.sanitizeName(metas[k].name) + '.md');
    }

    // 书架索引（文件夹归组就在这里面）
    try {
      const shelfPath: string = ctx.filesDir + '/shelf.json';
      if (fs.accessSync(shelfPath)) {
        items.push(fs.readTextSync(shelfPath, { encoding: 'utf-8' }));
        names.push('shelf.json');
      }
    } catch (err) {
      // 没有 shelf.json 就跳过
    }

    // 阅读设置快照：把会影响观感的键都收进来
    const configKeys: string[] = [
      'readerFontSize', 'readerLineHeight', 'readerMeasure', 'readerThemeMode',
      'immersiveLightEnabled', 'appearanceMaterialType', 'appearanceMaterialLevel',
      'glassStrength', 'cardFallback', 'themeColor', 'cardTint', 'pageBgTint',
      'wallpaperPath', 'wallpaperBlur', 'wallpaperScrim', 'readerShowMeta',
      'readerKeepScreenOn', 'readerCustomBgLight', 'readerCustomBgDark',
      // 引擎管理：被关闭的渲染引擎列表（随配置一起上云 / 恢复）
      'disabledEngines'
    ];
    const snapshot: Record<string, string | number | boolean> = {};
    for (let k = 0; k < configKeys.length; k++) {
      const key: string = configKeys[k];
      const v: string | undefined = AppStorage.get<string>(key);
      if (v !== undefined) {
        snapshot[key] = v;
        continue;
      }
      const n: number | undefined = AppStorage.get<number>(key);
      if (n !== undefined) {
        snapshot[key] = n;
        continue;
      }
      const b: boolean | undefined = AppStorage.get<boolean>(key);
      if (b !== undefined) {
        snapshot[key] = b;
      }
    }
    items.push(JSON.stringify(snapshot));
    names.push('config.json');

    result.total = items.length + 1;

    // ② 逐个上传（RequestMethod 枚举不含 MKCOL，建目录交给服务端/用户在网盘端完成）
    for (let k = 0; k < items.length; k++) {
      onProgress(k, result.total, names[k]);
      const status: number = await WebDavStore.request(
        WebDavStore.urlOf(cfg, names[k]), http.RequestMethod.PUT, cfg, items[k]);
      if (status >= 200 && status < 300) {
        result.uploaded++;
      } else if (status === 409) {
        result.error = '服务器上不存在目录「' + cfg.dir + '」，请先在网盘端创建后重试';
        onProgress(k + 1, result.total, result.error);
        return result;
      } else {
        result.error = names[k] + ' 上传失败（HTTP ' + status + '）';
        onProgress(k + 1, result.total, result.error);
        return result;
      }
    }

    // ③ **完整备份包**：全量 filesDir（含 AI 对话记录 / 批注 / 手写 / 壁纸 / 偏好设置）
    //    打成 zip 上传，恢复时整包下载解压，一个不漏。
    onProgress(items.length, result.total, '打包完整备份…');
    const zipPath: string = ctx.cacheDir + '/litemd_webdav_full.zip';
    const packErr: string = await BackupStore.packToZip(ctx, zipPath);
    if (packErr.length > 0) {
      result.error = packErr;
      onProgress(result.total, result.total, packErr);
      return result;
    }
    let bytes: ArrayBuffer = new ArrayBuffer(0);
    try {
      bytes = WebDavStore.readFileBytes(zipPath);
    } catch (err) {
      result.error = '读取备份包失败';
      onProgress(result.total, result.total, result.error);
      return result;
    }
    onProgress(items.length, result.total, FULL_ZIP_NAME);
    const up: number = await WebDavStore.uploadBinary(
      WebDavStore.urlOf(cfg, FULL_ZIP_NAME), cfg, bytes);
    if (up >= 200 && up < 300) {
      result.uploaded++;
    } else if (up === 409) {
      result.error = '服务器上不存在目录「' + cfg.dir + '」，请先在网盘端创建后重试';
      onProgress(result.total, result.total, result.error);
      return result;
    } else {
      result.error = FULL_ZIP_NAME + ' 上传失败（' + (up === -1 ? '网络异常' : 'HTTP ' + up) + '）';
      onProgress(result.total, result.total, result.error);
      return result;
    }

    onProgress(result.total, result.total, '备份完成');
    return result;
  }

  /**
   * 从 WebDAV 恢复：下载完整备份包并整包解压（**覆盖**本机同名数据）。
   * 返回给用户看的结果文案。
   */
  static async restoreFull(ctx: common.UIAbilityContext, cfg: WebDavConfig,
                           onProgress: (label: string) => void): Promise<string> {
    onProgress('正在下载完整备份包…');
    const dl: WebDavDownload = await WebDavStore.downloadBinary(
      WebDavStore.urlOf(cfg, FULL_ZIP_NAME), cfg);
    if (dl.code === 404) {
      return '服务器上还没有完整备份包，请先执行一次备份';
    }
    if (dl.code === -1) {
      return '下载失败（网络异常）';
    }
    if (dl.code < 200 || dl.code >= 300) {
      return '下载失败（HTTP ' + dl.code + '）';
    }
    if (dl.data.byteLength === 0) {
      return '下载到的备份包是空的';
    }
    onProgress('正在恢复数据…');
    const zipPath: string = ctx.cacheDir + '/litemd_webdav_restore.zip';
    try {
      WebDavStore.writeFileBytes(zipPath, dl.data);
    } catch (err) {
      return '写入本地缓存失败';
    }
    return BackupStore.restoreFromPath(ctx, zipPath);
  }
}
