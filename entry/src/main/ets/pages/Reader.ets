/**
 * LiteMdReader · 阅读页
 * ======================
 *
 * 三件事构成本页的主体：
 *  ① 正文渲染（复用 MdParser + MdBlockView）
 *  ② 右滑呼出「目录」抽屉，左滑呼出「注释」抽屉
 *  ③ 阅读位置持久化（退出再进来回到上次的位置）
 *
 * 抽屉不用 bindSheet：半模态是从底部弹出的，而这里要的是左右侧滑，
 * 所以用 Stack 分层 + translate 位移实现，材质外壳仍复用 ImmersiveSheetPanel，
 * 保证抽屉的玻璃质感和卡片完全同源。
 */

import { TagStyle } from '../service/TagStyle';
import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import {
  ANNOTATION_COLORS,
  HwBar,
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  annotationColor,
  barFrostColor,
  FOLDER_SPRING,
  isDarkTheme,
  paletteFor,
  READER_BG_DEFAULT_DARK,
  READER_BG_DEFAULT_LIGHT,
  withAlpha
, LIGHT_PALETTE } from '../theme/DesignTokens';
import {
  ImmersiveBar,
  ImmersiveCard,
  ImmersiveCardLayer,
  ImmersiveChip,
  ImmersiveIconButton,
  ImmersiveSheetPanel
} from '../material/ImmersiveCard';
import { getImmersiveMaterial } from '../material/SystemMaterial';
import { modalSheetOptions, SheetKeyboardLift } from '../material/ModalSheet';
import { MdTable, TableAlign, TableTool } from '../service/TableTool';
import { TableEditorDialog } from '../components/TableEditorDialog';
import { AutoScrollTile } from '../components/AutoScrollTile';
import { ReadAloudTile } from '../components/ReadAloudTile';
import { ExportOptionsPanel } from '../components/ExportOptionsPanel';
import { ReadingSettingsPanel } from '../settings/ReadingSettings';
import { AnnotationStore } from '../service/AnnotationStore';
import { applySystemBarTheme, applyAppColorMode, setKeepScreenOn, setWindowBrightnessLevel,
  syncSystemDarkFromContext, markThemeApplied, themeChangedSince,
  startThemeWatchdog, stopThemeWatchdog } from '../service/AppWindow';
import { WallpaperStore } from '../service/WallpaperStore';
import { DocMeta, DocStore, ReaderRoute, DocFileInfo, DocTimes } from '../service/DocStore';
// 桌面卡片数据同步：进度落盘后即时推送（2×2 最近阅读卡片）
import { FormSync } from '../service/FormSync';
import { UpdateService } from '../service/UpdateService';
import { ReaderTab, TabStore } from '../service/TabStore';
import { FontStore } from '../service/FontStore';
import { NavLifecycle } from '../service/NavLifecycle';
import { GripAware } from '../service/GripAware';
import { ShareKitService } from '../service/ShareKitService';
import { GenWallpaper, genWallpaperFlatColor } from '../theme/GenWallpaper';
import { HeroInit, HeroRect, HeroTransition } from '../service/HeroTransition';
import { DocCover, coverColorsOf } from '../components/DocCover';
import { DiagramWeb } from '../components/DiagramWeb';
import { MdAnnotation, MdBlock, MdBlockKind, MdHeading, MdInline, MdInlineKind, MdMetaItem, MdNote, MdParseResult, MdTaskState } from '../markdown/MdTypes';
import { ChartCache } from '../service/ChartCache';
import { EngineRegistry } from '../service/EngineRegistry';
import { ChartRenderPool, ChartTask } from '../components/ChartRenderPool';
import { DiagramDownloadHost, DlJob } from '../components/DiagramDownloadHost';
import { InlineFormulaPool } from '../components/InlineFormulaPool';
import { MathFormulaText } from '../components/MathFormulaText';
import { NotePanel } from '../components/NotePanel';
import { MergeExportPanel } from '../components/MergeExportPanel';
import { MergeSource } from '../service/MergeExport';
import { FormulaTask, FormulaTasks } from '../markdown/FormulaTasks';
import { ReaderFlagTile } from '../components/ReaderFlagTile';
import { MdParser } from '../markdown/MdParser';
import { ReadingLog } from '../service/ReadingLog';
import { GraphResult, KnowledgeGraph } from '../service/KnowledgeGraph';
// 朗读：系统文本转语音（Core Speech Kit，无需权限）
import { textToSpeech } from '@kit.CoreSpeechKit';
// 朗读高亮：spanLabel 与正文渲染同一坐标口径
import { MdViewUtil } from '../markdown/MdView';
import { MdBlockView } from '../markdown/MdView';
import { ExportService } from '../service/ExportService';
import { EpubExport } from '../service/EpubExport';
import { L10n } from '../service/L10n';

// ══ 乐谱音频合成（后台线程）：音符事件 → 16bit WAV ══
/**
 * 图片管理面板里的一行：正文引用的一张图。
 *
 * `raw` 存的是**正文里的完整 Markdown 片段**（`![alt](href)`）——
 * 删除 / 替换都按它在原文里做字符串替换，不需要重新排版整篇。
 */
interface DocImage {
  /** 完整 Markdown 片段（原样，用于删除与替换） */
  raw: string;
  /** 目标地址（相对路径 / http(s) / data:） */
  href: string;
  /** Image 组件可直接用的源（本地图解析后的 file:// 或 http 地址；找不到为空） */
  src: string;
  /** 显示名（文件名或网络地址末段） */
  label: string;
  /** 是否网络图 */
  net: boolean;
  /** 本地图是否真实存在 */
  exists: boolean;
}

interface ScoreNote {
  /** 起始拍 */
  t: number;
  /** 时值（拍） */
  d: number;
  /** 频率 Hz */
  f: number;
  /** 1 = 伴奏声部（低音量正弦） */
  b: number;
}

interface ScoreSpec {
  bpm: number;
  notes: ScoreNote[];
}

/** 后台合成：按音符事件叠加谐波并加起收包络，输出 16bit 单声道 WAV（ArrayBuffer）。 */
@Concurrent
function synthScoreWavTask(spec: string): ArrayBuffer {
  const parsed: ScoreSpec = JSON.parse(spec) as ScoreSpec;
  const sr: number = 22050;
  const beatSec: number = 60 / (parsed.bpm > 0 ? parsed.bpm : 72);
  let totalB: number = 1;
  for (let k = 0; k < parsed.notes.length; k++) {
    const nt = parsed.notes[k];
    const t = nt.t + nt.d;
    if (t > totalB) {
      totalB = t;
    }
  }
  const totalSec: number = totalB * beatSec + 0.6;
  const n: number = Math.floor(totalSec * sr);
  const buf: Float32Array = new Float32Array(n);
  for (let k = 0; k < parsed.notes.length; k++) {
    const nt = parsed.notes[k];
    const vol: number = nt.b > 0 ? 0.16 : 0.34;
    const tau: number = (nt.b > 0 ? 0.9 : 0.7) + Math.max(0, 1000 - nt.f) / 2000;
    const startS: number = Math.floor(nt.t * beatSec * sr);
    const lenS: number = Math.floor(Math.min(nt.d * beatSec + 0.15, 2.2) * sr);
    for (let i = 0; i < lenS; i++) {
      const idx: number = startS + i;
      if (idx >= n) {
        break;
      }
      const tt: number = i / sr;
      const env: number = Math.min(1, tt / 0.008) * Math.exp(-tt / tau) * Math.min(1, (lenS - i) / (sr * 0.05));
      let s: number = Math.sin(2 * Math.PI * nt.f * tt);
      if (nt.b === 0) {
        s += 0.5 * Math.sin(4 * Math.PI * nt.f * tt) + 0.33 * Math.sin(6 * Math.PI * nt.f * tt)
          + 0.22 * Math.sin(8 * Math.PI * nt.f * tt) + 0.14 * Math.sin(10 * Math.PI * nt.f * tt);
      }
      buf[idx] += s * vol * env;
    }
  }
  const bytes: number = 44 + n * 2;
  const ab: ArrayBuffer = new ArrayBuffer(bytes);
  const dv: DataView = new DataView(ab);
  const wstr = (off: number, str: string) => {
    for (let i = 0; i < str.length; i++) {
      dv.setUint8(off + i, str.charCodeAt(i));
    }
  };
  wstr(0, 'RIFF');
  dv.setUint32(4, bytes - 8, true);
  wstr(8, 'WAVE');
  wstr(12, 'fmt ');
  dv.setUint32(16, 16, true);
  dv.setUint16(20, 1, true);
  dv.setUint16(22, 1, true);
  dv.setUint32(24, sr, true);
  dv.setUint32(28, sr * 2, true);
  dv.setUint16(32, 2, true);
  dv.setUint16(34, 16, true);
  wstr(36, 'data');
  dv.setUint32(40, n * 2, true);
  let off = 44;
  for (let i = 0; i < n; i++) {
    const v = Math.max(-1, Math.min(1, buf[i]));
    dv.setInt16(off, v < 0 ? v * 0x8000 : v * 0x7FFF, true);
    off += 2;
  }
  return ab;
}

/** 列表里正文块之前固定占用的条目数：文档信息卡占 1 条。 */
const LIST_HEADER_COUNT: number = 1;

/**
 * 下载 PNG 的**尺寸上限保护**（像素）。
 * 正常公式/图表远达不到（一块 360vp 宽的图表在 3.5 倍屏上是 1260px 宽），
 * 只有"又宽又长的巨型图"才会触发 —— 那时按**等比**缩一档，既不拉伸也不挤压，
 * 只是别让用户拿到一张几十兆、发不出去的图。
 */
const DL_PNG_MAX_AREA: number = 24000000;
const DL_PNG_MAX_SIDE: number = 6000;

/**
 * 批注草稿（用户要求：不小心退出后重新点「添加批注」，输入的内容还在）。
 * 用 AppStorage 记「草稿文本 + 时间戳」，**3 分钟内有效**，超时视为已放弃。
 */
const NOTE_DRAFT_KEY: string = 'readerNoteDraft';
const NOTE_DRAFT_AT_KEY: string = 'readerNoteDraftAt';
const NOTE_DRAFT_TTL: number = 3 * 60 * 1000;

/** 文档编码选项（识别错误时手动指定；auto 为自动识别）。 */
interface EncodingChoice {
  label: string;
  value: string;
}

const ENCODING_CHOICES: EncodingChoice[] = [
  { label: L10n.t('自动'), value: 'auto' },
  { label: 'UTF-8', value: 'utf-8' },
  { label: 'GBK', value: 'gbk' },
  { label: 'GB18030', value: 'gb18030' },
  { label: 'Big5', value: 'big5' },
  { label: 'Latin-1', value: 'iso-8859-1' }
];

/** 阅读页查找条占用的顶部高度（vp）：命中行要停在它下方（64 不够，实测差一点 → 76） */
const SEARCH_BAR_INSET: number = 76;

/**
 * 锚点归一化：忽略空白、大小写与常见标点。
 * 标题里带标点、锚点里不带（或反之）是很常见的情况，不归一化就会「点了没反应」。
 */
function normalizeAnchor(text: string): string {
  let out: string = '';
  for (let k = 0; k < text.length; k++) {
    const c: string = text.charAt(k).toLowerCase();
    if (c === ' ' || c === '\t' || c === '-' || c === '_' || c === '.' || c === '/'
      || c === '·' || c === '。' || c === '，' || c === '、' || c === '：' || c === ':') {
      continue;
    }
    out = out + c;
  }
  return out;
}

@Component
export struct Reader {
  /**
   * 路由参数（Navigation 迁移后由 navPageBuilder 传入，不再走 router.getParams）。
   * name = 要打开的文档名；query = 全库搜索带进来的关键词。
   */
  route: ReaderRoute = { name: '' };
  /** 导航栈：用于返回书架、继续下钻编辑页 */
  stack: NavPathStack | null = null;
  /** 生命周期转发：NavDestination 的 onShown/onHidden 调用（见 NavLifecycle） */
  life: NavLifecycle = new NavLifecycle();
  @StorageLink('readerFontSize') @Watch('onVisualChanged') fontSize: number = HwType.bodyDefault;
  @StorageLink('readerLineHeight') @Watch('onVisualChanged') lineMul: number = HwType.lineDefault;
  @StorageLink('readerMeasure') measure: number = HwType.measureDefault;
  /** 已关闭的渲染引擎（设置 → 引擎管理）：开关变化时重收预渲染 / 行内公式任务 */
  @StorageProp('disabledEngines') @Watch('onEnginesChanged') disabledEngineList: string = '';
  @StorageLink('readerThemeMode') @Watch('onThemeChanged') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') @Watch('onThemeChanged') systemDark: boolean = false;  /**
   * 主题纪元：明暗一变自增（见 applyThemeChange）。
   * 它拼在**正文 List 容器的 key** 上——只换条目 key 不够，
   * 已挂载的 ListItem 与其中的按钮是被列表复用的，必须换容器 key 才会真正重建。
   */
  @State themeEpoch: number = 0;
  /** 语言切换计数：变更时整页重建（key 拼接），文案随词典刷新 */
  @StorageProp('languageTick') languageTick: number = 0;
  /** 显示设置变化即刻下发窗口（阅读页持有常亮 / 亮度行为，离开时交还）。
   *  亮度不能叫 brightness——与组件基类的 .brightness() 属性方法重名（同 outline 的坑）。 */
  @StorageLink('readerKeepScreenOn') @Watch('onDisplaySettingChanged') keepOn: boolean = false;
  @StorageLink('readerBrightness') @Watch('onDisplaySettingChanged') brightLevel: number = 0;
  /** 文档信息卡开关（阅读设置里的「显示」段） */
  @StorageLink('readerShowMeta') showMetaCard: boolean = true;
  /**
   * 首行缩进（传给正文块：MdBlockView 以 @Prop 接收，属性管道才可靠回刷）。
   * **再加 @Watch 强制重建正文**：真机上仅靠属性下发时，正文 List 里已挂载的条目
   * 会复用、缩进要退出重进才生效（用户反馈）——换 renderEpoch（条目 key 里含它）
   * 才能保证当帧重建。
   */
  @StorageLink('readerIndent') @Watch('onIndentChanged') indentOn: boolean = false;
  /** 侧边栏沉浸光感开关（关闭后目录 / 批注面板用阅读背景色） */
  @StorageLink('drawerImmersive') drawerImmersive: boolean = true;
  /** 信息卡：创建 / 修改时间（毫秒，0 = 未知）与收藏状态 */
  @State docCreatedAt: number = 0;
  @State docModifiedAt: number = 0;
  @State docStarred: boolean = false;
  /** 当前文档的自定义标签（信息卡编辑，书架筛选 / 学习卡展示共用） */
  @State docTags: string[] = [];
  /** 标签输入草稿 */
  @State tagDraft: string = '';
  /** 面板内容强刷纪元：深浅切换时换容器 key，让 bindSheet 的面板重建 */
  @State sheetEpoch: number = 0;
  /** 沉浸布局下状态栏 / 手势条的避让高度（px），由 AppWindow 写入 */
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  @StorageProp('safeBottomPx') safeBottomPx: number = 0;
  /** 壁纸三键（只作为重渲染的订阅点；取色实际由 WallpaperStore 统一算） */
  @StorageLink('wallpaperPath') wallpaperPath: string = '';
  /** 浅色 / 深色模式各自的壁纸（深浅模式自动切换） */
  @StorageProp('wallpaperPathLight') wallpaperPathLight: string = '';
  @StorageProp('wallpaperPathDark') wallpaperPathDark: string = '';

  /** 当前模式生效的壁纸：浅色用浅色壁纸，深色用深色壁纸；未设置则回退旧全局壁纸 */
  private wallpaperPathEffective(): string {
    if (this.isDark()) {
      return this.wallpaperPathDark.length > 0 ? this.wallpaperPathDark : this.wallpaperPath;
    }
    return this.wallpaperPathLight.length > 0 ? this.wallpaperPathLight : this.wallpaperPath;
  }
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 4;
  @StorageLink('wallpaperScrim') wallpaperScrim: number = 42;
  /** 外观刷新计数（见 SettingsMirror）：主题色 / 灰字 / 沾色改完后靠它重算派生色 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  /** 沉浸光感开关（已强制开启）：标签芯片等部件据此决定是否要让出底色 */
  @StorageProp('immersiveLightEnabled') immersiveOn: boolean = true;

  @State blocks: MdBlock[] = [];
  @State docOutline: MdHeading[] = [];
  @State notes: MdNote[] = [];
  /** 用户批注（荧光笔 / 文字批注） */
  @State annotations: MdAnnotation[] = [];
  /** 处于"系统选择模式"的块 id：该块恢复系统原生长按菜单（复制 / 翻译 / 小艺） */
  @State systemSelectBlock: string = '';
  /** YAML Front Matter 抽出的元数据 */
  @State docMeta: MdMetaItem[] = [];
  /** 大纲里被折叠的标题（按 seq 记） */
  @State collapsedSeqs: number[] = [];
  /** 文档内查找 */
  @State searchOpen: boolean = false;
  @State searchQuery: string = '';
  @State searchHits: number[] = [];
  @State searchCursor: number = -1;
  @State docName: string = '';
  @State docBuiltin: boolean = false;
  /**
   * 该文档当前是否「只读」（标记存在 shelf.json，见 DocStore.isReadOnly）。
   * 只读只锁「改写正文」这条路：编辑按钮与任务勾选框；
   * 阅读 / 批注 / 封面 / 导出 / 亮度等一概照常。可在「更多」面板里切换。
   */
  @State docReadOnly: boolean = false;
  /** 该文档的自定义封面（书架里设的）——详情头那枚小封面跟着一起变，保持一致 */
  @State docCoverColor: string = '';
  @State docCoverImage: string = '';
  @State docWordCount: number = 0;
  @State docCharCount: number = 0;
  /** 文件信息（用户要求）：磁盘字节大小 + 正文 MD5，loadDoc 时现算一次。-1 = 未知 */
  @State docSizeBytes: number = -1;
  @State docMd5: string = '';
  @State docHeadingCount: number = 0;
  @State docCodeCount: number = 0;
  @State docTableCount: number = 0;
  @State loadError: string = '';

  /** 打开的标签（模块级 TabStore 的镜像，驱动标签栏渲染） */
  @State tabs: ReaderTab[] = [];
  /** 渲染纪元：字号 / 行高 / 主题 / 批注 / 搜索词变化时自增，拼进 ForEach 的 key。
   * **不这样做正文就调不了字号**——MdBlockView 的 bodySize 等是经 ForEach 传入的 @Prop，
   * ForEach 键不变时子组件的 @Prop 不会重新同步，设置变化根本到不了正文。
   */
  @State renderEpoch: number = 0;
  /**
   * **单块刷新通道**：某个块的内容就地变了（如勾选题目），只换这一块条目的 key，
   * 让它一张卡重建。以前这种地方一律 `renderEpoch++`——那会把**整篇正文**重建：
   * 所有卡片重新创建、图表重新加载、visibleBlocks 打回 80，用户实测表现为
   * "勾一下任务列表，整屏内容闪一下，已经收起来的顶栏底栏又弹出来"。
   * 形如 `块id:序号`；keygen 直接读这个 @State 字符串，所以是真实的渲染依赖，
   * 换块时旧块 key 回到原样（它的 @Prop 数据本来就是最新的，多重建一次无副作用）。
   */
  @State blockRev: string = '';

  /** 该块刚被单块刷新过 → 返回它的序号，否则空串（key 保持原样，不打扰别的卡） */
  private blockRevSuffix(blockId: string): string {
    const at: number = this.blockRev.indexOf(':');
    if (at <= 0 || this.blockRev.substring(0, at) !== blockId) {
      return '';
    }
    return '_v' + this.blockRev.substring(at + 1);
  }

  /** 只重建这一块（调用方需先把数据改好） */
  private bumpBlockRev(blockId: string): void {
    this.blockRev = blockId + ':' + (Date.now() % 1000000);
  }
  /**
   * **本页自己的深浅记忆**（不再依赖全局"已应用"标记）：
   * 全局标记会被别的页面先置位（切深浅时设置页先收到），阅读页据此**跳过重建**
   * → 出现"背景跟着变深、正文文字却还是浅色主题的深色字"（用户实测看不清）。
   */
  private lastAppliedDark: boolean = false;
  private lastAppliedValid: boolean = false;
  /** 图表后台预渲染任务（打开文件时生成，池子逐个渲染成 PNG 写缓存） */
  @State chartTasks: ChartTask[] = [];
  /** 行内公式图任务（InlineFormulaPool 用：MathJax → SVG → PNG） */
  @State formulaTasks: FormulaTask[] = [];
  /**
   * **注释抽屉**的公式图任务（批注原文 / 备注 / 脚注里的 $公式$）：
   * 抽屉项的 MathFormulaText 以 generate=false 只吃缓存，由这一个共用池出图，
   * 避免"每条批注各挂一个 Web"。抽屉打开 / 批注变更 / 字号与深浅变化时重收。
   */
  @State drawerFormulaTasks: FormulaTask[] = [];
  /** 抽屉公式图就绪信号（递增 → 批注卡片 key 重算 → 线性化文字换成图） */
  @State drawerFormulaTick: number = 0;
  /**
   * 半模态显隐开关。**与 activeSheet 分离**是关键：关闭时只翻此开关，
   * activeSheet 留到 onDismiss 再清——否则 dismiss 动画期间 builder 渲染成空，
   * 用户看到一块白色空面板卡在屏幕上（真机踩过）。
   */
  @State sheetVisible: boolean = false;
  /** 粒子消散触发序号：切换标签 / 文档时自增（外观设置开启才生效） */
  /** Lute 导出引擎（隐藏 Web，onPageEnd 后可用） */
  /** 图表/公式放大浮层 */
    @State enlargeMode: string = '';
  /** 背景光斑缓慢漂移（无限往复，两团时长不同 → 相位错开，看起来随机） */
  @State blobAX: number = 0;
  @State blobAY: number = 0;
  @State blobBX: number = 0;
  @State blobBY: number = 0;
  // 浮层缩放：± 按钮写 webZoom，由 DiagramWeb 换算成引擎的相对缩放
  // （WebviewController.zoom）；双指捏合走引擎自带的页面缩放，两者是同一个
  // 页面比例，可以叠加。⚠️ 不要改成自己接 ArkUI 手势：Web 组件在原生层就吃掉
  // 了触摸序列，外层手势收不到双指，实测反而把捏合彻底弄没了。
  @State enlargePayload: string = '';
  /** 代码块放大时的**已高亮 HTML**（与正文卡片同一套分词配色；空=纯文本） */
  @State enlargeRichHtml: string = '';
  /**
   * 代码块放大时的**指定高亮行**（围栏元数据 js{1,3-5}，逗号分隔的 1 起行号）。
   * 正文卡片按 block.hlLines 铺行底色，浮层是另一个渲染面（Web），
   * 不传下去就"一放大高亮全没了"（用户实测）。
   */
  @State enlargeHlCsv: string = '';
  /** 放大浮层的一镜到底共享 id（与正文里那张卡片同 id） */
  @State enlargeGeo: string = '';
  /**
   * **图表就绪信号**：后台预渲染池每完成一个图表递增。图表 / 公式条目只用它
   * （不再用全局 renderEpoch）作 key —— 否则任何一次 renderEpoch 变化或"图表逐一
   * 渲染完成"都会整树重建 → 图表反复重新加载、闪来闪去（用户反馈）。
   */
  @State chartReadyTick: number = 0;
  /**
   * 下载任务（非空 = 挂载 DiagramDownloadHost 这块**独立渲染表面**）。
   * 用独立表面而不是浮层那块：见 DiagramDownloadHost 的注释（浮层表面被裁剪、
   * 高度被画布钉死，屏外内容进不了快照）。
   */
  @State dlJob: DlJob | null = null;
  /** 下载进行中（按钮置灰 + 防重复触发；到"另存为写完"为止都算） */
  @State dlBusy: boolean = false;
  /** 浮层的 Web 是否挂载（退后台卸载、回前台重挂 —— 修"关屏再开自动退出页面"） */
  @State enlargeWebMounted: boolean = true;
  /** 回前台信号（EntryAbility 递增） */
  @StorageProp('appForegroundTick') @Watch('onAppForegroundTick') appFgTick: number = 0;
  /**
   * **图表失败重试信号**（导出 / 打印前由 ExportService/PrintService 递增）：
   * 转发给后台池清空失败集重跑一轮——"导出全图片化"时不希望个别时序抖动失败的
   * 图拖累成"现场渲染的容器"。
   */
  @StorageProp('chartRetryTick') @Watch('onChartRetry') chartRetryTick: number = 0;
  /** 转发给 ChartRenderPool 的重试计数（池子 @Watch 到就清失败集重跑） */
  @State poolRetryTick: number = 0;
  /** 旋转后重新自适应请求计数（传给 DiagramWeb） */
  @State enlargeRefitTick: number = 0;
  /** 本段阅读的起始时间戳（ms）；0 = 未在计时（离场 / 退后台后清零） */
  private readStartAt: number = 0;
  /** 当前文档的**原文**（图片管理按 Markdown 片段做精确替换，见 scanDocImages） */
  private rawContent: string = '';
  /** 手写批注图（手写页以批注模式返回时写入）：此处落成红双下划线批注 */
  @StorageProp('sketchAnnotationImage') @Watch('onSketchAnnotation') sketchAnnotation: string = '';
  /** 系统返回手势关闭浮层的信号（Index 的 onBackPressed 发出） */
  @StorageProp('readerOverlayCloseTick') @Watch('onOverlayCloseTick') overlayCloseTick: number = 0;
  /** 应用退后台计数（EntryAbility 递增）：回前台前复位浮层，避免 Web 状态异常 */
  @StorageProp('appBackgroundTick') @Watch('onAppBackgroundTick') appBgTick: number = 0;
  /** 上次 onShownNow 时见过的后台计数（判断是否为回前台恢复） */
  private lastSeenBgTick: number = -1;
  /** 放大内容的原标题（脑图主题等；空串 = 不显示标题） */
  @State enlargeTitle: string = '';
  /** 反向链接：引用了当前文档的文档名列表 */
  @State backlinks: string[] = [];
  /** 本文档引用的图片清单（图片管理面板） */
  @State docImages: DocImage[] = [];
  /** 放大浮层旋转（横屏）展示 */
  @State rotated: boolean = false;
  /** 放大浮层的 Web 内容缩放（body.style.zoom） */
  @State webZoom: number = 1;
  /** 放大浮层的**图片**缩放倍率（图片模式用原生 Image + 手势，不走 Web） */
  @State imgScale: number = 1;
  /** 图片捏合手势的起始倍率（手势增量基准） */
  private imgPinchBase: number = 1;
  /** 图片拖动平移（图片模式）与拖动基准 */
  @State imgDx: number = 0;
  @State imgDy: number = 0;
  private imgDxBase: number = 0;
  private imgDyBase: number = 0;
  /** 画布区实测尺寸：旋转画布时按"高×宽"互换 */
  @State canvasW: number = 0;
  @State canvasH: number = 0;


  /** 旋转 / 取消旋转（横屏展示），带转场动画。 */
  private toggleRotate(): void {
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.rotated = !this.rotated;
    });
  }

  /**
   * 缩放倍率步进（±25%）。范围 **0.05~4**（用户反馈：原 0.5~3 默认有时太大
   * 又不能再缩小）——放大时需要更小的下限才能把大图整体收进视野。
   * 与双指捏合不冲突：两者作用在同一个引擎页面比例上，可叠加。
   */
  private zoomBy(factor: number): void {
    // **图片模式**：缩放作用在原生 Image 上（不走 Web）
    if (this.enlargeMode === 'image') {
      const next: number = this.imgScale * factor;
      if (!(next > 0)) {
        return;
      }
      this.imgScale = Math.min(8, Math.max(0.05, next));
      return;
    }
    this.setWebZoom(this.webZoom * factor);
  }

  /**
   * **唯一的 webZoom 写入出口**（± 按钮用）。
   *
   * ⚠️ 下限 **0.05 必须与渲染模板 viewport 的 `minimum-scale=0.05` 对齐**：
   * DiagramWeb 是按「目标倍率 ÷ 已应用倍率」给引擎发相对增量的，如果这里允许
   * 记到 0.01 而引擎只肯到 0.05，两边就会错位 —— 表现为往回放大时前几下一点
   * 反应没有（要先"吃掉"那段虚假的差额）。上限同理留在 maximum-scale=10 之内。
   */
  private setWebZoom(v: number): void {
    if (!(v > 0)) {
      return;
    }
    this.webZoom = Math.min(4, Math.max(0.05, v));
  }

  /**
   * 退后台 / 关屏时**保留浮层、只卸载 Web**（用户要求：关屏再开不要自动退出
   * 图表界面）—— 后台被系统回收后 Web 表面状态不可靠，回前台重挂即可。
   */
  onAppBackgroundTick(): void {

    // 退后台先结算阅读时长：后台停留不该算进"读了多久"
    this.settleReadTime(false);
    if (this.enlargeMode.length === 0 || !this.enlargeWebMounted) {
      return;
    }
    this.enlargeWebMounted = false;
  }

  /** 回前台：把卸载掉的 Web 重新挂载（图表重新渲染），浮层保持打开。 */
  onAppForegroundTick(): void {
    // 回前台锁定自动收起 650ms（同 onShownNow：恢复期位移不误触发收起）
    this.autoHideLockUntil = Date.now() + 650;
    // 从回前台这一刻重新起算这段阅读
    this.readStartAt = Date.now();
    if (this.enlargeMode.length === 0 || this.enlargeWebMounted) {
      return;
    }
    this.enlargeWebMounted = true;
  }

  /** 图表失败重试：导出 / 打印前发给后台池（清失败集重跑一轮，见 ChartRenderPool.retryTick）。 */
  onChartRetry(): void {
    if (this.chartRetryTick <= 0) {
      return;
    }
    this.poolRetryTick = this.poolRetryTick + 1;
  }

  // ══════════════════════ 阅读时长统计 ══════════════════════
  //
  // 只记**真实停留**：退后台、切走页面都先结算，后台时间不计入；
  // 短于 5 秒的片段丢弃（切文档、误触进出产生的噪声不算阅读）。

  /**
   * 结算当前这段阅读时长。
   * @param restart true = 结算后立刻重新起算（切文档时用），false = 停在原处（离场时用）
   */
  private settleReadTime(restart: boolean): void {
    const now: number = Date.now();
    if (this.readStartAt > 0 && this.docName.length > 0) {
      const sec: number = (now - this.readStartAt) / 1000;
      // 上限 12 小时：开着页面忘了关不该把统计拉爆
      if (sec >= 5 && sec <= 12 * 3600) {
        const c = this.ctx();
        if (c !== null) {
          ReadingLog.add(c, this.docName, sec);
        }
      }
    }
    this.readStartAt = restart ? now : 0;
  }

  /** 系统返回手势：关闭图表 / 图片放大浮层（而非退出阅读页）。 */
  onOverlayCloseTick(): void {
    if (this.enlargeMode.length === 0 && this.zoomImgKey.length === 0) {
      return;
    }
    this.closeOverlays();
  }

  /**
   * 把沙箱路径 / 相对路径转成 Web 可直接加载的 file:// URI。
   * **必须做 URL 编码**：文档名多为中文，图片文件名同样含中文 —— 未编码时
   * Web 加载会直接失败（用户实测"点击放大按钮提示图片加载失败"）。
   */
  toFileUri(path: string): string {
    if (path.startsWith('file://') || path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    let abs: string = path;
    if (!path.startsWith('/')) {
      const root: string = DocStore.docsRoot();
      abs = root.length > 0 ? root + '/' + path : path;
    }
    try {
      // encodeURI 会保留 '/' 与 ':'，只编码中文 / 空格等
      return 'file://' + encodeURI(abs);
    } catch (err) {
      return 'file://' + abs;
    }
  }

  /** 从批注里取出手写图（note 前缀 `hw:`）并在放大浮层中查看。 */
  openHandwriteAnno(ann: MdAnnotation): void {
    if (ann.note.length <= 3 || !ann.note.startsWith('hw:')) {
      return;
    }
    const rel: string = ann.note.substring(3);
    // **用 resolveImagePath 找真实文件**（相对 / ./ 前缀 / images 目录候选都能命中；
    // 直接拿相对路径给 Image 组件会是一片空白 —— 用户实测）
    const resolved: string = DocStore.resolveImagePath(rel);
    if (resolved.length === 0) {
      this.toast(L10n.t('找不到手写批注图片'));
      return;
    }
    const uri: string = resolved;
    this.imgScale = 1;
    this.imgDx = 0;
    this.imgDy = 0;
    this.rotated = false;
    this.getUIContext().animateTo({ duration: 280, curve: Curve.FastOutSlowIn }, () => {
      this.enlargeMode = 'image';
      this.enlargePayload = uri;
      this.enlargeGeo = '';
      this.enlargeTitle = ann.text.length > 0 ? ann.text : L10n.t('手写批注');
      this.enlargeWebMounted = true;
      this.enlargeRefitTick = 0;
      AppStorage.setOrCreate('readerOverlayOpen', true);
    });
  }

  /**
   * 手写页以「批注模式」返回：把手写图存成批注（**红色双下划线** + 图路径）。
   * 图片路径放在 note 字段（前缀 `hw:`），查看/删除都走既有批注链路。
   */
  onSketchAnnotation(): void {
    const rel: string = this.sketchAnnotation;
    if (rel.length === 0 || this.pendingBlockId.length === 0) {
      return;
    }
    const blockId: string = this.pendingBlockId;
    const start: number = this.pendingStart;
    const end: number = this.pendingEnd;
    const text: string = this.noteQuote;
    AppStorage.setOrCreate('sketchAnnotationImage', '');
    AppStorage.setOrCreate('sketchMode', '');
    if (end <= start) {
      this.toast(L10n.t('没有可标注的选区'));
      return;
    }
    const list: MdAnnotation[] = this.withoutOverlap(this.annotations, blockId, start, end);
    list.push(this.buildAnnotation(blockId, start, end, text, -1, 'hw:' + rel, 'dbl'));
    this.commitAnnotations(list);
    this.toast(L10n.t('已添加手写批注'));
  }

  /** 关闭所有放大浮层（图表 / 图片）并复位缩放、旋转等临时状态。 */
  closeOverlays(): void {
    this.getUIContext().animateTo({ duration: 280, curve: Curve.FastOutSlowIn }, () => {
      this.enlargeMode = '';
      this.enlargeGeo = '';
      this.enlargeTitle = '';
      this.zoomImgKey = '';
      this.zoomImgSrc = '';
    });
    this.rotated = false;
    this.webZoom = 1;
    this.imgScale = 1;
    // **对照面板恢复**（用户要求）：从对照面板里点开的浮层，关闭后自动把
    // 面板重新拉起（对照文档还选着，直接回到对照现场，不用重新选）
    if (this.compareSheetWasOpen) {
      this.compareSheetWasOpen = false;
      this.activeSheet = 'compare';
      this.sheetVisible = true;
    }
    this.imgDx = 0;
    this.imgDy = 0;
    this.enlargeWebMounted = true;
    AppStorage.setOrCreate('readerOverlayOpen', false);
  }
  /** 图片一镜到底：正在放大的那张图（key 与正文里的图片共享 geometry id） */
  @State zoomImgKey: string = '';
  @State zoomImgSrc: string = '';
  @State zoomImgOpen: boolean = false;
  /** 手指落在图表 Web 上时 >0：根级捏合（改字号）必须抑制 */
  private webTouchDepth: number = 0;
  // ── 一镜到底几何（官方算法：详情页从书架封面位置缩放展开 / 缩回） ──
  @State heroScale: number = 1;
  @State heroX: number = 0;
  @State heroY: number = 0;
  @State heroClipW: string = '100%';
  @State heroClipH: string = '100%';
  /** 页面底不透明度：展开时从 0 渐显，缩回时渐隐（露出下层书架） */
  @State heroBg: number = 1;
  /** 正在播放缩回动画（避免重复触发返回） */
  private heroExiting: boolean = false;
  /** 本次来源几何（缩回时的目标） */
  private heroInit: HeroInit | null = null;
  /** 大屏/横屏：目录停靠左侧 */
  @State tocPinned: boolean = false;

  /** 上一帧是否处于大屏：用于捕捉「窄→宽」的切换瞬间（自动钉住两侧面板）。 */
  private wasWide: boolean = false;
  /** 停靠面板宽度（持久化记忆：拖分隔条功能已移除，宽度固定为上次记忆值） */
  @StorageLink('readerTocPanelW') tocPanelWidth: number = 300;
  @StorageLink('readerNotesPanelW') notesPanelWidth: number = 300;
  /** 大屏/横屏：注释停靠右侧 */
  @State notesPinned: boolean = false;
  /** 标签长按菜单 */
  @State tabMenuFor: string = '';
  /** 悬浮工具条上的「更多」菜单与亮度快捷面板（参考图三） */

  @State noteDraft: string = '';
  @State noteQuote: string = '';
  /**
   * **公式批注上下文**（action='mathnote' 时非空，其余批注为空串）。
   * 面板内的编辑/选区/预览都由 NotePanel 自持（bindSheet 不跟宿主刷新），
   * 这里只留**提交与写回时宿主必须知道**的三样：
   *  - noteMathQuote：文档里当前这条公式的源码（收窄定位的基准）；
   *  - noteMathBlockId：它所在的块（写回要用 srcLine）；
   *  - noteMathBase：这条公式在块渲染文本里的起始偏移（annotateHandler 传来的 start），
   *    收窄后的区间 = base + 选中段在 noteMathQuote 中的位置。
   */
  @State noteMathQuote: string = '';
  @State noteMathBlockId: string = '';
  private noteMathBase: number = 0;
  @State tocOpen: boolean = false;
  @State notesOpen: boolean = false;
  @State progress: number = 0;
  @State progressBlock: number = 0;
  @State activeHeading: string = '';
  /** 注释抽屉的分类筛选（'' = 全部；分类见 annoKindLabel） */
  @State notesFilter: string = '';
  /** 注释侧栏：搜索条展开态 + 关键词（'' = 不过滤） */
  @State notesSearchOpen: boolean = false;
  @State notesQuery: string = '';
  @State scrolled: boolean = false;
  /** 顶栏 / 底栏是否展开。向下滚动自动收起，向上滚动或回到顶部恢复 */
  /** 顶栏与底栏**独立**收放：收起底栏不该把顶栏也带下去 */
  @State topBarVisible: boolean = true;
  @State bottomBarVisible: boolean = true;
  /**
   * **沉浸阅读**（用户要求）：隐藏顶栏与底栏（含其中所有功能按钮），
   * 只在**右下角**保留一个退出按钮。入口在顶栏返回按钮的右侧。
   * 直接复用既有的 `topBarVisible` / `bottomBarVisible` 两个开关（它们本来就决定
   * 顶栏 / 底栏是否渲染），再让滚动收放逻辑在沉浸期间整体短路 —— 否则往下滑一下
   * 又会被"滚回顶部自动展开"带回来。
   */
  @State immersiveRead: boolean = false;
  /**
   * 文档编码（用户要求：识别错误时手动选择）。
   * `auto` = 自动：BOM 优先（UTF-8 / UTF-16），否则先按 UTF-8 解，出现替换符
   * 说明不是合法 UTF-8 → 回落 GB18030（覆盖绝大多数中文文档）。
   * 其余值手动指定：utf-8 / gbk / gb18030 / big5 / iso-8859-1。
   */
  @State docEncoding: string = 'auto';
  /**
   * **大文件懒渲染**（用户要求：大体积 md 不严重卡顿/卡死）。
   * ArkUI 的 ForEach 会一次性创建全部 ListItem —— 几万块的文档光建组件就卡死。
   * 这里只渲染前 `visibleBlocks` 块，末尾放一个「哨兵」ListItem，滚动到它时再追加一批
   * （参考 lv-markdown-in 的 lazyRender + 预渲染块数思路）。
   *
   * **转场降载**（1.1.0）：经「一镜到底」进来时首批只渲染 24 块（转场期间屏幕
   * 还被飞行封面盖着，24 块足够铺满首屏），转场结束（onShownNow）再补到 80 ——
   * 首帧少渲染几十个块，转场掉帧明显改善（流畅度检测 186 → 达标方向）。
   * 直接打开（无转场）仍按 80 起。
   */
  @State visibleBlocks: number = 80;
  /**
   * 放大浮层「查看源码」切换前的内容形态（图表 / HTML / code …）。
   * 用于从源码形态一键切回原来的预览形态。
   */
  @State enlargePrevMode: string = '';
  /**
   * 标签栏位置（用户要求）：false = 顶栏下方（默认）/ true = **底部悬浮栏上方**。
   * 置底时：宽度与底部悬浮胶囊**完全一致**、固定贴在它上面（不随滚动收放），
   * 入口在「更多」面板里。持久化键 readerTabBarAtBottom。
   */
  @StorageLink('readerTabBarAtBottom') tabBarAtBottom: boolean = false;
  /** 智感握姿：-1 左手 / 0 未知或居中 / 1 右手（见 service/GripAware.ets） */
  @State gripSide: number = 0;
  /**
   * 大屏 / 平板横屏专属（更多面板里设置，仅宽屏显示）：
   * 目录 / 注释与批注侧边栏是否**默认展开**。只存偏好 —— 运行中手动收放不改写它。
   */
  @StorageProp('readerTocPinnedDefault') tocPinnedDefault: boolean = true;
  @StorageProp('readerNotesPinnedDefault') notesPinnedDefault: boolean = true;
  /** 默认停靠偏好是否已应用到本次页面（rootWidth 量到、isWide 可判后应用一次） */
  private pinnedDefaultsApplied: boolean = false;
  /** 系统选择胶囊的自定义位置（vp）；-1 = 未拖过 → 用自动贴边公式 */
  @State sysTabX: number = -1;
  @State sysTabY: number = -1;
  /** 拖动手势的起点基准（onActionStart 时快照当前位置） */
  private sysTabBaseX: number = 0;
  private sysTabBaseY: number = 0;
  /** 函数绘制壁纸的 id（空 = 不用） */
  @StorageProp('wallpaperGenId') genWallId: string = '';
  /**
   * 自定义函数壁纸的两端色（暗端 A / 亮端 B）。
   * 侧边栏关闭沉浸光感时用它算"与背景同色"的底色，**必须在本页订阅**：
   * 纯函数里读 AppStorage 不登记渲染依赖，改色后已画出的侧边栏不会重算。
   */
  @StorageProp('wallpaperCustomA') customWallA: string = '#1E222B';
  @StorageProp('wallpaperCustomB') customWallB: string = '#E8EDF4';
  /** 阅读背景（与外观壁纸独立）：手选图路径 / 内置款 id */
  @StorageProp('readerBgPath') readerBgPath: string = '';
  @StorageProp('readerBgId') readerBgId: string = '';
  /** 切换标签时的内容滑入位移（vp），0 = 静止 */
  @State contentSlideX: number = 0;
  /** 翻页动效的透明度分量（0.3 → 1） */
  /** 当前打开的半模态面板：settings/note/tabMenu/bright/more；空串 = 全关 */
  @State activeSheet: string = '';
  /**
   * 合并导出面板的数据源（打开面板那一刻重建，见 openMergeExport 的 sheetEpoch）。
   * MergeExportPanel 的 sources/preselect 是普通成员，只在创建时读一次，
   * 所以每次打开都要先把这两份刷新一遍、再换纪元重建面板。
   */
  @State mergeSources: MergeSource[] = [];
  @State mergePreselect: string[] = [];
  @State contentFade: number = 1;
  @State rootWidth: number = 360;
  /** 窗口高度（vp）：页面过渡的缩放锚点兜底用 */
  @State rootHeight: number = 800;
  /** List 的初始滚动位置（构造时定位，避免「先顶部再跳走」的闪动） */
  @State listInitialIndex: number = 0;
  /** 是否首次加载（首次用 initialIndex 定位；切标签才用 scrollToIndex） */
  private firstLoad: boolean = true;

  private scroller: Scroller = new Scroller();
  /**
   * 自动滚屏：是否正在滚。
   * **走 AppStorage 而不是 @State**：入口在「更多」面板里的磁贴，
   * 而 bindSheet 的内容不跟宿主状态重渲染（本工程固定坑），
   * 共享同一份状态两边才不会打架（详见 components/AutoScrollTile）。
   */
  @StorageLink('autoScrollOn') autoScrolling: boolean = false;
  /** 自动滚屏档位 1–10（换算见 autoVpPerSec） */
  @StorageLink('autoScrollSpeed') autoSpeed: number = 4;
  /** 自动滚屏的定时器句柄（-1 = 没有） */
  private autoTimer: number = -1;
  /**
   * 暂停浮钮是否显示。
   * **与 autoScrolling 分开**：暂停（点钮 / 点正文 / 滚到文末）只停表、
   * 钮留着并变成「继续」；只有长按钮或离开阅读页才真正收起（用户要求）。
   */
  @State autoBarVisible: boolean = false;
  /** 暂停浮钮位置（translate 状态）；-1 = 尚未初始化（首次开始时按握姿定边） */
  @State pauseBtnX: number = -1;
  @State pauseBtnY: number = -1;
  private pauseDragBaseX: number = 0;
  private pauseDragBaseY: number = 0;
  /** 滚动期间握姿兜底核对的节拍计数（见 syncGripSideForAutoScroll） */
  private autoGripTick: number = 0;
  // ── 朗读（TTS）──
  /** 朗读会话是否活跃（含暂停，浮钮据此显示） */
  @StorageLink('ttsOn') ttsOn: boolean = false;
  /** 是否正在发声 */
  @StorageLink('ttsSpeaking') ttsSpeaking: boolean = false;
  /** TTS 引擎（懒创建；结束会话时 shutdown 并置空） */
  private ttsEngine: textToSpeech.TextToSpeechEngine | null = null;
  /** 可朗读的块下标序列 */
  private ttsQueue: number[] = [];
  /** 当前读到队列的第几项（-1 = 未开始） */
  private ttsPos: number = -1;
  /** 是否处于暂停态（onComplete 靠它区分"读完了"与"被 stop 打断"） */
  private ttsPaused: boolean = false;
  /** 当前句在渲染文本中的区间 */
  private ttsSegStart: number = -1;
  private ttsSegEnd: number = -1;
  /** 当前块的句子区间列表与进度 */
  private ttsSegs: number[][] = [];
  private ttsSegAt: number = 0;
  /** 当前块的渲染文本（句子切分基于它） */
  private ttsRendered: string = '';
  /** requestId 自增段（每次开始会话 +1，避免旧 request 的回调串台） */
  private ttsRequest: number = 0;
  /** 每次发声再自增一次（同一个 requestId 复用会被引擎拒） */
  private ttsSpeakSeq: number = 0;
  /** 当前方向上累计的滚动位移（vp），超过阈值才收起顶栏，避免轻微滚动就闪 */
  private scrollAccum: number = 0;
  /** 程序化滚动（目录跳转 / 搜索定位 / 恢复进度）期间锁定自动收起，动画帧会误触发 */
  private autoHideLockUntil: number = 0;
  /** 下次布局完成后要跳到的块下标；-1 表示不需要恢复 */
  private pendingJump: number = -1;
  /** 进度落盘节流：滚动中不写，停下来才写 */
  private progressDirty: boolean = false;
  /** 待写入的批注选区（弹出批注输入框时暂存） */
  private pendingBlockId: string = '';
  private pendingStart: number = -1;
  private pendingEnd: number = -1;
  private pendingColor: number = 0;
  /** 待写入的批注形态（'' = 荧光底纹，'card' = 学习卡的实色底） */
  private pendingStyle: string = '';
  /** 捏合调字号时的起始字号 */
  private pinchBaseFont: number = 0;
  /** 全库搜索带进来的关键词。等首帧布局完成、恢复阅读位置之后再执行查找 */
  private routeQuery: string = '';
  /**
   * 「全部待办」点条目带进来的目标行号（1 起，0 = 无）。
   * 首帧布局完成后按行号找块并滚过去（用户反馈"点进去要自己找位置"）。
   */
  private routeFocusLine: number = 0;
  /** 是否从「全部待办」面板进来：退出时给书架一个"重新打开该面板"的信号 */
  private fromTaskBoard: boolean = false;
  // ── 表格可视化编辑（点正文表格打开，保存按块 srcLine 写回原文）──
  /** 编辑中的表格（与 TableEditorDialog 的 @Link 同一引用；打开时整体替换） */
  @State editTable: MdTable = { header: [''], rows: [['']], align: ['none'] } as MdTable;
  /** 正在编辑的表格块 id（保存时按块的 srcLine 定位原文行段） */
  @State tableEditBlockId: string = '';
  tableDialog: CustomDialogController = new CustomDialogController({
    builder: TableEditorDialog({
      tbl: $editTable,
      onSave: (): void => {
        this.saveTableEdit();
      }
    }),
    autoCancel: true,
    customStyle: true
  });

  aboutToAppear(): void {
    this.startBlobDrift();
    // Navigation 迁移后参数由 navPageBuilder 直接注入（不再走 router.getParams）
    const params: ReaderRoute = this.route;
    let routeName: string = '';
    if (params !== undefined && params !== null && params.name !== undefined) {
      routeName = params.name;
    }
    if (params !== undefined && params !== null && params.query !== undefined
      && params.query !== null && params.query.trim().length > 0) {
      this.routeQuery = params.query.trim();
    }
    // 「全部待办」条目跳转：记下目标行与"退出后回任务面板"的意图
    if (params !== undefined && params !== null && params.focusLine !== undefined
      && params.focusLine !== null && params.focusLine > 0) {
      this.routeFocusLine = params.focusLine;
    }
    if (params !== undefined && params !== null && params.fromTasks === true) {
      this.fromTaskBoard = true;
    }
    // 多标签：进阅读页先恢复落盘的标签会话，路由参数指向的文档聚焦既有标签或新开
    const ctx = this.ctx();
    if (ctx !== null) {
      TabStore.init(ctx);
      // 用户导入的自定义字体在此注册，正文 fontFamily 才能生效
      FontStore.registerAll(ctx);
    }
    const target: string = routeName.length > 0 ? routeName : TabStore.activeName();
    if (target.length > 0) {
      TabStore.open(target, '');
      this.docName = TabStore.activeName();
    }
    this.tabs = TabStore.list();
    // 首次加载放在 build 之前：这样 List 能在**构造时**就用 initialIndex 定到上次位置，
    // 而不是先渲染到顶部、再 setTimeout 跳过去（那会看到一次明显的闪跳）。
    if (this.docName.length > 0) {
      this.loadDoc();
    }
    // 一镜到底·首帧就位（必须在 build 之前）：让第一帧就出现在封面位置/尺寸上
    const hero: HeroInit | null = HeroTransition.takeInit();
    if (hero !== null) {
      this.heroInit = hero;
      this.heroScale = hero.scale;
      this.heroX = hero.translateX;
      this.heroY = hero.translateY;
      this.heroClipW = hero.clipW;
      this.heroClipH = hero.clipH;
      this.heroBg = 0;
      // 转场降载：首帧只渲染 24 块，转场结束（onShownNow）补回 80
      this.visibleBlocks = 24;
    }
    // Navigation 化之后 @Entry 的 onPageShow/onPageHide 不再触发，
    // 由 NavDestination 的 onShown/onHidden 转发（见 NavLifecycle）。
    this.life.onShow = () => {
      this.onShownNow();
    };
    this.life.onHide = () => {
      this.onHiddenNow();
    };
  }

  /** 原 onPageShow 的内容：Navigation 下由 NavDestination.onShown 转发进来。 */
  private onShownNow(): void {
    // **回前台/回页面锁定自动收起 650ms**：恢复期布局位移会产生滚动事件，
    // 误触发顶栏收起 = 内容整体上移一小段（用户实测：退后台再回来自动上移）
    this.autoHideLockUntil = Date.now() + 650;
    // **校准叠加层标志**（返回键拦截判据）：只以真实状态为准 —— 标志残留会让
    // 侧滑返回一直被吞掉（用户实测"不能侧滑返回"）。
    AppStorage.setOrCreate('readerOverlayOpen',
      this.enlargeMode.length > 0 || this.zoomImgOpen);
    // 首次已在 aboutToAppear 加载（为了 List 构造时定位）；从别处返回本页时才重新加载
    // ⚠️ **应用切后台再回来不重新加载**：重建会让滚动位置漂移、内容闪现回跳
    //（用户实测：退后台再打开，界面上移一小段 + 闪现）。外部改动在下次
    // 真正进出页面时才会重新加载。
    const resumedFromBg: boolean = this.appBgTick !== this.lastSeenBgTick;
    this.lastSeenBgTick = this.appBgTick;
    // ⚠️ 放大浮层（下载公式/图表图）打开期间**不重载**：另存对话框会触发
    // NavDestination onShown → loadDoc 重建正文 → 阅读位置跳回（用户实测
    // "保存后返回自动上移"）。浮层开着 = 用户仍在阅读上下文里，无需重载。
    const enlargeOpen: boolean = this.enlargeMode.length > 0;
    if (!this.firstLoad && !resumedFromBg && !enlargeOpen) {
      this.loadDoc();
    }
    this.firstLoad = false;
    // 回到阅读页：开始计这一段阅读时长
    this.readStartAt = Date.now();
    // **转场结束后**把首屏补回标准批量（进入时只渲染 24 块降载，见 aboutToAppear）
    if (this.visibleBlocks < 80) {
      setTimeout(() => {
        this.visibleBlocks = Math.max(this.visibleBlocks, 80);
      }, 450);
    }
    // 系统深浅同步 + 必要刷新：实机证明 @Watch 不来，这里手动比对，
    // 不一致就重建正文整树（材质 / 壁纸 / 正文色一次到位）。
    syncSystemDarkFromContext();
    this.applyThemeChange();
    // 可见期间探测器：系统深浅一变立刻重建正文（@Watch 实机不触发）
    startThemeWatchdog(() => {
      this.applyThemeChange();
      applySystemBarTheme(this.isDark());
    });
    applySystemBarTheme(this.isDark());
    this.applyDisplaySettings();
    // 一镜到底进场：从书架封面矩形展开（无来源几何时自动跳过，退化为普通淡入）
    // 浮层打开期间跳过（重播进场动画 = 视觉位移）
    if (!enlargeOpen) {
      this.heroEnter();
    }
    // 智感握姿：**先申请权限再监听**（DETECT_GESTURE 是运行时授权权限，
    // 只声明不申请会让 motion.on 抛错被吞掉 → gripSide 恒 0 → 底部栏与选择
    // 胶囊都不跟手）。设备不支持或用户拒绝时静默降级。
    const gripCb = (side: number): void => {
      if (side !== this.gripSide) {
        this.gripSide = side;
        // 换手后清掉手动拖动位置：胶囊立即回到该手一侧（"智感握姿"要跟着手走）
        this.sysTabX = -1;
        this.sysTabY = -1;
        // 分屏退出浮钮同样跟手（用户没拖过才跟；拖过则尊重手动位置）
        if (this.compareSplit && !this.exitBtnDragged) {
          this.exitBtnX = side === -1 ? 10 : this.rootWidth - 44;
        }
        // 自动滚屏的暂停浮钮**始终跟手**（用户要求：换左手就该到左边去）。
        // 这颗钮是"随时叫停 / 继续"的临时控件，跟手比保住手动位置更重要，
        // 所以不像分屏退出钮那样受"用户拖过就不再跟"的限制。
        // 判据用 floatBtnVisible()（暂停时钮还在，也该跟着手走；朗读会话同理）。
        // **横向移动带动画**：瞬移太生硬，滑动过去才看得出"它跟着手走了"。
        if (this.floatBtnVisible()) {
          const targetX: number = this.sideToX(side, 44);
          if (targetX !== this.pauseBtnX) {
            this.getUIContext().animateTo({ duration: 320, curve: Curve.FastOutSlowIn }, () => {
              this.pauseBtnX = targetX;
            });
          }
        }
      }
    };
    const gripCtx = this.ctx();
    if (gripCtx !== null) {
      GripAware.startWithPermission(gripCtx, gripCb).catch(() => {
        // 权限/能力不可用：保持居中
      });
    } else {
      GripAware.start(gripCb);
    }
    // **跨设备分享监听**（碰一碰 + 隔空传送）：阅读页内有效，离开时注销。
    // 设备不支持 HarmonyShare 时内部静默跳过。
    ShareKitService.startListening((): string | null => {
      return this.currentDocSharePath();
    });
  }

  /** 原 aboutToDisappear 的内容：由 NavDestination.onHidden 转发进来（被盖住时）。 */
  private onHiddenNow(): void {
    this.flushProgress();
    // 离开阅读页：结算这段阅读时长（后台停留已在退后台时先停表，不会多算）
    this.settleReadTime(false);
    // **从「全部待办」进来时给书架留一个"回来"的信号**（用户要求：退出文件后
    // 返回全部待办页面，而不是落回书架）。书架在 NavDestination.onWillDisappear
    // 里读它 —— 那时机在本方法之后，标志一定已经写好。
    if (this.fromTaskBoard) {
      AppStorage.setOrCreate('readerExitToTasks', true);
    }
    // 离开阅读页：叠加层标志一并复位（防残留导致侧滑返回失灵）
    AppStorage.setOrCreate('readerOverlayOpen', false);
    // 离开阅读页：亮度交还系统（-1.0 的语义见 AppWindow 注释），常亮一并关闭。
    // 回到本页时 onShown 会按设置重新下发。
    setWindowBrightnessLevel(0);
    setKeepScreenOn(false);
    // **退出系统选择模式**（防残留）：该模式是"当前块"的临时状态，
    // 离开页面还留着会让后续交互状态错乱（用户反馈图模块偶现无反应疑似与其相关）
    if (this.systemSelectBlock.length > 0) {
      this.systemSelectBlock = '';
      this.sysTabX = -1;
      this.sysTabY = -1;
    }
    // 停掉跨设备分享监听（碰一碰 / 隔空传送只在阅读页有效）
    ShareKitService.stopListening();
    // 停掉握姿监听：不在阅读页时没必要一直占着传感器
    GripAware.stop();
    // 停掉自动滚屏：定时器跨页面空转会一直耗电（离开页面必须收干净）
    this.stopAutoScroll();
    // 朗读也要收干净：TTS 引擎不释放会一直占着音频通道，回到书架还在念
    this.stopReadAloud();
    // 停掉深浅探测器：不在本页时不必问系统
    stopThemeWatchdog();
  }

  /**
   * 当前文档的沙箱绝对路径（碰一碰 / 隔空传送分享用）。
   * 内置文档在 rawfile 不在磁盘 → 返回 null（不可分享）。
   */
  private currentDocSharePath(): string | null {
    if (this.docName.length === 0 || this.docBuiltin) {
      return null;
    }
    const c = this.ctx();
    if (c === null) {
      return null;
    }
    try {
      const meta = DocStore.find(c, this.docName);
      if (meta === undefined || meta.builtin) {
        return null;
      }
      const path: string = DocStore.docAbsolutePath(c, meta);
      return fs.accessSync(path) ? path : null;
    } catch (err) {
      return null;
    }
  }

  /** 阅读显示设置（常亮 / 亮度）变化时立即作用于主窗口。 */
  onDisplaySettingChanged(): void {
    this.applyDisplaySettings();
  }

  /**
   * 首行缩进变化：换 renderEpoch（条目 key 里含它）→ 正文当帧重建。
   * 真机上仅靠 @Prop 下发时，List 里已挂载的条目会被复用、缩进要退出重进才生效。
   */
  onIndentChanged(): void {
    this.renderEpoch++;
  }

  private applyDisplaySettings(): void {
    setKeepScreenOn(this.keepOn);
    setWindowBrightnessLevel(this.brightLevel);
  }

  /** 一镜到底·进场：从来源封面矩形展开到全屏（官方 BookFlip 几何算法）。 */
  /** 一镜到底·进场：几何已由书架算好、并已在 aboutToAppear 就位（首帧不闪），
   *  这里只负责把它动画展开到全屏（官方 BookFlip 的 doEnterAnimation）。 */
  private heroEnter(): void {
    if (this.heroInit === null) {
      return;   // 无来源几何（菜单入口等）：普通进入
    }
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: 420, curve: Curve.FastOutSlowIn }, () => {
        this.heroScale = 1;
        this.heroX = 0;
        this.heroY = 0;
        this.heroClipW = '100%';
        this.heroClipH = '100%';
        this.heroBg = 1;
      });
    }, 32);
  }

  /** 一镜到底·退场：缩回来源封面位置后再真正返回（动画期间下层书架可见）。 */
  private heroExit(): void {
    if (this.heroExiting) {
      return;
    }
    const init: HeroInit | null = this.heroInit;
    if (init === null) {
      this.backNow();
      return;
    }
    this.heroExiting = true;
    this.flushProgress();
    this.getUIContext().animateTo({
      duration: 400,
      curve: Curve.FastOutSlowIn,
      onFinish: () => {
        this.heroExiting = false;
        this.backNow();
      }
    }, () => {
      this.heroScale = init.scale;
      this.heroX = init.translateX;
      this.heroY = init.translateY;
      this.heroClipW = init.clipW;
      this.heroClipH = init.clipH;
      this.heroBg = 0;
    });
  }

  /** 真正返回（路由 back）。**不要在这里调 heroExit，否则递归**。 */
  private backNow(): void {
    try {
      if (this.stack !== null) {
        this.stack.pop();
      }
    } catch (err) {
      this.toast(L10n.t('返回失败'));
    }
  }

  /** 主题变化时同步系统栏图标颜色 + 整树重建正文。 */
  onThemeChanged(): void {
    applyAppColorMode(this.themeMode);
    applySystemBarTheme(this.isDark());
    this.applyThemeChange();
  }

  // 说明：@StorageProp('systemDark') 上的 @Watch **实机不触发**（见 AppWindow 注释），
  // 所以刷新靠 onShownNow / onThemeChanged 里的 applyThemeChange()，不依赖它。

  /**
   * 明暗真的变了才整树重建正文（renderEpoch 拼在所有正文条目的 key 上）。
   * 深浅切换后正文颜色 / 代码块底色 / 图表缓存深浅一次刷新到位。
   */
  private applyThemeChange(): void {
    const dark: boolean = this.isDark();
    // **只按本页自己的上次值判断**：全局标记会因其它页面先切过而返回"没变"，
    // 导致正文条目不重建、文字停在旧主题（深色下深字看不清 —— 用户实测）。
    if (this.lastAppliedValid && this.lastAppliedDark === dark) {
      markThemeApplied(dark);
      return;
    }
    this.lastAppliedDark = dark;
    this.lastAppliedValid = true;
    markThemeApplied(dark);
    this.getUIContext().animateTo(this.animateParam(), () => {
      // 两个都要加：renderEpoch 换条目 key，themeEpoch 换 **List 容器** key
      //（容器不换 key，已挂载的条目 / 按钮会被复用、颜色不更新——用户反馈的现象）
      this.renderEpoch++;
      this.themeEpoch++;
      // **半模态面板也要重建**：面板内容由 bindSheet 的 builder 渲染、不跟随宿主
      // 状态刷新——深色切换时面板会出现"切换不完全"（正文变了、面板还是旧色）
      this.sheetEpoch++;
    });
    // 公式图缓存键含深浅（deep 主题的字色不同）——重建任务生成新键的图
    this.rebuildFormulaTasks();
    // 图表/公式块缓存键 v4 起还含**卡片底色**（五档主题孪生款底色不同）——
    // 切主题后按新底色重收预渲染任务，新键的图才会生成（否则只能一直走实时渲染）
    this.chartTasks = this.collectChartTasks(dark);
    // 抽屉公式图键含深浅（批注/脚注里的公式随主题重出）
    this.rebuildDrawerFormulaTasks();
  }

  /** 字号 / 行高等影响正文排版的设置变化 → 强制正文条目重建。 */
  onVisualChanged(): void {
    this.renderEpoch++;
    // 公式图缓存键含字号——不重建任务就会一直查询"新字号键"（永远没有的图），
    // 公式回落成线性化文本（用户实测"字体放大缩小后渲染消失"）
    this.rebuildFormulaTasks();
    // 抽屉公式图键同样含字号（批注/脚注里的公式随字号重出）
    this.rebuildDrawerFormulaTasks();
  }

  /**
   * 重建行内公式图任务。
   *
   * 行内公式图的缓存键 = hash(**字号** + 深浅 + 源码 + 代际盐)。字号或深浅一变，
   * 旧键失效、新键尚无图——**必须重算任务清单**（否则队列里还是旧键的任务，
   * 新键的图永远不会被生成，公式长期停留在线性化文本）。已生成过的键由
   * InlineFormulaPool 自动跳过（秒级恢复）；首次生成后台排队进行。
   */
  private rebuildFormulaTasks(): void {
    this.formulaTasks = FormulaTasks.collect(this.blocks, this.isDark(), this.fontSize);
  }

  /**
   * 重收**注释抽屉**的公式图任务（批注原文 + 备注 + 脚注；关 MathJax 时 collectText
   * 返回空）。抽屉项 generate=false 只读缓存，本池是它们唯一的出图通道：
   * 公式学习卡 / 公式批注的原文与正文公式同键（同字号同深浅）→ 直接命中缓存秒显；
   * 用户在备注里手写的 $…$ 由本池生成。
   */
  private rebuildDrawerFormulaTasks(): void {
    const out: FormulaTask[] = [];
    const addAll = (src: string): void => {
      const t: FormulaTask[] = FormulaTasks.collectText(src, this.isDark(), this.fontSize);
      for (let q = 0; q < t.length; q++) {
        out.push(t[q]);
      }
    };
    for (let k = 0; k < this.annotations.length; k++) {
      const ann: MdAnnotation = this.annotations[k];
      if (ann.note.startsWith('hw:')) {
        continue;
      }
      addAll(ann.text);
      addAll(ann.note);
    }
    for (let k = 0; k < this.notes.length; k++) {
      addAll(this.notes[k].text);
    }
    this.drawerFormulaTasks = out;
  }

  /**
   * 「设置 → 引擎管理」里有引擎被开关 → 重收渲染任务：
   *   · 行内公式（MathJax）：collect 在引擎关闭期间返回空，重新开启后要补生成；
   *   · 图表预渲染（各引擎）：关闭时停止给后台池派新活，开启时补跑一遍。
   * 正文块自身的显隐由 MdBlockView 订阅同一 AppStorage 键即时重渲染，无需换 key。
   */
  onEnginesChanged(): void {
    // 换 renderEpoch 强制正文重建：真机上子组件的 @StorageProp 不保证回刷
    //（readerIndent 先例），key 驱动的整列表重建是项目铁律的兜底手段
    this.renderEpoch++;
    this.rebuildFormulaTasks();
    this.chartTasks = this.collectChartTasks(this.isDark());
  }

  /**
   * 图表 / 公式后台预渲染任务收集（块序；含"已关闭引擎跳过"）。
   *
   * 顺序 = **块序**（同一块先块级公式/图表、再该块的行内公式）：用户从文档
   * 头部开始阅读，前面的内容先就绪。此前"块级全部先、行内全部排后"会把
   * 文档开头的行内公式挤到队尾，长时间只能看到线性化文本。
   *
   * 已关闭引擎的块不进队列（设置 → 引擎管理）：后台池不再为它渲染，
   * 也不会把"已关闭"的图写进缓存（正文由 MdView 直接显示源码兜底卡）。
   */
  private collectChartTasks(dark: boolean): ChartTask[] {
    const out: ChartTask[] = [];
    for (let k = 0; k < this.blocks.length; k++) {
      const b: MdBlock = this.blocks[k];
      let mode: string = '';
      if (b.kind === MdBlockKind.Math) {
        // **块级公式不进烘焙队列**（用户拍板"直接全透明"）：截图必然带一层底色矩形，
        // 于是同一篇里"烘过的公式"是一块白底、"没烘的"是透底正文，两种长相混在一起。
        // 公式没有需要截图的交互成本，正文与导出都直接用 KaTeX 实时渲染就是真透明，
        // 尺寸也天然跟着字号走 —— 顺带绕开公式图的所有尺寸口径问题。
        // （行内公式仍然要烘：它是 ImageSpan 混排在文字里，必须有位图。）
        continue;
      } else if (b.kind === MdBlockKind.Chart) {
        mode = b.lang.toLowerCase();
      }
      if (mode.length === 0) {
        continue;
      }
      // html 块是原生 WebView 预览（无第三方引擎），langId 返回空串 → isOff 恒 false
      if (EngineRegistry.isOff(EngineRegistry.langId(mode), this.disabledEngineList)) {
        continue;
      }
      // **脑图走专用实时卡片**（用户拍板）：markmap 卡片始终实时渲染（自带拖拽 /
      // 缩放可浏览整图），不经过后台池截图——拍摄管线对脑图的适配成本远高于
      // 实时渲染收益（此前多轮"卡片只剩窄条"均源于此）。
      if (mode === 'markmap') {
        continue;
      }
      // **salt / ditaa / nwdiag：进池烘图、但正文仍走实时卡片**（2026-10-16 调整）：
      // 这三张是澄笺自绘的 HTML 模板。正文曾因"实时卡与烘焙图两层叠加"（用户实测
      // "阅读界面显示了 2 层卡片、覆盖掉了"）而整体排除出池子——那是对**正文显示**
      // 的防护；但导出 / 打印同样靠"池子的快照图"（没图就退化成现场渲染的容器），
      // 这三类一直烘不出来 → 导出里永远是"要 JS 现场画的容器"，和"图表一律用
      // 生成的图片"的目标相悖。现在**只为导出 / 打印供图**而烘（正文的"用图分支"
      // 在 MdView.isPoolOnlyLang 里对这三类保持排除，显示行为一点不变）。
      // **HTML 预览必须留在实时 Web 上**（用户实测"卡片上无法操作，只能放大后才行"）：
      // html 块的产物是**可交互网页**（按钮、canvas 触摸），一旦进后台池烘焙成 PNG，
      // 正文就会走 chartImagePath 的静态图分支——看着一样，点起来是死的。
      // 放大浮层本来就是实时 Web，所以只有卡片坏，症状才这么偏。
      if (mode === 'html') {
        continue;
      }
      // 键含卡片底色（v4）：五档主题的深浅孪生款 codeBlockBg 不同，
      // 不区分会复用别主题烘焙的图（"深色下背景发红/发绿"——用户实测）
      out.push({
        key: ChartCache.keyFor(mode, b.code, dark, withAlpha(this.palette().codeBlockBg, 'FF')),
        mode: mode,
        payload: b.code
      } as ChartTask);
    }
    return out;
  }

  // ══════════════════════ 顶栏 / 底栏的收起与展开 ══════════════════════
  //
  // 旧版用「首个可见块下标跳变」判断方向，块小的时候滚一屏跨几十个下标，
  // 轻轻一滑栏就没了——用户感知是「不正常消失」。现在改成**累计位移阈值**：
  // 往下读累计超过约四行才收，往回翻任何一帧立刻展开，回到顶部强制展开。
  // 收起时外层容器高度折叠到只剩系统栏避让，正文真实扩大（而不是被隐形栏占着）。

  private toggleAllBars(show: boolean): void {
    // 沉浸阅读期间不允许把栏条带回来（滚动收放 / 回到顶部强制展开都要让路）
    if (this.immersiveRead) {
      return;
    }
    if (this.topBarVisible === show && this.bottomBarVisible === show) {
      return;
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.topBarVisible = show;
      this.bottomBarVisible = show;
    });
  }

  private toggleTopBar(show: boolean): void {
    if (this.immersiveRead) {
      return;
    }
    if (this.topBarVisible === show) {
      return;
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.topBarVisible = show;
    });
  }

  private toggleBottomBar(show: boolean): void {
    if (this.immersiveRead) {
      return;
    }
    if (this.bottomBarVisible === show) {
      return;
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.bottomBarVisible = show;
    });
  }

  /** 放大浮层当前内容是否带源码（图表 / HTML / 代码本身）。 */
  private enlargeHasCode(): boolean {
    const m: string = this.enlargeMode.toLowerCase();
    // **本身就是源码放大**（从代码块点放大进来）：不显示"查看源码"开关 ——
    // 它已经是源码，再切没有意义，早前的实现还会让状态错乱（用户实测点击会出错）。
    if (m === 'code' && this.enlargePrevMode.length === 0) {
      return false;
    }
    return m === 'mermaid' || m === 'zenuml' || m === 'markmap' || m === 'echarts' || m === 'abc'
      || m === 'graphviz' || m === 'flowchart' || m === 'wavedrom' || m === 'html'
      || m === 'nomnoml' || m === 'chart' || m === 'vega' || m === 'plantuml' || m === 'code';
  }

  /**
   * 放大浮层里「查看源码 ↔ 返回预览」（用户要求：按钮放在「减」左边）。
   * 切换只换 `enlargeMode`（渲染形态），payload 不变 —— 缩放 / 旋转参数都保留。
   */
  private toggleEnlargeCode(): void {
    if (this.enlargeMode.toLowerCase() === 'code') {
      this.enlargeMode = this.enlargePrevMode.length > 0 ? this.enlargePrevMode : 'code';
      return;
    }
    this.enlargePrevMode = this.enlargeMode;
    this.enlargeMode = 'code';
    // 图表源码不是任何编程语言，必须清掉高亮 HTML（否则会拿上一次的配色乱染一屏）
    this.enlargeRichHtml = '';
    // 指定高亮行同理：源码视图里没有围栏元数据可依据
    this.enlargeHlCsv = '';
  }

  /**
   * 可下载的放大内容：**公式与图表**（两者都是"渲染出来的画"，存成 PNG 才有意义）。
   * 代码 / 图片 / 网页预览不出下载按钮：代码该复制、图片本身就在磁盘上、网页预览
   * 是交互内容，截一张图都不合适（与撤下那版的按钮口径一致）。
   * ⚠️ 只认**有独立渲染模板**的图种：zenuml 是 mermaid 模板内部的图种（放大时
   * mode 仍是 mermaid），单独放进来会指向一份不存在的模板。
   */
  private dlSupported(): boolean {
    const m: string = this.enlargeMode.toLowerCase();
    return m === 'katex' || m === 'mermaid' || m === 'echarts' || m === 'abc'
      || m === 'graphviz' || m === 'flowchart' || m === 'plantuml'
      || m === 'wavedrom' || m === 'vega' || m === 'chart'
      || m === 'nomnoml' || m === 'ditaa' || m === 'nwdiag'
      || m === 'salt' || m === 'markmap';
  }

  /**
   * 下载当前放大内容 —— **另开一块渲染表面重画一遍**再存文件，不是截屏幕上那块。
   *
   * v1~v4 四版都从"看得见的表面"截图（池子小快照 → 裁边 → 浮层大画布现场截图 →
   * 整页模式），四版都不达预期；根因是浮层那块 Web 被画布容器 `.clip(true)` 裁着、
   * 高度被画布钉死 —— 屏外内容**根本不在那块表面里**。这里改走独立表面：
   * 浅色白底、按内容自然尺寸渲染、不被任何容器裁剪（见 DiagramDownloadHost）。
   */
  private startEnlargeDownload(): void {
    if (this.dlBusy || this.enlargeMode.length === 0 || !this.dlSupported()) {
      return;
    }
    // 排版宽度 = 放大时的画布宽（与用户看到的排版逐字一致；超宽公式由渲染链路
    // 按这个宽度等比缩进画面，不靠"把容器开得很宽"去装）
    const w: number = this.canvasW > 0 ? this.canvasW : 360;
    // 脑图**不回传自然高度**（它没有自然尺寸，画布就是容器）：宿主钉死表面高度 =
    // 画布高，autoFit 铺满 —— 与浮层里看到的那张脑图完全一致
    const isMm: boolean = this.enlargeMode.toLowerCase() === 'markmap';
    const fh: number = isMm && this.canvasH > 0 ? this.canvasH : 0;
    const job: DlJob = {
      mode: this.enlargeMode,
      payload: this.enlargePayload,
      width: w,
      forceHeight: fh
    };
    this.dlBusy = true;
    this.toast(L10n.t('正在生成图片，请稍候…'));
    this.dlJob = job;
  }

  /** 文件名：优先用放大内容的标题（图表/公式的标题就是它的来源标题），清洗非法字符 */
  private dlFileName(): string {
    const base: string = this.enlargeTitle.length > 0
      ? this.enlargeTitle
      : (this.enlargeMode.length > 0 ? this.enlargeMode : 'image');
    return base.replace(/[\\/:*?"<>|]/g, '_') + '.png';
  }

  /**
   * 快照产物 → 裁边 → 尺寸上限保护 → 系统「另存为」。
   * 渲染表面用完即卸（本方法第一件事就是清 dlJob），后面全是本地字节处理。
   */
  private onDlDone(pixel: image.PixelMap, w: number, h: number): void {
    this.dlJob = null;
    const name: string = this.dlFileName();
    this.saveDlPng(pixel, name);
  }

  private async saveDlPng(pixel: image.PixelMap, name: string): Promise<void> {
    const ctx: common.UIAbilityContext | null = this.ctx();
    try {
      const packer: image.ImagePacker = image.createImagePacker();
      let bytes: ArrayBuffer = await packer.packToData(pixel, { format: 'image/png', quality: 100 });
      try {
        pixel.release();
      } catch (re) {
        // 释放失败无副作用（进程回收兜底）
      }
      // **裁到内容包围盒**（用户要求：长宽就是渲染内容的边界、大片空白不要）：
      // 渲染页四周的内边距、引擎自带的居中留白、脑图 autoFit 的边距全在这一步去掉，
      // 只留 12 设备像素呼吸边。
      bytes = await ChartCache.trimPng(bytes);
      // 尺寸上限保护：极端大的图（超长边或超大像素面积）**等比**缩一档 ——
      // 横纵同倍率，不拉伸不挤压；正常尺寸的公式/图表完全不受影响。
      bytes = await ChartCache.capPngSize(bytes, DL_PNG_MAX_AREA, DL_PNG_MAX_SIDE);
      if (ctx === null) {
        this.dlBusy = false;
        return;
      }
      const docPicker = new picker.DocumentViewPicker(ctx);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [name];
      docPicker.save(options).then((uris: string[]) => {
        if (uris.length === 0) {
          this.dlBusy = false;
          return;
        }
        let file: fs.File | null = null;
        try {
          file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
          fs.writeSync(file.fd, bytes);
          this.toast(L10n.t('已保存图片（浅色背景）'));
        } catch (err) {
          this.toast(L10n.t('写入文件失败'));
        } finally {
          if (file !== null) {
            try {
              fs.closeSync(file);
            } catch (closeErr) {
              // 关闭失败无副作用
            }
          }
          this.dlBusy = false;
        }
      }).catch((err: BusinessError) => {
        // 用户取消另存也是这条（系统选择器 reject），不报错
        this.dlBusy = false;
      });
    } catch (err) {
      this.toast(L10n.t('图片生成失败，请重试'));
      this.dlBusy = false;
    }
  }

  /** 渲染/快照失败：如实说清楚，别让浮层停在"生成中" */
  private onDlFail(reason: string): void {
    this.dlJob = null;
    this.dlBusy = false;
    // narrow = 平台没能把这块表面按宽度渲染完（理论上不会发生：表面宽度 = 画布宽，
    // 从不超过屏幕）——如实告知，不存一张缺右边的图
    this.toast(reason === 'narrow'
      ? L10n.t('这张图太宽，没能完整出图')
      : L10n.t('图片生成失败，请重试'));
  }

  /** 切换沉浸阅读：进入即收起顶栏 / 底栏，退出即恢复。 */
  private toggleImmersive(): void {
    const next: boolean = !this.immersiveRead;
    this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
      this.immersiveRead = next;
      this.topBarVisible = !next;
      this.bottomBarVisible = !next;
    });
  }

  /**
   * 程序化滚动前调用：跳转的目标位置要让用户看见上下文。
   * @param expand 跳转后是否展开栏条。标签切换/进度恢复**不展开**——
   *               用户刚把栏收起来，切个标签栏又弹回来，非常打扰。
   */
  private lockAutoHide(expand: boolean = true): void {
    this.autoHideLockUntil = Date.now() + 700;
    this.scrollAccum = 0;
    if (expand) {
      this.toggleAllBars(true);
    }
  }

  /**
   * onDidScroll 每帧调用；offset 正值 = 向下滚（往文档深处读）。
   *
   * 防闪三件套：
   *  · **迟滞阈值**——收要累计 +120，展要累计 -60，两个阈值拉开，在边界附近怎么抖都不会来回切；
   *  · **方向切换清零**——上一帧还是正的这帧变负，说明是回弹不是用户意图，累计作废；
   *  · **切换后冷却 320ms**——刚收起时列表常有一小段反向回弹，冷却期内不受理。
   */
  private onScrollFrame(offset: number): void {
    if (Date.now() < this.autoHideLockUntil) {
      return;
    }
    // 浮层开着时保持展开：查找条挂在顶栏下面，栏收走它也跟着没了
    if (this.searchOpen || this.anyDrawerOpen() || this.activeSheet !== '') {
      this.toggleAllBars(true);
      return;
    }
    if (offset > 0) {
      if (this.scrollAccum < 0) {
        this.scrollAccum = 0;
      }
      this.scrollAccum += offset;
      if (this.scrollAccum > 120) {
        this.scrollAccum = 0;
        this.toggleAllBars(false);
        this.autoHideLockUntil = Date.now() + 320;
      }
    } else if (offset < 0) {
      if (this.scrollAccum > 0) {
        this.scrollAccum = 0;
      }
      this.scrollAccum += offset;
      if (this.scrollAccum < -60) {
        this.scrollAccum = 0;
        this.toggleAllBars(true);
        this.autoHideLockUntil = Date.now() + 320;
      }
    }
  }

  // ══════════════════════ 数据 ══════════════════════

  private ctx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  private loadDoc(): void {
    // 换文档：先把上一篇的阅读时长结掉，再为下一篇起算
    this.settleReadTime(true);
    const ctx = this.ctx();
    if (ctx === null || this.docName.length === 0) {
      return;
    }
    try {
      DocStore.init(ctx);
      const meta: DocMeta | undefined = DocStore.find(ctx, this.docName);
      if (meta === undefined) {
        this.loadError = '文档不存在，可能已被删除。';
        this.blocks = [];
        this.toast(this.loadError);
        return;
      }
      // 书架「⋯ → 文档编码」可能给这篇设过编码（AppStorage 按文档存）→ 优先采用
      const storedEnc: string | undefined = AppStorage.get<string>('docEncoding_' + this.docName);
      if (storedEnc !== undefined && storedEnc.length > 0) {
        this.docEncoding = storedEnc;
      }
      const text: string = DocStore.readText(ctx, meta, this.docEncoding);
      // 原文留一份：图片管理要按 Markdown 片段在正文里做精确替换（改一张图不动别处）
      this.rawContent = text;
      const result: MdParseResult = MdParser.parse(text);
      this.blocks = result.blocks;
      // 换文档 / 换编码都从首批重新开始（否则上一份文档的加载进度会带过来）
      this.visibleBlocks = 80;
      this.docOutline = result.outline;
      this.notes = result.notes;
      this.annotations = AnnotationStore.load(ctx, this.docName);
      this.renderEpoch++;
      this.docMeta = result.meta;
      this.docBuiltin = meta.builtin;
      // 只读标记（未设过时：内置教程只读、自建文档可写）
      this.docReadOnly = DocStore.isReadOnly(ctx, this.docName);
      // 书架里设过的自定义封面在这里沿用（详情头的小封面与书架保持一致）。
      // 可选属性先落局部常量再判空——就地 `x === undefined ? '' : x` 在 ArkTS 里不收窄
      const cc: string | undefined = meta.coverColor;
      const ci: string | undefined = meta.coverImage;
      this.docCoverColor = cc === undefined ? '' : cc;
      this.docCoverImage = ci === undefined || ci.length === 0
        ? '' : DocStore.resolveImagePath(ci);
      this.docWordCount = result.wordCount;
      this.docCharCount = result.charCount;
      this.docHeadingCount = result.headingCount;
      this.docCodeCount = result.codeBlockCount;
      this.docTableCount = result.tableCount;
      // 文件实况信息（大小 / MD5）：文档很小，同步现算一次即可
      const finfo: DocFileInfo | null = DocStore.fileInfo(ctx, this.docName);
      this.docSizeBytes = finfo !== null ? finfo.sizeBytes : -1;
      this.docMd5 = finfo !== null ? finfo.md5 : '';
      // 创建 / 修改日期与收藏标记（信息卡展示 + 爱心按钮）
      const times: DocTimes = DocStore.fileTimes(ctx, this.docName);
      this.docCreatedAt = times.created;
      this.docModifiedAt = times.modified;
      this.docStarred = DocStore.isStarred(ctx, this.docName);
      // **图表 / 公式后台预渲染任务**（用户要求：打开文件即后台加载转图片并写缓存，
      // 不等滑到位置才加载；导出也直接用缓存图）。收集与排序、已关闭引擎跳过
      // 见 collectChartTasks（设置 → 引擎管理）。
      const dark: boolean = this.isDark();
      this.chartTasks = this.collectChartTasks(dark);
      // **行内公式图任务**：MathJax → PNG（含字号；图未就绪时正文回落线性化文本）
      this.formulaTasks = FormulaTasks.collect(this.blocks, dark, this.fontSize);
      // **多设备流转数据源**（应用接续）：迁移发起时 EntryAbility.onContinue
      // 从这里取当前文档与进度
      AppStorage.setOrCreate('continueDocName', this.docName);
      AppStorage.setOrCreate('continueDocContent', text);
      AppStorage.setOrCreate('continueDocProgress', meta.progressRatio);
      // **标签栏自愈**（用户要求）：指向已删除文档的标签自动移除
      for (let t = this.tabs.length - 1; t >= 0; t--) {
        if (this.tabs[t].name !== this.docName
          && DocStore.find(ctx, this.tabs[t].name) === undefined) {
          TabStore.close(this.tabs[t].name);
          this.tabs = TabStore.list();
        }
      }
      this.loadError = '';
      this.progress = meta.progressRatio;
      this.progressBlock = meta.progressIndex;
      this.activeHeading = result.outline.length > 0 ? result.outline[0].text : '';
      // ── 恢复阅读位置 ──
      // · 任务勾选后的重载：不跳（用户就停在原地）
      // · 首次加载：交给 List 的 initialIndex（构造时就定好，不会「先顶部再闪跳」）
      // · 之后（切标签等）：List 已存在，只能用 scrollToIndex，等一帧布局后再跳
      const jumpTarget: number = meta.progressIndex > 0 ? meta.progressIndex + this.headerCount() : 0;
      if (this.skipRestoreOnce) {
        this.skipRestoreOnce = false;
        this.pendingJump = -1;
      } else if (this.firstLoad) {
        // 「全部待办」点条目进来：**首帧就定到那一行**（initialIndex 在构造时生效，
        // 与恢复进度同一套机制，不会「先渲染顶部再闪跳」）。pendingJump 一并给上，
        // 让 applyPendingJump 走完剩下的收尾（定位提示 / 关抽屉）。
        let initial: number = jumpTarget;
        let jump: number = -1;
        if (this.routeFocusLine > 0) {
          const bi: number = this.blockIndexOfLine(this.routeFocusLine);
          if (bi >= 0) {
            initial = bi + this.headerCount();
            jump = bi;
          }
        }
        this.listInitialIndex = initial;
        this.pendingJump = jump;
      } else {
        this.pendingJump = meta.progressIndex > 0 ? meta.progressIndex : 0;
      }
      DocStore.touch(ctx, this.docName);
      // 等列表完成一次布局后再跳转，否则 Scroller 还没绑定到组件
      setTimeout(() => {
        this.applyPendingJump();
      // 等一帧布局完成再跳（列表刚重建，Scroller 还没绑定）
      }, 120);
    } catch (err) {
      this.loadError = '读取失败：' + DocStore.describeError(err as BusinessError);
      this.blocks = [];
      this.toast(this.loadError);
    }
  }

  // ══════════════════════ 读写 / 只读 ══════════════════════
  //
  // 每篇文档一个持久标记（shelf.json），书架「选择操作」与阅读页「更多」共用同一套语义：
  // 只读 = 锁住「改写正文」这条路（编辑页入口 + 任务勾选框不写盘）；
  // 阅读 / 批注 / 封面 / 导出 / 亮度一概照常。

  /** 详情头那行状态文案（内置 / 自建 + 当前读写状态）。 */
  private docStatusLine(): string {
    const kind: string = this.docBuiltin ? L10n.t('内置语法教程') : L10n.t('自建文档');
    // 用户要求：徽标后带上文档**格式**（md / txt）
    const fmt: string = this.docName.toLowerCase().endsWith('.txt') ? 'TXT' : 'MD';
    if (this.docReadOnly) {
      return kind + ' · ' + fmt + ' · 只读 · 可在「更多」里切换';
    }
    return kind + ' · ' + fmt + ' · 可写' + (this.docBuiltin ? L10n.t(' · 常驻第一格') : '');
  }

  /** 切换读写 / 只读（写 shelf.json，切当前这篇）。 */
  private toggleDocReadOnly(readOnly: boolean): void {
    if (this.docReadOnly === readOnly) {
      return;
    }
    const ctx = this.ctx();
    if (ctx === null || this.docName.length === 0) {
      return;
    }
    try {
      if (!DocStore.setReadOnly(ctx, this.docName, readOnly)) {
        this.toast(L10n.t('切换失败：文档不存在'));
        return;
      }
      this.docReadOnly = readOnly;
      this.toast(readOnly ? L10n.t('已切为只读：编辑入口已锁') : L10n.t('已切为可写：可以编辑了'));
    } catch (err) {
      this.toast('切换失败：' + DocStore.describeError(err as BusinessError));
    }
  }

  /** 含行内公式的块 key 后缀（`_m<就绪数>`）——实现见 FormulaTasks.readySuffix。 */
  private inlineReadySuffix(block: MdBlock): string {
    return FormulaTasks.readySuffix(this.ctx(), block, this.isDark(), this.fontSize);
  }

  /** 列表里正文块之前占用的条目数：信息卡可开关，隐藏后正文块下标整体前移 1 位。 */
  private headerCount(): number {
    return this.showMetaCard ? LIST_HEADER_COUNT : 0;
  }

  /** 文件大小展示：B / KB / MB；未知（-1）显示「—」。 */
  private fileSizeLabel(): string {
    if (this.docSizeBytes < 0) {
      return '—';
    }
    if (this.docSizeBytes < 1024) {
      return this.docSizeBytes + ' B';
    }
    if (this.docSizeBytes < 1024 * 1024) {
      return (Math.round(this.docSizeBytes / 102.4) / 10) + ' KB';
    }
    return (Math.round(this.docSizeBytes / 10485.76) / 100) + ' MB';
  }

  private applyPendingJump(): void {
    if (this.pendingJump < 0) {
      return;
    }
    const target: number = this.pendingJump;
    this.pendingJump = -1;
    // 文档间链接带来的锚点（一次性消费）：优先于进度恢复，定位到对应标题。
    // 新开的文档没有进度（target<=0），锚点跳转也不能被早退挡掉。
    const anchor: string = TabStore.consumeAnchor(this.docName);
    if (anchor.length > 0) {
      this.jumpToAnchor(anchor);
      return;
    }
    // 「全部待办」点条目进来的目标行（一次性消费）：**比进度恢复优先**——
    // 用户是冲着某一条待办来的，不能又被"上次读到哪"拉走。
    if (this.routeFocusLine > 0) {
      const line: number = this.routeFocusLine;
      this.routeFocusLine = 0;
      this.jumpToSourceLine(line);
      return;
    }
    if (target <= 0) {
      return;
    }
    // 切标签/进度恢复的跳转**不展开栏条**：用户刚收起来，跳一下又弹回去非常打扰
    this.lockAutoHide(false);
    try {
      this.scroller.scrollToIndex(target + this.headerCount(), false, ScrollAlign.START);
    } catch (err) {
      // 列表尚未就绪时忽略，用户仍可手动滚动
    }
    // 全库搜索跳转进来：布局稳定后打开查找条并定位首个命中（一次性）
    if (this.routeQuery.length > 0) {
      const query: string = this.routeQuery;
      this.routeQuery = '';
      this.openSearch();
      this.runSearch(query);
    }
  }

  private flushProgress(): void {
    const ctx = this.ctx();
    if (ctx === null || this.docName.length === 0 || !this.progressDirty) {
      return;
    }
    this.progressDirty = false;
    try {
      DocStore.saveProgress(ctx, this.docName, this.progressBlock, this.progress);
      // 桌面卡片即时刷新：进度落盘后推一次（30 秒节流在 FormSync 内部）
      FormSync.pushRecents(ctx);
    } catch (err) {
      // 进度丢失不影响阅读
    }
  }

  // ══════════════════════ 多标签页 ══════════════════════
  //
  // 移植自参考项目：再次打开已打开的文档聚焦既有标签而非重复开；
  // 每个标签的滚动位置复用 DocStore 的进度存储，切换即恢复现场；
  // 标签列表与激活项落盘 tabs.json，重启后进入阅读页自动恢复。
  // 手机没有中键/右键：关闭用标签上的 ×，长按标签弹菜单。

  /** 在标签中打开文档：已在当前标签则直接跳锚点，否则切换过去。 */
  private openInTab(name: string, anchor: string): void {
    if (name === this.docName) {
      if (anchor.length > 0) {
        this.jumpToAnchor(anchor);
      }
      return;
    }
    this.flushProgress();
    this.closeSearch();
    const ctx = this.ctx();
    if (ctx !== null) {
      TabStore.open(name, anchor);
    }
    this.tabs = TabStore.list();

    // 切换标签的滑入动画：新标签在右边就从右滑进来，在左边就从左滑进来
    let oldIdx: number = 0;
    let newIdx: number = 0;
    for (let k = 0; k < this.tabs.length; k++) {
      if (this.tabs[k].name === this.docName) {
        oldIdx = k;
      }
      if (this.tabs[k].name === name) {
        newIdx = k;
      }
    }
    const dir: number = newIdx >= oldIdx ? 1 : -1;
    this.docName = name;
    // **翻页动效**（参考 animation-collection）：新内容从切换方向整页滑入 + 淡入
    this.contentSlideX = dir * this.rootWidth * 0.5;
    this.contentFade = 0.3;
    this.loadDoc();
    // 滑到位：位移 + 透明度一起回位，就是一次「翻页」
    this.getUIContext().animateTo({ duration: 320, curve: Curve.FastOutSlowIn }, () => {
      this.contentSlideX = 0;
      this.contentFade = 1;
    });
  }

  private activateTab(name: string): void {
    this.openInTab(name, '');
  }

  private closeTab(name: string): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const wasActive: boolean = name === this.docName;
    if (wasActive) {
      this.flushProgress();
    }
    let next: string = '';
    // **包在 animateTo 里**：标签芯片的 transition（淡出）才会播放，
    // 兄弟标签也会以布局动画滑动补位（用户要求）
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      next = TabStore.close(name);
      this.tabs = TabStore.list();
    });
    this.closeTabMenu();
    if (next.length === 0) {
      // 最后一个标签关掉了，回书架
      try {
        // 返程共享元素动画：必须包在 animateTo 里
        this.getUIContext().animateTo({ duration: 350, curve: Curve.FastOutSlowIn }, () => {
          // 一镜到底退场：先缩回书架封面位置，动画结束再真正返回
          this.heroExit();
        });
      } catch (err) {
        this.toast(L10n.t('返回失败'));
      }
      return;
    }
    if (wasActive && next !== this.docName) {
      this.docName = next;
      this.loadDoc();
    }
  }

  private closeOtherTabs(name: string): void {
    TabStore.closeOthers(name);
    this.tabs = TabStore.list();
    this.closeTabMenu();
    if (name !== this.docName) {
      this.flushProgress();
      this.docName = name;
      this.loadDoc();
    }
  }

  private closeAllTabs(): void {
    TabStore.closeAll();
    this.tabs = TabStore.list();
    this.closeTabMenu();
    try {
      // 返程共享元素动画：必须包在 animateTo 里
      this.getUIContext().animateTo({ duration: 350, curve: Curve.FastOutSlowIn }, () => {
        // 一镜到底退场：先缩回书架封面位置，动画结束再真正返回
        this.heroExit();
      });
    } catch (err) {
      this.toast(L10n.t('返回失败'));
    }
  }

  /** 重新解析当前文档（标签菜单里的「刷新」）。 */
  private reloadActiveDoc(): void {
    this.closeTabMenu();
    this.loadDoc();
    this.toast(L10n.t('已重新加载'));
  }

  private openTabMenu(name: string): void {
    this.tabMenuFor = name;
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.activeSheet = 'tabMenu';
      this.sheetVisible = true;
    });
  }

  private closeTabMenu(): void {
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.sheetVisible = false;
    });
  }

  /** 标签上显示的名字：长文档名截中间，留出 × 的位置。 */
  private tabLabel(name: string): string {
    if (name.length <= 10) {
      return name;
    }
    return name.substring(0, 8) + '…';
  }

  /** 内部文档链接（`[文字](./other.md#锚点)`）：在书架里定位后开标签跳转。 */
  private openDocLink(href: string): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    let h: string = href.trim();
    let anchor: string = '';
    const hashAt: number = h.indexOf('#');
    if (hashAt >= 0) {
      anchor = h.substring(hashAt + 1);
      h = h.substring(0, hashAt);
    }
    try {
      h = decodeURIComponent(h);
    } catch (err) {
      // 解码失败按原文处理
    }
    let base: string = h.substring(h.lastIndexOf('/') + 1);
    if (base.startsWith('./')) {
      base = base.substring(2);
    }
    const lower: string = base.toLowerCase();
    if (lower.endsWith('.markdown')) {
      base = base.substring(0, base.length - 9);
    } else if (lower.endsWith('.md')) {
      base = base.substring(0, base.length - 3);
    } else if (lower.endsWith('.txt')) {
      base = base.substring(0, base.length - 4);
    }
    if (base.length === 0) {
      this.toast(L10n.t('链接没有指向任何文档'));
      return;
    }
    const meta: DocMeta | undefined = DocStore.findByLinkTarget(ctx, base);
    if (meta === undefined) {
      this.toast('书架里找不到《' + base + '》');
      return;
    }
    this.openInTab(meta.name, anchor);
  }

  // ══════════════════════ 阅读背景色 ══════════════════════

  @StorageLink('readerCustomBgLight') customBgLight: string = '';
  @StorageLink('readerCustomBgDark') customBgDark: string = '';

  /**
   * 当前的自定义阅读背景色；**没选时用固定默认色（不再回退主题渐变）**。
   *
   * ⚠️ 用 `bgDark()`（只看系统深浅）而不是 `isDark()`（含主题档位）：
   * 「阅读背景」**完全独立于主题**（用户明确要求"默认固定是阅读背景颜色"）——
   * 没选自定义色 = 固定纸白 / 碳黑，切主题（羊皮纸/护眼绿/深色）阅读背景永远不变。
   * 主题只管文字 / 卡片 / 强调色（palette 链），背景与主题彻底分家。
   */
  private pageBackground(): string {
    if (this.bgDark()) {
      return this.customBgDark.length > 0 ? this.customBgDark : READER_BG_DEFAULT_DARK;
    }
    return this.customBgLight.length > 0 ? this.customBgLight : READER_BG_DEFAULT_LIGHT;
  }

  /**
   * 目录 / 批注侧边栏在**关闭沉浸光感**时的底色：与当前阅读背景**同色**。
   *
   * ⚠️ 不能只读 `pageBackground()`（自定义纯色 / 固定纸白碳黑）——阅读背景实际有
   * 更高优先级的来源，与 `backdrop()` 的取层顺序必须**逐条对齐**：
   *   ① 阅读背景图 → ② 阅读背景生成壁纸 → ③ 外观壁纸图 → ④ 外观生成壁纸 → ⑤ 纯色
   * 之前只做了 ⑤，而 `readerBgId` 出厂默认就是「竹影」（一款淡青渐变壁纸），
   * 于是关掉光感的侧边栏永远是 #FAF7F1（白）/#141414（黑），
   * 跟背景完全对不上（用户反馈"颜色还是白色或黑色，没有变成背景选的颜色"）。
   *
   * 图片类背景（①③）取不到主色，就用**与背景层同浓度的遮罩色**当面板底色：
   * 半透明 + 面板自身的 `backgroundBlurStyle(Thin)`，观感是"背景图被磨砂压暗的一块"，
   * 色温与整屏一致，不会跳出一块纯白/纯黑。
   */
  private readerBgColor(): string {
    // ① 阅读背景图：沿用阅读背景层的遮罩（半透明，透出图片色调）
    if (this.readerBgPath.length > 0) {
      return WallpaperStore.scrimColorOf(this.readerBgScrim(), this.bgDark());
    }
    // ② 阅读背景生成壁纸：取当前深浅下生效款的主底色
    if (this.readerBgId.length > 0) {
      const c: string = genWallpaperFlatColor(this.readerBgId, this.bgDark(),
        this.customWallA, this.customWallB);
      if (c.length > 0) {
        return c;
      }
    }
    // ③ 外观壁纸图：同上，用外观壁纸的遮罩浓度
    if (this.wallpaperPathEffective().length > 0) {
      return WallpaperStore.scrimColorOf(this.wallpaperScrim, this.bgDark());
    }
    // ④ 外观生成壁纸
    if (this.genWallId.length > 0) {
      const c: string = genWallpaperFlatColor(this.genWallId, this.bgDark(),
        this.customWallA, this.customWallB);
      if (c.length > 0) {
        return c;
      }
    }
    // ⑤ 自定义纯色阅读背景；再兜底固定默认纸色
    const c: string = this.pageBackground();
    return c.length > 0 ? c : this.palette().pageTop;
  }

  // ══════════════════════ 批注 ══════════════════════

  /**
   * 正文批注事件入口（由 MdBlockView 回调上来）。
   * 增删改一律走「整份替换 + 落盘」，不做增量更新——批注数量少，
   * 整体写入的一致性比省一次 IO 重要得多。
   */
  private onAnnotate(action: string, blockId: string, start: number, end: number,
                     text: string, color: number): void {
    if (action === 'remove') {
      this.removeAnnotations(blockId, start, end);
      return;
    }
    if (action === 'note' || action === 'mathnote') {
      this.pendingBlockId = blockId;
      this.pendingStart = start;
      this.pendingEnd = end;
      this.pendingColor = -1;
      this.pendingStyle = '';
      this.noteQuote = text;
      // 公式批注：面板要带渲染与源码编辑。非公式路径必须清空，否则上一次的
      // 公式上下文会留在面板里（源码编辑框出现在普通文字批注面板上）。
      if (action === 'mathnote') {
        this.noteMathQuote = text;
        this.noteMathBlockId = blockId;
        this.noteMathBase = start;
      } else {
        this.clearMathNoteContext();
      }
      // **恢复未过期的草稿**：不小心退出后再点「添加批注」，之前写的内容还在；
      // 超过 3 分钟视为已放弃（避免很久以后突然冒出旧草稿）。
      const draftAt: number = AppStorage.get<number>(NOTE_DRAFT_AT_KEY) ?? 0;
      if (draftAt > 0 && Date.now() - draftAt <= NOTE_DRAFT_TTL) {
        this.noteDraft = AppStorage.get<string>(NOTE_DRAFT_KEY) ?? '';
      } else {
        this.noteDraft = '';
      }
      this.getUIContext().animateTo(this.animateParam(), () => {
        // **换纪元重建面板**：NotePanel 的 init* 只在组件创建那一刻读一次，
        // 而 bindSheet 的内容实例可能被复用；不换纪元就会把上一条批注的草稿/原文
        // 带进新面板（sheetEpoch 这套约定原本就是为"面板内容不跟宿主刷新"准备的）
        this.sheetEpoch++;
        this.activeSheet = 'note';
        this.sheetVisible = true;
      });
      return;
    }
    // **学习卡**（1.1.0）：实色黄底高亮 + 必填批注内容，数据供「复习卡片 / 批注速记」使用
    if (action === 'studycard' || action === 'mathstudycard') {
      this.pendingBlockId = blockId;
      this.pendingStart = start;
      this.pendingEnd = end;
      this.pendingColor = 3;            // 默认黄色（ANNOTATION_COLORS 索引 3）
      this.pendingStyle = 'card';       // 实色底形态（见 MdView.pieceBackground）
      this.noteQuote = text;
      // 公式学习卡与公式批注共用同一个面板（渲染 + 源码 + 选段），只是形态预选卡片
      if (action === 'mathstudycard') {
        this.noteMathQuote = text;
        this.noteMathBlockId = blockId;
        this.noteMathBase = start;
      } else {
        this.clearMathNoteContext();
      }
      this.noteDraft = '';
      AppStorage.setOrCreate(NOTE_DRAFT_KEY, '');
      AppStorage.setOrCreate(NOTE_DRAFT_AT_KEY, 0);
      this.getUIContext().animateTo(this.animateParam(), () => {
        // **换纪元重建面板**：NotePanel 的 init* 只在组件创建那一刻读一次，
        // 而 bindSheet 的内容实例可能被复用；不换纪元就会把上一条批注的草稿/原文
        // 带进新面板（sheetEpoch 这套约定原本就是为"面板内容不跟宿主刷新"准备的）
        this.sheetEpoch++;
        this.activeSheet = 'note';
        this.sheetVisible = true;
      });
      return;
    }
    // **handwrite：手写批注**（用户要求）—— 记下选区，去手写页画；
    // 画完回来把手写图存成 'dbl'（红色双下划线）批注。
    if (action === 'handwrite') {
      this.pendingBlockId = blockId;
      this.pendingStart = start;
      this.pendingEnd = end;
      this.pendingColor = -1;
      this.noteQuote = text;
      this.clearMathNoteContext();
      AppStorage.setOrCreate('sketchMode', 'annotate');
      AppStorage.setOrCreate('sketchAnnotationImage', '');
      if (this.stack !== null) {
        this.stack.pushPath({ name: 'pages/Sketch' });
      } else {
        this.toast(L10n.t('当前环境无法打开手写页'));
      }
      return;
    }
    // wavy：波浪线标注（画在字下方），与荧光笔同属「同区间先清再写」
    if (action === 'wavy') {
      const list: MdAnnotation[] = this.withoutOverlap(this.annotations, blockId, start, end);
      list.push(this.buildAnnotation(blockId, start, end, text, -1, '', 'wavy'));
      this.commitAnnotations(list);
      this.toast(L10n.t('已添加波浪线'));
      return;
    }
    // sysselect：该块进入"系统选择模式"（恢复系统原生长按菜单，方便复制 / 翻译 / 唤起小艺）
    if (action === 'sysselect') {
      this.systemSelectBlock = blockId;
      this.toast(L10n.t('长按文字可复制 / 翻译 / 唤起小艺；点一下正文退出'));
      return;
    }
    // highlight：同一区间先清掉旧批注再写入，避免反复涂抹层层叠加
    const list: MdAnnotation[] = this.withoutOverlap(this.annotations, blockId, start, end);
    list.push(this.buildAnnotation(blockId, start, end, text, color, '', ''));
    this.commitAnnotations(list);
    this.toast('已添加' + this.colorName(color) + '荧光笔');
  }

  private colorName(index: number): string {
    if (index < 0 || index >= ANNOTATION_COLORS.length) {
      return '';
    }
    return ANNOTATION_COLORS[index].name + '色';
  }

  private buildAnnotation(blockId: string, start: number, end: number, text: string,
                          color: number, note: string, style: string): MdAnnotation {
    const now: number = Date.now();
    const ann: MdAnnotation = {
      id: blockId + '_' + start + '_' + end + '_' + now,
      blockId: blockId,
      start: start,
      end: end,
      text: text,
      color: color,
      note: note,
      style: style,
      created: now
    };
    return ann;
  }

  /** 去掉与该区间重叠的既有批注（同块内）。 */
  private withoutOverlap(list: MdAnnotation[], blockId: string,
                         start: number, end: number): MdAnnotation[] {
    const kept: MdAnnotation[] = [];
    for (let k = 0; k < list.length; k++) {
      const a: MdAnnotation = list[k];
      if (a.blockId === blockId && !(a.end <= start || a.start >= end)) {
        continue;
      }
      kept.push(a);
    }
    return kept;
  }

  private removeAnnotations(blockId: string, start: number, end: number): void {
    const kept: MdAnnotation[] = [];
    let removed: number = 0;
    for (let k = 0; k < this.annotations.length; k++) {
      const a: MdAnnotation = this.annotations[k];
      if (a.blockId === blockId && !(a.end <= start || a.start >= end)) {
        removed++;
        continue;
      }
      kept.push(a);
    }
    if (removed === 0) {
      this.toast(L10n.t('这一段没有批注'));
      return;
    }
    this.commitAnnotations(kept);
    this.toast('已清除 ' + removed + ' 条批注');
  }

  private commitAnnotations(list: MdAnnotation[]): void {
    this.annotations = list;
    this.renderEpoch++;
    // 抽屉的公式图任务随批注增删重收（新增公式学习卡 / 公式批注 → 新任务入池）
    this.rebuildDrawerFormulaTasks();
    const ctx = this.ctx();
    if (ctx !== null) {
      AnnotationStore.save(ctx, this.docName, list);
    }
  }

  /** 清空公式批注上下文（非公式路径与关闭面板时都要调，避免面板串成公式态）。 */
  private clearMathNoteContext(): void {
    this.noteMathQuote = '';
    this.noteMathBlockId = '';
  }

  /**
   * 「保存公式」：把编辑框里的 LaTeX 写回原文并重载正文。
   *
   * 两种形态定位方式不同：
   *   · 块级公式（`$$…$$` / `\[…\]`）：整块就是一个行段，按原有定界符与
   *     单行/多行形态替换 `[起始行, 闭合行]`；
   *   · 行内公式（段落里的 `$…$`）：在该块的行段里找整串 `$旧源码$` 替换。
   *
   * ⚠️ **任何一步定位不上都只提示、不动文件**（与表格写回同一套纪律）：写坏原文
   * 比不写严重得多。重载后块序号不变（替换的是同一段行区间、且仍解析成一个块），
   * 所以批注锚点 noteMathBase 直接续用，区间尾端按新源码长度重算。
   *
   * 返回是否真的写回成功 —— NotePanel 只在成功时把本地基准换成新源码，
   * 失败时面板维持原状（预览与"只批选中段"的定位才不会跟正文脱节）。
   */
  private saveMathEdit(edited: string): boolean {
    const ctx = this.ctx();
    if (ctx === null || this.noteMathBlockId.length === 0) {
      return false;
    }
    const newLatex: string = edited.trim();
    if (newLatex.length === 0) {
      this.toast(L10n.t('公式源码是空的，未写回'));
      return false;
    }
    if (newLatex === this.noteMathQuote) {
      this.toast(L10n.t('源码没有变化'));
      return false;
    }
    const idx: number = this.blockIndexOf(this.noteMathBlockId);
    if (idx < 0) {
      this.toast(L10n.t('找不到对应的公式块，未写回'));
      return false;
    }
    const block: MdBlock = this.blocks[idx];
    try {
      const meta: DocMeta | undefined = DocStore.find(ctx, this.docName);
      if (meta === undefined) {
        this.toast(L10n.t('文档不存在'));
        return false;
      }
      const text: string = DocStore.readText(ctx, meta, this.docEncoding);
      const lines: string[] = text.replace(/\r\n?/g, '\n').split('\n');
      const spanEnd: number = idx + 1 < this.blocks.length
        ? this.blocks[idx + 1].srcLine : lines.length;
      const out: string[] | null = block.kind === MdBlockKind.Math
        ? this.spliceMathBlock(lines, block, newLatex)
        : this.spliceInlineMath(lines, block.srcLine, spanEnd, this.noteMathQuote, newLatex);
      if (out === null) {
        return false;
      }
      DocStore.update(ctx, this.docName, out.join('\n'));
      this.skipRestoreOnce = true;
      this.loadDoc();
      // 面板保持打开：改完源码接着批注是常见路径
      this.noteMathQuote = newLatex;
      if (idx < this.blocks.length) {
        this.noteMathBlockId = this.blocks[idx].id;
      }
      this.pendingEnd = this.noteMathBase + newLatex.length;
      this.toast(L10n.t('公式已写回文档'));
      return true;
    } catch (err) {
      this.toast('保存失败：' + DocStore.describeError(err as BusinessError));
      return false;
    }
  }

  /**
   * 块级公式写回：替换 `[起始行, 闭合行]` 整段。
   * 用 `block.code`（解析结果）反查校验——行段按解析口径重新取出的 LaTeX 必须与它
   * 一致，否则说明文档在打开后被改过（行号已漂），此时绝不落笔。
   */
  private spliceMathBlock(lines: string[], block: MdBlock, newLatex: string): string[] | null {
    const start: number = block.srcLine;
    if (start < 0 || start >= lines.length) {
      this.toast(L10n.t('该公式所在位置无法定位，未写回'));
      return null;
    }
    const head: string = lines[start].trim();
    let delim: string = '';
    let close: string = '';
    if (head.startsWith('$$')) {
      delim = '$$';
      close = '$$';
    } else if (head.startsWith('\\[')) {
      delim = '\\[';
      close = '\\]';
    } else {
      this.toast(L10n.t('该公式所在位置无法定位，未写回'));
      return null;
    }
    if (newLatex.indexOf(delim) >= 0 || newLatex.indexOf(close) >= 0) {
      this.toast('源码里不能包含「' + delim + '」，未写回');
      return null;
    }
    // 单行形态（$$x$$）闭合就是本行；否则向后找到以 close 结尾的行
    let end: number = -1;
    let single: boolean = false;
    if (head.length > delim.length + close.length && head.endsWith(close)) {
      end = start;
      single = true;
    } else {
      for (let k = start + 1; k < lines.length; k++) {
        if (lines[k].trim().endsWith(close)) {
          end = k;
          break;
        }
      }
    }
    if (end < 0) {
      this.toast(L10n.t('没找到这条公式的闭合行，未写回'));
      return null;
    }
    // 按解析口径重取正文，与 block.code 比对。**要和 MdParser 逐行同构**（首行余量
    // 空串也压、中间行含空行照压、闭合行只在非空时压）：解析层保留了块内的空行
    // （\begin{cases} 之类），这里若把空行滤掉，比对必然失配、把合法写回误拒。
    const body: string[] = [];
    if (single) {
      body.push(head.substring(delim.length, head.length - close.length).trim());
    } else {
      body.push(head.substring(delim.length).trim());
      for (let k = start + 1; k < end; k++) {
        body.push(lines[k].trim());
      }
      const tail: string = lines[end].trim();
      const seg: string = tail.substring(0, tail.length - close.length).trim();
      if (seg.length > 0) {
        body.push(seg);
      }
    }
    if (body.join('\n').trim() !== block.code) {
      this.toast(L10n.t('文档已改动，位置对不上了，未写回'));
      return null;
    }
    const replacement: string[] = single
      ? [delim + newLatex + close]
      : [delim].concat(newLatex.split('\n'), [close]);
    return lines.slice(0, start).concat(replacement, lines.slice(end + 1));
  }

  /**
   * 行内公式写回：在块的行段里整串替换 `$旧源码$`（兼容 `\(旧源码\)`）。
   * 找不到、或同一段里出现多处相同源码（不知道该改哪一处）都拒绝写回。
   */
  private spliceInlineMath(lines: string[], from: number, to: number,
                           oldLatex: string, newLatex: string): string[] | null {
    if (oldLatex.length === 0) {
      this.toast(L10n.t('原公式源码为空，未写回'));
      return null;
    }
    if (newLatex.indexOf('$') >= 0) {
      this.toast(L10n.t('行内公式源码里不能包含 $，未写回'));
      return null;
    }
    const forms: string[][] = [['$' + oldLatex + '$', '$' + newLatex + '$'],
      ['\\(' + oldLatex + '\\)', '\\(' + newLatex + '\\)']];
    const lo: number = Math.max(0, from);
    const hi: number = Math.min(lines.length - 1, to);
    for (let f = 0; f < forms.length; f++) {
      const needle: string = forms[f][0];
      let hitLine: number = -1;
      let hits: number = 0;
      for (let k = lo; k <= hi; k++) {
        let at: number = lines[k].indexOf(needle);
        while (at >= 0) {
          hits += 1;
          hitLine = k;
          at = lines[k].indexOf(needle, at + needle.length);
        }
      }
      if (hits === 0) {
        continue;
      }
      if (hits > 1) {
        this.toast(L10n.t('这里有不止一处相同的公式源码，无法确定改哪一处，未写回'));
        return null;
      }
      const fixed: string = lines[hitLine].split(needle).join(forms[f][1]);
      const out: string[] = lines.slice(0, hitLine).concat([fixed], lines.slice(hitLine + 1));
      return out;
    }
    this.toast(L10n.t('这条行内公式在原文里定位不到（可能写法带空格），未写回'));
    return null;
  }

  /**
   * 批注落库（NotePanel 提交回调）。
   * @param draft0 批注正文
   * @param style  '' 普通批注 / 'card' 学习卡（面板里可切换，所以形态在这里定）
   * @param sub    面板中选中的公式子串；'' = 整条公式
   */
  private saveNoteDraft(draft0: string, style: string, sub: string): void {
    if (this.pendingStart < 0) {
      this.sheetVisible = false;
      return;
    }
    const draft: string = draft0.trim();
    const isCard: boolean = style === 'card';
    this.pendingStyle = style;
    // 学习卡要实色底（同 studycard 入口的口径：默认黄色索引 3）
    this.pendingColor = isCard ? 3 : -1;
    let aStart: number = this.pendingStart;
    let aEnd: number = this.pendingEnd;
    let aText: string = this.noteQuote;
    // 公式批注：按**文档现存源码**给选中段定位（组件交回的是文本，不是偏移——
    // 偏移属于面板，区间属于文档，写回后只有这边这份是最新的）
    if (this.noteMathQuote.length > 0 && sub.length > 0) {
      const at: number = this.noteMathQuote.indexOf(sub);
      if (at >= 0) {
        aStart = this.noteMathBase + at;
        aEnd = aStart + sub.length;
        aText = sub;
      }
    }
    const list: MdAnnotation[] = this.withoutOverlap(this.annotations, this.pendingBlockId,
      aStart, aEnd);
    list.push(this.buildAnnotation(this.pendingBlockId, aStart, aEnd,
      aText, this.pendingColor, draft, this.pendingStyle));
    this.commitAnnotations(list);
    this.pendingStart = -1;
    this.pendingStyle = '';
    this.clearMathNoteContext();
    // 提交成功 → 清掉草稿（3 分钟窗口结束，避免下次打开又冒出旧内容）
    AppStorage.setOrCreate(NOTE_DRAFT_KEY, '');
    AppStorage.setOrCreate(NOTE_DRAFT_AT_KEY, 0);
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.sheetVisible = false;
    });
    this.toast(isCard ? L10n.t('已添加学习卡，可在书架「文房」复习') : L10n.t('已添加批注'));
  }

  /** 批注形态分类文字（用户要求：四类标识独立展示，不串）。 */
  private annoKindLabel(ann: MdAnnotation): string {
    if (ann.style === 'card') {
      return '学习卡';
    }
    if (ann.style === 'wavy') {
      return '波浪线';
    }
    if (ann.style === 'dbl') {
      return '手写批注';
    }
    return ann.note.length > 0 ? L10n.t('文字批注') : L10n.t('荧光笔');
  }

  /** 当前实际存在的形态种类（固定顺序，没有的过滤掉 —— 用户要求）。 */
  private availableKinds(): string[] {
    const fixed: string[] = ['学习卡', '文字批注', '荧光笔', '波浪线', '手写批注'];
    const out: string[] = [];
    for (let f = 0; f < fixed.length; f++) {
      for (let k = 0; k < this.annotations.length; k++) {
        if (this.annoKindLabel(this.annotations[k]) === fixed[f]) {
          out.push(fixed[f]);
          break;
        }
      }
    }
    return out;
  }

  /** 某一形态的批注数量。 */
  private kindCount(kind: string): number {
    let n: number = 0;
    for (let k = 0; k < this.annotations.length; k++) {
      if (this.annoKindLabel(this.annotations[k]) === kind) {
        n++;
      }
    }
    return n;
  }

  /**
   * 分类筛选钮（用户要求：**沉浸光感效果**、字体大一点）——
   * 用 ImmersiveChip 承载（自带材质层与按压反馈）。
   */
  @Builder
  kindChip(label: string, kind: string, count: number) {
    ImmersiveChip({
      palette: this.palette(),
      chipActive: this.notesFilter === kind,
      chipFontSize: HwType.caption + 2,
      chipLabel: label,
      chipOnTap: () => {
        this.notesFilter = this.notesFilter === kind ? '' : kind;
      }
    })
  }

  /** 按分类筛选后的批注（notesFilter 空 = 全部）。 */
  private filteredAnnotations(): MdAnnotation[] {
    // 筛选的分类已不存在（批注被删）时自动回到"全部"，避免列表空转
    if (this.notesFilter.length > 0 && this.availableKinds().indexOf(this.notesFilter) < 0) {
      return this.annotations;
    }
    if (this.notesFilter.length === 0) {
      return this.annotations;
    }
    const out: MdAnnotation[] = [];
    for (let k = 0; k < this.annotations.length; k++) {
      if (this.annoKindLabel(this.annotations[k]) === this.notesFilter) {
        out.push(this.annotations[k]);
      }
    }
    return out;
  }

  // ── 注释侧栏：搜索（关键词过滤，与分类筛选叠加）──

  /** 展开 / 收起搜索条（带动画；收起时清词） */
  private toggleNotesSearch(): void {
    this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
      this.notesSearchOpen = !this.notesSearchOpen;
      if (!this.notesSearchOpen) {
        this.notesQuery = '';
      }
    });
  }

  /** 单条批注是否命中搜索词（正文 / 备注 / 分类名都参与匹配）。 */
  private annHit(ann: MdAnnotation): boolean {
    const q: string = this.notesQuery.trim().toLowerCase();
    if (q.length === 0) {
      return true;
    }
    if (ann.text.toLowerCase().indexOf(q) >= 0) {
      return true;
    }
    if (ann.note.length > 0 && ann.note.toLowerCase().indexOf(q) >= 0) {
      return true;
    }
    return this.annoKindLabel(ann).toLowerCase().indexOf(q) >= 0;
  }

  /** 按分类 + 关键词双重过滤后的批注（侧栏列表用）。 */
  private searchedAnnotations(): MdAnnotation[] {
    const base: MdAnnotation[] = this.filteredAnnotations();
    if (this.notesQuery.trim().length === 0) {
      return base;
    }
    const out: MdAnnotation[] = [];
    for (let i = 0; i < base.length; i++) {
      if (this.annHit(base[i])) {
        out.push(base[i]);
      }
    }
    return out;
  }

  /** 脚注列表按关键词过滤。 */
  private searchedNotes(): MdNote[] {
    const q: string = this.notesQuery.trim().toLowerCase();
    if (q.length === 0) {
      return this.notes;
    }
    const out: MdNote[] = [];
    for (let i = 0; i < this.notes.length; i++) {
      const n: MdNote = this.notes[i];
      if (n.text.toLowerCase().indexOf(q) >= 0 || n.label.toLowerCase().indexOf(q) >= 0) {
        out.push(n);
      }
    }
    return out;
  }

  private deleteAnnotation(ann: MdAnnotation): void {
    const kept: MdAnnotation[] = [];
    for (let k = 0; k < this.annotations.length; k++) {
      if (this.annotations[k].id !== ann.id) {
        kept.push(this.annotations[k]);
      }
    }
    this.commitAnnotations(kept);
    this.toast(L10n.t('已删除批注'));
  }

  /** 按块 id 跳转；正文被改过导致找不到时给出提示而不是静默失败。 */
  private jumpToBlockId(blockId: string): void {
    const index: number = this.blockIndexOf(blockId);
    if (index < 0) {
      this.toast(L10n.t('这段正文已被修改，位置已失效'));
      return;
    }
    this.jumpTo(index);
  }

  /** 块 id → 块下标；找不到返回 -1。 */
  private blockIndexOf(blockId: string): number {
    for (let k = 0; k < this.blocks.length; k++) {
      if (this.blocks[k].id === blockId) {
        return k;
      }
    }
    return -1;
  }

  // ══════════════════════ 导出 HTML ══════════════════════
  //
  // 移植自参考项目的「导出自包含 HTML」：样式内嵌进单个文件，浏览器可直接打开。
  // 保存位置由系统「另存为」对话框决定，写入的是用户选择的 URI，无需任何权限。

  /**
   * 导出 HTML。
   *
   * **统一走自研渲染器**（MdToHtml）：它完全在我们手里，排版可控、无外部依赖。
   *
   * 原先还挂了一个隐藏 Web 跑 `render/lute.html` 做「更漂亮的排版」，后来发现：
   *   ① 那份 html 的内联脚本转义损坏（真机日志：`Uncaught SyntaxError`、
   *      SVG 属性里混进 `\"`、未闭合字符串把后续 JS 当 URL 去加载）；
   *   ② 常驻挂载这个 Web 会持续刷错误日志，并在画面上留残影
   *      （「关掉查找后残留圆形图标」的元凶）。
   * 既然自研渲染器已经够用，就把 Lute 整条链路**彻底摘掉**，不留半死代码。
   */
  private exportHtml(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    // **智能导出**（用户要求）：渲染库提前缓存到应用内、导出时内嵌（自包含、
    // 离线可渲染）；首次自动下载；下载失败回退在线模式。
    try {
      const content: string = DocStore.readText(ctx, DocStore.find(ctx, this.docName)!, this.docEncoding);
      ExportService.exportHtmlSmart(ctx, this.docName, content, (m: string) => {
        this.toast(m);
      }, this.isDark(), withAlpha(this.palette().codeBlockBg, 'FF'));
    } catch (err) {
      this.toast(L10n.t('导出失败'));
    }
  }

  private saveHtml(ctx: common.UIAbilityContext, html: string): void {
    const docPicker = new picker.DocumentViewPicker(ctx);
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [this.docName + '.html'];
    docPicker.save(options).then((uris: string[]) => {
      if (uris.length === 0) {
        return;
      }
      let file: fs.File | null = null;
      try {
        file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, html);
        this.toast(L10n.t('已导出 HTML'));
      } catch (err) {
        this.toast(L10n.t('写入文件失败'));
      } finally {
        if (file !== null) {
          try {
            fs.closeSync(file);
          } catch (closeErr) {
            // 关闭失败无副作用
          }
        }
      }
    }).catch((err: BusinessError) => {
      this.toast('保存失败：' + err.message);
    });
  }

  // ══════════════════════ 表格可视化编辑 ══════════════════════
  //
  // 点正文表格打开 TableEditorDialog（结构化网格），保存时按块的 srcLine
  // 把 `TableTool.toLines()` 产物写回原文行段并重载 —— 与任务勾选同一套
  // "改原文 + 重载"链路，块 id / 批注坐标由重新 parse 自愈。

  /** 打开表格编辑：从块上的解析结果构造 MdTable（rows[0]=表头，分隔行不在块里）。 */
  private openTableEdit(blockId: string): void {
    if (this.docReadOnly) {
      this.toast(L10n.t('只读文档不能编辑表格，先在「更多」里切成可写'));
      return;
    }
    const idx: number = this.blockIndexOf(blockId);
    if (idx < 0) {
      return;
    }
    const block: MdBlock = this.blocks[idx];
    if (block.rows.length < 1) {
      return;
    }
    const header: string[] = [];
    const headerRaw: string[] = block.rows[0].raw;
    for (let k = 0; k < headerRaw.length; k++) {
      header.push(headerRaw[k]);
    }
    const rows: string[][] = [];
    for (let i = 1; i < block.rows.length; i++) {
      const r: string[] = [];
      const raw: string[] = block.rows[i].raw;
      // 补齐 / 裁齐到表头列数：手写 Markdown 常见某行少写一列，不齐会在网格里错位
      for (let k = 0; k < header.length; k++) {
        r.push(k < raw.length ? raw[k] : '');
      }
      rows.push(r);
    }
    const align: TableAlign[] = [];
    for (let k = 0; k < header.length; k++) {
      const a: number = k < block.aligns.length ? block.aligns[k] : 0;
      align.push(a === 1 ? 'center' : (a === 2 ? 'right' : 'left'));
    }
    this.editTable = { header: header, rows: rows, align: align } as MdTable;
    this.tableEditBlockId = blockId;
    this.tableDialog.open();
  }

  /** 保存表格：写回原文对应行段（表头 + 分隔 + 数据行），重载正文。 */
  private saveTableEdit(): void {
    this.tableDialog.close();
    const ctx = this.ctx();
    if (ctx === null || this.tableEditBlockId.length === 0) {
      return;
    }
    const idx: number = this.blockIndexOf(this.tableEditBlockId);
    if (idx < 0) {
      return;
    }
    const block: MdBlock = this.blocks[idx];
    const srcLine: number = block.srcLine;
    try {
      const meta: DocMeta | undefined = DocStore.find(ctx, this.docName);
      if (meta === undefined) {
        this.toast(L10n.t('文档不存在'));
        return;
      }
      const text: string = DocStore.readText(ctx, meta, this.docEncoding);
      const lines: string[] = text.replace(/\r\n?/g, '\n').split('\n');
      // 定位校验三连（⚠️ 不能拿"编辑后的列数"与原文比对——用户加/删列后必然对不上）：
      // ① srcLine 行确实是表格行；② 下一行是分隔行；③ 不在引用内（行首 '>'）。
      // 引用内表格块的 srcLine 是引用体相对行号，指向原文几乎必然错位，这里一并拦下。
      if (srcLine < 0 || srcLine + 1 >= lines.length
        || lines[srcLine].trim().startsWith('>')
        || !TableTool.isTableRow(lines[srcLine])
        || !TableTool.isDelimiterRow(lines[srcLine + 1])) {
        this.toast(L10n.t('该表格所在位置暂不支持直接写回（如引用内的表格）'));
        return;
      }
      // 行段终点：分隔行下一行起**连续的表格行**（与解析口径一致；不依赖编辑后的行数，
      // 写回本来就要支持增删行改变行数）
      let end: number = srcLine + 2;
      while (end < lines.length && TableTool.isTableRow(lines[end])) {
        end++;
      }
      const newLines: string[] = TableTool.toLines(this.editTable);
      const out: string[] = lines.slice(0, srcLine).concat(newLines, lines.slice(end));
      DocStore.update(ctx, this.docName, out.join('\n'));
      this.tableEditBlockId = '';
      this.skipRestoreOnce = true;
      this.loadDoc();
      this.toast(L10n.t('表格已更新'));
    } catch (err) {
      this.toast('保存失败：' + DocStore.describeError(err as BusinessError));
    }
  }

  // ══════════════════════ 任务列表勾选 ══════════════════════
  //
  // 用户文档：按块记录的源码行号改写原文 `- [ ]` ↔ `- [x]` 并保存重载
  // （只改勾选标记、不动行数，块 id 与批注坐标都不漂移）。
  // 内置教程只读：改内存态供演示，重载后还原。

  /** 勾选后重载时跳过「恢复上次阅读位置」（用户就停在原地）。 */
  private skipRestoreOnce: boolean = false;

  private onTaskToggle(blockId: string): void {
    const idx: number = this.blockIndexOf(blockId);
    if (idx < 0) {
      return;
    }
    const block: MdBlock = this.blocks[idx];
    if (block.task !== MdTaskState.Todo && block.task !== MdTaskState.Done) {
      return;
    }
    const done: boolean = block.task === MdTaskState.Done;
    const flip = (): void => {
      block.task = done ? MdTaskState.Todo : MdTaskState.Done;
      // 只换这一块：以前这里 renderEpoch++ 会把整篇正文重建（所有卡重建成、图表重载、
      // visibleBlocks 打回 80），实测就是"勾一下闪一下 + 收起的栏弹回来"
      this.bumpBlockRev(block.id);
    };
    // 只读文档：勾选**不写盘**（只改内存态供演示，重载后还原）——
    // 与内置教程原来的演示行为一致。
    if (this.docReadOnly) {
      flip();
      this.toast(done ? L10n.t('已取消勾选（只读文档，不写盘）') : L10n.t('已完成（只读文档，不写盘）'));
      return;
    }
    if (this.docBuiltin) {
      flip();
      this.toast(done ? L10n.t('已取消勾选（演示状态，重载后还原）') : L10n.t('已完成（演示状态，重载后还原）'));
      return;
    }
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      const meta: DocMeta | undefined = DocStore.find(ctx, this.docName);
      if (meta === undefined) {
        return;
      }
      const text: string = DocStore.readText(ctx, meta, this.docEncoding);
      const lines: string[] = text.split('\n');
      if (!this.flipTaskMarker(lines, block.srcLine)) {
        this.toast(L10n.t('无法定位勾选框'));
        return;
      }
      DocStore.update(ctx, this.docName, lines.join('\n'));
      // 写盘成功后**不整篇重载**：勾选只改一行里的 `[ ]`↔`[x]`（长度都不变），
      // loadDoc() 会把 blocks / 大纲 / 批注重建一遍、visibleBlocks 打回 80，
      // 用户实测就是"内容闪一下、已收起的顶栏底栏弹出来"。
      // 这里只同步内存里那份原文（后续保存要拿它作基线）+ 就地翻这一块。
      this.rawContent = lines.join('\n');
      flip();
      this.toast(done ? L10n.t('已取消勾选') : L10n.t('已完成'));
    } catch (err) {
      this.toast('勾选失败：' + DocStore.describeError(err as BusinessError));
    }
  }

  /** 把 `lines[lineNo]` 这一行的 `[ ]` ↔ `[x]` 翻过来；不是任务行返回 false。 */
  private flipTaskMarker(lines: string[], lineNo: number): boolean {
    if (lineNo < 0 || lineNo >= lines.length) {
      return false;
    }
    const line: string = lines[lineNo];
    const at: number = line.indexOf('[ ]');
    if (at >= 0) {
      lines[lineNo] = line.substring(0, at) + '[x]' + line.substring(at + 3);
      return true;
    }
    const atLower: number = line.indexOf('[x]');
    const atUpper: number = line.indexOf('[X]');
    const atX: number = atLower >= 0 && (atUpper < 0 || atLower < atUpper) ? atLower : atUpper;
    if (atX < 0) {
      return false;
    }
    lines[lineNo] = line.substring(0, atX) + '[ ]' + line.substring(atX + 3);
    return true;
  }

  /**
   * **折叠面板里**的任务行勾选。面板正文不是独立块（没有 blockId 可查），
   * 所以按"原文行号"回写：先翻块内正文让界面立刻变，再按同一行号翻文件。
   */
  private onTaskLineToggle(blockId: string, lineNo: number): void {
    const idx: number = this.blockIndexOf(blockId);
    if (idx < 0) {
      return;
    }
    const block: MdBlock = this.blocks[idx];
    const bodyStart: number = block.bodyStart === undefined ? block.srcLine + 1 : block.bodyStart;
    const k: number = lineNo - bodyStart;
    const body: string[] = block.codeLines;
    if (k < 0 || k >= body.length || !this.flipTaskMarker(body, k)) {
      return;
    }
    block.code = body.join('\n');
    this.bumpBlockRev(blockId);
    if (this.docReadOnly || this.docBuiltin) {
      // 只读 / 内置教程：勾选只留在内存做演示，重载后还原（与块外任务行为一致）
      return;
    }
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      const meta: DocMeta | undefined = DocStore.find(ctx, this.docName);
      if (meta === undefined) {
        return;
      }
      const lines: string[] = DocStore.readText(ctx, meta, this.docEncoding).split('\n');
      if (!this.flipTaskMarker(lines, lineNo)) {
        this.toast(L10n.t('无法定位勾选框'));
        return;
      }
      DocStore.update(ctx, this.docName, lines.join('\n'));
      this.rawContent = lines.join('\n');
    } catch (err) {
      this.toast('勾选失败：' + DocStore.describeError(err as BusinessError));
    }
  }

  // ══════════════════════ 站内锚点 ══════════════════════

  /** `[文字](#标题)`：按标题文本或**显式锚点 id** 匹配大纲并跳转（文字匹配忽略空白、大小写与常见标点）。 */
  private jumpToAnchor(href: string): void {
    const raw: string = href.startsWith('#') ? href.substring(1) : href;
    const target: string = normalizeAnchor(decodeURIComponent(raw));
    if (target.length === 0) {
      return;
    }
    for (let k = 0; k < this.docOutline.length; k++) {
      // 先认 `{#id}`：以前只比标题文字，于是"显式锚点"只有导出的网页能用，
      // 应用里点了没反应（用户实测"显式锚点与交叉引用没实现"）
      const id: string = this.docOutline[k].anchor === undefined ? '' : normalizeAnchor(this.docOutline[k].anchor);
      if ((id.length > 0 && id === target) || normalizeAnchor(this.docOutline[k].text) === target) {
        this.jumpTo(this.docOutline[k].blockIndex);
        return;
      }
    }
    this.toast('找不到锚点「' + raw + '」');
  }

  // ══════════════════════ 文档内查找 ══════════════════════

  private openSearch(): void {
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.searchOpen = true;
    });
  }

  private closeSearch(): void {
    this.searchQuery = '';
    this.searchHits = [];
    this.searchCursor = -1;
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.searchOpen = false;
    });
  }

  /** 以「块」为命中单位：块内所有命中都会高亮，上一个/下一个在块之间跳。 */
  private runSearch(text: string): void {
    this.searchQuery = text;
    this.renderEpoch++;
    const needle: string = text.trim().toLowerCase();
    const hits: number[] = [];
    if (needle.length > 0) {
      for (let k = 0; k < this.blocks.length; k++) {
        if (this.blocks[k].plain.toLowerCase().indexOf(needle) >= 0) {
          hits.push(k);
        }
      }
    }
    this.searchHits = hits;
    this.searchCursor = hits.length > 0 ? 0 : -1;
    if (this.searchCursor >= 0) {
      this.jumpToSearchHit(hits[0]);
    }
  }

  private stepSearch(delta: number): void {
    const total: number = this.searchHits.length;
    if (total === 0) {
      this.toast(L10n.t('没有匹配的内容'));
      return;
    }
    let next: number = this.searchCursor + delta;
    if (next < 0) {
      next = total - 1;
    }
    if (next >= total) {
      next = 0;
    }
    this.searchCursor = next;
    this.jumpToSearchHit(this.searchHits[next]);
  }

  private searchLabel(): string {
    if (this.searchHits.length === 0) {
      return this.searchQuery.trim().length > 0 ? L10n.t('无匹配') : '';
    }
    return (this.searchCursor + 1) + ' / ' + this.searchHits.length;
  }

  // ══════════════════════ 大纲折叠 ══════════════════════

  private isCollapsed(seq: number): boolean {
    return this.collapsedSeqs.indexOf(seq) >= 0;
  }

  private toggleCollapse(seq: number): void {
    // 折叠/展开包在 animateTo 里：存活行位移、新增/移除行的 transition 才会播放
    this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
      const next: number[] = [];
      let removed: boolean = false;
      for (let k = 0; k < this.collapsedSeqs.length; k++) {
        if (this.collapsedSeqs[k] === seq) {
          removed = true;
          continue;
        }
        next.push(this.collapsedSeqs[k]);
      }
      if (!removed) {
        next.push(seq);
      }
      this.collapsedSeqs = next;
    });
  }

  /**
   * 标题是否有子级。
   * 因为 headingSeq 只对标题自增，所以大纲第 k 项的 seq 恒等于 k+1，
   * 直接用 seq-1 当下标即可，不必再维护映射表。
   */
  private hasChildren(seq: number): boolean {
    const i: number = seq - 1;
    if (i < 0 || i + 1 >= this.docOutline.length) {
      return false;
    }
    return this.docOutline[i + 1].level > this.docOutline[i].level;
  }

  /** 全部展开 / 只保留到二级标题（带折叠动画）。 */
  private setAllCollapsed(collapse: boolean): void {
    this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
      const next: number[] = [];
      if (collapse) {
        for (let k = 0; k < this.docOutline.length; k++) {
          const seq: number = this.docOutline[k].seq;
          if (this.hasChildren(seq)) {
            next.push(seq);
          }
        }
      }
      this.collapsedSeqs = next;
    });
  }

  /** 当前可见的大纲条目：父级被折叠时，其更深层的子级隐藏。 */
  private visibleOutline(): MdHeading[] {
    const out: MdHeading[] = [];
    let hideDeeperThan: number = 0;
    for (let k = 0; k < this.docOutline.length; k++) {
      const h: MdHeading = this.docOutline[k];
      if (hideDeeperThan > 0) {
        if (h.level > hideDeeperThan) {
          continue;
        }
        hideDeeperThan = 0;
      }
      out.push(h);
      if (this.isCollapsed(h.seq)) {
        hideDeeperThan = h.level;
      }
    }
    return out;
  }

  // ══════════════════════ 捏合调字号 ══════════════════════

  /** 启动背景光斑的缓慢漂移：无限往复，两团时长/方向都不同，观感是「缓慢随机游走」 */
  private startBlobDrift(): void {
    // **延迟 600ms 再起漂移动画**（1.1.0 转场降载）：两条无限动画若在转场期间
    // 就开始跑，会与一镜到底的首帧渲染抢主线程（转场流畅度检测不通过的成因之一）；
    // 背景光斑晚半秒开始漂，肉眼不可感知。
    setTimeout(() => {
      this.getUIContext().animateTo({
        duration: 14000, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate
      }, () => {
        this.blobAX = 70;
        this.blobAY = 46;
      });
      this.getUIContext().animateTo({
        duration: 19000, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate
      }, () => {
        this.blobBX = -58;
        this.blobBY = -64;
      });
    }, 600);
  }

  private onPinchStart(): void {
    if (this.enlargeMode.length > 0) {
      // 全屏查看图表时，捏合属于图表缩放，不要改正文字号
      return;
    }
    if (this.webTouchDepth > 0) {
      return;
    }
    this.pinchBaseFont = this.fontSize;
    // 字号变化触发整树重排，滚动回调会跟着抖；捏合期间锁定自动收起
    this.autoHideLockUntil = Date.now() + 1200;
  }

  /** 双指捏合直接改正文字号，等价于参考项目的 Ctrl+滚轮。 */
  private onPinchUpdate(scale: number): void {
    if (this.webTouchDepth > 0) {
      return;
    }
    if (this.enlargeMode.length > 0) {
      // 全屏查看图表时，捏合属于图表缩放，不要改正文字号
      return;
    }
    this.autoHideLockUntil = Date.now() + 1200;
    let next: number = this.pinchBaseFont * scale;
    if (next < HwType.bodyMin) {
      next = HwType.bodyMin;
    }
    if (next > HwType.bodyMax) {
      next = HwType.bodyMax;
    }
    const rounded: number = Math.round(next);
    // 只在取整值真的变了才写，避免连续手势把整棵树反复重渲染
    if (rounded !== this.fontSize) {
      this.fontSize = rounded;
    }
  }

  // ══════════════════════ 主题与尺寸 ══════════════════════

  /**
   * 阅读背景（壁纸 / 纯色）该按**哪一档**取色。
   *
   * ⚠️ **刻意只看 `systemDark`，不看 `themeMode`**（用户要求）：
   * 「阅读背景壁纸」是用户自己挑的那张，**切换主题不该改它的颜色**。
   * 之前这里用 `isDark()`（含主题档位），于是「深色 → 羊皮纸」时遮罩从压黑变压白，
   * 壁纸看起来被"改色"了。现在只有系统真正切深浅时背景才跟着变。
   *
   * 文字/调色板仍走 `palette()`（跟主题），两者各管一摊、互不干扰。
   */
  private bgDark(): boolean {
    return this.systemDark;
  }

  /**
   * 阅读背景层的遮罩浓度：深色下压得更轻（用户反馈"深色太深了"），
   * 只作用于阅读背景（readerBgPath / readerBgId）两层，外观壁纸不受影响。
   */
  private readerBgScrim(): number {
    return this.bgDark() ? Math.round(this.wallpaperScrim * 0.45) : this.wallpaperScrim;
  }

  private isDark(): boolean {
    // 统一转调 isDarkTheme：**羊皮纸 / 护眼绿是浅色纸底**。
    // 之前这里只判 Dark / Light，两档纸色会掉到 systemDark → 系统深色时阅读背景
    // （GenWallpaper darkMode / 遮罩浓度 / 自定义背景色取哪一档）按深色处理，
    // 纸色底被压成黑底，而文字仍取浅色系深绿字 → 黑底浅字看不清。
    return isDarkTheme(this.themeMode, this.systemDark);
  }

  private palette(): ReaderPalette {
    // 三个来源都要显式读一遍落成局部常量：主题色 / 灰字 / 沾色在 paletteFor 里读
    // AppStorage，纯函数读不登记依赖；这里不登记的话主题切换会被 ArkUI 跳过重算
    const tick: number = this.appearanceTick;
    // 羊皮纸 / 护眼绿有独立调色板，必须按主题模式取色，不能只看明暗
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  private measureWidth(): number {
    const w: number = this.measure * this.fontSize + HwSpace.lg * 2;
    return w > this.rootWidth ? this.rootWidth : w;
  }

  /** 抽屉宽度：随屏幕宽度自适应；**宽屏（平板）收紧到 280**，避免侧边栏占比过大。 */
  private drawerWidth(): number {
    const cap: number = this.isWide() ? 280 : 320;
    const w: number = Math.min(cap, this.rootWidth * (this.isWide() ? 0.5 : 0.82));
    return w < 200 ? 200 : w;
  }

  /** 沉浸光感是否真的会渲染（开关 × 材质构造成功）。 */
  private materialOn(): boolean {
    return this.immersiveOn && getImmersiveMaterial() !== null;
  }

  /**
   * 标签芯片底色。
   * **材质可用时必须让出底色**（选中只留一层主题色薄染、未选中全透明）：
   * 否则材质采样到的是这层近实色底，看起来就是普通纯色芯片、没有光感。
   * 材质不可用时才用磨砂 / 淡底兜底（与顶栏同一套配方）。
   */
  private tabBaseColor(name: string): string {
    const selected: boolean = this.docName === name;
    if (this.materialOn()) {
      return selected ? this.palette().accentSoft : '#00000000';
    }
    return selected ? this.palette().accentSoft : barFrostColor(this.palette().surface);
  }

  /**
   * 大屏 / 横屏判定（左右停靠三栏的唯一开关）。
   *
   * ⚠️ **必须同时要求横屏**（用户 2026-10-09 反馈：大屏竖屏下两侧栏被固定显示，
   * 应与手机端一致走侧滑抽屉）：
   *   · 横屏且根宽 ≥700vp → 启用左右停靠三栏（目录默认展开 / 注释默认展开）；
   *   · 竖屏（含平板竖屏、大屏竖屏、折叠屏展开态竖屏）→ 恒为侧滑抽屉。
   * 曾一度放宽为「宽度 ≥700vp 即三栏（不要求横屏）」（多屏协同轮），
   * 结果大屏竖屏也被当成三栏 —— 停靠是**大屏横屏专属**功能，这里补回方向判断。
   */
  private isWide(): boolean {
    return this.rootWidth >= 700 && this.rootWidth > this.rootHeight;
  }

  /** 停靠列开启后，悬浮顶/底栏要让开的左侧宽度。 */
  private barInsetLeft(): number {
    return this.isWide() && this.tocPinned ? this.tocPanelWidth + HwSpace.xs : 0;
  }

  /** 停靠列开启后，悬浮顶/底栏要让开的右侧宽度。 */
  private barInsetRight(): number {
    return this.isWide() && this.notesPinned ? this.notesPanelWidth + HwSpace.xs : 0;
  }

  /**
   * 底部悬浮胶囊的**自适应宽度**：按已有选项实算
   * （进度 38 + 分隔线 1 + 按钮 5×36 + 元素间 6×md 间距 + 胶囊左右内边距 2×xs），
   * 不再整条拉满（用户要求：展开宽度根据已有选项自适应）。
   * 标签条在**胶囊上方**（见 build 的底部层），所以这里不含标签宽度。
   */
  private bottomBarAdaptiveWidth(): number {
    const w: number = 38 + 1 + 36 * 5 + HwSpace.md * 6 + HwSpace.xs * 2;
    return Math.min(w, this.barAreaWidth());
  }

  /**
   * 收起态胶囊宽度：进度 + 阅读设置 + （置底且多标签时）那一排数字。
   * 数字排不进去的话，收起态就看不到标签了——所以宽度必须跟着内容算。
   */
  private bottomBarMiniWidth(): number {
    let w: number = HwBar.miniBottom;
    if (this.tabBarAtBottom && this.tabs.length > 1) {
      w += this.bottomTabsWidth() + HwSpace.xs;
    }
    return Math.min(w, this.barAreaWidth());
  }

  /** 悬浮胶囊里那段标签条的宽度（最多摆 5 个数字芯片，超出可横向滑动）。 */
  private bottomTabsWidth(): number {
    const n: number = this.tabs.length > 5 ? 5 : this.tabs.length;
    return n * 26 + (n - 1) * 5;
  }

  /** 顶/底栏浮层可用宽度：整幅减去两侧停靠列。 */
  private barAreaWidth(): number {
    const w: number = this.expandedBarWidth() - this.barInsetLeft() - this.barInsetRight();
    return w > 200 ? w : 200;
  }

  /**
   * 首屏占位条目高度：让开状态栏 + 悬浮胶囊，多标签时再让开标签页，
   * 查找条打开时也要让开——否则第一屏文字初始就被标签芯片 / 查找条压住
   * （用户要求：初始文字顶部与上方悬浮胶囊保持距离，不被遮挡）。
   * 占位条目只决定首屏起点，滚动后正文照旧从悬浮层底下穿过。
   * **不能**按 topBarVisible 计算：栏收起瞬间占位高度跟着变，列表会跳动。
   */
  private topSpacerHeight(): number {
    let h: number = this.padTop() + HwBar.pill + HwSpace.md;
    // 标签栏置底时不占首屏高度（它挂在底部悬浮栏上方）
    if (this.tabs.length > 1 && !this.tabBarAtBottom) {
      h += HwBar.tabs - 4; // 标签栏实高（与 tabBar() 的 .height() 同源）
    }
    if (this.searchOpen) {
      h += HwBar.pill + HwSpace.xs; // 查找条胶囊 + 其顶间距（与 build() 里搜索行同源）
    }
    return h;
  }

  private togglePinned(kind: string): void {
    // **动画锁**（用户要求）：上一个开合动画没执行完，忽略下一次操作——
    // 快速"收起又拉出"会打断前一动画，正文宽度来回跳（抽搐）
    if (this.sideAnimLock()) {
      return;
    }
    this.getUIContext().animateTo(this.animateParam(), () => {
      if (kind === 'toc') {
        this.tocPinned = !this.tocPinned;
      } else {
        this.notesPinned = !this.notesPinned;
      }
    });
  }

  private closePinned(kind: string): void {
    // **动画锁**：同 togglePinned
    if (this.sideAnimLock()) {
      return;
    }
    this.getUIContext().animateTo(this.animateParam(), () => {
      if (kind === 'toc') {
        this.tocPinned = false;
      } else {
        this.notesPinned = false;
      }
    });
  }

  /** 关闭**单侧**侧边栏：宽屏收停靠列、窄屏收浮层（互不影响另一侧）。 */
  private closeSide(kind: string): void {
    if (this.isWide()) {
      this.closePinned(kind);
      return;
    }
    this.getUIContext().animateTo(this.animateParam(), () => {
      if (kind === 'toc') {
        this.tocOpen = false;
      } else {
        this.notesOpen = false;
      }
    });
  }

  /**
   * **滑出保险（用户建议）**：滑动关闭后，系统把同一个关闭动作再执行一次——
   * 第一次动画结束后强制把对应侧的停靠 / 浮层状态全部清掉，
   * 防止任何中间态残留导致"没有完全滑出"。
   */
  private scheduleDoubleClose(kind: string): void {
    setTimeout(() => {
      if (kind === 'toc') {
        this.tocPinned = false;
        this.tocOpen = false;
      } else {
        this.notesPinned = false;
        this.notesOpen = false;
      }
    }, 320);
  }

  /**
   * 沉浸布局下，正文顶部要避开状态栏。
   * AppWindow 存的是 px，这里换算成 vp——换算依赖 UI 上下文，只能在页面里做。
   * 用 UIContext 上的 px2vp，全局那个已标记废弃。
   */
  private padTop(): number {
    return this.getUIContext().px2vp(this.safeTopPx) + HwSpace.xs;
  }

  /** 底部同理：避开手势条，否则底栏会被系统的横条压住。 */
  private padBottom(): number {
    return this.getUIContext().px2vp(this.safeBottomPx) + HwSpace.xs;
  }

  /**
   * 展开态栏宽 = 整幅减去左右内边距。
   * 必须是**数值**：`.width('100%')` 在宽度插值里没有中间态，动画会整段跳过。
   */
  private expandedBarWidth(): number {
    // **自适应长度**：随窗口宽度伸缩（去掉 520 限宽——平板上胶囊不再固定半长）
    const w: number = this.rootWidth - HwSpace.lg * 2;
    return w > 200 ? w : 200;
  }

  /**
   * 收起态胶囊宽度：返回 + 搜索两个 36 按钮 = 96；
   * 有多标签时每个序号再占 30（22 徽标 + 8 间距），最多算 4 个，否则胶囊会长得不像胶囊。
   */
  /**
   * 收起态标签序号区的宽度。**胶囊宽度与序号区宽度必须共用这一个公式**——
   * 之前两处各写一份（30/28、间距 6/5）漂移了，胶囊就差几个 vp，最后一个按钮被切边。
   */
  private collapsedTabsWidth(): number {
    const n: number = this.tabs.length > 5 ? 5 : this.tabs.length;
    return n * 26 + (n - 1) * 5;
  }

  private collapsedTopWidth(): number {
    // 收起态内容就是两颗 36 的圆钮（返回 + 搜索），中间隔 HwSpace.sm；
    // 胶囊左右各留 HwSpace.sm —— 这样**左边离返回按钮的距离 = 右边离搜索按钮的距离**，
    // 右边不会再空一截（之前用固定的 miniTop=116，两钮只占 82，右侧空出 22）。
    const pad: number = HwSpace.sm;
    let w: number = pad + 36 + HwSpace.sm + 36 + pad;
    // 标签栏在顶部时，胶囊里还要放那一排 1/2/3 序号
    if (this.tabs.length > 1 && !this.tabBarAtBottom) {
      w += HwSpace.sm + this.collapsedTabsWidth();
    }
    return w;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1800 });
    } catch (err) {
      // 提示失败不影响主流程
    }
  }

  // ══════════════════════ 抽屉 ══════════════════════

  private anyDrawerOpen(): boolean {
    return this.tocOpen || this.notesOpen;
  }

  /**
   * 侧滑抽屉打开时的**背景模糊**（用户要求：与书架搜索展开同款 blur 6）。
   * 只作用于抽屉**背后**的层（主体内容 + 顶栏 / 标签栏 / 底栏）；
   * 抽屉本体与遮罩不模糊。
   * **仅手机 / 竖屏抽屉形态生效**——大屏横屏是停靠三栏（并列布局），不做模糊。
   */
  private drawerBlur(): number {
    return !this.isWide() && this.anyDrawerOpen() ? 6 : 0;
  }

  private animateParam(): AnimateParam {
    const param: AnimateParam = { duration: 260, curve: Curve.FastOutSlowIn };
    return param;
  }

  /**
   * **侧边栏开合动画锁**（用户要求：动画必须完全执行完才能执行下一个）：
   * 锁着时开合入口直接忽略本次操作——快速"收起又拉出"不再打断前一动画，
   * 正文宽度不会来回跳（抽搐根因）。锁 320ms（260ms 动画 + 余量）。
   */
  private sideAnimBusy: boolean = false;

  private sideAnimLock(): boolean {
    if (this.sideAnimBusy) {
      return true;
    }
    this.sideAnimBusy = true;
    setTimeout(() => {
      this.sideAnimBusy = false;
    }, 320);
    return false;
  }

  /** 目录抽屉的进出场位移：从左侧屏外滑入。 */
  private tocTransition(): TransitionOptions {
    // 滑出距离放宽到屏宽级别：即使宽度快照与面板实际宽度略有出入，
    // 也保证完全滑出屏幕，不会"一部分卡在屏幕外"（用户反馈的概率性 bug）
    const slide: number = Math.max(this.drawerWidth(), this.rootWidth);
    const options: TransitionOptions = { translate: { x: -slide } };
    return options;
  }

  /** 注释抽屉的进出场位移：从右侧屏外滑入。 */
  private notesTransition(): TransitionOptions {
    const slide: number = Math.max(this.drawerWidth(), this.rootWidth);
    const options: TransitionOptions = { translate: { x: slide } };
    return options;
  }

  /**
   * 抽屉的挂载 / 卸载必须包在 animateTo 里，`transition` 的进出场动画才会播放；
   * 这也是 ArkUI 里「条件渲染 + transition」的标准写法。
   * 用 UIContext 上的 animateTo，全局那个已经标记废弃。
   */
  private openToc(): void {
    // 大屏/横屏：目录固定停靠在左侧（可手动关闭），不再用浮层抽屉
    if (this.isWide()) {
      // **动画锁**：上一个停靠开合动画没走完，忽略本次（防打断抽搐）
      if (this.sideAnimLock()) {
        return;
      }
      this.getUIContext().animateTo(this.animateParam(), () => {
        this.tocPinned = !this.tocPinned;
      });
      // 展开后把目录滚到"当前读到的那一节"（用户要求：自动定位到当前所在位置）
      setTimeout(() => {
        this.tocFollowCurrent();
      }, 320);
      return;
    }
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.notesOpen = false;
      this.tocOpen = true;
    });
    setTimeout(() => {
      this.tocFollowCurrent();
    }, 300);
  }

  /**
   * 进入 AI 对话（1.2.0）：默认携带当前阅读文档——
   * 文档名与原文经 AppStorage 信号传给对话页（首条消息发送时注入正文），
   * quote 非空 = 长按选择条「发送AI」带来的选中文本。
   */
  private openAiChat(quote: string): void {
    // **基础模式（纯离线）拦截**（用户要求）：AI 助手要走网络，离线模式直接挡在入口
    if (UpdateService.isOffline()) {
      this.toast(L10n.t('基础模式（纯离线）下 AI 助手不可用'));
      return;
    }
    AppStorage.setOrCreate('aiChatDocName', this.docName);
    AppStorage.setOrCreate('aiChatDocContent', this.rawContent);
    AppStorage.setOrCreate('aiChatQuote', quote);
    if (this.stack !== null) {
      this.stack.pushPath({ name: 'pages/AiChat' });
    }
  }

  // ── 目录自动定位（滚到当前所在章节）──
  /** 目录滚动控制器 */
  private tocScroller: Scroller = new Scroller();
  /** 目录各行的文本 / 纵向偏移（行高不固定，用 onAreaChange 实测最稳） */
  private tocRowText: string[] = [];
  private tocRowTop: number[] = [];

  /** 记录目录行位置（滚动定位用）。 */
  private rememberTocRow(text: string, area: Area): void {
    // position 在类型上是可选的，先收窄再取（ArkTS 对可选链的检查很严）
    const pos: Position | undefined = area.position;
    if (pos === undefined) {
      return;
    }
    // Position 的 x / y 都是可选的，逐个收窄（ArkTS 不接受直接当 Length 用）
    const raw: Length | undefined = pos.y;
    if (raw === undefined || typeof raw !== 'number') {
      return;
    }
    for (let k: number = 0; k < this.tocRowText.length; k++) {
      if (this.tocRowText[k] === text) {
        this.tocRowTop[k] = raw;
        return;
      }
    }
    this.tocRowText.push(text);
    this.tocRowTop.push(raw);
  }

  /**
   * 把目录滚到"当前正在读的那一节"。
   * 目录一打开就定位、之后正文滚动换了章节也跟着走 —— 长文档里翻目录找位置最费劲，
   * 让它自己跟着走省一半事。
   */
  private tocFollowCurrent(): void {
    if (this.activeHeading.length === 0 || !this.tocVisible()) {
      return;
    }
    let at: number = -1;
    for (let k: number = 0; k < this.tocRowText.length; k++) {
      if (this.tocRowText[k] === this.activeHeading) {
        at = k;
        break;
      }
    }
    if (at < 0) {
      return;
    }
    const y: number = this.tocRowTop[at];
    try {
      this.tocScroller.scrollTo({
        xOffset: 0,
        // 上面留一点余量，让人看到"上一节"的上下文
        yOffset: y > 12 ? y - 12 : 0,
        animation: { duration: 260, curve: Curve.FastOutSlowIn }
      });
    } catch (err) {
      // 列表尚未布局完：忽略，下次章节变化还会再来一次
    }
  }

  /** 目录当前是否可见（浮层抽屉打开，或大屏停靠）。 */
  private tocVisible(): boolean {
    return this.tocOpen || (this.isWide() && this.tocPinned);
  }

  private openNotes(): void {
    // 抽屉要渲染批注/脚注里的公式：打开时重收一次任务（共用水池）
    this.rebuildDrawerFormulaTasks();
    // 大屏/横屏：注释固定停靠在右侧
    if (this.isWide()) {
      // **动画锁**：同 openToc
      if (this.sideAnimLock()) {
        return;
      }
      this.getUIContext().animateTo(this.animateParam(), () => {
        this.notesPinned = !this.notesPinned;
      });
      return;
    }
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.tocOpen = false;
      this.notesOpen = true;
    });
  }

  private closeDrawers(): void {
    // 大屏：目录/批注是停靠列，收起 = 取消钉住
    if (this.isWide()) {
      if (!this.tocPinned && !this.notesPinned) {
        return;
      }
      this.getUIContext().animateTo(this.animateParam(), () => {
        this.tocPinned = false;
        this.notesPinned = false;
      });
      return;
    }
    if (!this.anyDrawerOpen()) {
      return;
    }
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.tocOpen = false;
      this.notesOpen = false;
    });
  }

  // ── 底部浮层的开关。条件挂载必须包在 animateTo 里，进出场动画才会播放 ──

  private openSettings(): void {
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.activeSheet = 'settings';
      this.sheetVisible = true;
    });
  }

  private closeSettings(): void {
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.sheetVisible = false;
    });
  }

  private closeNoteSheet(): void {
    this.pendingStart = -1;
    this.clearMathNoteContext();
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.sheetVisible = false;
    });
  }

  /**
   * 查找命中跳转：**命中行要停在查找条下方**（用户反馈：之前滚到视口顶部，
   * 整行被搜索框盖住，找半天）。做法 = 先瞬时滚到该块顶部，再上移一个
   * 「查找条高度 + 间距」的量。
   */
  private jumpToSearchHit(blockIndex: number): void {
    if (!this.isWide()) {
      this.closeDrawers();
    }
    this.lockAutoHide();
    try {
      // 先瞬时到位（不用动画），再做一次偏移：避免两段滚动互相打断
      this.scroller.scrollToIndex(blockIndex + this.headerCount(), false, ScrollAlign.START);
      this.getUIContext().animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
        this.scroller.scrollBy(0, -SEARCH_BAR_INSET);
      });
    } catch (err) {
      // 列表尚未就绪时忽略
    }
  }

  private jumpTo(blockIndex: number): void {
    // **懒渲染**：目标块可能尚未渲染（visibleBlocks 之外），这时 scrollToIndex 指向
    // 不存在的条目 → 点了没反应（用户实测：在文档顶部点目录最后一项无效）。
    // 先把它纳入渲染范围，再跳。
    if (blockIndex + 8 > this.visibleBlocks) {
      this.visibleBlocks = Math.min(this.blocks.length, blockIndex + 24);
    }
    // **平板（宽屏）：跳转后目录 / 注释保持展开**，不自动收起（用户要求）
    if (!this.isWide()) {
      this.closeDrawers();
    }
    this.lockAutoHide();
    try {
      this.scroller.scrollToIndex(blockIndex + this.headerCount(), true, ScrollAlign.START);
    } catch (err) {
      // 忽略
    }
  }

  /**
   * 原文行号（**1 起**，与 TaskBoard.collect 返回的 `line` 同口径）→ 块下标。
   *
   * ⚠️ 块上记的 `srcLine` 是 **0 起**（与勾选写回时 `lines[block.srcLine]` 一致），
   * 所以比较用 `srcLine >= line - 1`，取第一个覆盖该行的块；
   * 行号落在文档末尾之后时退回最后一块。
   *
   * @returns 块下标；正文为空时返回 -1。
   */
  private blockIndexOfLine(line: number): number {
    if (this.blocks.length === 0) {
      return -1;
    }
    const want: number = line - 1;
    for (let k = 0; k < this.blocks.length; k++) {
      if (this.blocks[k].srcLine >= want) {
        return k;
      }
    }
    return this.blocks.length - 1;
  }

  /**
   * 定位到原文第 `line` 行并提示行号（「全部待办」点条目进来用）。
   * 与 jumpTo 的区别：先按行号反查块，找不到时给出明确提示而不是静默不动。
   */
  private jumpToSourceLine(line: number): void {
    const bi: number = this.blockIndexOfLine(line);
    if (bi < 0) {
      this.toast(L10n.t('这一行在正文里找不到对应内容'));
      return;
    }
    this.jumpTo(bi);
    this.toast('已定位到第 ' + line + ' 行');
  }

  // ══════════════════════ 滚动 ══════════════════════

  private onListScroll(start: number, end: number, center: number): void {
    const total: number = this.blocks.length;
    if (total > 0) {
      const ratio: number = (center + 1 - this.headerCount()) / total;
      this.progress = ratio > 1 ? 1 : (ratio < 0 ? 0 : ratio);
    }
    this.progressBlock = center > this.headerCount() ? center - this.headerCount() : 0;
    this.scrolled = start > 0;
    this.progressDirty = true;

    // 回到文档顶部时永远展开，避免「在最上面却找不到入口」
    if (start <= 0) {
      this.scrollAccum = 0;
      this.toggleAllBars(true);
    }

    const blockIndex: number = center - this.headerCount();
    let current: string = '';
    for (let k = 0; k < this.docOutline.length; k++) {
      if (this.docOutline[k].blockIndex <= blockIndex) {
        current = this.docOutline[k].text;
      } else {
        break;
      }
    }
    const before: string = this.activeHeading;
    if (current.length > 0) {
      this.activeHeading = current;
    } else if (this.docOutline.length > 0) {
      this.activeHeading = this.docOutline[0].text;
    }
    // 章节变了且目录正开着 → 目录跟着滚到新章节（用户要求：自动滑动到当前所在位置）
    if (this.activeHeading !== before && this.tocVisible()) {
      this.tocFollowCurrent();
    }
  }

  // ══════════════════════ 顶栏 ══════════════════════

  @Builder
  topBar() {
    ImmersiveBar({
      palette: this.palette(),
      // 收起态左右内边距都用 sm：与展开态的紧凑观感一致，
      // 也让「左边离返回键」与「右边离搜索键」的距离相等（用户要求：间距一致、右边不空）
      barPaddingH: HwSpace.sm,
      barPaddingV: HwSpace.xs,
      barHeight: HwBar.pill,
      // 悬浮胶囊：展开时与正文列对齐（大屏避开停靠侧栏），收起时原地向左收缩
      barWidth: this.topBarVisible ? this.barAreaWidth() : this.collapsedTopWidth(),
      barWidthPx: this.topBarVisible ? this.barAreaWidth() : this.collapsedTopWidth()
    }) {
      // 同一时刻只挂一层内容，杜绝「收起胶囊与展开内容叠加、内容溢出胶囊」的错位
      if (this.topBarVisible) {
      ImmersiveIconButton({
        buttonSize: 34,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          this.backToShelf();
        }
      }) {
        SymbolGlyph($r('sys.symbol.arrow_left'))
          .fontSize(17)
          .fontColor([this.palette().textPrimary])
      }

      // **沉浸阅读入口**（用户要求：放在顶栏返回按钮的右侧；与右侧两按钮保持同样的间隙）
      Column()
        .width(HwSpace.xs)
      ImmersiveIconButton({
        buttonSize: 34,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          this.toggleImmersive();
        }
      }) {
        SymbolGlyph($r('sys.symbol.eye'))
          .fontSize(17)
          .fontColor([this.palette().textPrimary])
      }

      Column({ space: 1 }) {
        Text(this.docName.length > 0 ? this.docName : L10n.t('未命名文档'))
          .fontSize(HwType.label)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.palette().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.activeHeading.length > 0 ? this.activeHeading : L10n.t('右滑目录 · 左滑注释'))
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      .padding({ left: HwSpace.xs, right: HwSpace.xs })
      // **双击标题快速回到文档顶部**（用户要求）。
      // 用 priorityGesture：顶栏胶囊自己带手势，普通 gesture 会被父级先消费掉。
      .priorityGesture(TapGesture({ count: 2 }).onAction(() => {
        this.scroller.scrollEdge(Edge.Top);
        this.toast(L10n.t('已回到顶部'));
      }))

      // 导出入口（用户要求）：搜索按钮左边，弹出 HTML / MD / 分享。
      // 与查找按钮的间隙用**独立占位**（不包 Column / 不链 margin——
      // 尾随闭包组件链属性会编译报错，包一层又会改变按钮的尺寸表现）
      ImmersiveIconButton({
        buttonSize: 34,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          this.openExport();
        }
      }) {
        SymbolGlyph($r('sys.symbol.doc_text_badge_arrow_up'))
          .fontSize(16)
          .fontColor([this.palette().textPrimary])
      }

      Column().width(HwSpace.xs)

      // 目录 / 字号 / 亮度都在底部悬浮工具条（参考图三），顶栏只留返回、标题与查找。
      // **不再做共享元素**：按钮与查找条共用 geometryTransition id 时，按钮被移除
      // 的瞬间会把最后一帧留在查找条中心（用户反馈的"搜索图标残留"）。
      // 查找条自己带动画，这里普通出现/消失即可。
      if (!this.searchOpen) {
        Stack() {
          ImmersiveIconButton({
            buttonSize: 34,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
          if (this.searchOpen) {
            this.closeSearch();
          } else {
            this.openSearch();
          }
        }
      }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(16)
              .fontColor([this.palette().textPrimary])
          }
        }
        .width(34)
        .height(34)
      }
      } else {
        this.miniTopContent()
      }
    }
  }

  /** 文档内查找条：输入即跳转到首个命中，上一个 / 下一个在命中块之间移动。 */
  @Builder
  searchBar() {
    // 包一层 Stack 才能挂 geometryTransition：
    // 自定义组件 + 尾随闭包之后不允许再链式调属性。
    // 这一层与顶栏那颗搜索按钮共享 'readerSearch'，所以查找条是「从按钮长出来的」。
    Stack() {
    ImmersiveBar({
      palette: this.palette(),
      barPaddingH: HwSpace.xs,
      barPaddingV: 4,
      barHeight: HwBar.pill,
      // **与顶部悬浮胶囊同宽**：必须用 barAreaWidth()（减去停靠列），
      // 不能用 expandedBarWidth()——平板横屏有停靠列时查找条会比胶囊长（用户反馈）
      barWidth: this.barAreaWidth(),
      barWidthPx: this.barAreaWidth()
    }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(15)
        .fontColor([this.palette().textTertiary])
        .margin({ left: HwSpace.xs })

      TextInput({ text: this.searchQuery, placeholder: L10n.t('在本文中查找') })
        .layoutWeight(1)
        .fontSize(HwType.label)
        .fontColor(this.palette().textPrimary)
        .placeholderColor(this.palette().textTertiary)
        .backgroundColor('#00000000')
        .padding({ left: HwSpace.xs, right: HwSpace.xs })
        .maxLines(1)
        .onChange((value: string) => {
          this.runSearch(value);
        })

      Text(this.searchLabel())
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
        .padding({ left: HwSpace.xs, right: HwSpace.xs })

      // 上下查找 / 关闭三颗按钮之间插一点空隙：28 的圆钮并排会贴在一起
      Column()
        .width(HwSpace.xxs)
      ImmersiveIconButton({
        buttonSize: 28,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          this.stepSearch(-1);
        }
      }) {
        SymbolGlyph($r('sys.symbol.chevron_up'))
          .fontSize(14)
          .fontColor([this.palette().accent])
      }

      // ↑↓ 之间的空隙：之前漏了这层，两颗圆钮贴在一起（用户截图指出）
      Column()
        .width(HwSpace.xs)

      ImmersiveIconButton({
        buttonSize: 28,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          this.stepSearch(1);
        }
      }) {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(14)
          .fontColor([this.palette().accent])
      }

      // 与关闭钮之间再留一点空隙，避免三颗圆钮挤成一团
      Column()
        .width(HwSpace.xs)
      ImmersiveIconButton({
        buttonSize: 28,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          this.closeSearch();
        }
      }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(14)
          .fontColor([this.palette().textSecondary])
      }
    }
    }
    // **外层 Stack 也必须与胶囊同宽**（barAreaWidth，减去停靠列）：
    // 之前用 expandedBarWidth()，平板横屏有停靠列时它比内容区宽，
    // 查找条整体右移、一半出屏（用户反馈）
    .width(this.barAreaWidth())
    .height(HwBar.pill)
    .geometryTransition('readerSearch', { follow: true })
  }

  // ══════════════════════ 标签栏 ══════════════════════

  /**
   * 顶部标签栏（多标签 + 标签栏在顶部时显示）：只有一个标签时不显示（手机上不值得占一行），
   * 序号 + 文件名 + 关闭叉，点击切换、× 关闭、长按弹菜单。
   * **标签栏置底时这一层不渲染**——那种情况下标签条是悬浮胶囊内部的一段（见 bottomTabs）。
   */
  @Builder
  tabBar() {
    Scroll() {
      Row({ space: HwSpace.sm }) {
        ForEach(this.tabs, (tab: ReaderTab, idx: number) => {
          Stack() {
            // 底：**材质可用时必须透明**，否则材质采样到的是这层近实色底，
            // 看起来就是"普通纯色芯片"、完全没有光感（顶栏胶囊同理）；
            // 材质不可用时才给磨砂兜底。
            Column()
              .width(LayoutPolicy.matchParent)
              .height(LayoutPolicy.matchParent)
              .borderRadius(HwRadius.pill)
              .backgroundColor(this.tabBaseColor(tab.name))
              .hitTestBehavior(HitTestMode.None)

            // 沉浸光感承载层（Toggle 承载方案，与顶栏/底栏/芯片同一条路径）
            ImmersiveCardLayer({ layerRadius: HwRadius.pill, layerShadow: false })

            Row({ space: 4 }) {
              // **序号前缀**（用户要求）：1、2、3… 方便认是第几个标签
              Text((idx + 1) + ' ')
              .fontSize(HwType.caption - 0.5)
              .fontColor(this.docName === tab.name ? this.palette().accent : this.palette().textTertiary)
              Text(this.tabLabel(tab.name))
              .fontSize(HwType.caption + 0.5)
              .fontWeight(this.docName === tab.name ? FontWeight.Medium : FontWeight.Normal)
              // 未选中标签必须用 textPrimary：胶囊底接近实色，textSecondary 在上面发灰看不清
              .fontColor(this.docName === tab.name ? this.palette().accent : this.palette().textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 128 })

            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(12)
              .fontColor([this.docName === tab.name ? this.palette().accent : this.palette().textTertiary])
              .onClick(() => {
                this.closeTab(tab.name);
              })
            }
            .padding({ left: 10, right: 6, top: 4, bottom: 4 })
            .borderRadius(HwRadius.pill)
          }
          .onClick(() => {
            this.activateTab(tab.name);
          })
          .gesture(
            LongPressGesture()
              .onAction(() => {
                this.openTabMenu(tab.name);
              })
          )
          // **关闭淡出**（用户要求）：删除标签时整片淡出，
          // 包在 animateTo 里的数组变更会让兄弟标签自动滑动补位
          .transition(TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.FastOutSlowIn }))
        }, (tab: ReaderTab) => tab.name)
      }
      // 左内边距用 lg：视口是整屏宽（标签栏层没有左右 padding），
      // 静止时第一个标签仍在常规边距上，滑动时才从屏幕边缘滑出去。
      .padding({ left: HwSpace.lg, right: 0 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    // 视口 = **整屏宽**：标签栏层没有左右 padding，'100%' 就是屏幕宽度，
    // 标签的出现 / 消失点天然落在屏幕边缘。
    .width('100%')
    .height(HwBar.tabs - 4)
  }

  // ── bindSheet 的内容包装（面板底色 / 模糊由 Sheet 本体负责，这里只补内边距）──


  // ── 半模态面板的官方标题栏文案（标题区由 ModalSheet 自带，内容不再自绘标题）──

  /** 封面格式角标：MD / TXT（应用同时支持两种文件）。 */
  private docFormatLabel(): string {
    const ctx = this.ctx();
    if (ctx === null) {
      return 'MD';
    }
    const meta: DocMeta | undefined = DocStore.find(ctx, this.docName);
    if (meta === undefined) {
      return 'MD';
    }
    return meta.fileName.toLowerCase().endsWith('.txt') ? 'TXT' : 'MD';
  }

  /** 收藏 / 取消收藏（信息卡右上角爱心）。 */    /** 打开标签编辑面板并读入当前文档标签 */
  private openTagEditor(): void {
    const c = this.ctx();
    this.docTags = [];
    if (c !== null) {
      const meta: DocMeta | undefined = DocStore.find(c, this.docName);
      const raw: string[] | undefined = meta === undefined ? undefined : meta.tags;
      if (raw !== undefined) {
        this.docTags = raw.slice();
      }
    }
    this.tagDraft = '';
    this.sheetEpoch++;
    this.activeSheet = 'tags';
    this.sheetVisible = true;
  }

  /** 添加标签（去重、非空，添加即落盘） */
  private addTag(): void {
    const v: string = this.tagDraft.trim();
    if (v.length === 0) {
      return;
    }
    for (let k = 0; k < this.docTags.length; k++) {
      if (this.docTags[k] === v) {
        this.tagDraft = '';
        return;
      }
    }
    this.docTags = this.docTags.concat([v]);
    this.tagDraft = '';
    const c = this.ctx();
    if (c !== null) {
      DocStore.setTags(c, this.docName, this.docTags);
    }
  }

  /** 移除标签（立即落盘） */
  private removeTag(tag: string): void {
    const kept: string[] = [];
    for (let k = 0; k < this.docTags.length; k++) {
      if (this.docTags[k] !== tag) {
        kept.push(this.docTags[k]);
      }
    }
    this.docTags = kept;
    const c = this.ctx();
    if (c !== null) {
      DocStore.setTags(c, this.docName, this.docTags);
    }
  }

  private toggleStar(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const next: boolean = !this.docStarred;
    if (DocStore.setStarred(ctx, this.docName, next)) {
      this.docStarred = next;
      this.toast(next ? L10n.t('已收藏') : L10n.t('已取消收藏'));
    }
  }

  /** 时间戳 → 'YYYY-MM-DD HH:mm'；0 显示「—」。 */
  private static timeLabel(ms: number): string {
    if (ms <= 0) {
      return '—';
    }
    const d: Date = new Date(ms);
    const pad = (v: number): string => {
      return v < 10 ? '0' + v : '' + v;
    };
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
      + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  /** 当前面板的官方标题栏主标题。 */
  private sheetTitle(): string {
    if (this.activeSheet === 'settings') {
      return '阅读设置';
    }
    if (this.activeSheet === 'note') {
      return '添加批注';
    }
    if (this.activeSheet === 'tags') {
      return '文档标签';
    }
    if (this.activeSheet === 'tabMenu') {
      return this.tabMenuFor;
    }
    if (this.activeSheet === 'bright') {
      return '亮度与主题';
    }
    if (this.activeSheet === 'export') {
      return '导出与分享';
    }
    if (this.activeSheet === 'merge') {
      return '合并导出';
    }
    if (this.activeSheet === 'compare') {
      return '对照阅读';
    }
    if (this.activeSheet === 'web') {
      return this.webHost();
    }
    return '更多';
  }

  /** 当前面板的官方标题栏副标题；空串 = 不显示。 */
  private sheetSubtitle(): string {
    if (this.activeSheet === 'settings') {
      return '设置会随应用记忆，切换文档同样生效';
    }
    if (this.activeSheet === 'note') {
      return '批注会记在这段文字上，可在注释面板里查看';
    }
    if (this.activeSheet === 'bright') {
      return '只调低本应用窗口的亮度，离开阅读页自动交还系统';
    }
    if (this.activeSheet === 'tabMenu') {
      return '标签操作';
    }
    if (this.activeSheet === 'export') {
      return '「' + this.docName + '」';
    }
    if (this.activeSheet === 'merge') {
      return '把多篇按选定顺序拼成一篇，再导 HTML / 打印 / MD / TXT';
    }
    return '';
  }

  /**
   * 面板内容 = 键盘垫高层 + 具体面板。
   * 平台对 BindSheet 不做键盘避让（SDK 的 setKeyboardAvoidMode NOTE 里点名 BindSheet
   * 不生效），所以统一包一层 SheetKeyboardLift，键盘弹起时把内容抬到输入法上方。
   */
  @Builder
  currentSheet() {
    SheetKeyboardLift() {
      this.currentSheetBody()
    }
  }

  /** 按 activeSheet 渲染对应面板内容（键盘垫高在外层做，见 currentSheet）。 */
  @Builder
  currentSheetBody() {
    if (this.activeSheet === 'settings') {
      this.settingsSheet()
    } else if (this.activeSheet === 'note') {
      this.noteSheet()
    } else if (this.activeSheet === 'tags') {
      this.tagsSheet()
    } else if (this.activeSheet === 'tabMenu') {
      this.tabMenuSheet()
    } else if (this.activeSheet === 'bright') {
      this.brightSheet()
    } else if (this.activeSheet === 'export') {
      Column() {
        ExportOptionsPanel({
          stack: this.stack,
          docName: this.docName,
          builtin: this.docBuiltin,
          palette: this.palette(),
          onClosed: () => {
            this.closeMore();
          }
        })
      }
      .width('100%')
      .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.sm })
      .id('shExport_' + this.sheetEpoch)
    } else if (this.activeSheet === 'merge') {
      // 双写分支只为强制重建（面板数据在 openMergeExport 里刚刷过）
      if (this.sheetEpoch % 2 === 0) {
        this.mergeSheet()
      } else {
        this.mergeSheet()
      }
    } else if (this.activeSheet === 'more') {
      this.moreSheet()
    } else if (this.activeSheet === 'web') {
      this.webPane()
    } else if (this.activeSheet === 'compare') {
      this.compareSheet()
    } else if (this.activeSheet === 'backlinks') {
      this.backlinksSheet()
    } else if (this.activeSheet === 'images') {
      this.imagesSheet()
    }
  }

  /** 网页面板：奇偶分支结构一致、每次打开强制重建 Web 实例（加载新地址）。 */
  @Builder
  webPane() {
    if (this.webEpoch % 2 === 0) {
      this.webPaneInner()
    } else {
      this.webPaneInner()
    }
  }

  @Builder
  webPaneInner() {
    Column() {
      Web({ src: this.webUrl, controller: this.webCtrl })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        .darkMode(WebDarkMode.Auto)
        .overScrollMode(OverScrollMode.NEVER)
    }
    .width('100%')
    .height('100%')
  }

  // ══════════════════════ 分屏对照（批 5） ══════════════════════
  //
  // 复用 bindSheet 面板机制做「对照阅读」：面板第一态是**选文档列表**，
  // 选中后同一面板切换为第二篇文档的**只读渲染**（与当前文档并排对照 ——
  // 面板从底部拉起、可与正文并排看）。零核心布局改动、定高面板无结构跳动。

  // ── 网页开放（用户要求）：点击正文 http(s) 链接在半模态面板内打开 ──
  /** 开关（持久化键 readerWebOpen；关闭时点链接维持「复制地址」的旧行为） */
  @StorageLink('readerWebOpen') webOpen: boolean = false;
  /** 当前面板要打开的网页地址 */
  @State webUrl: string = '';
  /** Web 重建纪元：每次打开面板自增，奇偶分支切换强制新建 Web（src 创建时固定不随属性重载） */
  @State webEpoch: number = 0;
  private webCtrl: webview.WebviewController = new webview.WebviewController();

  /** 打开网页面板：每次都换奇偶分支重建 Web，加载新地址。 */
  private openWebSheet(href: string): void {
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.webUrl = href;
      this.webEpoch++;
      this.activeSheet = 'web';
      this.sheetVisible = true;
    });
  }

  /** 网页地址 → 主机名（面板标题用）。 */
  private webHost(): string {
    const h: string = this.webUrl;
    const schemeEnd: number = h.indexOf('://');
    const start: number = schemeEnd >= 0 ? schemeEnd + 3 : 0;
    const slash: number = h.indexOf('/', start);
    const end: number = slash >= 0 ? slash : h.length;
    return h.substring(start, end);
  }

  /** 网页刷新（面板标题栏按钮）。 */
  private refreshWebPage(): void {
    try {
      this.webCtrl.refresh();
      this.toast(L10n.t('已刷新'));
    } catch (err) {
      // Web 尚未挂载 / 已销毁：无操作
    }
  }

  /** 复制当前网页链接（面板标题栏按钮）。 */
  private copyWebLink(): void {
    if (this.webUrl.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.webUrl);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.toast(L10n.t('链接已复制'));
      }).catch(() => {
        this.toast(L10n.t('复制失败'));
      });
    } catch (err) {
      this.toast(L10n.t('复制失败'));
    }
  }

  /**
   * 网页面板标题区（自定义标题，替换官方标题文案）：
   * 「刷新 / 复制链接」两枚胶囊（用户要求，参考本地 xjau 网页登录面板的标题栏操作区）。
   */
  @Builder
  webSheetTitle() {
    Row({ space: HwSpace.xs }) {
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
          .fontSize(13)
          .fontColor([this.palette().textPrimary])
        Text(L10n.t('刷新'))
          .fontSize(12.5)
          .fontColor(this.palette().textPrimary)
      }
      .padding({ left: 10, right: 12, top: 5, bottom: 5 })
      .borderRadius(HwRadius.pill)
      .backgroundColor(this.palette().quoteBg)
      .onClick(() => {
        this.refreshWebPage();
      })

      Row({ space: 4 }) {
        Image($r('app.media.ic_public_copy'))
          .width(13)
          .height(13)
          .fillColor(this.palette().textPrimary)
        Text(L10n.t('复制链接'))
          .fontSize(12.5)
          .fontColor(this.palette().textPrimary)
      }
      .padding({ left: 10, right: 12, top: 5, bottom: 5 })
      .borderRadius(HwRadius.pill)
      .backgroundColor(this.palette().quoteBg)
      .onClick(() => {
        this.copyWebLink();
      })

      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 对照的文档名（空串 = 面板处于"选文档"状态） */
  @State compareDoc: string = '';
  /** 对照文档解析出的块（只读渲染） */
  @State compareBlocks: MdBlock[] = [];
  /** 对照切换纪元：换文档时 ++，列表 ForEach 重建 */
  @State compareEpoch: number = 0;
  /** 对照面板在浮层打开前是否开着：关闭浮层后据此自动恢复面板 */
  private compareSheetWasOpen: boolean = false;
  /** **左右分屏对照**：正文左半、对照文档右半（对照面板里开启） */
  @State compareSplit: boolean = false;
  /** 分屏退出浮钮位置（translate 状态）：拖动 / 吸附都改它；-1 = 未初始化 */
  @State exitBtnX: number = -1;
  @State exitBtnY: number = -1;
  private exitDragBaseX: number = 0;
  private exitDragBaseY: number = 0;
  /** 用户手动拖过浮钮 = true：此后握姿不再自动挪它（尊重手动位置） */
  private exitBtnDragged: boolean = false;

  /** 打开对照面板（从更多面板磁贴进）。 */
  private openCompare(): void {
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.compareDoc = '';
      this.compareBlocks = [];
      this.activeSheet = 'compare';
      this.sheetVisible = true;
    });
  }

  /** 选定对照文档：解析为只读块。 */
  private loadCompare(name: string): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      const meta: DocMeta | undefined = DocStore.find(ctx, name);
      if (meta === undefined) {
        this.toast(L10n.t('文档不存在'));
        return;
      }
      const content: string = DocStore.readText(ctx, meta);
      const parsed = MdParser.parse(content);
      this.compareBlocks = parsed.blocks;
      this.compareDoc = name;
      this.compareEpoch = this.compareEpoch + 1;
    } catch (err) {
      this.toast('读取失败：' + DocStore.describeError(err as BusinessError));
    }
  }

  /** 对照面板：未选文档 = **宫格选择**；已选 = 只读渲染 + 换一篇 / 左右分屏。 */
  @Builder
  compareSheet() {
    Column({ space: HwSpace.sm }) {
      if (this.compareDoc.length > 0) {
        Row({ space: HwSpace.xs }) {
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: L10n.t('‹ 换一篇'),
            chipOnTap: () => {
              this.compareDoc = '';
              this.compareBlocks = [];
            }
          })
          ImmersiveChip({
            palette: this.palette(),
            chipActive: true,
            chipLabel: L10n.t('左右分屏'),
            chipOnTap: () => {
              // 进入**左右分屏**：正文左半、对照文档右半。
              // ⚠️ 只翻 sheetVisible（activeSheet 留给 onDismiss 清）——同一帧里
              // "关面板 + 清内容标识"会冲突（工程铁律：真机白屏 + 面板不退）。
              // 浮钮初始位置：按智感握姿定边、垂直居中（之后可自由拖动吸附）
              this.exitBtnX = this.gripSide === -1 ? 10 : this.rootWidth - 44;
              this.exitBtnY = this.rootHeight / 2 - 17;
              this.compareSplit = true;
              this.sheetVisible = false;
            }
          })
          Text('《' + this.compareDoc + '》 · 只读')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column({ space: HwSpace.sm }) {
            ForEach(this.compareBlocks, (b: MdBlock) => {
              MdBlockView({
                block: b,
                palette: this.palette(),
                bodySize: this.fontSize,
                lineMul: this.lineMul,
                dark: this.isDark(),
                // 对照是只读视图：批注 / 勾选 / 锚点等回调不传（默认空实现）；
                // 放大有反应（铁律），但 **geoKey 传空**——对照块与正文块共享同一套
                // geometryTransition id，两份同 id 元素会让一镜到底错乱（图层错误），
                // 对照侧不走共享元素、浮层直接全屏出现。
                // ⚠️ **先收面板再开浮层**：半模态是系统层，永远盖住页面内的浮层
                //（面板开着点放大 = 浮层被压在下面，图层错误实测）。
                // 关浮层后 closeOverlays 会按 compareSheetWasOpen 自动恢复面板
                enlargeHandler: (mode: string, payload: string, geoKey: string, title: string) => {
                  this.compareSheetWasOpen = true;
                  this.sheetVisible = false;
                  this.openEnlarge(mode, payload, '', title);
                },
                imageTapHandler: (key: string, src: string) => {
                  this.compareSheetWasOpen = true;
                  this.sheetVisible = false;
                  this.openZoomImage(key, src);
                }
              })
            }, (b: MdBlock) => 'cmp_' + this.compareEpoch + '_' + b.id)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .width('100%')
        .layoutWeight(1)
      } else {
        Text(L10n.t('选一篇文档与《') + this.docName + '》对照（译文 / 原文 / 笔记）；选定后可进左右分屏。')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .width('100%')

        // **宫格选择**（用户要求：列表改成宫格样式）
        Grid() {
          ForEach(this.trailCandidateDocs(), (m: DocMeta) => {
            GridItem() {
              Column({ space: 2 }) {
                Text(m.name)
                  .fontSize(HwType.caption + 1)
                  .fontColor(this.palette().textPrimary)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(TextAlign.Center)
                  .width('100%')
                Text(m.progressRatio > 0.005
                  ? L10n.t('已读 ') + Math.round(m.progressRatio * 100) + '%' : L10n.t('未读'))
                  .fontSize(HwType.caption - 2)
                  .fontColor(this.palette().textTertiary)
              }
              .width('100%')
              .height(72)
              .justifyContent(FlexAlign.Center)
              .padding(HwSpace.xs)
              .borderRadius(HwRadius.inner)
              .backgroundColor(this.palette().quoteBg)
              .onClick(() => {
                this.loadCompare(m.name);
              })
            }
          }, (m: DocMeta) => 'cmpsel_' + m.name)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(6)
        .rowsGap(6)
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.sm })
    .id('shCompare_' + this.compareEpoch)
  }

  /** 对照选文档的候选：书架全部文档，排除当前正在读的这篇，按最近打开排序。 */
  private trailCandidateDocs(): DocMeta[] {
    const ctx = this.ctx();
    if (ctx === null) {
      return [];
    }
    const list: DocMeta[] = DocStore.list(ctx);
    const items: DocMeta[] = [];
    for (let k = 0; k < list.length; k++) {
      if (list[k].name !== this.docName) {
        items.push(list[k]);
      }
    }
    items.sort((a: DocMeta, b: DocMeta): number => b.lastOpen - a.lastOpen);
    return items.slice(0, 30);
  }

  @Builder
  settingsSheet() {
    Scroll() {
      Column({ space: HwSpace.md }) {
        ReadingSettingsPanel({ showReadingHints: true, showHeader: false })
        // **文档编码**（用户要求）：识别错误时手动指定，切换后重新解析正文
        this.encodingCard()
      }
      .width('100%')
      .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.lg })
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
  }

  /**
   * 文档编码选择卡（「阅读设置」底部）。
   * **为什么需要它**：非 UTF-8 的文档（例如 Windows 记事本存出来的 GBK/ANSI 文本）
   * 按 UTF-8 硬解会整篇乱码。自动模式已能覆盖大多数情况，识别不准时在这里手动指定。
   */
  @Builder
  encodingCard() {
    ImmersiveCard({
      cardRadius: HwRadius.card,
      cardPadding: HwSpace.lg,
      palette: this.palette()
    }) {
      Column({ space: HwSpace.sm }) {
        Text(L10n.t('文档编码'))
          .fontSize(HwType.label + 1)
          .fontColor(this.palette().textPrimary)
          .width('100%')

        Text(this.docEncoding === 'auto'
          ? L10n.t('自动识别：先按 UTF-8 解码，出现乱码则按 GB18030 重试；识别不准时可手动指定。')
          : L10n.t('当前手动指定为 ') + this.encodingLabel(this.docEncoding) + '。切换后正文会重新解析。')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .lineHeight(HwType.caption * 1.7)
          .width('100%')

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(ENCODING_CHOICES, (item: EncodingChoice) => {
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: L10n.t(item.label),
              chipActive: this.docEncoding === item.value,
              chipOnTap: () => {
                this.switchEncoding(item.value);
              }
            })
              .margin({ right: HwSpace.xs, bottom: HwSpace.xs })
          }, (item: EncodingChoice) => item.value)
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 编码的显示名（找不到就原样返回）。 */
  private encodingLabel(value: string): string {
    for (let k = 0; k < ENCODING_CHOICES.length; k++) {
      if (ENCODING_CHOICES[k].value === value) {
        return ENCODING_CHOICES[k].label;
      }
    }
    return value;
  }

  /** 切换文档编码并重新解析正文。 */
  private switchEncoding(value: string): void {
    if (this.docEncoding === value) {
      return;
    }
    this.docEncoding = value;
    // 同步到 AppStorage：书架「⋯ → 文档编码」读同一份，两处切换互相可见
    AppStorage.setOrCreate('docEncoding_' + this.docName, value);
    this.loadDoc();
    this.toast('编码已切换：' + this.encodingLabel(value));
  }

  /** 标签编辑面板：输入添加 + 芯片移除，改动即时落盘 */
  @Builder
  tagsSheet() {
    Column({ space: HwSpace.md }) {
      Row({ space: HwSpace.sm }) {
        TextInput({ text: this.tagDraft, placeholder: L10n.t('输入标签，如：单词 / 语法 / 精读…') })
          .layoutWeight(1)
          .fontSize(HwType.label)
          .fontColor(this.palette().textPrimary)
          .placeholderColor(this.palette().textTertiary)
          .backgroundColor(this.palette().codeBlockBg)
          .borderRadius(HwRadius.pill)
          .onChange((value: string) => {
            this.tagDraft = value;
          })
          .onSubmit(() => {
            this.addTag();
          })
        ImmersiveChip({
          palette: this.palette(),
          chipLabel: L10n.t('添加'),
          chipOnTap: () => {
            this.addTag();
          }
        })
      }
      .width('100%')

      if (this.docTags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.docTags, (tag: string) => {
            Row({ space: 8 }) {
              Text('#' + tag)
                .fontSize(HwType.label)
                .fontColor(this.palette().accent)
              Text('×')
                .fontSize(HwType.label)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.palette().textTertiary)
                .onClick(() => {
                  this.removeTag(tag);
                })
            }
            .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 5, bottom: 5 })
            .borderRadius(HwRadius.pill)
            .border({ width: 1, color: this.palette().divider })
          }, (tag: string) => tag)
        }
        .width('100%')
      } else {
        Text(L10n.t('还没有标签。添加后：书架顶栏可按标签筛选，学习卡左上角会显示所属标签。'))
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .lineHeight(HwType.caption * 1.6)
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.sm, bottom: HwSpace.lg })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  noteSheet() {
    Column() {
      // **面板内容自持状态**（NotePanel）：bindSheet 的 builder 不跟宿主 @State
      // 重渲染（本工程固定坑，见 sheetEpoch / AutoScrollTile 同一套结论），而选段
      // 预览、批注/学习卡切换、聚焦抬高都要在面板开着时刷新，状态只能住组件里。
      // 这里传的 init* 只在"打开面板那一刻"被读一次，结果由回调交回本页面落库。
      NotePanel({
        initQuote: this.noteQuote,
        initMathQuote: this.noteMathQuote,
        initDraft: this.noteDraft,
        initStyle: this.pendingStyle,
        dark: this.isDark(),
        bodySize: this.fontSize,
        palette: this.palette(),
        onDraft: (value: string) => {
          this.noteDraft = value;
          // 边输入边记草稿（带时间戳）—— 误退出后 3 分钟内可恢复
          AppStorage.setOrCreate(NOTE_DRAFT_KEY, value);
          AppStorage.setOrCreate(NOTE_DRAFT_AT_KEY, Date.now());
        },
        onSaveMath: (latex: string): boolean => {
          return this.saveMathEdit(latex);
        },
        onSubmit: (draft: string, style: string, sub: string) => {
          this.saveNoteDraft(draft, style, sub);
        },
        onCancel: () => {
          this.closeNoteSheet();
        }
      })
    }
    .width('100%')
    .padding(HwSpace.lg)
    .id('shNote_' + this.sheetEpoch)
  }

  /** 合并导出面板（选篇 / 排序 / 合并样式 + 四种输出）。 */
  @Builder
  mergeSheet() {
    Column() {
      MergeExportPanel({
        sources: this.mergeSources,
        preselect: this.mergePreselect,
        stack: this.stack,
        palette: this.palette(),
        onClosed: () => {
          this.closeMore();
        }
      })
    }
    .width('100%')
    .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.sm })
    .id('shMerge_' + this.sheetEpoch)
  }

  @Builder
  tabMenuSheet() {
    Column() {
      this.tabMenuPanel()
    }
    .width('100%')
    .padding(HwSpace.lg)
    .id('shTabMenu_' + this.sheetEpoch)
  }

  @Builder
  brightSheet() {
    Column() {
      this.brightPanel()
    }
    .width('100%')
    .padding(HwSpace.lg)
    .id('shBright_' + this.sheetEpoch)
  }

  @Builder
  moreSheet() {
    Column() {
      this.morePanel()
    }
    .width('100%')
    .padding(HwSpace.lg)
    .id('shMore_' + this.sheetEpoch)
  }

  // ══════════════════════ 自动滚屏 ══════════════════════
  //
  // 长文档免手滑匀速下滚。三个刻意的取舍：
  //  1. **用 scroller.scrollBy 的定时步进**，而不是一次性 animateTo 到结尾 ——
  //     后者在长文上会一次性重排整列表（掉帧），且中途无法暂停；
  //  2. **到底自动停**（isAtEnd），否则定时器会一直空转耗电；
  //  3. **点正文任意处即停**：这是最符合直觉的"叫停"方式，比再去找按钮快。

  /** 标签长按菜单（对应桌面版的右键菜单；路径类操作在沙箱手机上无对应物，未列入）。标题栏由 ModalSheet 官方标题区提供。 */
  @Builder
  tabMenuPanel() {
    // **按钮布局**（用户要求）：原来是一列芯片，功能项之间没有轻重差别、
    // 也不好看清有几个操作。改成与「更多」面板同款的 2×2 等宽按钮磁贴 ——
    // 四个动作各占一格，图标 + 文字，点哪块一目了然。
    Column({ space: HwSpace.sm }) {
      Row({ space: HwSpace.xs }) {
        this.moreTile('关闭此标签', $r('sys.symbol.xmark'), (): void => {
          this.closeTab(this.tabMenuFor);
        })
        this.moreTile('关闭其他', $r('sys.symbol.square_on_square_fill'), (): void => {
          this.closeOtherTabs(this.tabMenuFor);
        })
      }
      .width('100%')

      Row({ space: HwSpace.xs }) {
        this.moreTile('关闭全部', $r('sys.symbol.trash'), (): void => {
          this.closeAllTabs();
        })
        this.moreTile('重新加载', $r('sys.symbol.arrow_counterclockwise'), (): void => {
          this.reloadActiveDoc();
        })
      }
      .width('100%')

      Text(L10n.t('复制路径 / 打开所在文件夹是桌面端能力，应用沙箱内无对应概念'))
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
        .width('100%')
        .padding({ top: HwSpace.xs })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ══════════════════════ 文档详情头（参考图二：封面 → 信息 → 统计） ══════════════════════

  @Builder
  docMetaCard() {
    Column() {
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.md }) {
          // ── 标签按钮（用户要求：爱心左边，点开标签编辑面板）+ 收藏爱心 ──
          Row() {
            ImmersiveIconButton({
              buttonSize: 30,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.openTagEditor();
              }
            }) {
              Text('#')
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.docTags.length > 0 ? this.palette().accent : this.palette().textTertiary)
            }
            Blank()
            SymbolGlyph(this.docStarred ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
              .fontSize(20)
              .fontColor([this.docStarred ? '#FFE5484D' : this.palette().textTertiary])
              .onClick(() => {
                this.toggleStar();
              })
          }
          .width('100%')

          // 封面缩略图（程序化书封，与书架同一套）
          Row() {
            Column() {
              DocCover({
                title: this.docName,
                builtin: this.docBuiltin,
                coverTop: coverColorsOf(this.docName, this.docBuiltin).top,
                coverBottom: coverColorsOf(this.docName, this.docBuiltin).bottom,
                coverInk: coverColorsOf(this.docName, this.docBuiltin).ink,
                coverBadge: this.docBuiltin ? L10n.t('内置教程') : L10n.t('澄笺'),
                edgeColor: this.palette().divider,
                coverColor: this.docCoverColor,
                coverImage: this.docCoverImage,
                // 格式角标：MD / TXT
                formatLabel: this.docFormatLabel()
              })
            }
            .width(150)
            .aspectRatio(0.72)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)

          Column({ space: 3 }) {
            Text(this.docName)
              .fontSize(this.fontSize + 6)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.palette().textPrimary)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.docStatusLine())
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 信息标签行（图二的 chips 形态）
          Row({ space: HwSpace.xs }) {
            Text(L10n.t('字数 ') + this.docWordCount)
              .fontSize(HwType.caption)
              .fontColor(this.palette().textSecondary)
              .padding({ left: 9, right: 9, top: 3, bottom: 3 })
              .borderRadius(HwRadius.pill)
              .backgroundColor(this.palette().quoteBg)
            Text(L10n.t('标题 ') + this.docHeadingCount)
              .fontSize(HwType.caption)
              .fontColor(this.palette().textSecondary)
              .padding({ left: 9, right: 9, top: 3, bottom: 3 })
              .borderRadius(HwRadius.pill)
              .backgroundColor(this.palette().quoteBg)
            Text(L10n.t('代码块 ') + this.docCodeCount)
              .fontSize(HwType.caption)
              .fontColor(this.palette().textSecondary)
              .padding({ left: 9, right: 9, top: 3, bottom: 3 })
              .borderRadius(HwRadius.pill)
              .backgroundColor(this.palette().quoteBg)
            Text(L10n.t('批注 ') + this.annotations.length)
              .fontSize(HwType.caption)
              .fontColor(this.palette().textSecondary)
              .padding({ left: 9, right: 9, top: 3, bottom: 3 })
              .borderRadius(HwRadius.pill)
              .backgroundColor(this.palette().quoteBg)
          }
          .width('100%')

          Divider()
            .strokeWidth(1)
            .color(this.palette().divider)

          // 数据行（图二底部三列式）
          Row() {
            this.metricCell('已读', Math.round(this.progress * 100) + '%')
            this.metricCell('字符', '' + this.docCharCount)
            this.metricCell('表格', '' + this.docTableCount)
            this.metricCell('脚注', '' + this.notes.length)
          }
          .width('100%')

          // ── 文件信息（用户要求）：文件大小 + MD5（字数已在上方 chips 里）──
          Column({ space: HwSpace.xxs }) {
            Row({ space: HwSpace.xs }) {
              Text(L10n.t('文件大小'))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
              Blank()
              Text(this.fileSizeLabel())
                .fontSize(HwType.caption)
                .fontColor(this.palette().textSecondary)
            }
            .width('100%')

            // MD5（用户要求保留显示；「文件哈希」行已按要求删除）。
            // **结构与"文件大小 / 日期"行完全同构**（Blank 撑开右对齐）——
            // 此前用 layoutWeight，与相邻行的滑动表现不一致（用户反馈）
            Row({ space: HwSpace.xs }) {
              Text('MD5')
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
              Blank()
              Text(this.docMd5.length > 0 ? this.docMd5 : '—')
                .fontSize(HwType.caption)
                .fontColor(this.palette().textSecondary)
                .constraintSize({ maxWidth: '62%' })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            // 创建 / 修改日期（用户要求；内置文档没有独立创建时间，显示 —）
            Row({ space: HwSpace.xs }) {
              Text(L10n.t('创建日期'))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
              Blank()
              Text(Reader.timeLabel(this.docCreatedAt))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textSecondary)
            }
            .width('100%')

            Row({ space: HwSpace.xs }) {
              Text(L10n.t('修改日期'))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
              Blank()
              Text(Reader.timeLabel(this.docModifiedAt))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textSecondary)
            }
            .width('100%')
          }
          .width('100%')
          .padding({ top: HwSpace.xxs })

          // YAML Front Matter：顶部 --- 之间的元数据渲染成卡内信息行，不进正文
          if (this.docMeta.length > 0) {
            Column({ space: HwSpace.xxs }) {
              ForEach(this.docMeta, (item: MdMetaItem) => {
                Row({ space: HwSpace.xs }) {
                  Text(item.key)
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textTertiary)
                    .width(86)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.value.length > 0 ? item.value : '—')
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textSecondary)
                    .layoutWeight(1)
                    .maxLines(3)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
              }, (item: MdMetaItem, index: number) => 'fm' + index + '_' + item.key)
            }
            .width('100%')
            .padding({ top: HwSpace.xxs })
          }

          // **文档标签**（用户要求）：信息卡里展示，样式按标签名确定性生成
          //（同名同色、异名错开色相），深浅主题各有一套明暗值。
          if (this.docTags.length > 0) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.docTags, (tag: string) => {
                Text('#' + tag)
                  .fontSize(HwType.caption)
                  .fontColor(TagStyle.fg(tag, this.isDark()))
                  .backgroundColor(TagStyle.bg(tag, this.isDark()))
                  .borderRadius(HwRadius.pill)
                  .border({ width: 1, color: TagStyle.border(tag, this.isDark()) })
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .margin({ right: 6, bottom: 6 })
                  .onClick(() => {
                    // 点标签 → 打开标签面板（与信息卡里的入口一致）
                    this.openTagEditor();
                  })
              }, (tag: string) => 'ctxTag_' + tag)
            }
            .width('100%')
            .padding({ top: HwSpace.xs })
          }

          Text(L10n.t('右滑目录 · 左滑注释 · 底部工具条可调字号与亮度 · 长按选中可荧光笔/批注'))
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .margin({ bottom: HwSpace.lg })
  }

  @Builder
  metricCell(label: string, value: string) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(HwType.label + 2)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.palette().accent)
      Text(label)
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  // ══════════════════════ 悬浮工具条（参考图三：磨砂胶囊悬浮在正文上） ══════════════════════
  //
  // 不占布局——正文铺满整屏，从工具条底下穿过；磨砂外壳（半透明 + 背景模糊），
  // 按钮本体仍是沉浸光感的 ImmersiveIconButton。进度百分比放最左，点击回到顶部。

  @Builder
  floatingToolBar() {
    // **一个胶囊 + 宽度插值**：收起缩到 miniBottom、展开撑到正文列宽。
    // 收放动画就是这条宽度的插值——上一轮拆成两个独立胶囊，宽度不再插值，
    // 收起/展开变成硬切、没有过渡。
    ImmersiveBar({
      palette: this.palette(),
      barPaddingH: HwSpace.xs,
      barPaddingV: HwSpace.xs,
      barHeight: HwBar.pill,
      barWidth: this.bottomBarVisible ? this.bottomBarAdaptiveWidth() : this.bottomBarMiniWidth(),
      barWidthPx: this.bottomBarVisible ? this.bottomBarAdaptiveWidth() : this.bottomBarMiniWidth()
    }) {
      if (this.bottomBarVisible) {
        Row({ space: HwSpace.md }) {
          Text(Math.round(this.progress * 100) + '%')
            .fontSize(HwType.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().accent)
            .width(38)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.lockAutoHide();
              try {
                this.scroller.scrollToIndex(0, true);
              } catch (err) {
                // 忽略
              }
            })

          Column()
            .width(1)
            .height(18)
            .backgroundColor(this.palette().divider)

          ImmersiveIconButton({
            buttonSize: 36,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              // 「目录」按钮已替换为 AI 助手（用户要求 1.2.0）：目录改由右滑手势呼出
              this.openAiChat('');
            }
          }) {
            Image($r('app.media.ai_spark'))
              .width(17)
              .height(17)
              .fillColor(this.palette().textPrimary)
          }

          ImmersiveIconButton({
            buttonSize: 36,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              this.openSettings();
            }
          }) {
            SymbolGlyph($r('sys.symbol.textformat'))
              .fontSize(17)
              .fontColor([this.palette().textPrimary])
          }

          ImmersiveIconButton({
            buttonSize: 36,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              this.openBright();
            }
          }) {
            SymbolGlyph($r('sys.symbol.sun_max'))
              .fontSize(17)
              .fontColor([this.palette().textPrimary])
          }

          // 快速编辑这篇 md：直接进编辑页（内置教程不可编辑）
          ImmersiveIconButton({
            buttonSize: 36,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              this.openEditorFromBar();
            }
          }) {
            SymbolGlyph($r('sys.symbol.square_and_pencil'))
              .fontSize(17)
              .fontColor([this.palette().textPrimary])
          }

          ImmersiveIconButton({
            buttonSize: 36,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              this.openMore();
            }
          }) {
            SymbolGlyph($r('sys.symbol.ellipsis_circle'))
              .fontSize(17)
              .fontColor([this.palette().textPrimary])
          }

          // （标签条不在展开态的胶囊里：它在**胶囊上方**完整显示，见 build 的底部层；
          //   只有胶囊收起时才缩进胶囊内部，见下面的收起态分支。）
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      } else {
        // 收起态：同一枚胶囊把「阅读进度」和「阅读设置」连在一起。
        // 两个控件都不自绘底色——一旦自绘就绕过承载层、没有材质。
        Row({ space: HwSpace.xs }) {
          Text(Math.round(this.progress * 100) + '%')
            .fontSize(HwType.label)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.palette().accent)
            .width(40)
            .height(36)
            .textAlign(TextAlign.Center)
            .borderRadius(18)
            .onClick(() => {
              // 只展开底栏自己，顶栏不受影响
              this.toggleBottomBar(true);
            })

          ImmersiveIconButton({
            buttonSize: 36,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              this.openSettings();
            }
          }) {
            SymbolGlyph($r('sys.symbol.textformat'))
              .fontSize(17)
              .fontColor([this.palette().textPrimary])
          }

          // ── 收起态的标签选择：**缩进胶囊里**，紧挨「阅读设置」按钮 ──
          // 用户要求：展开时标签栏在胶囊上方完整显示（序号+名称）；只有胶囊收起时
          // 才收成这一排数字，跟着胶囊一起缩进来，依旧可横向滑动切换。
          if (this.tabBarAtBottom && this.tabs.length > 1) {
            this.bottomTabs()
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
  }

  /**
   * 悬浮胶囊内部的标签条（**只在标签栏置底时用**）：
   * 一排 1/2/3 数字芯片，与顶栏收起态那排序号同款（当前这篇高亮），
   * 最多摆 5 个、超出可横向滑动；宽度由 bottomTabsWidth() 与胶囊宽度同步计算。
   * 点按切标签、长按弹标签菜单（与顶栏标签栏行为一致）。
   */
  @Builder
  bottomTabs() {
    Scroll() {
      Row({ space: 5 }) {
        ForEach(this.tabs, (tab: ReaderTab, index: number) => {
          Text('' + (index + 1))
            .fontSize(HwType.caption - 1)
            .fontWeight(this.docName === tab.name ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.docName === tab.name ? this.palette().accent : this.palette().textPrimary)
            .textAlign(TextAlign.Center)
            .width(26)
            .height(26)
            .borderRadius(13)
            .backgroundColor(this.tabBaseColor(tab.name))
            .onClick(() => {
              this.activateTab(tab.name);
            })
            .gesture(
              LongPressGesture()
                .onAction(() => {
                  this.openTabMenu(tab.name);
                })
            )
        }, (tab: ReaderTab, index: number) => 'bt' + index + '_' + tab.name + '_' + this.docName)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width(this.bottomTabsWidth())
    .height(30)
    // **两端圆形裁切**（用户要求：直角裁切难看）：曲率与悬浮胶囊同源
    // （HwRadius.pill），横向滑动时数字芯片从圆弧里滑出 / 滑入，
    // 不会在直边上被"切一刀"。clip 必须放在 borderRadius 之后才按圆角裁。
    .borderRadius(HwRadius.pill)
    .clip(true)
  }

  /** 收起态顶栏内容：返回 + 搜索 + 标签序号。外壳由 topBar 的 ImmersiveBar 统一提供。 */  @Builder
  miniTopContent() {
    Row({ space: HwSpace.sm }) {
      ImmersiveIconButton({
        buttonSize: 36,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          this.backToShelf();
        }
      }) {
        SymbolGlyph($r('sys.symbol.arrow_left'))
          .fontSize(16)
          .fontColor([this.palette().textPrimary])
      }
      ImmersiveIconButton({
        buttonSize: 36,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          if (this.searchOpen) {
            this.closeSearch();
          } else {
            // 收起态里点搜索：先把顶栏展开，查找条挂在展开态顶栏下面
            this.toggleTopBar(true);
            this.openSearch();
          }
        }
      }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(16)
          .fontColor([this.palette().textPrimary])
      }

      // 收起后标签不再显示文件名，而是收成 1/2/3 序号——既不丢「开了几篇」的信息，
      // 又能把胶囊压在很窄的宽度里。当前这篇高亮。
      // 胶囊里最多摆 5 个；**超过 5 个可以横向滑动**（Scroll 定宽 = 5 个位）。
      // **标签栏置底时这里不再显示**（用户要求：数字选择跟标签栏一起搬到下方悬浮栏）。
      if (this.tabs.length > 1 && !this.tabBarAtBottom) {
        Scroll() {
          Row({ space: 5 }) {
            ForEach(this.tabs, (tab: ReaderTab, index: number) => {
              // 圆形材质按钮：与顶栏其它按钮同一条材质通路。
              // 26 而非 30：5 个序号连同间距正好落在胶囊内，且上下留出余量不被切。
              ImmersiveIconButton({
                buttonSize: 26,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.activateTab(tab.name);
                }
              }) {
                Text('' + (index + 1))
                  .fontSize(HwType.caption - 1)
                  .fontWeight(this.docName === tab.name ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(this.docName === tab.name ? this.palette().accent : this.palette().textPrimary)
              }
            }, (tab: ReaderTab, index: number) => 'mn' + index + '_' + tab.name + '_' + this.docName)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width(this.collapsedTabsWidth())
        // 26 的序号钮给 30 的槽高，上下各留 2 余量，描边不被裁
        .height(30)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 亮度快捷面板：亮度滑条 + 屏幕常亮 + 主题五档（图三的 ☀ 按钮）。标题栏由 ModalSheet 官方标题区提供。 */
  @Builder
  brightPanel() {
    Column({ space: HwSpace.md }) {
      Row() {
        Text(this.brightLevel <= 0 ? L10n.t('跟随系统') : Math.round(this.brightLevel * 100) + '%')
          .fontSize(HwType.label)
          .fontColor(this.palette().accent)
          .width(64)
        SymbolGlyph($r('sys.symbol.moon'))
          .fontSize(14)
          .fontColor([this.palette().textTertiary])
        Slider({ value: this.brightLevel <= 0 ? 50 : Math.round(this.brightLevel * 100),
          min: 5, max: 100, step: 5, style: SliderStyle.OutSet })
          .layoutWeight(1)
          .selectedColor(this.palette().accent)
          .blockColor(this.palette().accent)
          .onChange((v: number, mode: SliderChangeMode) => {
            const ratio: number = Math.round(v) / 100;
            this.brightLevel = ratio < 0.05 ? 0.05 : ratio;
            setWindowBrightnessLevel(this.brightLevel);
          })
        SymbolGlyph($r('sys.symbol.sun_max'))
          .fontSize(16)
          .fontColor([this.palette().textSecondary])
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: HwSpace.xs }) {
        Text(L10n.t('屏幕常亮'))
          .fontSize(HwType.label)
          .fontColor(this.palette().textPrimary)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.keepOn })
          .onChange((isOn: boolean) => {
            this.keepOn = isOn;
            setKeepScreenOn(isOn);
          })
      }
      .width('100%')

      Row({ space: HwSpace.xs }) {
        this.themeChip(ReaderThemeMode.System, '跟随系统')
        this.themeChip(ReaderThemeMode.Light, '浅色')
        this.themeChip(ReaderThemeMode.Dark, '深色')
      }
      .width('100%')
      Row({ space: HwSpace.xs }) {
        this.themeChip(ReaderThemeMode.Sepia, '羊皮纸')
        this.themeChip(ReaderThemeMode.Green, '护眼绿')
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 「更多」菜单：**2×2 等宽磁贴**（注释 / 回顶 / 设置 / 导出）+ 更多操作行。
   * 标题栏由 ModalSheet 官方标题区提供。 */
  @Builder
  morePanel() {
    Column({ space: HwSpace.sm }) {
      // ── 读写 / 只读开关（与书架「选择操作」面板同一个标记）──
      Row({ space: HwSpace.xs }) {
        Text(L10n.t('读写 / 只读'))
          .fontSize(HwType.label)
          .fontColor(this.palette().textPrimary)
          .layoutWeight(1)
        ImmersiveChip({
          palette: this.palette(),
          chipLabel: L10n.t('可写'),
          chipActive: !this.docReadOnly,
          chipOnTap: () => {
            this.toggleDocReadOnly(false);
          }
        })
        ImmersiveChip({
          palette: this.palette(),
          chipLabel: L10n.t('只读'),
          chipActive: this.docReadOnly,
          chipOnTap: () => {
            this.toggleDocReadOnly(true);
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.docReadOnly
        ? '只读：编辑入口已锁、任务勾选不写盘；批注 / 导出 / 封面设置照常'
        : L10n.t('可写：正文可以在编辑页里修改'))
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
        .width('100%')

      // ── 网页开放（用户要求）：开启后点正文 http(s) 链接直接在半模态面板打开；
      // 关闭维持「点击复制地址」。开关持久化在 readerWebOpen。
      Row({ space: HwSpace.xs }) {
        Column({ space: 2 }) {
          Text(L10n.t('网页开放'))
            .fontSize(HwType.label)
            .fontColor(this.palette().textPrimary)
          Text(L10n.t('开启后点击正文链接直接在面板内打开；关闭则点击复制链接地址'))
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.webOpen })
          .onChange((isOn: boolean) => {
            this.webOpen = isOn;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // ── 大屏 / 平板横屏专属（用户要求）：侧边栏「默认展开」偏好 ──
      // 只在宽屏（横屏且根宽 ≥700）显示；竖屏与手机端是侧滑抽屉，没有这个概念。
      // 改动立即生效（当前会话）并持久化（下次打开文档按此默认）。
      if (this.isWide()) {
        Column({ space: HwSpace.sm }) {
          Row({ space: HwSpace.xs }) {
            Column({ space: 2 }) {
              Text(L10n.t('目录侧边栏默认展开'))
                .fontSize(HwType.label)
                .fontColor(this.palette().textPrimary)
              Text(L10n.t('进入阅读时目录停靠在左侧；运行中仍可手动收放'))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.tocPinnedDefault })
              .onChange((isOn: boolean) => {
                AppStorage.setOrCreate('readerTocPinnedDefault', isOn);
                this.tocPinned = isOn;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: HwSpace.xs }) {
            Column({ space: 2 }) {
              Text(L10n.t('批注侧边栏默认展开'))
                .fontSize(HwType.label)
                .fontColor(this.palette().textPrimary)
              Text(L10n.t('进入阅读时批注停靠在右侧；运行中仍可手动收放'))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.notesPinnedDefault })
              .onChange((isOn: boolean) => {
                AppStorage.setOrCreate('readerNotesPinnedDefault', isOn);
                this.notesPinned = isOn;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
      }

      // ── 主磁贴：**恢复 37fbe28 之前的固定分行**（用户明确要求"恢复以前的排版设计"）。
      //    自适应网格有两个治不好的毛病：① 列数靠 onAreaChange 实测回填，
      //    **第一次打开面板用的还是上一次的宽度**（用户实测：第一次还是旧排版，
      //    第二次才变）；② 换列数后行尾会留空格子。固定 2/3/3/2 四行、每颗
      //    layoutWeight(1) 均分，首帧就是最终形态，永远铺满不留缝。──
      Row({ space: HwSpace.xs }) {
        this.moreTile('注释与批注', $r('sys.symbol.paintbrush'), (): void => {
          this.openNotes();
        })
        this.moreTile('回到顶部', $r('sys.symbol.arrow_up_circle'), (): void => {
          this.lockAutoHide();
          try {
            this.scroller.scrollToIndex(0, true);
          } catch (err) {
            // 忽略
          }
        })
      }
      .width('100%')

      Row({ space: HwSpace.xs }) {
        this.moreTile('阅读设置', $r('sys.symbol.gearshape'), (): void => {
          this.openSettings();
        })
        this.moreTile('导出与分享', $r('sys.symbol.doc_text_badge_arrow_up'), (): void => {
          this.openExport();
        })
        // 合并导出：多篇拼一篇（选篇 + 排序 + HTML/打印/MD/TXT）
        this.moreTile('合并导出', $r('sys.symbol.doc_plaintext'), (): void => {
          this.openMergeExport();
        })
      }
      .width('100%')

      Row({ space: HwSpace.xs }) {
        // EPUB 导出（批 5）：整篇转成电子书（单章 + 内嵌样式）
        this.moreTile('EPUB 电子书', $r('sys.symbol.book'), (): void => {
          this.exportEpub();
        })
        // 反向链接：哪些文档引用了本篇（知识图谱的单篇视角）
        this.moreTile('被引用', $r('sys.symbol.arrow_up_left_and_arrow_down_right'), (): void => {
          this.openBacklinks();
        })
        // 图片管理：本文档引用过的图，逐张查看 / 另存 / 替换 / 删除引用
        this.moreTile('图片管理', $r('sys.symbol.picture'), (): void => {
          this.openImageManager();
        })
      }
      .width('100%')

      Row({ space: HwSpace.xs }) {
        // 分屏对照（批 5）：选另一篇文档与当前并排对照
        this.moreTile('对照阅读', $r('sys.symbol.rectangle_split_2x1'), (): void => {
          this.openCompare();
        })
        // 文献引用（批 5）：GB/T 7714 / APA / BibTeX 三格式一次复制
        this.moreTile('文献引用', $r('sys.symbol.doc_text'), (): void => {
          this.copyCitation();
        })
      }
      .width('100%')

      // ── 朗读全文：系统 TTS 逐段读（自持状态子组件，与自动滚屏互斥）──
      ReadAloudTile({
        palette: this.palette(),
        onPlay: (): void => {
          this.startReadAloud();
        },
        onPause: (): void => {
          this.pauseReadAloud();
        },
        onStop: (): void => {
          this.stopReadAloud();
        }
      })

      // ── 自动滚屏：更多里的小功能（通栏一格，自持状态子组件）──
      AutoScrollTile({
        palette: this.palette(),
        onToggle: (on: boolean): void => {
          if (on) {
            this.startAutoScroll();
          } else {
            // 面板里的「暂停」= 暂停（浮钮保留、可继续），不是结束会话
            this.pauseAutoScroll();
          }
        },
        onSpeed: (v: number): void => {
          this.onAutoSpeedChange(v);
        }
      })

      // ── 更多操作：与上方同样的**等宽磁贴**（用户要求排版统一）──
      Row({ space: HwSpace.xs }) {
        this.moreTile('复制全文', $r('sys.symbol.doc_plaintext'), (): void => {
          this.copyWholeText();
        })
        // 开关类磁贴用**自持状态的子组件**：bindSheet 的 builder 不跟宿主状态重渲染，
        // 写在宿主里点了标签不变（用户反馈）——组件自己订阅/自己写/自己刷
        ReaderFlagTile({
          kind: 'meta',
          palette: this.palette(),
          onChanged: (on: boolean) => {
            this.toast(on ? L10n.t('已显示信息卡') : L10n.t('已隐藏信息卡'));
          }
        })
      }
      .width('100%')

      Row({ space: HwSpace.xs }) {
        this.moreTile('重新加载', $r('sys.symbol.arrow_counterclockwise'), (): void => {
          this.loadDoc();
          this.toast(L10n.t('已重新加载'));
        })
        ReaderFlagTile({
          kind: 'drawer',
          palette: this.palette(),
          onChanged: (on: boolean) => {
            this.toast(on ? L10n.t('侧边栏已开启沉浸光感') : L10n.t('侧边栏改用阅读背景色'));
          }
        })
      }
      .width('100%')

      // ── 标签栏位置：**自持状态磁贴**（实时切换文案与图标）；
      //    空出的格子放入「亮度与主题」──
      Row({ space: HwSpace.xs }) {
        ReaderFlagTile({
          kind: 'tabbar',
          palette: this.palette(),
          onChanged: (on: boolean) => {
            this.toast(on ? L10n.t('标签栏已移到底部悬浮栏上方') : L10n.t('标签栏已移回顶部'));
          }
        })
        // 新增功能（补位）：亮度与主题面板入口（原来只能从底部工具条进）
        this.moreTile('亮度与主题', $r('sys.symbol.sun_max'), (): void => {
          this.openBright();
        })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 「更多」面板的等宽磁贴：图标 + 文字，点击整块响应。 */
  @Builder
  moreTile(label: string, icon: Resource, action: () => void) {
    Column({ space: 6 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([this.palette().accent])
      Text(label)
        .fontSize(HwType.caption)
        .fontColor(this.palette().textPrimary)
        .maxLines(1)
    }
    // 均分所在行的宽度（一行几颗就几等分）——首帧即最终形态，
    // 不需要等 onAreaChange 实测回填（那正是"第一次打开排版不对"的成因）
    .layoutWeight(1)
    .height(72)
    .justifyContent(FlexAlign.Center)
    .borderRadius(HwRadius.inner)
    .backgroundColor(this.palette().quoteBg)
    .onClick(() => {
      action();
    })
  }

  /** 复制全文到剪贴板（更多面板新增能力）。 */
  private copyWholeText(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      DocStore.init(ctx);
      const meta: DocMeta | undefined = DocStore.find(ctx, this.docName);
      if (meta === undefined) {
        this.toast(L10n.t('文档不存在'));
        return;
      }
      const text: string = DocStore.readText(ctx, meta, this.docEncoding);
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.toast('已复制全文（' + text.length + ' 字）');
      }).catch(() => {
        this.toast(L10n.t('复制失败'));
      });
    } catch (err) {
      this.toast(L10n.t('复制失败'));
    }
  }

  /**
   * 复制文献引用（批 5 之文献引用）：按文档名 + 修改时间生成
   * GB/T 7714（中文首选）/ APA / BibTeX 三种格式，一次复制，写作时直接粘。
   */
  private copyCitation(): void {
    const y: number = this.docModifiedAt > 0 ? new Date(this.docModifiedAt).getFullYear()
      : new Date().getFullYear();
    const safe: string = this.docName.replace(/[^A-Za-z0-9]/g, '') || 'doc';
    const gb: string = '[1] ' + this.docName + '[Z]. 澄笺笔记, ' + y + '.';
    const apa: string = this.docName + '. (' + y + '). 澄笺笔记.';
    const bib: string = '@misc{' + safe + y + ',\n  title = {' + this.docName + '},\n  year = {' + y + '},\n  note = {澄笺笔记}\n}';
    const text: string = gb + '\n\n' + apa + '\n\n' + bib;
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.toast(L10n.t('已复制 GB/T 7714 / APA / BibTeX 三种引用'));
    }).catch(() => {
      this.toast(L10n.t('复制失败'));
    });
  }

  /**
   * 代码块放大时按 geoKey（'mdcode_' + 块 id）找回那一块，交出它的高亮行 CSV。
   * 找不到 / 没有围栏元数据 → 空串（模板一行都不亮）。
   */
  private codeHlCsv(geoKey: string): string {
    const id: string = geoKey.startsWith('mdcode_') ? geoKey.substring('mdcode_'.length) : '';
    if (id.length === 0) {
      return '';
    }
    for (let k = 0; k < this.blocks.length; k++) {
      if (this.blocks[k].id === id) {
        const hl: number[] | undefined = this.blocks[k].hlLines;
        return hl === undefined ? '' : hl.join(',');
      }
    }
    return '';
  }

  /** 打开放大浮层（正文 / 对照面板共用）：图片 payload 统一转 file:// + URL 编码，
   *  挂载包在 animateTo 里让一镜到底几何动画生效。 */
  /**
   * 下载当前放大内容的**浅色快照 PNG**（用户要求，尝试性功能）：
   * 固定浅色、纯色背景——只取预渲染池烘的浅色版（payload 索引反查）。
   * 没有浅色快照（深色模式下看的图）时提示先在浅色模式查看，实验功能后续再优化。
   */
  private openEnlarge(mode: string, payload: string, geoKey: string, title: string): void {
    // 图片放大用**原生 Image 组件**；payload 统一转
    // `file://` + URL 编码（中文路径不编码时首次加载会失败，
    // 用户实测"第一次打开没画面，重开才正常"）
    let pl: string = payload;
    if (mode === 'image') {
      if (!pl.startsWith('file://') && !pl.startsWith('http')) {
        pl = pl.startsWith('/') ? 'file://' + encodeURI(pl)
          : 'file://' + encodeURI(DocStore.docsRoot() + '/' + pl);
      } else if (pl.startsWith('file://')) {
        pl = 'file://' + encodeURI(pl.substring('file://'.length));
      }
      this.imgScale = 1;
      this.imgDx = 0;
      this.imgDy = 0;
      this.rotated = false;
    }
    // **一镜到底**：挂载浮层必须包在 animateTo 里，geometryTransition
    // 才会把正文里的小卡片形变成全屏大画布
    this.getUIContext().animateTo({ duration: 320, curve: Curve.FastOutSlowIn }, () => {
      this.enlargeMode = mode;
      // 每次打开浮层都清空"切源码前的形态"：从代码块放大进来时它为空，
      // 用于隐藏「查看源码」开关（见 enlargeHasCode）
      this.enlargePrevMode = '';
      this.enlargePayload = pl;
      // **代码块放大补上语法颜色**：正文卡片是 ArkUI Span 逐 token 上色，浮层走 Web，
      // 此前只喂纯文本 → 一放大颜色全丢（用户实测）。用**同一套**分词与配色生成
      // 带色 HTML 随 payload 注入，两处逐 token 一致；代码块的 title 就是围栏语言 id。
      this.enlargeRichHtml = mode === 'code'
        ? MdViewUtil.highlightToHtml(pl, title, this.palette())
        : '';
      this.enlargeHlCsv = mode === 'code' ? this.codeHlCsv(geoKey) : '';
      this.enlargeGeo = geoKey;
      this.enlargeTitle = title;
      this.enlargeWebMounted = true;
      this.enlargeRefitTick = 0;
      AppStorage.setOrCreate('readerOverlayOpen', true);
    });
  }

  // ══════════════════════ 朗读（系统 TTS） ══════════════════════
  //
  // 用 Core Speech Kit 的 textToSpeech 逐段朗读：一段读完在 onComplete 里接着读下一段。
  // 两个刻意的决定：
  //  1. **按块推进**（而不是把整篇丢给引擎）：这样"读到哪就滚到哪"，也便于随时停；
  //  2. **与自动滚屏互斥**：两者都在驱动屏幕位置，同时开必然打架 —— 开始一个就停另一个；
  //     同时复用同一颗悬浮钮（点一下暂停 / 继续，长按结束）。

  /**
   * **朗读用的纯文本**：从行内片段拼，而不是用 `block.plain`。
   *
   * 为什么不能用 plain：它是**源码文本**（段落工厂里 `plain: text`），
   * 里面带着 `**粗体**`、`` `代码` ``、`[链接](地址)` 这些记号 ——
   * 直接念出来就是"星号星号……"，听着很难受（用户反馈）。
   * 行内片段是**渲染文本**（粗体片段的 text 就是"粗体"两个字），拼起来天然干净。
   */
  private spokenTextOf(block: MdBlock): string {
    let out: string = '';
    for (let k: number = 0; k < block.inlines.length; k++) {
      const it: MdInline = block.inlines[k];
      // 图片地址与脚注序号读出来没有意义，跳过
      if (it.kind === MdInlineKind.Image || it.kind === MdInlineKind.FootnoteRef) {
        continue;
      }
      let piece: string = it.text;
      if (it.kind === MdInlineKind.Link && piece.length === 0) {
        piece = it.href;
      }
      out = out + piece;
    }
    if (out.trim().length > 0) {
      return out.trim();
    }
    // 兜底（行内片段为空的老数据）：拿源码粗洗一遍，至少别把标记念出来
    return block.plain
      .replace(/^[#>\-\s]+/, '')
      .replace(/[*`~]/g, '')
      .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
      .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
      .trim();
  }

  /** 可朗读的块下标序列（跳过代码 / 图表 / 公式 / 表格 / 分割线 / 空文本）。 */
  private ttsBuildQueue(): void {
    const q: number[] = [];
    for (let k: number = 0; k < this.blocks.length; k++) {
      const b: MdBlock = this.blocks[k];
      if (b.kind === MdBlockKind.Code || b.kind === MdBlockKind.Chart
        || b.kind === MdBlockKind.Math || b.kind === MdBlockKind.Table
        || b.kind === MdBlockKind.Divider) {
        continue;
      }
      if (this.spokenTextOf(b).length > 0) {
        q.push(k);
      }
    }
    this.ttsQueue = q;
  }

  /** 开始朗读：创建引擎（幂等）后从当前阅读位置读起。 */
  private startReadAloud(): void {
    if (this.ttsOn) {
      this.resumeReadAloud();
      return;
    }
    if (this.docName.length === 0) {
      return;
    }
    // 互斥：朗读与自动滚屏都在驱动屏幕位置，同时开会打架
    this.stopAutoScroll();
    // 浮钮首次出现的位置（与自动滚屏同款：按握姿定边、屏幕中部）
    if (this.pauseBtnX < 0) {
      this.pauseBtnX = this.sideToX(this.gripSide, 44);
    }
    if (this.pauseBtnY < 0) {
      this.pauseBtnY = this.rootHeight / 2 - 22;
    }
    this.ttsBuildQueue();
    if (this.ttsQueue.length === 0) {
      this.toast(L10n.t('这篇没有可朗读的正文'));
      return;
    }
    // 起点 = 当前读到的那一段（找不到就从第一段开始）
    let pos: number = 0;
    for (let k: number = 0; k < this.ttsQueue.length; k++) {
      if (this.ttsQueue[k] >= this.progressBlock) {
        pos = k;
        break;
      }
    }
    this.ttsPos = pos;
    this.ttsRequest = this.ttsRequest + 1;
    if (this.ttsEngine !== null) {
      this.ttsOn = true;
      this.ttsPlayCurrent();
      return;
    }
    const mode: string = AppStorage.get<string>('appMode') ?? '';
    const params: textToSpeech.CreateEngineParams = {
      language: 'zh-CN',
      person: 0,
      // 基础离线模式下只能用离线音色；否则用在线音色（更自然）
      online: mode === 'offline' ? 0 : 1
    };
    textToSpeech.createEngine(params).then((engine: textToSpeech.TextToSpeechEngine) => {
      this.ttsEngine = engine;
      engine.setListener({
        onStart: (requestId: string, response: textToSpeech.StartResponse) => {
          this.ttsSpeaking = true;
        },
        onComplete: (requestId: string, response: textToSpeech.CompleteResponse) => {
          // 一句读完：接着读下一句 / 下一段。
          // ⚠️ 必须同时判断"没在暂停中"——`stop()` 也会走到 onComplete，
          // 只判断 ttsOn 的话，一暂停就会立刻被当成"这句读完了"继续读下一句，
          // 表现就是**暂停根本停不下来**（用户反馈）。
          if (this.ttsOn && !this.ttsPaused) {
            this.ttsAdvance();
          }
        },
        onStop: (requestId: string, response: textToSpeech.StopResponse) => {
          this.ttsSpeaking = false;
        },
        onError: (requestId: string, errorCode: number, errorMessage: string) => {
          this.ttsSpeaking = false;
          this.stopReadAloud();
          this.toast('朗读失败（' + errorCode + '）：' + errorMessage);
        }
      });
      this.ttsOn = true;
      this.ttsPlayCurrent();
    }).catch((err: BusinessError) => {
      this.ttsOn = false;
      this.ttsSpeaking = false;
      this.toast('朗读引擎不可用：' + err.message);
    });
  }

  /** 读当前这一段：切成句子逐句朗读，并把"正在读的那句"高亮出来。 */
  private ttsPlayCurrent(): void {
    if (this.ttsEngine === null || this.ttsPos < 0 || this.ttsPos >= this.ttsQueue.length) {
      this.stopReadAloud();
      return;
    }
    const blockIndex: number = this.ttsQueue[this.ttsPos];
    if (blockIndex < 0 || blockIndex >= this.blocks.length) {
      this.stopReadAloud();
      return;
    }
    // ⚠️ 不再自动滚动（用户要求："不自动滑动正在阅读位置了，不动了"）——
    // 朗读只出声，屏幕停在用户自己滚到的位置；想跟读就自己翻。
    // 渲染文本 → 按句切分 → 从第一句读起
    this.ttsRendered = this.renderedTextOf(this.blocks[blockIndex]);
    this.ttsSegs = this.splitSentences(this.ttsRendered);
    this.ttsSegAt = 0;
    this.ttsSpeakSegment();
  }

  /** 朗读当前块的第 ttsSegAt 句。 */
  private ttsSpeakSegment(): void {
    if (this.ttsEngine === null) {
      this.stopReadAloud();
      return;
    }
    if (this.ttsSegAt >= this.ttsSegs.length) {
      this.ttsNext();
      return;
    }
    const seg: number[] = this.ttsSegs[this.ttsSegAt];
    this.ttsSegStart = seg[0];
    this.ttsSegEnd = seg[1];
    // 朗读文本 = 该句的渲染文本；图片路径之类念出来是噪音，读之前清一下
    let spoken: string = this.ttsRendered.substring(seg[0], seg[1])
      .replace(/[^\s]*\.(png|jpg|jpeg|gif|webp|svg|bmp)/gi, '').trim();
    if (spoken.length === 0) {
      this.ttsSegAt = this.ttsSegAt + 1;
      this.ttsSpeakSegment();
      return;
    }
    // ⚠️ SpeakParams 只有 requestId（+ 可选 extraParams）：在线/离线是**建引擎**时定的
    // （CreateEngineParams.online），不是每次朗读的参数。
    // requestId 每次发声都取新的：恢复朗读时复用同一个 id 可能被引擎当成重复请求拒掉。
    this.ttsSpeakSeq = this.ttsSpeakSeq + 1;
    const speakParams: textToSpeech.SpeakParams = {
      requestId: 'cj_' + this.ttsRequest + '_' + this.ttsSpeakSeq
    };
    try {
      this.ttsEngine.speak(spoken, speakParams);
      this.ttsSpeaking = true;
    } catch (err) {
      this.stopReadAloud();
      this.toast(L10n.t('朗读失败，已停止'));
    }
  }

  /** 一句读完：推进到下一句；本段读完推进到下一段。 */
  private ttsAdvance(): void {
    this.ttsSegAt = this.ttsSegAt + 1;
    if (this.ttsSegAt >= this.ttsSegs.length) {
      this.ttsNext();
    } else {
      this.ttsSpeakSegment();
    }
  }

  /**
   * 当前块的**渲染文本**：逐行内片段用 `MdViewUtil.spanLabel` 拼 ——
   * 这正是正文渲染时每个 Span 的内容，所以句子的字符偏移与批注坐标系**完全一致**，
   * 高亮才能精确压在正在读的那几个字上。
   */
  private renderedTextOf(block: MdBlock): string {
    let out: string = '';
    for (let k: number = 0; k < block.inlines.length; k++) {
      out = out + MdViewUtil.spanLabel(block.inlines[k]);
    }
    return out;
  }

  /**
   * 把渲染文本按句切分，返回若干 `[start, end)` 区间（**含标点**）。
   * 断句依据：。！？!?；;\n；超过 120 字的长句再按逗号/顿号二次切分，
   * 否则一句话读十几秒，暂停和跟读都不灵。
   */
  private splitSentences(text: string): number[][] {
    const segs: number[][] = [];
    let start: number = 0;
    let k: number = 0;
    while (k < text.length) {
      const ch: string = text.charAt(k);
      const isBreak: boolean = ch === '。' || ch === '！' || ch === '？' || ch === '!'
        || ch === '?' || ch === ';' || ch === '；' || ch === '\n';
      if (!isBreak) {
        k++;
        continue;
      }
      // 收尾的引号 / 括号跟着句子一起走（"……。" 不能把引号落下）
      let end: number = k + 1;
      while (end < text.length && (text.charAt(end) === '”' || text.charAt(end) === '）'
        || text.charAt(end) === '"')) {
        end++;
      }
      if (text.substring(start, end).trim().length > 0) {
        segs.push([start, end]);
      }
      start = end;
      k = end;
    }
    if (start < text.length && text.substring(start).trim().length > 0) {
      segs.push([start, text.length]);
    }
    // 长句二次切分：在逗号 / 顿号 / 冒号处落刀，每段至少 40 字才切
    const out: number[][] = [];
    for (let s: number = 0; s < segs.length; s++) {
      const from: number = segs[s][0];
      const to: number = segs[s][1];
      if (to - from <= 120) {
        out.push(segs[s]);
        continue;
      }
      let last: number = from;
      for (let p: number = from; p < to; p++) {
        const ch2: string = text.charAt(p);
        if (ch2 === '，' || ch2 === ',' || ch2 === '、' || ch2 === '：' || ch2 === ':') {
          if (p + 1 - last >= 40) {
            out.push([last, p + 1]);
            last = p + 1;
          }
        }
      }
      if (last < to) {
        out.push([last, to]);
      }
    }
    return out;
  }

  /** 推进到下一段（读完整篇则自然结束）。 */
  private ttsNext(): void {
    this.ttsPos = this.ttsPos + 1;
    if (this.ttsPos >= this.ttsQueue.length) {
      this.toast(L10n.t('已读完这篇'));
      this.stopReadAloud();
      return;
    }
    this.ttsPlayCurrent();
  }

  /** 暂停（引擎停声，会话保留，可继续）。 */
  private pauseReadAloud(): void {
    // 先落"暂停中"标记再 stop：stop 会同步/异步触发 onComplete，
    // 标记早一步落下，onComplete 才不会把这次中断当成"读完一段"继续往下读
    this.ttsPaused = true;
    this.ttsSpeaking = false;
    if (this.ttsEngine !== null) {
      try {
        this.ttsEngine.stop();
      } catch (err) {
        // 停声失败不影响状态复位
      }
    }
  }

  /** 继续（从当前这一句重新读 —— 引擎不支持句中续播，停在哪就从哪句开头重来）。 */
  private resumeReadAloud(): void {
    if (this.ttsEngine === null) {
      this.ttsOn = false;
      this.ttsPaused = false;
      this.startReadAloud();
      return;
    }
    this.ttsPaused = false;
    this.ttsSpeakSegment();
  }

  /** 浮钮点击：朗读中 → 暂停/继续；否则走自动滚屏的暂停/继续。 */
  private floatTogglePause(): void {
    if (this.ttsOn) {
      if (this.ttsSpeaking) {
        this.pauseReadAloud();
      } else {
        this.resumeReadAloud();
      }
      return;
    }
    this.toggleAutoScrollPause();
  }

  /** 结束朗读并释放引擎（离开页面 / 长按浮钮 / 读完整篇）。 */
  private stopReadAloud(): void {
    this.ttsOn = false;
    this.ttsSpeaking = false;
    this.ttsPaused = false;
    this.ttsPos = -1;
    this.ttsSegStart = -1;
    this.ttsSegEnd = -1;
    this.ttsSegs = [];
    const engine: textToSpeech.TextToSpeechEngine | null = this.ttsEngine;
    this.ttsEngine = null;
    if (engine === null) {
      return;
    }
    try {
      engine.stop();
    } catch (err) {
      // 忽略
    }
    try {
      engine.shutdown();
    } catch (err) {
      // 忽略：释放失败也只是占用一点资源
    }
  }

  /** 浮钮是否显示（自动滚屏会话 或 朗读会话）。 */
  private floatBtnVisible(): boolean {
    return this.autoBarVisible || this.ttsOn;
  }

  /**
   * 传给块视图的批注列表：朗读时**注入一条合成高亮**（当前正在读的那句）。
   *
   * 复用荧光笔的渲染管道（坐标 / 透明度 / 主题色全部现成），不用给 MdView 加任何新概念。
   * 缓存以"块 + 句区间 + 批注数"为键：同一句话期间返回同一数组，
   * 避免正文滚动期间每次重渲染都新建数组造成 @Prop 抖动。
   */
  // （逐字高亮已按用户要求取消：只保留"当前正在播放的段落居中展示"）

  /** 浮钮图标：暂停态显示「播放」，运行态显示「暂停」（两种功能共用）。 */
  private floatBtnRunning(): boolean {
    return this.ttsOn ? this.ttsSpeaking : this.autoScrolling;
  }

  // ══════════════════════ 图片管理 ══════════════════════
  //
  // 一篇文档里插过的图散落各处：有的来自相册、有的是手写笔记导出的 PNG、
  // 有的是网络图。想清一张、换一张，靠翻正文找语法太费劲。
  // 这里把它们汇总成一份清单（缩略图 + 大小 + 是否存在），逐张处理。

  /** 扫出本文引用的图片（按正文出现顺序，去重）。 */
  private scanDocImages(): void {
    const out: DocImage[] = [];
    try {
      const re: RegExp = /!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;
      let m: RegExpExecArray | null = re.exec(this.rawContent);
      while (m !== null) {
        const raw: string = m[0];
        const href: string = m[2];
        let dup: boolean = false;
        for (let k: number = 0; k < out.length; k++) {
          if (out[k].href === href) {
            dup = true;
            break;
          }
        }
        if (!dup && href.length > 0) {
          const net: boolean = href.startsWith('http://') || href.startsWith('https://');
          const src: string = net ? href : DocStore.resolveImagePath(href);
          let label: string = href;
          const slash: number = href.lastIndexOf('/');
          if (slash >= 0 && slash + 1 < href.length) {
            label = href.substring(slash + 1);
          }
          out.push({
            raw: raw,
            href: href,
            src: src,
            label: label,
            net: net,
            exists: net ? true : src.length > 0
          } as DocImage);
        }
        m = re.exec(this.rawContent);
      }
    } catch (err) {
      // 正则异常不该让面板打不开
    }
    this.docImages = out;
  }

  /** 打开图片管理面板。 */
  private openImageManager(): void {
    if (this.docName.length === 0) {
      return;
    }
    this.scanDocImages();
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.activeSheet = 'images';
      this.sheetVisible = true;
    });
  }

  /** 点缩略图：复用阅读页既有的放大浮层。 */
  private openDocImage(index: number): void {
    if (index < 0 || index >= this.docImages.length) {
      return;
    }
    const item: DocImage = this.docImages[index];
    if (item.src.length === 0) {
      this.toast(item.net ? L10n.t('网络图片地址不可用') : L10n.t('本地图片不存在：') + item.href);
      return;
    }
    this.openZoomImage('docimg_' + index, item.src);
  }

  /** 把图片交给系统分享 / 另存（网络图不支持）。 */
  private saveDocImage(index: number): void {
    if (index < 0 || index >= this.docImages.length) {
      return;
    }
    const item: DocImage = this.docImages[index];
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    if (item.net) {
      this.toast(L10n.t('网络图片请长按图片保存，或先替换成本地图片'));
      return;
    }
    if (!item.exists) {
      this.toast(L10n.t('本地图片不存在，无法另存'));
      return;
    }
    ExportService.shareFile(ctx, DocStore.resolveAbsImagePath(item.href), (m: string): void => {
      this.toast(m);
    });
  }

  /**
   * 用相册里的图替换这一张（只改正文里的地址，不动别处）。
   * 新图会复制进 docs/images/，与原图共存 —— 原图不删，误操作还能改回来。
   */
  private replaceDocImage(index: number): void {
    if (this.docReadOnly || this.docBuiltin) {
      this.toast(L10n.t('只读 / 内置文档不能改图片引用'));
      return;
    }
    if (index < 0 || index >= this.docImages.length) {
      return;
    }
    const item: DocImage = this.docImages[index];
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      const photoPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      photoPicker.select(options).then((result: photoAccessHelper.PhotoSelectResult) => {
        if (result === undefined || result === null || result.photoUris === undefined
          || result.photoUris.length === 0) {
          return;
        }
        const rel: string | null = DocStore.importImageFromUri(ctx, result.photoUris[0]);
        if (rel === null) {
          this.toast(L10n.t('图片导入失败：格式不支持或超过 20MB'));
          return;
        }
        this.replaceInDoc(item.raw, item.raw.replace(item.href, rel), '已替换为 ' + rel);
      }).catch((err: BusinessError) => {
        this.toast('选择图片失败：' + err.message);
      });
    } catch (err) {
      this.toast(L10n.t('无法打开图片选择器'));
    }
  }

  /** 删除这一张的引用（只动正文里那一处，图片文件保留，可到数据管理清理）。 */
  private removeDocImage(index: number): void {
    if (this.docReadOnly || this.docBuiltin) {
      this.toast(L10n.t('只读 / 内置文档不能修改正文'));
      return;
    }
    if (index < 0 || index >= this.docImages.length) {
      return;
    }
    const item: DocImage = this.docImages[index];
    this.getUIContext().showAlertDialog({
      title: L10n.t('删除这张图片的引用？'),
      message: L10n.t('只从正文里移除 `') + item.label + '` 这一处引用，图片文件仍保留在应用里'
        + '（可在「设置 → 数据管理 → 图片管理」清理）。',
      primaryButton: {
        value: L10n.t('取消'),
        action: () => {
          // 什么都不做
        }
      },
      secondaryButton: {
        value: L10n.t('删除引用'),
        action: () => {
          this.replaceInDoc(item.raw, '', '已删除该图片引用');
        }
      }
    });
  }

  /** 把正文里某段原文替换成新内容并落盘重载（图片管理的统一出口）。 */
  private replaceInDoc(from: string, to: string, okMsg: string): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      const meta: DocMeta | undefined = DocStore.find(ctx, this.docName);
      if (meta === undefined) {
        this.toast(L10n.t('文档不存在'));
        return;
      }
      const text: string = DocStore.readText(ctx, meta, this.docEncoding);
      const at: number = text.indexOf(from);
      if (at < 0) {
        this.toast(L10n.t('正文里找不到这张图片的原始写法，可能已被编辑过'));
        return;
      }
      const next: string = text.substring(0, at) + to + text.substring(at + from.length);
      if (!DocStore.update(ctx, this.docName, next)) {
        this.toast(L10n.t('保存失败'));
        return;
      }
      this.skipRestoreOnce = true;
      this.loadDoc();
      this.scanDocImages();
      this.toast(okMsg);
    } catch (err) {
      this.toast('保存失败：' + DocStore.describeError(err as BusinessError));
    }
  }

  /** 图片管理面板：缩略图 + 名称 + 状态，逐张查看 / 另存 / 替换 / 删除引用。 */
  @Builder
  imagesSheet() {
    Column({ space: HwSpace.sm }) {
      if (this.docImages.length === 0) {
        Text(L10n.t('这篇文档里还没有图片。'))
          .fontSize(HwType.label)
          .fontColor(this.palette().textPrimary)
          .width('100%')
        Text(L10n.t('在编辑页用「插图片」从相册选图，或手写笔记导出后插入，都会出现在这里。'))
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .width('100%')
      } else {
        Text(L10n.t('共 ') + this.docImages.length + ' 张 · 点缩略图放大查看')
          .fontSize(HwType.label)
          .fontColor(this.palette().textPrimary)
          .width('100%')

        ForEach(this.docImages, (item: DocImage, index: number) => {
          Row({ space: HwSpace.sm }) {
            // 缩略图（找不到的本地图 / 网络图用占位块表示状态）
            if (item.src.length > 0) {
              Image(item.src)
                .width(46)
                .height(46)
                .objectFit(ImageFit.Cover)
                .borderRadius(HwRadius.inner)
                .border({ width: 1, color: this.palette().divider })
                .onClick(() => {
                  this.openDocImage(index);
                })
            } else {
              Column() {
                SymbolGlyph($r('sys.symbol.picture'))
                  .fontSize(16)
                  .fontColor([this.palette().textTertiary])
              }
              .width(46)
              .height(46)
              .justifyContent(FlexAlign.Center)
              .borderRadius(HwRadius.inner)
              .backgroundColor(this.palette().quoteBg)
            }

            Column({ space: 2 }) {
              Text(item.label)
                .fontSize(HwType.label)
                .fontColor(this.palette().textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(item.net ? L10n.t('网络图片') : (item.exists ? L10n.t('本地图片') : L10n.t('文件不存在')))
                .fontSize(HwType.caption)
                .fontColor(item.exists ? this.palette().textTertiary : '#FFD93B3B')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // 配色语义与其他面板一致：绿=安全动作（另存）、蓝=中性动作（替换）、红=破坏性（删除）
            ImmersiveChip({
              palette: this.palette(),
              chipTint: '#FF2E7D32',
              chipActive: true,
              chipLabel: L10n.t('另存'),
              chipOnTap: () => {
                this.saveDocImage(index);
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipTint: '#FF2F63E8',
              chipActive: true,
              chipLabel: L10n.t('替换'),
              chipOnTap: () => {
                this.replaceDocImage(index);
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipTint: '#FFD32F2F',
              chipActive: true,
              chipLabel: L10n.t('删除'),
              chipOnTap: () => {
                this.removeDocImage(index);
              }
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: HwSpace.xs, bottom: HwSpace.xs })
          .border({
            width: { bottom: 1 },
            color: this.palette().divider,
            style: BorderStyle.Dashed
          })
        }, (item: DocImage) => 'img_' + item.raw)
      }
    }
    .width('100%')
    .padding(HwSpace.lg)
    .id('shImages_' + this.sheetEpoch)
  }

  /** 反向链接面板：列出引用了本篇的文档，点一条直接开标签跳过去。 */
  @Builder
  backlinksSheet() {
    Column({ space: HwSpace.sm }) {
      if (this.backlinks.length === 0) {
        Text(L10n.t('还没有别的文档引用《') + this.docName + '》。')
          .fontSize(HwType.label)
          .fontColor(this.palette().textPrimary)
          .width('100%')
        Text(L10n.t('在别的文档里写 [[《') + this.docName + '》]] 就能建立连接，连好之后这里会自动列出来。')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .width('100%')
      } else {
        Text(this.backlinks.length + ' 篇文档引用了本篇')
          .fontSize(HwType.label)
          .fontColor(this.palette().textPrimary)
          .width('100%')

        ForEach(this.backlinks, (name: string) => {
          Row({ space: HwSpace.xs }) {
            SymbolGlyph($r('sys.symbol.arrow_up_right'))
              .fontSize(13)
              .fontColor([this.palette().accent])
            Text(name)
              .fontSize(HwType.label)
              .fontColor(this.palette().textPrimary)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .height(44)
          .padding({ left: HwSpace.md, right: HwSpace.md })
          .borderRadius(HwRadius.inner)
          .backgroundColor(this.palette().quoteBg)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openBacklinkDoc(name);
          })
        }, (name: string) => name)
      }
    }
    .width('100%')
    .padding(HwSpace.lg)
    .id('shBack_' + this.sheetEpoch)
  }

  // ══════════════════════ 放大浮层存为图片 ══════════════════════
  //
  // 代码块 / 图表 / 公式在放大浮层里都是 DiagramWeb 渲染的网页，
  // 用它的整页快照（webPageSnapshot）抓完整绘制结果 —— 比 componentSnapshot
  // 对 Web 表面可靠（组件快照对 Web 只抓可视区，长代码块会截不全）。
  // 抓到的是 PixelMap，打成 PNG 后走系统另存为（与 PDF / 图片导出同一条出路）。

  // ══════════════════════ 反向链接 ══════════════════════
  //
  // 知识图谱给出的是「全库关系图」，这里是它的**单篇视角**：
  // 只筛出指向当前文档的边。数据复用 KnowledgeGraph，不新扫一遍磁盘逻辑。

  /** 打开反向链接面板：先算，再开面板（面板里的列表是静态的，不需要后续刷新）。 */
  private openBacklinks(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      const r: GraphResult = KnowledgeGraph.build(ctx);
      const from: string[] = [];
      for (let k = 0; k < r.edges.length; k++) {
        if (r.edges[k].to === this.docName) {
          from.push(r.edges[k].from);
        }
      }
      this.backlinks = from;
    } catch (err) {
      this.backlinks = [];
    }
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.activeSheet = 'backlinks';
      this.sheetVisible = true;
    });
  }

  /** 点反向链接里的某篇：关面板 → 在新标签打开它。 */
  private openBacklinkDoc(name: string): void {
    this.sheetVisible = false;
    setTimeout(() => {
      this.openInTab(name, '');
    }, 220);
  }

  // ══════════════════════ EPUB 导出（批 5） ══════════════════════

  /** EPUB 导出入口：读正文交给 EpubExport（拉系统另存为）。 */
  private exportEpub(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      const meta: DocMeta | undefined = DocStore.find(ctx, this.docName);
      if (meta === undefined) {
        this.toast(L10n.t('文档不存在'));
        return;
      }
      const content: string = DocStore.readText(ctx, meta, this.docEncoding);
      EpubExport.exportEpub(ctx, this.docName, content, (m: string): void => {
        this.toast(m);
      });
    } catch (err) {
      this.toast('读取失败：' + DocStore.describeError(err as BusinessError));
    }
  }

  /**
   * **面板切换防白屏**：已有其他面板打开时，先收起、动画结束后再换内容打开。
   * 同一帧里换 builder 内容概率白屏（真机实锤：亮度面板开着直接点「更多」）。
   */
  private closeSheetThen(next: string): void {
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.sheetVisible = false;
    });
    setTimeout(() => {
      this.getUIContext().animateTo(this.animateParam(), () => {
        this.activeSheet = next;
        this.sheetVisible = true;
      });
    }, 260);
  }

  private openBright(): void {
    if (this.sheetVisible && this.activeSheet !== 'bright') {
      this.closeSheetThen('bright');
      return;
    }
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.activeSheet = 'bright';
      this.sheetVisible = true;
    });
  }

  private closeBright(): void {
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.sheetVisible = false;
    });
  }

  private openMore(): void {
    if (this.sheetVisible && this.activeSheet !== 'more') {
      this.closeSheetThen('more');
      return;
    }
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.activeSheet = 'more';
      this.sheetVisible = true;
    });
  }

  // ── 自动滚屏 ──

  /** 速度换算：档位 1–10 → 每秒 20–200 vp（上一版 12–120 偏慢，且是硬跳）。 */
  private autoVpPerSec(): number {
    return 20 + (this.autoSpeed - 1) * 20;
  }

  /** 一段动画（segMs 毫秒）应滚过的位移（vp）。 */
  private autoStepPx(segMs: number): number {
    return this.autoVpPerSec() * segMs / 1000;
  }

  /**
   * 开始自动滚屏。
   *
   * **平滑的关键：分段动画接续，而不是定时硬跳。**
   * 上一版是每 100ms 调一次 `scrollBy` —— 位移是一帧到位的瞬移，看着就是一格一格
   * 地顿（用户反馈"卡、想吐"）。现在改成：启动一段 `Linear` 动画滚过一小段距离，
   * 动画结束后立刻接下一段 —— 位移在时间上是连续的，观感就是**匀速滑动**。
   *
   * 段长取 320ms：太短（<150ms）动画引擎来不及起停、接缝处会有微小顿挫；
   * 太长（>600ms）中途暂停会"滑过头"。位移按档位换算，保证任何档位下速度恒定。
   */
  /**
   * 开始自动滚屏（从「更多」面板发起 / 会话起点）：**浮钮一并出现**。
   */
  private startAutoScroll(): void {
    this.stopAutoTimer();
    // 互斥：开始滚动就停掉朗读（两者都在驱动屏幕位置）
    this.stopReadAloud();
    // 暂停浮钮出现的位置：按**当前握姿**定边、屏幕中部（用户要求"屏幕中间位置靠边缘"）。
    // 每次开始都按握姿重算横向位置（纵向只在首次出现时定一次，用户拖过就尊重它）。
    // 另外先问一次系统"最近的操作手"再定边 —— 部分机型不派发换手事件，
    // 只依赖事件回调会出现"换了手还在原来那边"（用户反馈）。
    let side: number = this.gripSide;
    try {
      const recent: number = GripAware.recentSide();
      if (recent !== 0) {
        side = recent;
        this.gripSide = recent;
      }
    } catch (err) {
      // 取不到就用既有值
    }
    this.pauseBtnX = this.sideToX(side, 44);
    if (this.pauseBtnY < 0) {
      this.pauseBtnY = this.rootHeight / 2 - 22;
    }
    this.autoGripTick = 0;
    this.autoBarVisible = true;
    this.autoScrolling = true;
    this.autoScrollSegment();
  }

  /**
   * 握持手 → 贴边横坐标。
   * `side`：-1 左 / 0 未识别 / 1 右；未识别按右手侧处理（与分屏退出钮同一口径）。
   * `btnW` 是浮钮宽度，右侧位置由此反推。
   */
  private sideToX(side: number, btnW: number): number {
    return side === -1 ? 10 : this.rootWidth - btnW - 10;
  }

  /**
   * 滚动期间的握姿兜底核对。
   *
   * 为什么要有它：`motion` 的换手事件在部分机型/场景下不派发（本工程此前就踩过
   * "只挂 holdingHandChanged 导致不跟手"，后来补了 operatingHandChanged 才好），
   * 而自动滚屏这种"手不动、屏在动"的场景恰好最容易漏事件。这里每 5 段（约 1.6s）
   * 主动问一次系统最近的操作手 —— 只在识别出方向（非 0）且与当前不同时才动，
   * 所以不会把按钮误甩到另一边。
   */
  private syncGripSideForAutoScroll(): void {
    let side: number = 0;
    try {
      side = GripAware.recentSide();
    } catch (err) {
      return;
    }
    if (side === 0) {
      return;
    }
    if (side !== this.gripSide) {
      this.gripSide = side;
    }
    if (this.floatBtnVisible()) {
      const targetX: number = this.sideToX(side, 44);
      if (targetX !== this.pauseBtnX) {
        // 与事件路径同一套动画：兜底核对也不该瞬移
        this.getUIContext().animateTo({ duration: 320, curve: Curve.FastOutSlowIn }, () => {
          this.pauseBtnX = targetX;
        });
      }
    }
  }

  /** 一段自动滚动：动画滚过 `段长×速度` 的位移，结束后递归接下一段。 */
  private autoScrollSegment(): void {
    if (!this.autoScrolling) {
      return;
    }
    const segMs: number = 320;
    const px: number = this.autoStepPx(segMs);
    // 到文末就别再排下一段了（否则定时器空转耗电）
    let atEnd: boolean = false;
    try {
      atEnd = this.scroller.isAtEnd();
    } catch (err) {
      atEnd = false;
    }
    if (atEnd) {
      // 到底了：停表但**保留浮钮**（用户可能想回看上一段再继续），图标自动变「继续」
      this.pauseAutoScroll();
      this.toast(L10n.t('已到文末'));
      return;
    }
    try {
      // 用 scrollTo + **显式 Linear 动画**（而不是 animateTo 里 scrollBy）：
      // 位移参数与动画参数写在一次调用里，语义明确、不受动画上下文影响。
      // 目标位移基于当前偏移量，用户中途手动滑动也能自然接下（不会往回跳）。
      const cur = this.scroller.currentOffset();
      this.scroller.scrollTo({
        xOffset: cur.xOffset,
        yOffset: cur.yOffset + px,
        animation: { duration: segMs, curve: Curve.Linear }
      });
    } catch (err) {
      // 列表尚未完成布局等异常：暂停并保留浮钮（点一下「继续」即可重试，
      // 不必再回「更多」面板重新开一次），同时避免定时器空转
      this.pauseAutoScroll();
      return;
    }
    // 握姿兜底核对：搭在滚动节拍上（每 5 段 ≈ 1.6s 一次），不额外开定时器
    this.autoGripTick = this.autoGripTick + 1;
    if (this.autoGripTick % 5 === 0) {
      this.syncGripSideForAutoScroll();
    }
    this.autoTimer = setTimeout(() => {
      this.autoScrollSegment();
    }, segMs);
  }

  private stopAutoTimer(): void {
    if (this.autoTimer >= 0) {
      clearTimeout(this.autoTimer);
      this.autoTimer = -1;
    }
  }

  /**
   * **暂停**：停表但**保留浮钮**——钮上的图标变成「继续」，再点一下接着滚。
   * 用户要求"点击暂停后保留按钮，可再次点击继续"，所以暂停 ≠ 结束会话。
   */
  private pauseAutoScroll(): void {
    this.stopAutoTimer();
    this.autoScrolling = false;
  }

  /** 继续（从暂停态恢复）。必须**先置状态再起第一段**——autoScrollSegment 开头会检查它。 */
  private resumeAutoScroll(): void {
    if (this.autoScrolling) {
      return;
    }
    this.autoGripTick = 0;
    this.autoScrolling = true;
    this.autoScrollSegment();
  }

  /** 浮钮点击：滚动中 → 暂停；已暂停 → 继续。 */
  private toggleAutoScrollPause(): void {
    if (this.autoScrolling) {
      this.pauseAutoScroll();
    } else {
      this.resumeAutoScroll();
    }
  }

  /**
   * **彻底结束**自动滚屏：停表 + 收起浮钮（长按浮钮 / 离开阅读页 / 重新开始时走这里）。
   */
  private stopAutoScroll(): void {
    this.stopAutoTimer();
    this.autoScrolling = false;
    this.autoBarVisible = false;
  }

  /** 改档位：正在滚就按新速度重启计时器。 */
  private onAutoSpeedChange(v: number): void {
    const n: number = Math.round(v);
    this.autoSpeed = n < 1 ? 1 : (n > 10 ? 10 : n);
    if (this.autoScrolling) {
      this.startAutoScroll();
    }
  }

  /** 导出面板：HTML / MD / 分享。 */
  private openExport(): void {
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.activeSheet = 'export';
      this.sheetVisible = true;
    });
  }

  /**
   * 合并导出面板：候选 = 书架全部文档（内置教程也算），预选 = 当前这篇排第一。
   * ⚠️ 面板的 sources/preselect 只在创建那一刻读一次，所以每次打开都要重刷数据
   * 并换纪元重建（分支里用 sheetEpoch % 2 双写，见 currentSheetBody）。
   */
  private openMergeExport(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      DocStore.init(ctx);
      const list: DocMeta[] = DocStore.list(ctx);
      const src: MergeSource[] = [];
      for (let k = 0; k < list.length; k++) {
        src.push({ name: list[k].name, builtin: list[k].builtin === true } as MergeSource);
      }
      const pre: string[] = [];
      for (let k = 0; k < src.length; k++) {
        if (src[k].name === this.docName) {
          pre.push(this.docName);
          break;
        }
      }
      this.mergeSources = src;
      this.mergePreselect = pre;
    } catch (err) {
      this.toast(L10n.t('读取文档清单失败'));
      return;
    }
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.sheetEpoch++;
      this.activeSheet = 'merge';
      this.sheetVisible = true;
    });
  }

  /**
   * 收起面板：**只关显隐，不清内容**（activeSheet 留给 onDismiss 清理）。
   * 之前在这里把 activeSheet 清成 ''——dismiss 过程中 currentSheet() 渲染成空，
   * 用户看到的就是一块白色空面板卡在屏幕上（真机踩过）。
   */
  private closeMore(): void {
    this.sheetVisible = false;
  }

  /** 主题小芯片（亮度面板用；阅读设置面板有自己的一份）。 */
  @Builder
  themeChip(mode: number, label: string) {
    Text(label)
      .fontSize(HwType.label)
      .fontWeight(this.themeMode === mode ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.themeMode === mode ? this.palette().accent : this.palette().textPrimary)
      .textAlign(TextAlign.Center)
      // **必须 layoutWeight 均分**：写 width('100%') 时每个芯片都想占满整行，
      // 三个并排直接顶出屏幕、点不到（用户反馈）
      .layoutWeight(1)
      .height(36)
      .borderRadius(HwRadius.inner)
      .backgroundColor(this.themeMode === mode ? this.palette().accentSoft : this.palette().quoteBg)
      .onClick(() => {
        this.themeMode = mode;
      })
  }

  // ══════════════════════ 目录抽屉 ══════════════════════

  @Builder
  tocDrawer(closable: boolean) {
    Column() {
      ImmersiveSheetPanel({
        palette: this.palette(),
        panelRadius: HwRadius.sheet,
        panelPadding: HwSpace.md,
        panelHeight: '100%',
        panelScrollable: false,
        // 关闭沉浸光感时（「更多」里的开关）：底色用阅读背景色
        panelPlainColor: this.readerBgColor()
      }) {
        Column({ space: HwSpace.md }) {
          Row({ space: HwSpace.sm }) {
            Column({ space: 2 }) {
              Text(L10n.t('目录'))
                .fontSize(HwType.label + 3)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.palette().textPrimary)
              Text(this.docOutline.length + ' 个标题 · ' + this.docWordCount + ' 字')
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // 导出 HTML：任意文档（含内置教程）都能导出
            if (closable) {
              ImmersiveIconButton({
                buttonSize: 32,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.closePinned('toc');
                }
              }) {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(15)
                  .fontColor([this.palette().textPrimary])
              }
            }
            ImmersiveIconButton({
              buttonSize: 32,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.exportHtml();
              }
            }) {
              SymbolGlyph($r('sys.symbol.doc_plaintext'))
                .fontSize(15)
                .fontColor([this.palette().textSecondary])
            }

            // 编辑入口：**只读才不给**（用户要求：可写＝能编辑，内置教程切成可写后同样能编辑）。
            // 想让它出现，先在「更多」面板里把这篇切成「可写」。
            if (!this.docReadOnly) {
              ImmersiveIconButton({
                buttonSize: 32,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.openEditorFromBar();
                }
              }) {
                SymbolGlyph($r('sys.symbol.highlighter_line'))
                  .fontSize(15)
                  .fontColor([this.palette().accent])
              }
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 大纲折叠控制（移植自参考项目的「分级展开折叠 + 全部展开/折叠」）
          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: L10n.t('展开全部'),
              chipOnTap: () => {
                this.setAllCollapsed(false);
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: L10n.t('折叠到二级'),
              chipOnTap: () => {
                this.setAllCollapsed(true);
              }
            })
          }
          .width('100%')

          // ── 大纲滚动区：头部固定，只有这里滚动。折叠/展开带动画 ──
          // 挂 tocScroller：打开目录 / 章节变化时自动滚到当前所在的那一节
          Scroll(this.tocScroller) {
            if (this.docOutline.length === 0) {
              Text(L10n.t('这份文档没有标题，无法生成目录。'))
                .fontSize(HwType.label)
                .fontColor(this.palette().textTertiary)
                .width('100%')
                .padding({ top: HwSpace.lg })
            } else {
              Column() {
                ForEach(this.visibleOutline(), (item: MdHeading) => {
                  Row({ space: HwSpace.xs }) {
                    if (this.hasChildren(item.seq)) {
                      SymbolGlyph(this.isCollapsed(item.seq)
                        ? $r('sys.symbol.chevron_right')
                        : $r('sys.symbol.chevron_down'))
                        .fontSize(12)
                        .fontColor([this.palette().textTertiary])
                        .onClick(() => {
                          this.toggleCollapse(item.seq);
                        })
                    } else {
                      Column()
                        .width(12)
                    }
                    Column()
                      .width(3)
                      .height(15)
                      .borderRadius(2)
                      .backgroundColor(this.activeHeading === item.text
                        ? this.palette().accent
                        : this.palette().divider)
                    Text(item.text)
                      .fontSize(item.level <= 2 ? HwType.label + 1 : HwType.label)
                      .fontWeight(item.level <= 2 ? FontWeight.Medium : FontWeight.Normal)
                      .fontColor(this.activeHeading === item.text
                        ? this.palette().accent
                        : (item.level <= 2 ? this.palette().textPrimary : this.palette().textSecondary))
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Text('H' + item.level)
                      .fontSize(HwType.caption - 1)
                      .fontColor(this.palette().textTertiary)
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)
                  .padding({
                    left: HwSpace.xs + (item.level - 1) * 12,
                    right: HwSpace.xs,
                    top: HwSpace.sm,
                    bottom: HwSpace.sm
                  })
                  .borderRadius(HwRadius.inline)
                  .backgroundColor(this.activeHeading === item.text ? this.palette().accentSoft : '#00000000')
                  .onClick(() => {
                    this.jumpTo(item.blockIndex);
                  })
                  // 记录本行的纵向位置：目录要按它自动滚到"当前所在的一节"
                  .onAreaChange((oldValue: Area, newValue: Area) => {
                    this.rememberTocRow(item.text, newValue);
                  })
                  // 稳定 key（seq 唯一）+ transition：展开时新行淡入、收起时被移除行淡出，
                  // 存活行的位移由 animateTo 带动，整体呈现折叠动画
                  .transition({ opacity: 0, translate: { y: -6 } })
                }, (item: MdHeading) => 'h' + item.seq)
              }
              .width('100%')
            }
          }
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .layoutWeight(1)
          .align(Alignment.Top)
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width(this.drawerWidth())
    .height('100%')
    // 抽屉是全屏 Stack 的一部分，铺到了状态栏 / 手势条底下；
    // 内容必须内缩到安全区以内，否则标题「目录 / 注释」会被状态栏压住
    .padding({
      top: this.padTop() + HwSpace.xs,
      bottom: this.padBottom() + HwSpace.xs,
      left: HwSpace.sm,
      right: HwSpace.sm
    })
  }

  // ══════════════════════ 注释抽屉 ══════════════════════

  @Builder
  notesDrawer(closable: boolean) {
    Column() {
      ImmersiveSheetPanel({
        palette: this.palette(),
        panelRadius: HwRadius.sheet,
        panelPadding: HwSpace.md,
        panelHeight: '100%',
        // **面板自身不滚动**：标题 / 搜索 / 分类筛选要**固定**，只有下方批注列表滚
        //（用户反馈：整块一起滚，想搜索或换分类得先滑回顶部，太麻烦）
        panelScrollable: false,
        panelPlainColor: this.readerBgColor()
      }) {
        Column({ space: HwSpace.sm }) {
          // ── 固定区 1：标题 + 搜索钮 / 关闭钮 ──
          Row({ space: HwSpace.sm }) {
            Column({ space: 2 }) {
              Text(L10n.t('注释与批注'))
                .fontSize(HwType.label + 3)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.palette().textPrimary)
              Text(this.annotations.length + ' 条批注 · ' + this.notes.length + ' 条脚注')
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // 搜索钮（展开 / 收起搜索条，带过渡动画）
            ImmersiveIconButton({
              buttonSize: 30,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.toggleNotesSearch();
              }
            }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(13)
                .fontColor([this.notesSearchOpen ? this.palette().accent : this.palette().textPrimary])
            }

            if (closable) {
              ImmersiveIconButton({
                buttonSize: 30,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.closePinned('notes');
                }
              }) {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(13)
                  .fontColor([this.palette().textPrimary])
              }
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)

          // ── 固定区 2：搜索条（展开 / 收起走动画：透明度 + 上移）──
          if (this.notesSearchOpen) {
            Row({ space: HwSpace.xs }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(14)
                .fontColor([this.palette().textTertiary])
              TextInput({ text: this.notesQuery, placeholder: L10n.t('搜索批注内容 / 备注 / 分类…') })
                .id('notesSearchInput')
                .layoutWeight(1)
                .height('100%')
                .fontSize(HwType.label)
                .fontColor(this.palette().textPrimary)
                .placeholderColor(this.palette().textTertiary)
                .backgroundColor('#00000000')
                .padding({ left: 0, right: 0, top: 0, bottom: 0 })
                .maxLines(1)
                .defaultFocus(true)
                .onChange((v: string) => {
                  // 筛选变化包动画：列表高度随之平滑变化，不跳变
                  this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
                    this.notesQuery = v;
                  });
                })
              if (this.notesQuery.length > 0) {
                ImmersiveIconButton({
                  buttonSize: 26,
                  buttonMaterialShadow: false,
                  palette: this.palette(),
                  buttonOnTap: () => {
                    this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
                      this.notesQuery = '';
                    });
                  }
                }) {
                  SymbolGlyph($r('sys.symbol.xmark'))
                    .fontSize(13)
                    .fontColor([this.palette().textTertiary])
                }
              }
            }
            .width('100%')
            .height(38)
            .padding({ left: HwSpace.sm, right: HwSpace.xs })
            .borderRadius(HwRadius.pill)
            .backgroundColor(this.palette().quoteBg)
            // 展开 / 收起：显式 TransitionEffect（自带时长，不依赖 animateTo）
            .transition(TransitionEffect.OPACITY
              .animation({ duration: 220, curve: Curve.FastOutSlowIn })
              .combine(TransitionEffect.translate({ y: -8 })))
          }

          // ── 固定区 3：我的批注标题 + 分类筛选（**不随列表滚动**）──
          if (this.annotations.length > 0) {
            Text(L10n.t('我的批注'))
              .fontSize(HwType.label)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.palette().textSecondary)
              .width('100%')
              .padding({ top: HwSpace.xs })

            // 分类筛选（用户要求：按批注形态分类，带文字提示与数量）。
            // ⚠️ **只出现当前存在的种类**；横向滑动一行排开，不换行不挤压。
            Scroll() {
              Row({ space: HwSpace.xs }) {
                this.kindChip('全部 ' + this.annotations.length, '', this.annotations.length)
                ForEach(this.availableKinds(), (kind: string) => {
                  this.kindChip(kind + ' · ' + this.kindCount(kind), kind,
                    this.kindCount(kind))
                }, (kind: string) => 'kf_' + kind)
              }
              .padding({ left: 2, right: 2, top: 2, bottom: 2 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
            .align(Alignment.Start)
          }

          // ── 滚动区：批注列表 + 脚注列表（只有这里随内容滚动）──
          Scroll() {
            Column({ space: HwSpace.sm }) {
              if (this.searchedAnnotations().length === 0 && this.annotations.length > 0) {
                Text(this.notesQuery.trim().length > 0
                  ? L10n.t('没有匹配「') + this.notesQuery.trim() + '」的批注'
                  : L10n.t('当前分类下没有批注'))
                  .fontSize(HwType.label)
                  .fontColor(this.palette().textTertiary)
                  .width('100%')
                  .padding({ top: HwSpace.md, bottom: HwSpace.md })
                  .textAlign(TextAlign.Center)
              }

              ForEach(this.searchedAnnotations(), (ann: MdAnnotation) => {
                Column({ space: HwSpace.xs }) {
                  Row({ space: HwSpace.xs }) {
                    // **形态分类文字提示**（学习卡 / 文字批注 / 荧光笔 / 波浪线 / 手写批注）
                    Text(this.annoKindLabel(ann))
                      .fontSize(HwType.caption - 1)
                      .fontColor(this.palette().accent)
                      .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                      .borderRadius(HwRadius.pill)
                      .backgroundColor(this.palette().quoteBg)
                    if (ann.color >= 0) {
                      Column()
                        .width(10)
                        .height(10)
                        .borderRadius(5)
                        .backgroundColor(annotationColor(ann.color, this.isDark()))
                    } else {
                      SymbolGlyph($r('sys.symbol.textformat'))
                        .fontSize(12)
                        .fontColor([this.palette().textTertiary])
                    }
                    Text(L10n.t('第 ') + (this.blockIndexOf(ann.blockId) + 1) + ' 段')
                      .fontSize(HwType.caption)
                      .fontColor(this.palette().textTertiary)
                      .layoutWeight(1)
                    // **手写批注：查看手写图**（点开进放大浮层，可缩放 / 旋转）
                    if (ann.note.startsWith('hw:')) {
                      ImmersiveChip({
                        palette: this.palette(),
                        chipLabel: L10n.t('查看'),
                        chipOnTap: () => {
                          this.openHandwriteAnno(ann);
                        }
                      })
                    }
                    ImmersiveChip({
                      palette: this.palette(),
                      chipTint: '#FFD32F2F',
                      chipActive: true,
                      chipLabel: L10n.t('删除'),
                      chipOnTap: () => {
                        // **包在 animateTo 里**：卡片淡出（transition），其余卡片滑动补位
                        this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
                          this.deleteAnnotation(ann);
                        });
                      }
                    })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)

                  // **批注原文渲染公式**（用户要求"注释与批注加上渲染效果"）：
                  // 公式学习卡 / 公式批注的原文与正文公式同键（同字号同深浅）→ 缓存直出；
                  // generate=false 只吃缓存，由抽屉的共用池统一出图（不逐条挂 Web）
                  MathFormulaText({
                    src: ann.text,
                    dark: this.isDark(),
                    fontSize: this.fontSize,
                    color: this.palette().textPrimary,
                    generate: false
                  })

                  if (ann.note.length > 0) {
                    if (ann.note.startsWith('hw:')) {
                      Text(L10n.t('手写批注（点「查看」看手写图）'))
                        .fontSize(HwType.caption)
                        .fontColor(this.palette().textSecondary)
                        .lineHeight(HwType.caption * 1.6)
                        .width('100%')
                    } else {
                      // **备注渲染公式**（用户在备注里写的 $…$ 由抽屉共用池出图）
                      MathFormulaText({
                        src: ann.note,
                        dark: this.isDark(),
                        fontSize: this.fontSize,
                        color: this.palette().textSecondary,
                        lineMul: 1.6,
                        generate: false
                      })
                    }
                  }
                }
                .width('100%')
                .padding(HwSpace.sm)
                .borderRadius(HwRadius.inner)
                // **不透明卡片**（半透明看不清底下正文）——按深浅给实色
                .backgroundColor(this.isDark() ? '#FF2B2F38' : '#FFF6F3EC')
                .border({
                  width: { left: 3 },
                  color: { left: ann.color >= 0 ? annotationColor(ann.color, this.isDark()) : this.palette().divider }
                })
                .onClick(() => {
                  this.jumpToBlockId(ann.blockId);
                })
                // **删除 / 筛选淡出**（配 animateTo 的数组变更，其余卡片滑动补位）
                .transition(TransitionEffect.OPACITY.animation({ duration: 240, curve: Curve.FastOutSlowIn }))
              }, (ann: MdAnnotation) => 'ann_' + ann.id + '_t' + this.drawerFormulaTick)

              Text(L10n.t('脚注'))
                .fontSize(HwType.label)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.palette().textSecondary)
                .width('100%')
                .padding({ top: HwSpace.xs })

              if (this.notes.length === 0) {
                Text(L10n.t('在正文里用 [^标签] 引用、用 [^标签]: 内容 定义，注释就会出现在这里。语法教程第 10 节有示例。'))
                  .fontSize(HwType.label)
                  .fontColor(this.palette().textTertiary)
                  .lineHeight(HwType.label * 1.7)
                  .width('100%')
              } else if (this.searchedNotes().length === 0) {
                Text(L10n.t('没有匹配「') + this.notesQuery.trim() + '」的脚注')
                  .fontSize(HwType.label)
                  .fontColor(this.palette().textTertiary)
                  .width('100%')
                  .padding({ top: HwSpace.sm })
              } else {
                ForEach(this.searchedNotes(), (note: MdNote) => {
                  Column({ space: HwSpace.xs }) {
                    Row({ space: HwSpace.xs }) {
                      Text('[' + note.no + ']')
                        .fontSize(HwType.caption)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.palette().accent)
                      Text(note.label)
                        .fontSize(HwType.caption)
                        .fontColor(this.palette().textTertiary)
                        .layoutWeight(1)
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center)

                    // **脚注内容渲染公式**（同批注：吃全局缓存，共用池出图）
                    MathFormulaText({
                      src: note.text,
                      dark: this.isDark(),
                      fontSize: this.fontSize,
                      color: this.palette().textSecondary,
                      lineMul: 1.7,
                      generate: false
                    })
                  }
                  .width('100%')
                  .padding(HwSpace.sm)
                  .borderRadius(HwRadius.inner)
                  .backgroundColor(this.palette().quoteBg)
                  .border({ width: { left: 3 }, color: { left: this.palette().accent } })
                  .onClick(() => {
                    this.jumpTo(note.blockIndex);
                  })
                  .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.FastOutSlowIn }))
                }, (note: MdNote, index: number) => 'n' + index + '_' + note.no)
              }

              // 底部留白：最后一张卡片不贴到面板底边
              Column().width('100%').height(HwSpace.md)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)

        // **抽屉共用公式池**（1×1 隐形）：批注原文 / 备注 / 脚注里的 $公式$
        // 由这一个池出图（抽屉项 generate=false 只吃缓存）；关 MathJax 时任务为空不挂
        if (this.drawerFormulaTasks.length > 0) {
          InlineFormulaPool({
            tasks: this.drawerFormulaTasks,
            dark: this.isDark(),
            onOneDone: () => {
              this.drawerFormulaTick++;
            }
          })
        }
      }
    }
    .width(this.drawerWidth())
    .height('100%')
    .padding({
      top: this.padTop() + HwSpace.xs,
      bottom: this.padBottom() + HwSpace.xs,
      left: HwSpace.sm,
      right: HwSpace.sm
    })
  }

  // ══════════════════════ 页面过渡 ══════════════════════

  /**
   * 图片一镜到底：点正文图片 → 全屏大图。
   * 与正文那张图共享同一个 geometry id，所以系统会把「这一张小图」无缝拉成全屏，
   * 关闭时再沿原路返回（无需自己算矩形）。
   */
  private openZoomImage(key: string, src: string): void {
    if (src.length === 0) {
      return;
    }
    this.zoomImgKey = key;
    this.zoomImgSrc = src;
    AppStorage.setOrCreate('readerOverlayOpen', true);
    this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
      this.zoomImgOpen = true;
    });
  }

  private closeZoomImage(): void {
    AppStorage.setOrCreate('readerOverlayOpen', false);
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.zoomImgOpen = false;
    });
    // 关闭过渡结束后清掉内容（避免下一次打开先闪上一张）
    setTimeout(() => {
      if (!this.zoomImgOpen) {
        this.zoomImgKey = '';
        this.zoomImgSrc = '';
      }
    }, 300);
    // **对照面板恢复**：从对照面板点开的图片浮层，关闭后把面板拉回来（同 closeOverlays）
    if (this.compareSheetWasOpen) {
      this.compareSheetWasOpen = false;
      this.activeSheet = 'compare';
      this.sheetVisible = true;
    }
  }

  /**
   * 工具栏「编辑」：直接进编辑页快速改这篇 md。
   * **判据只看「只读」标记**（用户要求：可写就是能编辑、只读才不给编辑）——
   * 之前这里按 docBuiltin 挡掉内置教程，即使把它切成「可写」也进不去编辑页。
   */
  private openEditorFromBar(): void {
    if (this.docReadOnly) {
      this.toast(L10n.t('该文档是只读的，先在「更多」里切成「可写」'));
      return;
    }
    if (this.stack === null || this.docName.length === 0) {
      return;
    }
    this.flushProgress();
    const route: ReaderRoute = { name: this.docName };
    try {
      this.stack.pushPath({ name: 'pages/Editor', param: route });
    } catch (err) {
      this.toast(L10n.t('打不开编辑页'));
    }
  }

  /** 打开这篇文档的起点 X（书架里文件格的窗口坐标；没有就取屏幕中心）。 */
  private openOriginX(): number {
    const v: number | undefined = AppStorage.get<number>('openOriginX');
    return v !== undefined && v > 0 ? v : this.rootWidth / 2;
  }

  /**
   * 智感握姿的水平偏移。
   *
   * 胶囊**默认就停在右下角**（= 右手位），所以：
   *   · 右手 / 未识别 / 工具条展开 → 偏移 0，保持右下角不动
   *   · **左手** → 整条平移到左下角（位移 = 可用宽 - 胶囊宽）
   * 这样「右手不用动、左手自动靠过来」，与用户实际操作习惯一致。
   */
  private gripOffset(): number {
    if (this.bottomBarVisible || this.gripSide !== -1) {
      return 0;
    }
    const avail: number = this.rootWidth - (HwSpace.lg + this.barInsetLeft())
      - (HwSpace.lg + this.barInsetRight());
    // 用收起态胶囊实际宽度代替固定 HwBar.miniBottom：
    // 底部有标签时胶囊比 miniBottom 宽，写死 96 会导致整体偏移过大，
    // 胶囊左侧（百分比区域）跑出屏幕。
    const capsuleW: number = this.bottomBarMiniWidth();
    return -(avail - capsuleW);
  }

  /**
   * 返回书架。几何动画由书架的封面层「一镜到底」承担（见 Index.onPageShow），
   * 所以这里不需要再动材质开关——页面只是淡出。
   */
  private backToShelf(): void {
    // 直接走一镜到底退场（heroExit 自己带缩回动画与 onFinish 返回）
    this.heroExit();
  }

  private openOriginY(): number {
    const v: number | undefined = AppStorage.get<number>('openOriginY');
    return v !== undefined && v > 0 ? v : this.rootHeight / 2;
  }

  /**
  /** 页面瞬切：一镜到底由 hero 几何动画承担（见 heroEnter / heroExit）。 */
  /** 页面本身不做转场动画：一镜到底由 heroEnter/heroExit 的几何动画承担，
   *  pageTransition 只声明时长以免与它抢时序。 */
  /** 页面瞬切：一镜到底的动画由 hero 几何（从封面矩形展开/缩回）承担，
   *  页面转场再叠动画会与它抢时序，所以这里只做瞬时交接。 */
  /** 页面淡入淡出：一镜到底由 hero 几何动画承担；淡变是保底与柔化，
   *  确保任何情况下都不会出现「无动画硬切」。 */
  pageTransition() {
    PageTransitionEnter({ type: RouteType.None, duration: 300, curve: Curve.FastOutSlowIn })
      .opacity(0)
    PageTransitionExit({ type: RouteType.None, duration: 300, curve: Curve.FastOutSlowIn })
      .opacity(0)
  }


  build() {
    Stack({ alignContent: Alignment.TopStart }) {

      // 背景层：一镜到底展开时从透明渐显（缩回时渐隐，露出下层书架封面）
      Column() {
        this.backdrop()
      }
      .width('100%')
      .height('100%')
      .opacity(this.heroBg)
      .hitTestBehavior(HitTestMode.None)

      // 图表后台预渲染池：打开文件即把公式 / 图表逐个渲染成 PNG 写缓存
      //（完成后 renderEpoch++ 让正文把 DiagramWeb 占位换成缓存图）。
      // 放在背景层之上、内容层之下；视觉透明、不吃触摸。
      ChartRenderPool({
        tasks: this.chartTasks,
        dark: this.isDark(),
        // 快照防黑底：webPageSnapshot 不含 alpha，透明会合成成黑——渲染时铺卡片底色。
        // ⚠️ 必须取**不透明版**（palette 原始值带 55% 透明度，Web 里会再合成出偏色底）
        cardBg: withAlpha(this.palette().codeBlockBg, 'FF'),
        // 烘焙宽度 = 正文栏宽（去掉左右内边距）。必须给：不给就由"组件当时多宽"
        // 决定排版，转场那几百毫秒里烘出来的图会挤成窄条（见 ChartRenderPool.hostWidth）
        hostWidth: this.rootWidth - HwSpace.lg * 2,
        // 导出 / 打印前的失败重试信号（见 ChartRenderPool.retryTick）
        retryTick: this.poolRetryTick,
        onOneDone: () => {
          // 只递增**图表就绪信号**：仅图表 / 公式条目重建（换成缓存图），
          // 正文其它条目不受影响 —— 避免整树重建造成的闪烁
          this.chartReadyTick++;
        }
      })

      // 行内公式图生成池（MathJax → SVG → PNG）：挂点 1×1 隐形，不占视觉；
      // 每完成一张回调 → chartReadyTick++ → 含该公式的段落重建、换成图
      InlineFormulaPool({
        tasks: this.formulaTasks,
        dark: this.isDark(),
        onOneDone: () => {
          this.chartReadyTick++;
        }
      })

      // **下载的独立渲染表面**（用户要求：下载时不截屏幕上那块）：
      // 放大浮层点「下载」→ 挂载这块表面（浅色白底 + 内容自然尺寸 + 不被裁剪），
      // 尺寸稳定后整页快照 → 裁边 → 另存 PNG。用完即卸（dlJob 清空即卸载）。
      // ⚠️ 必须挂在**根 Stack 这一层**：它比屏幕可能更高（长图）、也可能更宽，
      //    外面任何 `.clip(true)` 或固定高容器都会把整张图裁掉（v1~v4 的坑）。
      if (this.dlJob !== null) {
        DiagramDownloadHost({
          job: this.dlJob,
          onDone: (pixel: image.PixelMap, w: number, h: number) => {
            this.onDlDone(pixel, w, h);
          },
          onFail: (reason: string) => {
            this.onDlFail(reason);
          }
        })
      }

      // ── 正文：铺满整屏。顶栏、标签栏、工具条全部悬浮在文字上方，
      //    滚动时文字从两条悬浮栏底下穿过（磨砂/材质透出文字）。
      //    顶栏收起时顶部内边距动画收缩，正文向上扩充占满让出的空间。──
      // 主体内容层：一镜到底从书架封面矩形缩放展开 / 缩回（官方 BookFlip 几何算法）
      Column() {
          Row() {
            // 大屏/横屏：目录停靠左侧（宽度可拖分隔条调节）
            if (this.isWide() && this.tocPinned) {
              Column() {
                this.tocDrawer(true)
              }
              .width(this.tocPanelWidth)
              .height('100%')
              .margin({ left: HwSpace.xs })
              // **分隔条黑线已移除**（用户实测：拖拽热区与侧滑手势竞争导致
              // 侧滑滑出不完全），调宽功能一并移除
            }
          List({ scroller: this.scroller, space: 0, initialIndex: this.listInitialIndex }) {
            // 首屏间隙做成**随内容滚动的占位条目**，而不是 List 的 padding。
            // List 的 padding 是内容裁剪边界：顶部留 padding 的话，正文永远画不进胶囊底下，
            // 悬浮栏下面就是一条死白——这正是「顶栏侵占界面」的观感来源。
            // 用占位条目则既保证第一屏与顶栏有间隙，滚动后正文又能从胶囊底下穿过。
            ListItem() {
              Column()
                .layoutWeight(1)
                .height(this.topSpacerHeight())
            }

            if (this.showMetaCard) {
              ListItem() {
                this.docMetaCard()
              }
            }

            // **只渲染已加载的块**：`.slice` 返回新数组，key 不变时已渲染的块被复用，
            // 新增的一批才会创建组件（不会整列重建）。
            ForEach(this.blocks.slice(0, this.visibleBlocks), (block: MdBlock) => {
              ListItem() {
                MdBlockView({
                  block: block,
                  palette: this.palette(),
                  bodySize: this.fontSize,
                  lineMul: this.lineMul,
                  // 首行缩进以属性管道下发（子组件内部读 AppStorage 不保证回刷）
                  indentOn: this.indentOn,
                  dark: this.isDark(),
                  annotations: this.annotations,
                  searchQuery: this.searchQuery,
                  systemSelectId: this.systemSelectBlock,
                  sysSelectExit: (blockId: string) => {
                    if (this.systemSelectBlock === blockId) {
                      this.systemSelectBlock = '';
                      // 退出即重置胶囊位置（下次进入恢复初始贴边）
                      this.sysTabX = -1;
                      this.sysTabY = -1;
                    }
                  },
                  sysSelectEnter: (blockId: string) => {
                    this.systemSelectBlock = blockId;
                  },
                  annotateHandler: (action: string, blockId: string, start: number,
                                    end: number, text: string, color: number) => {
                    this.onAnnotate(action, blockId, start, end, text, color);
                  },
                  anchorHandler: (href: string) => {
                    this.jumpToAnchor(href);
                  },
                    docLinkHandler: (href: string) => {
                      this.openDocLink(href);
                    },
                    // 网页开放（用户要求）：开关开启时点 http(s) 链接走半模态面板
                    webOpen: this.webOpen,
                    webLinkHandler: (href: string) => {
                      this.openWebSheet(href);
                    },
                    taskToggleHandler: (blockId: string) => {
                      this.onTaskToggle(blockId);
                    },
                    taskLineHandler: (blockId: string, lineNo: number) => {
                      this.onTaskLineToggle(blockId, lineNo);
                    },
                    tableEditHandler: (blockId: string) => {
                      this.openTableEdit(blockId);
                    },
                    enlargeHandler: (mode: string, payload: string, geoKey: string, title: string) => {
                      this.openEnlarge(mode, payload, geoKey, title);
                    },
                    webTouchHandler: (down: boolean) => {
                      this.webTouchDepth = Math.max(0, this.webTouchDepth + (down ? 1 : -1));
                    },
                    imageTapHandler: (key: string, src: string) => {
                      this.openZoomImage(key, src);
                    },
                    aiAskHandler: (text: string) => {
                      // 长按选择条「发送AI」（1.2.0）：带选中文本 + 当前文档进入 AI 对话
                      this.openAiChat(text);
                    }
                })
              }
              }, (block: MdBlock) => {
                // **图表 / 公式条目**：key 用「内容哈希 + **该块自身缓存是否就绪**」。
                // 就绪的条目切到缓存图、未就绪的保持占位——只有真正变化的那一个
                // 会重建，其余 Web 实例被复用，不再反复重新加载（用户反馈：闪来闪去）。
                // 注意 key 里**不能**放 chartReadyTick：那会让所有图表条目一起变。
                if (block.kind === MdBlockKind.Chart || block.kind === MdBlockKind.Math) {
                  // 读取图表就绪信号以**建立依赖**（它变化 → key 重算 → 就绪的条目
                  // 才切换成缓存图），但信号本身不进 key（否则所有图表条目一起变）
                  const tick: number = this.chartReadyTick;
                  const mode: string = block.kind === MdBlockKind.Math
                    ? 'katex' : block.lang.trim().toLowerCase();
                  const ck: string = ChartCache.keyFor(mode, block.code, this.isDark(),
                    withAlpha(this.palette().codeBlockBg, 'FF'));
                  const c: common.UIAbilityContext | null = this.ctx();
                  const ready: boolean =
                    c !== null && ChartCache.path(c, ck).length > 0;
                  return block.id + '_' + this.docName + '_' + ck
                    + (tick >= 0 ? (ready ? '_r' : '_p') : '_p')
                    // 引擎开关（设置 → 引擎管理）变化 → 图表/公式条目也要重建成源码卡
                    //（完整列表进 key：开关组合不同就必然不同，避免"关 A 开 B"长度撞车）
                    + '_e' + this.disabledEngineList;
                }
                // 含行内公式的段落：key 追加"公式图就绪数"——图就绪后本段重建，
                // 线性化文本才会换成公式图（见 inlineReadySuffix 注释）
                return block.id + '_' + this.docName + '_' + this.renderEpoch
                  + this.inlineReadySuffix(block)
                  // 单块就地刷新（勾选任务等）：只有这一块的 key 变，别的一律复用
                  + this.blockRevSuffix(block.id);
              })

            // **懒渲染的「继续加载」入口**（大文件分批渲染）。
            // ⚠️ 不能用 ListItem 的 onAppear 自动追加：ForEach 不是懒加载，所有
            // ListItem 一创建 onAppear 就全部触发 —— 用户实测表现为"一直显示加载中
            // 却加载不出来"（还可能反复触发）。改成**点一下加载一批**，行为确定。
            if (this.blocks.length > this.visibleBlocks) {
              ListItem() {
                Row() {
                  Text(L10n.t('正在加载更多…（已显示 ') + this.visibleBlocks + ' / ' + this.blocks.length + ' 块）')
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textTertiary)
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: HwSpace.md, bottom: HwSpace.md })
              }
              // **滚动到就自动加载**（用户要求：不要手动点，否则体验割裂）。
              // 用 onVisibleAreaChange 而不是 ListItem.onAppear —— ForEach 不是懒加载，
              // onAppear 会在条目创建时全部触发（此前"一直加载中"就是这个原因）；
              // 可见比例回调只在**真的滚到这里**时触发，语义正确且可靠。
              .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean) => {
                if (isVisible) {
                  this.visibleBlocks = Math.min(this.blocks.length, this.visibleBlocks + 60);
                }
              })
            }

            ListItem() {
              Text(L10n.t('—— 文档结束 ——'))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
                .width('100%')
                .textAlign(TextAlign.Center)
                // 文末留白放在条目自身：让最后一段能滚到悬浮工具条上方，而不是被裁在 List 的 padding 外。
                // 底栏胶囊顶边距屏底 = padBottom + 4 + HwBar.pill(52)，留白再多给一段呼吸距离，
                // 滚到底后最后几行整体抬到胶囊上方
                .padding({ top: HwSpace.xl, bottom: this.padBottom() + HwBar.pill + 72 })
            }
          }
          // 有停靠列时占剩余宽度：目录/注释靠边，正文居中
          .layoutWeight(1)
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          // **List 的 padding 是内容裁剪边界**——底部不能留 padding，否则工具条底下
          // 永远是一条空白，文字画不进去；文末留白放到最后一个 ListItem 自己的 padding 里。
          // 顶部 padding 必须为 0（首屏间隙由上面的占位条目承担），正文才能画进胶囊底下。
          .padding({ left: HwSpace.lg, right: HwSpace.lg })
          .onScrollIndex((start: number, end: number, center: number) => {
            this.onListScroll(start, end, center);
          })
          // 每帧滚动位移驱动顶栏收起与展开（累计阈值，见 onScrollFrame）
          .onDidScroll((offset: number, state: ScrollState) => {
            this.onScrollFrame(offset);
          })
          .onScrollStop(() => {
            this.flushProgress();
          })
          // 自动滚屏时**点正文任意处即暂停**：比再去找按钮快得多。
          // 只暂停、不结束：浮钮留着变成「继续」，随时接着看。
          // 只在滚动中生效，其余时候这个点击什么都不做。
          .onClick(() => {
            if (this.autoScrolling) {
              this.pauseAutoScroll();
            }
          })
          // **主题纪元也拼在 List 容器上**（关键修复）：
          // 只改条目的 key 不够——已挂载的 ListItem / 其中的按钮是由列表**复用**的，
          // 换容器的 key 才会把整段正文真正重建一遍（用户反馈：正文前段、部分按钮
          // 切换深浅后不变色，就是因为它们是被复用的那一批）。
          .key('readerBody_' + this.themeEpoch + '_l' + this.languageTick)

          // 大屏/横屏：注释停靠右侧（正文列与目录列之间），宽度同样可调
          if (this.isWide() && this.notesPinned) {
            Column() {
              this.notesDrawer(true)
            }
            .width(this.notesPanelWidth)
            .height('100%')
            .margin({ right: HwSpace.xs })
          }

          // ── 对照列（分屏对照，批 5）：右半屏渲染第二篇文档（只读）──
          // 与正文 List 平级的 layoutWeight 兄弟 → 五五开；退出 = 屏幕侧缘中部浮钮（随握姿）。
          if (this.compareSplit) {
            Column({ space: HwSpace.xs }) {
              Row({ space: HwSpace.xs }) {
                Text(L10n.t('对照 · 《') + this.compareDoc + '》')
                  .fontSize(HwType.caption)
                  .fontColor(this.palette().textSecondary)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Scroll() {
                Column({ space: HwSpace.sm }) {
                  ForEach(this.compareBlocks, (b: MdBlock) => {
                    MdBlockView({
                      block: b,
                      palette: this.palette(),
                      // 分屏列窄，正文用小一号字
                      bodySize: Math.max(HwType.bodyMin, this.fontSize - 2),
                      lineMul: this.lineMul,
                      dark: this.isDark(),
                      // 分屏列的放大同样 **geoKey 传空**（与正文同 id 元素共存会让
                      // 一镜到底错乱，见对照面板同名注释）
                      enlargeHandler: (mode: string, payload: string, geoKey: string, title: string) => {
                        this.openEnlarge(mode, payload, '', title);
                      },
                      imageTapHandler: (key: string, src: string) => {
                        this.openZoomImage(key, src);
                      }
                    })
                  }, (b: MdBlock) => 'split_' + this.compareEpoch + '_' + b.id)
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
              }
              .align(Alignment.Top)
              .scrollBar(BarState.Off)
              .width('100%')
              .layoutWeight(1)
            }
            .layoutWeight(1)
            .height('100%')
            // 顶/底避让：顶部让开顶栏胶囊；**底部直通屏幕底**（用户要求显示区域到屏底、顶部不动）
            .padding({ top: this.padTop() + HwBar.pill + 6, bottom: 0 })
            .border({ width: { left: 1 }, color: this.palette().divider })
            // 打开从右侧滑入、退出向右滑出（用户要求出入都有动画）
            .transition(TransitionEffect.asymmetric(
              TransitionEffect.translate({ x: 80 }).combine(TransitionEffect.OPACITY)
                .animation({ duration: 300, curve: Curve.FastOutSlowIn }),
              TransitionEffect.translate({ x: 80 }).combine(TransitionEffect.OPACITY)
                .animation({ duration: 240, curve: Curve.FastOutSlowIn })))
          }
        }
      .width(this.heroClipW)
      .height(this.heroClipH)
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height('100%')
      .clip(true)
      .scale({ x: this.heroScale, y: this.heroScale })
      .translate({ x: this.heroX, y: this.heroY })
      // 切换标签时的**翻页动效**：整页从切换方向滑入 + 淡入（位移由 openInTab 设置）
      .translate({ x: this.contentSlideX })
      .opacity(this.contentFade)
      // 侧滑抽屉打开时的背景模糊（同书架搜索展开）
      .blur(this.drawerBlur())

      // ── 分屏对照的退出浮钮：**可自由拖动、松手吸附最近的屏幕侧缘**（用户要求），
      // 出现/消失带缩放淡入淡出动画。初始位置按智感握姿定边。
      if (this.compareSplit) {
        Stack() {
          ImmersiveIconButton({
            buttonSize: 34,
            buttonMaterialShadow: true,
            palette: this.palette(),
            buttonOnTap: () => {
              this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
                this.compareSplit = false;
              });
            }
          }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(15)
              .fontColor([this.palette().accent])
          }
        }
        .width(34)
        .height(34)
        // 位置 = 基准 position(0,0) + translate 状态（拖动 / 吸附都改状态）
        .translate({ x: this.exitBtnX, y: this.exitBtnY })
        // ⚠️ 单指拖动必须写 fingers: 1（工程铁律）
        .gesture(PanGesture({ fingers: 1 })
          .onActionStart((_e: GestureEvent) => {
            this.exitBtnDragged = true;
            this.exitDragBaseX = this.exitBtnX;
            this.exitDragBaseY = this.exitBtnY;
          })
          .onActionUpdate((e: GestureEvent) => {
            this.exitBtnX = Math.min(Math.max(this.exitDragBaseX + e.offsetX, 6),
              this.rootWidth - 40);
            this.exitBtnY = Math.min(Math.max(this.exitDragBaseY + e.offsetY, 60),
              this.rootHeight - 110);
          })
          .onActionEnd(() => {
            // 吸附：重心在左半 → 贴左缘，否则贴右缘
            const targetX: number = this.exitBtnX + 17 < this.rootWidth / 2
              ? 10 : this.rootWidth - 44;
            this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
              this.exitBtnX = targetX;
            });
          }))
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.scale({ x: 0.6, y: 0.6 }).combine(TransitionEffect.OPACITY)
            .animation({ duration: 260, curve: Curve.FastOutSlowIn }),
          TransitionEffect.scale({ x: 0.6, y: 0.6 }).combine(TransitionEffect.OPACITY)
            .animation({ duration: 200, curve: Curve.FastOutSlowIn })))
      }

      // ── 自动滚屏的**暂停浮钮**：屏幕中部靠边、沉浸光感，可自由拖拽后吸附最近侧缘。
      //
      // 与分屏退出浮钮同一套做法（位置 = 基准 (0,0) + translate 状态；拖动改状态；
      // 松手吸附；单指 PanGesture 必须写 fingers: 1；握姿换手时跟随，用户拖过就不跟）。
      // 之所以值得单独做一颗：滚动中用户最想做的就是"停"，此刻手指不该还去够底栏。
      if (this.floatBtnVisible()) {
        Stack() {
          ImmersiveIconButton({
            buttonSize: 44,
            buttonMaterialShadow: true,
            palette: this.palette(),
            buttonOnTap: () => {
              // 两种会话共用一颗钮：朗读中管朗读，否则管自动滚屏
              this.floatTogglePause();
            }
          }) {
            // 图标随状态切换，各挂一层过渡：暂停/继续之间是**淡入淡出**而不是硬闪
            if (this.floatBtnRunning()) {
              SymbolGlyph($r('sys.symbol.pause_fill'))
                .fontSize(18)
                .fontColor([this.palette().accent])
                .transition(TransitionEffect.OPACITY.animation({
                  duration: 160, curve: Curve.FastOutSlowIn
                }))
            } else {
              SymbolGlyph($r('sys.symbol.play_fill'))
                .fontSize(18)
                .fontColor([this.palette().accent])
                .transition(TransitionEffect.OPACITY.animation({
                  duration: 160, curve: Curve.FastOutSlowIn
                }))
            }
          }
        }
        .width(44)
        .height(44)
        .translate({ x: this.pauseBtnX, y: this.pauseBtnY })
        // 手势组：**长按结束会话 + 单指拖动改位置**并行绑定
        // （并行而非串行：长按判定期间手指往往会有轻微位移，串行会被拖动抢走）
        .gesture(GestureGroup(GestureMode.Parallel,
          // 长按浮钮 → 关闭并收起（会话结束）
          LongPressGesture({ repeat: false, duration: 500 })
            .onAction(() => {
              // 长按 = 结束当前会话（朗读与自动滚屏共用这颗钮，两个一起收干净）
              const wasReading: boolean = this.ttsOn;
              this.stopReadAloud();
              this.stopAutoScroll();
              this.toast(wasReading ? L10n.t('已停止朗读') : L10n.t('已退出自动滚屏'));
            }),
          // ⚠️ 单指拖动必须写 fingers: 1（工程铁律）
          PanGesture({ fingers: 1 })
          .onActionStart((_e: GestureEvent) => {
            // 拖拽位置只作为基准；换手时仍会跟到该手一侧（见 gripCb 的说明）
            this.pauseDragBaseX = this.pauseBtnX;
            this.pauseDragBaseY = this.pauseBtnY;
          })
          .onActionUpdate((e: GestureEvent) => {
            this.pauseBtnX = Math.min(Math.max(this.pauseDragBaseX + e.offsetX, 6),
              this.rootWidth - 50);
            this.pauseBtnY = Math.min(Math.max(this.pauseDragBaseY + e.offsetY, 60),
              this.rootHeight - 110);
          })
          .onActionEnd(() => {
            // 吸附：重心在左半 → 贴左缘，否则贴右缘（垂直位置保留用户拖到的位置）
            const targetX: number = this.pauseBtnX + 22 < this.rootWidth / 2
              ? 10 : this.rootWidth - 54;
            this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
              this.pauseBtnX = targetX;
            });
          })))
        // 进出场：缩放 + 淡入淡出（突然冒出来会显得突兀）
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.scale({ x: 0.6, y: 0.6 }).combine(TransitionEffect.OPACITY)
            .animation({ duration: 240, curve: Curve.FastOutSlowIn }),
          TransitionEffect.scale({ x: 0.6, y: 0.6 }).combine(TransitionEffect.OPACITY)
            .animation({ duration: 180, curve: Curve.FastOutSlowIn })))
      }

      // ── 悬浮顶栏：一个胶囊，宽度插值；展开/收起内容用 if 切换，
      //    同一时刻只有一层，杜绝「两层叠加 + 内容溢出胶囊」的错位。──
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          Row() {
            this.topBar()
          }
          .width('100%')

          if (this.topBarVisible && this.tabs.length > 1 && !this.tabBarAtBottom
            && !this.searchOpen) {
            // 占位：标签栏在下方独立的「标签栏层」里（没有左右 padding，视口横跨整屏）。
            // **查找条展开时标签栏隐藏 → 占位也去掉**，查找条上移到无标签栏时的位置（用户要求）。
            Column().width('100%').height(HwBar.tabs - 4)
          }

          // 文档内查找条（移植自参考项目的 Ctrl+F 当前文档查找）
          if (this.topBarVisible && this.searchOpen) {
            Row() {
              this.searchBar()
            }
            .width('100%')
            .padding({ top: HwSpace.xs })
          }
        }
        // 左对齐：标签栏要出血到屏幕边缘（宽度超出本列），
        // Column 默认居中对齐会把超宽子节点居中再受负边距影响，导致整体错位。
        .alignItems(HorizontalAlign.Start)
        .width(this.barAreaWidth())
      }
      .width('100%')
      .height('100%')
      // 顶/底栏都要让开系统栏——上一轮重构时把这段 padding 弄丢了，
      // 胶囊直接顶到屏幕边缘（顶部钻进状态栏、底部压进手势条）。
      // 有停靠列时再让开侧栏宽度，胶囊与正文列对齐、不压到目录/注释上。
      .padding({
        left: HwSpace.lg + this.barInsetLeft(),
        right: HwSpace.lg + this.barInsetRight(),
        top: this.padTop()
      })
      .hitTestBehavior(HitTestMode.Transparent)
      // **主题纪元拼在顶栏层上**：明暗切换时整个顶栏（胶囊 + 里面的按钮）重建。
      // 只改条目 key 不够——按钮是由这一层复用的，会保留旧颜色。
      .key('readerTopLayer_' + this.themeEpoch + '_l' + this.languageTick)
      // **沉浸阅读：整层完全不渲染**（用户要求"完全隐藏"，而不是收成迷你胶囊）——
      // Visibility.None 既不绘制也不占位，比只翻 topBarVisible 彻底得多。
      .visibility(this.immersiveRead ? Visibility.None : Visibility.Visible)
      // 侧滑抽屉打开时的背景模糊（同书架搜索展开）
      .blur(this.drawerBlur())

      // ── 标签栏层：与顶栏 Stack **平级**、没有左右 padding ——
      // Scroll 的 '100%' 就是整屏宽，标签的出现 / 消失点天然落在屏幕边缘。
      // **标签栏置底时这一层不渲染**（改挂在下面「悬浮底栏」那一层里）。
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.topBarVisible && this.tabs.length > 1 && !this.tabBarAtBottom && !this.searchOpen) {
          // **查找条展开时隐藏标签栏**（用户要求）；包一层 Column 挂 transition：
          // 收起查找后标签栏**滑入 + 淡入**出现（用户要求过渡动画）
          Column() {
            this.tabBar()
          }
          .width('100%')
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 240, curve: Curve.FastOutSlowIn })
            .combine(TransitionEffect.translate({ y: -10 })))
        }
      }
      .height('100%')
      .padding({ top: this.padTop() + HwBar.pill })
      .hitTestBehavior(HitTestMode.Transparent)
      // **标签栏长度按正文显示区域而定**（用户要求）：让开目录/注释停靠列；
      // 分屏对照时再让出右半——标签不再跑到目录和注释区域下面
      .width(this.compareSplit
        ? (this.rootWidth - this.barInsetLeft() - this.barInsetRight()) / 2
        : this.rootWidth - this.barInsetLeft() - this.barInsetRight())
      .margin({ left: this.barInsetLeft() })
      // 侧滑抽屉打开时的背景模糊（同书架搜索展开）
      .blur(this.drawerBlur())

      // ── 悬浮底栏：同样一个胶囊、宽度插值，内容用 if 切换 ──
      Stack({ alignContent: Alignment.BottomEnd }) {
        Column({ space: HwSpace.xs }) {
          // **标签栏置底（展开态）**：正常显示在悬浮胶囊**上方**，
          // 与胶囊同宽（同一个 bottomBarAdaptiveWidth()），序号 + 文件名的完整形态；
          // 胶囊收起时它消失，标签选择改由胶囊内部那一排数字承担（见 floatingToolBar 收起态）。
          if (this.tabBarAtBottom && this.tabs.length > 1 && this.bottomBarVisible) {
            Column() {
              this.tabBar()
            }
            .width(this.bottomBarAdaptiveWidth())
            .alignItems(HorizontalAlign.Start)
            // **两端圆形裁切**（用户要求：直角裁切难看）：置底时标签栏是"固定宽的一条"，
            // 横向滑动会在两端把芯片直角切掉半块 —— 用与悬浮胶囊同源的曲率
            // （HwRadius.pill）裁成圆弧，芯片从圆弧里滑出 / 滑入。
            // ⚠️ 只加在这里，不要加进 tabBar() 里面：顶部的 tabBar() 视口是整屏宽，
            // 静止时首标签距屏幕边缘只有 lg 的余量，加圆角会把它的左缘切掉。
            .borderRadius(HwRadius.pill)
            .clip(true)
          }
          this.floatingToolBar()
        }
        // 与顶栏同宽：都避开停靠列、与正文列对齐
        .width(this.barAreaWidth())
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .height('100%')
      .padding({
        left: HwSpace.lg + this.barInsetLeft(),
        right: HwSpace.lg + this.barInsetRight(),
        bottom: this.padBottom() + 4
      })
      // 智感握姿：收起态跟随握持手左右偏移，单手操作时胶囊贴近拇指一侧；
      // 展开态不偏移（要与正文列对齐）。side = -1 左 / 0 居中 / 1 右。
      .translate({ x: this.gripOffset() })
      .animation({ duration: 260, curve: Curve.FastOutSlowIn })
      .hitTestBehavior(HitTestMode.Transparent)
      // **主题纪元拼在底栏层上**：明暗切换时整颗胶囊（含里面的按钮与标签数字）重建
      .key('readerBottomLayer_' + this.themeEpoch + '_l' + this.languageTick)
      // 同上：沉浸阅读时底栏层整层不渲染（连收起态的迷你胶囊也一并消失）
      .visibility(this.immersiveRead ? Visibility.None : Visibility.Visible)
      // 侧滑抽屉打开时的背景模糊（同书架搜索展开）
      .blur(this.drawerBlur())

      // **沉浸阅读的退出胶囊**（用户要求：改到**左上角**、样式与编辑页「专注中」一致）；
      // 沉浸期间顶栏 / 底栏 / 标签栏 / 查找条全部不渲染，它是屏幕上唯一的控件。
      // 底色走沉浸光感承载层（用户要求：胶囊也要有光感）——内容 Row 透明底浮在上层
      if (this.immersiveRead) {
        Stack() {
          ImmersiveCardLayer({ layerRadius: HwRadius.pill, layerShadow: false })
          Row({ space: 6 }) {
            Text(L10n.t('专注中'))
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
            ImmersiveIconButton({
              buttonSize: 30,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.toggleImmersive();
              }
            }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(14)
                .fontColor([this.palette().accent])
            }
          }
          .alignItems(VerticalAlign.Center)
          .padding({ left: 10, right: 6, top: 4, bottom: 4 })
        }
        .borderRadius(HwRadius.pill)
        // 左上角：避开系统状态栏（与顶栏同档留白）；**大屏横屏要给停靠目录栏让位**，
        // 否则胶囊落在目录面板上（用户实测：三栏时"专注中"跑到目录区域）
        .position({ x: HwSpace.lg + this.barInsetLeft(), y: 52 })
      }

      // **系统选择模式的退出胶囊**（用户要求）：屏幕右缘中部（智感握姿拇指可及），
      // 点一下恢复自定义批注菜单、胶囊消失。出现 / 消失都带淡入缩放过渡。
      if (this.systemSelectBlock.length > 0) {
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .borderRadius(23)
            .backgroundColor(this.materialOn() ? '#00000000' : barFrostColor(this.palette().surface))
            .backgroundBlurStyle(this.materialOn() ? BlurStyle.NONE : BlurStyle.Thin)
            .hitTestBehavior(HitTestMode.None)

          ImmersiveCardLayer({ layerRadius: 23, layerShadow: true })

          SymbolGlyph($r('sys.symbol.undo'))
            .fontSize(20)
            .fontColor([this.palette().accent])
        }
        .width(46)
        .height(46)
        // **可拖动**（用户要求：支持自由移动位置，但默认自动贴边）：
        // 未拖过（sysTabX < 0）时按贴边公式定位；拖过后停在松手的位置（本次阅读内有效）。
        // 用 priorityGesture 压过根 Stack 的横向 priorityGesture，拖动才不会被抢。
        .position({
          x: this.sysTabX >= 0 ? this.sysTabX
            : (this.gripSide === -1
              ? this.barInsetLeft() + 8
              : this.rootWidth - this.barInsetRight() - 54),
          y: this.sysTabY >= 0 ? this.sysTabY
            : Math.max(80, this.rootHeight * 0.44)
        })
        .priorityGesture(
          PanGesture({ direction: PanDirection.All, distance: 5 })
            .onActionStart(() => {
              this.sysTabBaseX = this.sysTabX >= 0 ? this.sysTabX
                : (this.gripSide === -1
                  ? this.barInsetLeft() + 8
                  : this.rootWidth - this.barInsetRight() - 54);
              this.sysTabBaseY = this.sysTabY >= 0 ? this.sysTabY
                : Math.max(80, this.rootHeight * 0.44);
            })
            .onActionUpdate((event: GestureEvent) => {
              this.sysTabX = Math.max(8, Math.min(this.rootWidth - 54,
                this.sysTabBaseX + event.offsetX));
              this.sysTabY = Math.max(80, Math.min(this.rootHeight - 140,
                this.sysTabBaseY + event.offsetY));
            })
            .onActionEnd(() => {
              // **吸附屏幕边缘**（用户要求）：松手后 x 吸到最近的左/右边缘
              //（避开停靠列），y 保持在松手高度。
              const leftX: number = this.barInsetLeft() + 8;
              const rightX: number = this.rootWidth - this.barInsetRight() - 54;
              this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
                this.sysTabX = Math.abs(this.sysTabX - leftX) <= Math.abs(this.sysTabX - rightX)
                  ? leftX : rightX;
              });
            })
        )
        .animation({ duration: 260, curve: Curve.FastOutSlowIn })
        .onClick(() => {
          this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
            this.systemSelectBlock = '';
          });
          // 退出即重置位置：下次进入恢复初始贴边（用户要求）
          this.sysTabX = -1;
          this.sysTabY = -1;
          this.toast(L10n.t('已恢复批注菜单'));
        })
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.FastOutSlowIn })
            .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
            .combine(TransitionEffect.translate({ x: 24 })),
          TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.FastOutSlowIn })
            .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
            .combine(TransitionEffect.translate({ x: 24 }))
        ))
      }

      // 图表 / 公式放大查看浮层：毛玻璃暗化背景（相册式），图表卡片 1600px 大画布
      // 横向/纵向滚动平移；行内正文被盖住且根级捏合被抑制，不会误改字号
      if (this.enlargeMode.length > 0) {
        Stack({ alignContent: Alignment.TopStart }) {
          // 背景：**固定灰色磨砂**（不跟主题走），相册查看器的观感
          // 原底保留（用户要求）：只压一层 20% 轻暗纱 + 轻模糊，
          // 阅读页自己的底色 / 壁纸 / 光斑都能透出来，不再是整片死灰
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#33000000')
            .backgroundBlurStyle(BlurStyle.Regular)
            .hitTestBehavior(HitTestMode.None)

          Column() {
            Row({ space: HwSpace.sm }) {
              // 左上角标题：显示原内容的标题（脑图主题等）；没有就不占位显示
              if (this.enlargeTitle.length > 0) {
                Text(this.enlargeTitle)
                  .fontSize(HwType.label + 1)
                  .fontColor(this.isDark() ? '#FFFFFFFF' : '#E6222226')
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(TextAlign.Start)
              } else {
                Blank()
              }
              // **下载图片**（用户要求，只在公式 / 图表上出现）：另开一块独立渲染
              // 表面重画一遍再另存 —— 浅色白底、长宽即内容边界、屏外内容也在图里
              //（不截屏幕上那块：见 startEnlargeDownload 的注释）。
              // 下载进行中变淡（按钮不吃第二次点击，防重复生成）。
              if (this.dlSupported()) {
                ImmersiveIconButton({
                  buttonSize: 34,
                  buttonMaterialShadow: false,
                  palette: this.palette(),
                  buttonOnTap: () => {
                    this.startEnlargeDownload();
                  }
                }) {
                  SymbolGlyph($r('sys.symbol.arrow_down_circle'))
                    .fontSize(15)
                    .fontColor([this.dlBusy
                      ? (this.isDark() ? '#66FFFFFF' : '#66222226')
                      : (this.isDark() ? '#FFFFFFFF' : '#E6222226')])
                }
              }
              // **查看源码 ↔ 返回预览**（用户要求：放在「减」按钮左边）。
              // 图表 / HTML / 代码三类放大内容都适用：只换渲染形态，payload 不变。
              if (this.enlargeHasCode()) {
                ImmersiveIconButton({
                  buttonSize: 34,
                  buttonMaterialShadow: false,
                  palette: this.palette(),
                  buttonOnTap: () => {
                    this.toggleEnlargeCode();
                  }
                }) {
                  SymbolGlyph($r('sys.symbol.text_alignleft'))
                    .fontSize(15)
                    .fontColor([this.enlargeMode === 'code'
                      ? this.palette().accent
                      : (this.isDark() ? '#FFFFFFFF' : '#E6222226')])
                }
              }
              // 缩小：body 缩放 ×0.8（最小 0.5）
              ImmersiveIconButton({
                buttonSize: 34,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.zoomBy(0.8);
                }
              }) {
                SymbolGlyph($r('sys.symbol.minus'))
                  .fontSize(15)
                  .fontColor([this.isDark() ? '#FFFFFFFF' : '#E6222226'])
              }
              // 放大：body 缩放 ×1.25（最大 3）
              ImmersiveIconButton({
                buttonSize: 34,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.zoomBy(1.25);
                }
              }) {
                SymbolGlyph($r('sys.symbol.plus'))
                  .fontSize(15)
                  .fontColor([this.isDark() ? '#FFFFFFFF' : '#E6222226'])
              }
              // 旋转（横屏）展示：整个内容层转 90°，尺寸按横屏互换
              ImmersiveIconButton({
                buttonSize: 34,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.toggleRotate();
                }
              }) {
                SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
                  .fontSize(15)
                  .fontColor([this.isDark() ? '#FFFFFFFF' : '#E6222226'])
              }
              // **刷新**（用户要求）：图表内容挤在一起时，按当前容器尺寸重新排布
              // （refit）—— mermaid / markmap / graphviz / svg 会按新宽度重画，
              // 不用退出重进；缩放同时归 1。图片模式没有 refit 概念，不显示此按钮。
              if (this.enlargeMode !== 'image') {
                ImmersiveIconButton({
                  buttonSize: 34,
                  buttonMaterialShadow: false,
                  palette: this.palette(),
                  buttonOnTap: () => {
                    // 递增触发 DiagramWeb 的 @Watch('doRefit') → 重载页面按当前容器重渲染。
                    // 重载会把引擎页面比例打回 1 倍，所以这里同步把 webZoom 也归 1，
                    // 否则记账与实际显示错位，之后按 ± 会先"空转"几档
                    this.webZoom = 1;
                    this.enlargeRefitTick = this.enlargeRefitTick + 1;
                  }
                }) {
                  Image($r('app.media.arrow_2_circlepath'))
                    .width(18)
                    .height(18)
                    .fillColor(this.isDark() ? '#FFFFFFFF' : '#E6222226')
                }
              }
              ImmersiveIconButton({
                buttonSize: 34,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  // **统一走 closeOverlays**：除了复位缩放状态，还会把"从对照面板
                  // 点开"的浮层关闭后面板自动拉回来（内联关闭漏了这条恢复链，
                  // 用户实测点 × 不弹回、只有侧滑返回才弹回）
                  this.closeOverlays();
                }
              }) {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(15)
                  .fontColor([this.isDark() ? '#FFFFFFFF' : '#E6222226'])
              }
            }
            .width('100%')
            .padding({ left: HwSpace.lg, right: HwSpace.lg, top: this.padTop() })
            // 按钮行出现 / 消失更自然：随浮层挂载淡入下落、卸载淡出上移
            .transition({
              opacity: 0,
              translate: { y: -10 }
            })

            // 画布区：**只旋转里面的画布**，标题行 / 按钮保持竖屏不转（用户要求）。
            // 画布尺寸按"画布区的高×宽"互换，转 90° 后正好铺满画布区。
            // **保留原卡片的颜色和边框**（codeBlockBg + 描边），放大页仍是"那张卡片"。
            Stack({ alignContent: Alignment.Center }) {
              Column() {
                if (this.enlargeMode === 'image') {
                  // **图片模式：原生 Image + 捏合手势**（沙箱图片走 Web 加载不可靠，
                  // 用户实测"图片加载失败"）；缩放 / 旋转与图表模式完全一致。
                  Image(this.enlargePayload)
                    .objectFit(ImageFit.Contain)
                    .width('100%')
                    .height('100%')
                    .scale({ x: this.imgScale, y: this.imgScale })
                    .offset({ x: this.imgDx, y: this.imgDy })
                    // **手指落在图片上时抑制阅读页根级捏合**（否则双指缩放会被
                    // "改字号"抢走 —— 用户实测图片页不能双指缩放）
                    .onTouch((event: TouchEvent) => {
                      if (event.type === TouchType.Down) {
                        this.webTouchDepth = this.webTouchDepth + 1;
                      } else if (event.type === TouchType.Up
                        || event.type === TouchType.Cancel) {
                        this.webTouchDepth = Math.max(0, this.webTouchDepth - 1);
                      }
                    })
                    // **用 priorityGesture**：外层根 Stack 上有横向滑动的 priorityGesture，
                    // 普通 gesture 会被它拦掉（用户实测"不能滑动、不能双指缩放"）
                    .priorityGesture(
                      // **拖动 + 双指缩放并行**（用户要求：能滑动、能双指缩放）
                      // ⚠️ 拖动必须是 **fingers: 1（单指）**：此前写的是 2 指，用户实测
                      // "放大查看图片 / 手写笔记不能单指拖动"（必须两指按住才动，等于不可用）。
                      // 单指拖 + 双指捏合在 Parallel 组里互不冲突。
                      GestureGroup(GestureMode.Parallel,
                        PanGesture({ fingers: 1, distance: 1 })
                          .onActionStart(() => {
                            this.imgDxBase = this.imgDx;
                            this.imgDyBase = this.imgDy;
                          })
                          .onActionUpdate((event: GestureEvent) => {
                            this.imgDx = this.imgDxBase + event.offsetX;
                            this.imgDy = this.imgDyBase + event.offsetY;
                          }),
                        PinchGesture({ fingers: 2 })
                          .onActionStart(() => {
                            this.imgPinchBase = this.imgScale;
                          })
                          .onActionUpdate((event: GestureEvent) => {
                            const sc: number = event.scale !== undefined ? event.scale : 1;
                            this.imgScale = Math.min(8, Math.max(0.05, this.imgPinchBase * sc));
                          })
                      )
                    )
                } else {
                  DiagramWeb({
                    mode: this.enlargeMode,
                    payload: this.enlargePayload,
                    // 代码放大的高亮 HTML（其它模式为空，模板按纯文本渲染）
                    richHtml: this.enlargeRichHtml,
                    // 指定高亮行（围栏元数据 js{1,3-5}），放大后仍然要亮
                    hlLines: this.enlargeHlCsv,
                    dark: this.isDark(),
                    // ⚠️ **页面底色必须不透明**：透明 Web 表面在「一镜到底」退场的
                    // geometryTransition 快照里被系统合成成垃圾色（真机：卡片发红）
                    cardBg: withAlpha(this.palette().codeBlockBg, 'FF'),
                    // ⚠️ 双指捏合**必须留给引擎**（zoomAccess=true）：DiagramWeb 是
                    // Web 组件，它在原生层就吞掉触摸序列，外层套 ArkUI 手势收不到
                    // 双指（实测：套了 priorityGesture 反而彻底不能捏合）。而且
                    // ctrl.zoom() 与捏合是同一个页面比例，± 与双指天然叠加。
                    zoom: true,
                    fit: true,
                    fillHeight: true,
                    webZoom: this.webZoom,
                    // **refit 通道**（此前一直没接上）：工具栏「刷新」/旋转后递增，
                    // DiagramWeb 的 @Watch('doRefit') 会让页面按当前容器与缩放重新自适应
                    refitRequest: this.enlargeRefitTick,
                    onWebTouch: (down: boolean) => {
                      this.webTouchDepth = Math.max(0, this.webTouchDepth + (down ? 1 : -1));
                    }
                  })
                }
              }
              .width(this.rotated ? this.canvasH : '100%')
              .height(this.rotated ? this.canvasW : '100%')
              .borderRadius(HwRadius.card)
              // 与 Web 页面底色同源（不透明）：快照/形变全程颜色一致
              .backgroundColor(withAlpha(this.palette().codeBlockBg, 'FF'))
              .border({ width: 1, color: this.palette().divider })
              .clip(true)
              .rotate({
                x: 0,
                y: 0,
                z: 1,
                angle: this.rotated ? 90 : 0,
                centerX: '50%',
                centerY: '50%'
              })
              .geometryTransition(this.enlargeGeo, { follow: true })
            }
            .width('100%')
            .layoutWeight(1)
            // 与上方按钮行留出空隙（用户反馈贴在一起）
            .margin({ top: HwSpace.sm })
            .onAreaChange((oldValue: Area, newValue: Area) => {
              // 量出画布区实际尺寸：旋转时按它互换宽高
              const w: Length = newValue.width;
              const h: Length = newValue.height;
              if (typeof w === 'number' && w > 0) {
                this.canvasW = w;
              }
              if (typeof h === 'number' && h > 0) {
                this.canvasH = h;
              }
            })
          }
          .width('100%')
          .height('100%')
        }
        .width('100%')
        .height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }

      // ── 图片一镜到底：全屏大图 ──
      // 与正文里那张图共享同一 geometry id，打开/关闭都由系统做形状补间，
      // 所以是「从那张小图长出来、再缩回那张小图」，不需要自己算矩形。
      if (this.zoomImgOpen && this.zoomImgSrc.length > 0) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#B3A6A6A6')
            .backgroundBlurStyle(BlurStyle.Regular)
            .onClick(() => {
              this.closeZoomImage();
            })

          Image(this.zoomImgSrc)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
            .draggable(false)
            .geometryTransition('mdimg_' + this.zoomImgKey, { follow: true })
            .onClick(() => {
              this.closeZoomImage();
            })
        }
        .width('100%')
        .height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .transition(TransitionEffect.OPACITY.animation({ duration: 240, curve: Curve.FastOutSlowIn }))
      }

      // 导出链路已统一走自研渲染器，这里不再挂载任何隐藏 Web（见 exportHtml 注释）。

      // 粒子消散（外观设置开启时，切换标签 / 文档爆一次）

      // 遮罩：随抽屉一起挂载 / 卸载，用透明度过渡淡入淡出
      if (this.anyDrawerOpen()) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#59000000')
          .onClick(() => {
            this.closeDrawers();
          })
          .transition({ opacity: 0 })
      }

      // 目录抽屉：靠左对齐；挂载时从左侧屏外滑入
      if (this.tocOpen) {
        Stack({ alignContent: Alignment.TopStart }) {
          this.tocDrawer(false)
        }
        .width('100%')
        .height('100%')
        // **屏幕裁切**：抽屉滑出屏幕外的部分不可见，
        // 杜绝"概率性一部分卡在屏幕外"（用户反馈）
        .clip(true)
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(this.tocTransition())
      }

      // 注释抽屉：靠右对齐；挂载时从右侧屏外滑入
      if (this.notesOpen) {
        Stack({ alignContent: Alignment.TopEnd }) {
          this.notesDrawer(false)
        }
        .width('100%')
        .height('100%')
        .clip(true)
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(this.notesTransition())
      }

      // （手写批注浮层已删除：功能以后重做）





    }
    .width('100%')
    .height('100%')
    // ══════════ 半模态面板：官方规范（material/ModalSheet.ets）══════════
    // 模态型 + 固定 MEDIUM 高 + 官方标题栏 / 关闭按钮 / 拖拽条。
    // 本 SDK：bindSheet 不支持 $$(双向)语法、同节点不认多条 bindSheet ——
    // 所以用一个字符串 activeSheet 鉴别当前面板，builder 内部再按需切换。
    .bindSheet(this.sheetVisible, this.currentSheet(), modalSheetOptions({
      title: this.sheetTitle(),
      subtitle: this.sheetSubtitle(),
      surface: this.palette().surface,
      // 高度档位与键盘避让都由 ModalSheet 统一给（见 modalSheetOptions / SheetKeyboardLift），
      // 这里只声明"批注面板从贴合内容起档"。
      // **网页面板近乎满屏**（用户要求：参考本地 xjau 网页登录面板）：
      // 大尺寸 + 标题区换成「刷新 / 复制链接」操作条 + 隐藏拖拽条（避免与网页内滚动打架）
      large: this.activeSheet === 'web',

      titleBuilder: this.activeSheet === 'web' ? this.webSheetTitle.bind(this) : undefined,
      // 拖拽条隐藏（用户要求：滑动条太丑）——网页面板与「全部编辑功能」面板
      hideDragBar: this.activeSheet === 'web' || this.activeSheet === 'more',
      // 横屏也是全宽大面板（不转 480vp 居中窗口）——「差不多屏幕一样大」
      fullWidth: this.activeSheet === 'web',
      // **批注面板贴合内容起档**：手机形态下 ModalSheet 会把它排成
      // [FIT_CONTENT, MEDIUM, LARGE] 三档（拖拽条可往上拉），横屏平台不支持多档、
      // 退成 height=FIT_CONTENT。其余面板仍从 MEDIUM 起档、可拖到 LARGE。
      // 「全部编辑功能」也贴合内容：拖拽条已按用户要求隐藏，内容自适应高度
      // 才不会出现"面板比磁贴矮、底部被裁"（磁贴已改自适应列数，高度可控）。
      fitContent: this.activeSheet === 'note' || this.activeSheet === 'more',
      // 竖屏（含平板竖屏）按手机形态出底部面板；平板竖屏宽度收一半
      phoneLayout: this.rootWidth <= this.rootHeight,
      screenWidth: this.rootWidth,
      onDismiss: () => {
        // dismiss 完成后才清内容标识：关闭动画期间面板保持原内容（避免白板）。
        // ⚠️ 这里**必须无条件清**：系统 dismiss 后 sheetVisible 若仍是 true，
        // bindSheet 的可见状态与实际不一致，「更多」面板就再也打不开了（真机实锤）。
        // 面板切换的白屏问题由 closeSheetThen（先关后开）解决，与此处无关。
        this.sheetVisible = false;
        this.activeSheet = '';
      }
    }))
    // 让根节点铺满整个窗口（含状态栏与手势条区域），避让由 padTop / padBottom 统一负责。
    // 不显式声明的话，ArkUI 可能再给根节点加一层默认安全区内边距，与我们的内边距叠成双份。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // 根背景保持透明：一镜到底展开/缩回时下层书架要能透出来；
    // 页面自身的底色由 backdrop 层负责（它受 heroBg 控制、随转场渐显渐隐）。
    .backgroundColor(Color.Transparent)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      // Area.width 的类型是 Length（number | string | Resource），必须收窄后再用
      const raw: Length = newValue.width;
      if (typeof raw === 'number' && raw > 0 && raw !== this.rootWidth) {
        this.rootWidth = raw;
      }
      const rawH: Length = newValue.height;
      if (typeof rawH === 'number' && rawH > 0 && rawH !== this.rootHeight) {
        this.rootHeight = rawH;
      }
      // 进入大屏/横屏时把目录与注释钉在两侧 —— **钉不钉按用户的默认偏好**（更多面板里设置，
      // 仅宽屏显示；用户反馈：想要"默认不展开"的选择权）。只在「窄→宽」的切换瞬间应用一次，
      // 之后用户手动开合就尊重用户的选择。
      const wide: boolean = this.isWide();
      if (wide && !this.wasWide) {
        this.tocPinned = this.tocPinnedDefault;
        this.notesPinned = this.notesPinnedDefault;
      }
      this.wasWide = wide;
    })
    //
    // 用 priorityGesture 而不是 gesture：内层 List 会优先吃掉落在它区域上的滑动手势，
    // 普通 gesture 常常收不到横向滑动。加上 direction: Horizontal 约束后，
    // 纵向拖动不满足手势识别条件，会正常交还给 List 滚动。
    .priorityGesture(
      PanGesture({ direction: PanDirection.Horizontal, distance: 24 })
        // **拖分隔条调宽功能已移除**（用户实测：分隔条拖拽热区与侧滑手势竞争，
        // 导致侧滑滑出不完全；黑线分隔条一并去掉）。
        // 这根手势现在只负责：侧滑开合目录 / 注释（onActionEnd 的分区逻辑）。
        .onActionEnd((event: GestureEvent) => {
          const dx: number = event.offsetX;
          // 按触点分区（用户要求）：起点在屏幕偏左 → 这一次滑动只管目录；
          // 起点在屏幕偏右 → 只管注释与批注。避免两边互相抢手势。
          // GestureEvent 本体没有窗口坐标，从 fingerList 里取第一根手指的屏幕绝对 X
          // （与本侧滑手势其它回调里的 globalDisplayX 同一口径）
          // globalDisplayX 是 number | undefined：先落局部常量再收窄（ArkTS 规则）。
          // ⚠️ 双指竞争收尾时 fingerList[0] 可能 undefined（真机崩溃实录），逐层判空
          let startX: number = 0;
          const fl = event.fingerList;
          if (fl !== undefined && fl.length > 0 && fl[0] !== undefined
            && fl[0].globalDisplayX !== undefined) {
            startX = fl[0].globalDisplayX;
          }
          const leftZone: boolean = startX * 2 < this.rootWidth;
          const notesShown: boolean = this.isWide() ? this.notesPinned : this.notesOpen;
          const tocShown: boolean = this.isWide() ? this.tocPinned : this.tocOpen;
          if (dx > 56) {
            // ★ 手机窄屏：不分左右区，右滑开目录 / 左滑开注释（方向感自然）
            if (!this.isWide()) {
              if (dx > 56) {
                // 右滑 → 开目录（或关闭已打开的注释）
                if (notesShown) {
                  this.closeSide('notes');
                  this.scheduleDoubleClose('notes');
                } else if (!tocShown) {
                  this.openToc();
                }
              } else if (dx < -56) {
                // 左滑 → 开注释（或关闭已打开的目录）
                if (tocShown) {
                  this.closeSide('toc');
                  this.scheduleDoubleClose('toc');
                } else if (!notesShown) {
                  this.openNotes();
                }
              }
            } else if (leftZone) {
              // 宽屏：屏幕偏左 → 打开目录
              if (!tocShown) {
                this.openToc();
              }
            } else if (notesShown) {
              // 宽屏：屏幕偏右 → 右滑关闭注释
              this.closeSide('notes');
              this.scheduleDoubleClose('notes');
            }
          } else if (dx < -56) {
            // ★ 手机窄屏：不分左右区，左滑开注释（或关闭已打开的目录）
            if (!this.isWide()) {
              if (tocShown) {
                this.closeSide('toc');
                this.scheduleDoubleClose('toc');
              } else if (!notesShown) {
                this.openNotes();
              }
            } else if (leftZone) {
              // 宽屏：屏幕偏左 → 左滑关闭目录
              if (tocShown) {
                this.closeSide('toc');
                this.scheduleDoubleClose('toc');
              }
            } else if (!notesShown) {
              // 宽屏：屏幕偏右 → 左滑打开注释
              this.openNotes();
            }
          }
        })
    )
    // 双指捏合调字号（等价于参考项目的 Ctrl+滚轮）
    .priorityGesture(
      PinchGesture()
        .onActionStart(() => {
          this.onPinchStart();
        })
        .onActionUpdate((event: GestureEvent) => {
          this.onPinchUpdate(event.scale);
        })
    )
  }

  /**
   * 批注面板的多档高度已上收到 ModalSheet：手机形态由 modalSheetOptions 统一排
   * [FIT_CONTENT, MEDIUM, LARGE] / [MEDIUM, LARGE] 档位，横屏退成定高（平台不支持
   * 多档拖拽）。页面侧只需声明 fitContent 起档与否。
   */


  @Builder
  backdrop() {
    // 阅读背景，按优先级：
    //   ① 壁纸（设了就铺满，再压一层可调浓度的遮罩保证正文可读）
    //   ② 外观设置里的自定义背景色
    //   ③ 主题默认渐变
    // 光斑两团始终保留，让沉浸光感有东西可采样
    // 阅读背景置顶：它只管阅读页，与外观壁纸互相独立
    //
    // ⚠️ ①② 两层用 `bgDark()`（只看系统深浅）而不是 `isDark()`（含主题档位）：
    // 用户挑的壁纸颜色**不因切换主题而改变**（见 bgDark 注释）。
    if (this.readerBgPath.length > 0) {
      Image(WallpaperStore.imageSourceOf(this.readerBgPath))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .blur(this.wallpaperBlur)

      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(WallpaperStore.scrimColorOf(this.readerBgScrim(), this.bgDark()))
    } else if (this.readerBgId.length > 0) {
      GenWallpaper({ styleId: this.readerBgId, darkMode: this.bgDark() })

      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(WallpaperStore.scrimColorOf(this.readerBgScrim(), this.bgDark()))
    } else if (this.wallpaperPathEffective().length > 0) {
      Image(WallpaperStore.imageSourceOf(this.wallpaperPathEffective()))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .blur(this.wallpaperBlur)

      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.bgDark()))
    } else if (this.genWallId.length > 0) {
      // 函数绘制壁纸（零位图），与书架同一套：见 theme/GenWallpaper.ets
      GenWallpaper({ styleId: this.genWallId, darkMode: this.bgDark() })

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

    // 光斑两团：有图片壁纸 / 阅读背景图时不再绘制（用户要求）
    if (this.readerBgPath.length === 0 && this.wallpaperPathEffective().length === 0) {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width(340)
        .height(340)
        .borderRadius(170)
        .radialGradient({
          center: ['50%', '50%'],
          radius: 170,
          colors: [[this.palette().glowCool, 0.0], [this.palette().glowCool, 0.30], ['#00000000', 1.0]]
        })
        .blur(26)
        .translate({ x: -100 + this.blobAX, y: -80 + this.blobAY })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    }

    if (this.readerBgPath.length === 0 && this.wallpaperPathEffective().length === 0) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column()
        .width(300)
        .height(300)
        .borderRadius(150)
        .radialGradient({
          center: ['50%', '50%'],
          radius: 150,
          colors: [[this.palette().glowWarm, 0.0], [this.palette().glowWarm, 0.28], ['#00000000', 1.0]]
        })
        .blur(26)
        .translate({ x: 90 + this.blobBX, y: 100 + this.blobBY })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    }
  }
}

