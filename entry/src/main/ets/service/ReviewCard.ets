/**
 * 复习卡片（ReviewCard）—— 把批注变成可复习的卡片，并按间隔重复排期。
 *
 * 定位：批注汇总让"看得见"，这一层解决"记得住"。卡片**由批注派生**（高亮文本当正面，
 * 文字批注当背面），在此外挂一套 SM-2 简化排期参数。
 *
 * 两个刻意的设计决定：
 * 1. **排期数据独立存储**（沙箱 `review.json`），不写进批注本体 —— 批注是用户内容，
 *    复习进度是应用状态，两者生命周期不同；混在一起会导致"同步批注时把复习进度冲掉"。
 * 2. **卡片与批注按 id 对齐**：`id = 文档名|批注id`。同步时**只增删、不动已有进度**，
 *    这样用户改批注内容不会让复习计划归零。
 */
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';

/** 一张复习卡片 */
export interface ReviewCard {
  /** `文档名|批注id`（稳定标识） */
  id: string;
  docName: string;
  /** 正面：高亮文本 */
  front: string;
  /** 背面：文字批注（可能为空） */
  back: string;
  /** 复习间隔（天） */
  interval: number;
  /** 难度系数（SM-2 的 EF，下限 1.3） */
  ease: number;
  /** 下次到期时间（ms） */
  due: number;
  /** 已复习次数 */
  reps: number;
  /** 上次复习时间（ms），0 = 从未复习 */
  lastReview: number;
  /**
   * 连续「记得」次数（1.1.0 复习逻辑：会话内累计选满 3 次「记得」才算掌握，
   * 中途忘了 / 模糊即清零重数）。旧存档没有该字段 → undefined，按 0 处理。
   */
  streak?: number;
}

/** 复习统计 */
export interface ReviewStats {
  total: number;
  /** 今日到期（含逾期） */
  due: number;
  /** 已复习过至少一次 */
  learned: number;
}

/** 一天（ms） */
const DAY: number = 24 * 60 * 60 * 1000;
/** ease 下限（SM-2 规定不低于 1.3） */
const MIN_EASE: number = 1.3;

export class ReviewCardStore {
  private static pathOf(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/review.json';
  }

  /** 读取全部卡片（文件缺失 / 损坏 → 返回空数组，不抛错）。 */
  static load(ctx: common.UIAbilityContext): ReviewCard[] {
    const path: string = ReviewCardStore.pathOf(ctx);
    try {
      const text: string = fs.readTextSync(path);
      if (text.length === 0) {
        return [];
      }
      const raw: ReviewCard[] = JSON.parse(text) as ReviewCard[];
      return raw === null || raw === undefined ? [] : raw;
    } catch (err) {
      // 文件不存在或内容损坏都走这里：静默返回空，下次 sync 会重建
      return [];
    }
  }

  /** 写盘（失败静默 —— 复习进度丢失不应影响主流程）。 */
  static save(ctx: common.UIAbilityContext, cards: ReviewCard[]): void {
    const path: string = ReviewCardStore.pathOf(ctx);
    try {
      const text: string = JSON.stringify(cards);
      const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, text);
      fs.closeSync(f);
    } catch (err) {
      // 忽略：下次复习会重新生成
    }
  }

  /**
   * 由批注同步卡片：新增缺失的卡片、删除已不存在的卡片，**保留已有卡片的排期进度**。
   * @param items 形如 [{docName, annId, front, back}] 的批注快照
   */
  static sync(ctx: common.UIAbilityContext, items: ReviewSeed[]): ReviewCard[] {
    const old: ReviewCard[] = ReviewCardStore.load(ctx);
    const out: ReviewCard[] = [];
    const now: number = Date.now();
    for (let k = 0; k < items.length; k++) {
      const seed: ReviewSeed = items[k];
      const id: string = seed.docName + '|' + seed.annId;
      let exist: ReviewCard | null = null;
      for (let j = 0; j < old.length; j++) {
        if (old[j].id === id) {
          exist = old[j];
          break;
        }
      }
      if (exist !== null) {
        // 保留进度，只同步内容（用户改了批注文字，进度不清零）
        exist.front = seed.front;
        exist.back = seed.back;
        out.push(exist);
      } else {
        out.push({
          id: id, docName: seed.docName, front: seed.front, back: seed.back,
          interval: 0, ease: 2.5, due: now, reps: 0, lastReview: 0
        } as ReviewCard);
      }
    }
    ReviewCardStore.save(ctx, out);
    return out;
  }

  /**
   * 评分并推进排期（SM-2 简化版）。
   * @param grade 0 = 忘了（重来）· 1 = 模糊（小幅推进）· 2 = 记得（按 EF 推进）
   */
  static grade(card: ReviewCard, grade: number): ReviewCard {
    const now: number = Date.now();
    if (grade <= 0) {
      // 忘了：明天再来，难度上调
      card.reps = 0;
      card.interval = 1;
      card.ease = Math.max(MIN_EASE, card.ease - 0.2);
    } else if (grade === 1) {
      // 模糊：间隔小幅增长（不乘 EF，避免"半懂"被推进太远）
      card.reps = card.reps + 1;
      card.interval = Math.max(1, Math.round(card.interval * 1.2));
      card.ease = Math.max(MIN_EASE, card.ease - 0.15);
    } else {
      // 记得：首次 1 天、第二次 3 天，之后按 EF 递增（SM-2 的标准推进）
      card.reps = card.reps + 1;
      if (card.reps === 1) {
        card.interval = 1;
      } else if (card.reps === 2) {
        card.interval = 3;
      } else {
        card.interval = Math.max(1, Math.round(card.interval * card.ease));
      }
      card.ease = Math.min(2.8, card.ease + 0.1);
    }
    card.lastReview = now;
    card.due = now + card.interval * DAY;
    return card;
  }

  /** 今日应复习的卡片（含逾期），按到期时间升序。 */
  static dueToday(cards: ReviewCard[]): ReviewCard[] {
    const now: number = Date.now();
    const out: ReviewCard[] = [];
    for (let k = 0; k < cards.length; k++) {
      if (cards[k].due <= now) {
        out.push(cards[k]);
      }
    }
    out.sort((a: ReviewCard, b: ReviewCard) => a.due - b.due);
    return out;
  }

  /** 统计信息。 */
  static stats(cards: ReviewCard[]): ReviewStats {
    const now: number = Date.now();
    let due: number = 0;
    let learned: number = 0;
    for (let k = 0; k < cards.length; k++) {
      if (cards[k].due <= now) {
        due++;
      }
      if (cards[k].reps > 0) {
        learned++;
      }
    }
    return { total: cards.length, due: due, learned: learned } as ReviewStats;
  }

  /** 摘要文案。 */
  static summary(s: ReviewStats): string {
    if (s.total === 0) {
      return '还没有复习卡片（先用荧光笔或批注标记几处内容）';
    }
    if (s.due === 0) {
      return '共 ' + s.total + ' 张卡片 · 今天没有到期，已掌握 ' + s.learned + ' 张';
    }
    return '共 ' + s.total + ' 张卡片 · **今天到期 ' + s.due + ' 张**';
  }
}

/** 同步用的批注快照（避免 service 反向依赖 markdown 层） */
export interface ReviewSeed {
  docName: string;
  annId: string;
  front: string;
  back: string;
}
