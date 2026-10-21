/**
 * 澄笺 · 复习页（1.1.0，参考背单词软件的界面重构）
 * ==============================
 *
 * **两个形态**：
 *
 * ① **学习主页**（默认）—— 悬浮胶囊顶栏 + 分段页签（学习 / 统计），
 *    内容照背单词 App 的信息架构分节：
 *      · 「计划」：选择要复习的文档（默认不汇总，选哪篇背哪篇）+ 今日到期 + 开始复习；
 *      · 「统计」：概览 2×2（今日复习条数 / 累计复习条数 / 今日时长 / 累计时长）
 *        + 遗忘曲线分桶；
 *      · 「签到日历」：月历可翻月，签到的日子点亮，底部连续 / 累计签到。
 *
 * ② **复习中**（全屏翻卡，参考背单词的刷词页）——
 *      · 顶栏：退出 + 「第 x / N 张」+ 提示按钮；
 *      · 中部大字正面（高亮文本），点卡片翻面看批注；
 *      · 底部三个大按钮：**记得（绿）/ 模糊（黄）/ 忘了（红）**，带色点下划线；
 *      · 复习逻辑：忘了 / 模糊 → 排队尾重复出现直到记住（streak 清零）；
 *        记得 → 累计 3 次才算掌握（之后按 SM-2 艾宾浩斯曲线拉长间隔），未满会再出现。
 *
 * 背景与书架同一套优先级（图片壁纸 / 程序化壁纸 / 自定义色 / 主题渐变）。
 * 统计与签到持久化到 `filesDir/review_stats.json`。
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { textToSpeech } from '@kit.CoreSpeechKit';
import {
  HwBar, HwFont, HwRadius, HwSpace, HwType, ReaderPalette, paletteFor, isDarkTheme, ReaderThemeMode
} from '../theme/DesignTokens';
import { ImmersiveBar, ImmersiveCard, ImmersiveChip, ImmersiveIconButton } from '../material/ImmersiveCard';
import { GenWallpaper } from '../theme/GenWallpaper';
import { WallpaperStore } from '../service/WallpaperStore';
import { WallpaperImage } from '../components/WallpaperImage';
import { DocMeta, DocStore } from '../service/DocStore';
import { MdAnnotation } from '../markdown/MdTypes';
import { AnnotationStore } from '../service/AnnotationStore';
import { ReviewCard, ReviewCardStore, ReviewSeed } from '../service/ReviewCard';
import { DocCover, coverColorsOf } from '../components/DocCover';
import { MathFormulaText } from '../components/MathFormulaText';
import { L10n } from '../service/L10n';
import { AppearanceFx } from '../service/AppearanceFx';

/** 遗忘曲线的一个分桶：区间上限（天）+ 展示名。 */
interface DueBucket {
  maxDays: number;
  label: string;
}

const BUCKETS: DueBucket[] = [
  { maxDays: 1, label: L10n.t('1 天') },
  { maxDays: 3, label: L10n.t('3 天') },
  { maxDays: 7, label: L10n.t('一周内') },
  { maxDays: 15, label: L10n.t('半月内') },
  { maxDays: 30, label: L10n.t('一月内') },
  { maxDays: 36500, label: L10n.t('更久') }
];

/** 掌握所需的连续「记得」次数。 */
const MASTER_STREAK: number = 3;

/** 复习统计与签到（持久化 JSON）。 */
interface ReviewStatsFile {
  todayKey: string;
  todayCount: number;
  todaySeconds: number;
  totalCount: number;
  totalSeconds: number;
  signDays: string[];
  /** 每日复习目标条数（可自定义） */
  dailyGoal?: number;
  /** 未完成的复习会话（临时退出后恢复进度用） */
  session?: ReviewSessionFile;
}

/** 进行中的会话：剩余队列（卡 id）+ 进度。 */
interface ReviewSessionFile {
  ids: string[];
  index: number;
  mastered: number;
  total: number;
}

function reviewDayKey(ms: number): string {
  const d: Date = new Date(ms);
  const m: string = (d.getMonth() + 1) < 10 ? '0' + (d.getMonth() + 1) : '' + (d.getMonth() + 1);
  const day: string = d.getDate() < 10 ? '0' + d.getDate() : '' + d.getDate();
  return d.getFullYear() + '-' + m + '-' + day;
}

@Component
export struct ReviewPage {
  stack: NavPathStack | null = null;
  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  /** **界面字体**（外观设置 → 界面字体）：本页界面文字都从这里取 */
  @StorageProp('appFontFamily') uiFontKey: string = '';
  /** 界面字号缩放系数 / 界面字重相对加粗量（外观设置） */
  @StorageProp('appFontScale') uiFontScale: number = 1;
  @StorageProp('appFontWeightDelta') uiFontWeightDelta: number = 0;
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  @StorageProp('safeBottomPx') safeBottomPx: number = 0;
  /**
   * **系统返回拦截回调**：Index 的 NavDestination.onBackPressed 通过它询问本页。
   * 返回 true = 已自行处理（刷卡形态 → 回到本页「学习」页签），不退出页面。
   */
  onBackBind: (cb: () => boolean) => void = (_cb: () => boolean): void => {};

  // ── 背景（与书架同一优先级）──
  @StorageProp('wallpaperPathLight') wallpaperPathLight: string = '';
  @StorageProp('wallpaperPathDark') wallpaperPathDark: string = '';
  @StorageProp('wallpaperPath') wallpaperPath: string = '';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 4;
  @StorageLink('wallpaperScrim') wallpaperScrim: number = 42;
  @StorageProp('wallpaperGenId') genWallId: string = '';
  @StorageLink('readerCustomBgLight') customBgLight: string = '';
  @StorageLink('readerCustomBgDark') customBgDark: string = '';

  /** 页签：0 学习主页 · 1 统计 */
  @State tab: number = 0;
  /** 语言切换计数：变更时整页重建（key 拼接），文案随词典刷新 */
  @StorageProp('languageTick') languageTick: number = 0;
  /** 是否处于全屏复习（刷卡形态） */
  @State reviewing: boolean = false;
  /** 本轮全部背完：展示完成界面（用户要求专门设计） */
  @State finished: boolean = false;

  /** 全部卡片 */
  @State cards: ReviewCard[] = [];
  /** 有卡片的文档名（筛选 chips） */
  @State docNames: string[] = [];
  @State docCounts: number[] = [];
  /** 有学习卡的文档元数据（计划卡封面展示用，与 docNames 对齐） */
  @State planMetas: DocMeta[] = [];
  /** 选中的文档（空 = 全部） */
  @State selected: string[] = [];
  /** 复习队列与进度 */
  @State queue: ReviewCard[] = [];
  @State queueTotal: number = 0;
  @State queueIndex: number = 0;
  @State flipped: boolean = false;
  /** 互换模式：正面显示批注、背面显示原文（单词与翻译互换，用户要求） */
  @StorageLink('reviewSwapMode') swapMode: boolean = false;
  /** 拼写模式：输入隐藏内容判定，完全一致才通过 */
  @StorageLink('reviewTypingMode') typingMode: boolean = false;
  /** 拼写输入内容 */
  @State typeInput: string = '';
  /** 拼写判定失败（翻面显示正确答案并按模糊计） */
  @State typeWrong: boolean = false;

  /** 当前卡的正面（互换模式下显示批注内容） */
  private cardFront(): string {
    const c: ReviewCard = this.queue[this.queueIndex];
    return this.swapMode ? c.back : c.front;
  }

  /** 当前卡的背面（互换模式下显示原文） */
  private cardBack(): string {
    const c: ReviewCard = this.queue[this.queueIndex];
    return this.swapMode ? c.front : c.back;
  }

  /** 当前卡的文档标签（书架标签系统：信息卡添加，此处只读展示） */
  private docTagsOf(name: string): string[] {
    const c = this.ctx();
    if (c === null) {
      return [];
    }
    const meta: DocMeta | undefined = DocStore.find(c, name);
    const raw: string[] | undefined = meta === undefined ? undefined : meta.tags;
    return raw === undefined ? [] : raw;
  }

  /** 切换互换模式（学习主页提前选好，复习中只执行） */
  private toggleSwapMode(): void {
    this.getUIContext().animateTo(AppearanceFx.anim(200, Curve.FastOutSlowIn), () => {
      this.swapMode = !this.swapMode;
      this.flipped = false;
      this.typeWrong = false;
    });
  }

  /** 切换拼写模式 */
  private toggleTypingMode(): void {
    this.getUIContext().animateTo(AppearanceFx.anim(200, Curve.FastOutSlowIn), () => {
      this.typingMode = !this.typingMode;
      this.typeInput = '';
      this.typeWrong = false;
    });
  }

  /** 拼写提交：输入与隐藏内容完全一致（trim 后）才通过，否则翻面看答案并按模糊计 */
  private submitTyping(): void {
    if (this.typeInput.trim().length === 0 || this.queueIndex >= this.queue.length) {
      return;
    }
    const hidden: string = this.cardBack().trim();
    if (this.typeInput.trim() === hidden) {
      this.typeWrong = false;
      this.typeInput = '';
      this.grade(2);
    } else {
      this.typeWrong = true;
      this.flipped = true;
      this.grade(1);
    }
  }
  @State hintText: string = '';
  /** 提示自动消失计时器（2 秒） */
  private hintTimer: number = -1;
  // ── 学习卡朗读（系统文本转语音，队列本就只收学习卡）──
  private ttsEngine: textToSpeech.TextToSpeechEngine | null = null;
  private ttsRequest: number = 0;
  @State ttsBusy: boolean = false;

  /** 朗读当前卡：正面（单词 / 原句）+ 中文备注；再点一次停止。 */
  private speakCurrentCard(): void {
    if (this.queueIndex >= this.queue.length) {
      return;
    }
    if (this.ttsBusy) {
      // 再点一次 = 停止
      try {
        this.ttsEngine?.stop();
      } catch (err) {
        // 忽略
      }
      this.ttsBusy = false;
      return;
    }
    const card: ReviewCard = this.queue[this.queueIndex];
    // **只读卡片正面**（单词 / 原句）：批注内容（中文释义）不播（用户要求）；互换模式读互换后的正面
    const text: string = this.swapMode ? card.back : card.front;
    if (this.ttsEngine === null) {
      // 基础离线模式下只能用离线音色（与阅读页朗读同一口径）
      const mode: string = AppStorage.get<string>('appMode') ?? '';
      const params: textToSpeech.CreateEngineParams = {
        language: 'zh-CN',
        person: 0,
        online: mode === 'offline' ? 0 : 1
      };
      textToSpeech.createEngine(params)
        .then((engine: textToSpeech.TextToSpeechEngine) => {
          this.ttsEngine = engine;
          engine.setListener({
            onStart: (requestId: string, response: textToSpeech.StartResponse) => {
              this.ttsBusy = true;
            },
            onComplete: (requestId: string, response: textToSpeech.CompleteResponse) => {
              this.ttsBusy = false;
            },
            onStop: (requestId: string, response: textToSpeech.StopResponse) => {
              this.ttsBusy = false;
            },
            onError: (requestId: string, errorCode: number, errorMessage: string) => {
              this.ttsBusy = false;
              this.getUIContext().getPromptAction().showToast({
                message: L10n.t('朗读失败（') + errorCode + '）：' + errorMessage,
                duration: 2000
              });
            }
          });
          this.ttsSpeakText(text);
        })
        .catch((err: BusinessError) => {
          this.getUIContext().getPromptAction().showToast({ message: L10n.t('语音引擎创建失败'), duration: 2000 });
        });
      return;
    }
    this.ttsSpeakText(text);
  }

  private ttsSpeakText(text: string): void {
    if (this.ttsEngine === null || text.length === 0) {
      return;
    }
    this.ttsRequest = this.ttsRequest + 1;
    const speakParams: textToSpeech.SpeakParams = {
      requestId: 'review_' + this.ttsRequest
    };
    try {
      this.ttsEngine.speak(text, speakParams);
      this.ttsBusy = true;
    } catch (err) {
      this.ttsBusy = false;
      this.getUIContext().getPromptAction().showToast({ message: L10n.t('朗读失败，已停止'), duration: 2000 });
    }
  }
  @State sessionMastered: number = 0;
  // ── 「记得」确认态（展示具体内容卡 + 竖向 3 灯）──
  /** 评分后进入确认卡：展示具体内容，按钮确认后才推进 */
  @State pendingConfirm: boolean = false;
  /** 本次评分类型：0 忘了 · 1 模糊 · 2 记得（确认卡的提示语与按钮随类型变化） */
  @State pendingKind: number = -1;
  /** 本次「记得」后的连续次数（确认卡上点灯，仅记得时用） */
  @State confirmStreak: number = 0;
  /** 本次是否已达成掌握（3 灯全亮） */
  @State pendingMastered: boolean = false;
  @State loaded: boolean = false;
  @State loadError: string = '';

  // ── 统计与签到 ──
  @State statTodayCount: number = 0;
  @State statTodaySeconds: number = 0;
  @State statTotalCount: number = 0;
  @State statTotalSeconds: number = 0;
  @State signDays: string[] = [];
  /** 签到日历当前查看的年月（默认当月） */
  @State viewYear: number = new Date().getFullYear();
  @State viewMonth: number = new Date().getMonth();
  /** 每日复习目标条数（可自定义，持久化） */
  @State dailyGoal: number = 20;
  private tickTimer: number = -1;
  private statDirty: boolean = false;
  /** 学习 / 统计两页的滑动控制器（分段页签点击时同步切页） */
  private reviewSwiper: SwiperController = new SwiperController();

  aboutToAppear(): void {
    // 向 Index 注册系统返回拦截：刷卡形态中侧滑 / 返回键 = 回到本页「学习」页签
    this.onBackBind((): boolean => {
      if (this.reviewing) {
        this.exitReview();
        return true;
      }
      return false;
    });
    this.reload();
    this.loadStats();
    // 每秒累计停留时长（页面在前台才算），每 15 秒落一次盘
    this.tickTimer = setInterval(() => {
      this.statTodaySeconds = this.statTodaySeconds + 1;
      this.statTotalSeconds = this.statTotalSeconds + 1;
      this.statDirty = true;
      if (this.statTodaySeconds % 15 === 0) {
        this.saveStats();
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
    this.saveStats();
  }

  private syncFlashFlag(): void {
    AppStorage.setOrCreate('reviewFlashOn', this.reviewing && !this.finished);
  }

  private ctx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  private palette(): ReaderPalette {
    return paletteFor(this.themeMode, this.systemDark);
  }

  private isDark(): boolean {
    return isDarkTheme(this.themeMode, this.systemDark);
  }

  private wallpaperPathEffective(): string {
    if (this.isDark()) {
      return this.wallpaperPathDark.length > 0 ? this.wallpaperPathDark : this.wallpaperPath;
    }
    return this.wallpaperPathLight.length > 0 ? this.wallpaperPathLight : this.wallpaperPath;
  }

  private pageBackground(): string {
    if (this.isDark()) {
      return this.customBgDark.length > 0 ? this.customBgDark : '';
    }
    return this.customBgLight.length > 0 ? this.customBgLight : '';
  }

  private safeTopVp(): number {
    return this.getUIContext().px2vp(this.safeTopPx);
  }

  private padBottom(): number {
    return this.getUIContext().px2vp(this.safeBottomPx) + HwSpace.xs;
  }

  // ────────────────────────── 数据 ──────────────────────────

  private reload(): void {
    const c = this.ctx();
    if (c === null) {
      return;
    }
    try {
      DocStore.init(c);
      const seeds: ReviewSeed[] = this.buildSeeds(c);
      ReviewCardStore.sync(c, seeds);
      this.cards = ReviewCardStore.load(c);
      this.rebuildDocNames();
      this.rebuildQueue();
      this.loaded = true;
      this.loadError = '';
      this.syncFlashFlag();
    } catch (err) {
      const e = err as BusinessError;
      this.loadError = '复习数据加载失败：' + (e.message !== undefined ? e.message : '');
    }
  }

  private buildSeeds(c: common.UIAbilityContext): ReviewSeed[] {
    const out: ReviewSeed[] = [];
    const list: DocMeta[] = DocStore.list(c);
    for (let k = 0; k < list.length; k++) {
      const arr: MdAnnotation[] = AnnotationStore.load(c, list[k].name);
      for (let j = 0; j < arr.length; j++) {
        const a: MdAnnotation = arr[j];
        // **只认「学习卡」**（用户明确要求）：批注 / 荧光笔 / 波浪线 / 手写批注
        // 是独立的标识形态，不混入复习数据
        if (a.style !== 'card') {
          continue;
        }
        const front: string = a.text.trim();
        if (front.length === 0) {
          continue;
        }
        out.push({
          docName: list[k].name, annId: a.id, front: front, back: a.note
        } as ReviewSeed);
      }
    }
    return out;
  }

  private rebuildDocNames(): void {
    const names: string[] = [];
    const counts: number[] = [];
    for (let k = 0; k < this.cards.length; k++) {
      const n: string = this.cards[k].docName;
      let at: number = -1;
      for (let d = 0; d < names.length; d++) {
        if (names[d] === n) {
          at = d;
          break;
        }
      }
      if (at < 0) {
        names.push(n);
        counts.push(1);
      } else {
        counts[at] = counts[at] + 1;
      }
    }
    for (let a = 0; a < names.length; a++) {
      for (let b = a + 1; b < names.length; b++) {
        if (counts[b] > counts[a]) {
          const tn: string = names[a];
          names[a] = names[b];
          names[b] = tn;
          const tc: number = counts[a];
          counts[a] = counts[b];
          counts[b] = tc;
        }
      }
    }
    this.docNames = names;
    this.docCounts = counts;
    // 计划卡的封面数据（用户要求：展示有学习卡的书的封面）
    const c = this.ctx();
    this.planMetas = [];
    if (c !== null) {
      DocStore.init(c);
      const list: DocMeta[] = DocStore.list(c);
      for (let a = 0; a < names.length; a++) {
        for (let m = 0; m < list.length; m++) {
          if (list[m].name === names[a]) {
            this.planMetas.push(list[m]);
            break;
          }
        }
      }
    }
    for (let s = this.selected.length - 1; s >= 0; s--) {
      let alive: boolean = false;
      for (let d = 0; d < names.length; d++) {
        if (names[d] === this.selected[s]) {
          alive = true;
          break;
        }
      }
      if (!alive) {
        this.selected.splice(s, 1);
      }
    }
  }

  private rebuildQueue(): void {
    const due: ReviewCard[] = ReviewCardStore.dueToday(this.cards);
    const out: ReviewCard[] = [];
    for (let k = 0; k < due.length; k++) {
      if (this.selected.length === 0) {
        out.push(due[k]);
        continue;
      }
      for (let s = 0; s < this.selected.length; s++) {
        if (this.selected[s] === due[k].docName) {
          out.push(due[k]);
          break;
        }
      }
    }
    this.queue = out;
    this.queueTotal = out.length;
    this.queueIndex = 0;
    this.flipped = false;
    this.hintText = '';
    this.sessionMastered = 0;
  }

  private toggleDoc(name: string): void {
    let at: number = -1;
    for (let s = 0; s < this.selected.length; s++) {
      if (this.selected[s] === name) {
        at = s;
        break;
      }
    }
    if (at >= 0) {
      this.selected.splice(at, 1);
    } else {
      this.selected.push(name);
    }
    this.rebuildQueue();
  }

  private streakOf(card: ReviewCard): number {
    return card.streak === undefined ? 0 : card.streak;
  }

  /** 开始复习：进全屏刷卡形态。 */
  private startReview(): void {
    this.reviewing = true;
    this.flipped = false;
    this.hintText = '';
    this.syncFlashFlag();
  }

  private exitReview(): void {
    // 退出前停掉卡片朗读，避免声音在书架继续播放
    try {
      this.ttsEngine?.stop();
    } catch (err) {
      // 忽略
    }
    this.ttsBusy = false;
    // **临时退出保留会话**（用户要求）：已背的 / 没背的都记着，重进页面接着背。
    // 这里不 rebuildQueue（那会把剩余队列重置），只标记退出并把会话落盘。
    // 退出后停留在本页的「学习」页签（复习卡片所在处）。
    this.reviewing = false;
    this.tab = 0;
    this.statDirty = true;
    this.saveStats();
    this.syncFlashFlag();
  }

  /**
   * 评分（1.1.0：**忘了 / 模糊 / 记得都先展示具体内容**，确认后才推进）：
   *   · **忘了**：SM-2 回 1 天，streak 清零，确认「下一个」后排队尾（今天还会出现）；
   *   · **模糊**：SM-2 间隔 ×1.2，streak 清零，确认后排队尾；
   *   · **记得**：streak + 1 点灯；不满 3 次 → 确认后排队尾再出现；
   *     满 3 次 → 掌握，按艾宾浩斯曲线拉长间隔，今天不再出现。
   */
  /**
   * 遗忘曲线卡片：**预测曲线**（按当前卡片 SM-2 数据聚合）vs **标准艾宾浩斯曲线**（参考线）。
   * 保留模型：R(t) = exp(-t / S)，S ≈ 间隔天数 × 3（间隔即复习计划点，此处按经验系数放大）。
   */
  @Builder
  forgettingCurveCard() {
    this.sectionHead(L10n.t('遗忘曲线 · 预测与标准'))
    ImmersiveCard({
      cardRadius: HwRadius.card,
      cardPadding: HwSpace.lg,
      palette: this.palette()
    }) {
      Column({ space: HwSpace.xs }) {
        Canvas(this.forgetCtx)
          .width('100%')
          .height(190)
          .onReady(() => {
            this.drawForgetCurve();
          })
        Row({ space: HwSpace.md }) {
          Row({ space: 6 }) {
            Column()
              .width(16).height(3).borderRadius(2)
              .backgroundColor(this.palette().accent)
            Text(L10n.t('你的预测'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textSecondary)
          }
          .alignItems(VerticalAlign.Center)
          Blank()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        Text(L10n.t('横轴：天后') + ' · ' + L10n.t('纵轴：记忆保持率'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
          .width('100%')
        Text(L10n.t('预测基于当前卡片的间隔与难度系数聚合；复习会让曲线整体抬升。'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 遗忘曲线画布上下文 */
  private forgetCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true))

  /** 绘制预测遗忘曲线与标准艾宾浩斯参考线 */
  private drawForgetCurve(): void {
    const ctx = this.forgetCtx;
    const w: number = ctx.width;
    const h: number = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    const DAYS: number = 30;
    const ml: number = 34;
    const mr: number = 10;
    const mt: number = 10;
    const mb: number = 20;
    const gw: number = w - ml - mr;
    const gh: number = h - mt - mb;
    const pal = this.palette();
    ctx.clearRect(0, 0, w, h);
    // 网格与坐标轴
    ctx.strokeStyle = pal.divider;
    ctx.lineWidth = 1;
    ctx.font = '10px sans-serif';
    ctx.fillStyle = pal.textTertiary;
    for (let g = 0; g <= 4; g++) {
      const gy: number = mt + gh * g / 4;
      ctx.beginPath();
      ctx.moveTo(ml, gy);
      ctx.lineTo(ml + gw, gy);
      ctx.stroke();
      ctx.fillText(String(100 - g * 25) + '%', 2, gy + 4);
    }
    for (let d = 0; d <= DAYS; d += 10) {
      const gx: number = ml + gw * d / DAYS;
      ctx.beginPath();
      ctx.moveTo(gx, mt);
      ctx.lineTo(gx, mt + gh);
      ctx.stroke();
      ctx.fillText(d + 'd', gx - 6, h - 6);
    }
    // 预测曲线：按卡片聚合 R_i(t) = exp(-t / S_i)，S_i = max(间隔,0.5) × 3（经验系数）
    const studied: ReviewCard[] = this.cards.filter((c: ReviewCard) => c.lastReview > 0 && c.interval > 0);
    ctx.strokeStyle = pal.accent;
    ctx.lineWidth = 2.5;
    ctx.beginPath();
    if (studied.length > 0) {
      for (let d = 0; d <= DAYS * 2; d++) {
        const t: number = d / 2;
        let sum: number = 0;
        for (let i = 0; i < studied.length; i++) {
          const sN: number = Math.max(studied[i].interval, 0.5) * 3 * Math.max(studied[i].ease, 1.3) / 2.5;
          sum += Math.exp(-t / sN);
        }
        const r: number = sum / studied.length;
        const x: number = ml + gw * t / DAYS;
        const y: number = mt + gh * (1 - r);
        if (d === 0) {
          ctx.moveTo(x, y);
        } else {
          ctx.lineTo(x, y);
        }
      }
    }
    ctx.stroke();
  }

  private grade(gradeValue: number): void {
    const c = this.ctx();
    if (c === null || this.queueIndex >= this.queue.length) {
      return;
    }
    const cur: ReviewCard = this.queue[this.queueIndex];
    if (gradeValue <= 1) {
      cur.streak = 0;
      try {
        const all: ReviewCard[] = ReviewCardStore.load(c);
        for (let k = 0; k < all.length; k++) {
          if (all[k].id === cur.id) {
            ReviewCardStore.grade(all[k], gradeValue);
            break;
          }
        }
        ReviewCardStore.save(c, all);
        this.cards = all;
      } catch (err) {
        // 落盘失败不影响会话推进
      }
      this.pendingKind = gradeValue;
      this.confirmStreak = 0;
      this.pendingMastered = false;
    } else {
      // 记得：streak 点灯并落盘（SM-2 的间隔推进等「下一个」确认掌握时才应用）
      const streak: number = this.streakOf(cur) + 1;
      cur.streak = streak;
      try {
        const all: ReviewCard[] = ReviewCardStore.load(c);
        for (let k = 0; k < all.length; k++) {
          if (all[k].id === cur.id) {
            all[k].streak = streak;
            break;
          }
        }
        ReviewCardStore.save(c, all);
        this.cards = all;
      } catch (err) {
        // 忽略
      }
      this.pendingKind = 2;
      this.confirmStreak = streak;
      this.pendingMastered = streak >= MASTER_STREAK;
    }
    this.pendingConfirm = true;
    this.flipped = true;
    this.hintText = '';
    this.bumpStats();
    this.saveSession();
  }

  /** 确认卡上的「下一个」：按类型收尾（掌握落 SM-2，否则排队尾）并推进。 */
  private confirmContinue(): void {
    this.typeInput = '';
    this.typeWrong = false;
    this.flipped = false;
    const c = this.ctx();
    const cur: ReviewCard | undefined =
      this.queueIndex < this.queue.length ? this.queue[this.queueIndex] : undefined;
    const mastered: boolean = this.pendingKind === 2 && this.pendingMastered;
    if (c !== null && cur !== undefined && mastered) {
      // 掌握：SM-2 按记得推进间隔（艾宾浩斯），今天不再出现
      try {
        const all: ReviewCard[] = ReviewCardStore.load(c);
        for (let k = 0; k < all.length; k++) {
          if (all[k].id === cur.id) {
            ReviewCardStore.grade(all[k], 2);
            break;
          }
        }
        ReviewCardStore.save(c, all);
        this.cards = all;
      } catch (err) {
        // 忽略
      }
      this.sessionMastered = this.sessionMastered + 1;
    }
    // 摘出当前卡：掌握了不回队（今天结束），否则排到队尾今天还会再出现
    this.queue.splice(this.queueIndex, 1);
    if (cur !== undefined && !mastered) {
      this.queue.push(cur);
    }
    this.pendingConfirm = false;
    this.pendingMastered = false;
    this.confirmStreak = 0;
    this.pendingKind = -1;
    this.nextCard();
    this.saveSession();
  }

  /** 确认卡上的「记错了」：按忘了处理（streak 清零、排队尾）。 */
  private markWrong(): void {
    const c = this.ctx();
    const cur: ReviewCard | undefined =
      this.queueIndex < this.queue.length ? this.queue[this.queueIndex] : undefined;
    if (c !== null && cur !== undefined) {
      cur.streak = 0;
      try {
        const all: ReviewCard[] = ReviewCardStore.load(c);
        for (let k = 0; k < all.length; k++) {
          if (all[k].id === cur.id) {
            ReviewCardStore.grade(all[k], 0);
            break;
          }
        }
        ReviewCardStore.save(c, all);
        this.cards = all;
      } catch (err) {
        // 忽略
      }
    }
    this.queue.splice(this.queueIndex, 1);
    if (cur !== undefined) {
      this.queue.push(cur);
    }
    this.pendingConfirm = false;
    this.pendingMastered = false;
    this.confirmStreak = 0;
    this.pendingKind = -1;
    this.nextCard();
    this.saveSession();
  }

  /** 会话进度写入待存标记（saveStats 序列化当前队列）。 */
  private saveSession(): void {
    this.statDirty = true;
    this.saveStats();
  }

  /** 推进到下一张：队列空了就结束本轮（回到主页，会话一并清除）。 */
  private nextCard(): void {
    this.flipped = false;
    this.hintText = '';
    if (this.queue.length === 0) {
      // **背完了：进入完成界面**（用户要求专门设计展示），
      // 并兜底签到 +（用户反馈：背完没自动签到）。完成界面留在本页展示。
      this.finished = true;
      this.ensureSignedToday();
      this.syncFlashFlag();
      // 强制落盘：清掉文件里的旧会话（背完了不该在重开时恢复）
      this.statDirty = true;
      this.saveStats();
      return;
    }
    if (this.queueIndex >= this.queue.length) {
      this.queueIndex = 0;
    }
    this.saveSession();
  }

  /** 兜底：今天复习过（statTodayCount > 0）就确保今天已签。 */
  private ensureSignedToday(): void {
    const today: string = reviewDayKey(Date.now());
    if (this.statTodayCount > 0 && this.signDays.indexOf(today) < 0) {
      this.signDays.push(today);
    }
  }

  /** 完成界面上的「返回」：收尾回主页（复习卡片所在处）。 */
  private finishBack(): void {
    this.finished = false;
    this.reviewing = false;
    this.tab = 0;
    this.rebuildQueue();
    // 强制落盘：把文件里残留的旧会话清掉（否则重进会恢复已背完的会话）
    this.statDirty = true;
    this.saveStats();
    this.syncFlashFlag();
  }

  /**
   * 完成界面上的「继续学习」（用户要求：再来一遍 + 提前把明天的计划放到现在）——
   * 队列 = 今天到期 + 明天到期（含今天掌握后明天才到期的卡），重新开始一轮。
   */
  private startExtraRound(): void {
    const horizon: number = Date.now() + 2 * 24 * 60 * 60 * 1000;
    const out: ReviewCard[] = [];
    for (let k = 0; k < this.cards.length; k++) {
      const card: ReviewCard = this.cards[k];
      if (card.due <= horizon && (this.selected.length === 0
        || this.selected.indexOf(card.docName) >= 0)) {
        out.push(card);
      }
    }
    if (out.length === 0) {
      try {
        this.getUIContext().getPromptAction().showToast({
          message: L10n.t('暂时没有可提前的卡片'), duration: 1800
        });
      } catch (err) {
        // 忽略
      }
      return;
    }
    this.queue = out;
    this.queueTotal = out.length;
    this.queueIndex = 0;
    this.flipped = false;
    this.hintText = '';
    this.sessionMastered = 0;
    this.finished = false;
    this.reviewing = true;
    this.syncFlashFlag();
    this.saveSession();
  }

  // ────────────────────────── 统计与签到 ──────────────────────────

  private statsPath(): string {
    const c = this.ctx();
    return c !== null ? c.filesDir + '/review_stats.json' : '';
  }

  private loadStats(): void {
    const path: string = this.statsPath();
    if (path.length === 0) {
      return;
    }
    try {
      const text: string = fs.readTextSync(path);
      const obj: ReviewStatsFile = JSON.parse(text) as ReviewStatsFile;
      const today: string = reviewDayKey(Date.now());
      if (obj.todayKey === today) {
        this.statTodayCount = obj.todayCount;
        this.statTodaySeconds = obj.todaySeconds;
        // **签到兜底**：今天有复习记录就确保今天已签（用户反馈背完没自动签到）
        if (obj.todayCount > 0 && this.signDays.indexOf(today) < 0) {
          this.signDays.push(today);
        }
      } else {
        this.statTodayCount = 0;
        this.statTodaySeconds = 0;
      }
      this.statTotalCount = obj.totalCount;
      this.statTotalSeconds = obj.totalSeconds;
      this.signDays = obj.signDays !== undefined ? obj.signDays : [];
      // 每日目标（自定义，用户要求）；非法值兜底为 20
      this.dailyGoal = obj.dailyGoal !== undefined && obj.dailyGoal >= 1
        ? Math.round(obj.dailyGoal) : 20;
      // **恢复未完成的会话**（用户要求：临时退出后接着背）：
      // 按 id 把剩余队列映射回卡片（已不存在的卡跳过），直接进入刷卡形态。
      if (obj.session !== undefined && obj.session.ids.length > 0) {
        const restored: ReviewCard[] = [];
        for (let k = 0; k < obj.session.ids.length; k++) {
          for (let j = 0; j < this.cards.length; j++) {
            if (this.cards[j].id === obj.session.ids[k]) {
              restored.push(this.cards[j]);
              break;
            }
          }
        }
        if (restored.length > 0) {
          this.queue = restored;
          this.queueTotal = obj.session.total;
          this.queueIndex = Math.min(obj.session.index, restored.length - 1);
          this.sessionMastered = obj.session.mastered;
          this.reviewing = true;
          // ⚠️ 会话恢复后必须同步侧滑返回旗标（reviewFlashOn）——
          // 恢复的会话不走 startReview，漏了这步旗标就是 false，
          // 侧滑返回会把整个页面弹掉、落回文房页（用户反馈）。
          this.syncFlashFlag();
        }
      }
    } catch (err) {
      // 首次使用没有文件
    }
  }

  private saveStats(): void {
    const path: string = this.statsPath();
    if (path.length === 0 || !this.statDirty) {
      return;
    }
    try {
      const obj: ReviewStatsFile = {
        todayKey: reviewDayKey(Date.now()),
        todayCount: this.statTodayCount,
        todaySeconds: this.statTodaySeconds,
        totalCount: this.statTotalCount,
        totalSeconds: this.statTotalSeconds,
        signDays: this.signDays,
        dailyGoal: this.dailyGoal
      };
      // **会话持久化**（用户要求：临时退出也要记住背完的与没背完的）——
      // 复习中就把剩余队列（卡 id）与进度写进文件，重进页面时恢复。
      if (this.reviewing && this.queue.length > 0) {
        const ids: string[] = [];
        for (let k = 0; k < this.queue.length; k++) {
          ids.push(this.queue[k].id);
        }
        obj.session = {
          ids: ids,
          index: this.queueIndex,
          mastered: this.sessionMastered,
          total: this.queueTotal
        };
      }
      // ⚠️ **必须带 TRUNC**（记录消失的 bug 根因）：不带截断的写入若新内容比旧的短，
      // 文件尾部会残留旧字节 → JSON 损坏 → 下次启动解析失败 → 统计与签到全部清零。
      const file = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(obj));
      fs.closeSync(file.fd);
      this.statDirty = false;
    } catch (err) {
      // 落盘失败下次再试
    }
  }

  private bumpStats(): void {
    this.statTodayCount = this.statTodayCount + 1;
    this.statTotalCount = this.statTotalCount + 1;
    const today: string = reviewDayKey(Date.now());
    if (this.signDays.indexOf(today) < 0) {
      this.signDays.push(today);
    }
    this.statDirty = true;
    this.saveStats();
  }

  /** 连续签到天数：从今天（今天没签就从昨天）往回数连续有签的天数。 */
  private streakSignDays(): number {
    let streak: number = 0;
    const cur: Date = new Date();
    if (this.signDays.indexOf(reviewDayKey(cur.getTime())) < 0) {
      cur.setDate(cur.getDate() - 1);
    }
    while (this.signDays.indexOf(reviewDayKey(cur.getTime())) >= 0) {
      streak++;
      cur.setDate(cur.getDate() - 1);
      if (streak > 3650) {
        break;
      }
    }
    return streak;
  }

  private isSigned(dayKey: string): boolean {
    return this.signDays.indexOf(dayKey) >= 0;
  }

  private isTodayKey(key: string): boolean {
    return key === reviewDayKey(Date.now());
  }

  /** 指定年月的日历格子（周一开头）：前导空串 + 每天的 dayKey。 */
  private calendarCells(year: number, month: number): string[] {
    const first: Date = new Date(year, month, 1);
    const days: number = new Date(year, month + 1, 0).getDate();
    // 周一开头：getDay() 0=周日 → 偏移 (getDay()+6)%7
    const lead: number = (first.getDay() + 6) % 7;
    const cells: string[] = [];
    for (let k = 0; k < lead; k++) {
      cells.push('');
    }
    for (let d = 1; d <= days; d++) {
      const m: string = (month + 1) < 10 ? '0' + (month + 1) : '' + (month + 1);
      const dd: string = d < 10 ? '0' + d : '' + d;
      cells.push(year + '-' + m + '-' + dd);
    }
    return cells;
  }

  // ────────────────────────── 遗忘曲线辅助 ──────────────────────────

  private bucketOf(interval: number): number {
    for (let b = 0; b < BUCKETS.length; b++) {
      if (interval <= BUCKETS[b].maxDays) {
        return b;
      }
    }
    return BUCKETS.length - 1;
  }

  private bucketCounts(): number[] {
    const out: number[] = [];
    for (let b = 0; b < BUCKETS.length; b++) {
      out.push(0);
    }
    for (let k = 0; k < this.cards.length; k++) {
      const at: number = this.bucketOf(this.cards[k].interval);
      out[at] = out[at] + 1;
    }
    return out;
  }

  private filteredCards(): ReviewCard[] {
    if (this.selected.length === 0) {
      return this.cards;
    }
    const out: ReviewCard[] = [];
    for (let k = 0; k < this.cards.length; k++) {
      for (let s = 0; s < this.selected.length; s++) {
        if (this.selected[s] === this.cards[k].docName) {
          out.push(this.cards[k]);
          break;
        }
      }
    }
    return out;
  }

  private fmtDue(ms: number): string {
    if (ms <= 0) {
      return '未排期';
    }
    const d: Date = new Date(ms);
    return (d.getMonth() + 1) + '-' + d.getDate();
  }

  /** 提示内容：批注（背面）的前 40%，没有批注就给高亮文本的前一半。 */
  private showHint(): void {
    if (this.queueIndex >= this.queue.length) {
      return;
    }
    const card: ReviewCard = this.queue[this.queueIndex];
    if (card.back.length > 0) {
      const cut: number = Math.max(4, Math.round(card.back.length * 0.4));
      this.hintText = '批注开头：' + card.back.substring(0, cut)
        + (cut < card.back.length ? '…' : '');
    } else {
      const cut: number = Math.max(2, Math.round(card.front.length * 0.5));
      this.hintText = '原文开头：' + card.front.substring(0, cut)
        + (cut < card.front.length ? '…' : '');
    }
    // **2 秒后自动消失**（用户要求）：重复点击会重置计时
    if (this.hintTimer !== -1) {
      clearTimeout(this.hintTimer);
    }
    this.hintTimer = setTimeout(() => {
      this.hintText = '';
      this.hintTimer = -1;
    }, 2000);
  }

  private human(seconds: number): string {
    if (seconds < 60) {
      return seconds + ' 秒';
    }
    if (seconds < 3600) {
      return Math.round(seconds / 60) + ' 分钟';
    }
    return (seconds / 3600).toFixed(1) + ' 小时';
  }

  // ────────────────────────── 界面 ──────────────────────────

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ── 背景：与书架同一套优先级 ──
      if (this.wallpaperPathEffective().length > 0) {
        // 整屏壁纸走 WallpaperImage：模糊**预烘成位图**，转场期间不再每帧重算
        WallpaperImage({ path: this.wallpaperPathEffective(), radiusVp: this.wallpaperBlur })
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.isDark()))
      } else if (this.genWallId.length > 0) {
        GenWallpaper({ styleId: this.genWallId, darkMode: this.isDark() })
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.isDark()))
      } else if (this.pageBackground().length > 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.pageBackground())
      } else {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [[this.palette().pageTop, 0.0], [this.palette().pageBottom, 1.0]]
          })
      }

      if (this.reviewing) {
        // ── 全屏刷卡形态；背完进入**完成界面**（用户要求专门设计）──
        // 进出背诵带过渡（用户要求：凡事有动画）：进入自下而上淡入、退出淡出
        Column() {
          if (this.finished) {
            this.finishedView()
          } else {
            this.flashView()
          }
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.OPACITY.animation(AppearanceFx.anim(260, Curve.FastOutSlowIn))
            .combine(TransitionEffect.translate({ y: 36 })),
          TransitionEffect.OPACITY.animation(AppearanceFx.anim(200, Curve.FastOutSlowIn))
            .combine(TransitionEffect.translate({ y: 18 }))
        ))
      } else {
        // ── 学习主页 / 统计（悬浮胶囊顶栏 + 分段页签）──
        Column() {
        Column() {
          // 悬浮顶栏：返回 + 分段页签（用户要求：与其他页面一样悬浮顶栏）。
          // ⚠️ 顶栏写在 Scroll **之后**并且 zIndex(2)：写在前面会被后声明的 Scroll
          // 盖住（图层顺序 = 声明顺序），顶栏就成了"垫在内容底下"（真机反馈图层错误）。
          Row() {
            ImmersiveBar({
              palette: this.palette(),
              barPaddingH: HwSpace.sm,
              barPaddingV: 4,
              barHeight: HwBar.pill,
              barWidth: '100%'
            }) {
              Row({ space: HwSpace.xs }) {
                ImmersiveIconButton({
                  buttonSize: 36,
                  buttonMaterialShadow: false,
                  palette: this.palette(),
                  buttonOnTap: () => {
                    if (this.stack !== null) {
                      this.stack.pop(AppearanceFx.navAnimated());
                    }
                  }
                }) {
                  SymbolGlyph($r('sys.symbol.chevron_left'))
                    .fontSize(20)
                    .fontColor([this.palette().textPrimary])
                }

                // 分段页签：学习 / 统计（**沉浸光感 chip**，用户要求）
                Row({ space: HwSpace.xs }) {
                  ImmersiveChip({
                    palette: this.palette(),
                    chipActive: this.tab === 0,
                    chipLabel: L10n.t('学习'),
                    chipOnTap: () => {
                      this.tab = 0;
                      this.reviewSwiper.changeIndex(0, true);
                    }
                  })
                  ImmersiveChip({
                    palette: this.palette(),
                    chipActive: this.tab === 1,
                    chipLabel: L10n.t('统计'),
                    chipOnTap: () => {
                      this.tab = 1;
                      this.reviewSwiper.changeIndex(1, true);
                    }
                  })
                }
                .alignItems(VerticalAlign.Center)

                Blank()
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }
          }
          .width('100%')
          .padding({ left: HwSpace.lg, right: HwSpace.lg })
          .position({ x: 0, y: this.safeTopVp() + HwSpace.sm })
          .hitTestBehavior(HitTestMode.Transparent)
          // 顶栏浮在滚动内容之上（图层错误修复的第二道保险）
          .zIndex(2)

          // ── 学习 / 统计两页：**左右滑动切换**（用户要求）＋ 页签点击同步 ──
          Swiper(this.reviewSwiper) {
            // 页 1：学习主页
            Scroll() {
              Column({ space: HwSpace.lg }) {
                this.homeTab()
              }
              .width('100%')
              .padding({
                left: HwSpace.lg,
                right: HwSpace.lg,
                top: this.safeTopVp() + HwBar.pill + HwSpace.lg,
                bottom: this.padBottom() + HwSpace.xxl
              })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .height('100%')
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .align(Alignment.Top)

            // 页 2：统计
            Scroll() {
              Column({ space: HwSpace.lg }) {
                this.statsTab()
              }
              .width('100%')
              .padding({
                left: HwSpace.lg,
                right: HwSpace.lg,
                top: this.safeTopVp() + HwBar.pill + HwSpace.lg,
                bottom: this.padBottom() + HwSpace.xxl
              })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .height('100%')
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .align(Alignment.Top)
          }
          .width('100%')
          .layoutWeight(1)
          .loop(false)
          .indicator(false)
          .index(this.tab)
          .duration(260)
          .onChange((index: number) => {
            this.tab = index;
          })
        }
        .width('100%')
        .height('100%')
        }
        .width('100%')
        .height('100%')
        // 返回学习主页：淡入（与进入背诵的转场对称）
        .transition(TransitionEffect.OPACITY.animation(AppearanceFx.anim(220, Curve.FastOutSlowIn)))
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 分节标题（「计划」「统计」式的小节头）。 */
  @Builder
  sectionHead(title: string) {
    Text(title)
      .fontFamily(HwFont.resolve(this.uiFontKey))
      .fontSize(HwFont.sx(HwType.label + 3, this.uiFontScale))
      .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
      .fontColor(this.palette().textPrimary)
      .width('100%')
      .margin({ top: HwSpace.xs })
  }

  /** 学习主页：计划（选文档）→ 概览 2×2 → 签到日历。 */
  @Builder
  homeTab() {
    // ── 计划：选文档 + 开始复习 ──
    this.sectionHead('计划')
    ImmersiveCard({
      cardRadius: HwRadius.card,
      cardPadding: HwSpace.lg,
      palette: this.palette()
    }) {
      Column({ space: HwSpace.sm }) {
        if (this.docNames.length === 0) {
          Text(L10n.t('还没有复习卡片 —— 在文档里划选文字，选「学习卡」并写上内容，这里就会生成卡片。'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwType.label * 1.7)
            .width('100%')
        } else {
          // **书籍封面横排**（用户要求：展示有学习卡的书的封面），点封面选中 / 取消
          Scroll() {
            Row({ space: HwSpace.md }) {
              ForEach(this.planMetas, (meta: DocMeta, index: number) => {
                Column({ space: 4 }) {
                  Stack({ alignContent: Alignment.TopEnd }) {
                    Column() {
                      DocCover({
                        title: meta.name,
                        builtin: meta.builtin,
                        coverTop: coverColorsOf(meta.name, meta.builtin).top,
                        coverBottom: coverColorsOf(meta.name, meta.builtin).bottom,
                        coverInk: coverColorsOf(meta.name, meta.builtin).ink,
                        edgeColor: this.selected.indexOf(meta.name) >= 0
                          ? this.palette().accent : this.palette().divider,
                        coverColor: meta.coverColor,
                        coverImage: meta.coverImage,
                        hideName: true,
                        // 迷你封面按比例收紧圆角（5/13 的大圆角在 56vp 上不协调）
                        smallCorners: true
                      })
                    }
                    .width(56)
                    .aspectRatio(0.72)

                    // 选中角标（用户指定图标：Edge checkmark.svg）
                    if (this.selected.indexOf(meta.name) >= 0) {
                      Column() {
                        Image($r('app.media.checkmark'))
                          .width(12)
                          .height(12)
                          .fillColor('#FFFFFFFF')
                          .draggable(false)
                      }
                      .width(16)
                      .height(16)
                      .borderRadius(8)
                      .backgroundColor(this.palette().accent)
                      .margin(3)
                      .justifyContent(FlexAlign.Center)
                      .alignItems(HorizontalAlign.Center)
                    }
                  }
                  .width(56)

                  // **书籍标题**（用户要求：要能滚动）—— 溢出自动跑马灯播放
                  Text(meta.name)
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                    .fontColor(this.palette().textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.MARQUEE })
                    .width(64)
                    .textAlign(TextAlign.Center)

                  Text(this.docCounts[index] + ' 张')
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(HwType.caption - 1, this.uiFontScale))
                    .fontColor(this.palette().textTertiary)
                }
                .alignItems(HorizontalAlign.Center)
                .onClick(() => {
                  this.toggleDoc(meta.name);
                })
              }, (meta: DocMeta) => 'pl_' + meta.name)
            }
            // **靠左显示**（用户要求，参考背单词计划卡）：不加多余偏移
            .justifyContent(FlexAlign.Start)
            .padding({ left: 2, right: 2, top: 4, bottom: 4 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .align(Alignment.Start)

          // **当日计划完成提示**（用户要求）：队列已空且今天背过 → 明确告知
          if (this.queue.length === 0 && this.statTodayCount > 0) {
            Row({ space: HwSpace.xs }) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(13)
                .fontColor(['#FF1F9E66'])
              Text(L10n.t('当日计划已完成，明天继续！想加练可点下方开始复习'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                .fontColor('#FF1F9E66')
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }

          Text(this.selected.length > 0
            ? L10n.t('已选 ') + this.selected.length + ' 篇 · ' + this.queue.length + ' 张到期'
            : (this.queue.length === 0 && this.statTodayCount > 0
              ? L10n.t('开始下一轮加练，或明天继续！')
              : L10n.t('未筛选：全部 ') + this.docNames.length + ' 篇 · ' + this.queue.length + ' 张到期'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .width('100%')

          // ── 每日目标（用户要求：自定义每天学习几条，计算剩余时间）──
          Row({ space: HwSpace.sm }) {
            Text(L10n.t('每日复习'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
              .fontColor(this.palette().textPrimary)
            Blank()
            Row({ space: HwSpace.xs }) {
              ImmersiveIconButton({
                buttonSize: 28,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.setDailyGoal(this.dailyGoal - 5);
                }
              }) {
                SymbolGlyph($r('sys.symbol.minus'))
                  .fontSize(13)
                  .fontColor([this.palette().textPrimary])
              }
              Text(this.dailyGoal + ' 条')
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
                .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
                .fontColor(this.palette().textPrimary)
                .width(52)
                .textAlign(TextAlign.Center)
              ImmersiveIconButton({
                buttonSize: 28,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.setDailyGoal(this.dailyGoal + 5);
                }
              }) {
                SymbolGlyph($r('sys.symbol.plus'))
                  .fontSize(13)
                  .fontColor([this.palette().textPrimary])
              }
            }
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 剩余计算：今日达标差额 + 按目标节奏的预计天数
          Text(this.remainingHint())
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .width('100%')
        }

        // ── 复习模式（**提前在外面选好**，不进背诵再切）：互换 / 拼写 ──
        Row({ space: HwSpace.xs }) {
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: L10n.t('互换'),
            chipActive: this.swapMode,
            chipOnTap: () => {
              this.toggleSwapMode();
            }
          })
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: L10n.t('拼写'),
            chipActive: this.typingMode,
            chipOnTap: () => {
              this.toggleTypingMode();
            }
          })
          Text(L10n.t('拼写模式下输入与隐藏内容完全一致才通过'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 开始复习：主行动按钮（沉浸光感 chip，**放大一号**，用户要求）
        Row({ space: HwSpace.sm }) {
          Blank()
          ImmersiveChip({
            palette: this.palette(),
            chipTint: this.palette().accent,
            chipActive: true,
            chipFontSize: 16,
            chipPaddingH: HwSpace.lg + 4,
            chipPaddingV: HwSpace.sm + 2,
            chipLabel: this.queue.length > 0
              ? L10n.t('开始复习 · ') + this.queue.length + ' 张到期'
              : L10n.t('开始复习'),
            chipOnTap: () => {
              this.startReview();
            }
          })
          Blank()
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }

    // ── 统计：概览 2×2 ──
    this.sectionHead('统计')
    ImmersiveCard({
      cardRadius: HwRadius.card,
      cardPadding: HwSpace.lg,
      palette: this.palette()
    }) {
      Column({ space: HwSpace.md }) {
        Row({ space: HwSpace.sm }) {
          this.statCell2x2(this.statTodayCount + '', '今日复习条数', '#FF1F9E66')
          this.statCell2x2(this.statTotalCount + '', '累计复习条数', '#FF2F63E8')
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        Row({ space: HwSpace.sm }) {
          this.statCell2x2(this.human(this.statTodaySeconds), '今日时长', '#FFE08000')
          this.statCell2x2(this.human(this.statTotalSeconds), '累计时长', '#FF8A5AF0')
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }

    // ── 签到日历（当月简版，可翻月的完整版在统计页签）──
    this.sectionHead('签到日历')
    ImmersiveCard({
      cardRadius: HwRadius.card,
      cardPadding: HwSpace.lg,
      palette: this.palette()
    }) {
      Column({ space: HwSpace.sm }) {
        Row({ space: HwSpace.sm }) {
          Text(L10n.t('连续签到 ') + this.streakSignDays() + ' 天')
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontColor(this.palette().accent)
          Blank()
          Text(L10n.t('累计 ') + this.signDays.length + ' 天')
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontColor(this.palette().textSecondary)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        this.calendarGrid(this.viewYear, this.viewMonth)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 概览 2×2 的一个格子：色点 + 标签 + 大数字。 */
  @Builder
  statCell2x2(value: string, label: string, dotColor: string) {
    Column({ space: 3 }) {
      Row({ space: 4 }) {
        Column()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(dotColor)
        Text(label)
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
      }
      .alignItems(VerticalAlign.Center)
      Text(value)
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(HwType.label + 5, this.uiFontScale))
        .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
        .fontColor(this.palette().textPrimary)
        .maxLines(1)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /** 月历格子网格（周一起始），year/month 决定哪个月。 */
  @Builder
  calendarGrid(year: number, month: number) {
    Row() {
      ForEach(['一', '二', '三', '四', '五', '六', '日'], (w: string) => {
        Text(w)
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwType.caption - 2)
          .fontColor(this.palette().textTertiary)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
      }, (w: string) => 'wh_' + w)
    }
    .width('100%')

    Grid() {
      ForEach(this.calendarCells(year, month), (cell: string) => {
        GridItem() {
          Column() {
            if (cell.length > 0) {
              // ⚠️ 圆片**固定尺寸**：此前格子是 width('100%')+aspectRatio(1) 的正方形，
              // 大屏 / 横屏下卡片一宽，格子就撑成大块（日历又大又稀疏、今日圆圈巨大）——
              // 固定 30 的圆片 + 固定 32 的行高，任何宽度下密度都一致（用户要求）。
              Column() {
                Text(cell.substring(cell.length - 2))
                  .fontSize(HwType.caption)
                  .fontWeight(this.isTodayKey(cell) ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(this.isSigned(cell)
                    ? '#FFFFFFFF'
                    : (this.isFutureKey(cell, year, month)
                      ? this.palette().textTertiary
                      : (this.isTodayKey(cell)
                        ? this.palette().accent : this.palette().textPrimary)))
              }
              .width(30)
              .height(30)
              .borderRadius(15)
              .backgroundColor(this.isSigned(cell) ? this.palette().accent : '#00000000')
              .border({
                width: this.isTodayKey(cell) && !this.isSigned(cell) ? 1.5 : 0,
                color: this.palette().accent
              })
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
            }
          }
          .width('100%')
          .height(32)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }
      }, (cell: string) => 'cal_' + year + '_' + month + '_' + cell)
    }
    .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr')
    .rowsGap(2)
    .columnsGap(2)
    .width('100%')
  }

  /** 该格子是否是未来的日子（还没到，置灰）。 */
  private isFutureKey(key: string, year: number, month: number): boolean {
    const now: Date = new Date();
    if (year > now.getFullYear()) {
      return true;
    }
    if (year === now.getFullYear() && month > now.getMonth()) {
      return true;
    }
    return year === now.getFullYear() && month === now.getMonth()
      && parseInt(key.substring(key.length - 2), 10) > now.getDate();
  }

  /** 统计页签：遗忘曲线 + 每张卡到期 + 签到日历（可翻月）。 */
  @Builder
  statsTab() {
    this.sectionHead('遗忘曲线')
    ImmersiveCard({
      cardRadius: HwRadius.card,
      cardPadding: HwSpace.lg,
      palette: this.palette()
    }) {
      Column({ space: HwSpace.sm }) {
        Text(L10n.t('卡片按复习间隔分布（SM-2：忘了回 1 天，记得按难度系数拉长间隔）'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
          .width('100%')
        ForEach(this.bucketCounts(), (count: number, index: number) => {
          Row({ space: HwSpace.sm }) {
            Text(BUCKETS[index].label)
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textSecondary)
              .width(52)
            Stack({ alignContent: Alignment.Start }) {
              Column()
                .width('100%')
                .height(10)
                .borderRadius(5)
                .backgroundColor(this.palette().divider)
              Column()
                .width(this.cards.length > 0
                  ? (count * 100 / this.cards.length).toString() + '%' : '0%')
                .height(10)
                .borderRadius(5)
                .backgroundColor(this.palette().accent)
                .animation(AppearanceFx.anim(300, Curve.FastOutSlowIn))
            }
            .layoutWeight(1)
            .height(10)
            Text(count + ' 张')
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textSecondary)
              .width(44)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }, (count: number, index: number) => 'bk_' + index + '_' + count)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }

    this.forgettingCurveCard()

    this.sectionHead('每张卡的下次到期')
    ImmersiveCard({
      cardRadius: HwRadius.card,
      cardPadding: HwSpace.lg,
      palette: this.palette()
    }) {
      Column({ space: HwSpace.xs }) {
        Scroll() {
          Column({ space: HwSpace.xs }) {
            ForEach(this.filteredCards(), (card: ReviewCard) => {
              Row({ space: HwSpace.sm }) {
                Text(card.front)
                  .fontSize(HwType.label)
                  .fontColor(this.palette().textPrimary)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                // 固定宽 + 右对齐：两列文本上下对齐（用户反馈长短不齐）
                Text(L10n.t('间隔 ') + card.interval + ' 天')
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                  .fontColor(this.palette().textTertiary)
                  .width(70)
                  .textAlign(TextAlign.End)
                Text(this.fmtDue(card.due))
                  .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                  .fontColor(card.due <= Date.now() ? '#FFD95B3B' : this.palette().accent)
                  .width(46)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }, (card: ReviewCard) => 'fc_' + card.id + '_' + card.interval)
          }
          .width('100%')
        }
        .constraintSize({ maxHeight: 300 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }

    this.sectionHead('签到日历')
    ImmersiveCard({
      cardRadius: HwRadius.card,
      cardPadding: HwSpace.lg,
      palette: this.palette()
    }) {
      Column({ space: HwSpace.sm }) {
        // 月份翻页：< 2026年10月 >
        Row({ space: HwSpace.xs }) {
          ImmersiveIconButton({
            buttonSize: 28,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              this.shiftMonth(-1);
            }
          }) {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(13)
              .fontColor([this.palette().textSecondary])
          }
          Text(this.viewYear + ' 年 ' + (this.viewMonth + 1) + ' 月')
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
            .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
            .fontColor(this.palette().textPrimary)
          ImmersiveIconButton({
            buttonSize: 28,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              this.shiftMonth(1);
            }
          }) {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(13)
              .fontColor([this.palette().textSecondary])
          }
          Blank()
          Text(L10n.t('连续 ') + this.streakSignDays() + ' 天 · 累计 ' + this.signDays.length + ' 天')
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        this.calendarGrid(this.viewYear, this.viewMonth)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 签到日历翻月。 */
  private shiftMonth(delta: number): void {
    let m: number = this.viewMonth + delta;
    let y: number = this.viewYear;
    if (m < 0) {
      m = 11;
      y--;
    } else if (m > 11) {
      m = 0;
      y++;
    }
    this.viewMonth = m;
    this.viewYear = y;
  }

  /**
   * **完成界面**（用户要求专门设计并优化）：紧凑居中布局 ——
   * 大对勾 + 标题 + **无卡片包裹**的 2×2 成果格 + 返回按钮。
   * 之前用 ImmersiveCard 包统计会莫名被拉伸成巨长卡片（真机截图），这里不再用卡。
   */
  @Builder
  finishedView() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: HwSpace.xl }) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width(84)
            .height(84)
            .borderRadius(42)
            .backgroundColor(this.palette().accentSoft)
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(44)
            .fontWeight(FontWeight.Bold)
            .fontColor([this.palette().accent])
        }

        Text(L10n.t('本轮复习完成'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.label + 6, this.uiFontScale))
          .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
          .fontColor(this.palette().textPrimary)

        // 成果 2×2：直接排在背景上（不用卡片包裹，避免被拉伸）
        Column({ space: HwSpace.md }) {
          Row({ space: HwSpace.sm }) {
            this.statCell2x2(this.sessionMastered + '', '本次掌握', '#FF1F9E66')
            this.statCell2x2(this.statTodayCount + '', '今日复习条数', '#FF2F63E8')
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)

          Row({ space: HwSpace.sm }) {
            this.statCell2x2(this.human(this.statTodaySeconds), '今日时长', '#FFE08000')
            this.statCell2x2(this.human(this.statTotalSeconds), '累计时长', '#FF8A5AF0')
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        .width('100%')
        .padding({
          left: HwSpace.lg,
          right: HwSpace.lg,
          top: HwSpace.md,
          bottom: HwSpace.md
        })
        .borderRadius(HwRadius.card)
        .backgroundColor(this.palette().quoteBg)
        .alignItems(HorizontalAlign.Start)

        Text(L10n.t('已背的卡片按遗忘曲线排期，到期的日子会再和你见面。'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
          .textAlign(TextAlign.Center)
          .width('100%')

        Text(L10n.t('返回'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.label + 2, this.uiFontScale))
          .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
          .fontColor('#FFFFFFFF')
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: HwSpace.sm + 2, bottom: HwSpace.sm + 2 })
          .borderRadius(HwRadius.pill)
          .backgroundColor(this.palette().accent)
          .onClick(() => {
            this.finishBack();
          })

        // 继续学习：再来一遍，并**提前把明天的计划放到现在**（用户要求）
        Text(L10n.t('继续学习 · 提前明天的计划'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
          .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
          .fontColor(this.palette().accent)
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: HwSpace.sm + 2, bottom: HwSpace.sm + 2 })
          .borderRadius(HwRadius.pill)
          .border({ width: 1.5, color: this.palette().accent })
          .onClick(() => {
            this.startExtraRound();
          })
      }
      .width('82%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }

  /** 调整每日目标（下限 5、上限 200，步进 5）。 */
  private setDailyGoal(goal: number): void {
    const clamped: number = Math.min(200, Math.max(5, goal));
    if (clamped === this.dailyGoal) {
      return;
    }
    this.dailyGoal = clamped;
    this.statDirty = true;
    this.saveStats();
  }

  /** 剩余计算提示：今日达标差额 + 按目标节奏的预计天数。 */
  private remainingHint(): string {
    const todayLeft: number = Math.max(0, this.dailyGoal - this.statTodayCount);
    let pending: number = 0;
    for (let k = 0; k < this.cards.length; k++) {
      if (this.cards[k].due <= Date.now() || this.cards[k].reps === 0) {
        pending++;
      }
    }
    const days: number = this.dailyGoal > 0 ? Math.ceil(pending / this.dailyGoal) : 0;
    return '今日还差 ' + todayLeft + ' 条达标 · 待背 ' + pending
      + ' 张，按此节奏约 ' + days + ' 天背完';
  }

  /** 全屏刷卡形态（参考背单词的刷词页：大字居中 + 底部三色大按钮）。 */
  @Builder
  flashView() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column() {
        // ── 卡面内容：**包 Scroll**，长批注也能滚动看完（用户要求"文本要能滚动"）──
        // 顶部让位：悬浮胶囊顶栏（safeTop + 胶囊高），内容从其下方穿过
        Scroll() {
        if (this.pendingConfirm) {
          Column({ space: HwSpace.lg }) {
            // 标题行：记得才有**竖向 3 灯**（记得一次亮一颗，3 颗全亮 = 通过）
            Row({ space: HwSpace.sm }) {
              Text(this.pendingKind === 2
                ? L10n.t('记忆确认 · 连续第 ') + this.confirmStreak + ' 次「记得」'
                : (this.pendingKind === 1 ? L10n.t('模糊 · 再看一遍内容') : L10n.t('忘了 · 再学一遍内容')))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
                .fontColor(this.palette().textSecondary)
              Blank()
              if (this.pendingKind === 2) {
                Column({ space: 4 }) {
                  ForEach([2, 1, 0], (dot: number) => {
                    Column()
                      .width(8)
                      .height(8)
                      .borderRadius(4)
                      .backgroundColor(this.confirmStreak > dot
                        ? this.palette().accent : this.palette().divider)
                  }, (dot: number) => 'lamp_' + dot + '_' + this.confirmStreak)
                }
                .alignItems(HorizontalAlign.Center)
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            // **卡面公式渲染**（用户要求）：学习卡内容含公式（公式菜单 → 学习卡的
            // 裸 LaTeX / 正文划选的 $…$）→ 在卡面小区域直接渲染成公式图
            MathFormulaText({
              src: this.cardFront(),
              dark: this.isDark(),
              fontSize: HwType.label + 2,
              color: this.palette().textTertiary,
              textAlign: TextAlign.Start
            })

            if (this.queue[this.queueIndex].back.length > 0) {
              MathFormulaText({
                src: this.cardBack(),
                dark: this.isDark(),
                fontSize: HwType.label + 5,
                bold: true,
                color: this.palette().textPrimary,
                textAlign: TextAlign.Start
              })
            } else {
              Text(L10n.t('（这条批注没有写文字批注）'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.label + 5, this.uiFontScale))
                .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
                .fontColor(this.palette().textPrimary)
                .lineHeight((HwType.label + 5) * 1.6)
                .width('100%')
            }

            if (this.pendingKind === 2) {
              Text(this.pendingMastered
                ? L10n.t('✓ 3 灯全亮，已通过！之后按遗忘曲线排期')
                : L10n.t('还差 ') + (3 - this.confirmStreak) + ' 次「记得」通过，先继续下一张')
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                .fontColor(this.pendingMastered ? '#FF1F9E66' : this.palette().textTertiary)
                .width('100%')
            }
          }
          .width('100%')
          .padding({ left: HwSpace.lg, right: HwSpace.lg, top: this.safeTopVp() + HwBar.pill + HwSpace.xl })
          .alignItems(HorizontalAlign.Start)
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.OPACITY.animation(AppearanceFx.anim(240, Curve.FastOutSlowIn))
              .combine(TransitionEffect.translate({ y: 14 })),
            TransitionEffect.OPACITY.animation(AppearanceFx.anim(180, Curve.FastOutSlowIn))
          ))
        } else if (this.queueIndex < this.queue.length) {
          Column({ space: HwSpace.md }) {
            Text(this.queue[this.queueIndex].docName)
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
              .width('100%')
            // ── 文档标签（学习卡左上角展示，数量不限自适应换行）──
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.docTagsOf(this.queue[this.queueIndex].docName), (tag: string) => {
                Text('#' + tag)
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(HwType.caption - 1, this.uiFontScale))
                  .fontColor(this.palette().accent)
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                  .borderRadius(HwRadius.pill)
                  .border({ width: 1, color: this.palette().divider })
                  .margin({ right: HwSpace.xs, bottom: HwSpace.xs })
              }, (tag: string) => tag)
            }
            .width('100%')
            // **卡面公式渲染**（同上）：正面 = 原文（含公式时直接渲染）
            MathFormulaText({
              src: this.cardFront(),
              dark: this.isDark(),
              fontSize: HwType.label + 8,
              bold: true,
              color: this.palette().textPrimary,
              textAlign: TextAlign.Start
            })
            if (this.flipped) {
              if (this.cardBack().length > 0) {
                MathFormulaText({
                  src: this.cardBack(),
                  dark: this.isDark(),
                  fontSize: HwType.label + 3,
                  color: this.palette().accent,
                  textAlign: TextAlign.Start
                })
                .transition(TransitionEffect.OPACITY
                  .animation(AppearanceFx.anim(200, Curve.FastOutSlowIn)))
              } else {
                Text(L10n.t('（这条批注没有写文字批注 —— 回想一下当时为什么划它）'))
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(HwType.label + 3, this.uiFontScale))
                  .fontColor(this.palette().accent)
                  .lineHeight((HwType.label + 3) * 1.7)
                  .width('100%')
                  .transition(TransitionEffect.OPACITY
                    .animation(AppearanceFx.anim(200, Curve.FastOutSlowIn)))
              }
            }
            if (this.hintText.length > 0) {
              Text(this.hintText)
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                .fontColor(this.palette().accent)
                .width('100%')
                .transition(TransitionEffect.OPACITY
                  .animation(AppearanceFx.anim(200, Curve.FastOutSlowIn)))
            }
          }
          .width('100%')
          .padding({ left: HwSpace.lg, right: HwSpace.lg, top: this.safeTopVp() + HwBar.pill + HwSpace.xl })
          .alignItems(HorizontalAlign.Start)
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.OPACITY.animation(AppearanceFx.anim(240, Curve.FastOutSlowIn))
              .combine(TransitionEffect.translate({ y: 14 })),
            TransitionEffect.OPACITY.animation(AppearanceFx.anim(180, Curve.FastOutSlowIn))
          ))
          .onClick(() => {
            if (!this.typingMode) {
              this.flipped = !this.flipped;
            }
          })
        }
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)

      // ── 底部按钮区：确认态是「记错了 / 下一个」**大按钮**，否则三色大按钮 ──
      Column({ space: HwSpace.md }) {
        if (this.pendingConfirm) {
          if (this.hintText.length > 0) {
            Text(this.hintText)
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
              .textAlign(TextAlign.Center)
              .width('100%')
              .transition(TransitionEffect.OPACITY.animation(AppearanceFx.anim(200, Curve.FastOutSlowIn)))
          }
          // 沉浸光感大按钮：**居中排布、不贴屏幕边缘**（用户要求），材质由 chip 自带
          Row({ space: HwSpace.md }) {
            // 「记错了」：仅记得的确认卡有（给一次反悔机会，按忘了处理）
            if (this.pendingKind === 2) {
              Row() {
                ImmersiveChip({
                  palette: this.palette(),
                  chipTint: '#FFD32F2F',
                  chipActive: true,
                  chipFontSize: 17,
                  chipLabel: L10n.t('记错了'),
                  chipOnTap: () => {
                    this.markWrong();
                  }
                })
              }
              .layoutWeight(1)
              .justifyContent(FlexAlign.End)
            }
            Row() {
              ImmersiveChip({
                palette: this.palette(),
                chipTint: '#FF1F9E66',
                chipActive: true,
                chipFontSize: 17,
                chipLabel: L10n.t('下一个'),
                chipOnTap: () => {
                  this.confirmContinue();
                }
              })
            }
            .layoutWeight(1)
            // 单颗时也要**居中**（用户反馈：模糊/忘了的下一个跑左边去了）
            .justifyContent(this.pendingKind === 2 ? FlexAlign.Start : FlexAlign.Center)
          }
          .width('100%')
          .padding({ left: HwSpace.xl, right: HwSpace.xl })
        } else if (this.typingMode) {
          if (this.hintText.length > 0) {
            Text(this.hintText)
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
              .textAlign(TextAlign.Center)
              .width('100%')
              .transition(TransitionEffect.OPACITY.animation(AppearanceFx.anim(200, Curve.FastOutSlowIn)))
          }
          if (this.typeWrong) {
            Text(L10n.t('不对——正确内容已翻面显示，按「下一个」继续'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor('#FFD32F2F')
              .textAlign(TextAlign.Center)
              .width('100%')
              .transition(TransitionEffect.OPACITY.animation(AppearanceFx.anim(200, Curve.FastOutSlowIn)))
          }
          Row({ space: HwSpace.sm }) {
            TextInput({ text: this.typeInput, placeholder: L10n.t('输入隐藏的内容…') })
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .layoutWeight(1)
              .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
              .fontColor(this.palette().textPrimary)
              .placeholderColor(this.palette().textTertiary)
              .backgroundColor(this.palette().codeBlockBg)
              .borderRadius(HwRadius.pill)
              .onChange((value: string) => {
                this.typeInput = value;
              })
              .onSubmit(() => {
                this.submitTyping();
              })
          }
          .width('100%')
          Row({ space: HwSpace.sm }) {
            Row() {
              ImmersiveChip({
                palette: this.palette(),
                chipTint: '#FF1F9E66',
                chipActive: true,
                chipFontSize: 15,
                chipLabel: L10n.t('提交'),
                chipOnTap: () => {
                  this.submitTyping();
                }
              })
            }
            .layoutWeight(1)
            Row() {
              ImmersiveChip({
                palette: this.palette(),
                chipTint: '#FFE08000',
                chipActive: true,
                chipFontSize: 15,
                chipLabel: L10n.t('提示'),
                chipOnTap: () => {
                  this.getUIContext().animateTo(AppearanceFx.anim(200, Curve.FastOutSlowIn), () => {
                    this.flipped = true;
                  });
                }
              })
            }
            .layoutWeight(1)
            Row() {
              ImmersiveChip({
                palette: this.palette(),
                chipTint: '#FFD32F2F',
                chipActive: true,
                chipFontSize: 15,
                chipLabel: L10n.t('忘记了'),
                chipOnTap: () => {
                  this.typeInput = '';
                  this.typeWrong = false;
                  this.grade(0);
                }
              })
            }
            .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.sm })
        } else {
          if (this.hintText.length > 0) {
            Text(this.hintText)
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
              .textAlign(TextAlign.Center)
              .width('100%')
              .transition(TransitionEffect.OPACITY.animation(AppearanceFx.anim(200, Curve.FastOutSlowIn)))
          }
          Row() {
            this.flashButton('记得', '#FF1F9E66', 2)
            this.flashButton('模糊', '#FFE08000', 1)
            this.flashButton('忘了', '#FFD32F2F', 0)
          }
          .width('100%')
          .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.sm })
        }
      }
      .width('100%')
      .padding({
        left: HwSpace.lg,
        right: HwSpace.lg,
        bottom: this.padBottom() + HwSpace.lg
      })
      .hitTestBehavior(HitTestMode.Transparent)

      // ── 悬浮胶囊顶栏（用户要求：与其他页面同一套效果）：
      // 退出 + 进度 + **学习卡朗读**（speaker_wave_2 图标）+ 提示（绿色沉浸光感）。
      // ⚠️ 写在内容之后 + position + zIndex(2)：与学习主页顶栏同款图层方案。
      Row() {
        ImmersiveBar({
          palette: this.palette(),
          barPaddingH: HwSpace.sm,
          barPaddingV: 4,
          barHeight: HwBar.pill,
          barWidth: '100%'
        }) {
          Row({ space: HwSpace.xs }) {
            ImmersiveIconButton({
              buttonSize: 36,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.exitReview();
              }
            }) {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                .fontSize(20)
                .fontColor([this.palette().textPrimary])
            }
            Text(L10n.t('剩余 ') + this.queue.length + ' 张 · 已掌握 ' + this.sessionMastered + ' 张')
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
              .fontColor(this.palette().textSecondary)
              .layoutWeight(1)
              .maxLines(1)
            // **学习卡朗读**（系统文本转语音）：读单词 + 中文备注；再点一次停止
            ImmersiveIconButton({
              buttonSize: 32,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.speakCurrentCard();
              }
            }) {
              Image($r('app.media.speaker_wave_2'))
                .width(18)
                .height(18)
                .fillColor(this.ttsBusy ? this.palette().accent : this.palette().textPrimary)
                .draggable(false)
            }
            // 确认态（记得 / 模糊 / 忘了 之后）隐藏「提示」：此时卡面已展示全部内容
            if (!this.pendingConfirm) {
              ImmersiveChip({
                palette: this.palette(),
                chipTint: '#FF2E7D32',
                chipActive: true,
                chipLabel: L10n.t('提示'),
                chipOnTap: () => {
                  this.showHint();
                }
              })
              // 出现 / 消失带缩放淡入淡出过渡（用户要求：凡事有动画）
              .transition(TransitionEffect.asymmetric(
                TransitionEffect.OPACITY.animation(AppearanceFx.anim(200, Curve.FastOutSlowIn))
                  .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 })),
                TransitionEffect.OPACITY.animation(AppearanceFx.anim(160, Curve.FastOutSlowIn))
                  .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
              ))
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')
      .padding({ left: HwSpace.lg, right: HwSpace.lg })
      .position({ x: 0, y: this.safeTopVp() + HwSpace.sm })
      .hitTestBehavior(HitTestMode.Transparent)
      .zIndex(2)
    }
    .width('100%')
    .height('100%')
  }

  /** 刷卡页底部的大按钮：文字 + 同色圆点下划线（参考背单词的 认识/模糊/不认识）。 */
  @Builder
  flashButton(label: string, color: string, gradeValue: number) {
    Column({ space: 4 }) {
      Text(label)
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(HwType.label + 6, this.uiFontScale))
        .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
        .fontColor(color)
      Column()
        .width(18)
        .height(3)
        .borderRadius(2)
        .backgroundColor(color)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.grade(gradeValue);
    })
  }
}
