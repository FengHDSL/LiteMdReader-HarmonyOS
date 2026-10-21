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
import { font, MeasureText } from '@kit.ArkUI';
import { text } from '@kit.ArkGraphics2D';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 系统字体表里的一款（**一个样式一条**，不再按家族合并）。
 * · key    = fullName，选中后存进设置、注册与 fontFamily 解析都用它 —— 家族名分不出
 *            Regular / Bold / Italic，只有全名能定位到具体样式；
 * · family = descriptor.fontFamily，用于分组显示与老值的兼容（老设置里存的是家族名）；
 * · type   = 'installed'（用户装的）/ 'generic'（系统自带）/ 'stylish'（样式字体）；
 * · path   = 字体文件绝对路径，注册进 ArkUI 字体管理器时用；空 = 取不到文件（不可用）。
 */
export interface SystemFont {
  key: string;
  family: string;
  fullName: string;
  path: string;
  type: string;
  style: string;
}

/** 磁盘索引（fontindex.json）的结构；版本变了旧索引直接作废重扫。 */
interface FontIndexFile {
  version: number;
  savedAt: number;
  fonts: SystemFont[];
}

export interface UserFont {
  /** 注册的 familyName（= 文件名去扩展名），同时是设置键 */
  family: string;
  /** 沙箱内文件名 */
  fileName: string;
}

export class FontStore {
  private static dir: string = '';
  /** 磁盘索引版本：字段结构或枚举口径一变就 +1，旧索引自动作废重扫 */
  private static readonly INDEX_VERSION: number = 1;
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
   * **注册失败**的系统字体家族名（沙箱读不到那个路径时就是这样）。
   * 选这些款不会有任何视觉效果，界面要如实提示，而不是让用户以为"点了没反应"。
   */
  static installFailed: string[] = [];

  /** 这款已安装字体是否可用（没进失败名单就算可用；名单在注册阶段填） */
  static installedUsable(family: string): boolean {
    return FontStore.installFailed.indexOf(family) < 0;
  }

  /** 字重探测结果缓存（key = 家族名；true = 有真粗体） */
  private static boldCache: Record<string, boolean> = {};

  /**
   * **这款字体有没有真粗体**（外观设置的「字重」档位用它决定置灰）。
   * SDK 里没有查字重的接口（`FontInfo` / `FontDescriptor` 只给 path / family / fullName /
   * postScriptName），所以只能实测：同一串字分别按 400 与 700 量宽度，
   * 宽度几乎不变就说明这款字体没有粗体字重（引擎要么合成假粗、要么直接忽略）。
   * 用拉丁与数字测量：中文在很多字体里本身就缺字形，会污染结果。
   */
  static supportsBold(family: string): boolean {
    const key: string = family.length === 0 ? '__default__' : family;
    const cached: boolean | undefined = FontStore.boldCache[key];
    if (cached !== undefined && cached !== null) {
      return cached;
    }
    const fam: string = family.length === 0 ? 'HarmonyOS Sans' : family;
    let ok: boolean = false;
    try {
      const regular: number = MeasureText.measureText({
        textContent: 'Handgloves 0123456789', fontSize: 20, fontFamily: fam, fontWeight: 400
      });
      const bold: number = MeasureText.measureText({
        textContent: 'Handgloves 0123456789', fontSize: 20, fontFamily: fam, fontWeight: 700
      });
      // 5% 以上的宽度差才算"真的换了字重"
      ok = regular > 0 && Math.abs(bold - regular) / regular > 0.05;
    } catch (err) {
      // 量不了就当不支持（宁可不给加粗档位）
      ok = false;
    }
    FontStore.boldCache[key] = ok;
    return ok;
  }

  /**
   * **查询系统已安装字体**（用户要求：调用系统字体管理器，应用无需自建导入工具）。
   * API 14+：getSystemFontFullNamesByType(INSTALLED) → getFontDescriptorByFullName
   * 取 fontFamily（这才是 fontFamily 属性匹配用的家族名）。同家族多个全名去重。
   */
  static async loadInstalled(force: boolean = false): Promise<SystemFont[]> {
    if (FontStore.sysReady && !force) {
      return FontStore.sysCache.slice();
    }
    // 第二次及以后打开面板：先吃磁盘索引（扫描要逐款取 descriptor，是真会卡的那一下），
    // 没有索引才现扫；扫完立刻落盘。
    if (!force) {
      const cached: SystemFont[] = FontStore.readIndex();
      if (cached.length > 0) {
        FontStore.sysCache = cached;
        FontStore.sysReady = true;
        return cached.slice();
      }
    }
    const out: SystemFont[] = await FontStore.scanInstalled();
    if (out.length > 0) {
      FontStore.sysCache = out;
      FontStore.sysReady = true;
      FontStore.writeIndex(out);
    }
    return out.slice();
  }

  /** 强制重扫（界面上的「刷新」按钮走这条），返回新的总数。 */
  static async refreshInstalled(): Promise<number> {
    const out: SystemFont[] = await FontStore.scanInstalled();
    FontStore.sysCache = out;
    FontStore.sysReady = true;
    FontStore.writeIndex(out);
    return out.length;
  }

  /**
   * 现扫系统字体表。三个类型都要查，只查 INSTALLED 会少一大半：
   *  · INSTALLED = 用户在系统「字体安装和管理」里装的；
   *  · GENERIC   = 系统自带字体；
   *  · STYLISH   = 样式字体（2-in-1 那套，手机上一般空）。
   * **不按家族名去重**：一款字体的 Regular / Bold / Italic 是各自独立的 fullName，
   * 去重就把样式并掉了（用户反馈"多个样式没显示出来"）。只按 fullName 去重，
   * 顺序按 INSTALLED → GENERIC → STYLISH，先出现的赢。
   */
  private static async scanInstalled(): Promise<SystemFont[]> {
    const types: text.SystemFontType[] = [
      text.SystemFontType.INSTALLED, text.SystemFontType.GENERIC, text.SystemFontType.STYLISH
    ];
    const typeTags: string[] = ['installed', 'generic', 'stylish'];
    const seen: string[] = [];
    const out: SystemFont[] = [];
    for (let t = 0; t < types.length; t++) {
      let fullNames: string[] = [];
      try {
        fullNames = await text.getSystemFontFullNamesByType(types[t]);
      } catch (err) {
        continue;
      }
      const batch: SystemFont[] = await FontStore.describeAll(fullNames, types[t], typeTags[t], seen);
      for (let k = 0; k < batch.length; k++) {
        out.push(batch[k]);
      }
    }
    return out;
  }

  /**
   * 逐款取 descriptor —— 这是扫描里最慢的一段，**分批并发**而不是串行 await
   * （串行时几百款要排队几百个 Promise，就是打开面板那一下的卡顿）。
   */
  private static async describeAll(fullNames: string[], type: text.SystemFontType,
    tag: string, seen: string[]): Promise<SystemFont[]> {
    const out: SystemFont[] = [];
    const step: number = 16;
    for (let start = 0; start < fullNames.length; start += step) {
      const slice: string[] = fullNames.slice(start, start + step);
      const settled: (text.FontDescriptor | null)[] = [];
      for (let k = 0; k < slice.length; k++) {
        settled.push(null);
      }
      const jobs: Promise<void>[] = [];
      for (let k = 0; k < slice.length; k++) {
        const idx: number = k;
        const name: string = slice[k];
        jobs.push(text.getFontDescriptorByFullName(name, type).then((d: text.FontDescriptor) => {
          settled[idx] = d;
        }).catch(() => {
          settled[idx] = null;
        }));
      }
      await Promise.all(jobs);
      for (let k = 0; k < slice.length; k++) {
        const d: text.FontDescriptor | null = settled[k];
        const name: string = slice[k];
        if (d === null || seen.indexOf(name) >= 0) {
          continue;
        }
        const family: string = d.fontFamily ?? '';
        if (family.length === 0) {
          continue;
        }
        seen.push(name);
        out.push({
          // 选中的就是这个键：**样式各自独立**，家族名分不出 Bold / Italic
          key: name,
          family: family,
          fullName: name,
          path: d.path ?? '',
          type: tag,
          style: FontStore.styleOf(family, name)
        });
      }
    }
    return out;
  }

  /** 从 fullName 里剥出样式后缀（"HarmonyOS Sans SC Bold" → "Bold"），认不出就返回空串 */
  private static styleOf(family: string, fullName: string): string {
    if (fullName.length <= family.length || !fullName.startsWith(family)) {
      return '';
    }
    return fullName.substring(family.length).trim();
  }

  /** 磁盘索引路径（放在 fonts 目录里，不用 '..' —— 沙箱路径按字面解析，回溯不保证可用）。 */
  private static indexPath(): string {
    if (FontStore.dir.length === 0) {
      return '';
    }
    return FontStore.dir + '/fontindex.json';
  }

  private static readIndex(): SystemFont[] {
    const p: string = FontStore.indexPath();
    if (p.length === 0) {
      return [];
    }
    try {
      const raw: FontIndexFile = JSON.parse(fs.readTextSync(p, { encoding: 'utf-8' })) as FontIndexFile;
      if (raw === undefined || raw === null || raw.version !== FontStore.INDEX_VERSION
        || raw.fonts === undefined || raw.fonts === null) {
        return [];
      }
      return raw.fonts;
    } catch (err) {
      return [];
    }
  }

  private static writeIndex(fonts: SystemFont[]): void {
    const p: string = FontStore.indexPath();
    if (p.length === 0) {
      return;
    }
    try {
      const file: fs.File = fs.openSync(p,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        const payload: FontIndexFile = { version: FontStore.INDEX_VERSION, savedAt: Date.now(), fonts: fonts };
        fs.writeSync(file.fd, JSON.stringify(payload));
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      // 写失败只是下次还要重扫，不影响功能
    }
  }

  /**
   * **把系统字体注册进 ArkUI 字体管理器**（关键一步）。
   * 官方文档说 INSTALLED 字体直接取 `descriptor.fontFamily` 就能用，但真机实测
   * （2026-10-21）不成立：选择器里的预览行与正文都仍是系统默认字。所以按导入字体
   * 同一套办法补注册 —— `font.registerFont({ familyName, familySrc: 'file://' + path })`。
   * 家族名与 fullName **各注册一份**：老设置里存的是家族名（去重时代的值），新选的是
   * fullName（分样式），两条路都要能解析到。
   * @returns 成功可用的数量（含"早就注册过"的）
   */
  static async registerInstalledAll(): Promise<number> {
    const list: SystemFont[] = await FontStore.loadInstalled();
    let ok: number = 0;
    for (let k = 0; k < list.length; k++) {
      ok += await FontStore.registerSystemFont(list[k]);
    }
    hilog.info(0x0000, 'FontStore', 'installed fonts registered %{public}d/%{public}d', ok, list.length);
    return ok;
  }

  /**
   * 只注册**当前正在用的**那几款（设置里存的键）。启动时走这条而不是 registerInstalledAll：
   * 几百款逐个 registerFont + 取索引是书架首帧后的明显负载，而没被选中的字体根本不需要注册。
   * 在选择器里点中某款时，宿主再对该款调 ensureRegisteredByName 补上。
   */
  static async registerSelected(names: string[]): Promise<number> {
    const list: SystemFont[] = await FontStore.loadInstalled();
    let ok: number = 0;
    for (let n = 0; n < names.length; n++) {
      const name: string = names[n];
      if (name.length === 0) {
        continue;
      }
      for (let k = 0; k < list.length; k++) {
        const s: SystemFont = list[k];
        // 家族名与 fullName 都算命中：老值是家族名，新值是带样式的全名
        if (s.key === name || s.family === name) {
          ok += await FontStore.registerSystemFont(s);
        }
      }
    }
    return ok;
  }

  /** 选中某款时按需注册（列表里点一下就走，不等下一次启动）。 */
  static async ensureRegisteredByName(name: string): Promise<void> {
    await FontStore.registerSelected([name]);
  }

  /** 注册单款系统字体（家族名 + 全名各一份）。@returns 1 = 可用，0 = 没路径 / 注册失败。 */
  private static async registerSystemFont(s: SystemFont): Promise<number> {
    if (s.path.length === 0) {
      const list: SystemFont[] = await FontStore.loadInstalled();
      // 索引里的路径为空：这款就是取不到文件，记进"不可用"名单，界面点它时给说明
      for (let k = 0; k < list.length; k++) {
        if (list[k].key === s.key && list[k].path.length === 0 && FontStore.installFailed.indexOf(s.key) < 0) {
          FontStore.installFailed.push(s.key);
        }
      }
      hilog.warn(0x0000, 'FontStore', 'installed font has no path: %{public}s', s.key);
      return 0;
    }
    let ok: number = 0;
    const names: string[] = [s.family, s.key];
    for (let n = 0; n < names.length; n++) {
      const name: string = names[n];
      if (name.length === 0 || FontStore.registered.indexOf(name) >= 0) {
        ok = 1;
        continue;
      }
      try {
        const info: font.FontOptions = { familyName: name, familySrc: 'file://' + s.path };
        font.registerFont(info);
        FontStore.registered.push(name);
        ok = 1;
      } catch (err) {
        const code: number = err === null || err === undefined ? 0 : (err as BusinessError).code;
        hilog.warn(0x0000, 'FontStore', 'register installed font failed: %{public}s code=%{public}d',
          name, code);
        if (FontStore.installFailed.indexOf(s.key) < 0) {
          FontStore.installFailed.push(s.key);
        }
      }
    }
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
