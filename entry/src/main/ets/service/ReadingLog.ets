/**
 * 澄笺 · 阅读日志（每篇累计时长 + 每日阅读时长）
 * ===============================================
 *
 * 与「写作日志」对称的另一半：写作日志回答"写了多少"，这里回答"读了多少"。
 *
 * 为什么要独立存储：
 *  - `DocMeta` 里有 `progressRatio`（读到百分之几）与 `mtime`，但**没有时长**——
 *    进度只能说明"读到哪"，说明不了"花了多久"；同一篇读 5 分钟和读 50 分钟
 *    在书架上都只是"已读 30%"。
 *  - 时长是**跨会话累加**的量，必须落盘，否则杀进程即清零。
 *
 * 设计取舍（与 WritingLog 保持一致，减少两套心智）：
 *  - 模块级单例 + `reading-log.json`；写盘收口在 service 层，页面只读。
 *  - 每天一条**当日累计**（当天多次阅读累加当日格），另存**每篇累计**。
 *  - 只记**真实停留**：退后台、切走页面都不计入（由页面在结算点上报片段时长，
 *    服务本身不做时间推理）。
 *  - 单篇上限 6 小时 / 单日上限 12 小时：防止"开着页面忘了关"把统计拉爆。
 *  - 最多留 400 天（与热力图同口径）。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

/** 一天的阅读记录 */
export interface ReadDay {
  /** 本地日期键，形如 '2026-10-06' */
  day: string;
  /** 当天累计阅读秒数 */
  seconds: number;
  /** 当天读过的文档篇数（去重由页面侧保证传入增量，这里只累加次数） */
  opens: number;
}

/** 单篇文档的累计阅读时长 */
export interface ReadDoc {
  /** 文档名（DocMeta.name，中文显示名） */
  name: string;
  /** 累计秒数 */
  seconds: number;
  /** 最后阅读时间戳（ms） */
  lastAt: number;
}

/** reading-log.json 的反序列化结构 */
interface ReadFile {
  days: ReadDay[];
  docs: ReadDoc[];
}

/** 区间汇总 */
export interface ReadRange {
  /** 区间内阅读秒数 */
  seconds: number;
  /** 区间内有阅读的天数 */
  activeDays: number;
}

/** 单篇上限（秒）：6 小时 */
const DOC_CAP: number = 6 * 3600;
/** 单日上限（秒）：12 小时 */
const DAY_CAP: number = 12 * 3600;

/** 本地日期键（与 WritingLog.dayKeyOf 同口径：本地时区，跨零点算新的一天）。 */
export function readDayKey(ts: number): string {
  const d: Date = new Date(ts);
  const m: number = d.getMonth() + 1;
  const day: number = d.getDate();
  return d.getFullYear() + '-' + (m < 10 ? '0' : '') + m + '-' + (day < 10 ? '0' : '') + day;
}

export class ReadingLog {
  private static days: ReadDay[] = [];
  private static docs: ReadDoc[] = [];
  private static path: string = '';
  private static ready: boolean = false;
  /** 保留天数（与热力图 53 周口径一致） */
  private static readonly KEEP: number = 400;

  /**
   * 从磁盘重新载入（备份恢复之后调用）。
   * days / docs 是内存缓存且有 ready 门闩：不重载的话，下一次 add()→persist()
   * 会把**恢复前的**阅读时长记录写回 reading-log.json，把刚导入的盖掉。
   */
  static reload(ctx: common.UIAbilityContext): void {
    ReadingLog.ready = false;
    ReadingLog.init(ctx);
  }

  /** 必须在其它方法之前调用；重复调用安全。 */
  static init(ctx: common.UIAbilityContext): void {
    if (ReadingLog.ready) {
      return;
    }
    ReadingLog.path = ctx.filesDir + '/reading-log.json';
    try {
      if (fs.accessSync(ReadingLog.path)) {
        const text: string = fs.readTextSync(ReadingLog.path, { encoding: 'utf-8' });
        if (text.length > 0) {
          const parsed: ReadFile = JSON.parse(text) as ReadFile;
          if (parsed !== null && parsed !== undefined) {
            if (Array.isArray(parsed.days)) {
              const rawDays: ReadDay[] = parsed.days;
              for (let i = 0; i < rawDays.length; i++) {
                const r: ReadDay = rawDays[i];
                if (r === null || r === undefined) {
                  continue;
                }
                const dk: string = typeof r.day === 'string' ? r.day : '';
                if (dk.length < 8) {
                  continue;
                }
                const sec: number = typeof r.seconds === 'number' && isFinite(r.seconds) ? r.seconds : 0;
                const op: number = typeof r.opens === 'number' && isFinite(r.opens) ? r.opens : 0;
                ReadingLog.days.push({ day: dk, seconds: sec, opens: op } as ReadDay);
              }
            }
            if (Array.isArray(parsed.docs)) {
              const rawDocs: ReadDoc[] = parsed.docs;
              for (let i = 0; i < rawDocs.length; i++) {
                const r: ReadDoc = rawDocs[i];
                if (r === null || r === undefined) {
                  continue;
                }
                const nm: string = typeof r.name === 'string' ? r.name : '';
                if (nm.length === 0) {
                  continue;
                }
                const sec: number = typeof r.seconds === 'number' && isFinite(r.seconds) ? r.seconds : 0;
                const at: number = typeof r.lastAt === 'number' && isFinite(r.lastAt) ? r.lastAt : 0;
                ReadingLog.docs.push({ name: nm, seconds: sec, lastAt: at } as ReadDoc);
              }
            }
          }
        }
      }
    } catch (err) {
      // 文件损坏按无历史处理
      ReadingLog.days = [];
      ReadingLog.docs = [];
    }
    ReadingLog.sort();
    ReadingLog.trim();
    ReadingLog.ready = true;
  }

  /**
   * 上报一段阅读时长（页面在离开 / 退后台时结算后调用）。
   *
   * 参数语义：`seconds` 是**这一段**的时长，服务负责累加到当日与当篇。
   * 极端值（负数 / 超过单日上限）直接丢弃——页面异常时不应该污染统计。
   */
  static add(ctx: common.UIAbilityContext, docName: string, seconds: number): void {
    ReadingLog.init(ctx);
    if (seconds <= 0 || seconds > DAY_CAP || docName.length === 0) {
      return;
    }
    const sec: number = Math.round(seconds);
    const key: string = readDayKey(Date.now());
    let hitDay: boolean = false;
    for (let k = 0; k < ReadingLog.days.length; k++) {
      if (ReadingLog.days[k].day === key) {
        const sum: number = ReadingLog.days[k].seconds + sec;
        ReadingLog.days[k].seconds = sum > DAY_CAP ? DAY_CAP : sum;
        ReadingLog.days[k].opens = ReadingLog.days[k].opens + 1;
        hitDay = true;
        break;
      }
    }
    if (!hitDay) {
      ReadingLog.days.push({ day: key, seconds: sec, opens: 1 } as ReadDay);
    }
    let hitDoc: boolean = false;
    for (let k = 0; k < ReadingLog.docs.length; k++) {
      if (ReadingLog.docs[k].name === docName) {
        const sum: number = ReadingLog.docs[k].seconds + sec;
        ReadingLog.docs[k].seconds = sum > DOC_CAP ? DOC_CAP : sum;
        ReadingLog.docs[k].lastAt = Date.now();
        hitDoc = true;
        break;
      }
    }
    if (!hitDoc) {
      ReadingLog.docs.push({ name: docName, seconds: sec, lastAt: Date.now() } as ReadDoc);
    }
    ReadingLog.sort();
    ReadingLog.trim();
    ReadingLog.persist();
  }

  /** 某天的阅读秒数（无记录返回 0）。 */
  static secondsOn(day: string): number {
    for (let k = 0; k < ReadingLog.days.length; k++) {
      if (ReadingLog.days[k].day === day) {
        return ReadingLog.days[k].seconds;
      }
    }
    return 0;
  }

  /** 某篇文档的累计阅读秒数。 */
  static docSeconds(ctx: common.UIAbilityContext, name: string): number {
    ReadingLog.init(ctx);
    for (let k = 0; k < ReadingLog.docs.length; k++) {
      if (ReadingLog.docs[k].name === name) {
        return ReadingLog.docs[k].seconds;
      }
    }
    return 0;
  }

  /** 最近 n 天的汇总（含今天）。 */
  static lastDays(ctx: common.UIAbilityContext, n: number): ReadRange {
    ReadingLog.init(ctx);
    if (n <= 0) {
      return { seconds: 0, activeDays: 0 } as ReadRange;
    }
    const fromKey: string = readDayKey(Date.now() - (n - 1) * 86400000);
    let seconds: number = 0;
    let active: number = 0;
    for (let k = 0; k < ReadingLog.days.length; k++) {
      const r: ReadDay = ReadingLog.days[k];
      if (r.day < fromKey) {
        continue;
      }
      seconds += r.seconds;
      if (r.seconds > 0) {
        active++;
      }
    }
    return { seconds: seconds, activeDays: active } as ReadRange;
  }

  /** 累计总秒数（全部历史）。 */
  static totalSeconds(ctx: common.UIAbilityContext): number {
    ReadingLog.init(ctx);
    let sum: number = 0;
    for (let k = 0; k < ReadingLog.days.length; k++) {
      sum += ReadingLog.days[k].seconds;
    }
    return sum;
  }

  /** 读得最多的前 n 篇（按时长降序；并列时最近读过的在前）。 */
  static topDocs(ctx: common.UIAbilityContext, n: number): ReadDoc[] {
    ReadingLog.init(ctx);
    const all: ReadDoc[] = [];
    for (let k = 0; k < ReadingLog.docs.length; k++) {
      const r: ReadDoc = ReadingLog.docs[k];
      all.push({ name: r.name, seconds: r.seconds, lastAt: r.lastAt } as ReadDoc);
    }
    all.sort((a: ReadDoc, b: ReadDoc): number => {
      if (a.seconds !== b.seconds) {
        return b.seconds - a.seconds;
      }
      return b.lastAt - a.lastAt;
    });
    const take: number = n > 0 ? n : 0;
    return take >= all.length ? all : all.slice(0, take);
  }

  /** 时长的人类可读文案：不足 1 分钟按秒，1 小时以上按时分。 */
  static human(seconds: number): string {
    const s: number = seconds > 0 ? Math.round(seconds) : 0;
    if (s < 60) {
      return s + ' 秒';
    }
    const min: number = Math.floor(s / 60);
    if (min < 60) {
      return min + ' 分钟';
    }
    const h: number = Math.floor(min / 60);
    const rest: number = min % 60;
    return rest > 0 ? h + ' 小时 ' + rest + ' 分' : h + ' 小时';
  }

  private static sort(): void {
    ReadingLog.days.sort((a: ReadDay, b: ReadDay): number => (a.day < b.day ? -1 : (a.day > b.day ? 1 : 0)));
    ReadingLog.docs.sort((a: ReadDoc, b: ReadDoc): number => b.seconds - a.seconds);
  }

  private static trim(): void {
    if (ReadingLog.days.length > ReadingLog.KEEP) {
      ReadingLog.days = ReadingLog.days.slice(ReadingLog.days.length - ReadingLog.KEEP);
    }
    // 只留前 200 篇：统计页展示 top5 足够，全部留着会让文件无意义地变大
    if (ReadingLog.docs.length > 200) {
      ReadingLog.docs = ReadingLog.docs.slice(0, 200);
    }
  }

  private static persist(): void {
    try {
      const data: ReadFile = { days: ReadingLog.days, docs: ReadingLog.docs } as ReadFile;
      const text: string = JSON.stringify(data);
      const file: fs.File = fs.openSync(ReadingLog.path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, text);
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
    } catch (err) {
      // 落盘失败只影响统计，不影响阅读
    }
  }
}
