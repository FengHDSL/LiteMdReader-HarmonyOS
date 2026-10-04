/**
 * 澄笺 · 设置 · 写作日志
 * ====================
 *
 * 写作记录页：总览统计 / 热力图（近半年）/ 最新文档（封面墙）。
 *
 * 数据来源：
 *  - service/WritingLog.ets 的每日快照（写盘时落的累计值）。
 *    区间字数一律按「每日累计值求差」还原成实际写入量——
 *    直接拿累计值求和会把当前总字数重复计入 N 次。
 *  - 书架总量 / 最新文档走 DocStore，只数自建文档。
 *
 * 版式约定（用户要求）：
 *  - 卡片与其他设置页同款（HwRadius.sheet 圆角、无材质阴影、通栏宽）；
 *  - 热力图**不追求一整年**：近 26 周（半年），格子宽度翻倍更易读；
 *  - GitHub 风格结构：年度（半年）总结行 + 月份对齐列 + 左侧星期 + 图例 + 点击看详情。
 *
 * ⚠️ ArkUI 白屏四坑（本页全部规避，见 MEMORY.md）：
 *   ① ForEach 第一参数必须真数组（HEAT_ROWS / HEAT_COLS）；
 *   ② 不用 Set/Map/for...of（线性查找）；
 *   ③ @Builder 内不跨分支返回异构结构；
 *   ④ ForEach 的 itemGenerator 里不调 @Builder（柱子/格子全部内联画）。
 */
import { NavLifecycle } from '../service/NavLifecycle';
import { common } from '@kit.AbilityKit';
import { SettingsShell } from './SettingsShell';
import { ImmersiveCard, ImmersiveChip } from '../material/ImmersiveCard';
import { DocCover, coverColorsOf, coverStyleFromColor } from '../components/DocCover';
import { DocMeta, DocStore } from '../service/DocStore';
import { DayRecord, LogRange, WritingLog, dayKeyOf } from '../service/WritingLog';
import {
  CoverStyle,
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  isDarkTheme,
  paletteFor,
  withAlpha
} from '../theme/DesignTokens';

/** 热力图列数（周）：GitHub 同款一整年 53 周，横向滑动查看 */
const HEAT_WEEKS: number = 53;
/** 热力图行列驱动数组（ForEach 必须真数组，见文件头） */
const HEAT_ROWS: number[] = [0, 1, 2, 3, 4, 5, 6];
const HEAT_COLS: number[] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
  13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
  26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
  40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52
];
/** 热力图格子固定边长（不随屏宽均分 —— 一年 53 列靠横向滑动看完） */
const HEAT_CELL: number = 12;
/** 热力图格子间距 */
const HEAT_GAP: number = 2;
/** 热力图图例的透明度梯度（与 heatColor 的分档一致，首格 = 没写的底格） */
const HEAT_LEGEND: string[] = ['1F', '40', '66', '8C', 'B3', 'E0'];
/** 「最新文档」封面墙最多展示几本 */
const LATEST_MAX: number = 8;
/** 年份选择可选几年（写作日志数据保留 400 天 ≈ 13 个月，两年足够） */
const YEAR_OPTIONS: number = 2;

/** 热力图月份标注（GitHub 风格：标在该月第一天所在列上方） */
interface MonthMark {
  /** 如 '10月' */
  label: string;
  /** 起始列（0..25） */
  col: number;
}

/** 最新文档时间线的一条 */
interface LatestDoc {
  name: string;
  fileName: string;
  builtin: boolean;
  coverColor: string;
  coverImage: string;
  hideName: boolean;
  /** 修改日期 '10-02' */
  date: string;
  /** 所属月份键 '2026-10' */
  monthKey: string;
  /** 月份标签 '2026 年 10 月' */
  monthLabel: string;
  words: number;
}

/** 时间线的一个月份分组 */
interface LatestGroup {
  /** 月份键 '2026-10' */
  monthKey: string;
  /** 分隔行标签 '2026 年 10 月' */
  monthLabel: string;
  /** 组内最大字数（比例条归一化用） */
  maxWords: number;
  docs: LatestDoc[];
}

/** 某一年的写作统计 */
interface YearStats {
  words: number;
  activeDays: number;
}

@Component
export struct SettingsWriting {
  stack: NavPathStack | null = null;
  life: NavLifecycle = new NavLifecycle();

  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  /** 本页实测宽度（热力图格子尺寸按可用宽度算） */
  /** 书架总量（自建） */
  @State totalDocs: number = 0;
  @State totalWords: number = 0;
  /** 今日 / 本月实际写入 */
  @State todayWords: number = 0;
  @State monthWords: number = 0;
  /** 热力图数据（按天升序） */
  @State days: DayRecord[] = [];
  /** 数据加载失败的可见错误（大屏排障用：不再静默吞掉，空白时能看到原因） */
  @State loadError: string = '';
  /** 热力图当前查看的年份（GitHub 右侧年份列表的同功能） */
  @State viewYear: number = new Date().getFullYear();
  /** 热力图横向滚动控制器：进页面 / 切年份后自动滚到"今天"所在列（GitHub 同款） */
  private heatScroller: Scroller = new Scroller();
  /** 最新文档（封面墙） */
  @State latestDocs: LatestDoc[] = [];

  aboutToAppear(): void {
    this.life.onShow = () => {
      this.reload();
    };
    this.reload();
  }

  private ctx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  private reload(): void {
    const c = this.ctx();
    if (c === null) {
      return;
    }
    // 全程 try/catch：统计挂了也不能白屏；**错误写进 loadError 显示出来**（排障）
    try {
      WritingLog.init(c);
      this.days = WritingLog.list();
      this.loadShelfTotals(c);
      this.calcToday();
      this.calcMonth();
      this.calcLatestDocs(c);
      this.loadError = '';
      // 热力图默认滚到"最新有数据"的列：内容要等一帧布局完成，延迟触发
      setTimeout(() => {
        this.scrollHeatToLatest();
      }, 120);
    } catch (err) {
      this.days = [];
      this.latestDocs = [];
      this.totalDocs = 0;
      this.totalWords = 0;
      this.todayWords = 0;
      this.monthWords = 0;
      const e = err as BusinessError;
      this.loadError = '数据加载失败：' + (e.message && e.message.length > 0
        ? e.message : (e.code !== undefined ? 'code ' + e.code : '未知错误'));
    }
  }

  /** 书架总量：只数自建文档（内置教程是预置内容，不算产出）。 */
  private loadShelfTotals(c: common.UIAbilityContext): void {
    const list: DocMeta[] = DocStore.list(c);
    let n: number = 0;
    let w: number = 0;
    for (let k = 0; k < list.length; k++) {
      if (list[k].builtin) {
        continue;
      }
      n++;
      w += list[k].wordCount;
    }
    this.totalDocs = n;
    this.totalWords = w;
  }

  /**
   * 今日实际写入 = 今天累计 − 前一条记录的累计。
   * 用 lastDays(1)（它的基线就是"区间前最后一条"），无昨天记录时基线 0 → 今日累计值。
   */
  private calcToday(): void {
    const c = this.ctx();
    if (c === null) {
      return;
    }
    this.todayWords = WritingLog.lastDays(c, 1).words;
  }

  /** 本月实际写入 = 从本月 1 号到今天的每日增量之和。 */
  private calcMonth(): void {
    const now: Date = new Date();
    const key: string = now.getFullYear() + '-' + (now.getMonth() + 1 < 10 ? '0' : '') + (now.getMonth() + 1);
    this.monthWords = this.monthDelta(key);
  }

  /**
   * 某自然月的写入增量（'2026-10'）。
   * prev **跨月连续跟踪**：上月末最后一条就是本月 1 号的基线。
   */
  private monthDelta(yearMonth: string): number {
    let prev: number = 0;
    let sum: number = 0;
    for (let k = 0; k < this.days.length; k++) {
      const r: DayRecord = this.days[k];
      const inMonth: boolean = r.day.length >= 7 && r.day.substring(0, 7) === yearMonth;
      if (inMonth) {
        const delta: number = r.words - prev;
        if (delta > 0) {
          sum += delta;
        }
      }
      prev = r.words;
    }
    return sum;
  }

  /** 最新文档：自建文档按 mtime 降序前 N（封面墙数据）。 */
  private calcLatestDocs(c: common.UIAbilityContext): void {
    const list: DocMeta[] = DocStore.list(c);
    const docs: DocMeta[] = [];
    for (let k = 0; k < list.length; k++) {
      if (!list[k].builtin) {
        docs.push(list[k]);
      }
    }
    docs.sort((a: DocMeta, b: DocMeta): number => b.mtime - a.mtime);
    const out: LatestDoc[] = [];
    const limit: number = docs.length < LATEST_MAX ? docs.length : LATEST_MAX;
    for (let k = 0; k < limit; k++) {
      const m: DocMeta = docs[k];
      const day: Date = new Date(m.mtime);
      const y: number = day.getFullYear();
      const mo: number = day.getMonth() + 1;
      const monthKey: string = y + '-' + (mo < 10 ? '0' : '') + mo;
      const t: string = dayKeyOf(m.mtime);
      const item: LatestDoc = {
        name: m.name,
        fileName: m.fileName,
        builtin: m.builtin,
        coverColor: m.coverColor !== undefined ? m.coverColor : '',
        coverImage: m.coverImage !== undefined ? m.coverImage : '',
        hideName: m.hideCoverName === true,
        date: t.length >= 10 ? t.substring(5) : t,
        monthKey: monthKey,
        monthLabel: y + ' 年 ' + mo + ' 月',
        words: m.wordCount
      };
      out.push(item);
    }
    this.latestDocs = out;
  }

  private palette(): ReaderPalette {
    const tick: number = this.appearanceTick;
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  private isDark(): boolean {
    return isDarkTheme(this.themeMode, this.systemDark);
  }

  /** 数字格式：过万显示"x.x 万"，其余千分位空格。 */
  private fmt(n: number): string {
    const v: number = Math.round(n);
    if (v >= 10000) {
      return (v / 10000).toFixed(1) + ' 万';
    }
    const s: string = v.toString();
    const parts: string[] = [];
    for (let k = s.length - 1; k >= 0; k -= 3) {
      parts.unshift(s.substring(Math.max(0, k - 2), k + 1));
    }
    return parts.join(' ');
  }

  // ══════════════════════ 热力图配色 ══════════════════════

  /**
   * 某格颜色：跟随主题色的 5 档透明度梯度（不是 GitHub 的绿，也不是参考图的粉紫）。
   * @param words 当天写入字数（增量口径，0 = 没写）
   */
  private heatColor(words: number): string {
    const p: ReaderPalette = this.palette();
    if (words <= 0) {
      return withAlpha(p.accent, '1F');
    }
    let lvl: number = 1;
    if (words >= 1200) {
      lvl = 4;
    } else if (words >= 500) {
      lvl = 3;
    } else if (words >= 150) {
      lvl = 2;
    }
    const alpha: string[] = ['40', '66', '8C', 'B3', 'E0'];
    return withAlpha(p.accent, alpha[lvl]);
  }

  /**
   * 热力图格子边长：**固定值**（一年 53 列靠横向滑动看完）；
   * 打开/切年份后自动定位到**最新有数据的日期**所在列（右下角，GitHub 同款）。
   */
  private cellSize(): number {
    return HEAT_CELL;
  }

  /**
   * 第 w 周、第 d 行（0=周日）的日期键 —— **按 viewYear 窗口**：
   * 起点 = 该年 1 月 1 日所在周（含它的周日开头），53 列覆盖全年；
   * **只画 viewYear 内的日子**：去年 12 月 / 明年 1 月的格子留空 ——
   * 之前不截断，年初的"12月"列和"1月"贴在一起（用户反馈）；未来日期同样留空。
   */
  private keyAt(w: number, d: number): string {
    const jan1: Date = new Date(this.viewYear, 0, 1);
    const dow: number = jan1.getDay();
    const windowStart: number = new Date(this.viewYear, 0, 1 - dow).getTime();
    const ts: number = windowStart + (w * 7 + d) * 86400000;
    const yearStart: number = new Date(this.viewYear, 0, 1).getTime();
    const yearEnd: number = new Date(this.viewYear + 1, 0, 1).getTime();
    if (ts < yearStart || ts >= yearEnd || ts > Date.now()) {
      return '';
    }
    return dayKeyOf(ts);
  }

  /** 热力图行间距 / 格间距。 */
  private heatGap(): number {
    return HEAT_GAP;
  }

  /** 某天的写入增量（按日期键查询）。 */
  private dayWordsOf(day: string): number {
    let prev: number = 0;
    for (let k = 0; k < this.days.length; k++) {
      if (this.days[k].day === day) {
        const d: number = this.days[k].words - prev;
        return d > 0 ? d : 0;
      }
      prev = this.days[k].words;
    }
    return 0;
  }

  // ══════════════════════ 界面 ══════════════════════

  /** 顶部 4 格总览：总笔记 / 累计字数 / 本月字数 / 今日字数。 */
  @Builder
  overviewRow() {
    Row({ space: HwSpace.sm }) {
      this.statCell(this.totalDocs.toString(), '总笔记')
      this.statCell(this.fmt(this.totalWords), '累计字数')
      this.statCell(this.fmt(this.monthWords), '本月字数')
      this.statCell(this.fmt(this.todayWords), '今日字数')
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /** 单个统计格。 */
  @Builder
  statCell(value: string, label: string) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(HwType.label + 6)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.palette().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(label)
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /** 写作热力图卡（GitHub 风格：年份选择右上角 + 横向滑动一年 + 月份对齐列 + 左侧星期）。 */
  @Builder
  heatmapCard() {
    Column({ space: HwSpace.sm }) {
      // 年份选择：**右上角下拉 Select**（用户要求；替代原一排年份芯片）
      Row({ space: HwSpace.xs }) {
        Blank()
        Select(this.yearSelectOptions())
          .selected(this.yearOptions().indexOf(this.viewYear))
          .value(this.viewYear + ' 年')
          .font({ size: HwType.caption })
          .fontColor(this.palette().textPrimary)
          .backgroundColor(withAlpha(this.palette().accent, '2E'))
          .borderRadius(HwRadius.inner)
          .onSelect((index: number) => {
            const y: number = this.yearOptions()[index];
            // 切年份带动画：key 含 viewYear → 整片格子重建，animateTo 让新格淡入
            this.getUIContext().animateTo({ duration: 280, curve: Curve.FastOutSlowIn }, () => {
              this.viewYear = y;
            });
            // 切年份后重新定位到该年最新有数据的列
            setTimeout(() => {
              this.scrollHeatToLatest();
            }, 120);
          })
      }
      .width('100%')

      Row({ space: HwSpace.xs }) {
        // 左侧星期标注（只标一/三/五行），行高与格子严格一致；**不随横向滚动**（GitHub 同款）
        Column({ space: this.heatGap() }) {
          ForEach(HEAT_ROWS, (row: number) => {
            Row() {
              if (row === 1 || row === 3 || row === 5) {
                Text(this.weekLabel(row))
                  .fontSize(HwType.caption - 2)
                  .fontColor(this.palette().textTertiary)
              }
            }
            .width(this.weekColWidth())
            .height(this.cellSize())
            .alignItems(VerticalAlign.Center)
          }, (row: number) => 'wd_' + row)
        }
        .alignItems(HorizontalAlign.Start)

        // 月份标注 + 格子阵一起横向滑动（内容宽 = 53 列固定）
        // 挂 heatScroller：进页面 / 切年份后自动滚到"今天"所在列（GitHub 同款，
        // 用户反馈"不然还得滑动过去，麻烦"）
        Scroll(this.heatScroller) {
          Column({ space: this.heatGap() }) {
            // 月份标注：Stack + 按列偏移定位（标签可跨列溢出，GitHub 同款效果）
            Stack({ alignContent: Alignment.TopStart }) {
              ForEach(this.monthMarks(), (m: MonthMark) => {
                Text(m.label)
                  .fontSize(HwType.caption - 2)
                  .fontColor(this.palette().textTertiary)
                  .maxLines(1)
                  .margin({ left: m.col * this.colStep() })
              }, (m: MonthMark) => 'mm_' + m.label)
            }
            .width(HEAT_WEEKS * this.colStep())
            .height(15)

            // 7 行 × 53 列。⚠️ itemGenerator 里不能调 @Builder（白屏坑④），格子内联画
            Column({ space: this.heatGap() }) {
              ForEach(HEAT_ROWS, (row: number) => {
                Row({ space: this.heatGap() }) {
            ForEach(HEAT_COLS, (col: number) => {
              if (this.keyAt(col, row).length > 0) {
                Column()
                  .width(this.cellSize())
                  .height(this.cellSize())
                  .borderRadius(3)
                  .backgroundColor(this.heatColor(this.dayWordsOf(this.keyAt(col, row))))
                  // 今日描边高亮（GitHub 没有的设计，本应用的创新点）
                  .border({
                    width: this.keyAt(col, row) === this.todayKey() ? 1.5 : 0,
                    color: this.palette().accent
                  })
                  // 切年份时旧格淡出、新格淡入（配合年份芯片里的 animateTo）
                  .transition({ opacity: 0 })
                  .onClick(() => {
                    this.toastCell(this.keyAt(col, row));
                  })
              } else {
                Column()
                  .width(this.cellSize())
                  .height(this.cellSize())
              }
            }, (col: number) => 'hc_' + row + '_' + col)
                }
              }, (row: number) => 'hr_' + row)
            }
            .width(HEAT_WEEKS * this.colStep())
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 底部：左统计口径说明（GitHub "Learn how we count contributions" 位）+ 右图例
      //（图例收紧：格 8vp、间距 3 —— 用户反馈之前间距太宽）
      Row({ space: 3 }) {
        Text('按每日写作增量统计')
          .fontSize(HwType.caption - 1)
          .fontColor(this.palette().textTertiary)
        Blank()
        Text('少')
          .fontSize(HwType.caption - 1)
          .fontColor(this.palette().textTertiary)
        ForEach(HEAT_LEGEND, (a: string) => {
          Column()
            .width(8)
            .height(8)
            .borderRadius(2)
            .backgroundColor(withAlpha(this.palette().accent, a))
        }, (a: string) => 'lg_' + a)
        Text('多')
          .fontSize(HwType.caption - 1)
          .fontColor(this.palette().textTertiary)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 总结行文案（按 viewYear 全年统计：月增量求和 + 有产出天数）。 */
  private halfYearSummary(): string {
    const label: string = this.viewYear + ' 年';
    const s: YearStats = this.yearStats(this.viewYear);
    if (s.words <= 0) {
      return label + '还没有写作记录';
    }
    return label + '写下 ' + this.fmt(s.words) + ' 字 · ' + s.activeDays + ' 天有产出';
  }

  /** 某年的写作统计：每日累计值求差（prev 跨月跨年连续跟踪）。 */
  private yearStats(year: number): YearStats {
    const prefix: string = year + '-';
    let prev: number = 0;
    let words: number = 0;
    let active: number = 0;
    for (let k = 0; k < this.days.length; k++) {
      const r: DayRecord = this.days[k];
      const inYear: boolean = r.day.length >= 5 && r.day.substring(0, 5) === prefix;
      const delta: number = r.words - prev;
      if (inYear && delta > 0) {
        words += delta;
        active++;
      }
      prev = r.words;
    }
    const s: YearStats = { words: words, activeDays: active };
    return s;
  }

  /** 年份选择项：今年往前 YEAR_OPTIONS 年（新 → 旧）。 */
  private yearOptions(): number[] {
    const now: number = new Date().getFullYear();
    const out: number[] = [];
    for (let k = 0; k < YEAR_OPTIONS; k++) {
      out.push(now - k);
    }
    return out;
  }

  /** Select 下拉的选项（数字年份 → SelectOption）。 */
  private yearSelectOptions(): SelectOption[] {
    const out: SelectOption[] = [];
    const ys: number[] = this.yearOptions();
    for (let k = 0; k < ys.length; k++) {
      const opt: SelectOption = { value: ys[k] + ' 年' };
      out.push(opt);
    }
    return out;
  }

  /** 星期标注文案：row 0=周日 → '日'。 */
  private weekLabel(row: number): string {
    const names: string[] = ['日', '一', '二', '三', '四', '五', '六'];
    return names[row];
  }

  /** 左侧星期列宽。 */
  private weekColWidth(): number {
    return 16;
  }

  /** 列步进 = 格子边长 + 间距（月份标注按列定位用）。 */
  private colStep(): number {
    return this.cellSize() + this.heatGap();
  }

  /** 今天的日期键。 */
  private todayKey(): string {
    return dayKeyOf(Date.now());
  }

  /**
   * 把热力图横向滚动到**最新有数据的日期**所在列（用户要求：右下角显示最新有数据的日期，
   * 不用滑动过去找）。没有数据时滚到今天列。
   *
   * 视口宽无法在滚动前精确量出，用「目标列起点 − 一屏余量」估算并夹到 ≥0：
   * 多滚一点让目标列靠在可视区右缘。内容未布局完成时 scrollTo 无效，调用方延迟一帧触发。
   */
  private scrollHeatToLatest(): void {
    try {
      // 最新有数据的一天：days 按日期升序，最后一条即最新
      let targetDay: string = this.days.length > 0
        ? this.days[this.days.length - 1].day
        : this.todayKey();
      // 目标日期可能不在当前查看的年份窗口内（切到去年时）→ 退回该年年末
      if (targetDay.substring(0, 4) !== this.viewYear.toString()) {
        targetDay = this.viewYear + '-12-31';
        const yearEnd: Date = new Date(this.viewYear, 11, 31);
        if (yearEnd.getTime() > Date.now()) {
          targetDay = this.todayKey();
        }
      }
      const t: number = new Date(targetDay + 'T00:00:00').getTime();
      if (isNaN(t)) {
        return;
      }
      const jan1: Date = new Date(this.viewYear, 0, 1);
      const dow: number = jan1.getDay();
      const windowStart: number = new Date(this.viewYear, 0, 1 - dow).getTime();
      const col: number = Math.floor((t - windowStart) / (7 * 86400000));
      if (col < 0) {
        return;
      }
      // 视口宽不做精确量测（不再挂 onAreaChange）：按常见机型 ~300vp 估算，
      // 目标列靠右缘即可，误差不影响"打开即见最新"的目的
      const viewport: number = 280;
      const x: number = Math.max(0, (col + 1) * this.colStep() - viewport + this.colStep());
      this.heatScroller.scrollTo({ xOffset: x, yOffset: 0 });
    } catch (err) {
      // 定位失败不影响展示，用户可手动滑
    }
  }

  /** 点击格子：toast 当天日期与写入字数。 */
  private toastCell(day: string): void {
    const words: number = this.dayWordsOf(day);
    try {
      this.getUIContext().getPromptAction().showToast({
        message: day + (words > 0 ? ' · 写了 ' + this.fmt(words) + ' 字' : ' · 没有写作'),
        duration: 1400
      });
    } catch (err) {
      // 提示失败无副作用
    }
  }

  /**
   * 月份标注：**按"每月 1 号所在列"直接计算**（不再逐列扫周日行）。
   * 之前只扫每列的周日，10 月 1 号若落在周四周上就永远不会被标注（用户反馈
   * "已经 10 月了上面还写 9 月"）。现在每个月 1 号算出列号即标注，1..12 月全精确。
   */
  private monthMarks(): MonthMark[] {
    const out: MonthMark[] = [];
    const jan1: Date = new Date(this.viewYear, 0, 1);
    const dow: number = jan1.getDay();
    const windowStart: number = new Date(this.viewYear, 0, 1 - dow).getTime();
    const now: number = Date.now();
    for (let m = 1; m <= 12; m++) {
      const monthStart: number = new Date(this.viewYear, m - 1, 1).getTime();
      if (monthStart > now) {
        break; // 未来月份不标
      }
      const col: number = Math.floor((monthStart - windowStart) / (7 * 86400000));
      if (col < 0 || col >= HEAT_WEEKS) {
        continue;
      }
      const mark: MonthMark = { label: m + '月', col: col };
      out.push(mark);
    }
    return out;
  }

  /** 最新文档卡：GitHub Contribution activity 时间线复刻 —— 月份分隔 + 活动条目 + 字数比例条。 */
  @Builder
  latestDocsCard() {
    Column({ space: HwSpace.sm }) {
      if (this.latestDocs.length === 0) {
        Text('还没有自建笔记，去书架新建一篇吧')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .width('100%')
          .padding({ top: HwSpace.sm, bottom: HwSpace.sm })
      } else {
        // 按月分组的时间线（GitHub activity 同构）：月份粗体行 + 细线，
        // 每条 = 圆形封面点 + 文档名（强调色）+ 字数日期 + 右侧字数比例条
        ForEach(this.latestGroups(), (g: LatestGroup) => {
          Column({ space: HwSpace.sm }) {
            // 月份分隔行：粗体月份 + 横线（GitHub "October 2026 ——" 式）
            Row({ space: HwSpace.sm }) {
              Text(g.monthLabel)
                .fontSize(HwType.label)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.palette().textPrimary)
              Divider()
                .strokeWidth(1)
                .color(this.palette().divider)
                .layoutWeight(1)
            }
            .width('100%')

            ForEach(g.docs, (item: LatestDoc) => {
              Row({ space: HwSpace.sm }) {
                // 迷你封面图标：D 型渐变块（左书脊小圆角、右大圆角），
                // 圆角按 30vp 尺寸等比缩放 —— DocCover 的 5/13 是按大封面设计的，
                // 直接套在 30vp 上右圆角占 43% 宽，观感失调（用户反馈"圆角不对"）
                Column()
                  .width(24)
                  .aspectRatio(0.72)
                  .borderRadius({ topLeft: 2, bottomLeft: 2, topRight: 6, bottomRight: 6 })
                  // **描边**（用户要求）：细一圈深色描边，浅色壁纸上轮廓更清晰
                  .border({ width: 1, color: this.palette().divider })
                  .linearGradient({
                    angle: 200,
                    colors: [[this.latestDotColors(item).top, 0.0],
                      [this.latestDotColors(item).bottom, 1.0]]
                  })

                Column({ space: 2 }) {
                  Text(item.name)
                    .fontSize(HwType.label)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.palette().accent)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.fmt(item.words) + ' 字 · ' + item.date)
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textTertiary)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                // 右侧字数比例条：长度 = 该文档字数 / 组内最大字数（GitHub 绿条同构）
                Column()
                  .width(this.barWidthFor(item.words, g.maxWords))
                  .height(6)
                  .borderRadius(3)
                  .backgroundColor(withAlpha(this.palette().accent, 'B3'))
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }, (item: LatestDoc) => 'la_' + item.name + '_' + item.date)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }, (g: LatestGroup) => 'lg_' + g.monthKey)

        // 比例条说明（用户问"那个进度条是什么意思"）
        Text('右侧横条表示该文档的字数多少：越长字数越多（按这一批里字数最多的一篇归一化）。')
          .fontSize(HwType.caption - 1)
          .fontColor(this.palette().textTertiary)
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 时间线迷你封面的配色：自定义封面色优先，否则文档名哈希色。 */
  private latestDotColors(item: LatestDoc): CoverStyle {
    if (item.coverColor.length > 0) {
      return coverStyleFromColor(item.coverColor);
    }
    return coverColorsOf(item.name, item.builtin);
  }

  /** 时间线比例条宽：按组内最大字数归一化到 [24, 96]vp。 */
  private barWidthFor(words: number, maxWords: number): number {
    if (maxWords <= 0 || words <= 0) {
      return 24;
    }
    const w: number = 24 + Math.round(words / maxWords * 72);
    return w > 96 ? 96 : w;
  }

  /**
   * 最新文档按月分组（时间线数据）。
   * latestDocs 已按 mtime 降序，顺序遍历切组即可（组的顺序 = 月份从新到旧）。
   */
  private latestGroups(): LatestGroup[] {
    const out: LatestGroup[] = [];
    for (let k = 0; k < this.latestDocs.length; k++) {
      const item: LatestDoc = this.latestDocs[k];
      // date 形如 '10-02'；组键补年份从 mtime 来 —— 直接用文档的 dayKey
      const key: string = item.monthKey;
      let g: LatestGroup | null = null;
      for (let j = 0; j < out.length; j++) {
        if (out[j].monthKey === key) {
          g = out[j];
          break;
        }
      }
      if (g === null) {
        const ng: LatestGroup = {
          monthKey: key,
          monthLabel: item.monthLabel,
          maxWords: 0,
          docs: []
        };
        out.push(ng);
        g = ng;
      }
      g.docs.push(item);
      g.maxWords = item.words > g.maxWords ? item.words : g.maxWords;
    }
    return out;
  }

  build() {
    SettingsShell({
      shellTitle: '写作日志',
      shellSubtitle: '热力图 · 字数 · 本地计算',
      stack: this.stack,
      life: this.life
    }) {
      Column({ space: HwSpace.lg }) {
        // ① 总览 4 格
        ImmersiveCard({
          cardRadius: HwRadius.card,
          cardPadding: HwSpace.lg,
          palette: this.palette()
        }) {
          this.overviewRow()
        }

        // 数据加载失败的可见提示（排障：不再静默吞掉）
        if (this.loadError.length > 0) {
          Text(this.loadError)
            .fontSize(HwType.caption)
            .fontColor('#FFD93B3B')
            .width('100%')
        }

        // ② 总结行（GitHub "202 contributions in the last year" 式：
        //    **卡外区块标题**，大号字直接压在背景上，热力图卡紧随其下）
        Text(this.halfYearSummary())
          .fontSize(HwType.label + 4)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.palette().textPrimary)
          .width('100%')

        // ③ 热力图卡（月份/星期/格子/图例全在卡内；左下角统计口径说明）
        ImmersiveCard({
          cardRadius: HwRadius.card,
          cardPadding: HwSpace.lg,
          palette: this.palette()
        }) {
          this.heatmapCard()
        }

        // ④ "最近动态"区块标题（GitHub "Contribution activity" 式：卡外标题）
        Text('最近动态')
          .fontSize(HwType.label + 4)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.palette().textPrimary)
          .width('100%')

        // ⑤ 动态时间线卡（月份分隔 + 活动条目 + 字数比例条）
        ImmersiveCard({
          cardRadius: HwRadius.card,
          cardPadding: HwSpace.lg,
          palette: this.palette()
        }) {
          this.latestDocsCard()
        }

        Text('数据来自本机写作记录，卸载应用或清除数据后不可恢复。')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .width('100%')
      }
      .width('100%')
      // ⚠️ **不要加左右 padding**：SettingsShell 的内容区已有一层 padding(lg)，
      // 这里再套一层就是双重复 → 卡片两边各多缩 20vp（用户连续三轮反馈"卡片窄"的真因）。
      // 只保留底部避让。**也不要 constraintSize / onAreaChange 写状态**：
      // 大屏横屏下尺寸回调高频触发 + 状态回写会造成渲染异常（曾整页白屏），
      // 与其他设置页保持完全一致的写法。
      .padding({ bottom: HwSpace.xxl })
    }
  }
}
