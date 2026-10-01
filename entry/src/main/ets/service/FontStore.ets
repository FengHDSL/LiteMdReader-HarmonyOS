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
import { fileIo as fs } from '@kit.CoreFileKit';

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
    return alive;
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
    }
    return removed;
  }
}
