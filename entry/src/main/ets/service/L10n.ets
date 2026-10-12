/**
 * 澄笺 · 应用语言（i18n 运行时）
 * ============================
 *
 * 为什么是自己查词典，而不是 resources/*/string.json + $r()：
 *   ① 全应用约 2,000 处文案直接写在 .ets 里（Text('深色模式')、toast、占位符、
 *      Web 模板标题、导出文件名…），$r() 只能覆盖 ArkUI 文本，且 key 必须是**字面量**；
 *   ② 平台的 i18n.System.setAppPreferredLanguage 要**冷启动**才生效
 *      （SDK @ohos.i18n.d.ts:300：Resources are loaded in the preferred language
 *      when the application is launched），等于每切一次语言都要用户重启应用；
 *   ③ 词典以**简体原文当键**，没登记的句子自动回退原文 → 可以一页一页迁移，
 *      中途界面不会出现空白或 ???，也不会因为漏翻译而坏掉。
 *   setAppPreferredLanguage 仍然会调用：下次冷启动时，系统级组件（日期格式、
 *   resourceManager 资源目录、服务卡片）就与界面语言一致。
 *
 * 生效路径：setChoice() 写 appLanguage + 递增 languageTick；
 * 每个页面挂一个 `@StorageProp(L10n.KEY_TICK) langTick`，取文案时读一次它，
 * ArkUI 才会把这个页面登记成"语言变了要重画"（与 palette() 里读 appearanceTick 同理）。
 *
 * 硬规则（tools/verify-l10n.js 会检查）：
 *   · 「澄笺」二字与拼音 cheng / xuan / yan / zhu / xia 是品牌名，任何语言都不翻译；
 *   · 占位符 %1 %2 必须在各语言里出现同组（语序不同可以调换位置）；
 *   · 词典值不能为空串，查不到就回退简体原文。
 */
import { i18n } from '@kit.LocalizationKit';
import { EN_US_MAP } from './l10n/DictEn';
import { EN_GB_MAP } from './l10n/DictEnGb';
import { ZH_HANT_MAP } from './l10n/DictZhHant';
import { ZH_TW_MAP } from './l10n/DictZhTw';
import { JA_JP_MAP } from './l10n/DictJa';
import { KO_KR_MAP } from './l10n/DictKo';

export class L10n {
  /** AppStorage：用户选的语言（'system' 或内置 id） */
  static readonly KEY_CHOICE: string = 'appLanguage';
  /** AppStorage：语言刷新计数（页面靠它重画） */
  static readonly KEY_TICK: string = 'languageTick';
  static readonly SYSTEM: string = 'system';
  static readonly ZH_CN: string = 'zh-CN';
  /** 选择项顺序（外观设置里的芯片按这个顺序排） */
  static readonly IDS: string[] = [
    'system', 'zh-CN', 'zh-HK', 'zh-TW', 'en-US', 'en-GB', 'ja-JP', 'ko-KR'
  ];

  /** 语言刷新计数：包一层，避免每个页面手写 AppStorage.get 的异常处理。 */
  static tick(): number {
    try {
      const v: number | undefined = AppStorage.get<number>(L10n.KEY_TICK);
      return v === undefined || v === null ? 0 : v;
    } catch (err) {
      return 0;
    }
  }

  /** 用户的选择（原始值，可能还是 'system'）。 */
  static choice(): string {
    try {
      const v: string | undefined = AppStorage.get<string>(L10n.KEY_CHOICE);
      if (v === undefined || v === null || v.length === 0) {
        return L10n.SYSTEM;
      }
      return v;
    } catch (err) {
      return L10n.SYSTEM;
    }
  }

  /**
   * 把任意语言标签（zh-Hans-CN / en-Latn-GB / ja-JP…）归一到内置 id。
   * 认不出来的一律按简体中文显示 —— 用户明确要求：跟随系统时若没有内置这几种，
   * 就展示简体中文（而不是硬塞一个机器翻译的语言）。
   */
  static match(tag: string): string {
    const s: string = tag.split('_').join('-').toUpperCase();
    if (s.indexOf('ZH') === 0) {
      if (s.indexOf('HK') >= 0 || s.indexOf('MO') >= 0) {
        return 'zh-HK';
      }
      if (s.indexOf('TW') >= 0 || s.indexOf('HANT') >= 0) {
        return 'zh-TW';
      }
      return L10n.ZH_CN;
    }
    if (s.indexOf('EN') === 0) {
      if (s.indexOf('GB') >= 0 || s.indexOf('IE') >= 0 || s.indexOf('AU') >= 0
        || s.indexOf('NZ') >= 0) {
        return 'en-GB';
      }
      return 'en-US';
    }
    if (s.indexOf('JA') === 0) {
      return 'ja-JP';
    }
    if (s.indexOf('KO') === 0) {
      return 'ko-KR';
    }
    return L10n.ZH_CN;
  }

  /** 系统语言解析成内置 id（跟随系统时用它）。 */
  static systemId(): string {
    let tag: string = '';
    try {
      tag = i18n.System.getFirstPreferredLanguage();
    } catch (err) {
      tag = '';
    }
    return L10n.match(tag);
  }

  private static cacheTick: number = -1;
  private static cacheChoice: string = L10n.SYSTEM;
  private static cacheCurrent: string = L10n.ZH_CN;

  /** 当前实际用于取词典的语言 id。缓存靠 languageTick 失效。 */
  static current(): string {
    const t: number = L10n.tick();
    const c: string = L10n.choice();
    if (t === L10n.cacheTick && c === L10n.cacheChoice) {
      return L10n.cacheCurrent;
    }
    const resolved: string = c === L10n.SYSTEM ? L10n.systemId() : c;
    L10n.cacheTick = t;
    L10n.cacheChoice = c;
    L10n.cacheCurrent = resolved;
    return resolved;
  }

  /** 词典查找链（前面的优先命中；en-GB 只登记拼写差异，其余落 EN_US）。 */
  private static chain(id: string): Map<string, string>[] {
    if (id === 'zh-HK') {
      return [ZH_HANT_MAP];
    }
    if (id === 'zh-TW') {
      return [ZH_TW_MAP, ZH_HANT_MAP];
    }
    if (id === 'en-US') {
      return [EN_US_MAP];
    }
    if (id === 'en-GB') {
      return [EN_GB_MAP, EN_US_MAP];
    }
    if (id === 'ja-JP') {
      return [JA_JP_MAP];
    }
    if (id === 'ko-KR') {
      return [KO_KR_MAP];
    }
    return [];
  }

  /** 取文案：简体直接原样返回，其它语言查词典，查不到回退简体原文。 */
  static t(src: string): string {
    if (src.length === 0) {
      return src;
    }
    const id: string = L10n.current();
    if (id === L10n.ZH_CN) {
      return src;
    }
    const maps: Map<string, string>[] = L10n.chain(id);
    for (let i = 0; i < maps.length; i++) {
      const v: string | undefined = maps[i].get(src);
      if (v !== undefined && v !== null && v.length > 0) {
        return v;
      }
    }
    return src;
  }

  /** 带一个占位符的文案（%1）。 */
  static f1(src: string, a: string): string {
    return L10n.t(src).split('%1').join(a);
  }

  /** 带两个占位符的文案（%1 %2，语序由各语言自己排）。 */
  static f2(src: string, a: string, b: string): string {
    const s: string = L10n.t(src).split('%1').join(a).split('%2').join(b);
    return s;
  }

  /** 各语言的自称（**不进词典**：语言名一律用本语言书写，与系统设置一致）。 */
  static endonym(id: string): string {
    if (id === 'zh-CN') {
      return '简体中文';
    }
    if (id === 'zh-HK') {
      return '繁體中文（香港）';
    }
    if (id === 'zh-TW') {
      return '繁體中文（台灣）';
    }
    if (id === 'en-US') {
      return 'English (US)';
    }
    if (id === 'en-GB') {
      return 'English (UK)';
    }
    if (id === 'ja-JP') {
      return '日本語';
    }
    if (id === 'ko-KR') {
      return '한국어';
    }
    return id;
  }

  /** 选择项芯片上的文案：跟随系统要翻译，其它语言显示自称。 */
  static chipLabel(id: string): string {
    return id === L10n.SYSTEM ? L10n.t('跟随系统') : L10n.endonym(id);
  }

  /** 当前语言说明行：跟随系统时把解析结果一并写出来。 */
  static describe(): string {
    if (L10n.choice() === L10n.SYSTEM) {
      return L10n.f1('跟随系统（当前：%1）', L10n.endonym(L10n.current()));
    }
    return L10n.f1('当前语言：%1', L10n.endonym(L10n.current()));
  }

  /**
   * 切换语言：写选择 + 递增刷新计数（所有挂了 langTick 的页面当帧重画），
   * 再把选择镜像给平台的 setAppPreferredLanguage，让下次冷启动时系统级资源同语言。
   */
  static setChoice(id: string): void {
    AppStorage.setOrCreate(L10n.KEY_CHOICE, id);
    AppStorage.setOrCreate(L10n.KEY_TICK, L10n.tick() + 1);
    L10n.mirrorToPlatform();
  }

  /** 把 appLanguage 映射成平台的 preferred language（跟随系统 = default）。 */
  static mirrorToPlatform(): void {
    try {
      const c: string = L10n.choice();
      i18n.System.setAppPreferredLanguage(c === L10n.SYSTEM ? 'default' : c);
    } catch (err) {
      // 平台镜像失败不影响应用内文案（词典切换是独立生效的）
    }
  }

  /**
   * 备份恢复之后调用：SettingsMirror 已经把 appLanguage 的新值写进 AppStorage，
   * 这里只补两件事——递增刷新计数让各页面重画、把新选择镜像给平台。
   * （不重启就能看到界面换语言；系统级文字仍是下次启动对齐。）
   */
  static reapply(): void {
    AppStorage.setOrCreate(L10n.KEY_TICK, L10n.tick() + 1);
    L10n.mirrorToPlatform();
  }

  /** 启动时调用：确保 tick 键存在，并把持久化的选择同步给平台。 */
  static init(): void {
    if (L10n.tick() === 0) {
      AppStorage.setOrCreate(L10n.KEY_TICK, 1);
    }
    L10n.mirrorToPlatform();
  }
}
