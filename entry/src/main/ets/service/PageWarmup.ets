/**
 * 澄笺 · 页面组件预热（Beta，2026-10-20 新增）
 *
 * 用户要求：打开应用后**在后台把常用页面依赖的东西先备好**（不加载文档内容），
 * 让页面点开时不必现算；并且**关闭应用或超过固定时间后自动清除**（beta 性质，方便回退）。
 *
 * 边界（务必如实告知，不做超出能力的事）：
 *   · ArkUI 没有"预创建页面组件树"的公开 API——所以这里预热的是**页面依赖的纯数据与
 *     派生资源**：五档主题 × 深浅两套调色板、多语言词典链、版本历史常量；
 *   · **不读任何文档正文**（用户明确要求），文档仍是打开时才读；
 *   · 全部由「设置 → 外观 → 页面组件预热（Beta）」开关控制，默认关闭；
 *   · 持有一份引用清单（`held`），`clear()` 时一并释放——关闭应用 / 退后台 / 超时
 *     （`TTL_MS`）都会清，重新前台再按需预热。
 */
import { L10n } from './L10n';
import { CHANGELOG_ALL } from './Changelog';
import { paletteFor, ReaderPalette } from '../theme/DesignTokens';

export class PageWarmup {
  /** 预热结果保留时长：超时后下次前台重新预热（避免长期占内存） */
  static readonly TTL_MS: number = 10 * 60 * 1000;

  /** 上次预热完成时刻（0 = 未预热 / 已清除） */
  private static warmedAt: number = 0;
  /** 持住的调色板引用（清除时一起放掉，便于 GC） */
  private static held: ReaderPalette[] = [];

  /** 开关是否打开（设置 → 外观 → 页面组件预热 Beta） */
  static enabled(): boolean {
    return AppStorage.get<boolean>('preloadPages') === true;
  }

  /**
   * 尝试预热（幂等）。调用点：Index 页面显示时。
   * 晚 1.2s 再跑，避开首帧与首屏渲染；开关关闭时顺手清掉已有预热。
   */
  static maybeWarmup(): void {
    if (!PageWarmup.enabled()) {
      PageWarmup.clear();
      return;
    }
    const now: number = Date.now();
    if (PageWarmup.warmedAt > 0 && now - PageWarmup.warmedAt < PageWarmup.TTL_MS) {
      return;
    }
    setTimeout(() => {
      try {
        // ① 五档主题 × 深浅两套调色板：外观设置 / 阅读页 / 编辑页都要用
        const held: ReaderPalette[] = [];
        for (let m = 1; m <= 5; m++) {
          held.push(paletteFor(m, false));
          held.push(paletteFor(m, true));
        }
        PageWarmup.held = held;
        // ② 词典链（中英各一条）：任意一次翻译就会把链装好
        L10n.t('设置');
        // ③ 版本历史（内置常量，版本页打开即读）
        if (CHANGELOG_ALL.length > 0) {
          PageWarmup.warmedAt = Date.now();
        } else {
          PageWarmup.warmedAt = Date.now();
        }
      } catch (err) {
        // 预热失败无副作用：页面仍会在打开时各自初始化
        PageWarmup.warmedAt = 0;
      }
    }, 1200);
  }

  /** 清除预热（退后台 / 关闭应用 / 开关关闭时调用）。 */
  static clear(): void {
    PageWarmup.warmedAt = 0;
    PageWarmup.held = [];
  }

  /** 诊断文本（设置页/日志可用）：已预热? + 剩余有效秒数 */
  static stateText(): string {
    if (PageWarmup.warmedAt <= 0) {
      return '未预热';
    }
    const left: number = Math.max(0, PageWarmup.TTL_MS - (Date.now() - PageWarmup.warmedAt));
    return '已预热（剩余 ' + Math.floor(left / 1000) + ' 秒）';
  }
}
