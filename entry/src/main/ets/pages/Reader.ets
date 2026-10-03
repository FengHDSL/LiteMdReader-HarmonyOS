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

import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
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
} from '../theme/DesignTokens';
import {
  ImmersiveBar,
  ImmersiveCard,
  ImmersiveCardLayer,
  ImmersiveChip,
  ImmersiveIconButton,
  ImmersiveSheetPanel
} from '../material/ImmersiveCard';
import { getImmersiveMaterial } from '../material/SystemMaterial';
import { modalSheetOptions } from '../material/ModalSheet';
import { ExportOptionsPanel } from '../components/ExportOptionsPanel';
import { ReadingSettingsPanel } from '../settings/ReadingSettings';
import { AnnotationStore } from '../service/AnnotationStore';
import { applySystemBarTheme, applyAppColorMode, setKeepScreenOn, setWindowBrightnessLevel,
  syncSystemDarkFromContext, markThemeApplied, themeChangedSince,
  startThemeWatchdog, stopThemeWatchdog } from '../service/AppWindow';
import { WallpaperStore } from '../service/WallpaperStore';
import { DocMeta, DocStore, ReaderRoute, DocFileInfo, DocTimes } from '../service/DocStore';
// 桌面卡片暂时停用（见 flushProgress 里的注释）：FormSync 调用一并注释
// import { FormSync } from '../service/FormSync';
import { ReaderTab, TabStore } from '../service/TabStore';
import { FontStore } from '../service/FontStore';
import { NavLifecycle } from '../service/NavLifecycle';
import { GripAware } from '../service/GripAware';
import { ShareKitService } from '../service/ShareKitService';
import { GenWallpaper } from '../theme/GenWallpaper';
import { HeroInit, HeroRect, HeroTransition } from '../service/HeroTransition';
import { DocCover, coverColorsOf } from '../components/DocCover';
import { DiagramWeb } from '../components/DiagramWeb';
import { MdAnnotation, MdBlock, MdBlockKind, MdHeading, MdMetaItem, MdNote, MdParseResult, MdTaskState } from '../markdown/MdTypes';
import { ChartCache } from '../service/ChartCache';
import { ChartRenderPool, ChartTask } from '../components/ChartRenderPool';
import { ReaderFlagTile } from '../components/ReaderFlagTile';
import { MdParser } from '../markdown/MdParser';
import { MdBlockView } from '../markdown/MdView';
import { ExportService } from '../service/ExportService';

/** 列表里正文块之前固定占用的条目数：文档信息卡占 1 条。 */
const LIST_HEADER_COUNT: number = 1;/**
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
  @StorageLink('readerThemeMode') @Watch('onThemeChanged') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') @Watch('onThemeChanged') systemDark: boolean = false;  /**
   * 主题纪元：明暗一变自增（见 applyThemeChange）。
   * 它拼在**正文 List 容器的 key** 上——只换条目 key 不够，
   * 已挂载的 ListItem 与其中的按钮是被列表复用的，必须换容器 key 才会真正重建。
   */
  @State themeEpoch: number = 0;
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
   * **本页自己的深浅记忆**（不再依赖全局"已应用"标记）：
   * 全局标记会被别的页面先置位（切深浅时设置页先收到），阅读页据此**跳过重建**
   * → 出现"背景跟着变深、正文文字却还是浅色主题的深色字"（用户实测看不清）。
   */
  private lastAppliedDark: boolean = false;
  private lastAppliedValid: boolean = false;
  /** 图表后台预渲染任务（打开文件时生成，池子逐个渲染成 PNG 写缓存） */
  @State chartTasks: ChartTask[] = [];
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
  // （旧的原生捏合/平移状态已删：缩放改由 DiagramWeb 的 webZoom + Web 原生双指完成）
  @State enlargePayload: string = '';
  /** 放大浮层的一镜到底共享 id（与正文里那张卡片同 id） */
  @State enlargeGeo: string = '';
  /** 放大浮层的 Web 组件 id（导出图片快照按 id 抓） */
  @State enlargeWebId: string = '';
  /**
   * **图表就绪信号**：后台预渲染池每完成一个图表递增。图表 / 公式条目只用它
   * （不再用全局 renderEpoch）作 key —— 否则任何一次 renderEpoch 变化或"图表逐一
   * 渲染完成"都会整树重建 → 图表反复重新加载、闪来闪去（用户反馈）。
   */
  @State chartReadyTick: number = 0;
  /** 浮层的 Web 是否挂载（退后台卸载、回前台重挂 —— 修"关屏再开自动退出页面"） */
  @State enlargeWebMounted: boolean = true;
  /** 回前台信号（EntryAbility 递增） */
  @StorageProp('appForegroundTick') @Watch('onAppForegroundTick') appFgTick: number = 0;
  /** 旋转后重新自适应请求计数（传给 DiagramWeb） */
  @State enlargeRefitTick: number = 0;
  /** 手写批注图（手写页以批注模式返回时写入）：此处落成红双下划线批注 */
  @StorageProp('sketchAnnotationImage') @Watch('onSketchAnnotation') sketchAnnotation: string = '';
  /** 系统返回手势关闭浮层的信号（Index 的 onBackPressed 发出） */
  @StorageProp('readerOverlayCloseTick') @Watch('onOverlayCloseTick') overlayCloseTick: number = 0;
  /** 应用退后台计数（EntryAbility 递增）：回前台前复位浮层，避免 Web 状态异常 */
  @StorageProp('appBackgroundTick') @Watch('onAppBackgroundTick') appBgTick: number = 0;
  /** 放大内容的原标题（脑图主题等；空串 = 不显示标题） */
  @State enlargeTitle: string = '';
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
   * 缩放倍率步进（±25%）。范围 **0.25~4**（用户反馈：原 0.5~3 默认有时太大
   * 又不能再缩小）——放大时需要更小的下限才能把大图整体收进视野。
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
    // **手动无限缩小**（用户要求）：不设实际下限 —— 只挡 0 / 异常值（1% 以下
    // 图形已不可辨，再小没有意义且容易触发除零类问题）；放大上限仍为 4 倍。
    const next: number = this.webZoom * factor;
    if (!(next > 0)) {
      return;
    }
    this.webZoom = Math.min(4, Math.max(0.01, next));
  }

  /**
   * 退后台 / 关屏时**保留浮层、只卸载 Web**（用户要求：关屏再开不要自动退出
   * 图表界面）—— 后台被系统回收后 Web 表面状态不可靠，回前台重挂即可。
   */
  onAppBackgroundTick(): void {
    if (this.enlargeMode.length === 0 || !this.enlargeWebMounted) {
      return;
    }
    this.enlargeWebMounted = false;
  }

  /** 回前台：把卸载掉的 Web 重新挂载（图表重新渲染），浮层保持打开。 */
  onAppForegroundTick(): void {
    if (this.enlargeMode.length === 0 || this.enlargeWebMounted) {
      return;
    }
    this.enlargeWebId = 'enlarge_' + Date.now();
    this.enlargeWebMounted = true;
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
      this.toast('找不到手写批注图片');
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
      this.enlargeTitle = ann.text.length > 0 ? ann.text : '手写批注';
      this.enlargeWebId = 'enlarge_' + Date.now();
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
      this.toast('没有可标注的选区');
      return;
    }
    const list: MdAnnotation[] = this.withoutOverlap(this.annotations, blockId, start, end);
    list.push(this.buildAnnotation(blockId, start, end, text, -1, 'hw:' + rel, 'dbl'));
    this.commitAnnotations(list);
    this.toast('已添加手写批注');
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
  /** 停靠面板宽度（大屏下拖分隔条可调，范围 220~460） */
  @State tocPanelWidth: number = 300;
  @State notesPanelWidth: number = 300;
  /** 分隔条拖动状态：'toc' | 'notes' | ''（空 = 未在拖分隔条） */
  private sideDrag: string = '';
  private sideDragStartWidth: number = 0;
  private sideDragBaseX: number = 0;
  /** 大屏/横屏：注释停靠右侧 */
  @State notesPinned: boolean = false;
  /** 标签长按菜单 */
  @State tabMenuFor: string = '';
  /** 悬浮工具条上的「更多」菜单与亮度快捷面板（参考图三） */

  @State noteDraft: string = '';
  @State noteQuote: string = '';
  @State tocOpen: boolean = false;
  @State notesOpen: boolean = false;
  @State progress: number = 0;
  @State progressBlock: number = 0;
  @State activeHeading: string = '';
  @State scrolled: boolean = false;
  /** 顶栏 / 底栏是否展开。向下滚动自动收起，向上滚动或回到顶部恢复 */
  /** 顶栏与底栏**独立**收放：收起底栏不该把顶栏也带下去 */
  @State topBarVisible: boolean = true;
  @State bottomBarVisible: boolean = true;
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
  /** 阅读背景（与外观壁纸独立）：手选图路径 / 内置款 id */
  @StorageProp('readerBgPath') readerBgPath: string = '';
  @StorageProp('readerBgId') readerBgId: string = '';
  /** 切换标签时的内容滑入位移（vp），0 = 静止 */
  @State contentSlideX: number = 0;
  /** 翻页动效的透明度分量（0.3 → 1） */
  /** 当前打开的半模态面板：settings/note/tabMenu/bright/more；空串 = 全关 */
  @State activeSheet: string = '';
  @State contentFade: number = 1;
  @State rootWidth: number = 360;
  /** 窗口高度（vp）：页面过渡的缩放锚点兜底用 */
  @State rootHeight: number = 800;
  /** List 的初始滚动位置（构造时定位，避免「先顶部再跳走」的闪动） */
  @State listInitialIndex: number = 0;
  /** 是否首次加载（首次用 initialIndex 定位；切标签才用 scrollToIndex） */
  private firstLoad: boolean = true;

  private scroller: Scroller = new Scroller();
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
  /** 捏合调字号时的起始字号 */
  private pinchBaseFont: number = 0;
  /** 全库搜索带进来的关键词。等首帧布局完成、恢复阅读位置之后再执行查找 */
  private routeQuery: string = '';

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
    // **校准叠加层标志**（返回键拦截判据）：只以真实状态为准 —— 标志残留会让
    // 侧滑返回一直被吞掉（用户实测"不能侧滑返回"）。
    AppStorage.setOrCreate('readerOverlayOpen',
      this.enlargeMode.length > 0 || this.zoomImgOpen);
    // 首次已在 aboutToAppear 加载（为了 List 构造时定位）；从别处返回本页时才重新加载
    if (!this.firstLoad) {
      this.loadDoc();
    }
    this.firstLoad = false;
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
    this.heroEnter();
    // 智感握姿：**先申请权限再监听**（DETECT_GESTURE 是运行时授权权限，
    // 只声明不申请会让 motion.on 抛错被吞掉 → gripSide 恒 0 → 底部栏与选择
    // 胶囊都不跟手）。设备不支持或用户拒绝时静默降级。
    const gripCb = (side: number): void => {
      if (side !== this.gripSide) {
        this.gripSide = side;
        // 换手后清掉手动拖动位置：胶囊立即回到该手一侧（"智感握姿"要跟着手走）
        this.sysTabX = -1;
        this.sysTabY = -1;
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
      this.toast('返回失败');
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
  }

  /** 字号 / 行高等影响正文排版的设置变化 → 强制正文条目重建。 */
  onVisualChanged(): void {
    this.renderEpoch++;
  }

  // ══════════════════════ 顶栏 / 底栏的收起与展开 ══════════════════════
  //
  // 旧版用「首个可见块下标跳变」判断方向，块小的时候滚一屏跨几十个下标，
  // 轻轻一滑栏就没了——用户感知是「不正常消失」。现在改成**累计位移阈值**：
  // 往下读累计超过约四行才收，往回翻任何一帧立刻展开，回到顶部强制展开。
  // 收起时外层容器高度折叠到只剩系统栏避让，正文真实扩大（而不是被隐形栏占着）。

  private toggleAllBars(show: boolean): void {
    if (this.topBarVisible === show && this.bottomBarVisible === show) {
      return;
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.topBarVisible = show;
      this.bottomBarVisible = show;
    });
  }

  private toggleTopBar(show: boolean): void {
    if (this.topBarVisible === show) {
      return;
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.topBarVisible = show;
    });
  }

  private toggleBottomBar(show: boolean): void {
    if (this.bottomBarVisible === show) {
      return;
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.bottomBarVisible = show;
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
      const text: string = DocStore.readText(ctx, meta);
      const result: MdParseResult = MdParser.parse(text);
      this.blocks = result.blocks;
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
      // **图表后台预渲染任务**（用户要求：打开文件即后台加载转图片并写缓存，
      // 不等滑到位置才加载；导出也直接用缓存图）
      const tasks: ChartTask[] = [];
      const dark: boolean = this.isDark();
      for (let k = 0; k < this.blocks.length; k++) {
        const b: MdBlock = this.blocks[k];
        let mode: string = '';
        if (b.kind === MdBlockKind.Math) {
          mode = 'katex';
        } else if (b.kind === MdBlockKind.Chart) {
          mode = b.lang.toLowerCase();
        }
        if (mode.length === 0) {
          continue;
        }
        tasks.push({
          key: ChartCache.keyFor(mode, b.code, dark),
          mode: mode,
          payload: b.code
        } as ChartTask);
      }
      this.chartTasks = tasks;
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
        this.listInitialIndex = jumpTarget;
        this.pendingJump = -1;
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
    const kind: string = this.docBuiltin ? '内置语法教程' : '自建文档';
    // 用户要求：徽标后带上文档**格式**（md / txt）
    const fmt: string = this.docName.toLowerCase().endsWith('.txt') ? 'TXT' : 'MD';
    if (this.docReadOnly) {
      return kind + ' · ' + fmt + ' · 只读 · 可在「更多」里切换';
    }
    return kind + ' · ' + fmt + ' · 可写' + (this.docBuiltin ? ' · 常驻第一格' : '');
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
        this.toast('切换失败：文档不存在');
        return;
      }
      this.docReadOnly = readOnly;
      this.toast(readOnly ? '已切为只读：编辑入口已锁' : '已切为可写：可以编辑了');
    } catch (err) {
      this.toast('切换失败：' + DocStore.describeError(err as BusinessError));
    }
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
      // 桌面卡片即时刷新：**暂时停用**（卡片有 bug 待修，见 module.json5 的说明）。
      // 恢复时取消注释即可（import FormSync 也要一起恢复）。
      // FormSync.pushRecents(ctx);
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
        this.toast('返回失败');
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
      this.toast('返回失败');
    }
  }

  /** 重新解析当前文档（标签菜单里的「刷新」）。 */
  private reloadActiveDoc(): void {
    this.closeTabMenu();
    this.loadDoc();
    this.toast('已重新加载');
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
      this.toast('链接没有指向任何文档');
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
   * 目录 / 批注侧边栏在**关闭沉浸光感**时的底色：与阅读背景同色
   * （没设自定义背景色就退回主题底色）。
   */
  private readerBgColor(): string {
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
    if (action === 'note') {
      this.pendingBlockId = blockId;
      this.pendingStart = start;
      this.pendingEnd = end;
      this.pendingColor = -1;
      this.noteQuote = text;
      this.noteDraft = '';
      this.getUIContext().animateTo(this.animateParam(), () => {
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
      AppStorage.setOrCreate('sketchMode', 'annotate');
      AppStorage.setOrCreate('sketchAnnotationImage', '');
      if (this.stack !== null) {
        this.stack.pushPath({ name: 'pages/Sketch' });
      } else {
        this.toast('当前环境无法打开手写页');
      }
      return;
    }
    // wavy：波浪线标注（画在字下方），与荧光笔同属「同区间先清再写」
    if (action === 'wavy') {
      const list: MdAnnotation[] = this.withoutOverlap(this.annotations, blockId, start, end);
      list.push(this.buildAnnotation(blockId, start, end, text, -1, '', 'wavy'));
      this.commitAnnotations(list);
      this.toast('已添加波浪线');
      return;
    }
    // sysselect：该块进入"系统选择模式"（恢复系统原生长按菜单，方便复制 / 翻译 / 唤起小艺）
    if (action === 'sysselect') {
      this.systemSelectBlock = blockId;
      this.toast('长按文字可复制 / 翻译 / 唤起小艺；点一下正文退出');
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
      this.toast('这一段没有批注');
      return;
    }
    this.commitAnnotations(kept);
    this.toast('已清除 ' + removed + ' 条批注');
  }

  private commitAnnotations(list: MdAnnotation[]): void {
    this.annotations = list;
    this.renderEpoch++;
    const ctx = this.ctx();
    if (ctx !== null) {
      AnnotationStore.save(ctx, this.docName, list);
    }
  }

  /** 批注输入框的保存。 */
  private saveNoteDraft(): void {
    if (this.pendingStart < 0) {
      this.sheetVisible = false;
      return;
    }
    const draft: string = this.noteDraft.trim();
    const list: MdAnnotation[] = this.withoutOverlap(this.annotations, this.pendingBlockId,
      this.pendingStart, this.pendingEnd);
    list.push(this.buildAnnotation(this.pendingBlockId, this.pendingStart, this.pendingEnd,
      this.noteQuote, this.pendingColor, draft, ''));
    this.commitAnnotations(list);
    this.pendingStart = -1;
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.sheetVisible = false;
    });
    this.toast('已添加批注');
  }

  private deleteAnnotation(ann: MdAnnotation): void {
    const kept: MdAnnotation[] = [];
    for (let k = 0; k < this.annotations.length; k++) {
      if (this.annotations[k].id !== ann.id) {
        kept.push(this.annotations[k]);
      }
    }
    this.commitAnnotations(kept);
    this.toast('已删除批注');
  }

  /** 按块 id 跳转；正文被改过导致找不到时给出提示而不是静默失败。 */
  private jumpToBlockId(blockId: string): void {
    const index: number = this.blockIndexOf(blockId);
    if (index < 0) {
      this.toast('这段正文已被修改，位置已失效');
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
      const content: string = DocStore.readText(ctx, DocStore.find(ctx, this.docName)!);
      ExportService.exportHtmlSmart(ctx, this.docName, content, (m: string) => {
        this.toast(m);
      });
    } catch (err) {
      this.toast('导出失败');
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
        this.toast('已导出 HTML');
      } catch (err) {
        this.toast('写入文件失败');
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
    // 只读文档：勾选**不写盘**（只改内存态供演示，重载后还原）——
    // 与内置教程原来的演示行为一致。
    if (this.docReadOnly) {
      this.blocks[idx].task = done ? MdTaskState.Todo : MdTaskState.Done;
      this.renderEpoch++;
      this.toast(done ? '已取消勾选（只读文档，不写盘）' : '已完成（只读文档，不写盘）');
      return;
    }
    if (this.docBuiltin) {
      this.blocks[idx].task = done ? MdTaskState.Todo : MdTaskState.Done;
      this.renderEpoch++;
      this.toast(done ? '已取消勾选（演示状态，重载后还原）' : '已完成（演示状态，重载后还原）');
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
      const text: string = DocStore.readText(ctx, meta);
      const lines: string[] = text.split('\n');
      const lineNo: number = block.srcLine;
      if (lineNo < 0 || lineNo >= lines.length) {
        this.toast('无法定位原文行');
        return;
      }
      const line: string = lines[lineNo];
      const at: number = line.indexOf('[ ]');
      if (at >= 0) {
        lines[lineNo] = line.substring(0, at) + '[x]' + line.substring(at + 3);
      } else {
        const atLower: number = line.indexOf('[x]');
        const atUpper: number = line.indexOf('[X]');
        const atX: number = atLower >= 0 && (atUpper < 0 || atLower < atUpper) ? atLower : atUpper;
        if (atX < 0) {
          this.toast('无法定位勾选框');
          return;
        }
        lines[lineNo] = line.substring(0, atX) + '[ ]' + line.substring(atX + 3);
      }
      DocStore.update(ctx, this.docName, lines.join('\n'));
      this.skipRestoreOnce = true;
      this.loadDoc();
      this.toast(done ? '已取消勾选' : '已完成');
    } catch (err) {
      this.toast('勾选失败：' + DocStore.describeError(err as BusinessError));
    }
  }

  // ══════════════════════ 站内锚点 ══════════════════════

  /** `[文字](#标题)`：按标题文本匹配大纲并跳转（忽略空白、大小写与常见标点）。 */
  private jumpToAnchor(href: string): void {
    const raw: string = href.startsWith('#') ? href.substring(1) : href;
    const target: string = normalizeAnchor(decodeURIComponent(raw));
    if (target.length === 0) {
      return;
    }
    for (let k = 0; k < this.docOutline.length; k++) {
      if (normalizeAnchor(this.docOutline[k].text) === target) {
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
      this.jumpTo(hits[0]);
    }
  }

  private stepSearch(delta: number): void {
    const total: number = this.searchHits.length;
    if (total === 0) {
      this.toast('没有匹配的内容');
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
    this.jumpTo(this.searchHits[next]);
  }

  private searchLabel(): string {
    if (this.searchHits.length === 0) {
      return this.searchQuery.trim().length > 0 ? '无匹配' : '';
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
   * 大屏/横屏判定（原：根宽 ≥700vp 启用左右停靠三栏）。
   * **用户要求（2026-09-30）：仅竖屏与手机端界面一致**——
   * 竖屏（含平板竖屏）恒为侧滑抽屉；横屏且根宽 ≥700vp 才启用停靠三栏。
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
   * 首屏占位条目高度：让开状态栏 + 悬浮胶囊，多标签时再让开标签栏，
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
    this.getUIContext().animateTo(this.animateParam(), () => {
      if (kind === 'toc') {
        this.tocPinned = !this.tocPinned;
      } else {
        this.notesPinned = !this.notesPinned;
      }
    });
  }

  private closePinned(kind: string): void {
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

  private animateParam(): AnimateParam {
    const param: AnimateParam = { duration: 260, curve: Curve.FastOutSlowIn };
    return param;
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
      this.getUIContext().animateTo(this.animateParam(), () => {
        this.tocPinned = !this.tocPinned;
      });
      return;
    }
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.notesOpen = false;
      this.tocOpen = true;
    });
  }

  private openNotes(): void {
    // 大屏/横屏：注释固定停靠在右侧
    if (this.isWide()) {
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
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.sheetVisible = false;
    });
  }

  private jumpTo(blockIndex: number): void {
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
    if (current.length > 0) {
      this.activeHeading = current;
    } else if (this.docOutline.length > 0) {
      this.activeHeading = this.docOutline[0].text;
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

      Column({ space: 1 }) {
        Text(this.docName.length > 0 ? this.docName : '未命名文档')
          .fontSize(HwType.label)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.palette().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.activeHeading.length > 0 ? this.activeHeading : '右滑目录 · 左滑注释')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      .padding({ left: HwSpace.xs, right: HwSpace.xs })

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

      TextInput({ text: this.searchQuery, placeholder: '在本文中查找' })
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

  /** 收藏 / 取消收藏（信息卡右上角爱心）。 */  private toggleStar(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const next: boolean = !this.docStarred;
    if (DocStore.setStarred(ctx, this.docName, next)) {
      this.docStarred = next;
      this.toast(next ? '已收藏' : '已取消收藏');
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
    if (this.activeSheet === 'tabMenu') {
      return this.tabMenuFor;
    }
    if (this.activeSheet === 'bright') {
      return '亮度与主题';
    }
    if (this.activeSheet === 'export') {
      return '导出与分享';
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
    return '';
  }

  /** 按 activeSheet 渲染对应面板内容。 */
  @Builder
  currentSheet() {
    if (this.activeSheet === 'settings') {
      this.settingsSheet()
    } else if (this.activeSheet === 'note') {
      this.noteSheet()
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
    } else if (this.activeSheet === 'more') {
      this.moreSheet()
    }
  }

  @Builder
  settingsSheet() {
    Scroll() {
      Column() {
        ReadingSettingsPanel({ showReadingHints: true, showHeader: false })
      }
      .width('100%')
      .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.lg })
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
  }

  @Builder
  noteSheet() {
    Column() {
      this.notePanel()
    }
    .width('100%')
    .padding(HwSpace.lg)
    .id('shNote_' + this.sheetEpoch)
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

  /** 标签长按菜单（对应桌面版的右键菜单；路径类操作在沙箱手机上无对应物，未列入）。标题栏由 ModalSheet 官方标题区提供。 */
  @Builder
  tabMenuPanel() {
    Column({ space: HwSpace.xs }) {
      ImmersiveChip({
        palette: this.palette(),
        chipLabel: '关闭此标签',
        chipOnTap: () => {
          this.closeTab(this.tabMenuFor);
        }
      })
      ImmersiveChip({
        palette: this.palette(),
        chipLabel: '关闭其他标签',
        chipOnTap: () => {
          this.closeOtherTabs(this.tabMenuFor);
        }
      })
      ImmersiveChip({
        palette: this.palette(),
        chipLabel: '关闭全部标签',
        chipOnTap: () => {
          this.closeAllTabs();
        }
      })
      ImmersiveChip({
        palette: this.palette(),
        chipLabel: '重新加载此文档',
        chipOnTap: () => {
          this.reloadActiveDoc();
        }
      })

      Text('复制路径 / 打开所在文件夹是桌面端能力，应用沙箱内无对应概念')
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
          // ── 收藏爱心（用户要求：信息卡右上角，点击变红表示已收藏）──
          Row() {
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
                coverBadge: this.docBuiltin ? '内置教程' : '澄笺',
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
            Text('字数 ' + this.docWordCount)
              .fontSize(HwType.caption)
              .fontColor(this.palette().textSecondary)
              .padding({ left: 9, right: 9, top: 3, bottom: 3 })
              .borderRadius(HwRadius.pill)
              .backgroundColor(this.palette().quoteBg)
            Text('标题 ' + this.docHeadingCount)
              .fontSize(HwType.caption)
              .fontColor(this.palette().textSecondary)
              .padding({ left: 9, right: 9, top: 3, bottom: 3 })
              .borderRadius(HwRadius.pill)
              .backgroundColor(this.palette().quoteBg)
            Text('代码块 ' + this.docCodeCount)
              .fontSize(HwType.caption)
              .fontColor(this.palette().textSecondary)
              .padding({ left: 9, right: 9, top: 3, bottom: 3 })
              .borderRadius(HwRadius.pill)
              .backgroundColor(this.palette().quoteBg)
            Text('批注 ' + this.annotations.length)
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
              Text('文件大小')
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
              Blank()
              Text(this.fileSizeLabel())
                .fontSize(HwType.caption)
                .fontColor(this.palette().textSecondary)
            }
            .width('100%')

            // MD5（用户要求保留显示；「文件哈希」行已按要求删除）
            Row({ space: HwSpace.xs }) {
              Text('MD5')
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
              Text(this.docMd5.length > 0 ? this.docMd5 : '—')
                .fontSize(HwType.caption)
                .fontColor(this.palette().textSecondary)
                .layoutWeight(1)
                .textAlign(TextAlign.End)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            // 创建 / 修改日期（用户要求；内置文档没有独立创建时间，显示 —）
            Row({ space: HwSpace.xs }) {
              Text('创建日期')
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
              Blank()
              Text(Reader.timeLabel(this.docCreatedAt))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textSecondary)
            }
            .width('100%')

            Row({ space: HwSpace.xs }) {
              Text('修改日期')
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

          Text('右滑目录 · 左滑注释 · 底部工具条可调字号与亮度 · 长按选中可荧光笔/批注')
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
              this.openToc();
            }
          }) {
            SymbolGlyph($r('sys.symbol.list_bullet'))
              .fontSize(17)
              .fontColor([this.palette().textPrimary])
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
        Text(this.brightLevel <= 0 ? '跟随系统' : Math.round(this.brightLevel * 100) + '%')
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
        Text('屏幕常亮')
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
        Text('读写 / 只读')
          .fontSize(HwType.label)
          .fontColor(this.palette().textPrimary)
          .layoutWeight(1)
        ImmersiveChip({
          palette: this.palette(),
          chipLabel: '可写',
          chipActive: !this.docReadOnly,
          chipOnTap: () => {
            this.toggleDocReadOnly(false);
          }
        })
        ImmersiveChip({
          palette: this.palette(),
          chipLabel: '只读',
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
        : '可写：正文可以在编辑页里修改')
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
        .width('100%')

      // ── 大屏 / 平板横屏专属（用户要求）：侧边栏「默认展开」偏好 ──
      // 只在宽屏（横屏且根宽 ≥700）显示；竖屏与手机端是侧滑抽屉，没有这个概念。
      // 改动立即生效（当前会话）并持久化（下次打开文档按此默认）。
      if (this.isWide()) {
        Column({ space: HwSpace.sm }) {
          Row({ space: HwSpace.xs }) {
            Column({ space: 2 }) {
              Text('目录侧边栏默认展开')
                .fontSize(HwType.label)
                .fontColor(this.palette().textPrimary)
              Text('进入阅读时目录停靠在左侧；运行中仍可手动收放')
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
              Text('批注侧边栏默认展开')
                .fontSize(HwType.label)
                .fontColor(this.palette().textPrimary)
              Text('进入阅读时批注停靠在右侧；运行中仍可手动收放')
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

      // ── 主磁贴：等宽平铺（用户要求）──
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
      }
      .width('100%')

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
            this.toast(on ? '已显示信息卡' : '已隐藏信息卡');
          }
        })
      }
      .width('100%')

      Row({ space: HwSpace.xs }) {
        this.moreTile('重新加载', $r('sys.symbol.arrow_counterclockwise'), (): void => {
          this.loadDoc();
          this.toast('已重新加载');
        })
        ReaderFlagTile({
          kind: 'drawer',
          palette: this.palette(),
          onChanged: (on: boolean) => {
            this.toast(on ? '侧边栏已开启沉浸光感' : '侧边栏改用阅读背景色');
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
            this.toast(on ? '标签栏已移到底部悬浮栏上方' : '标签栏已移回顶部');
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
        this.toast('文档不存在');
        return;
      }
      const text: string = DocStore.readText(ctx, meta);
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.toast('已复制全文（' + text.length + ' 字）');
      }).catch(() => {
        this.toast('复制失败');
      });
    } catch (err) {
      this.toast('复制失败');
    }
  }

  private openBright(): void {
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
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.activeSheet = 'more';
      this.sheetVisible = true;
    });
  }

  /** 导出面板：HTML / MD / 分享。 */
  private openExport(): void {
    this.getUIContext().animateTo(this.animateParam(), () => {
      this.activeSheet = 'export';
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
              Text('目录')
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
              chipLabel: '展开全部',
              chipOnTap: () => {
                this.setAllCollapsed(false);
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '折叠到二级',
              chipOnTap: () => {
                this.setAllCollapsed(true);
              }
            })
          }
          .width('100%')

          // ── 大纲滚动区：头部固定，只有这里滚动。折叠/展开带动画 ──
          Scroll() {
            if (this.docOutline.length === 0) {
              Text('这份文档没有标题，无法生成目录。')
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
        panelPlainColor: this.readerBgColor()
      }) {
        Column({ space: HwSpace.md }) {
          // 标题**左上角**、关闭按钮右上角：同一行，标题占满剩余宽度
          Row({ space: HwSpace.sm }) {
            Column({ space: 2 }) {
              Text('注释与批注')
                .fontSize(HwType.label + 3)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.palette().textPrimary)
              Text(this.annotations.length + ' 条批注 · ' + this.notes.length + ' 条脚注')
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

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

          // ── 我的批注 ──
          if (this.annotations.length > 0) {
            Text('我的批注')
              .fontSize(HwType.label)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.palette().textSecondary)
              .width('100%')
              .padding({ top: HwSpace.xs })

            ForEach(this.annotations, (ann: MdAnnotation) => {
              Column({ space: HwSpace.xs }) {
                Row({ space: HwSpace.xs }) {
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
                  Text('第 ' + (this.blockIndexOf(ann.blockId) + 1) + ' 段')
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textTertiary)
                    .layoutWeight(1)
          // **手写批注：查看手写图**（用户要求，点开进放大浮层，可缩放 / 旋转）
          if (ann.note.startsWith('hw:')) {
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '查看',
              chipOnTap: () => {
                this.openHandwriteAnno(ann);
              }
            })
          }
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: '删除',
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

                Text(ann.text)
                  .fontSize(HwType.label)
                  .fontColor(this.palette().textPrimary)
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')

                if (ann.note.length > 0) {
                  Text(ann.note.startsWith('hw:') ? '手写批注（点「查看」看手写图）' : ann.note)
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textSecondary)
                    .lineHeight(HwType.caption * 1.6)
                    .width('100%')
                }
              }
              .width('100%')
              .padding(HwSpace.sm)
              .borderRadius(HwRadius.inner)
              // **不透明卡片**（用户反馈：半透明看不清底下正文）——按深浅给实色
              .backgroundColor(this.isDark() ? '#FF2B2F38' : '#FFF6F3EC')
              .border({
                width: { left: 3 },
                color: { left: ann.color >= 0 ? annotationColor(ann.color, this.isDark()) : this.palette().divider }
              })
              .onClick(() => {
                this.jumpToBlockId(ann.blockId);
              })
              // **删除淡出**（用户要求）：配 animateTo 的数组变更，其余卡片滑动补位
              .transition(TransitionEffect.OPACITY.animation({ duration: 240, curve: Curve.FastOutSlowIn }))
            }, (ann: MdAnnotation) => 'ann_' + ann.id)
          }

          Text('脚注')
            .fontSize(HwType.label)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().textSecondary)
            .width('100%')
            .padding({ top: HwSpace.xs })

          if (this.notes.length === 0) {
            Text('在正文里用 [^标签] 引用、用 [^标签]: 内容 定义，注释就会出现在这里。语法教程第 10 节有示例。')
              .fontSize(HwType.label)
              .fontColor(this.palette().textTertiary)
              .lineHeight(HwType.label * 1.7)
              .width('100%')
          } else {
            ForEach(this.notes, (note: MdNote) => {
              Column({ space: HwSpace.xs }) {
                Row({ space: HwSpace.xs }) {
                  Text('[' + note.no + ']')
                    .fontSize(HwType.caption)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.palette().accent)
                  Text(note.label)
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textTertiary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)

                Text(note.text)
                  .fontSize(HwType.label)
                  .fontColor(this.palette().textSecondary)
                  .lineHeight(HwType.label * 1.7)
                  .width('100%')
              }
              .width('100%')
              .padding(HwSpace.sm)
              .borderRadius(HwRadius.inner)
              .backgroundColor(this.palette().quoteBg)
              .border({ width: { left: 3 }, color: { left: this.palette().accent } })
              .onClick(() => {
                this.jumpTo(note.blockIndex);
              })
            }, (note: MdNote, index: number) => 'n' + index + '_' + note.no)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
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
  }

  /**
   * 工具栏「编辑」：直接进编辑页快速改这篇 md。
   * **判据只看「只读」标记**（用户要求：可写就是能编辑、只读才不给编辑）——
   * 之前这里按 docBuiltin 挡掉内置教程，即使把它切成「可写」也进不去编辑页。
   */
  private openEditorFromBar(): void {
    if (this.docReadOnly) {
      this.toast('该文档是只读的，先在「更多」里切成「可写」');
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
      this.toast('打不开编辑页');
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
        onOneDone: () => {
          // 只递增**图表就绪信号**：仅图表 / 公式条目重建（换成缓存图），
          // 正文其它条目不受影响 —— 避免整树重建造成的闪烁
          this.chartReadyTick++;
        }
      })

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
              // 内缘分隔线：既是视觉提示，也是拖拽热区
              .border({ width: { right: 1 }, color: this.palette().divider })
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

            ForEach(this.blocks, (block: MdBlock) => {
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
                    taskToggleHandler: (blockId: string) => {
                      this.onTaskToggle(blockId);
                    },
                    enlargeHandler: (mode: string, payload: string, geoKey: string, title: string) => {
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
                        this.enlargePayload = pl;
                        this.enlargeGeo = geoKey;
                        this.enlargeTitle = title;
                        // 每次打开生成唯一 Web id：导出图片快照按它定位；
                        // 唯一化也避免与正文/池子的 Web 组件 id 撞车
                        this.enlargeWebId = 'enlarge_' + Date.now();
                        this.enlargeWebMounted = true;
                        this.enlargeRefitTick = 0;
                        AppStorage.setOrCreate('readerOverlayOpen', true);
                      });
                    },
                    webTouchHandler: (down: boolean) => {
                      this.webTouchDepth = Math.max(0, this.webTouchDepth + (down ? 1 : -1));
                    },
                    imageTapHandler: (key: string, src: string) => {
                      this.openZoomImage(key, src);
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
                  const ck: string = ChartCache.keyFor(mode, block.code, this.isDark());
                  const c: common.UIAbilityContext | null = this.ctx();
                  const ready: boolean =
                    c !== null && ChartCache.path(c, ck).length > 0;
                  return block.id + '_' + this.docName + '_' + ck
                    + (tick >= 0 ? (ready ? '_r' : '_p') : '_p');
                }
                return block.id + '_' + this.docName + '_' + this.renderEpoch;
              })

            ListItem() {
              Text('—— 文档结束 ——')
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
          // **主题纪元也拼在 List 容器上**（关键修复）：
          // 只改条目的 key 不够——已挂载的 ListItem / 其中的按钮是由列表**复用**的，
          // 换容器的 key 才会把整段正文真正重建一遍（用户反馈：正文前段、部分按钮
          // 切换深浅后不变色，就是因为它们是被复用的那一批）。
          .key('readerBody_' + this.themeEpoch)

          // 大屏/横屏：注释停靠右侧（正文列与目录列之间），宽度同样可调
          if (this.isWide() && this.notesPinned) {
            Column() {
              this.notesDrawer(true)
            }
            .width(this.notesPanelWidth)
            .height('100%')
            .margin({ right: HwSpace.xs })
            .border({ width: { left: 1 }, color: this.palette().divider })
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

      // ── 悬浮顶栏：一个胶囊，宽度插值；展开/收起内容用 if 切换，
      //    同一时刻只有一层，杜绝「两层叠加 + 内容溢出胶囊」的错位。──
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          Row() {
            this.topBar()
          }
          .width('100%')

          if (this.topBarVisible && this.tabs.length > 1 && !this.tabBarAtBottom) {
            // 占位：标签栏在下方独立的「标签栏层」里（没有左右 padding，
            // 视口横跨整屏，出血才对称）；这里只占住高度，让查找条位置不变。
            // 标签栏置底时不需要占位（下方也没有标签栏）。
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
      .key('readerTopLayer_' + this.themeEpoch)

      // ── 标签栏层：与顶栏 Stack **平级**、没有左右 padding ——
      // Scroll 的 '100%' 就是整屏宽，标签的出现 / 消失点天然落在屏幕边缘。
      // **标签栏置底时这一层不渲染**（改挂在下面「悬浮底栏」那一层里）。
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.topBarVisible && this.tabs.length > 1 && !this.tabBarAtBottom) {
          this.tabBar()
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.padTop() + HwBar.pill })
      .hitTestBehavior(HitTestMode.Transparent)

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
      .key('readerBottomLayer_' + this.themeEpoch)

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
          this.toast('已恢复批注菜单');
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
              ImmersiveIconButton({
                buttonSize: 34,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  // 关闭也要包 animateTo：卸载浮层时一镜到底才能反向播放
                  this.getUIContext().animateTo({ duration: 280, curve: Curve.FastOutSlowIn }, () => {
                    this.enlargeMode = '';
                    this.enlargeGeo = '';
                    this.enlargeTitle = '';
                  });
                  this.rotated = false;
                  this.webZoom = 1;
                  // **必须清掉叠加层标志**：否则返回键拦截会一直生效，
                  // 侧滑返回就"失灵"了（用户实测）
                  AppStorage.setOrCreate('readerOverlayOpen', false);
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
                      GestureGroup(GestureMode.Parallel,
                        PanGesture({ fingers: 2, distance: 1 })
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
                    dark: this.isDark(),
                    zoom: true,
                    fit: true,
                    fillHeight: true,
                    webZoom: this.webZoom,
                    onWebTouch: (down: boolean) => {
                      this.webTouchDepth = Math.max(0, this.webTouchDepth + (down ? 1 : -1));
                    }
                  })
                }
              }
              .width(this.rotated ? this.canvasH : '100%')
              .height(this.rotated ? this.canvasW : '100%')
              .borderRadius(HwRadius.card)
              .backgroundColor(this.palette().codeBlockBg)
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
      // 竖屏（含平板竖屏）按手机形态出底部面板；平板竖屏宽度收一半
      phoneLayout: this.rootWidth <= this.rootHeight,
      screenWidth: this.rootWidth,
      onDismiss: () => {
        // dismiss 完成后才清内容标识：关闭动画期间面板保持原内容（避免白板）
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
        // 大屏：横扫开合被禁用（停靠列用顶栏按钮开合），
        // 但**拖分隔条调宽**仍走这根手势——priorityGesture 优先级最高，
        // 正好独占横向拖动，不会和正文滚动/停靠面板打架。
        .onActionStart((event: GestureEvent) => {
          this.sideDrag = '';
          if (!this.isWide()) {
            return;
          }
          // GestureEvent 本体没有窗口坐标，从 fingerList 里取第一根手指的位置
          if (event.fingerList.length === 0) {
            return;
          }
          const x: number = event.fingerList[0].globalDisplayX;
          const tocEdge: number = HwSpace.xs + this.tocPanelWidth;
          const notesEdge: number = this.rootWidth - HwSpace.xs - this.notesPanelWidth;
          if (this.tocPinned && Math.abs(x - tocEdge) <= 18) {
            this.sideDrag = 'toc';
            this.sideDragStartWidth = this.tocPanelWidth;
            this.sideDragBaseX = x;
          } else if (this.notesPinned && Math.abs(x - notesEdge) <= 18) {
            this.sideDrag = 'notes';
            this.sideDragStartWidth = this.notesPanelWidth;
            this.sideDragBaseX = x;
          }
        })
        .onActionUpdate((event: GestureEvent) => {
          if (this.sideDrag.length === 0 || event.fingerList.length === 0) {
            return;
          }
          const x: number = event.fingerList[0].globalDisplayX;
          const delta: number = x - this.sideDragBaseX;
          if (this.sideDrag === 'toc') {
            // 拖拽调宽的上限与 drawerWidth() 的上限一致，避免面板比滑入数学宽出错位
            this.tocPanelWidth = Math.max(220, Math.min(this.drawerWidth(), this.sideDragStartWidth + delta));
          } else if (this.sideDrag === 'notes') {
            this.notesPanelWidth = Math.max(220, Math.min(this.drawerWidth(), this.sideDragStartWidth - delta));
          }
        })
        .onActionEnd((event: GestureEvent) => {
          this.sideDrag = '';
          const dx: number = event.offsetX;
          // 按触点分区（用户要求）：起点在屏幕偏左 → 这一次滑动只管目录；
          // 起点在屏幕偏右 → 只管注释与批注。避免两边互相抢手势。
          // GestureEvent 本体没有窗口坐标，从 fingerList 里取第一根手指的屏幕绝对 X
          // （与本侧滑手势其它回调里的 globalDisplayX 同一口径）
          // globalDisplayX 是 number | undefined：先落局部常量再收窄（ArkTS 规则）
          let startX: number = 0;
          if (event.fingerList.length > 0) {
            const gx: number | undefined = event.fingerList[0].globalDisplayX;
            if (gx !== undefined) {
              startX = gx;
            }
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

  /** 文字批注输入面板的内容（标题栏由 ModalSheet 官方标题区提供）。 */
  @Builder
  notePanel() {
    Column({ space: HwSpace.md }) {
        Column() {
          Text('「' + this.noteQuote + '」')
            .fontSize(HwType.label)
            .fontColor(this.palette().textSecondary)
            .lineHeight(HwType.label * 1.7)
            .width('100%')
        }
        .width('100%')
        .padding(HwSpace.sm)
        .borderRadius(HwRadius.inline)
        .backgroundColor(this.palette().quoteBg)
        .border({ width: { left: 3 }, color: { left: this.palette().accent } })

        TextArea({ text: this.noteDraft, placeholder: '写下你的批注……' })
          .width('100%')
          .height(120)
          .fontSize(HwType.label)
          .fontColor(this.palette().textPrimary)
          .placeholderColor(this.palette().textTertiary)
          .backgroundColor(this.palette().quoteBg)
          .borderRadius(HwRadius.inner)
          .onChange((value: string) => {
            this.noteDraft = value;
          })

        Row({ space: HwSpace.sm }) {
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: '取消',
            chipOnTap: () => {
              this.closeNoteSheet();
            }
          })
          ImmersiveChip({
            palette: this.palette(),
            chipActive: true,
            chipLabel: '保存批注',
            chipOnTap: () => {
              this.saveNoteDraft();
            }
          })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

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

