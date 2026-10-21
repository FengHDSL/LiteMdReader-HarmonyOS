/**
 * LiteMdReader · 用户自定义字体
 * ===============================
 *
 * 设备上可稳定使用的只有系统默认字体，衬线/等宽在各机型上不可靠——
 * 所以正文字体只有「默认」，其余全部由用户自己导入 .ttf / .otf：
 * 文件复制进沙箱 <filesDir>/fonts/，启动（与导入时）用 font.registerFont 注册，
 * familyName 取文件名（去扩展名），设置里的字体键存这个 familyName。
 */

import { common } from '@kit.AbilityKit';
import { font } from '@kit.ArkUI';
import { text } from '@kit.ArkGraphics2D';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 系统已安装字体（family = fontFamily 家族名，可直接用于 fontFamily 属性） */
export interface SystemFont {
  family: string;
  fullName: string;
  /** 字体文件绝对路径（descriptor.path）——注册进 ArkUI 字体管理器时用 */
  path: string;
}

export interface UserFont {
  /** 注册的 familyName（= 文件名去扩展名），同时是设置键 */
  family: string;
  /** 沙箱内文件名 */
  fileName: string;
}

export class FontStore {
  private static dir: string = '';
  private static manifestPath: string = '';
  private static registered: string[] = [];

  static init(ctx: common.UIAbilityContext): void {
    if (FontStore.dir.length > 0) {
      return;
    }
    FontStore.dir = ctx.filesDir + '/fonts';
    FontStore.manifestPath = ctx.filesDir + '/fonts.json';
    try {
      if (!fs.accessSync(FontStore.dir)) {
        fs.mkdirSync(FontStore.dir, true);
      }
    } catch (err) {
      // 目录可能已存在
    }
  }

  /**
   * 读字体清单（fonts.json）。
   * fs 的目录列举只有异步接口，这里用清单文件维护列表：导入 / 删除时同步更新。
   */
  private static loadManifest(): UserFont[] {
    try {
      if (!fs.accessSync(FontStore.manifestPath)) {
        return [];
      }
      const text: string = fs.readTextSync(FontStore.manifestPath, { encoding: 'utf-8' });
      if (text.length === 0) {
        return [];
      }
      const parsed: UserFont[] = JSON.parse(text) as UserFont[];
      if (parsed === null || parsed === undefined) {
        return [];
      }
      return parsed;
    } catch (err) {
      return [];
    }
  }

  private static saveManifest(fonts: UserFont[]): void {
    try {
      const f: fs.File = fs.openSync(FontStore.manifestPath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, JSON.stringify(fonts));
      } finally {
        try {
          fs.closeSync(f);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
    } catch (err) {
      // 清单写失败只影响下次启动的列表
    }
  }

  /** 已导入字体列表（读清单）。 */
  static list(ctx: common.UIAbilityContext): UserFont[] {
    FontStore.init(ctx);
    // **进程内缓存**（1.1.0 转场降载）：Reader 每打开一篇文档都会调 registerAll →
    // list → 读清单文件 + 逐个 accessSync，全是同步 IO，正好卡在转场首帧前。
    // 字体清单只在导入 / 删除时变化（那两处会调 invalidateCache），缓存安全。
    if (FontStore.cacheReady) {
      return FontStore.cache.slice();
    }
    const fonts: UserFont[] = FontStore.loadManifest();
    // 磁盘文件被外部删掉的条目剔除
    const alive: UserFont[] = [];
    for (let k = 0; k < fonts.length; k++) {
      try {
        if (fs.accessSync(FontStore.dir + '/' + fonts[k].fileName)) {
          alive.push(fonts[k]);
        }
      } catch (err) {
        // 文件不存在，跳过
      }
    }
    FontStore.cache = alive;
    FontStore.cacheReady = true;
    return alive.slice();
  }

  /** 字体清单缓存（进程内）：转场期间避免重复同步 IO。 */
  private static cache: UserFont[] = [];
  private static cacheReady: boolean = false;

  /** 系统已安装字体（用户通过系统「字体安装和管理」导入的 INSTALLED 类型） */
  static sysCache: SystemFont[] = [];
  private static sysReady: boolean = false;

  /**
   * **查询系统已安装字体**（用户要求：调用系统字体管理器，应用无需自建导入工具）。
   * API 14+：getSystemFontFullNamesByType(INSTALLED) → getFontDescriptorByFullName
   * 取 fontFamily（这才是 fontFamily 属性匹配用的家族名）。同家族多个全名去重。
   */
  static async loadInstalled(): Promise<SystemFont[]> {
    if (FontStore.sysReady) {
      return FontStore.sysCache.slice();
    }
    try {
      const fullNames: string[] =
        await text.getSystemFontFullNamesByType(text.SystemFontType.INSTALLED);
      const seen: string[] = [];
      const out: SystemFont[] = [];
      for (let k = 0; k < fullNames.length; k++) {
        try {
          const descriptor: text.FontDescriptor =
            await text.getFontDescriptorByFullName(fullNames[k], text.SystemFontType.INSTALLED);
          const family: string = descriptor.fontFamily ?? '';
          if (family.length > 0 && seen.indexOf(family) < 0) {
            seen.push(family);
            out.push({
              family: family,
              fullName: fullNames[k],
              path: descriptor.path ?? ''
            });
          }
        } catch (err) {
          // 单个字体描述符失败跳过
        }
      }
      FontStore.sysCache = out;
      FontStore.sysReady = true;
      return out.slice();
    } catch (err) {
      // API 不支持 / 无字体：返回空
      return [];
    }
  }

  /**
   * **把系统已安装字体注册进 ArkUI 字体管理器**（关键一步）。
   * 官方文档说 INSTALLED 字体直接取 `descriptor.fontFamily` 就能用，但真机实测
   * （2026-10-21）不成立：选择器里的预览行与正文都仍是系统默认字。所以按导入字体
   * 同一套办法补注册 —— `font.registerFont({ familyName: family, familySrc: 'file://' + path })`，
   * 注册过之后 `fontFamily` 才解析得到。路径不可读时逐个静默跳过并记日志
   * （那种字体就是取不到文件，界面回退默认，不能让整个流程崩）。
   * @returns 成功可用的数量（含"早就注册过"的）
   */
  static async registerInstalledAll(): Promise<number> {
    const list: SystemFont[] = await FontStore.loadInstalled();
    let ok: number = 0;
    for (let k = 0; k < list.length; k++) {
      const s: SystemFont = list[k];
      if (FontStore.registered.indexOf(s.family) >= 0) {
        ok++;
        continue;
      }
      if (s.path.length === 0) {
        hilog.warn(0x0000, 'FontStore', 'installed font has no path: %{public}s', s.family);
        continue;
      }
      try {
        const info: font.FontOptions = {
          familyName: s.family,
          familySrc: 'file://' + s.path
        };
        font.registerFont(info);
        FontStore.registered.push(s.family);
        ok++;
      } catch (err) {
        const code: number = err === null || err === undefined ? 0 : (err as BusinessError).code;
        hilog.warn(0x0000, 'FontStore', 'register installed font failed: %{public}s code=%{public}d',
          s.family, code);
      }
    }
    hilog.info(0x0000, 'FontStore', 'installed fonts registered %{public}d/%{public}d', ok, list.length);
    return ok;
  }

  /** 字体导入 / 删除后调用：下次 list 重新读盘。 */
  static invalidateCache(): void {
    FontStore.cacheReady = false;
    FontStore.cache = [];
  }

  /** 注册全部已导入字体（幂等）。进书架 / 进设置页时调用。 */
  static registerAll(ctx: common.UIAbilityContext): void {
    const fonts: UserFont[] = FontStore.list(ctx);
    for (let k = 0; k < fonts.length; k++) {
      FontStore.registerOne(fonts[k]);
    }
  }

  private static registerOne(f: UserFont): void {
    if (FontStore.registered.indexOf(f.family) >= 0) {
      return;
    }
    try {
      // FontOptions 的字段是 familyName / familySrc；沙箱文件按官方建议带 file:// 前缀
      const info: font.FontOptions = {
        familyName: f.family,
        familySrc: 'file://' + FontStore.dir + '/' + f.fileName
      };
      font.registerFont(info);
      FontStore.registered.push(f.family);
    } catch (err) {
      // 注册失败（文件损坏等）跳过该字体，界面静默回退默认
    }
  }

  /** 从外部 URI 导入字体文件，返回注册的 familyName；失败返回空串。 */
  static importFromUri(ctx: common.UIAbilityContext, uri: string): string {
    FontStore.init(ctx);
    const slash: number = uri.lastIndexOf('/');
    let base: string = slash >= 0 ? uri.substring(slash + 1) : uri;
    base = decodeURIComponent(base);
    const lower: string = base.toLowerCase();
    if (!lower.endsWith('.ttf') && !lower.endsWith('.otf')) {
      return '';
    }
    let stem: string = base.substring(0, base.length - 4);
    stem = stem.replace(/[\\/:*?"<>|]/g, '_').trim();
    if (stem.length === 0) {
      stem = '导入字体';
    }
    const fileName: string = stem + (lower.endsWith('.otf') ? '.otf' : '.ttf');
    const target: string = FontStore.dir + '/' + fileName;
    try {
      const src: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat: fs.Stat = fs.statSync(src.fd);
      // 字体文件上限 30MB
      if (stat.size > 30 * 1024 * 1024) {
        fs.closeSync(src);
        return '';
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(src.fd, buffer);
      fs.closeSync(src);
      const dst: fs.File = fs.openSync(target,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(dst.fd, buffer);
      } finally {
        try {
          fs.closeSync(dst);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
    } catch (err) {
      return '';
    }
    const f: UserFont = { family: stem, fileName: fileName };
    FontStore.registerOne(f);
    // 更新清单
    const fonts: UserFont[] = FontStore.loadManifest();
    fonts.push(f);
    FontStore.saveManifest(fonts);
    FontStore.invalidateCache();
    return stem;
  }

  /** 删除字体文件。已注册的本体本次运行仍可用，重启后彻底消失。 */
  static remove(ctx: common.UIAbilityContext, family: string): boolean {
    const fonts: UserFont[] = FontStore.loadManifest();
    const kept: UserFont[] = [];
    let removed: boolean = false;
    for (let k = 0; k < fonts.length; k++) {
      if (fonts[k].family === family) {
        try {
          fs.unlinkSync(FontStore.dir + '/' + fonts[k].fileName);
          removed = true;
        } catch (err) {
          kept.push(fonts[k]);
        }
      } else {
        kept.push(fonts[k]);
      }
    }
    if (removed) {
      FontStore.saveManifest(kept);
      FontStore.invalidateCache();
    }
    return removed;
  }
}
