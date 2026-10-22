import { common } from '@kit.AbilityKit';
import { FontStore, SystemFont, UserFont } from './FontStore';

/**
 * 澄笺 · 字体选择数据缓存（FontPickCache）
 * ======================================
 *
 * 用户要求（2026-10-22）：「点字体选择按钮 → 先弹提醒 → **加载完再展开**列表；
 * 2 分钟内再次打开不要再加载一次」。
 *
 * 因此把「导入字体 + 系统字体」两份数据集中在这里缓存：
 *  · `fresh()` 同步判断是否还在有效期内（宿主据此决定弹不弹提醒、要不要等）；
 *  · `ensure()` 冷启动时真正去扫（`FontStore` 里已有内存 / 磁盘索引两级缓存）；
 *  · 并发合流：两个入口（中文字体 / 英数字体）同时点，只扫一次，共用同一个 Promise。
 *
 * TTL 取 2 分钟：系统字体表在用户装/删字体前不会变，2 分钟足以覆盖「连续挑几款看看」的场景，
 * 又不会让列表在真的换了字体之后长期停在旧数据上（超时后自然重扫一次）。
 */
export interface FontPickData {
  /** 用户导入进沙箱的字体 */
  user: UserFont[];
  /** 系统字体表（含各样式） */
  sys: SystemFont[];
}

export class FontPickCache {
  /** 缓存有效期：2 分钟 */
  private static readonly TTL: number = 2 * 60 * 1000;
  private static at: number = 0;
  private static data: FontPickData | null = null;
  /** 正在加载的那一次（并发合流用） */
  private static inflight: Promise<FontPickData> | null = null;

  /** 缓存是否仍在有效期内（同步；宿主点击时先问这个） */
  static fresh(): boolean {
    if (FontPickCache.data === null) {
      return false;
    }
    return (Date.now() - FontPickCache.at) < FontPickCache.TTL;
  }

  /** 取缓存（无效返回 null） */
  static peek(): FontPickData | null {
    return FontPickCache.fresh() ? FontPickCache.data : null;
  }

  /** 保证有一份数据：命中直接返回，否则真正加载（并发时共用同一次） */
  static ensure(ctx: common.UIAbilityContext | undefined): Promise<FontPickData> {
    const hit: FontPickData | null = FontPickCache.peek();
    if (hit !== null) {
      return Promise.resolve(hit);
    }
    const running: Promise<FontPickData> | null = FontPickCache.inflight;
    if (running !== null) {
      return running;
    }
    const job: Promise<FontPickData> = FontPickCache.load(ctx);
    FontPickCache.inflight = job;
    job.then((d: FontPickData) => {
      FontPickCache.data = d;
      FontPickCache.at = Date.now();
      FontPickCache.inflight = null;
    }).catch(() => {
      // 失败不写缓存：下次点击会重新尝试
      FontPickCache.inflight = null;
    });
    return job;
  }

  /** 导入 / 删除字体、强制重扫之后调用 */
  static invalidate(): void {
    FontPickCache.data = null;
    FontPickCache.at = 0;
    FontPickCache.inflight = null;
  }

  /** 真正取数据：先出导入字体（同步清单），再取系统字体表（异步） */
  private static async load(ctx: common.UIAbilityContext | undefined): Promise<FontPickData> {
    let user: UserFont[] = [];
    if (ctx !== undefined && ctx !== null) {
      FontStore.registerAll(ctx);
      user = FontStore.list(ctx);
    }
    const sys: SystemFont[] = await FontStore.loadInstalled();
    return { user: user, sys: sys };
  }
}
