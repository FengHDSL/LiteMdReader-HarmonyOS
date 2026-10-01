/**
 * LiteMdReader · 壁纸
 * ================
 *
 * 从系统图库选一张图作为阅读背景（移植自 xjau 的壁纸页语义）。
 *
 * 两个关键决策：
 *
 * 1. **用系统图库选择器（PhotoViewPicker），不要读媒体库权限**。
 *    选图器是系统 UI，用户选中的那张才是我们能拿到的，所以**不需要**申请
 *    `ohos.permission.READ_IMAGEVIDEO`。申请那个权限既过不了商店审核，
 *    用户也不会给——为了一张壁纸不值当。
 *
 * 2. **选中后立刻复制进沙箱**。图库里拿到的 `file://media/...` URI 是临时授权，
 *    重启后就会失效；落一份副本到 `<filesDir>/wallpaper.img` 才能长期生效。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

/** AppStorage 键：壁纸在沙箱里的绝对路径；空串 = 没有壁纸（旧全局键，保留兜底） */
export const WALLPAPER_PATH_KEY: string = 'wallpaperPath';
/** AppStorage 键：浅色模式壁纸路径（新增：深浅色自动切换不同壁纸） */
export const WALLPAPER_PATH_LIGHT_KEY: string = 'wallpaperPathLight';
/** AppStorage 键：深色模式壁纸路径 */
export const WALLPAPER_PATH_DARK_KEY: string = 'wallpaperPathDark';
/** AppStorage 键：壁纸模糊强度 0~20（vp），越大越朦胧，正文越清晰 */
export const WALLPAPER_BLUR_KEY: string = 'wallpaperBlur';
/** AppStorage 键：遮罩浓度 0~100，越大正文越易读 */
export const WALLPAPER_SCRIM_KEY: string = 'wallpaperScrim';

/**
 * 阅读背景（**与上面的应用壁纸完全隔离**）
 * --------------------------------------------------
 * 外观设置里的壁纸管的是书架/设置页的背景；
 * 这里这两项只管**阅读页正文背后**，互不影响，符合「阅读调整」的语义。
 */
export const READER_BG_PATH_KEY: string = 'readerBgPath';
export const READER_BG_ID_KEY: string = 'readerBgId';

export class WallpaperStore {
  /** 沙箱内的固定文件名。刻意不带扩展名——Image 能按内容识别格式。 */
  private static pathOf(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/wallpaper.img';
  }

  /** 当前壁纸路径（沙箱绝对路径）；空串表示未设置。 */
  static current(): string {
    const value: string | undefined = AppStorage.get<string>(WALLPAPER_PATH_KEY);
    return value !== undefined && value !== null ? value : '';
  }

  /** 供 Image 使用的 file:// 地址。Image 不认裸路径，必须带 file:// 前缀。 */
  static imageSource(): string {
    return WallpaperStore.imageSourceOf(WallpaperStore.current());
  }

  /**
   * 由**传入的路径**生成 Image 源。
   * 页面必须用这个（把自己 @StorageProp('wallpaperPath') 的值传进来）：
   * 纯函数里读 AppStorage 不登记依赖，换壁纸后已画出的页面不会重绘。
   */
  static imageSourceOf(path: string): string {
    return path.length > 0 ? 'file://' + path : '';
  }

  static blur(): number {
    const value: number | undefined = AppStorage.get<number>(WALLPAPER_BLUR_KEY);
    return value !== undefined && value !== null ? value : 4;
  }

  /** 遮罩 alpha（#AARRGGBB）。浓度 0 时返回全透明，让用户能完全关掉遮罩。 */
  static scrimColor(dark: boolean): string {
    const value: number | undefined = AppStorage.get<number>(WALLPAPER_SCRIM_KEY);
    const strength: number = value !== undefined && value !== null ? value : 42;
    return WallpaperStore.scrimColorOf(strength, dark);
  }

  /**
   * 由**传入的浓度**算遮罩色。
   * 页面必须用这个（把 @StorageLink('wallpaperScrim') 传进来）：
   * 纯函数里读 AppStorage 不登记依赖，拖动浓度滑块后已画出的页面不会重绘
   * ——「蒙版要退出界面再进才生效」就是这个原因。
   */
  static scrimColorOf(strength: number, dark: boolean): string {
    if (strength <= 0) {
      return '#00000000';
    }
    const a: number = Math.round(Math.min(100, strength) * 2.55);
    const hex: string = a < 16 ? '0' + a.toString(16).toUpperCase() : a.toString(16).toUpperCase();
    // 深色主题压黑、浅色主题压白，两个方向都是「让正文更清楚」
    return '#' + hex + (dark ? '000000' : 'FFFFFF');
  }

  /**
   * 拉起系统图库选一张图并落盘。
   * 返回空串表示成功（返回值为错误信息），失败时返回可读原因。
   */
  static async pick(ctx: common.UIAbilityContext): Promise<string> {
    return WallpaperStore.pickFor(ctx, false);
  }

  /**
   * 选壁纸（**按模式分别记忆**：深色 / 浅色可以设不同的壁纸）。
   * 落盘文件名带**时间戳**——路径每次都不同，页面的 @StorageProp 才能感知变化，
   * 壁纸才能**实时**切换（此前固定文件名 wallpaper.img 导致路径不变、页面不重绘）。
   *
   * @returns 空串 = 成功；否则是可读的错误原因。
   */
  static async pickFor(ctx: common.UIAbilityContext, dark: boolean): Promise<string> {
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const result: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      if (result === undefined || result === null || result.photoUris === undefined
        || result.photoUris.length === 0) {
        return '未选择图片';
      }
      const uri: string = result.photoUris[0];
      const dest: string = ctx.filesDir + '/wallpaper_' + (dark ? 'dark' : 'light') + '_'
        + Date.now() + '.img';

      // 删同模式的旧图，避免沙箱里残留文件越积越多
      const oldPath: string = AppStorage.get<string>(dark ? WALLPAPER_PATH_DARK_KEY : WALLPAPER_PATH_LIGHT_KEY)
        ?? '';
      try {
        if (oldPath.length > 0 && fs.accessSync(oldPath)) {
          fs.unlinkSync(oldPath);
        }
      } catch (cleanErr) {
        // 删不掉就留着，不影响结果
      }

      const src: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        fs.copyFileSync(src.fd, dest);
      } finally {
        try {
          fs.closeSync(src);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }

      AppStorage.setOrCreate(dark ? WALLPAPER_PATH_DARK_KEY : WALLPAPER_PATH_LIGHT_KEY, dest);
      return '';
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      return e.message !== undefined ? e.message : '选择图片失败';
    }
  }

  /** 清除壁纸：删文件并清空设置。 */
  /** 清除指定模式的壁纸（删除落盘文件 + 清空路径）。 */
  static clearFor(ctx: common.UIAbilityContext, dark: boolean): void {
    const key: string = dark ? WALLPAPER_PATH_DARK_KEY : WALLPAPER_PATH_LIGHT_KEY;
    const old: string | undefined = AppStorage.get<string>(key);
    try {
      if (old !== undefined && old.length > 0 && fs.accessSync(old)) {
        fs.unlinkSync(old);
      }
    } catch (err) {
      // 文件不存在或删不掉，都要把设置清掉
    }
    AppStorage.setOrCreate(key, '');
  }

  /**
   * 启动时校验 + **自愈**：
   *  · 设置里没记路径、但沙箱里还有壁纸文件 → 按固定文件名把路径补回去
   *    （曾出现"选完壁纸重启就没了"：键丢了但文件还在）
   *  · 记的路径文件已不在 → 用固定文件名那份副本兜底，都没有才清空设置
   */
  static validate(ctx: common.UIAbilityContext): void {
    const dest: string = WallpaperStore.pathOf(ctx);
    let destAlive: boolean = false;
    try {
      destAlive = fs.accessSync(dest);
    } catch (err) {
      destAlive = false;
    }
    const path: string = WallpaperStore.current();
    if (path.length === 0) {
      if (destAlive) {
        AppStorage.setOrCreate(WALLPAPER_PATH_KEY, dest);
      }
      return;
    }
    try {
      if (!fs.accessSync(path)) {
        AppStorage.setOrCreate(WALLPAPER_PATH_KEY, destAlive ? dest : '');
      }
    } catch (err) {
      AppStorage.setOrCreate(WALLPAPER_PATH_KEY, destAlive ? dest : '');
    }
  }

  // ══════════════════════ 阅读背景（与上面的应用壁纸互相独立） ══════════════════════

  /** 阅读背景图片在沙箱里的固定路径 */
  private static readerPathOf(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/reader_bg.img';
  }

  /**
   * 启动时校验 + 自愈阅读背景。
   * `readerBgPath` 此前**漏注册持久化**（只有 readerBgId 注册了），
   * 于是选完阅读背景一重启就"消失"——文件还在，路径没了。这里双向兜底修复。
   */
  static validateReaderBg(ctx: common.UIAbilityContext): void {
    const dest: string = WallpaperStore.readerPathOf(ctx);
    let destAlive: boolean = false;
    try {
      destAlive = fs.accessSync(dest);
    } catch (err) {
      destAlive = false;
    }
    const value: string | undefined = AppStorage.get<string>(READER_BG_PATH_KEY);
    const path: string = value === undefined || value === null ? '' : value;
    if (path.length === 0) {
      if (destAlive) {
        AppStorage.setOrCreate(READER_BG_PATH_KEY, dest);
      }
      return;
    }
    try {
      if (!fs.accessSync(path)) {
        AppStorage.setOrCreate(READER_BG_PATH_KEY, destAlive ? dest : '');
      }
    } catch (err) {
      AppStorage.setOrCreate(READER_BG_PATH_KEY, destAlive ? dest : '');
    }
  }

  /** 阅读背景图（file:// 地址）；空串 = 未设置 */
  static readerImageSource(): string {
    const value: string | undefined = AppStorage.get<string>(READER_BG_PATH_KEY);
    const path: string = value !== undefined && value !== null ? value : '';
    return path.length > 0 ? 'file://' + path : '';
  }

  /**
   * 选一张图作为**阅读背景**（与外观壁纸互不影响）。
   * 返回空串表示成功，否则是错误原因。
   */
  static async pickReaderBg(ctx: common.UIAbilityContext): Promise<string> {
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const result: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      if (result === undefined || result === null || result.photoUris === undefined
        || result.photoUris.length === 0) {
        return '未选择图片';
      }
      const uri: string = result.photoUris[0];
      // 唯一文件名（带时间戳）：路径每次都变，页面才能**实时**重绘阅读背景
      // （固定文件名 reader_bg.img 会导致路径字符串不变、@StorageProp 不触发）
      const dest: string = ctx.filesDir + '/reader_bg_' + Date.now() + '.img';
      const oldReaderBg: string | undefined = AppStorage.get<string>(READER_BG_PATH_KEY);
      try {
        if (oldReaderBg !== undefined && oldReaderBg.length > 0 && fs.accessSync(oldReaderBg)) {
          fs.unlinkSync(oldReaderBg);
        }
      } catch (cleanErr) {
        // 覆盖写即可
      }
      const src: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        fs.copyFileSync(src.fd, dest);
      } finally {
        try {
          fs.closeSync(src);
        } catch (closeErr) {
          // 忽略
        }
      }
      AppStorage.setOrCreate(READER_BG_PATH_KEY, dest);
      // 手选图优先于内置阅读背景，选完把内置款清掉
      AppStorage.setOrCreate(READER_BG_ID_KEY, '');
      return '';
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      return e.message !== undefined ? e.message : '选择图片失败';
    }
  }

  /** 清除阅读背景图（不动应用壁纸）。 */
  static clearReaderBg(ctx: common.UIAbilityContext): void {
    try {
      const dest: string = WallpaperStore.readerPathOf(ctx);
      if (fs.accessSync(dest)) {
        fs.unlinkSync(dest);
      }
    } catch (err) {
      // 文件不在也要清设置
    }
    AppStorage.setOrCreate(READER_BG_PATH_KEY, '');
  }
}
