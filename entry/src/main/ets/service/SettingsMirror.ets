/**
 * LiteMdReader · 设置镜像持久化
 * ==============================
 *
 * 为什么在 PersistentStorage 之外再落一份文件：
 *   实测出现「设置改完、退出应用重进就恢复默认」——主题色 / 灰体文本 / 深色模式
 *   这些键虽然都用 `PersistentStorage.persistProp` 注册过，但在部分设备/版本上
 *   写入并没有真正落到存储里。这里用**应用自己完全可控的文件**（沙箱 filesDir）
 *   再存一份：与 DocStore 的 shelf.json 同一条路径，已被证明可靠。
 *
 * 冲突处理（两份都可能存在，必须保证"新的赢"）：
 *   两边各记一个时间戳 —— 文件里是 `at`，PersistentStorage 里是 `appearanceSavedAt`。
 *   启动时只在「文件时间戳 > 已持久化时间戳」时才用文件覆盖 AppStorage，
 *   所以：
 *     · PersistentStorage 正常工作时两边时间戳同步，文件不会瞎覆盖；
 *     · PersistentStorage 失效（时间戳被重置成默认 0）时，文件必然更新 → 恢复成功。
 *
 * 同时负责广播 `appearanceTick`：主题色 / 灰字 / 沾色这类"派生色"开关
 * 是在 `paletteFor()` 里读 AppStorage 的（纯函数读不登记依赖），
 * 各页面读一下这个计数，改完设置当场就能重算，不必重进页面。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

/** 镜像文件结构 */
interface SettingsSnapshot {
  /** 写入时间（ms），用于与 PersistentStorage 的时间戳比新旧 */
  at: number;
  values: Record<string, string | number | boolean>;
}

export class SettingsMirror {
  /** AppStorage 键：已持久化的时间戳（与文件里的 at 比大小） */
  static readonly KEY_SAVED_AT: string = 'appearanceSavedAt';
  /** AppStorage 键：外观刷新计数（页面订阅它来做派生色重算） */
  static readonly KEY_TICK: string = 'appearanceTick';

  /**
   * 需要镜像的键：EntryAbility 里注册过持久化的那些（含阅读设置与外观设置）。
   * 新增持久化键时**记得同步加进来**，否则它就只有 PersistentStorage 一份兜底。
   */
  static readonly KEYS: string[] = [
    // 阅读排版 / 显示
    'readerThemeMode', 'readerFontSize', 'readerLineHeight', 'readerMeasure',
    'readerFontFamily', 'readerFontFamilyEn', 'readerFontWeight', 'readerParaSpace', 'readerIndent', 'readerShowMeta',
    // 界面字体（外观设置）与「同步到阅读页」开关、界面字号缩放与字重加粗
    'appFontFamily', 'appFontFamilyEn', 'appFontSyncReader', 'appFontScale', 'appFontWeightDelta',
    'readerKeepScreenOn', 'readerBrightness', 'readerCustomBgLight', 'readerCustomBgDark',
    'readerTabBarAtBottom',
    // 网页开放（阅读页「更多」面板开关）
    'readerWebOpen',
    'readerCardSwipeIgnore',
    // 大屏 / 平板横屏专属：侧边栏「默认展开」偏好
    'readerTocPinnedDefault', 'readerNotesPinnedDefault',
    'hlOpacity', 'waveThickness',
    // 壁纸 / 阅读背景
    'wallpaperPath', 'wallpaperPathLight', 'wallpaperPathDark',
    'wallpaperBlur', 'wallpaperScrim', 'wallpaperGenId',
    'readerBgPath', 'readerBgId',
    // 外观：主题色 / 卡片 / 灰体文本
    // （灰体文本：旧单套键 + 深浅两套新键；新键见 DesignTokens.grayTextOverride）
    'themeColor', 'cardTint', 'immersivePressGlow', 'cardGlowTouch',
    'customAccentFull', 'pageBgTint', 'grayTextMode', 'grayTextColor',
    // 手机端横屏开关（仅手机看得见的行；换机后保持同样的方向偏好）
    'phoneLandscape',
    'grayTextModeLight', 'grayTextModeDark', 'grayTextColorLight', 'grayTextColorDark',
    'glassStrength', 'cardFallback', 'particleDissolve',
    // 外观高级开关（2026-10-20）：沉浸光感 / 过渡动画 / 页面预热（beta）
    'immersiveLook', 'immersiveGrade', 'motionFx', 'preloadPages',
    // 书架显示：顶部「继续阅读」卡片 / 「回头看看」卡片是否显示
    'shelfResumeBanner', 'shelfMemoryCard',
    // 版本历史（自动保存与间隔）
    'versionAutoSave', 'versionAutoSaveInterval',
    // 学习卡的显示偏好：正反面互换 / 拼写记忆（复习页顶部芯片，换机后应保持一致）
    'reviewSwapMode', 'reviewTypingMode',
    // 引擎管理：被关闭的渲染引擎列表（逗号分隔 id，空串 = 全部开启）
    // 标签顺序（拖动排序后持久化；换机恢复同一套次序）
    'tagOrder',
    'disabledEngines',
    // 应用语言（外观设置里的选择器；languageTick 是会话内刷新计数，不进镜像）
    'appLanguage',
    // 备份必须带走的那部分：**大屏侧边栏宽度 / 抽屉沉浸 / 手写画布底纹**
    // （这些也是 persistProp 键，漏在这里就等于"换机恢复后设置少一截"）
    'readerTocPanelW', 'readerNotesPanelW', 'drawerImmersive',
    'sketchBgColor', 'sketchBgPattern', 'sketchBgLineWidth',
    // 材质档位（EntryAbility 每次启动会强制开材质，但等级/引擎选择仍应随备份走）
    'appearanceMaterialLevel', 'appearanceMaterialEngine',
    // **一次性标记与收藏名单**（第一腿 PersistentStorage 在真机强杀后不一定落盘，
    // 这几项必须有第二腿：设置页首启弹窗 / 更新弹窗 / 48h 自动检查 / 好评只弹一次 / 收藏恢复）
    'appMode', 'lastSeenVersion', 'lastAutoCheckAt', 'ratingPrompted',
    'starredDocsJson', 'starredTimesJson'
  ];

  private static pathOf(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/settings.json';
  }

  /**
   * **无条件**用镜像文件覆盖 AppStorage（备份恢复专用）。
   *
   * restore() 要靠时间戳比新旧，而刚解压出来的 settings.json 里 `at` 是**备份当时**的
   * 时间，通常比本机 `appearanceSavedAt` 旧 → 走 restore() 会被"旧的不覆盖新的"这条
   * 规则挡掉，设置看起来没恢复。恢复备份是用户明确要"以包里这份为准"，所以这里不比时间。
   *
   * 写的是 AppStorage：这些键都由 PersistentStorage.persistProp 注册过，
   * setOrCreate 会写穿到 preferences，因此**当场生效、也留到下次启动**，不需要重启应用。
   */
  static forceRestore(ctx: common.UIAbilityContext): number {
    let applied: number = 0;
    try {
      const path: string = SettingsMirror.pathOf(ctx);
      if (!fs.accessSync(path)) {
        return 0;
      }
      const text: string = fs.readTextSync(path, { encoding: 'utf-8' });
      if (text.length === 0) {
        return 0;
      }
      const snap: SettingsSnapshot = JSON.parse(text) as SettingsSnapshot;
      if (snap === null || snap === undefined || snap.values === undefined) {
        return 0;
      }
      for (let k = 0; k < SettingsMirror.KEYS.length; k++) {
        const key: string = SettingsMirror.KEYS[k];
        const v: string | number | boolean | undefined = snap.values[key];
        if (v === undefined || v === null) {
          continue;
        }
        AppStorage.setOrCreate(key, v);
        applied++;
      }
      const mirrorAt: number = snap.at === undefined ? Date.now() : snap.at;
      // 时间戳推到"现在"，免得下次启动时旧的 appearanceSavedAt 又把这批值判成过期
      AppStorage.setOrCreate(SettingsMirror.KEY_SAVED_AT,
        mirrorAt > Date.now() ? mirrorAt : Date.now());
    } catch (err) {
      // 镜像损坏：保持当前会话的设置不变
    }
    return applied;
  }

  /** 启动时调用一次：镜像比 PersistentStorage 新时，用它覆盖 AppStorage。 */
  static restore(ctx: common.UIAbilityContext): void {
    try {
      const path: string = SettingsMirror.pathOf(ctx);
      if (!fs.accessSync(path)) {
        return;
      }
      const text: string = fs.readTextSync(path, { encoding: 'utf-8' });
      if (text.length === 0) {
        return;
      }
      const snap: SettingsSnapshot = JSON.parse(text) as SettingsSnapshot;
      if (snap === null || snap === undefined || snap.values === undefined) {
        return;
      }
      const mirrorAt: number = snap.at === undefined ? 0 : snap.at;
      const storedAt: number | undefined = AppStorage.get<number>(SettingsMirror.KEY_SAVED_AT);
      if (storedAt !== undefined && storedAt !== null && storedAt >= mirrorAt) {
        // PersistentStorage 那份一样新（或更新）→ 不动，避免用旧镜像覆盖新设置
        return;
      }
      for (let k = 0; k < SettingsMirror.KEYS.length; k++) {
        const key: string = SettingsMirror.KEYS[k];
        const v: string | number | boolean | undefined = snap.values[key];
        if (v === undefined || v === null) {
          continue;
        }
        AppStorage.setOrCreate(key, v);
      }
      AppStorage.setOrCreate(SettingsMirror.KEY_SAVED_AT, mirrorAt);
    } catch (err) {
      // 镜像损坏不影响启动（PersistentStorage 那份仍在）
    }
  }

  /**
   * 落盘 + 广播刷新计数。在「设置改动 / 退到后台 / 退出」时调用。
   * ctx 为 null（拿不到上下文）时只广播计数，不落盘。
   */
  static save(ctx: common.UIAbilityContext | null): void {
    if (ctx !== null) {
      try {
        const values: Record<string, string | number | boolean> = {};
        for (let k = 0; k < SettingsMirror.KEYS.length; k++) {
          const key: string = SettingsMirror.KEYS[k];
          const s: string | undefined = AppStorage.get<string>(key);
          if (s !== undefined) {
            values[key] = s;
            continue;
          }
          const n: number | undefined = AppStorage.get<number>(key);
          if (n !== undefined) {
            values[key] = n;
            continue;
          }
          const b: boolean | undefined = AppStorage.get<boolean>(key);
          if (b !== undefined) {
            values[key] = b;
          }
        }
        const at: number = Date.now();
        const snap: SettingsSnapshot = { at: at, values: values };
        SettingsMirror.writeText(SettingsMirror.pathOf(ctx), JSON.stringify(snap));
        AppStorage.setOrCreate(SettingsMirror.KEY_SAVED_AT, at);
      } catch (err) {
        // 落盘失败只是少一层兜底，不影响使用
      }
    }
    SettingsMirror.bumpTick();
  }

  /** 广播「外观刷新计数」：页面 palette() 里读它，派生色改完当帧就能重算。 */
  static bumpTick(): void {
    const cur: number | undefined = AppStorage.get<number>(SettingsMirror.KEY_TICK);
    AppStorage.setOrCreate(SettingsMirror.KEY_TICK, (cur === undefined ? 0 : cur) + 1);
  }

  /** 与 DocStore.writeFile 同款落盘（fs 没有 writeTextSync 的兼容写法）。 */
  private static writeText(path: string, content: string): void {
    const file: fs.File =
      fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content);
    } finally {
      try {
        fs.closeSync(file);
      } catch (closeErr) {
        // 关闭失败无副作用
      }
    }
  }
}
