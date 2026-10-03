/**
 * 澄笺 · 写作日志（每日快照）
 * =======================
 *
 * 记录「每天写了多少字、动了多少篇」，供设置里的写作日志页做统计与热力图。
 *
 * 为什么需要独立存储：
 *  - `DocMeta` 只有 `mtime`（最后修改时间）与当前 `wordCount`，
 *    **没有"某天写了多少"的历史**——mtime 只能反映最后一次改哪天，
 *    一篇文档改 10 天会只留下 1 个痕迹，做不出热力图。
 *  - 所以每次写盘（`DocStore.update` / `create`）都往这里落一条**当日快照**，
 *    数值取「当天所有自建文档的累计字数」与「当天编辑过的文档数」，
 *    存成按日期索引的定长记录；统计区间直接对日期求和 / 取最后一条。
 *
 * 设计取舍：
 *  - 模块级单例 + `writing-log.json` 落盘（同 TabStore 范式）：
 *    写盘收口在 service 层，页面只读；跨会话保留，热力图才有历史。
 *  - 记录**累计值**而非增量：应用被杀 / 跨天多次保存都不会算错，
 *    代价是同一天重复保存会覆盖同一条（这正是我们要的——一天一格）。
 *  - 只统计**自建文档**：内置教程是预置内容，不算用户的写作产出。
 *  - 最多留 400 天（热力图展示 53 周 ≈ 371 天，留一点余量），超出丢弃最旧的。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

/** 一天的快照 */
export interface DayRecord {
  /** 本地日期键，形如 '2026-10-02'（不用时间戳，避免时区跨日） */
  day: string;
  /** 当天结束时，自建文档的累计字数 */
  words: number;
  /** 当天编辑过的自建文档数（同一天多次编辑同一篇只算一篇） */
  docs: number;
}

/** writing-log.json 的反序列化结构 */
interface LogFile {
  days: DayRecord[];
}

/** 区间汇总结果 */
export interface LogRange {
  /** 区间内累计字数 */
  words: number;
  /** 区间内"动过"的文档数（同一天多篇算多篇，跨天去重后累加） */
  docs: number;
  /** 区间内有写作的天数 */
  activeDays: number;
}

/** 本地日期键。用本地时区，跨零点算新的一天。 */
export function dayKeyOf(ts: number): string {
  const d: Date = new Date(ts);
  const m: number = d.getMonth() + 1;
  const day: number = d.getDate();
  return d.getFullYear() + '-' + (m < 10 ? '0' : '') + m + '-' + (day < 10 ? '0' : '') + day;
}

export class WritingLog {
  private static days: DayRecord[] = [];
  private static path: string = '';
  private static ready: boolean = false;
  /** 只保留的最近天数：热力图 53 周 = 371 天，留 29 天余量 */
  private static readonly KEEP: number = 400;

  /** 必须在任何其它方法之前调用；重复调用安全。 */
  static init(ctx: common.UIAbilityContext): void {
    if (WritingLog.ready) {
      return;
    }
    WritingLog.path = ctx.filesDir + '/writing-log.json';
    try {
      if (fs.accessSync(WritingLog.path)) {
        const text: string = fs.readTextSync(WritingLog.path, { encoding: 'utf-8' });
        if (text.length > 0) {
          // ArkTS 的 JSON.parse 返回的是 untyped，**必须先落到松散类型再逐字段收窄**，
          // 直接当 LogFile 用会在取字段时抛异常。
          const parsed: LogFile = JSON.parse(text) as LogFile;
          if (parsed !== null && parsed !== undefined && Array.isArray(parsed.days)) {
            const raw: DayRecord[] = parsed.days;
            // 索引循环而非 for...of：ArkTS 对迭代协议支持有限，索引最稳
            for (let i = 0; i < raw.length; i++) {
              const rec: DayRecord = raw[i];
              if (rec === null || rec === undefined) {
                continue;
              }
              // 逐条校验：文件损坏 / 手工改过时不至于让整份记录报废
              const dk: string = typeof rec.day === 'string' ? rec.day : '';
              if (dk.length < 8) {
                continue;
              }
              const w: number = typeof rec.words === 'number' && isFinite(rec.words) ? rec.words : 0;
              const dc: number = typeof rec.docs === 'number' && isFinite(rec.docs) ? rec.docs : 0;
              WritingLog.days.push({ day: dk, words: w, docs: dc } as DayRecord);
            }
          }
        }
      }
    } catch (err) {
      // 文件损坏按无历史处理，不影响其它功能
      WritingLog.days = [];
    }
    WritingLog.trim();
    WritingLog.ready = true;
  }

  /**
   * 记一条当日快照（写盘时调用）。
   * 同一天重复调用 = 覆盖当天那条（累计值语义，不累加）。
   */
  static record(ctx: common.UIAbilityContext, totalWords: number, docsTouched: number): void {
    WritingLog.init(ctx);
    const key: string = dayKeyOf(Date.now());
    const words: number = totalWords > 0 ? Math.round(totalWords) : 0;
    const docs: number = docsTouched > 0 ? docsTouched : 0;
    let found: boolean = false;
    for (let k = 0; k < WritingLog.days.length; k++) {
      if (WritingLog.days[k].day === key) {
        // **取较大值**：中途统计可能比最终值小（删了字），别让热力图倒退
        WritingLog.days[k].words = words > WritingLog.days[k].words ? words : WritingLog.days[k].words;
        WritingLog.days[k].docs = docs > WritingLog.days[k].docs ? docs : WritingLog.days[k].docs;
        found = true;
        break;
      }
    }
    if (!found) {
      WritingLog.days.push({ day: key, words: words, docs: docs } as DayRecord);
    }
    // 按日期升序（补录旧日期时也保持有序，汇总与热力图都依赖顺序）
    WritingLog.days.sort((a: DayRecord, b: DayRecord): number => (a.day < b.day ? -1 : (a.day > b.day ? 1 : 0)));
    WritingLog.trim();
    WritingLog.persist();
  }

  /** 全部快照（副本语义），按日期升序。 */
  static list(): DayRecord[] {
    const out: DayRecord[] = [];
    for (let k = 0; k < WritingLog.days.length; k++) {
      const r: DayRecord = WritingLog.days[k];
      out.push({ day: r.day, words: r.words, docs: r.docs } as DayRecord);
    }
    return out;
  }

  /** 某天的字数（无记录返回 0）。热力图逐格取色用。 */
  static wordsOn(day: string): number {
    for (let k = 0; k < WritingLog.days.length; k++) {
      if (WritingLog.days[k].day === day) {
        return WritingLog.days[k].words;
      }
    }
    return 0;
  }

  /**
   * 统计"最近 N 天"的汇总。
   *
   * 字数取**每天累计值的增量**：单日增量 = 今天的累计 − 前一天的累计
   * （第一天的前一日视为 0）。这样得到的是"当天实际写了多少"，
   * 而不是"当前总字数被重复计入 N 次"。
   * 篇数同理（每天动过的篇数去重累加）。
   */
  static lastDays(ctx: common.UIAbilityContext, n: number): LogRange {
    WritingLog.init(ctx);
    if (n <= 0) {
      return { words: 0, docs: 0, activeDays: 0 } as LogRange;
    }
    const now: number = Date.now();
    const fromKey: string = dayKeyOf(now - (n - 1) * 86400000);
    // 找基准：区间起始日的前一条记录，用它的累计值算首日增量
    let base: number = 0;
    let baseIdx: number = -1;
    for (let k = 0; k < WritingLog.days.length; k++) {
      if (WritingLog.days[k].day < fromKey) {
        base = WritingLog.days[k].words;
        baseIdx = k;
      } else {
        break;
      }
    }
    let words: number = 0;
    let docs: number = 0;
    let active: number = 0;
    let prev: number = base;
    for (let k = baseIdx + 1; k < WritingLog.days.length; k++) {
      const r: DayRecord = WritingLog.days[k];
      const delta: number = r.words - prev;
      // 增量为负（删字）时按 0 记，热力图只看"写了多少"
      words += delta > 0 ? delta : 0;
      docs += r.docs > 0 ? r.docs : 0;
      if (delta > 0) {
        active++;
      }
      prev = r.words;
    }
    return { words: words, docs: docs, activeDays: active } as LogRange;
  }

  /** 丢弃超出保留期的最旧记录。 */
  private static trim(): void {
    if (WritingLog.days.length <= WritingLog.KEEP) {
      return;
    }
    WritingLog.days = WritingLog.days.slice(WritingLog.days.length - WritingLog.KEEP);
  }

  private static persist(): void {
    try {
      const file: LogFile = { days: WritingLog.days };
      const f: fs.File = fs.openSync(WritingLog.path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, JSON.stringify(file));
      } finally {
        try {
          fs.closeSync(f);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
    } catch (err) {
      // 落盘失败只丢热力图历史，不影响写作
    }
  }
}
