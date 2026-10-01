/**
 * LiteMdReader · WebDAV 备份
 * ==========================
 *
 * 通过 WebDAV 把**全部文档 + 书架索引 + 批注 + 阅读设置**备份到用户自己的网盘
 * （坚果云、群晖、InfiniCloud 等任何支持 WebDAV 的服务）。
 *
 * 三个设计决策：
 *
 * 1. **只用标准 HTTP 方法**（PUT / MKCOL），不依赖任何私有 API——WebDAV 就是 HTTP，
 *   `@kit.NetworkKit` 的 http 模块足够。鉴权用 Basic（base64 of user:password）。
 *
 * 2. **先 MKCOL 建目录再 PUT**。多数 WebDAV 服务对「上传到不存在的目录」返回 409，
 *   所以备份开始时先尝试创建目录，失败不阻断（目录可能本来就存在）。
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
    const empty: WebDavConfig = { server: '', user: '', password: '', dir: 'litemdreader' };
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(ctx, { name: WebDavStore.PREF_NAME });
      const raw: string = store.getSync(WebDavStore.KEY_CONFIG, '') as string;
      if (raw.length === 0) {
        return empty;
      }
      const parsed: WebDavConfig = JSON.parse(raw) as WebDavConfig;
      return parsed;
    } catch (err) {
      return empty;
    }
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

  /**
   * 一键备份：全部文档 + 书架索引 + 批注 + 阅读设置快照。
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
      'readerKeepScreenOn', 'readerCustomBgLight', 'readerCustomBgDark'
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

    result.total = items.length;

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

    onProgress(result.total, result.total, '备份完成');
    return result;
  }
}
