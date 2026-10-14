/**
 * LiteMdReader · 书架（首页）
 * ============================
 *
 * 图一书架形态 + 华为笔记式拖拽归组：
 *  - 三列封面网格：新建卡 / 内置教程 / 文件夹格 / 零散文档格
 *  - **拖动封面到另一张封面上 → 合并成文件夹**；拖到文件夹格上 → 收进该文件夹
 *    （系统拖拽：长按即起拖，onDragStart / onDrop；**内置教程同样可拖可归组**）
 *  - 点文件夹格展开文件夹浮层：内部封面网格、重命名、解散、移出文档
 *  - **搜索按钮点击后原地向左展开成搜索框**（不做半模态面板），
 *    命中结果以非模态的下拉卡片列在顶栏下方，点结果直达命中处
 *  - 封面程序化绘制（DocCover），文档名哈希选色
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { componentUtils } from '@kit.ArkUI';
import {
  barFrostColor,
  CoverStyle,
  FOLDER_SPRING,
  HwBar,
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  isDarkTheme,
  paletteFor,
  READER_BG_DEFAULT_DARK,
  READER_BG_DEFAULT_LIGHT,
  withAlpha
} from '../theme/DesignTokens';
import { DocCover, coverColorsOf, coverStyleFromColor } from '../components/DocCover';
import {
  ImmersiveBar,
  ImmersiveCard,
  ImmersiveCardLayer,
  ImmersiveChip,
  ImmersiveIconButton
} from '../material/ImmersiveCard';
import { getImmersiveMaterial } from '../material/SystemMaterial';
import { modalSheetOptions, SheetKeyboardLift } from '../material/ModalSheet';
import { ExportOptionsPanel } from '../components/ExportOptionsPanel';
import { MergeExportPanel } from '../components/MergeExportPanel';
import { MergeSource } from '../service/MergeExport';
import { applySystemBarTheme, applyAppColorMode, syncSystemDarkFromContext,
  markThemeApplied, themeChangedSince, startThemeWatchdog, stopThemeWatchdog } from '../service/AppWindow';
import { WallpaperStore } from '../service/WallpaperStore';
import { DocImageHit, DocMeta, DocSearchHit, DocSearchResult, DocStore, PrintRoute, ReaderRoute, ShelfFolder } from '../service/DocStore';
import { DocLint, LintIssue, LintReport } from '../service/DocLint';
import { AnnotationStore } from '../service/AnnotationStore';
import { MdAnnotation } from '../markdown/MdTypes';
import { TaskBoard, TaskBoardResult, TaskItem } from '../service/TaskBoard';
import { ReadDoc, ReadRange, ReadingLog, readDayKey } from '../service/ReadingLog';
import { GraphResult, KnowledgeGraph } from '../service/KnowledgeGraph';
import { ReviewCard, ReviewCardStore, ReviewSeed, ReviewStats } from '../service/ReviewCard';
import { FontStore } from '../service/FontStore';
import { HeroInit, HeroRect, HeroTransition } from '../service/HeroTransition';
import { GenWallpaper } from '../theme/GenWallpaper';
import { NavLifecycle } from '../service/NavLifecycle';
import { Reader } from './Reader';
import { Editor } from './Editor';
import { Settings } from './Settings';
import { SettingsAppearance } from './SettingsAppearance';
import { SettingsData } from './SettingsData';
import { SettingsReading } from './SettingsReading';
import { SettingsWriting } from './SettingsWriting';
import { SettingsExplore } from './SettingsExplore';
import { SettingsEngines } from './SettingsEngines';
import { SettingsHelp } from './SettingsHelp';
import { Changelog } from './Changelog';
import { Sketch } from './Sketch';
import { ReviewPage } from './ReviewPage';
import { AiChat } from './AiChat';
import { AiSettings } from './AiSettings';
import { HtmlViewer } from './HtmlViewer';
import { GripAware } from '../service/GripAware';
import { LegalDoc, LegalDocRoute } from './LegalDoc';
import { UpdateService, APP_MODE_FULL, APP_MODE_OFFLINE } from '../service/UpdateService';
import { ChangelogEntry, latestChangelog } from '../service/Changelog';
import { UpdateContentDialog } from '../components/UpdateContentDialog';
import { AppModeDialog } from '../components/AppModeDialog';
import { SettingsMirror } from '../service/SettingsMirror';
import { uniformDataStruct, uniformTypeDescriptor } from '@kit.ArkData';
import { L10n } from '../service/L10n';

// ══════════════ 模块级常量（⚠️ 必须位于**全部 import 之后**）══════════════
// ArkTS 硬性规则：import 必须全部在文件顶部；夹在 import 之间声明 interface / const
// 会报 `arkts-no-misplaced-imports`（本文件已因此报错过一次）。

/** 文档模板（批 4：模板库）。`## 标题` 让目录开箱可用，`- [ ]` 让待办功能有内容。 */
interface DocTemplate {
  name: string;
  body: string;
}

const DOC_TEMPLATES: DocTemplate[] = [
  {
    name: L10n.t('读书笔记'),
    body: '# 《书名》\n\n- 作者：\n- 读完日期：\n\n## 核心论点\n\n1. \n\n'
      + '## 摘录\n\n> \n\n## 我的思考\n\n- [ ] 提炼一句话总结\n'
  },
  {
    name: L10n.t('会议记录'),
    body: '# 会议记录\n\n- 时间：\n- 参会：\n\n## 议题\n\n1. \n\n## 结论\n\n- \n\n## 待办\n\n- [ ] \n'
  },
  {
    name: L10n.t('周报'),
    body: '# 周报\n\n## 本周完成\n\n- [x] \n\n## 下周计划\n\n- [ ] \n\n## 风险与需要支持\n\n- \n'
  },
  {
    name: L10n.t('康奈尔笔记'),
    body: '# 主题\n\n| 线索 / 问题 | 笔记 |\n| --- | --- |\n|  |  |\n\n## 总结\n\n'
  },
  {
    name: L10n.t('每日复盘'),
    body: '# 复盘\n\n## 今天做成了什么\n\n- \n\n## 卡在哪里\n\n- \n\n## 明天第一件事\n\n- [ ] \n'
  },
  {
    // 这个模板是**给批注与复习卡片练手**用的：新建出来是可编辑的自建文档，
    // 可以自由划荧光笔、写批注，再去看「批注汇总」「复习卡片」的效果。
    name: L10n.t('复习素材'),
    body: '# 复习素材\n\n'
      + '> 用自己的话复述一遍，划上荧光笔或加上批注；'
      + '再到书架「⋯ → 批注汇总 / 复习卡片」看效果。\n\n'
      + '## 一句话概念\n\n'
      + '- ：\n'
      + '- ：\n'
      + '- ：\n\n'
      + '## 容易混的点\n\n'
      + '- 与 的区别：\n'
      + '- 与 的区别：\n\n'
      + '## 还没弄懂的\n\n'
      + '- [ ] \n'
  }
];

/** 搜索结果下拉面板最多显示的条数（更多提示用底部说明） */
const SEARCH_PANEL_MAX: number = 20;

/** 重命名面板按钮配色（用户指定：取消蓝、保存绿）。 */
const RENAME_CANCEL_COLOR: string = '#FF2A6FD6';
const RENAME_SAVE_COLOR: string = '#FF2F9E5F';

/** 搜索结果「图片」组：缩略图边长（vp） */
const SEARCH_IMAGE_THUMB: number = 56;

/** 书架底栏胶囊内「新建 / 导入」按钮的直径（vp），不能超过胶囊内高（52 - 8 = 44） */
const NEW_BTN_SIZE: number = 36;

/**
 * 展开文件夹时**先滚到位、再撑开**的一拍间隔（ms）。
 *
 * 从前是「撑开 → scrollToIndex(AUTO) → 220ms 后再 correctPanelScroll 补一滚」，
 * 两段滚动中间隔 220ms，肉眼看到的就是**蹲一下然后跳动**（书架上有「继续阅读」
 * 横幅时网格更高、面板顶边更靠下，第一滚幅度大，跳动感尤其强）。
 * 现在开面板这一拍只滚一次（最小滚动），之后高度动画只负责往下撑，全程无二次滚动。
 */
const FOLDER_SCROLL_SETTLE: number = 60;

/**
 * 展开文件夹时那次自动滚动的时长（ms）。
 *
 * 用 `scrollTo` 的 animation.duration 显式指定：SDK 自带的 `scrollToIndex(smooth=true)`
 * 是**固定短时长**跑完全程，跨几屏时快到像"甩"过去（用户反馈"滑动的太快了"）。
 * 曲线用 FOLDER_SPRING —— 与展开动画同一支，滑动与撑开同步收放。
 */
const FOLDER_GLIDE_MS: number = 420;

/**
 * 封面可选底色（只存这一个基色，明暗渐变与文字墨色由 coverStyleFromColor 自动推）。
 * 取自传统纸墨色的中低饱和区间，压在沉浸光感下不会发飘。
 */
const COVER_COLORS: string[] = [
  '#5B7FBF', '#4E8E7E', '#B4813C', '#A85454',
  '#7B6BA8', '#4E7E9B', '#8A8F98', '#C08A6A'
];

/** 文件夹封面在窗口中的矩形（打开/收起动画要与它完全重合） */
interface CoverRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/**
 * 书架网格的一项：文件夹格或松散文档格。
 * **文件夹与文档排在同一条流里**（顺序见 DocStore.shelfOrder），
 * 所以拖拽能让「文件夹 ↔ 文档」也互换位置。
 */
interface ShelfItem {
  /** 'folder' | 'doc' */
  kind: string;
  name: string;
  folder: ShelfFolder | null;
  meta: DocMeta | null;
}

@Entry
@Component
struct Index {
  @StorageLink('readerThemeMode') @Watch('onThemeModeChanged') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /**
   * 主题纪元：系统深浅 / 应用主题一变就自增，并**拼进根节点的 key**（见 build 末尾）。
   * 用户反馈：切系统深浅后当前页只更新一部分（要进别的页面才完全刷新）——
   * 只改 AppStorage 值不足以让材质、壁纸、派生色整棵树重算；
   * 换 key 会强制重建整棵组件树，一次刷新到位（key 必须是随主题变化的量，不能是常量）。
   * 拼在根节点上还能正常逐帧过渡（新老节点各渲染一帧，不会闪空白）。
   */
  @State themeEpoch: number = 0;
  /** 标签筛选：空 = 全部；非空 = 只显示带该标签的文档 */
  @State tagFilter: string = '';
  /** 语言切换计数：变更时整页重建（key 拼接），文案随词典刷新 */
  @StorageProp('languageTick') languageTick: number = 0;
  /** 智感握姿：-1 左手 / 0 未知或居中 / 1 右手 */
  @State gripSide: number = 0;
  /** 沉浸布局下的状态栏 / 手势条避让高度（px） */
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  @StorageProp('safeBottomPx') safeBottomPx: number = 0;
  /** 壁纸三键（作为重渲染订阅点；取色由 WallpaperStore 统一算） */
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
  /** AI 后台生成完成的新事件计数（>0 时书架 AI 入口显示官方 Badge 角标） */
  @StorageProp('aiNewReply') aiNewReply: number = 0;

  @State docs: DocMeta[] = [];
  @State folders: ShelfFolder[] = [];
  /** 启动页：首帧即显，1.2s 后淡出移除（竹影底 + foreground 图标 + ChéngJiān） */
  @State splashOn: boolean = true;
  @State splashOpacity: number = 1;
  /**
   * 网格的渲染顺序（文件夹 + 松散文档混排，见 DocStore.shelfOrder）。
   * 由 refresh() 统一构建——build/ForEach 期间只读，不写。
   */
  @State items: ShelfItem[] = [];
  /** 收藏文档（悬浮栏爱心按钮的快速查看列表） */
  @State starredDocs: DocMeta[] = [];
  /** 收藏列表排序：'starred' 最近收藏 / 'recent' 最近打开 / 'name' 按名称 */
  @State starSort: string = 'starred';
  /** 当前格子菜单对象的收藏状态（选择操作面板里的「收藏 / 取消收藏」） */
  @State cellMenuStarred: boolean = false;
  /** 复习卡片墙（批 3）：当前批次卡片、当前下标、是否已翻面看批注 */
  @State reviewCards: ReviewCard[] = [];
  @State reviewIndex: number = 0;
  @State reviewFlipped: boolean = false;
  /** 全部待办（批 2 改进）：面板里可滑动的完整列表 + 顶部摘要 */
  @State taskItems: TaskItem[] = [];
  @State taskSummary: string = '';
  /**
   * 勾选框点击的"闸门"：`ClickEvent` 没有 `stopPropagation()`，父容器的 onClick
   * 拦不住子组件已处理的点击。只能用**执行顺序（子先父后）+ 状态标记** ——
   * 勾选时置 true，整行 onClick 读到就复位并跳过跳转（工程既有做法）。
   */
  @State taskToggleGuard: boolean = false;
  /** 阅读轨迹：最近打开的文档（按 lastOpen 倒序，最多 20 条） */
  @State trailItems: DocMeta[] = [];
  /** 批量操作（批 5）：多选模式开关与已选文档名集合 */
  @State multiSelect: boolean = false;
  @State multiNames: string[] = [];
  /** 文件夹面板展开前的滚动偏移：收回时滑回原位（-1 = 未记录） */
  private folderRestoreY: number = -1;
  /** 当前格子菜单对象的文档编码（与阅读页共用 AppStorage 键 `docEncoding_<文档名>`） */
  @State cellMenuEncoding: string = 'auto';
  /** 半模态面板重建纪元：深浅切换时换容器 key，避免面板"切换不完全" */
  @State sheetEpoch: number = 0;
  /** 新建 / 导入后回书架：这次刷新带进场动画 */
  @State animateNextRefresh: boolean = false;
  // ── 版本更新弹窗 / 使用模式弹窗（首次使用 + 更新后首次启动）──
  @State updateTitle: string = '';
  @State updateLines: string[] = [];
  @State modeTitle: string = '选择使用模式';
  @State modeCurrent: string = '';
  updateDialog: CustomDialogController = new CustomDialogController({
    builder: UpdateContentDialog({ titleText: $updateTitle, lines: $updateLines }),
    autoCancel: false,
    customStyle: true
  });
  modeDialog: CustomDialogController = new CustomDialogController({
    builder: AppModeDialog({
      titleText: $modeTitle,
      currentMode: $modeCurrent,
      onPick: (mode: string) => {
        AppStorage.setOrCreate('appMode', mode);
        // 第二腿落盘（同 lastSeenVersion：PersistentStorage 在部分设备不可靠）
        SettingsMirror.save(this.ctx());
        this.toast(mode === APP_MODE_OFFLINE ? L10n.t('已切换为基础模式（纯离线）') : L10n.t('已切换为全量模式'));
      }
    }),
    autoCancel: false,
    customStyle: true
  });
  /** 两个一次性弹窗的会话内标记（持久化被系统吞掉时也不重复弹） */
  private modeAsked: boolean = false;
  private updateShown: boolean = false;
  @State userDocCount: number = 0;
  @State totalWords: number = 0;
  @State totalChars: number = 0;
  /** 原地展开的搜索框 */
  @State searchExpanded: boolean = false;
  @State searchQuery: string = '';
  @State searchHits: DocSearchHit[] = [];
  /** 搜索：**文件名命中**与**正文命中**分两组（用户要求分开展示） */
  @State searchNameHits: DocSearchHit[] = [];
  @State searchContentHits: DocSearchHit[] = [];
  /** 搜索：**图片文件名命中**（第三组，展示名称 + 缩略图） */
  @State searchImageHits: DocImageHit[] = [];
  /** 图片快速查看浮层：src 非空 = 打开中（点搜索结果里的图片项进入） */
  @State imgPreviewSrc: string = '';
  @State imgPreviewName: string = '';
  /** 浮层副标题：大小 · 分辨率 */
  @State imgPreviewMeta: string = '';

  /** 重命名对象类型：doc / folder */
  @State renameKind: string = 'doc';
  @State renameFrom: string = '';
  @State renameText: string = '';
  /** 封面「⋯」菜单（文档 / 文件夹共用，kind 区分） */
  /** 半模态面板鉴别：cellMenu / rename；空串 = 全关 */
  @State shelfSheet: string = '';
  /** 半模态显隐开关（与 shelfSheet 分离：关闭动画期间保留内容，避免白板） */
  @State shelfVisible: boolean = false;
  @State cellMenuKind: string = 'doc';
  @State cellMenuFor: string = '';
  @State cellMenuBuiltin: boolean = false;
  /**
   * 合并导出面板的数据（打开时刷新一遍，再换纪元重建面板 ——
   * MergeExportPanel 的 sources/preselect 只在创建那一刻读一次）
   */
  @State mergeSources: MergeSource[] = [];
  @State mergePreselect: string[] = [];
  /** 书架视图：true 网格 / false 树形（文件树形态） */
  @State treeMode: boolean = false;
  @State expandedFolders: string[] = [];
  /** iOS 6 主屏式文件夹展开：面板从被点图标正下方长出来，其余格子退到后面 */
  @State openFolderName: string = '';
  @State folderPanelOpen: boolean = false;
  /**
   * 面板是否**还挂在网格流里**（与 openFolderName 分开：收起时名字要留到动画跑完，
   * 用来压暗 / 模糊其余格子，而节点必须**立刻摘掉**）。
   * 早先收起是「高度收到 0，340ms 后再摘 GridItem」——摘的那一刻网格要再量一次布局，
   * 底部提示文本跟着**第二次上移**（"上移 → 顿一下 → 再上移"）。
   * 现在摘节点与收高度同一拍完成，提示文本在同一次动画里直接落到最终位置。
   */
  @State folderPanelMounted: boolean = false;
  /** 窗口高度（vp）：面板从图标下方一直铺到接近屏幕底部 */
  @State rootHeight: number = 800;
  /** 当前被拖动的文档名（空 = 没有拖拽） */
  @State draggingName: string = '';
  /** 合并成文件夹的动画：正在合并到哪个文档格（'' = 没有该动画） */
  @State mergingAt: string = '';
  /** 合并动画进度：外框是否已撑开（false → 缩小态） */
  /** 合并动画进度：外框是否已撑开（false → 缩小态） */
  @State mergeGrow: boolean = false;
  /** 拖拽悬停到哪一格上（该格轻微缩小，给"可以放这里"的反馈） */
  @State hoverDropAt: string = '';
  /** 被"吸入"的格子（收进文件夹 / 换位 / 解散时缩小淡出） */
  @State absorbAt: string = '';
  /** 外部文件拖到新建卡片上时，显示"释放导入"提示 */
  @State dragOverNewCard: boolean = false;
  /** 悬停满 1.5 秒的目标文档（松手 = 与它交换位置，用户要求） */
  @State swapReadyName: string = '';
  /** 当前悬停的目标（未满 1.5 秒） */
  private swapHoverTarget: string = '';
  /** 悬停计时器 */
  private swapTimer: number = -1;
  /** 函数绘制壁纸的 id（空 = 不用）；见 theme/GenWallpaper.ets */
  @StorageProp('wallpaperGenId') genWallId: string = '';
  /** 导航栈：书架是首页，阅读 / 设置 / 编辑都压在这条栈上 */
  private pathStack: NavPathStack = new NavPathStack();
  /** 页面生命周期转发（见 NavLifecycle）：NavDestination 的 onShown/onHidden 会调它 */
  private readerLife: NavLifecycle = new NavLifecycle();
  private settingsLife: NavLifecycle = new NavLifecycle();
  /** 复习页注册的系统返回拦截（刷卡形态中返回 = 回学习页签） */
  private reviewBackCb: (() => boolean) | null = null;
  /** 各文档封面的窗口矩形：打开文件时的「一镜到底」要从那一格长出来、缩回去 */
  private docRects: Map<string, CoverRect> = new Map<string, CoverRect>();
  /** 书架网格的滚动控制器：展开文件夹后自动滚到面板处 */
  private gridScroller: Scroller = new Scroller();
  /** 文档封面的「一镜到底」：docCoverName = 正在飞的封面；docCoverSlide = 向左滑走的进度 */
  @State docCoverName: string = '';
  @State docCoverHidden: boolean = false;
  @State docCoverP: number = 0;
  @State docCoverSlide: number = 0;
  /** 飞行封面用的文档属性（决定封面配色与是否内置） */
  private docCoverBuiltin: boolean = false;
  /** 刚从阅读页返回的那篇：用来播放「合上封面 + 缩回原格」的第二段动画 */
  private lastDocName: string = '';
  private coverRectX: number = 0;
  private coverRectY: number = 0;
  private coverRectW: number = 80;
  private coverRectH: number = 120;
  /** 继续阅读候选 */
  @State resumeName: string = '';
  @State resumeRatio: number = 0;
  @State resumeLastOpen: number = 0;
  /** 页面存活标记（定时器回调里判断：切走后不要再操作组件） */
  private pageAlive: boolean = true;
  /** 顶栏 / 底栏是否展开。向下滚动自动收起，向上滚动或回到顶部恢复 */
  @State barsVisible: boolean = true;
  @State rootWidth: number = 360;

  /**
   * 当前方向上累计的滚动位移（vp），超过阈值才收起顶栏
   */
  private scrollAccum: number = 0;

  aboutToAppear(): void {
    const ctx = this.ctx();
    if (ctx !== null) {
      // 用户导入的自定义字体在书架启动时就注册，正文渲染才能直接用
      FontStore.registerAll(ctx);
    }
    this.refresh();
    // ── 首次使用：先选使用模式（全量 / 基础离线）──
    this.askAppMode();
    // ── 更新后首次启动：弹一次本次更新内容（数据取自更新日志最新一条）──
    this.maybeShowUpdateDialog();
    // ── 自动检查更新：固定 48 小时一次，有更新用 toast 即时反馈 ──
    UpdateService.maybeAutoCheck(ctx, (message: string) => {
      this.toast(message);
    });
    // 启动页时序：首帧即显 → 1.2s 后开始淡出（420ms）→ 淡出结束移除
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: 420, curve: Curve.FastOutSlowIn }, () => {
        this.splashOpacity = 0;
      });
      setTimeout(() => {
        this.splashOn = false;
      }, 460);
    }, 1200);
  }

  /** 使用模式未选择时弹窗（首次使用）；选择结果写入 appMode。 */
  private askAppMode(): void {
    // **本会话只问一次**：即便持久化被系统吞掉，也不会在一次使用里重复弹
    if (this.modeAsked) {
      return;
    }
    const mode: string = UpdateService.appMode();
    if (mode.length > 0) {
      return;
    }
    this.modeAsked = true;
    this.modeTitle = '选择使用模式';
    this.modeCurrent = '';
    // **首次使用不弹更新日志**（用户要求：刚装上没有"更新"一说）：
    // 顺带把 seen 版本补成当前版本，避免下次启动再补弹。
    this.suppressUpdateDialogForFirstRun();
    setTimeout(() => {
      if (!this.pageAlive) {
        return;
      }
      this.modeDialog.open();
    }, 1600);
  }

  /**
   * 首次使用压制更新日志弹窗：标记已提示 + 记录当前版本号。
   * 这样「使用模式」先弹、且不会与更新日志同时弹出（用户要求的顺序）。
   */
  private suppressUpdateDialogForFirstRun(): void {
    const latest: ChangelogEntry = latestChangelog();
    this.updateShown = true;
    if (latest.version.length > 0) {
      AppStorage.setOrCreate('lastSeenVersion', latest.version);
      SettingsMirror.save(this.ctx());
    }
  }

  /**
   * 版本更新弹窗：**更新后首次启动弹一次**（对比最后提示过的版本号），
   * 内容直接取更新日志最新一条——发版只需维护 service/Changelog.ets，无需另写弹窗文案。
   */
  private maybeShowUpdateDialog(): void {
    if (this.updateShown) {
      return;
    }
    // 首次使用（还没选过使用模式）时，本方法什么都不做——
    // 由 askAppMode 负责压制，只有升级用户才看得到「本次更新内容」。
    if (UpdateService.appMode().length === 0) {
      return;
    }
    const latest: ChangelogEntry = latestChangelog();
    if (latest.version.length === 0) {
      return;
    }
    const seen: string | undefined = AppStorage.get<string>('lastSeenVersion');
    if (seen !== undefined && seen !== null && seen === latest.version) {
      return;
    }
    this.updateShown = true;
    AppStorage.setOrCreate('lastSeenVersion', latest.version);
    // **第二腿落盘**：PersistentStorage 在部分设备上不真正落盘（本工程既有结论），
    // 这里同步写一次 settings.json，否则每次启动都会重复弹（用户反馈）
    SettingsMirror.save(this.ctx());
    this.updateTitle = '已更新到 ' + latest.version;
    this.updateLines = latest.items;
    setTimeout(() => {
      if (!this.pageAlive) {
        return;
      }
      this.updateDialog.open();
    }, 2400);
  }

  // ── 顶栏 / 底栏收起与展开：累计位移阈值（与阅读页同一套） ──

  private toggleBars(show: boolean): void {
    if (this.barsVisible === show) {
      return;
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.barsVisible = show;
    });
  }

  /** 书架滚动是否处于顶部（顶部回弹的正偏移不触发底栏隐藏） */
  private shelfAtTop: boolean = true;

  private onScrollFrame(offset: number): void {
    if (this.searchExpanded || this.shelfSheet !== '') {
      this.toggleBars(true);
      return;
    }
    // 顶部回弹（已到顶时上滑只有动画反馈）：正偏移只是弹簧回弹，不触发隐藏
    if (this.shelfAtTop && offset > 0) {
      this.scrollAccum = 0;
      return;
    }
    if (offset > 0) {
      this.scrollAccum += offset;
      if (this.scrollAccum > 72) {
        this.scrollAccum = 0;
        this.toggleBars(false);
      }
    } else if (offset < 0) {
      this.scrollAccum = 0;
      this.toggleBars(true);
    }
  }

  // ── 搜索：按钮原地展开，不做半模态 ──

  private expandSearch(): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.searchExpanded = true;
    });
  }

  private collapseSearch(): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.searchExpanded = false;
      this.searchQuery = '';
      this.searchHits = [];
      this.searchNameHits = [];
      this.searchContentHits = [];
      this.searchImageHits = [];
    });
  }

  /**
   * 打开图片**快速查看浮层**（搜索结果「图片」组点条目）。
   *
   * 就地放大而不是"跳阅读页再定位"：图片命中只扫到文件路径、并不知道它被哪篇文档引用，
   * 就地查看既快又稳（不依赖文档上下文）。若将来要"跳到引用它的文档"，
   * 需要在 searchAll 里顺带记录引用关系。
   */
  private openImagePreview(img: DocImageHit): void {
    this.imgPreviewSrc = 'file://' + encodeURI(img.path);
    this.imgPreviewName = img.name;
    const dim: string = (img.width > 0 && img.height > 0)
      ? (img.width + ' × ' + img.height) : L10n.t('尺寸未知');
    this.imgPreviewMeta = DocStore.formatSize(img.size) + ' · ' + dim;
  }

  private closeImagePreview(): void {
    this.imgPreviewSrc = '';
    this.imgPreviewName = '';
    this.imgPreviewMeta = '';
  }

  private runShelfSearch(text: string): void {
    this.searchQuery = text;
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      const res: DocSearchResult = DocStore.searchAll(ctx, text);
      this.searchNameHits = res.names;
      this.searchContentHits = res.contents;
      this.searchImageHits = res.images;
      // 顶栏计数沿用总数（文件名命中 + 正文命中）
      this.searchHits = res.names.concat(res.contents);
    } catch (err) {
      this.searchNameHits = [];
      this.searchContentHits = [];
      this.searchImageHits = [];
      this.searchHits = [];
    }
  }

  private openSearchHit(hit: DocSearchHit): void {
    this.collapseSearch();
    const route: ReaderRoute = { name: hit.name, query: this.searchQuery.trim() };
    this.pushPage('pages/Reader', route);
  }

  // ── 菜单 / 重命名 / 文件夹 ──

  private openCellMenu(kind: string, name: string, builtin: boolean): void {
    this.cellMenuKind = kind;
    this.cellMenuFor = name;
    this.cellMenuBuiltin = builtin;
    // 打开菜单时同步该文档的收藏状态（菜单里有「收藏 / 取消收藏」）
    const c = this.ctx();
    if (c !== null) {
      this.cellMenuStarred = DocStore.isStarred(c, name);
      this.cellMenuEncoding = this.encodingOf(name);
      // 写入固定键：面板里的编码卡（EncodingChoiceCard）用 @StorageLink 订阅它
      AppStorage.setOrCreate('cellMenuEncoding', this.cellMenuEncoding);
    }
    // 打开时同步一次只读状态（后面由按钮自己维护，不再每次渲染现问数据层）
    this.cellMenuReadOnly = kind === 'doc' ? this.isDocReadOnly(name) : false;
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.shelfSheet = 'cellMenu';
      this.shelfVisible = true;
    });
  }

  private closeCellMenu(): void {
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.shelfVisible = false;
    });
  }

  // ── 读写 / 只读（每篇文档一个持久标记，见 DocStore.setReadOnly）──
  //
  // 只读 = 锁住「改写正文」这条路（编辑入口 + 阅读页任务勾选）；
  // 阅读 / 批注 / 封面 / 导出 / 重命名 / 删除都不受影响。
  // 标记存在 shelf.json。
  //
  // 面板里的开关状态**显式存成 @State**（之前是每次渲染现问数据层）：
  // 现问的做法在面板这种"打开后内容不重建"的场景下不可靠——用户点了按钮、
  // 数据层已经改对，但按钮没重绘，看上去就是"有提示、按钮没变化"。

  /** 当前菜单指向的文档是否只读（打开菜单时同步一次，切换时立即更新）。 */
  @State cellMenuReadOnly: boolean = false;

  /** 该文档当前是否只读（未设过标记时按「内置只读」兜底）。 */
  private isDocReadOnly(name: string): boolean {
    const ctx = this.ctx();
    if (ctx === null) {
      return false;
    }
    try {
      DocStore.init(ctx);
      return DocStore.isReadOnly(ctx, name);
    } catch (err) {
      return false;
    }
  }

  /** 切换读写 / 只读：先写数据层，成功后再同步界面状态并刷新。 */
  private toggleDocReadOnly(readOnly: boolean): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const name: string = this.cellMenuFor;
    if (this.isDocReadOnly(name) === readOnly) {
      // 已经是目标状态：只把界面同步过去（避免"点了没反应"的错觉）
      this.cellMenuReadOnly = readOnly;
      return;
    }
    try {
      if (DocStore.setReadOnly(ctx, name, readOnly)) {
        // **先落界面状态**，再 refresh()：即使 refresh 因为别的原因没触发重绘，
        // 按钮也已经在正确的选中态上。
        this.cellMenuReadOnly = readOnly;
        this.refresh();
        this.toast(readOnly ? L10n.t('已切为只读：编辑入口已锁') : L10n.t('已切为可写：可以编辑了'));
      } else {
        this.toast(L10n.t('切换失败：文档不存在'));
      }
    } catch (err) {
      this.toast('切换失败：' + DocStore.describeError(err as BusinessError));
    }
  }

  // ── 封面外观（底色 / 图片 / 名称显示）──
  //
  // 三项都作用在「当前 ⋯ 菜单指向的对象」（cellMenuKind + cellMenuFor）上，
  // 写完立刻 refresh()：索引里存的是元信息，界面靠 refresh 重新读一遍。
  // 注意 build/ForEach 期间不能写 @State，所以这些只在事件回调里调。

  /** 应用封面底色（空串 = 恢复按名字哈希的默认配色）。 */
  private applyCoverColor(color: string): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    if (DocStore.setCoverColor(ctx, this.cellMenuKind, this.cellMenuFor, color)) {
      this.refresh();
      this.toast(color.length === 0 ? L10n.t('已恢复默认配色') : L10n.t('封面颜色已更新'));
    }
  }

  /** 从系统图片选择器导入一张封面图（复制进沙箱，无需媒体库权限）。 */
  private pickCoverImage(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const kind: string = this.cellMenuKind;
    const target: string = this.cellMenuFor;
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
        if (DocStore.setCoverImage(ctx, kind, target, rel)) {
          this.refresh();
          this.toast(L10n.t('封面图已更新'));
        }
      }).catch((err: BusinessError) => {
        this.toast('选择图片失败：' + err.message);
      });
    } catch (err) {
      this.toast(L10n.t('无法打开图片选择器'));
    }
  }

  /** 移除封面图（回到程序化封面；底色设置保留）。 */
  private clearCoverImage(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    if (DocStore.setCoverImage(ctx, this.cellMenuKind, this.cellMenuFor, '')) {
      this.refresh();
      this.toast(L10n.t('已移除封面图'));
    }
  }

  /** 封面（格子上的名字）是否显示。 */
  private toggleCoverName(show: boolean): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    if (DocStore.setCoverHideName(ctx, this.cellMenuKind, this.cellMenuFor, !show)) {
      this.refresh();
      this.toast(show ? L10n.t('封面显示名称') : L10n.t('封面只留图形、隐藏名称'));
    }
  }

  /**
   * 当前菜单对象是否已设置封面图。
   * 注意：**可选属性必须"先落到局部常量再判空"**——ArkTS 对
   * `obj.optProp !== undefined && obj.optProp.length > 0` 这种就地写法不做类型收窄，
   * 数组下标访问（this.docs[k].xxx）更是直接报 "Object is possibly 'undefined'"。
   */
  private cellMenuHasCoverImage(): boolean {
    if (this.cellMenuKind === 'folder') {
      const f: ShelfFolder | null = this.folderByName(this.cellMenuFor);
      if (f === null) {
        return false;
      }
      const img: string | undefined = f.coverImage;
      return img !== undefined && img.length > 0;
    }
    for (let k = 0; k < this.docs.length; k++) {
      const m: DocMeta = this.docs[k];
      if (m.name === this.cellMenuFor) {
        const img2: string | undefined = m.coverImage;
        return img2 !== undefined && img2.length > 0;
      }
    }
    return false;
  }

  /** 当前菜单对象是否隐藏了封面名称。 */
  private cellMenuHideName(): boolean {
    if (this.cellMenuKind === 'folder') {
      const f: ShelfFolder | null = this.folderByName(this.cellMenuFor);
      return f !== null && f.hideCoverName === true;
    }
    for (let k = 0; k < this.docs.length; k++) {
      if (this.docs[k].name === this.cellMenuFor) {
        return this.docs[k].hideCoverName === true;
      }
    }
    return false;
  }

  /** 当前菜单对象当前用的底色（空 = 默认配色）。 */
  private cellMenuColor(): string {
    if (this.cellMenuKind === 'folder') {
      const f: ShelfFolder | null = this.folderByName(this.cellMenuFor);
      if (f === null) {
        return '';
      }
      const c: string | undefined = f.coverColor;
      return c === undefined ? '' : c;
    }
    for (let k = 0; k < this.docs.length; k++) {
      const m: DocMeta = this.docs[k];
      if (m.name === this.cellMenuFor) {
        const c2: string | undefined = m.coverColor;
        return c2 === undefined ? '' : c2;
      }
    }
    return '';
  }

  /**
   * 文档封面底色（空串 = 用名字哈希的默认配色）。
   * 优先级：**用户手动设的封面色** → 正文 Front Matter 的 `cover:` —— 两者都没有
   * 才回落到按文件名哈希出的配色（口径见 DocStore.coverColorOf）。
   */
  private coverColorOf(meta: DocMeta): string {
    return DocStore.coverColorOf(meta);
  }

  /** 文件夹是否有自定义封面图。 */
  private folderHasImage(folder: ShelfFolder): boolean {
    const img: string | undefined = folder.coverImage;
    return img !== undefined && img.length > 0;
  }

  /** 文件夹封面图源（无图返回空串）。 */
  private folderImageSrc(folder: ShelfFolder): string {
    const img: string | undefined = folder.coverImage;
    return img === undefined ? '' : this.coverImageSrc(img);
  }

  /** 文件夹自定义底色（空串 = 主题默认）。 */
  private folderColorOf(folder: ShelfFolder): string {
    const c: string | undefined = folder.coverColor;
    return c === undefined ? '' : c;
  }

  private openRename(kind: string, name: string): void {
    this.renameKind = kind;
    this.renameFrom = name;
    this.renameText = name;
    // ⚠️ **这里绝对不能先调 closeCellMenu()**：那会在同一帧里把 shelfVisible
    // 先置 false（触发 bindSheet 的 dismiss 动画）又立刻置 true（要求 show）——
    // 同一个 bindSheet "关到一半又开"会冲突，真机表现就是**面板不出现 + 页面闪退**
    // （用户反馈：更多 → 重命名，点完没弹输入框还崩）。
    // 正确做法：面板保持打开，只把**内容标识**从 menu 换成 rename
    // （indexSheet() 里的 if 分支会换成重命名内容），顺带还有"菜单就地变输入框"的观感。
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.shelfSheet = 'rename';
      this.shelfVisible = true;
    });
  }

  private closeRename(): void {
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.shelfVisible = false;
    });
  }

  /** 格子菜单 → 导出（HTML / MD / 分享，用户要求）。 */
  private openCellExport(): void {
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.shelfSheet = 'export';
      this.shelfVisible = true;
    });
  }

  /**
   * 合并导出（书架多选 → 合并导出）：候选 = 当前书架全部文档，
   * 预选 = 这次勾选的那批（保持勾选顺序）。
   */
  private openMergeExport(): void {
    const src: MergeSource[] = [];
    for (let k = 0; k < this.docs.length; k++) {
      src.push({ name: this.docs[k].name, builtin: this.docs[k].builtin === true } as MergeSource);
    }
    const pre: string[] = [];
    for (let k = 0; k < this.multiNames.length; k++) {
      pre.push(this.multiNames[k]);
    }
    this.mergeSources = src;
    this.mergePreselect = pre;
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.sheetEpoch++;
      this.shelfSheet = 'merge';
      this.shelfVisible = true;
    });
  }

  private toggleShelfMode(): void {
    this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
      this.treeMode = !this.treeMode;
    });
  }

  private toggleFolderExpand(name: string): void {
    const at: number = this.expandedFolders.indexOf(name);
    const next: string[] = [];
    for (let k = 0; k < this.expandedFolders.length; k++) {
      if (this.expandedFolders[k] !== name) {
        next.push(this.expandedFolders[k]);
      }
    }
    if (at < 0) {
      next.push(name);
    }
    this.expandedFolders = next;
  }

  // ── 文件夹展开（iOS 6 主屏式）──
  //
  // 原文件夹**留在原地不消失**，面板**排在网格流里、紧跟在图标后面、跨满三列**，
  // 高度从 0 长到目标值 —— 于是把下面的文件图标往下推开；顶缘一颗小箭头指向原图标。
  // 其余格子整体退到后面（透明度 + 模糊），主体凸显。

  private openFolderPanel(name: string): void {
    if (this.openFolderName === name) {
      this.closeFolderPanel();
      return;
    }
    // **已有面板展开时，点其他文件夹不响应**（用户要求）
    if (this.openFolderName.length > 0) {
      return;
    }
    // **记录展开前的滚动位置**（用户要求：收回时自动滑回原位）——
    // 在任何展开滚动发生之前取当前偏移；-1 = 取不到，收回时不滚
    try {
      const off: OffsetResult | undefined = this.gridScroller.currentOffset();
      if (off !== undefined && off !== null) {
        this.folderRestoreY = off.yOffset;
      }
    } catch (err) {
      this.folderRestoreY = -1;
    }
    // 挂载包在 animateTo 里：其他格子的模糊 / 透明度**渐入**（不再瞬间变糊）。
    // 先挂载（高度 0），下一拍再撑高——同一拍里改两个状态就没有「推开下面图标」的过程
    this.getUIContext().animateTo({ curve: FOLDER_SPRING }, () => {
      this.openFolderName = name;
      // 与 openFolderName 同一拍挂载：下面的格子一次动画被推开，不会二次跳
      this.folderPanelMounted = true;
    });
    this.folderPanelOpen = false;
    // **滚动只做一次、且是「最小滚动」，发生在撑开之前**。
    //
    // 语义沿用 1.0.2 的 `ScrollAlign.AUTO`：**只在面板露不全时才滚、只滚到刚好露出**。
    // 文件夹本来就在屏幕中部 → 一点都不滚，面板在原地/folders 下方长开（用户要的观感）。
    //
    // 与 1.0.2 的两处差别，都是修「蹲一下然后跳动」与「滑动的太快了」，**不改语义**：
    // ① 1.0.2 是「AUTO 跳一次 → 220ms 后 correctPanelScroll 再补一滚」= 两跳 = 跳动；
    //    现在手算差值、**只发一次** scrollTo。
    // ② 1.0.2 用 `scrollToIndex(smooth=true)`，固定短时长跑完全程、滚得越远越快；
    //    现在用 `scrollTo` + FOLDER_GLIDE_MS + FOLDER_SPRING，与展开动画同速。
    setTimeout(() => {
      // 定时器期间用户可能已切走页面：此时 Grid 已卸载，继续滚动会拿到
      // undefined 的偏移（见 scrollPanelTopIntoPlace 的说明）
      if (!this.pageAlive) {
        return;
      }
      this.scrollPanelTopIntoPlace();
      this.getUIContext().animateTo({ curve: FOLDER_SPRING }, () => {
        this.folderPanelOpen = true;
      });
    }, FOLDER_SCROLL_SETTLE);
  }

  /**
   * 展开**前**做一次**最小滚动**，把文件夹下方的那块面板挪进可视区。
   *
   * ⚠️ **语义必须是「最小滚动」，不是「对齐到某个位置」**（用户连续纠正：
   * 「文件夹展开要在文件夹下」「不是文件显示区域最下方！时 1.0.2 时的那样」）。
   * 1.0.2 用的是 `scrollToIndex(..., ScrollAlign.AUTO)` —— AUTO 的语义就是
   * **只在目标不在可视区时才滚、且只滚到刚好可见**。所以：
   *   · 文件夹本来就在屏幕中部 → 几乎不滚，面板留在它下方（原地震开）；
   *   · 文件夹靠近屏幕底部 → 才往上滚一点，让面板露出来。
   * 一旦改成 START/CENTER 那种"对齐到固定位置"，文件夹就会被拉到屏幕顶部、
   * 面板被甩到文件区下方 —— 这正是用户看到"放所有文件下方"的成因。
   *
   * **滚动上限 = 滚到底**（用户定义）：「长按封面拖…」那条文末提示浮到屏幕顶部、
   * 停在底栏上方，就是当前手动上滑能到的最低处。所以先算「露出面板需要滚多少」，
   * 再用「滚到底还剩多少」封顶 —— 取两者较小值。少了这个封顶，
   * 靠近末尾的文件夹会把内容一路推过文末提示、看起来像滚飞了。
   *
   * 与 1.0.2 的差别只有两处（都是修跳动/速度，不改语义）：
   * ① 用 `scrollTo` + **自定义 duration/curve** 取代 `smooth=true`：
   *    smooth 是固定短时长跑完全程，滚得越远越快（用户反馈"滑动的太快了"）；
   *    这里用 FOLDER_SPRING + FOLDER_GLIDE_MS，与展开动画同一支曲线、同档速度。
   * ② 滚动量自己算（实测文件夹位置），因此**只发一次滚动**，
   *    不像 1.0.2 那样"AUTO 跳一次 + 220ms 后再补一滚"（两跳 = 蹲一下然后跳动）。
   *
   * 实测用 `getRectangleById`（**不能用 onAreaChange**：面板此刻高度 0，回调不触发）。
   */
  private scrollPanelTopIntoPlace(): void {
    // **线上 jscrash 修复**（HiviewDFX 反馈：TypeError: Cannot read property
    // yOffset of undefined @ scrollPanelTopIntoPlace）：Grid 未挂载 / 页面已切走 /
    // 视图在列表与网格间切换时，Scroller.currentOffset() 会返回 undefined。
    // 这里先取出来判空，拿不到就跳过一次滚动（下次展开时会重新算）。
    const off: OffsetResult | undefined = this.gridScroller.currentOffset();
    if (off === undefined || off === null) {
      return;
    }
    const cur: number = off.yOffset;
    // 锚点 = 被点开的文件夹格子（面板在它下方）
    const anchorTop: number = this.folderAnchorTopByMeasure();
    if (anchorTop <= 0) {
      return;
    }
    // 可视区下沿 = 底栏胶囊上沿（面板底部要露在它上面才算看得见）
    const safeBottom: number = this.rootHeight - this.padBottom() - HwBar.pill - HwSpace.md;
    // 面板展开后的高度
    const panelH: number = this.folderPanelTarget();
    // 面板底边（窗口坐标）= 文件夹顶边 + 一行高 + 面板高
    const panelBottom: number = anchorTop + this.folderRowHeight() + panelH;
    if (panelBottom <= safeBottom) {
      // **整块面板已经在可视区内 → 一点都不滚**（1.0.2 的 AUTO 就是这个行为）
      return;
    }
    // ① 露出面板需要的滚动量
    let dist: number = panelBottom - safeBottom;
    // ② 「滚到底」的剩余量：文末提示上沿贴到顶栏（即它停在底栏上方）时为 0
    const room: number = this.roomToScrollEnd();
    if (room >= 0 && dist > room) {
      // 需要的比能滚的还多 → 只滚到"滚到底"这个上限，绝不越过去
      dist = room;
    }
    if (dist <= 1) {
      // 已经贴着上限（或已在位）→ 不滚
      return;
    }
    try {
      this.gridScroller.scrollTo({
        xOffset: 0,
        yOffset: cur + dist,
        // 曲线与展开动画**同一支** FOLDER_SPRING：滑动与撑开同步收放
        // （用户反馈"滑动速度要和文件夹展开的速度一样"）
        animation: { duration: FOLDER_GLIDE_MS, curve: FOLDER_SPRING }
      });
    } catch (err) {
      // 定位失败不影响展开本身（面板仍会展开，用户可手动滚）
    }
  }

  /**
   * 从当前位置到「滚到底」还能滚多少（vp）。
   *
   * 判据（用户定义）：网格末尾那条「长按封面拖到另一张上合并为文件夹 · 封面由文档名生成」
   * 的文末提示，它的上沿浮到屏幕顶部、整条停在底栏胶囊上方，就是手动上滑的极限。
   * 该提示的 GridItem 挂了 id `shelfEndHint`，这里实测它的上沿算差值。
   *
   * 返回 -1 表示**测不到**（提示不在渲染范围 / 首帧未排版）→ 调用方不做封顶。
   */
  private roomToScrollEnd(): number {
    const hintTop: number = this.endHintTopByMeasure();
    if (hintTop <= 0) {
      return -1;
    }
    // 文末提示上沿到屏幕顶部还有多远；滚那么多就到底了
    return hintTop;
  }

  /** 实测文末提示 GridItem 上沿的窗口坐标（vp）；测不到返回 0。 */
  private endHintTopByMeasure(): number {
    try {
      const info: componentUtils.ComponentInfo =
        this.getUIContext().getComponentUtils().getRectangleById('shelfEndHint');
      if (info === undefined || info === null) {
        return 0;
      }
      const wy: number = info.windowOffset.y;
      if (wy <= 0) {
        return 0;
      }
      return this.getUIContext().px2vp(wy);
    } catch (err) {
      return 0;
    }
  }

  /** 文件夹所在行的高度（封面 0.72 宽高比 + 名称/数量行 + 行间距），用于估算面板底边位置。 */
  private folderRowHeight(): number {
    const gridW: number = this.rootWidth - HwSpace.lg * 2;
    const cols: number = this.shelfColumns();
    const cellW: number = (gridW - HwSpace.md * (cols - 1)) / cols;
    return cellW / 0.72 + 34 + HwSpace.md;
  }

  /**
   * 实测「正在展开的文件夹」格子顶边的窗口坐标（vp）；测不到返回 0。
   *
   * 走 `getComponentUtils().getRectangleById('folderCellAnchor')`：
   * 只取 `windowOffset.y` —— 那是节点在窗口里的绝对位置，与节点高度无关，
   * 所以**不依赖展开动画是否已开始**（这正是不用 onAreaChange 的原因：
   * 面板高度为 0 时该回调压根不触发）。
   * （HeroTransition.measure() 会因 size.height <= 0 判失败返回空矩形，这里不能用它。）
   */
  private folderAnchorTopByMeasure(): number {
    try {
      const info: componentUtils.ComponentInfo =
        this.getUIContext().getComponentUtils().getRectangleById('folderCellAnchor');
      if (info === undefined || info === null) {
        return 0;
      }
      const wy: number = info.windowOffset.y;
      if (wy <= 0) {
        return 0;
      }
      // getRectangleById 返回 px，转 vp
      return this.getUIContext().px2vp(wy);
    } catch (err) {
      // 组件还没挂好（首帧）→ 返回 0，本拍不滚
      return 0;
    }
  }

  private closeFolderPanel(): void {
    // **收回时自动滑回展开前的位置**（用户要求）：与展开滚动对称——
    // 用 openFolderPanel 记录的原偏移，同一条 300ms 曲线一次滚回。
    // 未记录（-1）时静默跳过；滚动失败的 try 兜底不影响收起本身。
    if (this.folderRestoreY >= 0) {
      const restoreY: number = this.folderRestoreY;
      this.folderRestoreY = -1;
      try {
        this.gridScroller.scrollTo({
          xOffset: 0,
          yOffset: restoreY,
          animation: { duration: 300, curve: Curve.FastOutSlowIn }
        });
      } catch (scrollErr) {
        // 滚动失败不影响收起
      }
    }
    // 收起动画放慢（用户反馈太快）：300ms 标准曲线，与展开观感对称。
    // **摘节点与收高度放在同一拍**：之前是「高度收到 0 → 340ms 后再摘 GridItem」，
    // 摘的那一刻网格要再量一次布局，底部那行提示文本会**第二次上移**
    // （用户看到的「上移 → 顿一下 → 再上移」）。现在一起做完，提示文本一次到位；
    // 节点的消失由 folderExpandPanel 那层透明度 + 缩放收尾，不会有硬切感。
    this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
      this.folderPanelOpen = false;
      this.folderPanelMounted = false;
    });
    // 名字留到动画跑完再清：面板节点已摘，但它还兼着「压暗 / 模糊其他格子」的开关，
    // 早清会让其余格子在第一帧就弹回清晰。
    setTimeout(() => {
      if (!this.folderPanelOpen) {
        this.openFolderName = '';
      }
    }, 340);
  }

  /**
   * 有文件夹面板开着时，其他格子都要退到后面去（半透明 + 模糊），主体才凸显。
   * **条件带 folderPanelOpen**：收起时 folderPanelOpen 先变 false——模糊 / 透明度
   * 在同一条 animateTo 里平滑消散（之前只看 openFolderName，收完 340ms 后
   * 模糊瞬间消失，非常生硬——用户反馈）。
   */
  private cellDimmed(): boolean {
    return this.openFolderName.length > 0 && this.folderPanelOpen;
  }

  private cellOpacity(): number {
    return this.cellDimmed() ? 0.32 : 1;
  }

  private cellBlur(): number {
    // **搜索展开时整个书架同程度模糊**（用户要求：程度参考打开文件夹时的效果 = 6）
    return (this.cellDimmed() || this.searchExpanded) ? 6 : 0;
  }

  /**
   * 树形视图用：按**书架顺序（ord）**列出松散文档。
   * ⚠️ 不能直接用 this.docs（它按最近打开排序）——拖拽换位改的是书架顺序 ord，
   * 树形如果按 lastOpen 取数，换位后永远不刷新（用户实测「实际上真没刷新」）。
   * 网格的 buildItems 也是按 ord 组装的，两个视图从此同源同序。
   */
  private shelfOrderedLoose(includeBuiltin: boolean): DocMeta[] {
    const ctx = this.ctx();
    if (ctx === null) {
      return includeBuiltin ? this.looseBuiltinDocs() : this.looseDocs();
    }
    const order: string[] = DocStore.shelfOrder(ctx);
    const out: DocMeta[] = [];
    for (let k = 0; k < order.length; k++) {
      if (!order[k].startsWith(DocStore.ORDER_DOC)) {
        continue;
      }
      const name: string = order[k].substring(DocStore.ORDER_DOC.length);
      if (DocStore.folderOfDoc(name).length > 0) {
        continue;
      }
      for (let j = 0; j < this.docs.length; j++) {
        const m: DocMeta = this.docs[j];
        if (m.name === name && m.builtin === includeBuiltin) {
          out.push(m);
          break;
        }
      }
    }
    return out;
  }

  /** 树形视图的行内展开也要有动画：状态变更包在弹簧 animateTo 里。 */
  private toggleFolderExpandAnimated(name: string): void {
    this.getUIContext().animateTo({ curve: FOLDER_SPRING }, () => {
      this.toggleFolderExpand(name);
    });
  }

  /**
   * 展开面板的窗口矩形（窗口坐标 vp）。
   * 展开**前**的预滚（preScrollPanelIntoPlace）靠 panelWinTop 定目标位；
   * panelWinBottom 仍记录完整矩形，便于日后需要时再算"底部是否压到胶囊"。
   */
  private panelWinTop: number = 0;
  private panelWinBottom: number = 0;

  onPageShow(): void {
    this.pageAlive = true;
    // **系统深浅同步 + 必要的整页刷新**：
    // 实机日志证明 AppStorage 里 systemDark 会更新，但 @Watch 不触发，
    // 所以这里手动比对——不一致就整树重建（材质 / 壁纸 / 卡片一次到位）。
    syncSystemDarkFromContext();
    this.applyThemeChange();
    // 可见期间的深浅探测器：系统深浅一变立刻整页重建（@Watch 实机不触发，见 AppWindow）
    startThemeWatchdog(() => {
      this.applyThemeChange();
      applySystemBarTheme(this.isDark());
    });
    applySystemBarTheme(this.isDark());
    // 智感握姿：开始监听握持手（animateTo 让底部按钮滑动到位）。
    // ⚠️ 必须走 **startWithPermission**（DETECT_GESTURE 是 user_grant 权限，
    // 不申请 motion.on 静默抛错 → gripSide 恒 0 →"一直在右边"，用户实测）——
    // 与阅读页同一入口，已授权时不重复弹窗。
    const gripCtx = this.ctx();
    if (gripCtx !== null) {
      GripAware.startWithPermission(gripCtx, (side: number) => {
        this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
          this.gripSide = side;
        });
      }).catch(() => {
        // 权限/能力不可用：保持默认位置
      });
    } else {
      GripAware.start((side: number) => {
        this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
          this.gripSide = side;
        });
      });
    }
    // 返程转场期间**不刷新列表**：refresh 会让 Grid 重排，共享元素（封面）动画
    // 会因目标节点被替换而闪断。等转场结束（350ms + 余量）后再刷新数据。
    setTimeout(() => {
      this.refresh();
    }, 420);
    // **外部"打开方式"导入的文档**（EntryAbility 已写入书架）：刷新后提示一次
    const pending: string | undefined = AppStorage.get<string>('pendingOpenDocName');
    if (pending !== undefined && pending.length > 0) {
      AppStorage.setOrCreate('pendingOpenDocName', '');
      setTimeout(() => {
        this.refresh();
        this.toast('已导入《' + pending + '》');
      }, 460);
    }
    // **外部"打开方式"导入的备份 zip**（EntryAbility 已恢复数据）：提示 + 刷新书架
    const backupMsg: string | undefined = AppStorage.get<string>('pendingBackupImportMsg');
    if (backupMsg !== undefined && backupMsg.length > 0) {
      AppStorage.setOrCreate('pendingBackupImportMsg', '');
      setTimeout(() => {
        this.refresh();
        this.toast(backupMsg);
      }, 500);
    }
    // **桌面卡片点击路由**（2×2 最近阅读卡片，EntryAbility.handleCardAction 写的信号）：
    // 打开指定文档 / 进编辑器新建（target=shelf 无需信号，落在本页即可）
    const jumpDoc: string | undefined = AppStorage.get<string>('formJumpDoc');
    if (jumpDoc !== undefined && jumpDoc.length > 0) {
      AppStorage.setOrCreate('formJumpDoc', '');
      const jc = this.ctx();
      const meta: DocMeta | undefined = jc === null ? undefined : DocStore.find(jc, jumpDoc);
      if (jc !== null && meta !== undefined) {
        this.openDoc(meta);
      } else {
        this.toast(L10n.t('文档不存在或已删除'));
      }
    }
    const jumpNew: number | undefined = AppStorage.get<number>('formJumpNewDoc');
    if (jumpNew !== undefined && jumpNew > 0) {
      // 消费即清零（下一次点击 tick 会再自增）
      AppStorage.setOrCreate('formJumpNewDoc', 0);
      this.pushPage('pages/Editor');
    }
    // **多设备流转接续**（EntryAbility 已把迁移数据写进 AppStorage）：
    // 目标端有同名文档 → 直接打开；没有 → 用迁移来的正文创建一篇再打开。
    const cName: string | undefined = AppStorage.get<string>('pendingContinueDocName');
    if (cName !== undefined && cName.length > 0) {
      AppStorage.setOrCreate('pendingContinueDocName', '');
      const cContent: string = AppStorage.get<string>('pendingContinueDocContent') ?? '';
      const oversize: string = AppStorage.get<string>('pendingContinueOversize') ?? '0';
      const gc = this.ctx();
      if (gc === null) {
        return;
      }
      this.refresh();
      let target: string = cName;
      if (DocStore.find(gc, cName) === undefined) {
        if (oversize === '1' || cContent.length === 0) {
          this.toast('《' + cName + '》内容过大，未随流转传输正文');
          return;
        }
        const created: DocMeta | null = DocStore.create(gc, cName, cContent);
        if (created === null) {
          this.toast(L10n.t('接续文档创建失败'));
          return;
        }
        target = created.name;
        this.refresh();
        // **接续文档 5 分钟后自动清理**（用户要求）：临时接续的文件不留书架——
        // 5 分钟内没有被编辑过（mtime 未变）就自动删除；编辑过则视为正式文档保留
        const bornAt: number = Date.now();
        const bornName: string = created.name;
        setTimeout(() => {
          const cc2 = this.ctx();
          if (cc2 === null) {
            return;
          }
          const m: DocMeta | undefined = DocStore.find(cc2, bornName);
          if (m !== undefined && m.mtime <= bornAt + 1000) {
            DocStore.remove(cc2, bornName);
            this.refresh();
            this.toast('接续的《' + bornName + '》已自动清理');
          }
        }, 5 * 60 * 1000);
      }
      const route: ReaderRoute = { name: target };
      this.pushPage('pages/Reader', route);
      this.toast('已从另一台设备接续《' + cName + '》');
    }
  }

  /** 页面隐藏：停掉深浅探测器（不在本页时没必要问系统）。 */
  onPageHide(): void {
    // 页面不可见：定时器回调不要再操作组件（见 scrollPanelTopIntoPlace 的崩溃修复）
    this.pageAlive = false;
    GripAware.stop();
    stopThemeWatchdog();
  }

  /**
   * **系统返回键 / 侧滑手势**（@Entry 页面的生命周期回调）。
   *
   * 书架页有两层"临时浮出"的内容，返回时应逐层收掉，而不是直接退出应用：
   *   ① 图片快速查看浮层（最上层）→ 关闭浮层；
   *   ② 搜索展开（含结果下拉）→ 收起搜索。
   * 两层都收掉之后再返回 false，交回系统（退出应用）。
   *
   * 注：这里刻意不用「EntryAbility.onBackPressed + AppStorage 信号」那套 ——
   * `@StorageProp` 的 `@Watch` 在 AppStorage 被 Ability 改写时**不触发**（实机铁证），
   * 页面级 onBackPress 是唯一可靠的入口。
   */
  onBackPress(): boolean {
    if (this.multiSelect) {
      // 批量选择中：返回先退出多选，不退出应用
      this.exitMultiSelect();
      return true;
    }
    if (this.imgPreviewSrc.length > 0) {
      this.closeImagePreview();
      return true;
    }
    if (this.searchExpanded) {
      this.collapseSearch();
      return true;
    }
    return false;
  }

  /** 应用主题模式变化（设置里切五档）：同步系统栏 / 颜色模式，并整页刷新。 */
  onThemeModeChanged(): void {
    applyAppColorMode(this.themeMode);
    this.applyThemeChange();
    applySystemBarTheme(this.isDark());
  }

  // 说明：@StorageProp('systemDark') 上的 @Watch **实机不触发**（见 AppWindow 注释），
  // 所以刷新不依赖它，而是靠 onPageShow / onThemeModeChanged 里的 applyThemeChange()。

  /**
   * 明暗真的变了才整树重建：themeEpoch 同时拼在根部 Navigation 的 key
   * 和每个网格卡片的 itemKey 上，所以一次刷新覆盖整页（含卡片）。
   */
  private applyThemeChange(): void {
    const dark: boolean = this.isDark();
    if (!themeChangedSince(dark)) {
      markThemeApplied(dark);
      return;
    }
    markThemeApplied(dark);
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.themeEpoch = this.themeEpoch + 1;
      // **半模态面板也要跟着重建**：面板内容由 bindSheet 的 builder 渲染，
      // 它不跟随宿主状态刷新——深色切换时会出现"切换不完全"（正文/卡片变了、
      // 面板还是旧色，用户反馈）。换容器 key 让面板整棵子树重建。
      this.sheetEpoch = this.sheetEpoch + 1;
    });
    // 灰体文本的颜色由 paletteFor 现算，这里再广播一次刷新计数，
    // 保证「自动 / 按主题」的灰字跟着深浅一起换（用户反馈深色下没换色）
    AppStorage.setOrCreate('appearanceTick',
      (AppStorage.get<number>('appearanceTick') ?? 0) + 1);
  }

  // ══════════════════════ 数据 ══════════════════════

  private ctx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  /** 全部文档的标签并集（书架顶栏筛选条的候选） */
  private allTags(): string[] {
    const out: string[] = [];
    for (let k = 0; k < this.docs.length; k++) {
      const raw: string[] | undefined = this.docs[k].tags;
      if (raw === undefined) {
        continue;
      }
      for (let j = 0; j < raw.length; j++) {
        if (raw[j].length > 0 && out.indexOf(raw[j]) < 0) {
          out.push(raw[j]);
        }
      }
    }
    return out;
  }

  /** 标签匹配：空筛选 = 全部通过 */
  private tagMatches(meta: DocMeta): boolean {
    if (this.tagFilter.length === 0) {
      return true;
    }
    const raw: string[] | undefined = meta.tags;
    return raw !== undefined && raw.indexOf(this.tagFilter) >= 0;
  }

  /** 标签筛选条：全部 + 各标签（横向滚动，参考阅读页标签页设计） */
  @Builder
  tagBar() {
    Scroll() {
      Row({ space: HwSpace.xs }) {
        ImmersiveChip({
          palette: this.palette(),
          chipLabel: L10n.t('全部'),
          chipActive: this.tagFilter.length === 0,
          chipOnTap: () => {
            this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
              this.tagFilter = '';
              this.refreshShelfItems();
            });
          }
        })
        ForEach(this.allTags(), (tag: string) => {
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: '#' + tag,
            chipActive: this.tagFilter === tag,
            chipOnTap: () => {
              this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
                this.tagFilter = this.tagFilter === tag ? '' : tag;
                this.refreshShelfItems();
              });
            }
          })
        }, (tag: string) => tag)
      }
      .padding({ left: HwSpace.lg, right: HwSpace.lg })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    // 随分页切换渐入渐出（与页名同一节奏）
    .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.FastOutSlowIn }))
  }

  /** 按标签过滤重建书架网格（保持书架顺序） */
  private refreshShelfItems(): void {
    const c = this.ctx();
    if (c === null) {
      return;
    }
    this.items = this.buildItems(c, this.docs);
  }

  private refresh(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      DocStore.init(ctx);
      const list: DocMeta[] = DocStore.list(ctx);
      // **换成新数组引用**：DocStore 内部是原地改对象（saveProgress 直接改
      // meta.progressRatio），直接赋同一引用时 @State 会被判定"没变化"而不刷新。
      this.docs = list.slice();
      this.folders = DocStore.folderList();
      // 收藏列表（悬浮栏爱心按钮的快速查看）；沿用当前排序口径
      this.starredDocs = DocStore.starredList(ctx, this.starSort);
      // **展开状态要跟着文件夹一起收拾**：解散 / 重命名 / 数据变化后，
      // 若 openFolderName 还指着不存在的文件夹，其他格子会一直保持"退后 + 模糊"
      // （用户看到的"解散后偶尔整屏发糊"就是这个残留状态）。
      if (this.openFolderName.length > 0 && this.folderByName(this.openFolderName) === null) {
        this.openFolderName = '';
        this.folderPanelOpen = false;
        // 文件夹没了，0 高占位的面板也一起摘掉（留着会占一行网格空间）
        this.folderPanelMounted = false;
      }
      // 统一排序 → 网格项（文件夹与文档混排，拖拽才能互相换位）。
      // **新建 / 导入后回来**：把这次赋值放进 animateTo，配合格子的 transition
      // 让新封面淡入 + 轻微放大进场（否则新格子是"啪"地出现，用户反馈没动画）。
      if (this.animateNextRefresh) {
        this.animateNextRefresh = false;
        this.getUIContext().animateTo({ duration: 300, curve: Curve.Friction }, () => {
          this.items = this.buildItems(ctx, list);
        });
      } else {
        this.items = this.buildItems(ctx, list);
      }
      let words: number = 0;
      let chars: number = 0;
      let userCount: number = 0;
      let best: DocMeta | null = null;
      for (let k = 0; k < list.length; k++) {
        words += list[k].wordCount;
        chars += list[k].charCount;
        if (!list[k].builtin) {
          userCount++;
        }
        if (list[k].progressRatio > 0.005 && list[k].lastOpen > 0) {
          if (best === null || list[k].lastOpen > best.lastOpen) {
            best = list[k];
          }
        }
      }
      this.totalWords = words;
      this.totalChars = chars;
      this.userDocCount = userCount;
      this.resumeName = best !== null ? best.name : '';
      this.resumeRatio = best !== null ? best.progressRatio : 0;
      this.resumeLastOpen = best !== null ? best.lastOpen : 0;
      // 阅读统计卡数据（1.1.0 从写作日志页搬来）随书架一起刷新
      this.loadReadingStats();
    } catch (err) {
      this.toast('读取书架失败：' + DocStore.describeError(err as BusinessError));
    }
  }

  /** 全部内置文档。 */
  private builtinDocs(): DocMeta[] {
    const out: DocMeta[] = [];
    for (let k = 0; k < this.docs.length; k++) {
      if (this.docs[k].builtin) {
        out.push(this.docs[k]);
      }
    }
    return out;
  }

  /** 不在任何文件夹里的内置文档（收进「澄笺」文件夹后不再平铺在书架）。 */
  private looseBuiltinDocs(): DocMeta[] {
    const out: DocMeta[] = [];
    const all: DocMeta[] = this.builtinDocs();
    for (let k = 0; k < all.length; k++) {
      if (DocStore.folderOfDoc(all[k].name).length === 0) {
        out.push(all[k]);
      }
    }
    return out;
  }

  /** 不在任何文件夹里的自建文档（网格上直接平铺的部分）。 */
  private looseDocs(): DocMeta[] {
    const out: DocMeta[] = [];
    for (let k = 0; k < this.docs.length; k++) {
      const meta: DocMeta = this.docs[k];
      if (meta.builtin) {
        continue;
      }
      if (DocStore.folderOfDoc(meta.name).length === 0) {
        out.push(meta);
      }
    }
    return out;
  }

  /**
   * 树形视图要列的文件夹：**至少有一篇可见文档**才显示。
   *
   * 与网格口径保持一致 —— 只装内置文档的「澄笺」在内置被移除后应当一起消失，
   * 而不是留一个空文件夹挂在列表里（用户反馈）。
   */
  /**
   * 树形视图用：按**书架顺序（ord）**列出文件夹（只含有可见文档的）。
   * ⚠️ 与 shelfOrderedLoose 同理——文件夹↔文件夹换位改的是 ord，
   * 若按 this.folders（数组自身顺序）取数，换位永远不显示（用户实测）。
   */
  private shelfOrderedFolders(): ShelfFolder[] {
    const ctx = this.ctx();
    if (ctx === null) {
      return this.treeFolders();
    }
    const order: string[] = DocStore.shelfOrder(ctx);
    const out: ShelfFolder[] = [];
    for (let k = 0; k < order.length; k++) {
      if (!order[k].startsWith(DocStore.ORDER_FOLDER)) {
        continue;
      }
      const name: string = order[k].substring(DocStore.ORDER_FOLDER.length);
      for (let j = 0; j < this.folders.length; j++) {
        if (this.folders[j].name === name && this.folderDocs(name).length > 0) {
          out.push(this.folders[j]);
          break;
        }
      }
    }
    return out;
  }

  private treeFolders(): ShelfFolder[] {
    const out: ShelfFolder[] = [];
    for (let k: number = 0; k < this.folders.length; k++) {
      if (this.folderDocs(this.folders[k].name).length > 0) {
        out.push(this.folders[k]);
      }
    }
    return out;
  }

  /** 某文件夹内的文档元信息列表（**只含当前书架可见的文档**）。 */
  private folderDocs(folderName: string): DocMeta[] {
    const out: DocMeta[] = [];
    const ctx = this.ctx();
    for (let k = 0; k < this.docs.length; k++) {
      if (DocStore.folderOfDoc(this.docs[k].name) === folderName) {
        out.push(this.docs[k]);
      }
    }
    return out;
  }

  // ══════════════════════ 主题与尺寸 ══════════════════════

  private isDark(): boolean {
    // 统一转调 isDarkTheme：**羊皮纸 / 护眼绿是浅色纸底**，
    // 漏判会让壁纸 / 遮罩 / 系统栏按 systemDark 走，与纸色文字对不上。
    return isDarkTheme(this.themeMode, this.systemDark);
  }

  private palette(): ReaderPalette {
    // 三个来源都要显式读一遍落成局部常量：主题色 / 灰字 / 沾色是在 paletteFor 里
    // 读 AppStorage 的（纯函数读不登记依赖），这里不登记的话主题切换会被 ArkUI
    // 跳过重算，表现为部分节点沿用旧调色板（退出重进才恢复）
    const tick: number = this.appearanceTick;
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  private padTop(): number {
    return this.getUIContext().px2vp(this.safeTopPx) + HwSpace.xs;
  }

  private padBottom(): number {
    return this.getUIContext().px2vp(this.safeBottomPx) + HwSpace.xs;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1800 });
    } catch (err) {
      // 提示失败不影响主流程
    }
  }

  // ══════════════════════ 动作 ══════════════════════

  /**
   * 打开文档 = **一镜到底**：封面从那一格放大铺满 → 翻开 → 阅读页接管画面。
   * 反向：从阅读页返回时先合上封面，再缩回同一格（见 onPageShow）。
   */
  private openDoc(meta: DocMeta, ev?: ClickEvent): void {
    // **批量管理模式**：点封面 = 勾选 / 取消勾选，不打开文档（用户要求批量操作）
    if (this.multiSelect) {
      this.toggleMulti(meta.name);
      return;
    }
    // 一镜到底·出发（官方 BookFlip 方案）：拿到这一格封面的窗口矩形并预算展开几何。
    // 几何来源按可靠性排三层（任何一层拿到都能播动画）：
    //   ① onAreaChange 记录的 globalPosition（vp，窗口坐标，最稳）
    //   ② getComponentById 实测（px）
    //   ③ 点击坐标 + 标准格子尺寸估算（兜底，保证「一定有动画」）
    const ui = this.getUIContext();
    let rectVp: HeroRect = new HeroRect();
    const rec: CoverRect | undefined = this.docRects.get(meta.name);
    if (rec !== undefined && rec.w > 0 && rec.h > 0) {
      rectVp.left = rec.x;
      rectVp.top = rec.y;
      rectVp.width = rec.w;
      rectVp.height = rec.h;
    }
    if (rectVp.width <= 0 || rectVp.height <= 0) {
      const px: HeroRect = HeroTransition.measure(ui, 'covercell_' + meta.name);
      if (px.width > 0 && px.height > 0) {
        rectVp.left = ui.px2vp(px.left);
        rectVp.top = ui.px2vp(px.top);
        rectVp.width = ui.px2vp(px.width);
        rectVp.height = ui.px2vp(px.height);
      }
    }
    if (rectVp.width <= 0 || rectVp.height <= 0) {
      // 兜底：用点击点当封面中心，尺寸取三列网格的单格大小（宽高比 0.72）
      const cellW: number = (this.rootWidth - HwSpace.lg * 2 - HwSpace.md * (this.shelfColumns() - 1)) / this.shelfColumns();
      const cellH: number = cellW / 0.72;
      const cx: number = ev !== undefined && ev !== null ? ev.windowX : this.rootWidth / 2;
      const cy: number = ev !== undefined && ev !== null ? ev.windowY : this.rootHeight / 3;
      rectVp.left = cx - cellW / 2;
      rectVp.top = cy - cellH / 2;
      rectVp.width = cellW;
      rectVp.height = cellH;
    }
    const init: HeroInit = HeroTransition.computeInitFromVp(rectVp, this.rootWidth, this.rootHeight);
    HeroTransition.saveInit(init);
    this.lastDocName = meta.name;
    this.pushPage('pages/Reader', { name: meta.name });
  }

  /** 文档封面几何：p=0 是原来的格子矩形，p=1 铺满屏幕。 */
  private docCoverX(): number {
    return this.coverRectX * (1 - this.docCoverP);
  }

  private docCoverY(): number {
    return this.coverRectY * (1 - this.docCoverP);
  }

  private docCoverW(): number {
    return this.coverRectW + (this.rootWidth - this.coverRectW) * this.docCoverP;
  }

  private docCoverH(): number {
    return this.coverRectH + (this.rootHeight - this.coverRectH) * this.docCoverP;
  }

  /** 飞行中的文档封面（打开第一段 / 返回第二段共用）。 */
  @Builder
  docCoverOverlay() {
    Column() {
      // **真的那张封面**（与格子里一模一样：配色、标题、状态标），不是一块纯色
      DocCover({
        title: this.docCoverName,
        builtin: this.docCoverBuiltin,
        coverTop: coverColorsOf(this.docCoverName, this.docCoverBuiltin).top,
        coverBottom: coverColorsOf(this.docCoverName, this.docCoverBuiltin).bottom,
        coverInk: coverColorsOf(this.docCoverName, this.docCoverBuiltin).ink,
        edgeColor: this.palette().divider
      })
    }
    .width(this.docCoverW())
    .height(this.docCoverH())
    .position({ x: this.docCoverX(), y: this.docCoverY() })
    .borderRadius(13)
    .clip(true)
    // 向左滑走：封面整体左移一屏（阅读页同时从右滑入，动作连续）
    .translate({ x: -this.rootWidth * this.docCoverSlide })
    .opacity(this.docCoverHidden ? 0 : 1)
    .hitTestBehavior(HitTestMode.None)
    .animation({ curve: Curve.FastOutSlowIn })
  }

  private editDoc(name: string): void {
    // 只读文档不给编辑入口：菜单里已把「编辑」收成提示行，这里再兜一道，
    // 免得从别的路径（如将来的快捷入口）绕进来改到只读正文。
    if (this.isDocReadOnly(name)) {
      this.toast(L10n.t('该文档是只读的，先切成「可写」再编辑'));
      return;
    }
    const route: ReaderRoute = { name: name };
    this.pushPage('pages/Editor', route);
  }

  /**
   * 新建文档（书架的新建卡与底栏「新建」都走这里）。
   * 先弹出「新建」面板，让用户选**空白文档**还是**从模板开始** ——
   * 模板本来就属于新建流程（原先挂在封面「⋯」菜单里，逻辑不顺，用户提出）。
   */
  private createDoc(): void {
    this.shelfSheet = 'newDoc';
    this.shelfVisible = true;
  }

  /** 打开空白编辑器新建。 */
  private openEditorNew(): void {
    this.shelfVisible = false;
    // 新建后回到书架：让新封面带动画进场（见 refresh 里的 animateNextRefresh）
    this.animateNextRefresh = true;
    this.pushPage('pages/Editor');
  }

  private openSettingsPage(): void {
    this.pushPage('pages/Settings');
  }

  private pushPage(url: string, params?: ReaderRoute): void {
    try {
      if (params !== undefined) {
        this.pathStack.pushPath({ name: url, param: params });
      } else {
        this.pathStack.pushPath({ name: url });
      }
    } catch (err) {
      this.toast(L10n.t('页面跳转失败'));
    }
  }

  /**
   * 导入文档：**支持一次选多个文件**（用户要求批量导入）。
   * 逐个导入并统计成功 / 失败数，最后一个 toast 汇总结果；
   * 重名由 DocStore.importFromUri 自行处理（自动加序号，不会覆盖已有文档）。
   */
  private importDoc(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      const docPicker = new picker.DocumentViewPicker(ctx);
      const options = new picker.DocumentSelectOptions();
      // 1 → 50：多选批量导入
      options.maxSelectNumber = 50;
      options.fileSuffixFilters = ['.md', '.markdown', '.txt'];
      docPicker.select(options).then((uris: string[]) => {
        if (uris.length === 0) {
          return;
        }
        let ok: number = 0;
        let fail: number = 0;
        let lastName: string = '';
        for (let k = 0; k < uris.length; k++) {
          const meta: DocMeta | null = DocStore.importFromUri(ctx, uris[k]);
          if (meta === null) {
            fail++;
          } else {
            ok++;
            lastName = meta.name;
          }
        }
        this.refresh();
        if (ok === 1 && fail === 0) {
          this.toast('已导入《' + lastName + '》');
        } else if (fail === 0) {
          this.toast('已导入 ' + ok + ' 个文件');
        } else {
          this.toast('已导入 ' + ok + ' 个，失败 ' + fail + ' 个');
        }
      }).catch((err: BusinessError) => {
        this.toast('选择文件失败：' + err.message);
      });
    } catch (err) {
      this.toast(L10n.t('无法打开文件选择器'));
    }
  }

  private doRename(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const target: string = this.renameText.trim();
    if (target.length === 0) {
      this.toast(L10n.t('名称不能为空'));
      return;
    }
    if (target === this.renameFrom) {
      this.closeRename();
      return;
    }
    if (this.renameKind === 'folder') {
      if (DocStore.renameFolder(this.renameFrom, target)) {
        // 展开面板正开着这个文件夹时跟着改名，否则面板会停在旧名字上（内容找不到）
        if (this.openFolderName === this.renameFrom) {
          this.openFolderName = target;
        }
        this.closeRename();
        this.refresh();
        this.toast(L10n.t('文件夹已重命名'));
      } else {
        this.toast(L10n.t('重命名失败：名称非法或已存在'));
      }
      return;
    }
    if (DocStore.rename(ctx, this.renameFrom, target)) {
      this.closeRename();
      this.refresh();
      this.toast('已重命名为「' + target + '」');
    } else {
      this.toast(L10n.t('重命名失败：名称非法或已存在同名文档'));
    }
  }

  private askDeleteDoc(name: string): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    this.closeCellMenu();
    // 内置教程：正文在 rawfile 里删不掉 → 做的是「从书架移除 + 设置页可恢复」
    if (DocStore.isBuiltinName(name)) {
      this.getUIContext().getPromptAction().showDialog({
        title: L10n.t('移除内置教程'),
        message: L10n.t('将从书架移除《') + name + '》。正文不会被删除，随时可在「设置 → 数据管理」恢复。',
        buttons: [
          { text: L10n.t('取消'), color: this.palette().textSecondary },
          { text: L10n.t('移除'), color: '#FFD93B3B' }
        ]
      }).then((result) => {
        if (result.index !== 1) {
          return;
        }
        if (DocStore.hideBuiltin(ctx, name)) {
          this.playAbsorbAnim(name, () => {
            this.animatedRefresh();
            this.toast('已移除《' + name + '》，可在设置里恢复');
          });
        }
      }).catch((err: BusinessError) => {
        this.toast('操作失败：' + err.message);
      });
      return;
    }
    this.getUIContext().getPromptAction().showDialog({
      title: L10n.t('删除文档'),
      message: L10n.t('将删除《') + name + '》，此操作不可撤销。',
      buttons: [
        { text: L10n.t('取消'), color: this.palette().textSecondary },
        { text: L10n.t('删除'), color: '#FFD93B3B' }
      ]
    }).then((result) => {
      if (result.index !== 1) {
        return;
      }
      if (DocStore.remove(ctx, name)) {
        // 带"吸入"动画再刷新（删除也走统一动画路径）
        this.playAbsorbAnim(name, () => {
          this.animatedRefresh();
          this.toast('已删除《' + name + '》');
        });
      } else {
        this.toast(L10n.t('删除失败'));
      }
    }).catch((err: BusinessError) => {
      this.toast('操作失败：' + err.message);
    });
  }

  // ══════════════════════ 拖拽合并文件夹 ══════════════════════

  /**
   * 带动画的刷新：换位 / 收进文件夹 / 解散都走它。
   * 网格项用稳定 key（itemKey），所以 animateTo 里换掉 this.items 时
   * 系统会把位置变化、以及带 .transition 的出入场都做成动画。
   */
  private animatedRefresh(): void {
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.refresh();
    });
  }

  /**
   * 「吸入」动画：某一格缩小淡出（收进文件夹 / 换位 / 解散），
   * 结束后再真正落库 + 动画刷新。
   * 缩放与透明度由 cellScale()/cellOpacity() 按 absorbAt 取值，所以这里只需
   * 在 animateTo 里改 absorbAt 就能让过渡跑起来。
   */
  private playAbsorbAnim(name: string, done: () => void): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.absorbAt = name;
      this.hoverDropAt = '';
    });
    setTimeout(() => {
      done();
      setTimeout(() => {
        this.absorbAt = '';
      }, 280);
    }, 260);
  }

  /**
   * 格子缩放。
   *  · 合并中（书 → 文件夹）：收到 0.5，配合文件夹层从 0.5 长到 1，形成"书变文件夹"的形变
   *  · 被吸入（收进已有文件夹）：0.82，小一点即可
   *  · 拖拽悬停：0.94，只作"可以放这里"的提示
   */
  private cellScale(name: string): number {
    if (this.mergingAt === name) {
      return 0.5;
    }
    if (this.absorbAt === name) {
      return 0.82;
    }
    return this.hoverDropAt === name ? 0.94 : 1;
  }

  /**
   * 格子透明度。
   *  · 一镜到底飞行中：隐去
   *  · 合并中（本格是合并目标）：完全淡出，让位给"长出来"的文件夹层
   *  · 被吸入的那本：淡到 0.2
   */
  private cellAlpha(name: string, flying: boolean): number {
    if (flying) {
      return 0;
    }
    if (this.mergingAt === name) {
      return 0;
    }
    if (this.absorbAt === name) {
      return 0.2;
    }
    return 1;
  }

  /** 拖拽释放到某个文档格上。 */
  /** 拖拽悬停到文档上：登记目标并启动 1.5 秒换位计时（同上下文才可换位）。 */
  private trackSwapHover(targetName: string): void {
    this.cancelSwapHover();
    const dragged: string = this.draggingName;
    if (dragged.length === 0 || dragged.startsWith('folder:') || dragged === targetName) {
      return;
    }
    // 只有「同上下文」（同为散文档 / 同一文件夹内）才有换位意义
    if (DocStore.folderOfDoc(dragged) !== DocStore.folderOfDoc(targetName)) {
      return;
    }
    this.swapHoverTarget = targetName;
    this.swapTimer = setTimeout(() => {
      this.swapReadyName = targetName;
      this.swapTimer = -1;
    }, 1500);
  }

  /** 离开目标 / 拖拽结束：清掉换位状态与计时。 */
  private cancelSwapHover(): void {
    if (this.swapTimer !== -1) {
      clearTimeout(this.swapTimer);
      this.swapTimer = -1;
    }
    this.swapReadyName = '';
    this.swapHoverTarget = '';
  }

  /** 文档格的落点分流：悬停满 1.5 秒 → 交换位置；否则走原有归组 / 合并逻辑。 */
  private finishSwapOrDrop(targetName: string): void {
    // 落地即清悬停反馈：否则目标封面停在 0.94 缩小态，重启才恢复（用户实测）
    this.hoverDropAt = '';
    if (this.swapReadyName === targetName && this.draggingName.length > 0) {
      const dragged: string = this.draggingName;
      this.draggingName = '';
      this.cancelSwapHover();
      if (DocStore.swapShelfDocs(dragged, targetName)) {
        this.animatedRefresh();
        this.toast('已与「' + targetName + '」交换位置');
      }
      return;
    }
    this.cancelSwapHover();
    this.handleDropOnDoc(targetName);
  }

  private handleDropOnDoc(targetName: string): void {
    this.hoverDropAt = '';
    const dragged: string = this.draggingName;
    this.draggingName = '';
    if (dragged.length === 0 || dragged === targetName) {
      return;
    }
    // 拖来的是文件夹 → **与文档互换位置**（用户要求：文件夹要能和文件交换位置），
    // 先播「吸入」动画再落库换位
    if (dragged.startsWith('folder:')) {
      const from: string = dragged.substring(7);
      this.playAbsorbAnim(from, () => {
        if (DocStore.moveShelfEntry(DocStore.ORDER_FOLDER + from, DocStore.ORDER_DOC + targetName)) {
          this.animatedRefresh();
          this.toast('「' + from + '」已与「' + targetName + '」互换位置');
        }
      });
      return;
    }
    const targetFolder: string = DocStore.folderOfDoc(targetName);
    if (targetFolder.length > 0) {
      // 文档 → 文档（目标是文件夹里的文档）：收进该文件夹，带吸入动画
      this.playAbsorbAnim(dragged, () => {
        if (DocStore.addToFolder(targetFolder, dragged)) {
          this.animatedRefresh();
          this.toast('已收进「' + targetFolder + '」');
        }
      });
      return;
    }
    // 合并成文件夹：**先播形变动画**（书收到 0.5 淡出、文件夹层同步从 0.5 长出），
    // 形变到位后再真正合并；用 animatedRefresh 让旧格淡出、新文件夹格淡入，
    // 与浮层之间是无缝的交叉过渡（不是"啪一下直接换掉"）
    this.playMergeAnim(targetName, dragged, () => {
      const folder: ShelfFolder | null = DocStore.createFolderWith([targetName, dragged]);
      if (folder !== null) {
        this.animatedRefresh();
        this.toast('已合并为文件夹「' + folder.name + '」，点封面可查看');
      }
    });
  }

  /**
   * 合并成文件夹的动画（书 → 文件夹的形变）：
   *  ① 目标封面收到 0.5 并淡出，同时文件夹层从 0.5 长到 1（同一段动画 → 形变）
   *  ② 形变到位后真正合并并刷新：真实文件夹格在同一位置淡入，浮层随即撤掉
   *     （所以**不需要**再让浮层缩回去——那样会看到"文件夹又缩了一下"）
   * 状态只在事件回调里改（build 期间不写 @State）。
   */
  private playMergeAnim(target: string, source: string, done: () => void): void {
    this.mergingAt = target;
    this.mergeGrow = false;
    const absorb: boolean = source.length > 0 && source !== target;
    this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
      this.mergeGrow = true;
      // 被拖的那本书同步缩小淡出（"被吸进去"）—— 写在 animateTo 里才有过渡
      if (absorb) {
        this.absorbAt = source;
      }
    });
    setTimeout(() => {
      done();
      // 真实文件夹格已经在同一位置（.transition 淡入），浮层直接撤掉
      this.mergingAt = '';
      this.absorbAt = '';
    }, 520);
  }

  /** 拖拽释放到文件夹格上：文件夹 → 换位；文档 → 收进该文件夹。 */
  private handleDropOnFolder(folderName: string): void {
    this.hoverDropAt = '';
    const dragged: string = this.draggingName;
    this.draggingName = '';
    if (dragged.length === 0) {
      return;
    }
    // 拖来的是文件夹 → 换位（统一排序里换条目，文件夹与文档同一条流），带吸入动画
    if (dragged.startsWith('folder:')) {
      const from: string = dragged.substring(7);
      this.playAbsorbAnim(from, () => {
        if (DocStore.moveShelfEntry(DocStore.ORDER_FOLDER + from, DocStore.ORDER_FOLDER + folderName)) {
          this.animatedRefresh();
          this.toast('已把「' + from + '」移到「' + folderName + '」的位置');
        }
      });
      return;
    }
    // 文档 → 文件夹：收进该文件夹，带吸入动画
    this.playAbsorbAnim(dragged, () => {
      if (DocStore.addToFolder(folderName, dragged)) {
        this.animatedRefresh();
        this.toast('已收进「' + folderName + '」');
      }
    });
  }

  // ══════════════════════ 顶栏（大标题 + 原地展开搜索框） ══════════════════════

  /**
   * 书架宽屏判定（原：>760vp 顶栏收窄靠左、底栏收窄靠右、内容列限宽）。
   * **用户要求（2026-09-30）：仅竖屏与手机端界面一致**——
   * 竖屏（含平板竖屏）恒 false；横屏且 >760vp 才启用宽屏形态。
   */
  /** 平板放屏幕右下角、手机整行 */
  /** 多屏协同：窗口宽 ≥760vp 即启用大屏布局（不再要求横屏） */
  private isWideShelf(): boolean {
    return this.rootWidth > 760;
  }

  // ══════════════════════ 书架分页（书架 / 写作日志 / 文房） ══════════════════════
  //
  // 书架不再只是一页：左滑进「写作日志」（写作 + 阅读统计，回头看看卡置顶），
  // 右滑进「文房」（今日笺 / 复习卡片 / 全部待办 / 批注汇总的聚合桌面）。
  // 顶栏与底栏浮在所有页之上，标题随页切换；书架专属按钮只在书架页出现。

  private pageSwiper: SwiperController = new SwiperController();
  /** 当前分页：0 文房（左） · 1 书架（中，默认） · 2 写作日志（右） */
  @StorageLink('shelfPage') @Watch('onShelfPageStorage') shelfPage: number = 1;
  /** 最近一次真正应用到 Swiper 的页码（避免 Swiper onChange 与 AppStorage 回写互相触发） */
  private lastAppliedPage: number = 1;

  /** AppStorage 里的页码被外部（复习页退出等）改写时，同步拨动 Swiper。 */
  private onShelfPageStorage(): void {
    if (this.shelfPage !== this.lastAppliedPage) {
      this.lastAppliedPage = this.shelfPage;
      this.pageSwiper.changeIndex(this.shelfPage, false);
    }
  }
  /** 文房页 · 今日笺摘要行 */
  @State studyDigest: string[] = [];
  /** 文房页 · 今日到期复习卡数 */
  @State studyDue: number = 0;
  /** 文房页 · 复习总览摘要 */
  @State studyReviewSummary: string = '';
  /** 文房页 · 待办预览（前 3 条） */
  @State studyTasks: string[] = [];
  /** 文房页 · 待办总数 */
  @State studyTaskCount: number = 0;
  /** 文房页 · 今日笺 / 全部待办的**原地下拉**展开态（用户要求：不要弹窗） */
  @State studyDailyOpen: boolean = false;
  @State studyTasksOpen: boolean = false;
  /** 今日笺完整内容（下拉展开时展示） */
  @State studyDailyFull: string[] = [];
  /** 全部待办完整清单（下拉展开时展示，上限 50 条，**可勾选完成**） */
  @State studyTaskAll: TaskItem[] = [];
  /** 文房顶部「批注速记」预览行（存在复习卡片时展示） */
  @State studyAnnPreview: string[] = [];
  // ── 阅读统计卡（1.1.0 从写作日志页搬到书架）──
  @State readToday: number = 0;
  @State readWeek: number = 0;
  @State readWeekDays: number = 0;
  @State readTotal: number = 0;
  @State readTop: ReadDoc[] = [];
  /** 读过的文档数（打开过就算） */
  @State readDocCount: number = 0;
  /** 历史已读篇数（阅读日志里有留时记录的文档数） */
  @State readLogCount: number = 0;

  private pageTitle(): string {
    if (this.shelfPage === 0) {
      return '文房';
    }
    if (this.shelfPage === 2) {
      return '写作日志';
    }
    return '书架';
  }

  /** 切页后的联动：文房页重新取数（其余页数据随 refresh() 走）。 */
  private onShelfPageChanged(): void {
    if (this.shelfPage === 0) {
      this.refreshStudy();
    }
  }

  /** 阅读统计取数（书架阅读卡）：时长 + 两个篇数小卡。 */
  private loadReadingStats(): void {
    const c = this.ctx();
    if (c === null) {
      return;
    }
    try {
      ReadingLog.init(c);
      this.readToday = ReadingLog.secondsOn(readDayKey(Date.now()));
      const week: ReadRange = ReadingLog.lastDays(c, 7);
      this.readWeek = week.seconds;
      this.readWeekDays = week.activeDays;
      this.readTotal = ReadingLog.totalSeconds(c);
      this.readTop = ReadingLog.topDocs(c, 3);
      this.readLogCount = ReadingLog.topDocs(c, 999).length;
    } catch (err) {
      // 统计失败不影响书架
    }
    try {
      let n: number = 0;
      for (let k: number = 0; k < this.docs.length; k++) {
        if (this.docs[k].lastOpen > 0) {
          n++;
        }
      }
      this.readDocCount = n;
    } catch (err) {
      // 忽略
    }
  }

  /**
   * 阅读统计卡（1.1.0 从写作日志页搬到书架）：时长三格 + **两个篇数小卡**
   * （读过的文档 / 历史已读）+ 读得最多的几篇。
   */
  @Builder
  readingStatsCard() {
    ImmersiveCard({
      cardRadius: HwRadius.card,
      cardPadding: HwSpace.lg,
      palette: this.palette()
    }) {
      Column({ space: HwSpace.sm }) {
        Row({ space: HwSpace.xs }) {
          SymbolGlyph($r('sys.symbol.book'))
            .fontSize(18)
            .fontColor([this.palette().accent])
          Text(L10n.t('阅读'))
            .fontSize(HwType.label + 2)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.palette().textPrimary)
          Blank()
          Text(L10n.t('今日 ') + ReadingLog.human(this.readToday))
            .fontSize(HwType.caption)
            .fontColor(this.palette().accent)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: HwSpace.sm }) {
          this.readStatCell(ReadingLog.human(this.readToday), '今日阅读')
          this.readStatCell(ReadingLog.human(this.readWeek), '近 7 天')
          this.readStatCell(ReadingLog.human(this.readTotal), '累计阅读')
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        // 两个篇数小卡（用户要求）
        Row({ space: HwSpace.sm }) {
          this.readMiniCard($r('sys.symbol.doc_plaintext'),
            this.readDocCount + ' 篇', '读过的文档')
          this.readMiniCard($r('sys.symbol.clock'),
            this.readLogCount + ' 篇', '历史已读')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.readTop.length > 0) {
          ForEach(this.readTop, (d: ReadDoc) => {
            Row({ space: HwSpace.xs }) {
              Text(d.name)
                .fontSize(HwType.caption)
                .fontColor(this.palette().textSecondary)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(ReadingLog.human(d.seconds))
                .fontSize(HwType.caption)
                .fontColor(this.palette().accent)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }, (d: ReadDoc) => 'rt_' + d.name)
        }

        Text(L10n.t('近 7 天有 ') + this.readWeekDays + ' 天在读 · 只统计停留在本应用的时间')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 阅读时长统计格。 */
  @Builder
  readStatCell(value: string, label: string) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(HwType.label + 2)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.palette().textPrimary)
        .maxLines(1)
      Text(label)
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /** 篇数小卡：一个数字 + 一行说明（用户要求的"读过的文档 / 历史已读"）。 */
  @Builder
  readMiniCard(icon: Resource, value: string, label: string) {
    Row({ space: HwSpace.sm }) {
      SymbolGlyph(icon)
        .fontSize(16)
        .fontColor([this.palette().accent])
      Text(value)
        .fontSize(HwType.label + 1)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.palette().textPrimary)
      Text(label)
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
    }
    .layoutWeight(1)
    .padding({ top: HwSpace.xs, bottom: HwSpace.xs, left: HwSpace.sm, right: HwSpace.sm })
    .borderRadius(HwRadius.inner)
    .backgroundColor(this.palette().quoteBg)
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 文房页取数：与「今日笺 / 复习卡片 / 全部待办」的详情面板**同一数据源**
   * （DocStore / ReviewCardStore / TaskBoard），卡片上展示的就是详情里的内容，
   * 点卡片打开详情不会看到两套数字。
   */
  private refreshStudy(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const lines: string[] = [];
    const full: string[] = [];
    try {
      DocStore.init(ctx);
      const day: number = 24 * 60 * 60 * 1000;
      const now: number = Date.now();
      const list: DocMeta[] = DocStore.list(ctx);
      const changed: string[] = [];
      const opened: string[] = [];
      const reading: string[] = [];
      for (let k = 0; k < list.length; k++) {
        const m: DocMeta = list[k];
        if (now - m.mtime <= day && changed.length < 5) {
          changed.push(m.name);
        }
        if (m.lastOpen > 0 && now - m.lastOpen <= day && opened.length < 5) {
          opened.push(m.name);
        }
        if (m.progressRatio > 0.01 && m.progressRatio < 0.99 && reading.length < 5) {
          reading.push(m.name + ' ' + Math.round(m.progressRatio * 100) + '%');
        }
      }
      lines.push('今日修改：' + (changed.length > 0 ? changed.join('、') : L10n.t('无')));
      lines.push('今日读过：' + (opened.length > 0 ? opened.join('、') : L10n.t('无')));
      lines.push('读到一半：' + (reading.length > 0 ? reading.join('、') : L10n.t('无')));
      // 下拉展开时的完整版（与原「今日笺」弹窗同一套口径）
      full.push('【今日修改】' + (changed.length > 0 ? changed.join('、') : L10n.t('无')));
      full.push('【今日读过】' + (opened.length > 0 ? opened.join('、') : L10n.t('无')));
      full.push('【读到一半】' + (reading.length > 0 ? reading.join('、') : L10n.t('无')));
    } catch (err) {
      lines.push('书架数据读取失败');
    }
    this.studyDigest = lines;
    this.studyDailyFull = full;
    try {
      const due: ReviewCard[] = ReviewCardStore.dueToday(ReviewCardStore.load(ctx));
      this.studyDue = due.length;
      const st: ReviewStats = ReviewCardStore.stats(ReviewCardStore.load(ctx));
      this.studyReviewSummary = ReviewCardStore.summary(st);
    } catch (err) {
      this.studyDue = 0;
      this.studyReviewSummary = '复习数据读取失败';
    }
    try {
      const seeds: ReviewSeed[] = this.buildReviewSeeds(ctx);
      ReviewCardStore.sync(ctx, seeds);
      const cards: ReviewCard[] = ReviewCardStore.load(ctx);
      // 批注速记预览：优先给到期的（最该看的），没有就从全部卡里挑前三张
      const due: ReviewCard[] = ReviewCardStore.dueToday(cards);
      const pool: ReviewCard[] = due.length > 0 ? due : cards;
      const preview: string[] = [];
      for (let k: number = 0; k < pool.length && k < 3; k++) {
        preview.push(pool[k].front + '（' + pool[k].docName + '）');
      }
      this.studyAnnPreview = preview;
    } catch (err) {
      this.studyAnnPreview = [];
    }
    try {
      // **收全部（含已完成）**：用户要求勾选后划线保留在清单里，而不是消失
      const t: TaskBoardResult = TaskBoard.collect(ctx, false);
      this.studyTaskCount = t.open;
      const heads: string[] = [];
      for (let k = 0; k < t.items.length; k++) {
        if (t.items[k].done) {
          continue;
        }
        const one: string = t.items[k].text + '（' + t.items[k].docName + '）';
        if (heads.length < 3) {
          heads.push(one);
        }
      }
      this.studyTasks = heads;
      // 下拉清单直接用条目对象：勾选完成需要 docName + line（TaskBoard.toggle）
      this.studyTaskAll = t.items.length > 50 ? t.items.slice(0, 50) : t.items;
    } catch (err) {
      this.studyTaskCount = 0;
      this.studyTasks = [];
      this.studyTaskAll = [];
    }
  }

  // ══════════════════════ 底栏（统计 + 快捷新建 / 导入） ══════════════════════
  //
  // 用户要求：快捷「新建 / 导入」按钮**放在底部那颗悬浮胶囊里面**（不是旁边另挂一颗），
  // 走沉浸光感材质（材质由 ImmersiveBar 统一承载），点击新建文档、长按导入文档。
  // 按钮本体与统计文字同在胶囊内的那一行里，见 bottomBar()。

  // ══════════════ 顶栏胶囊调参区（大屏横屏）· 只改这里 ══════════════
  //
  // 【① 胶囊长度】三个状态各一行 return，直接改数字（单位 vp）：
  //   计算口径：10(左内边距) + 36×按钮数 + 6×(按钮数−1) + 10(右内边距)
  //     · 书架页 4 钮（搜索/视图/导入/设置）= 182 → 写 186（多 4 给渲染误差）
  //     · 文房 / 写作日志页 2 钮（搜索/设置）= 98 → 写 102（这就是「缩小后」的长度）
  //   数值越大胶囊越长；barWidth 直接取本方法，改这里即生效。
  private topPillWidth(): number {
    if (this.searchExpanded) {
      return 420;   // ← 搜索框展开态
    }
    if (this.shelfPage === 1) {
      return 186;   // ← 书架页（4 钮）
    }
    return 102;     // ← 文房 / 写作日志页（2 钮）= 缩小后
  }
  //
  // 【② 整体左右位移】胶囊右边缘距屏幕右边的留白（vp）。
  //   调大 = 整条胶囊往左移；调小 = 往右贴边。
  //   **顶栏、底栏、页数指示器三处共用这一个值**（改一处三者同步对齐）。
  private wideBarInset(): number {
    return HwSpace.lg;   // ← 默认 20
  }
  //
  // 【③ 底栏「回到书架」胶囊长度】文房 / 写作日志页的底栏（页数指示器也按它取中）
  private homePillWidth(): number {
    return 190;          // ← 默认 190
  }
  //
  // 【④ 书架页底栏胶囊长度】在 bottomBar() 里，搜 `barWidth: this.isWideShelf() ? 400`
  // ═══════════════════════════════════════════════════════════════════

  @Builder
  topBar() {
    // 顶栏从「占位的标题行」升级为**悬浮材质胶囊**（ImmersiveBar）：
    // 沉浸光感 + 悬浮，滚动内容从它下面穿过（Grid 顶部 padding 已为 0）。
    // 按钮从 38 收到 36：胶囊内高 52-8=44，36 上下各留 4 的余量，描边不被切。
    ImmersiveBar({
      palette: this.palette(),
      barPaddingH: HwSpace.sm,
      barPaddingV: 4,
      barHeight: HwBar.pill,
      // **平板放屏幕右上角**：宽屏胶囊只装按钮（标题固定在左上角，不进胶囊）。
      // 宽度取 topPillWidth()、位置取 wideBarInset() —— 都在本文件「顶栏胶囊调参区」
      // （紧邻 topBar() 上方），要调长度 / 位移改那两处即可。
      barWidth: this.isWideShelf() ? this.topPillWidth() : '100%'
    }) {
    Row({ space: HwSpace.xs }) {
      if (this.searchExpanded) {
        // 展开态：搜索框占满整行。它与收起态的搜索按钮**不再共享
        // geometryTransition id**（残留几何会把收起态按钮挤偏，见下方注释）。
        Row({ space: HwSpace.xs }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(17)
            .fontColor([this.palette().textTertiary])
          TextInput({ text: this.searchQuery, placeholder: L10n.t('在全部文档中搜索…') })
            .id('shelfSearchInput')
            .layoutWeight(1)
            .height('100%')
            .fontSize(HwType.label + 2)
            .fontColor(this.palette().textPrimary)
            .placeholderColor(this.palette().textTertiary)
            .backgroundColor('#00000000')
            // **四边内边距都要清零**：只清左右时，上下保留 TextInput 默认的内边距（约 12），
            // 36 高的输入框文字区被压到只剩一半 → 占位文字下半截被裁掉
            .padding({ left: 0, right: 0, top: 0, bottom: 0 })
            .maxLines(1)
            .defaultFocus(true)
            .onChange((value: string) => {
              this.runShelfSearch(value);
            })
          if (this.searchQuery.trim().length > 0) {
            Text(this.searchHits.length > 0 ? '' + this.searchHits.length : '0')
              .fontSize(HwType.caption)
              .fontColor(this.palette().accent)
          }
          ImmersiveIconButton({
            buttonSize: 34,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              this.collapseSearch();
            }
          }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(15)
              .fontColor([this.palette().textSecondary])
          }
        }
        .layoutWeight(1)
        .padding({ left: HwSpace.sm, right: HwSpace.xs, top: 4, bottom: 4 })
        .borderRadius(HwRadius.pill)
        .onClick(() => {
          // 收起输入法后再点搜索框：主动请求焦点，唤回键盘（用户反馈点不弹键盘）
          try {
            this.getUIContext().getFocusController().requestFocus('shelfSearchInput');
          } catch (err) {
            // 焦点请求失败无副作用
          }
        })
        // **不再铺 quoteBg**：默认调色板的 quoteBg 是 28% 透明的主题蓝，
        // 搜索框整圈发蓝（用户要求去掉）。外层 ImmersiveBar 胶囊本身就是
        // 沉浸光感底，这里保持全透明即可。
        .backgroundColor('#00000000')
        // ⚠️ **不做共享元素**（用户反馈：「点搜索后长度和位置就全恢复正常」= 残留几何）——
        // 与阅读页同一条教训（见 Reader.topBar 的注释）：搜索按钮与查找条共用
        // geometryTransition id 时，节点被移除的瞬间会把**最后一帧的几何**留在对方身上，
        // 收起态的搜索按钮于是带着查找条那一帧的宽/位渲染 → 把胶囊内其余按钮整体挤偏
        // （观感：按钮全右移、胶囊长度不对），且一直保持到下一次展开/收起才复位。
        // 展开/收起动画交给胶囊宽度插值 + 内容自身过渡，这里不再共享 id。
      } else {
        // **搜索按钮放到「书架」标题左边**（用户要求；手机端 + 大屏竖屏同此布局，
        // 宽屏横屏标题不进胶囊、保持原按钮顺序）
        // **搜索按钮常驻**（用户要求：保留不消失）；**原地把搜索展开**（用户反馈：
        // 没必要切回书架首页）—— 搜索结果本来就是全文档范围的，落到哪页都能点开
        if (!this.isWideShelf()) {
          Stack() {
            ImmersiveIconButton({
              buttonSize: 36,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.expandSearch();
              }
            }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(18)
                .fontColor([this.palette().textPrimary])
            }
          }
          .width(36)
          .height(36)
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 220, curve: Curve.FastOutSlowIn })
            .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 })))

          Column({ space: 1 }) {
            // 页名切换用**渐入渐出**（用户反馈硬切太突兀）：旧页名淡出、新页名淡入
            if (this.shelfPage === 0) {
              Text(L10n.t('文房'))
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.palette().textPrimary)
                .transition(TransitionEffect.OPACITY
                  .animation({ duration: 220, curve: Curve.FastOutSlowIn }))
            } else if (this.shelfPage === 2) {
              Text(L10n.t('写作日志'))
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.palette().textPrimary)
                .transition(TransitionEffect.OPACITY
                  .animation({ duration: 220, curve: Curve.FastOutSlowIn }))
            } else {
              Text(L10n.t('书架'))
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.palette().textPrimary)
                .transition(TransitionEffect.OPACITY
                  .animation({ duration: 220, curve: Curve.FastOutSlowIn }))
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        } else {
          // ⚠️ **这里不能放 Blank().layoutWeight(1)**：宽屏胶囊是「定宽 + 按钮数收缩」，
          // 余量被 Blank 吃掉会把按钮整组推到胶囊右半边（用户反馈「按钮全都右移」）。
          // 交给外层 Row 的 justifyContent(Center) 均分两侧余量，左右对称。

          // **搜索按钮常驻**（用户要求）：原地把搜索展开，不切回书架
          Stack() {
            ImmersiveIconButton({
              buttonSize: 36,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.expandSearch();
              }
            }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(18)
                .fontColor([this.palette().textPrimary])
            }
          }
          .width(36)
          .height(36)
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 220, curve: Curve.FastOutSlowIn })
            .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 })))
        }

      // 视图切换（网格 / 树形）是书架页专属：只在书架页显示
      if (this.shelfPage === 1) {
        // ⚠️ ImmersiveIconButton 是「组件 + 尾随闭包」，闭包后不能再链属性 ——
        // 过渡动画挂在外层 Stack 上
        Stack() {
          ImmersiveIconButton({
            buttonSize: 36,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              this.toggleShelfMode();
            }
          }) {
            SymbolGlyph(this.treeMode ? $r('sys.symbol.square_grid_2x2') : $r('sys.symbol.list_bullet'))
              .fontSize(18)
              .fontColor([this.palette().textPrimary])
          }
        }
        .transition(TransitionEffect.OPACITY
          .animation({ duration: 220, curve: Curve.FastOutSlowIn })
          .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 })))
      }

      // 导入文档同样是书架动作：只在书架页显示
      if (this.shelfPage === 1) {
        Stack() {
          ImmersiveIconButton({
            buttonSize: 36,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              this.importDoc();
            }
          }) {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(18)
              .fontColor([this.palette().textPrimary])
          }
        }
        .transition(TransitionEffect.OPACITY
          .animation({ duration: 220, curve: Curve.FastOutSlowIn })
          .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 })))
      }

        ImmersiveIconButton({
          buttonSize: 36,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            this.openSettingsPage();
          }
        }) {
          SymbolGlyph($r('sys.symbol.gearshape'))
            .fontSize(18)
            .fontColor([this.palette().textPrimary])
        }
      }
    }
    // **居中排列**：把宽度余量均分到两侧 → 左右间距恒等（用户要求对称）。
    // ⚠️ 必须显式 width('100%')：ImmersiveBar 的内容包装 Row 默认 Start 对齐，
    // 子 Row 不加宽度就只会按内容尺寸靠左——此时的 justifyContent 是空转，
    // 加上任何 Blank/layoutWeight 就会把按钮推偏（真机「按钮全右移」实锤）。
    .width('100%')
    .justifyContent(FlexAlign.Center)
    }
    // 注意：ImmersiveBar 是「自定义组件 + 尾随闭包」，不能再链式调属性；
    // 宽度已经用 barWidth 参数传入。
  }

  /**
   * 搜索结果下拉：非模态，盖在网格上方，点结果直达。
   *
   * **外壳**走沉浸光感承载层（照 miha_hm「Toggle 承载方案」的 Stack 分层）。
   *
   * 三层自下而上：① 降级层 → ② 承载层 → ③ 内容层。
   * 两条硬规则决定了这里的写法（照抄参考项目文档结论）：
   *   · **材质的视觉层级位于 backgroundColor / backgroundBlurStyle 之下**——
   *     所以降级层在材质生效时必须全透明，否则实色底会把材质整块盖住
   *     （这正是改前"挂了承载层却毫无光感"的原因）；
   *   · **承载层必须是 Toggle**（内容区的 Column/Row 挂 systemMaterial 不渲染、不报错）。
   * 内容层的缩进与写法保持不变，单独放在 searchResultsBody() 里。
   */
  @Builder
  searchResultsPanel() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ① 降级层：材质不可用时才可见（磨砂底，与顶/底栏同一配方）
      Column()
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .borderRadius(HwRadius.card)
        .backgroundColor(this.materialOn() ? '#00000000' : barFrostColor(this.palette().surface))
        .backgroundBlurStyle(this.materialOn() ? BlurStyle.NONE : BlurStyle.Thin)
        .hitTestBehavior(HitTestMode.None)

      // ② 材质承载层：隐形 Toggle 画布。材质采样的是它**背后窗口里的内容**，
      //    搜索展开时书架整体被模糊（cellBlur），玻璃后面就是那片模糊的书架。
      ImmersiveCardLayer({ layerRadius: HwRadius.card, layerShadow: false })

      // ③ 内容层：**包 Scroll**（用户实测：内容超高被 420 上限裁掉且不可滚，
      // 上滑手势还会穿透到书架网格、触发"搜索展开时滚动即收起搜索"）——
      // Scroll 消费掉面板内的滑动，内容超高时在面板内滚动；
      // 点击（结果卡片 / 空白）仍会冒泡到外壳的 onClick 收起逻辑，不受影响。
      Scroll() {
        this.searchResultsBody()
      }
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .constraintSize({ maxHeight: 420 })
    }
    .width('100%')
    .borderRadius(HwRadius.card)
    // 描边留在外壳上：材质画在 border 之下，细描边正好勾出玻璃边缘
    .border({ width: 0.8, color: this.palette().surfaceBorder })
    .clip(true)
    // **面板内的空白（组标题、卡片之间的缝隙）点一下也收起搜索**：
    // 用户要求"除了结果卡片本身，点任意区域都能退出搜索"。
    // 卡片自己的 onClick 会先消费点击（打开文档 / 放大图片），
    // 没被卡片接住的点击才冒泡到这里 → 收起。
    .onClick(() => {
      // 图片卡片的 onClick 会先执行（子先于父）并打开图片浮层，
      // 这里据此判断：浮层已打开就说明点击落在图片卡上 → 不要顺手把搜索收掉。
      // （ClickEvent 没有 stopPropagation，所以用「子先父后 + 状态判断」实现等效拦截。）
      if (this.imgPreviewSrc.length === 0) {
        this.collapseSearch();
      }
    })
    // **出现 / 收起的过渡**：从顶缘「伸长」出来（高度方向缩放）+ 淡入 + 轻微位移，
    // 收起时反向缩回。用 scale 的 centerY: 0 让缩放钉在面板顶缘，看起来就是往下长出来。
    .transition(TransitionEffect.OPACITY
      .animation({ duration: 240, curve: Curve.FastOutSlowIn })
      .combine(TransitionEffect.scale({ x: 1, y: 0.9, centerX: '50%', centerY: 0 }))
      .combine(TransitionEffect.translate({ y: -10 })))
  }

  /** 搜索结果面板**内容**（文件名 / 正文 / 图片三组 + 空态）。 */
  @Builder
  searchResultsBody() {
    Column({ space: HwSpace.xs }) {
      if (this.searchQuery.trim().length === 0) {
        Text(L10n.t('输入关键词，搜索文件名与全部文档正文'))
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .width('100%')
          .padding({ left: HwSpace.sm, top: HwSpace.xxs, bottom: HwSpace.xxs })
      } else if (this.searchNameHits.length === 0 && this.searchContentHits.length === 0
        && this.searchImageHits.length === 0) {
        // **空态也放在卡片里**（用户要求：稍大的卡片、居中、正常字号）
        Column() {
          Text(L10n.t('没有匹配的文件名、正文或图片'))
            .fontSize(HwType.label)
            .fontColor(this.palette().textSecondary)
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ top: HwSpace.xl, bottom: HwSpace.xl, left: HwSpace.md, right: HwSpace.md })
        .borderRadius(HwRadius.card)
        // **材质生效时绝不能铺不透明底**：沉浸光感的视觉层级位于 backgroundColor 之下，
        // 实色底会把材质整块盖住（表现为"挂了承载层却一点光感都没有"）。
        // 只有在材质不可用时才用磨砂底兜底 —— 与顶/底栏 barFrostColor 同一套配方。
        .backgroundColor(this.materialOn() ? '#00000000' : barFrostColor(this.palette().surface))
        .backgroundBlurStyle(this.materialOn() ? BlurStyle.NONE : BlurStyle.Thin)
        // **出现 / 消失过渡**（用户要求）
        .transition(TransitionEffect.OPACITY
          .animation({ duration: 220, curve: Curve.FastOutSlowIn })
          .combine(TransitionEffect.translate({ y: -8 })))
      } else {
        // ══ ① 文档（文件名命中：展示具体文档，参考系统搜索的卡片样式）══
        if (this.searchNameHits.length > 0) {
          Text(L10n.t('文档'))
            .fontSize(HwType.label + 5)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.palette().textPrimary)
            .width('100%')
            // 上/下留白与左间距取同一档（HwSpace.md）：标题整体下移一档，三边留白一致
            .padding({ left: HwSpace.md, top: HwSpace.md, bottom: HwSpace.md })

          Column() {
            ForEach(this.searchNameHits, (hit: DocSearchHit, index: number) => {
              Row({ space: HwSpace.sm }) {
                // 文件类型图标：圆角方块底 + 白色文档图标
                Stack() {
                  SymbolGlyph($r('sys.symbol.doc_plaintext'))
                    .fontSize(20)
                    .fontColor(['#FFFFFFFF'])
                }
                .width(40)
                .height(40)
                .borderRadius(10)
                .backgroundColor(this.palette().accent)

                Column({ space: 3 }) {
                  Text(hit.name)
                    .fontSize(HwType.label + 1)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.palette().textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(hit.builtin ? L10n.t('内置文档') : L10n.t('我的文档'))
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textTertiary)
                    .maxLines(1)
                  Text(DocStore.formatSize(hit.size) + ' · ' + DocStore.formatTime(hit.mtime))
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textTertiary)
                    .maxLines(1)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                // 打开箭头（参考图右侧的圆形箭头）
                SymbolGlyph($r('sys.symbol.arrow_up_right'))
                  .fontSize(17)
                  .fontColor([this.palette().textSecondary])
              }
              .width('100%')
              // **淡磨砂底**（用户要求）：每条命中自带一层半透明磨砂 + 圆角 +
              // 行间距，条目之间有了明确分界；材质生效时它与面板玻璃叠出层次，
              // 材质不可用时也仍是一层可见的浅底（withAlpha 保证不吃掉模糊）。
              .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 9, bottom: 9 })
              .borderRadius(HwRadius.inner)
              // 半透明磨砂底：三组（文档 / 内容 / 图片）**同一档**，保证观感一致。
              // 45% 太淡时在白玻璃上几乎看不出来（用户反馈"图片卡片没有半透明效果"），
              // 提到 60% —— 仍是半透明，但卡片边界明确可见。
              .backgroundColor(withAlpha(this.palette().surface, '99'))
              .backgroundBlurStyle(BlurStyle.Thin)
              .margin({ bottom: HwSpace.xs })
              // 逐条出现 / 消失的过渡（用户要求：结果的出现与伸长收起都要有动画）
              .transition(TransitionEffect.OPACITY
                .animation({ duration: 180, curve: Curve.FastOutSlowIn }))
              .onClick(() => {
                this.openSearchHit(hit);
              })
            }, (hit: DocSearchHit, index: number) => 'nm' + index + '_' + hit.name)

          }
          .width('100%')
          .padding({ left: HwSpace.md, right: HwSpace.md, top: 2, bottom: 2 })
          .borderRadius(HwRadius.card)
          // 材质生效时透明：光感由**最外层搜索面板**的承载层统一出（单层材质）。
          // 这里若再挂一层承载，就成了"玻璃上再叠一块玻璃"——两层都采样同一片背景，
          // 叠出来发白浑浊，反而不像光感。
          .backgroundColor(this.materialOn() ? '#00000000' : barFrostColor(this.palette().surface))
          .backgroundBlurStyle(this.materialOn() ? BlurStyle.NONE : BlurStyle.Thin)
          // **出现 / 消失过渡**（用户要求）
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 220, curve: Curve.FastOutSlowIn })
            .combine(TransitionEffect.translate({ y: -8 })))
        }

        // ══ ② 内容（正文命中：展示出现这段内容的具体文件）══
        if (this.searchContentHits.length > 0) {
          Text(L10n.t('内容'))
            .fontSize(HwType.label + 5)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.palette().textPrimary)
            .width('100%')
            // 上/下留白与左间距取同一档（HwSpace.md）：标题整体下移一档，三边留白一致
            .padding({ left: HwSpace.md, top: HwSpace.md, bottom: HwSpace.md })

          Column() {
            ForEach(this.searchContentHits, (hit: DocSearchHit, index: number) => {
              Row({ space: HwSpace.sm }) {
                Stack() {
                  SymbolGlyph($r('sys.symbol.text_alignleft'))
                    .fontSize(20)
                    .fontColor(['#FFFFFFFF'])
                }
                .width(40)
                .height(40)
                .borderRadius(10)
                // **实色主题色底**：原来用 accentSoft（28% 主题色薄底）配白图标，
                // 白字压在浅薄底上几乎看不见（用户反馈"内容图标看不清"）。
                // 实色底 + 白图标对比度立刻拉开，与「文档」组同一档观感。
                .backgroundColor(this.palette().accent)

                Column({ space: 3 }) {
                  // 命中片段（关键词加粗高亮）
                  Text() {
                    ForEach(hit.snippetParts, (part: string, pi: number) => {
                      Span(part)
                        .fontSize(HwType.label)
                        .fontWeight(pi % 2 === 1 ? FontWeight.Bold : FontWeight.Normal)
                        .fontColor(pi % 2 === 1 ? this.palette().accent : this.palette().textPrimary)
                    }, (part: string, pi: number) => 'sp' + index + '_' + pi)
                  }
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  // **出自哪个文件**
                  Text(hit.name)
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textTertiary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(DocStore.formatSize(hit.size) + ' · ' + DocStore.formatTime(hit.mtime))
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textTertiary)
                    .maxLines(1)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                SymbolGlyph($r('sys.symbol.arrow_up_right'))
                  .fontSize(17)
                  .fontColor([this.palette().textSecondary])
              }
              .width('100%')
              // **淡磨砂底**（用户要求）：每条命中自带一层半透明磨砂 + 圆角 +
              // 行间距，条目之间有了明确分界；材质生效时它与面板玻璃叠出层次，
              // 材质不可用时也仍是一层可见的浅底（withAlpha 保证不吃掉模糊）。
              .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 9, bottom: 9 })
              .borderRadius(HwRadius.inner)
              // 半透明磨砂底：三组（文档 / 内容 / 图片）**同一档**，保证观感一致。
              // 45% 太淡时在白玻璃上几乎看不出来（用户反馈"图片卡片没有半透明效果"），
              // 提到 60% —— 仍是半透明，但卡片边界明确可见。
              .backgroundColor(withAlpha(this.palette().surface, '99'))
              .backgroundBlurStyle(BlurStyle.Thin)
              .margin({ bottom: HwSpace.xs })
              // 逐条出现 / 消失的过渡（用户要求：结果的出现与伸长收起都要有动画）
              .transition(TransitionEffect.OPACITY
                .animation({ duration: 180, curve: Curve.FastOutSlowIn }))
              .onClick(() => {
                this.openSearchHit(hit);
              })
            }, (hit: DocSearchHit, index: number) => 'ct' + index + '_' + hit.name)

          }
          .width('100%')
          .padding({ left: HwSpace.md, right: HwSpace.md, top: 2, bottom: 2 })
          .borderRadius(HwRadius.card)
          // 与「文件」组同款：材质生效时透明，单层材质由外层搜索面板承载
          .backgroundColor(this.materialOn() ? '#00000000' : barFrostColor(this.palette().surface))
          .backgroundBlurStyle(this.materialOn() ? BlurStyle.NONE : BlurStyle.Thin)
          // **出现 / 消失过渡**（用户要求）
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 220, curve: Curve.FastOutSlowIn })
            .combine(TransitionEffect.translate({ y: -8 })))
        }

        // ══ ③ 图片（图片文件名命中：名称 + 缩略图，横向滚动）══
        if (this.searchImageHits.length > 0) {
          Text(L10n.t('图片'))
            .fontSize(HwType.label + 5)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.palette().textPrimary)
            .width('100%')
            // 上/下留白与左间距取同一档（HwSpace.md）：标题整体下移一档，三边留白一致
            .padding({ left: HwSpace.md, top: HwSpace.md, bottom: HwSpace.md })

          // **竖向通栏列表**（用户要求）：卡片宽度与「文档 / 内容」两组**完全一致**（撑满面板），
          // 不再做横向滚动的窄卡片；每张卡内部是「左缩略图 + 右文字」，整体靠左对齐。
          Column() {
            ForEach(this.searchImageHits, (img: DocImageHit, index: number) => {
              Row({ space: HwSpace.sm }) {
                Image('file://' + encodeURI(img.path))
                  .width(SEARCH_IMAGE_THUMB)
                  .height(SEARCH_IMAGE_THUMB)
                  .borderRadius(10)
                  .objectFit(ImageFit.Cover)
                  .draggable(false)

                Column({ space: 3 }) {
                  Text(img.name)
                    .fontSize(HwType.label + 1)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.palette().textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .textAlign(TextAlign.Start)
                  // 大小 · 分辨率（读不到尺寸时写「尺寸未知」，不留空行）
                  Text(DocStore.formatSize(img.size)
                    + ' · ' + ((img.width > 0 && img.height > 0)
                      ? (img.width + ' × ' + img.height) : L10n.t('尺寸未知')))
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textTertiary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                SymbolGlyph($r('sys.symbol.arrow_up_right'))
                  .fontSize(17)
                  .fontColor([this.palette().textSecondary])
              }
              .width('100%')
              .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 9, bottom: 9 })
              .borderRadius(HwRadius.inner)
              // 与「文档 / 内容」两组明细行同一档淡磨砂底
              // 半透明磨砂底：三组（文档 / 内容 / 图片）**同一档**，保证观感一致。
              // 45% 太淡时在白玻璃上几乎看不出来（用户反馈"图片卡片没有半透明效果"），
              // 提到 60% —— 仍是半透明，但卡片边界明确可见。
              .backgroundColor(withAlpha(this.palette().surface, '99'))
              .backgroundBlurStyle(BlurStyle.Thin)
              .margin({ bottom: HwSpace.xs })
              // 逐条出现 / 消失的过渡
              .transition(TransitionEffect.OPACITY
                .animation({ duration: 180, curve: Curve.FastOutSlowIn }))
              .onClick(() => {
                // 看完大图关掉后还要能接着看别的图 → 打开浮层后**不收搜索**
                // （面板外壳的 onClick 会读 imgPreviewSrc 判断，见 searchResultsPanel）
                this.openImagePreview(img);
              })
            }, (img: DocImageHit, index: number) => 'im' + index + '_' + img.name)
          }
          .width('100%')
          .padding({ left: HwSpace.md, right: HwSpace.md, top: 2, bottom: 2 })
          .borderRadius(HwRadius.card)
          // 同「文档 / 内容」两组：材质生效时透明，由外层承载层出光感
          .backgroundColor(this.materialOn() ? '#00000000' : barFrostColor(this.palette().surface))
          .backgroundBlurStyle(this.materialOn() ? BlurStyle.NONE : BlurStyle.Thin)
          // **出现 / 消失过渡**（用户要求）
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 220, curve: Curve.FastOutSlowIn })
            .combine(TransitionEffect.translate({ y: -8 })))
        }

        if (this.searchHits.length > SEARCH_PANEL_MAX) {
          Text(L10n.t('共 ') + this.searchHits.length + ' 条命中，仅显示前 ' + SEARCH_PANEL_MAX + ' 条')
            .fontSize(HwType.caption - 1)
            .fontColor(this.palette().textTertiary)
            .width('100%')
            .textAlign(TextAlign.Center)
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ══════════════════════ 封面网格 ══════════════════════

  /** 封面底部居中的细进度条 + 右下角百分比胶囊（见文件末尾的 CoverProgressBar 组件）。 */

  /** 封面 + 标题 + 日期的格子本体（拖拽属性在外层 Column 上，内置教程与自建文档同款）。 */
  @Builder
  coverContent(meta: DocMeta, inPanel: boolean) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Column() {
          DocCover({
            // **显示名优先用 Front Matter 的 `title:`**（封面配色仍按文件名哈希，
            // 所以改了标题不会连带换色）
            title: DocStore.displayName(meta),
            builtin: meta.builtin,
            coverTop: coverColorsOf(meta.name, meta.builtin).top,
            coverBottom: coverColorsOf(meta.name, meta.builtin).bottom,
            coverInk: coverColorsOf(meta.name, meta.builtin).ink,
            edgeColor: this.palette().divider,
            // 用户自定义：底色 / 封面图 / 是否显示名称
            coverColor: this.coverColorOf(meta),
            coverImage: this.coverImageSrc(meta.coverImage),
            hideName: meta.hideCoverName === true
            // 封面右上角的格式角标（MD / TXT）已按用户要求移除
          })
        }
        // 跨页共享元素：与阅读页详情头封面同 id，实现「一镜到底」
        // 供一镜到底测量：跳转前按此 id 取这一格在窗口中的真实矩形
        .id('covercell_' + meta.name)
        .width('100%')
        .aspectRatio(0.72)
        // 缩放 / 透明度统一由外层 GridItem 按 cellScale() / gridItemAlpha() 施加：
        // 悬停轻微缩小、合并与"吸入"时更明显，文档与文件夹走同一套
        .onClick((event: ClickEvent) => {
          // 带上点击坐标：阅读页据此从这一格放大展开
          // **面板展开时背后的格子不响应**；面板内的格子（inPanel）照常打开
          if (!inPanel && this.openFolderName.length > 0) {
            return;
          }
          this.openDoc(meta, event);
        })
        // 记录封面在窗口中的矩形：一镜到底要从这一格长出来、缩回去
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.rememberDocRect(meta.name, newValue);
        })

        // 收藏标记：**左上角红色爱心圆钮**（沉浸光感承载，仅收藏的文档显示；点击取消收藏）
        // starredDocs 是 DocMeta[]（含完整信息），按名称匹配当前格
        if (!this.multiSelect && this.starredDocs.findIndex((d: DocMeta) => d.name === meta.name) >= 0) {
          Stack() {
            ImmersiveIconButton({
              buttonSize: 30,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                // 点击爱心 = 取消收藏（与「⋯」菜单里的取消收藏同一通道）
                const c = this.ctx();
                if (c === null) {
                  return;
                }
                if (DocStore.setStarred(c, meta.name, false)) {
                  this.starredDocs = DocStore.starredList(c, this.starSort);
                  // 「⋯」面板开着且正指向这篇 → 同步菜单文案（否则要重开面板才变）
                  if (this.cellMenuFor === meta.name) {
                    this.cellMenuStarred = false;
                  }
                  this.toast(L10n.t('已取消收藏'));
                }
              }
            }) {
              SymbolGlyph($r('sys.symbol.heart_fill'))
                .fontSize(16)
                .fontColor(['#FFFF4D6D'])
            }
          }
          .width(30)
          .height(30)
          // 顶 / 左偏移 4：与右上角 ⋯ 按钮（margin top/right 4）同一水平线
          .position({ x: 4, y: 4 })
        }

        if (!this.multiSelect) {
          Column() {
            ImmersiveIconButton({
              // 26 → 30（用户反馈"右上角按钮看上去太小"，14vp 图标也确实偏小）
              buttonSize: 30,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                if (!inPanel && this.openFolderName.length > 0) {
                  return;
                }
                this.openCellMenu('doc', meta.name, meta.builtin);
              }
            }) {
              Image($r('app.media.more_dots'))
                // 14 → 18（用户反馈图标太小）
                .width(18)
                .height(18)
                .fillColor(this.palette().textSecondary)
            }
          }
          .margin({ top: 4, right: 4 })
        }

        // 阅读进度：底部居中细进度条 + 右下角百分比胶囊（**独立组件**）
        // ⚠️ 进度值进了格子指纹 → 进度变化会重建格子 → 新建节点无法播放属性动画
        //（初始即终值，"和直接切换没区别"是用户实测反馈）。所以进度条自己记住
        // 上次显示的比例，挂载后从旧值**平滑长到新值**，百分比数字随帧滚动。
        if (this.multiSelect) {
          // 批量多选：左上角勾选圆点占位（爱心隐藏）
          Column() {
            if (this.isMultiSelected(meta.name)) {
              SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                .fontSize(22)
                .fontColor([this.palette().accent])
            } else {
              Column()
                .width(22)
                .height(22)
                .borderRadius(11)
                .border({ width: 2, color: this.palette().textTertiary })
            }
          }
          .position({ x: 4, y: 4 })
        } else if (!meta.builtin && meta.progressRatio > 0.001) {
          Stack({ alignContent: Alignment.Bottom }) {
            CoverProgressBar({
              target: meta.progressRatio,
              docName: meta.name,
              palette: this.palette()
            })
          }
          // Stack 子节点尺寸统一用 matchParent（百分比在内容撑开的父级里会解析错）
          .width(LayoutPolicy.matchParent)
          .height(LayoutPolicy.matchParent)
          .hitTestBehavior(HitTestMode.None)
        }

        // 「书 → 文件夹」形变层：目标封面收到 0.5 并淡出，文件夹层从 0.5 长到 1、
        // 淡入 —— 两段同一时长，看起来就是"那本书长大了变成文件夹"。
        // 尺寸规则：matchParent，不能用百分比（父级高度是内容撑开的，百分比会拉满屏）
        if (this.mergingAt === meta.name) {
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width(LayoutPolicy.matchParent)
              .height(LayoutPolicy.matchParent)
              .borderRadius({ topLeft: 5, bottomLeft: 5, topRight: 13, bottomRight: 13 })
              .backgroundColor(this.palette().quoteBg)

            Column({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.folder'))
                .fontSize(30)
                .fontColor([this.palette().accent])
              Text(L10n.t('合并为文件夹'))
                .fontSize(HwType.caption)
                .fontColor(this.palette().accent)
            }
          }
          .width(LayoutPolicy.matchParent)
          .height(LayoutPolicy.matchParent)
          .borderRadius({ topLeft: 5, bottomLeft: 5, topRight: 13, bottomRight: 13 })
          .border({ width: 2, color: this.palette().accent })
          .clip(true)
          .scale({ x: this.mergeGrow ? 1 : 0.5, y: this.mergeGrow ? 1 : 0.5 })
          .opacity(this.mergeGrow ? 1 : 0)
          .hitTestBehavior(HitTestMode.None)
        }
      }
      .width('100%')

      // 名称：用户可选择不显示（图片封面常用）——只影响封面格上的名字，
      // 文档本身的名称不变
      if (meta.hideCoverName !== true) {
        // 显示名：Front Matter 里写了 title 就用它（文件名不动）
        Text(DocStore.displayName(meta))
          .fontSize(HwType.label + 1)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.palette().textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
      }

      // 日期行：Front Matter 的 `date:` 优先（作者写死的日期比"最后修改时间"更稳定）
      Text(meta.builtin ? L10n.t('内置教程')
        : (meta.fmDate !== undefined && meta.fmDate.length > 0
          ? meta.fmDate : DocStore.formatTime(meta.mtime)))
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /** 网格项最终透明度：文件夹展开时的"退后"× 合并/吸入动画 × 一镜到底飞行。 */
  private gridItemAlpha(item: ShelfItem): number {
    const dim: number = item.kind === 'folder' && this.openFolderName === item.name
      ? 1 : this.cellOpacity();
    const flying: boolean = item.kind === 'doc' && this.docCoverName === item.name;
    return dim * this.cellAlpha(item.name, flying);
  }

  /** 封面图路径 → Image 可用源（相对 docs/ 的路径交给 DocStore 解析）。 */
  private coverImageSrc(rel: string | undefined): string {
    if (rel === undefined || rel.length === 0) {
      return '';
    }
    return DocStore.resolveImagePath(rel);
  }

  @Builder
  docCell(meta: DocMeta, inPanel: boolean) {
    // **内置教程同样可拖**（用户要求）：长按拖动 → 与另一篇合并成文件夹、或收进已有文件夹。
    // 拖拽属性挂在外层 Column 上（与文件夹格同款），不再按 builtin 分支。
    Column() {
      this.coverContent(meta, inPanel)
      // **换位就绪提示**（用户要求：悬停 1.5 秒后松手交换位置）
      if (this.swapReadyName === meta.name) {
        Text(L10n.t('松手换位'))
          .fontSize(HwType.caption - 2)
          .fontColor('#FFFFFFFF')
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .borderRadius(HwRadius.pill)
          .backgroundColor('#FF2E7D32')
          .margin({ top: 3 })
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 180, curve: Curve.FastOutSlowIn })
            .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 })))
      }
    }
    .width('100%')
    // 系统拖拽：长按起拖；释放到别的文档 / 文件夹上触发 onDrop。
    //  · 只注册 onDragStart（不加 draggable(true)）→ 长按起拖，不与点击 / 网格滚动抢手势
    //  · onDrop 与 onDragStart 同节点 → 释放一定能命中
    .onDragStart((event: DragEvent) => {
      this.draggingName = meta.name;
      this.cancelSwapHover();
      const info: DragItemInfo = { extraInfo: meta.name };
      return info;
    })
    // 拖到本格上方 → 轻微缩小，给"可以放这里"的反馈（用户要求）；
    // 悬停满 1.5 秒 → 显示「松手换位」（用户要求：拖到其他文档上方 1.5 秒自动交换）
    .onDragEnter((event: DragEvent) => {
      this.hoverDropAt = meta.name;
      this.trackSwapHover(meta.name);
    })
    .onDragLeave((event: DragEvent) => {
      if (this.hoverDropAt === meta.name) {
        this.hoverDropAt = '';
      }
      if (this.swapHoverTarget === meta.name || this.swapReadyName === meta.name) {
        this.cancelSwapHover();
      }
    })
    .onDrop((event: DragEvent) => {
      this.finishSwapOrDrop(meta.name);
    })
  }

  /** 文件夹格：迷你封面预览（或自定义封面图）+ 名称 + 数量；点开浮层，⋯ 菜单，可接收拖入。 */
  @Builder
  folderCell(folder: ShelfFolder) {
    Column({ space: 6 }) {      Stack({ alignContent: Alignment.TopEnd }) {
        Column({ space: 4 }) {
          Stack({ alignContent: Alignment.TopStart }) {
            // ① 自定义封面图：铺满整格（同样带上"书"的圆角）
            //    是否有图统一走 folderHasImage()：可选属性就地判空在 ArkTS 里不参与收窄
            if (this.folderHasImage(folder)) {
              Image(this.folderImageSrc(folder))
                // 同样用 matchParent：百分比在"被内容撑开"的 Stack 里会按可用尺寸解析
                // （合并动画的外框就是这么变成一条长竖条的）
                .width(LayoutPolicy.matchParent)
                .height(LayoutPolicy.matchParent)
                .objectFit(ImageFit.Cover)
                .draggable(false)
            } else {
              // ② 默认：**2×2 迷你封面预览**（上下两排各两本，文件夹图标的样子）。
              //    永远显示前 4 本封面（不做"+N"顶替——用户反馈第 4 本会消失），
              //    总数由封面下方的「N 篇」表达。
              //    形状与外面文档封面同款 **D 型语言**（左书脊小圆角、右大圆角），
              //    但**按迷你封面的尺寸等比缩小**（2/6）：D 型 5/13 是按大封面（约 105vp）
              //    设计的，迷你封面只有约 46vp，直接套 13 会让右圆角占掉 1/3 宽，看着不协调；
              //    间距与外框边距统一为 4（原来边距 7 / 内距 4 不一致，难看）。
              Column({ space: 4 }) {
                Row({ space: 4 }) {
                  ForEach(this.folderPreviewColors(folder).slice(0, 2), (c: string, i: number) => {
                    Column()
                      .layoutWeight(1)
                      .height('100%')
                      .borderRadius({ topLeft: 2, bottomLeft: 2, topRight: 6, bottomRight: 6 })
                      .linearGradient({
                        angle: 200,
                        colors: [[c, 0.0], [c, 1.0]]
                      })
                  }, (c: string, i: number) => folder.name + 'a' + i + c)
                }
                .width('100%')
                .layoutWeight(1)

                Row({ space: 4 }) {
                  ForEach(this.folderPreviewColors(folder).slice(2, 4), (c: string, i: number) => {
                    Column()
                      .layoutWeight(1)
                      .height('100%')
                      .borderRadius({ topLeft: 2, bottomLeft: 2, topRight: 6, bottomRight: 6 })
                      .linearGradient({
                        angle: 200,
                        colors: [[c, 0.0], [c, 1.0]]
                      })
                  }, (c: string, i: number) => folder.name + 'b' + i + c)
                }
                .width('100%')
                .layoutWeight(1)
              }
              .width('100%')
              .height('100%')
            }
            // （原先左上角那颗文件夹小图标按用户要求已删除）
          }
          .width('100%')
          .aspectRatio(0.72)
          .padding(this.folderHasImage(folder) ? 0 : 4)
          .borderRadius({ topLeft: 5, bottomLeft: 5, topRight: 13, bottomRight: 13 })
          // 文件夹颜色：自定义色优先。**用不透明色**（之前带 15% 透明 → 看着像"变透明了"）
          .backgroundColor(this.folderColorOf(folder).length > 0
            ? this.folderColorOf(folder) : this.palette().quoteBg)
          .clip(true)
          .onClick((event: ClickEvent) => {
            this.openFolderPanel(folder.name);
          })
        }
        .width('100%')

        Column() {
          ImmersiveIconButton({
            // 26 → 30（用户反馈"右上角按钮看上去太小"，14vp 图标也确实偏小）
            buttonSize: 30,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              this.openCellMenu('folder', folder.name, false);
            }
          }) {
            Image($r('app.media.more_dots'))
              // 14 → 18（用户反馈图标太小）
              .width(18)
              .height(18)
              .fillColor(this.palette().textSecondary)
          }
        }
        .margin({ top: 4, right: 4 })
      }
      .width('100%')

      if (folder.hideCoverName !== true) {
        Text(folder.name)
          .fontSize(HwType.label + 1)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.palette().textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
      }

      // 篇数按**当前可见**成员算（隐藏的内置、已删的文档都不算）
      Text(this.folderDocs(folder.name).length + ' 篇')
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    // 拖拽与释放都挂在**整格同一个节点**上，与文档格（docCell）完全同款：
    //  · 只注册 onDragStart（不加 draggable(true)）→ 长按起拖，
    //    不会和点击、网格滚动抢手势（draggable(true) 是普通移动就起拖，
    //    加上去反而拖不动，这是之前换位失效的真因）
    //  · onDrop 与 onDragStart 同节点 → 释放一定能命中
    .onDragStart((event: DragEvent) => {
      this.draggingName = 'folder:' + folder.name;
      const info: DragItemInfo = { extraInfo: 'folder:' + folder.name };
      return info;
    })
    // 拖到本格上方 → 轻微缩小反馈
    .onDragEnter((event: DragEvent) => {
      this.hoverDropAt = folder.name;
    })
    .onDragLeave((event: DragEvent) => {
      if (this.hoverDropAt === folder.name) {
        this.hoverDropAt = '';
      }
    })
    // 落到本格 = 把拖来的文件夹换到此刻的位置（拖动换位）
    .onDrop((event: DragEvent) => {
      this.handleDropOnFolder(folder.name);
    })
    // **正在展开的那个文件夹**挂 id：展开前用它实测此刻的窗口位置，
    // 滚动目标按「文件夹落在屏幕上部、面板在它下方」来算（见 scrollPanelTopIntoPlace）。
    // ⚠️ id 必须挂在**卡片本体这层 Column** 上，不能挂 GridItem ——
    // GridItem 是布局容器，getRectangleById 在它上面实测常常拿不到矩形（本工程踩过）。
    .id(this.openFolderName === folder.name ? 'folderCellAnchor' : 'foldercell_' + folder.name)
  }

  /** 记录文档封面的窗口矩形：一镜到底的起点/终点必须精确到这一格。 */
  private rememberDocRect(name: string, area: Area): void {
    const w: Length = area.width;
    const h: Length = area.height;
    if (typeof w !== 'number' || typeof h !== 'number' || w <= 0 || h <= 0) {
      return;
    }
    const gp: Position = area.globalPosition;
    const gx: Length | undefined = gp.x;
    const gy: Length | undefined = gp.y;
    const x: number = typeof gx === 'number' ? gx : 0;
    const y: number = typeof gy === 'number' ? gy : 0;
    const rect: CoverRect = { x: x, y: y, w: w, h: h };
    this.docRects.set(name, rect);
  }

  private openFolder(): ShelfFolder | null {
    for (let k = 0; k < this.folders.length; k++) {
      if (this.folders[k].name === this.openFolderName) {
        return this.folders[k];
      }
    }
    return null;
  }

  /**
   * 展开面板的目标高度：标题 + 行数 × 单元格高。
   * 面板排在网格流里（见 folderExpandPanel），高度长多少就把下面的图标推多远。
   */
  private folderPanelTarget(): number {
    const folder: ShelfFolder | null = this.openFolder();
    if (folder === null) {
      return 220;
    }
    // 行高按**实际格宽**实算：面板内格子是完整文档卡（封面 0.72 + 名称时间），
    // 此前固定 150 的行高在宽屏上把整行截断（显示不完整，用户截图反馈）。
    const cols: number = this.panelDocCols();
    const innerW: number = this.rootWidth - HwSpace.lg * 2 - HwSpace.sm * 2;
    const cellW: number = (innerW - HwSpace.sm * (cols - 1)) / cols;
    const rowH: number = cellW / 0.72 + 60;
    const rows: number = Math.ceil(this.folderDocs(folder.name).length / cols);
    const h: number = 52 + rows * rowH + HwSpace.md;
    return Math.min(Math.max(h, 220), this.rootHeight - 160);
  }

  /**
   * 统一排序 → 网格项。文件夹与松散文档混在同一条流里（顺序取自 DocStore.shelfOrder），
   * 所以拖动文件夹到文档上、或文档到文件夹上，都能真正互换位置。
   * 只在 refresh() 里调用一次，结果存进 @State items（build 期间不写状态）。
   */
  private buildItems(ctx: common.UIAbilityContext, list: DocMeta[]): ShelfItem[] {
    const out: ShelfItem[] = [];
    // **标签筛选时平铺展示**（用户要求）：匹配文档直接排在顶层，
    // 不再按文件夹分组 —— 筛选语义是"找出所有带这个标签的文档"，
    // 藏进文件夹里反而要一个个点开找。
    if (this.tagFilter.length > 0) {
      for (let k = 0; k < list.length; k++) {
        const meta: DocMeta = list[k];
        if (this.tagMatches(meta)) {
          out.push({ kind: 'doc', name: meta.name, folder: null, meta: meta });
        }
      }
      return out;
    }
    const order: string[] = DocStore.shelfOrder(ctx);
    for (let k = 0; k < order.length; k++) {
      const entry: string = order[k];
      if (entry.startsWith(DocStore.ORDER_FOLDER)) {
        const name: string = entry.substring(DocStore.ORDER_FOLDER.length);
        const folder: ShelfFolder | null = this.folderByName(name);
        // ⚠️ **一个可见文档都没有的文件夹不显示**：只装内置文档的「澄笺」在
        // 内置被"从书架移除"后就该一起消失（用户反馈它孤零零挂在书架上）。
        // 文件夹记录本身不动 —— 恢复内置时它自然又会出现，成员也还在里面。
        // 标签筛选下：文件夹内有匹配成员才显示
        let folderVisible: boolean = folder !== null && this.folderDocs(name).length > 0;
        if (folderVisible && this.tagFilter.length > 0) {
          const members: DocMeta[] = this.folderDocs(name);
          let hit: boolean = false;
          for (let j = 0; j < members.length; j++) {
            if (this.tagMatches(members[j])) {
              hit = true;
              break;
            }
          }
          folderVisible = hit;
        }
        if (folder !== null && folderVisible) {
          out.push({ kind: 'folder', name: name, folder: folder, meta: null });
        }
      } else if (entry.startsWith(DocStore.ORDER_DOC)) {
        const name: string = entry.substring(DocStore.ORDER_DOC.length);
        let meta: DocMeta | null = null;
        for (let j = 0; j < list.length; j++) {
          if (!list[j].builtin && list[j].name === name) {
            meta = list[j];
            break;
          }
        }
        if (meta !== null && this.tagMatches(meta)) {
          out.push({ kind: 'doc', name: name, folder: null, meta: meta });
        }
      }
    }
    return out;
  }

  private folderByName(name: string): ShelfFolder | null {
    for (let k = 0; k < this.folders.length; k++) {
      if (this.folders[k].name === name) {
        return this.folders[k];
      }
    }
    return null;
  }

  /**
   * 网格项的稳定 key。
   * 内容 / 封面外观变了要重建（V1 的 ForEach 键不变时子组件 @Prop 不会重新同步），
   * 但**位置变化不能重建**——拖动换位靠 key 身份让系统做位移动画。
   */
  private itemKey(item: ShelfItem): string {
    const tag: string = this.itemCoverTag(item);
    // **主题纪元也要进 key**：深浅切换时卡片整树重建，
    // 封面渐变 / 进度徽标 / 文字颜色一次刷新到位（不用等下次 refresh）。
    if (item.kind === 'folder') {
      // 篇数用**可见成员数**：隐藏 / 恢复内置时它变化 → 文件夹格才重建刷新
      const n: number = this.folderDocs(item.name).length;
      return 'F_' + item.name + '_' + n + '_' + tag + '_t' + this.themeEpoch;
    }
    const mtime: number = item.meta !== null ? item.meta.mtime : 0;
    return 'D_' + item.name + '_' + mtime + '_' + tag + '_t' + this.themeEpoch;
  }

  /** 封面外观指纹（色 / 图 / 名称开关），参与 key。 */
  /**
   * 文档封面的外观指纹（自定义色 | 封面图 | 是否显示名）。
   * **进 ForEach key**：改封面色/图后 key 变化 → 面板内封面才会重建刷新。
   * 之前展开面板的 key 只有 name + themeEpoch，拖进文件夹后在面板里改封面色
   * key 不变 → ArkUI 复用旧组件，颜色永远不更新（用户反馈"无法应用"）。
   */
  private docCoverTag(meta: DocMeta): string {
    // 用 DocStore.coverColorOf：Front Matter 的 cover 改了也要让指纹变化 → 封面重建
    const c: string = DocStore.coverColorOf(meta);
    const rawI: string | undefined = meta.coverImage;
    const i: string = rawI === undefined ? '' : rawI;
    // ⚠️ **阅读进度必须进指纹**：格子 ForEach 的 key 不变时 ArkUI 会复用旧组件，
    // 封面底部的进度条 / 百分比永远停在旧值（用户实测"要重启应用才更新"）。
    const p: string = Math.round(meta.progressRatio * 100).toString();
    return c + '|' + i + '|' + (meta.hideCoverName === true ? '1' : '0') + '|p' + p;
  }

  private itemCoverTag(item: ShelfItem): string {
    if (item.kind === 'folder') {
      const f: ShelfFolder | null = item.folder;
      if (f === null) {
        return '';
      }
      // 可选属性先落局部常量：就地判空在 ArkTS 里不收窄（会报 possibly undefined）
      const rawC: string | undefined = f.coverColor;
      const rawI: string | undefined = f.coverImage;
      const c: string = rawC === undefined ? '' : rawC;
      const i: string = rawI === undefined ? '' : rawI;
      // **成员文档的封面指纹也要进 key**（用户反馈：改了文件夹内文件的封面，
      // 文件夹格 2×2 迷你预览不跟着变）—— 预览色取前 4 本的封面色，摘要拼进 key。
      let member: string = '';
      // 只用**可见成员**的封面指纹：隐藏的内置不该再影响文件夹格的观感
      const visible: DocMeta[] = this.folderDocs(f.name);
      for (let k: number = 0; k < visible.length && k < 4; k++) {
        const m: DocMeta = visible[k];
        // 色用 DocStore.coverColorOf（含 Front Matter 的 cover），指纹才与实拍一致
        const mc: string = DocStore.coverColorOf(m);
        const mi: string = m.coverImage !== undefined ? m.coverImage : '';
        member += mc + ',' + mi + ';';
      }
      return c + '|' + i + '|' + (f.hideCoverName === true ? '1' : '0') + '|' + member;
    }
    const m: DocMeta | null = item.meta;
    if (m === null) {
      return '';
    }
    return this.docCoverTag(m);
  }

  /** 当前展开的文件夹在统一排序（items）里的下标（-1 = 没展开）。 */
  private openFolderIndex(): number {
    for (let k = 0; k < this.items.length; k++) {
      if (this.items[k].kind === 'folder' && this.items[k].name === this.openFolderName) {
        return k;
      }
    }
    return -1;
  }

  /** 该文件夹所在列（0/1/2）。 */
  /**
   * 书架网格列数：**竖屏（含平板竖屏）与手机端一致，固定 3 列**；
   * 横屏恢复自适应（每列约 210vp，宽屏 3~6 列，用户要求「屏幕大就多显示」）。
   */
  private shelfColumns(): number {
    if (this.rootWidth <= this.rootHeight) {
      return 3;
    }
    const n: number = Math.floor(this.rootWidth / 210);
    return Math.max(3, Math.min(6, n));
  }

  private columnsTemplateStr(): string {
    const parts: string[] = [];
    for (let k = 0; k < this.shelfColumns(); k++) {
      parts.push('1fr');
    }
    return parts.join(' ');
  }

  /**
   * 展开面板内每行的文档数：**竖屏（含平板竖屏）与手机端一致，固定 3**；
   * 横屏恢复自适应（3~8 列，用户要求「屏幕大就多显示」）。
   */
  private panelDocCols(): number {
    if (this.rootWidth <= this.rootHeight) {
      return 3;
    }
    const n: number = Math.floor((this.rootWidth - HwSpace.lg * 2) / 150);
    return Math.max(3, Math.min(8, n));
  }

  private panelColumnsStr(): string {
    const parts: string[] = [];
    for (let k = 0; k < this.panelDocCols(); k++) {
      parts.push('1fr');
    }
    return parts.join(' ');
  }

  /**
   * 该文件夹在**网格里**实际所处的列（0 起）。
   *
   * ⚠️ 不能直接用 `openFolderIndex() % 列数`：那是 **items 流内**的下标，
   * 而 items 前面还排着「继续阅读横幅(1) + 新建卡(1) + looseBuiltinDocs()」这些前置项。
   * 漏掉这个偏移会算错列 → `panelAfterIndex()` 里的「本行还剩几格」也跟着错 →
   * **面板被插到下面几行之后**（用户反馈"展开在其他文件下方"）。
   *
   * 例：前置 2 项（无松散内置文档）+ 文件夹在 items 里第 0 位 → 网格绝对槽位 2 → 列 2。
   */
  private openFolderColumn(): number {
    const slot: number = this.openFolderIndex();
    if (slot < 0) {
      return 0;
    }
    const lead: number = this.gridLeadCount();
    return (lead + slot) % this.shelfColumns();
  }

  /**
   * 网格流里排在 items **之前**的项数（用于把 items 内下标换算成网格绝对槽位）。
   *
   * 真实顺序（见 build 里的 Grid）：
   *   · 继续阅读横幅 —— **通栏 GridItem（columnStart 0 ~ 列数-1），独占一整行**，
   *     所以它后面要偏移**一整行 = 列数 个槽位**，不是 1 个；
   *   · 新建卡 —— 普通 1 格；
   *   · looseBuiltinDocs() —— 逐个 1 格。
   */
  private gridLeadCount(): number {
    const cols: number = this.shelfColumns();
    // 横幅存在时才占那一行；没有横幅（resumeName 为空）时它的 GridItem 仍在流里
    // （resumeBanner() 内部 return，GridItem 壳还在），但它是通栏 → 依然占满一整行。
    return cols + 1 + this.looseBuiltinDocs().length;
  }

  /**
   * 展开面板要插在「本行最后一个格子」之后，**这样同行的邻居才留在原格**。
   * 统一排序之后只需一处判断：本行后面还有格子就插，没有就不插（返回 -1）。
   */
  private panelAfterIndex(): number {
    const i: number = this.openFolderIndex();
    if (i < 0) {
      return -1;
    }
    const after: number = i + (this.shelfColumns() - 1 - this.openFolderColumn());
    // **修复：文件夹在最后一行时面板插不进去（无法打开）**——
    // 之前 after 超出末尾就返回 -1（不挂面板），导致最后一行的文件夹点开没反应。
    // 现在收敛到网格末尾：面板跟在最后一个格子后面照常挂载。
    const last: number = this.items.length - 1;
    return Math.min(after, last);
  }

  /** 面板展开缩放的横向原点：对准该文件夹所在列的列心（顶缘小箭头已删除，仅作动画原点）。 */
  private folderPanelArrowX(): number {
    const gridW: number = this.rootWidth - HwSpace.lg * 2;
    return (this.openFolderColumn() + 0.5) * (gridW / this.shelfColumns()) - 7;
  }

  /**
   * 展开面板（iOS 6 报刊杂志式）：
   * **跨满三列**排在网格流里，高度从 0 长到目标值 —— 于是把下面的文件图标**往下推开**；
   * 它插在「文件夹行」末尾（见 folderPanelAfterIndex），所以同行邻居留在原格。
   * 原文件夹留在原地，面板从它那一列的列心向下展开；其他格子淡出 + 模糊。
   * 交互：点标题名称改名、点 chevron_up 收起、点网格空白处也收起（见 Grid.onClick）。
   */
  @Builder
  folderExpandPanel() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 面板壳换成沉浸光感卡片（ImmersiveCard = 全应用唯一的材质通路）
      ImmersiveCard({
        cardRadius: HwRadius.card,
        cardPadding: 0,
        cardMaterialShadow: false,
        palette: this.palette()
      }) {
      Column() {
        Row({ space: HwSpace.sm }) {
          SymbolGlyph($r('sys.symbol.folder'))
            .fontSize(18)
            .fontColor([this.palette().accent])
          Text(this.openFolderName)
            .fontSize(HwType.label + 2)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            // 点名称直接改名（用户要求：快速编辑文件夹名称），复用既有重命名浮层
            .onClick(() => {
              this.openRename('folder', this.openFolderName);
            })
          Text(this.folderDocs(this.openFolderName).length + ' 篇')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
          Image($r('app.media.chevron_up_circle'))
            .width(16)
            .height(16)
            .fillColor(this.palette().textSecondary)
            .onClick(() => {
              this.closeFolderPanel();
            })
        }
        .width('100%')
        .height(52)
        .padding({ left: HwSpace.md, right: HwSpace.md })
        .alignItems(VerticalAlign.Center)

        Divider().strokeWidth(1).color(this.palette().divider)

        Grid() {
          ForEach(this.folderDocs(this.openFolderName), (meta: DocMeta) => {
            GridItem() {
              this.docCell(meta, true)
            }
          }, (meta: DocMeta) => 'fp_' + meta.name + '_' + this.docCoverTag(meta) + '_t' + this.themeEpoch + '_l' + this.languageTick)
        }
        .columnsTemplate(this.panelColumnsStr())
        .columnsGap(HwSpace.sm)
        .rowsGap(HwSpace.sm)
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ left: HwSpace.sm, right: HwSpace.sm, top: HwSpace.sm })
      }
      .width('100%')
      .height(this.folderPanelOpen ? this.folderPanelTarget() : 0)
      .clip(true)
      // **从文件夹图形处延伸展开**：高度动画之外再叠一层缩放，
      // 缩放原点钉在「该文件夹所在列的列心 × 面板顶缘」——
      // 于是视觉上是从那颗文件夹图标往下长出来，收起时也是缩回那颗图标。
      .scale({
        x: 1,
        y: this.folderPanelOpen ? 1 : 0.86,
        centerX: this.folderPanelArrowX() + 7,
        centerY: 0
      })
      // 收起是与高度同时淡出的一层：面板在收起动画的第一帧就摘掉节点（见 closeFolderPanel），
      // 光靠高度收缩会「啪」一下消失；压一层透明度，摘节点时已经看不清了。
      .opacity(this.folderPanelOpen ? 1 : 0)
      .animation({ curve: FOLDER_SPRING })
      }
      // 顶缘那颗旋转 45° 的方块（菱形）指示箭头已按用户要求删除，
      // 面板顶缘直接就是卡片上沿；展开的缩放原点仍对准原文件夹所在列。
    }
    .width('100%')
    .height(this.folderPanelOpen ? this.folderPanelTarget() : 0)
    .opacity(this.folderPanelOpen ? 1 : 0)
    .animation({ curve: FOLDER_SPRING })
  }

  /** 文件夹预览里最多 4 篇文档的封面主色。 */
  private folderPreviewColors(folder: ShelfFolder): string[] {
    const out: string[] = [];
    // 预览色只取**可见成员**：隐藏的内置不参与（否则"空文件夹"还显示着它们的颜色）
    const visible: DocMeta[] = this.folderDocs(folder.name);
    for (let k: number = 0; k < visible.length && k < 4; k++) {
      const meta: DocMeta = visible[k];
      // 默认取文档名哈希色；**用户自定义色 / Front Matter 的 cover 优先**（与文档封面一致）
      const custom: string = DocStore.coverColorOf(meta);
      out.push(custom.length > 0 ? custom : coverColorsOf(meta.name, false).bottom);
    }
    while (out.length < 4) {
      out.push(this.palette().divider);
    }
    return out;
  }

  /** 沉浸光感开关（AppStorage 强制开启，见 EntryAbility） */
  @StorageProp('immersiveLightEnabled') immersiveOn: boolean = true;
  /** 书架顶部「继续阅读」卡片是否显示（外观设置里的开关，默认显示） */
  @StorageProp('shelfResumeBanner') showResumeBanner: boolean = true;
  /**
   * 「回头看看」卡片（随机一篇 / 那年今天）：**默认关闭**，
   * 开关在「写作日志」页（用户指定位置）。
   */
  // （「回头看看」卡的显隐开关已随 1.1.0 卡片搬家一并移除，卡片常驻「写作日志」页顶部）
  /**
   * 编辑页的未保存标记（Editor 通过 @StorageLink 写入）。
   * **系统返回手势的拦截判据**：dirty 时 onBackPressed 拦截并让 Editor 弹"保存 / 不保存"窗，
   * 避免侧滑误触退出丢内容（顶栏返回按钮早有此弹窗，手势此前没有）。
   */
  @StorageProp('editorDirty') editorDirty: boolean = false;
  /** 阅读页叠加层（图表 / 图片放大）是否打开：返回手势据此先关浮层而非退出页面 */
  @StorageProp('readerOverlayOpen') readerOverlayOpen: boolean = false;
  /** 沉浸光感是否真的会渲染（开关 × 材质构造成功）：新建卡外壳据此决定底色 */
  private materialOn(): boolean {
    return this.immersiveOn && getImmersiveMaterial() !== null;
  }

  /** 第一格「新建」卡（图一同款位置）——**沉浸光感**与其它封面一致 */
  @Builder
  newCell() {
    Column({ space: 6 }) {
      Column() {
        Stack({ alignContent: Alignment.Center }) {
          // ① 降级层：材质不可用时显示原底色
          Column()
            .width(LayoutPolicy.matchParent)
            .height(LayoutPolicy.matchParent)
            .borderRadius({ topLeft: 5, bottomLeft: 5, topRight: 13, bottomRight: 13 })
            .backgroundColor(this.materialOn() ? '#00000000' : this.palette().quoteBg)
            .backgroundBlurStyle(this.materialOn() ? BlurStyle.NONE : BlurStyle.Thin)
            .hitTestBehavior(HitTestMode.None)

          // ② 沉浸光感承载层（书形圆角：左 5 / 右 13）
          ImmersiveCardLayer({
            layerRadiusTL: 5,
            layerRadiusTR: 13,
            layerRadiusBL: 5,
            layerRadiusBR: 13,
            layerShadow: false
          })

          // ③ 内容
          Column({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(30)
              .fontColor([this.palette().textTertiary])
            Text(L10n.t('新建文档'))
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .aspectRatio(0.72)
        // 边框画在最外层，形状与其它封面一致
        .borderRadius({ topLeft: 5, bottomLeft: 5, topRight: 13, bottomRight: 13 })
        .border({
          width: this.dragOverNewCard ? 2 : 1.2,
          color: this.dragOverNewCard ? this.palette().accent : this.palette().divider
        })
        .clip(true)
        .onClick(() => {
          // **文件夹面板展开期间不允许新建**（用户要求）：面板盖住部分格子，
          // 此时新建会把新卡插到面板后面、状态错乱。直接忽略点击。
          if (this.openFolderName.length > 0) {
            return;
          }
          this.createDoc();
        })
      }
      .width('100%')

      Text(this.dragOverNewCard ? '释放导入 .md/.txt' : L10n.t('或长按导入'))
        .fontSize(HwType.caption)
        .fontColor(this.dragOverNewCard ? this.palette().accent : this.palette().textTertiary)
        .fontWeight(this.dragOverNewCard ? FontWeight.Medium : FontWeight.Regular)
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .gesture(
      LongPressGesture()
        .onAction(() => {
          this.importDoc();
        })
    )
    // ── 外部文件拖入（只支持 .md / .txt）──
    .onDragEnter(() => {
      this.dragOverNewCard = true;
    })
    .onDragLeave(() => {
      this.dragOverNewCard = false;
    })
    .onDrop((event?: DragEvent) => {
      this.dragOverNewCard = false;
      this.handleFileDrop(event);
    })
  }

  /**
   * 继续阅读横幅（网格首行通栏）。
   *
   * **可由外观设置里的「继续阅读卡片」开关关掉**：关掉时本 Builder 直接 return，
   * 但外层 GridItem / ListItem 的壳仍在流里（它是通栏项 → 依然占一整行槽位），
   * 所以 gridLeadCount() 的列偏移不用改；首屏留白也仍挂在那个 GridItem 上，
   * 关掉后书架顶部不会顶到悬浮胶囊底下。
   */
  @Builder
  resumeBanner() {
    // ⚠️ 外层必须有**唯一根容器**：@Builder 里平级的两个 if 会渲染成多根（白屏踩过）。
    // 两个横幅都关掉时这里是空 Column，GridItem 的壳与首屏留白照旧在流里。
    Column({ space: HwSpace.sm }) {
    if (this.resumeName.length > 0 && this.showResumeBanner) {
      ImmersiveCard({
        cardRadius: HwRadius.card,
        cardPadding: HwSpace.md,
        cardMaterialShadow: false,
        palette: this.palette(),
        cardClickable: true,
        cardOnTap: () => {
          const route: ReaderRoute = { name: this.resumeName };
          this.pushPage('pages/Reader', route);
        }
      }) {
        Row({ space: HwSpace.sm }) {
          SymbolGlyph($r('sys.symbol.book'))
            .fontSize(20)
            .fontColor([this.palette().accent])

          Column({ space: 3 }) {
            Row({ space: HwSpace.xs }) {
              Text(L10n.t('继续阅读'))
                .fontSize(HwType.caption)
                .fontColor(this.palette().accent)
              Text(L10n.t('已读 ') + Math.round(this.resumeRatio * 100) + '% · '
                + DocStore.formatTime(this.resumeLastOpen))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            Text(this.resumeName)
              .fontSize(HwType.label + 1)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.palette().textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          // 右箭头：改用圆形箭头图标（用户指定），尺寸不能太小
          Image($r('app.media.chevron_right_circle'))
            .width(20)
            .height(20)
            .fillColor(this.palette().textTertiary)
            .opacity(0.75)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    }
    .width('100%')
  }

  /**
   * 随机回顾卡。
   *
   * 两颗按钮两种口味：**随机一篇**（从书架里随便挑，排除"继续阅读"那篇）
   * 与 **那年今天**（往年同一天动过的文档）。写笔记的人最容易"只进不出"——
   * 存了几百篇却再没翻开过，这张卡就是给旧文一个再被看见的机会。
   *
   * （1.1.0 起卡片从书架页**搬到**「写作日志」页顶部——书架留给文档本身。）
   */
  @Builder
  memoryCard() {
    ImmersiveCard({
      cardRadius: HwRadius.card,
      cardPadding: HwSpace.md,
      cardMaterialShadow: false,
      palette: this.palette(),
      cardClickable: false
    }) {
      Row({ space: HwSpace.sm }) {
        SymbolGlyph($r('sys.symbol.clock'))
          .fontSize(20)
          .fontColor([this.palette().accent])

        Column({ space: 2 }) {
          Text(L10n.t('回头看看'))
            .fontSize(HwType.caption)
            .fontColor(this.palette().accent)
          // **溢出时自动滚动播放**（用户要求）：这颗卡片里图标 + 两个芯片占位，
          // 窄屏上这行提示会被挤得只剩几个字，省略号看不出内容 ——
          // 改成 MARQUEE（跑马灯），长了就自己滚一遍。
          Text(L10n.t('书架共 ') + this.docs.length + ' 篇 · 挑一篇旧文重读')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.MARQUEE })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        ImmersiveChip({
          palette: this.palette(),
          chipLabel: L10n.t('随机'),
          chipOnTap: () => {
            this.openRandomDoc();
          }
        }) {
          // 用户指定的自定义图标（单词卡套图 · 随机）
          Image($r('app.media.study_random'))
            .width(13)
            .height(13)
            .fillColor(this.palette().accent)
        }

        ImmersiveChip({
          palette: this.palette(),
          chipLabel: L10n.t('那年今天'),
          chipOnTap: () => {
            this.openOnThisDay();
          }
        }) {
          // 用户指定的自定义图标（单词卡套图 · 时光）
          Image($r('app.media.study_time'))
            .width(13)
            .height(13)
            .fillColor(this.palette().accent)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 随机打开一篇（排除"继续阅读"那篇，免得点了跟没点一样）。 */
  private openRandomDoc(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    DocStore.init(c);
    const list: DocMeta[] = DocStore.list(c);
    const picks: string[] = [];
    for (let k: number = 0; k < list.length; k++) {
      const n: string = list[k].name;
      if (n.length > 0 && n !== this.resumeName) {
        picks.push(n);
      }
    }
    if (picks.length === 0) {
      this.toast(L10n.t('书架里还没有可以重读的文档'));
      return;
    }
    const idx: number = Math.floor(Math.random() * picks.length);
    const name: string = picks[idx >= picks.length ? picks.length - 1 : idx];
    const route: ReaderRoute = { name: name };
    this.pushPage('pages/Reader', route);
  }

  // ══════════════════════ 文房（跨文档工具聚合页） ══════════════════════

  /**
   * 文房页的功能卡：标题 + 图标 + **默认展开的内容行** + 「查看详情」入口。
   * 卡片整体可点（进详情），内容行让"不看详情也知道现在什么状况"。
   */
  @Builder
  studyCard(title: string, icon: Resource, lines: string[], actionLabel: string,
    action: () => void, useMedia: boolean = false) {
    ImmersiveCard({
      cardRadius: HwRadius.card,
      cardPadding: HwSpace.lg,
      palette: this.palette(),
      cardClickable: true,
      cardOnTap: (): void => {
        action();
      }
    }) {
      Column({ space: HwSpace.sm }) {
        Row({ space: HwSpace.sm }) {
          // useMedia：自定义 SVG（media 资源）走 Image + fillColor 染色
          if (useMedia) {
            Image(icon)
              .width(20)
              .height(20)
              .fillColor(this.palette().accent)
              .draggable(false)
          } else {
            SymbolGlyph(icon)
              .fontSize(20)
              .fontColor([this.palette().accent])
          }
          Text(title)
            .fontSize(HwType.label + 3)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.palette().textPrimary)
          Blank()
          Row({ space: 4 }) {
            Text(actionLabel)
              .fontSize(HwType.caption)
              .fontColor(this.palette().accent)
            Image($r('app.media.chevron_right'))
              .width(12)
              .height(12)
              .fillColor(this.palette().accent)
              .draggable(false)
          }
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 内容行默认展示在外边（空态也给一句话，不留白板）
        ForEach(lines.length > 0 ? lines : ['暂无内容'], (line: string) => {
          Text(line)
            .fontSize(HwType.label)
            .fontColor(this.palette().textSecondary)
            .lineHeight(HwType.label * 1.7)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }, (line: string) => title + '_' + line)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /**
   * 今日笺卡：**原地下拉展示**（用户要求：不要弹窗）。
   * 收起态只露三行摘要；点卡片展开完整内容（待办 / 复习 / 修改 / 读过 / 读到一半）。
   */
  @Builder
  dailyNoteCard() {
    ImmersiveCard({
      cardRadius: HwRadius.card,
      cardPadding: HwSpace.lg,
      palette: this.palette(),
      cardClickable: true,
      cardOnTap: (): void => {
        this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
          this.studyDailyOpen = !this.studyDailyOpen;
        });
      }
    }) {
      Column({ space: HwSpace.sm }) {
        Row({ space: HwSpace.sm }) {
          SymbolGlyph($r('sys.symbol.doc_plaintext'))
            .fontSize(20)
            .fontColor([this.palette().accent])
          Text(L10n.t('今日笺'))
            .fontSize(HwType.label + 3)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.palette().textPrimary)
          Blank()
          Row({ space: 4 }) {
            Text(L10n.t('点开看今天的安排'))
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
            Image($r('app.media.chevron_right'))
              .width(12)
              .height(12)
              .fillColor(this.palette().textTertiary)
              .draggable(false)
              .rotate({ x: 0, y: 0, z: 1, angle: this.studyDailyOpen ? 90 : 0 })
              .animation({ duration: 200, curve: Curve.FastOutSlowIn })
          }
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // ⚠️ 收起态**不放详细内容**（用户要求：手动点击后才展开）——完整条目只在展开态渲染。

        // 下拉展开：完整内容（显式 TransitionEffect，展开收起都有动画）
        if (this.studyDailyOpen) {
          Column({ space: HwSpace.xs }) {
            ForEach(this.studyDailyFull, (line: string) => {
              Text(line)
                .fontSize(HwType.label)
                .fontColor(this.palette().textPrimary)
                .lineHeight(HwType.label * 1.8)
                .width('100%')
            }, (line: string) => 'df_' + line)
          }
          .width('100%')
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 240, curve: Curve.FastOutSlowIn })
            .combine(TransitionEffect.translate({ y: -8 })))
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /**
   * 全部待办卡：与今日笺同款**原地下拉**。
   * 展开区限高内滚（工程铁律：可变长内容必须限高），最多预览 50 条。
   */
  @Builder
  taskBoardCard() {
    ImmersiveCard({
      cardRadius: HwRadius.card,
      cardPadding: HwSpace.lg,
      palette: this.palette(),
      cardClickable: true,
      cardOnTap: (): void => {
        this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
          this.studyTasksOpen = !this.studyTasksOpen;
        });
      }
    }) {
      Column({ space: HwSpace.sm }) {
        Row({ space: HwSpace.sm }) {
          SymbolGlyph($r('sys.symbol.checkmark_square'))
            .fontSize(20)
            .fontColor([this.palette().accent])
          Text(L10n.t('全部待办'))
            .fontSize(HwType.label + 3)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.palette().textPrimary)
          Blank()
          Row({ space: 4 }) {
            Text(this.studyTaskCount > 0 ? this.studyTaskCount + ' 条未完成' : L10n.t('全部完成'))
              .fontSize(HwType.caption)
              .fontColor(this.studyTaskCount > 0 ? this.palette().accent : this.palette().textTertiary)
            Image($r('app.media.chevron_right'))
              .width(12)
              .height(12)
              .fillColor(this.palette().textTertiary)
              .draggable(false)
              .rotate({ x: 0, y: 0, z: 1, angle: this.studyTasksOpen ? 90 : 0 })
              .animation({ duration: 200, curve: Curve.FastOutSlowIn })
          }
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        ForEach(this.studyTasks.length > 0 ? this.studyTasks
          : ['所有文档里没有未完成的任务'], (line: string) => {
          Text(line)
            .fontSize(HwType.label)
            .fontColor(this.palette().textSecondary)
            .lineHeight(HwType.label * 1.7)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }, (line: string) => 'th_' + line)

        if (this.studyTasksOpen) {
          Scroll() {
            Column({ space: HwSpace.xs }) {
              // 待办清单：**可勾选完成**（用户要求）——勾选后**划线保留在清单里**，
              // 再点一次取消；状态直接写回原文档
              ForEach(this.studyTaskAll, (item: TaskItem) => {
                Row({ space: HwSpace.xs }) {
                  // 已完成：实心对勾框；未完成：空心框
                  if (item.done) {
                    SymbolGlyph($r('sys.symbol.checkmark_square_fill'))
                      .fontSize(16)
                      .fontColor([this.palette().accent])
                      .margin({ top: 2 })
                  } else {
                    Column()
                      .width(16)
                      .height(16)
                      .borderRadius(4)
                      .border({ width: 1.5, color: this.palette().textTertiary })
                      .margin({ top: 2 })
                  }
                  Column({ space: 1 }) {
                    Text(item.text)
                      .fontSize(HwType.label)
                      .fontColor(item.done ? this.palette().textTertiary : this.palette().textPrimary)
                      .decoration({
                        type: item.done ? TextDecorationType.LineThrough : TextDecorationType.None
                      })
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    Text(item.docName)
                      .fontSize(HwType.caption - 1)
                      .fontColor(this.palette().textTertiary)
                      .maxLines(1)
                      .width('100%')
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
                .padding({ top: HwSpace.xs, bottom: HwSpace.xs })
                .onClick(() => {
                  this.toggleStudyTask(item);
                })
              }, (item: TaskItem) => 'ta_' + item.docName + '_' + item.line + '_' + item.done)
            }
            .width('100%')
          }
          .width('100%')
          // 限高内滚：待办多时不把页面无限撑长
          .constraintSize({ maxHeight: 300 })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 240, curve: Curve.FastOutSlowIn })
            .combine(TransitionEffect.translate({ y: -8 })))
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /**
   * 勾选 / 取消文房清单里的一条待办（走 TaskBoard.toggle，直接写回原文档）。
   * 完成的条目从清单消失（collect 只收未完成），计数同步刷新。
   */
  private toggleStudyTask(item: TaskItem): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const msg: string = TaskBoard.toggle(ctx, item.docName, item.line);
    if (msg.length > 0) {
      this.toast(msg);
      return;
    }
    this.toast(item.done ? L10n.t('已取消完成') : L10n.t('已完成'));
    this.refreshStudy();
  }

  /** 打开「往年的今天」动过的文档（没有就提示）。 */
  private openOnThisDay(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    DocStore.init(c);
    const list: DocMeta[] = DocStore.list(c);
    const now: Date = new Date();
    const mm: number = now.getMonth() + 1;
    const dd: number = now.getDate();
    const year: number = now.getFullYear();
    const hits: string[] = [];
    let newest: number = 0;
    let pick: string = '';
    for (let k: number = 0; k < list.length; k++) {
      const meta: DocMeta = list[k];
      const ts: number = meta.mtime > 0 ? meta.mtime : 0;
      if (ts <= 0) {
        continue;
      }
      const d: Date = new Date(ts);
      // 必须是**往年**的同一天：今天刚改过的不算"那年今天"
      if (d.getFullYear() >= year || (d.getMonth() + 1) !== mm || d.getDate() !== dd) {
        continue;
      }
      hits.push(meta.name);
      if (ts > newest) {
        newest = ts;
        pick = meta.name;
      }
    }
    if (pick.length === 0) {
      this.toast(L10n.t('往年的今天没有留下文档'));
      return;
    }
    const route: ReaderRoute = { name: pick };
    this.pushPage('pages/Reader', route);
    this.toast('那年今天 · ' + (year - new Date(newest).getFullYear()) + ' 年前');
  }

  // ══════════════════════ 格子菜单 / 重命名 ══════════════════════

  // ── 半模态面板的官方标题栏文案（标题区由 ModalSheet 自带，内容不再自绘标题）──

  private sheetTitle(): string {
    if (this.shelfSheet === 'starred') {
      return '我的收藏';
    }
    if (this.shelfSheet === 'trail') {
      return '阅读轨迹';
    }
    if (this.shelfSheet === 'rename') {
      return this.renameKind === 'folder' ? L10n.t('重命名文件夹') : L10n.t('重命名文档');
    }
    if (this.shelfSheet === 'export') {
      return '导出与分享';
    }
    if (this.shelfSheet === 'merge') {
      return '合并导出';
    }
    return this.cellMenuFor;
  }

  private sheetSubtitle(): string {
    if (this.shelfSheet === 'starred') {
      return '共 ' + this.starredDocs.length + ' 篇 · 点一条直接阅读';
    }
    if (this.shelfSheet === 'trail') {
      return '最近打开的文档 · 点一条继续读';
    }
    if (this.shelfSheet === 'rename') {
      return this.renameKind === 'folder'
        ? L10n.t('文件夹只是归组，不影响文档本身')
        : '名称不能包含 / \\ : * ? " < > | 等字符';
    }
    if (this.shelfSheet === 'export') {
      return '「' + this.cellMenuFor + '」';
    }
    if (this.shelfSheet === 'merge') {
      return '把多篇按选定顺序拼成一篇，再导 HTML / 打印 / MD / TXT';
    }
    return '选择操作';
  }

  /**
   * 复习面板（批 3）：正面是高亮文本，点一下翻面看批注，再按三档自评推进排期。
   * ⚠️ 卡面内容用**方法返回文本**而不是在 @Builder 里写结构分支 ——
   * 工程踩过"@Builder 内跨分支返回不同结构导致空白"的坑，这里刻意规避。
   */
  @Builder
  reviewSheet() {
    Column({ space: HwSpace.md }) {
      Row() {
        Text(L10n.t('复习卡片'))
          .fontSize(HwType.label + 1)
          .fontColor(this.palette().textPrimary)
          .layoutWeight(1)
        Text((this.reviewIndex + 1) + ' / ' + this.reviewCards.length)
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 卡片主体（包一层 Column 承载 onClick —— ImmersiveCard 是尾随闭包组件，
      // 后面不能再链属性）
      Column() {
        ImmersiveCard({
          cardRadius: HwRadius.card,
          cardPadding: HwSpace.lg,
          palette: this.palette()
        }) {
          Column({ space: HwSpace.sm }) {
            Text(this.reviewFrontText())
              .fontSize(HwType.label + 2)
              .fontColor(this.palette().textPrimary)
              .lineHeight(HwType.label * 1.8)
              .width('100%')
            Text(this.reviewBackText())
              .fontSize(this.reviewFlipped ? HwType.label : HwType.caption)
              .fontColor(this.reviewFlipped ? this.palette().textSecondary
                : this.palette().textTertiary)
              .lineHeight(HwType.label * 1.7)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      .onClick(() => {
        this.reviewFlipped = !this.reviewFlipped;
      })

      Row({ space: HwSpace.sm }) {
        this.reviewButton('忘了', 0, '#FFD9534F')
        this.reviewButton('模糊', 1, '#FFE0A030')
        this.reviewButton('记得', 2, this.palette().accent)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.lg })
  }

  /** 卡面正面（高亮文本）。 */
  private reviewFrontText(): string {
    if (this.reviewIndex >= this.reviewCards.length) {
      return '';
    }
    return this.reviewCards[this.reviewIndex].front;
  }

  /** 卡面副文：未翻面给提示，翻面后给批注内容（或说明没有批注）+ 出处。 */
  private reviewBackText(): string {
    if (this.reviewIndex >= this.reviewCards.length) {
      return '';
    }
    const card: ReviewCard = this.reviewCards[this.reviewIndex];
    if (!this.reviewFlipped) {
      return '点一下卡片看批注';
    }
    const from: string = '\n\n—— 来自《' + card.docName + '》';
    if (card.back.length === 0) {
      return '（这条只有高亮，没有文字批注）' + from;
    }
    return card.back + from;
  }

  /** 三档评分按钮。 */
  @Builder
  reviewButton(label: string, grade: number, color: string) {
    Button(label)
      .fontSize(HwType.label)
      .fontColor('#FFFFFFFF')
      .backgroundColor(color)
      .layoutWeight(1)
      .height(42)
      .borderRadius(HwRadius.pill)
      .onClick(() => {
        this.gradeCurrent(grade);
      })
  }

  /**
   * 「全部待办」面板：跨文档的未完成任务清单，**可滑动查看全部**，
   * 点任意一条直接进那篇文档（用户反馈对话框只能看前几条，看不到剩下的）。
   */
  @Builder
  tasksSheet() {
    Column({ space: HwSpace.sm }) {
      Row({ space: HwSpace.xs }) {
        // **返回上一级**（用户要求）：回到封面「⋯」菜单，而不是关掉面板
        Text(L10n.t('‹ 返回'))
          .fontSize(HwType.label)
          .fontColor(this.palette().accent)
          .onClick(() => {
            this.shelfSheet = 'cellMenu';
            // 面板切换靠分支变化触发重建（工程约定）
            this.sheetEpoch = this.sheetEpoch + 1;
          })
        Text(L10n.t('全部待办'))
          .fontSize(HwType.label + 1)
          .fontColor(this.palette().textPrimary)
          .layoutWeight(1)
        Text(this.taskSummary)
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: HwSpace.xs }) {
          ForEach(this.taskItems, (it: TaskItem) => {
            Row({ space: HwSpace.sm }) {
              // 左侧勾选框：**点它只勾选、不跳转**（用户要求"支持勾选完成，
              // 同时影响到文件内的"）；点整行仍是跳进那篇文档的待办所在行。
              this.taskCheckBox(it)
              Column({ space: 2 }) {
                Text(it.text.length > 0 ? it.text : L10n.t('（空任务）'))
                  .fontSize(HwType.label)
                  // 已完成：划线 + 置灰（条目**保留在列表里**，用户要能看到勾过了什么）
                  .decoration({
                    type: it.done ? TextDecorationType.LineThrough : TextDecorationType.None,
                    color: this.palette().textTertiary
                  })
                  .fontColor(it.done ? this.palette().textTertiary : this.palette().textPrimary)
                  .width('100%')
                Text('《' + it.docName + '》第 ' + it.line + ' 行'
                  + (it.builtin ? L10n.t(' · 内置只读') : (it.readOnly ? L10n.t(' · 只读') : '')))
                  .fontSize(HwType.caption)
                  .fontColor(this.palette().textTertiary)
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding({ top: HwSpace.xs, bottom: HwSpace.xs })
            .onClick(() => {
              // 勾选框已处理过本次点击（子先父后）：复位闸门、不跳转
              if (this.taskToggleGuard) {
                this.taskToggleGuard = false;
                return;
              }
              this.shelfVisible = false;
              // focusLine：进页面就滚到这条待办所在行；fromTasks：退出后回本面板
              const route: ReaderRoute = { name: it.docName, focusLine: it.line, fromTasks: true };
              this.pushPage('pages/Reader', route);
            })
          }, (it: TaskItem, idx: number) => 'task_' + idx + '_' + it.docName + '_' + it.line
            + '_' + (it.done ? 'd' : 'o'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Auto)
      .width('100%')
      // **内容顶对齐**（Scroll 不足一屏默认居中——用户反馈"怎么把内容居中了"）
      .align(Alignment.Top)
      // 面板高度随内容（外层 bindSheet 对非收藏面板是 fitContent）；条目多时到限高内部滚
      .constraintSize({ maxHeight: 420 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.lg })
  }

  /**
   * 任务勾选框：自绘（空心方块 / 勾选填充），与正文任务列表同一套视觉与手感
   * （系统 Checkbox 在深浅主题下配色不可控，工程内一律自绘）。
   */
  @Builder
  taskCheckBox(it: TaskItem) {
    if (it.done) {
      SymbolGlyph($r('sys.symbol.checkmark_square_fill'))
        .fontSize(18)
        .fontColor([this.palette().accent])
        .margin({ top: 2 })
        .onClick(() => {
          this.toggleTaskItem(it);
        })
    } else {
      Column()
        .width(17)
        .height(17)
        .borderRadius(5)
        .border({ width: 1.5, color: this.palette().textTertiary })
        .margin({ top: 3 })
        .onClick(() => {
          this.toggleTaskItem(it);
        })
    }
  }

  /**
   * 勾选 / 取消勾选一条任务：**写回原文**（TaskBoard.toggle 只改 `[ ]`↔`[x]`），
   * 然后就地重收未完成列表 —— 勾完的那条自动消失，面板不关，可以连着勾。
   * 内置 / 只读文档由 TaskBoard 拒绝并给出可读原因，这里只负责弹提示。
   */
  private toggleTaskItem(it: TaskItem): void {
    // 置闸门：紧随其后的整行 onClick 读到就跳过跳转
    this.taskToggleGuard = true;
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    const err: string = TaskBoard.toggle(c, it.docName, it.line);
    if (err.length > 0) {
      this.toast(err);
      return;
    }
    // 就地重收**全部条目**（勾选的留下并划线，不消失）；key 含 done 状态 → 该行重建
    const r: TaskBoardResult = TaskBoard.collect(c, false);
    this.taskItems = r.items;
    this.taskSummary = TaskBoard.summary(r) + ' · ' + r.docs + ' 篇'
      + (r.truncated ? L10n.t('（已达上限）') : '');
  }

  /**
   * 「新建」面板（从书架新建卡 / 底栏「新建」进入）：空白文档 + 五个内置模板。
   *
   * ⚠️ 两种写法上的规避：① 不传回调参数给 @Builder（ArkTS 上不稳），改用**下标**；
   * ② 不在 ForEach 的 itemGenerator 里调用 @Builder（工程踩过的坑），直接逐个列出。
   */
  @Builder
  newDocSheet() {
    Column({ space: HwSpace.xs }) {
      Text(L10n.t('新建文档'))
        .fontSize(HwType.label + 1)
        .fontColor(this.palette().textPrimary)
        .width('100%')
      Text(L10n.t('可以直接写空白文档，也可以从模板开始 —— 模板自带小节标题与待办项。'))
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
        .lineHeight(HwType.caption * 1.7)
        .width('100%')

      this.templateRow(0)
      this.templateRow(1)
      this.templateRow(2)
      this.templateRow(3)
      this.templateRow(4)
      this.templateRow(5)
      this.templateRow(6)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.lg })
  }

  /** 新建面板里的一行：index 0 = 空白文档，其余对应 DOC_TEMPLATES[index - 1]。 */
  @Builder
  templateRow(index: number) {
    Row({ space: HwSpace.sm }) {
      // **图标**：自绘的圆角色块 + 单字徽标（不依赖符号库、不引资源，
      // 与代码块的语言徽标同一套做法，深浅主题下都清晰）
      Text(this.templateBadge(index))
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFFFF')
        .width(26)
        .height(26)
        .textAlign(TextAlign.Center)
        .borderRadius(8)
        .backgroundColor(this.templateBadgeColor(index))

      Column({ space: 2 }) {
        Text(index === 0 ? L10n.t('空白文档') : DOC_TEMPLATES[index - 1].name)
          .fontSize(HwType.label)
          .fontColor(this.palette().textPrimary)
          .width('100%')
        Text(index === 0 ? L10n.t('从零开始写') : this.templateHint(index - 1))
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: HwSpace.sm, bottom: HwSpace.sm })
    .onClick(() => {
      this.createFromTemplate(index === 0 ? '' : DOC_TEMPLATES[index - 1].name);
    })
  }

  /** 模板徽标上的单字（0 = 空白）。 */
  private templateBadge(index: number): string {
    if (index === 0) {
      return '＋';
    }
    const n: string = DOC_TEMPLATES[index - 1].name;
    if (n === '读书笔记') {
      return '读';
    }
    if (n === '会议记录') {
      return '会';
    }
    if (n === '周报') {
      return '周';
    }
    if (n === '康奈尔笔记') {
      return '康';
    }
    if (n === '每日复盘') {
      return '复';
    }
    if (n === '复习素材') {
      return '记';
    }
    return '文';
  }

  /** 模板徽标底色（暗一档，保证白字对比度）。 */
  private templateBadgeColor(index: number): string {
    if (index === 0) {
      return '#FF6B7280';
    }
    const n: string = DOC_TEMPLATES[index - 1].name;
    if (n === '读书笔记') {
      return '#FF4E6E9F';
    }
    if (n === '会议记录') {
      return '#FF7A5EA8';
    }
    if (n === '周报') {
      return '#FF2F7D6B';
    }
    if (n === '康奈尔笔记') {
      return '#FFB06A2E';
    }
    if (n === '每日复盘') {
      return '#FF9A5B4E';
    }
    if (n === '复习素材') {
      return '#FF3F7A8C';
    }
    return '#FF6B7280';
  }

  /** 模板的一句话说明 —— 让用户选之前就知道会得到什么结构。 */
  private templateHint(i: number): string {
    if (i < 0 || i >= DOC_TEMPLATES.length) {
      return '';
    }
    const n: string = DOC_TEMPLATES[i].name;
    if (n === '读书笔记') {
      return '作者 · 核心论点 · 摘录 · 我的思考';
    }
    if (n === '会议记录') {
      return '时间 · 参会 · 议题 · 结论 · 待办';
    }
    if (n === '周报') {
      return '本周完成 · 下周计划 · 风险与需要支持';
    }
    if (n === '康奈尔笔记') {
      return '线索与问题两列表格 · 总结';
    }
    if (n === '每日复盘') {
      return '做成了什么 · 卡在哪里 · 明天第一件事';
    }
    return '';
  }

  /**
   * bindSheet 内容 = 键盘垫高层 + 面板本体。
   * BindSheet 不参与平台的键盘避让（SDK 在 setKeyboardAvoidMode 的 NOTE 里点名
   * 排除 Dialog/Popup/Menu/BindSheet/...），所以一律包 SheetKeyboardLift，
   * 键盘弹起时把内容抬到输入法上方（重命名、新建文档这些都要打字）。
   */
  @Builder
  indexSheet() {
    SheetKeyboardLift() {
      this.indexSheetBody()
    }
  }

  /** 按 shelfSheet 渲染格子菜单 / 重命名 / 导出面板。 */
  @Builder
  indexSheetBody() {
    if (this.shelfSheet === 'starred') {
      // 同上：分支切换强制重建（收藏面板的排序 chip 选中态也依赖它刷新）
      if (this.sheetEpoch % 2 === 0) {
        this.starredSheet()
      } else {
        this.starredSheet()
      }
    } else if (this.shelfSheet === 'tasks') {
      this.tasksSheet()
    } else if (this.shelfSheet === 'trail') {
      this.trailSheet()
    } else if (this.shelfSheet === 'newDoc') {
      this.newDocSheet()
    } else if (this.shelfSheet === 'review') {
      this.reviewSheet()
    } else if (this.shelfSheet === 'rename') {
      this.renameSheet()
    } else if (this.shelfSheet === 'export') {
      Column() {
        ExportOptionsPanel({
          stack: this.pathStack,
          docName: this.cellMenuFor,
          builtin: this.cellMenuBuiltin,
          palette: this.palette(),
          onClosed: () => {
            this.closeRename();
          }
        })
      }
      .width('100%')
      .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.sm })
    } else if (this.shelfSheet === 'merge') {
      // 双写分支只为强制重建（面板数据刚在 openMergeExport 里刷过）
      if (this.sheetEpoch % 2 === 0) {
        this.mergeSheet()
      } else {
        this.mergeSheet()
      }
    } else {
      // **强制重建靠分支切换**（用户实测：面板里点收藏后文案不刷新）——
      // `.id()` / `.key()` 换值都不会重建节点，只有 if 分支切换是确定的
      // "销毁旧节点 + 创建新节点"（工程里手写页"一键清空"也是这么修的）。
      // 两个分支写法完全一致，仅所处分支不同。
      if (this.sheetEpoch % 2 === 0) {
        this.cellMenuSheet()
      } else {
        this.cellMenuSheet()
      }
    }
  }

  /** 合并导出面板（选篇 / 排序 / 合并样式 + 四种输出）。 */
  @Builder
  mergeSheet() {
    Column() {
      MergeExportPanel({
        sources: this.mergeSources,
        preselect: this.mergePreselect,
        stack: this.pathStack,
        palette: this.palette(),
        onClosed: () => {
          this.closeRename();
        }
      })
    }
    .width('100%')
    .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.sm })
  }

  /** bindSheet 内容包装（格子菜单 / 重命名）。菜单内容较高，**整页可滚**（MEDIUM 定高，超出会被裁掉）。 */
  @Builder
  cellMenuSheet() {
    // **与阅读页「阅读设置」面板同构**（用户验证过那个形态是对的）：
    // Scroll 直接撑满面板高度（MEDIUM 定高），内容超出即在面板内滚动，
    // 不再额外包 Column / layoutWeight / maxHeight —— 那几层包装在
    // 平板横屏的居中面板里会算错高度（底部裁掉 / 大块空白，都踩过）。
    Scroll() {
      Column() {
        this.cellMenuPanel()
      }
      .width('100%')
      .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.sm, bottom: HwSpace.xl })
      // 深浅切换时换 key 强制重建（面板不跟随宿主状态刷新 → "切换不完全"）
      .id('cellMenu_' + this.sheetEpoch)
    }
    .scrollBar(BarState.Off)
    .width('100%')
    // **高度：内容自适应 + 明确上限**（0.65 屏高）：FIT_CONTENT 面板里
    // height('100%') 参与测量会循环、导致内容超限时 Scroll 不滚（开关被遮挡
    // 且滑不上来 —— 用户实测）。上限拉高到 0.65 屏，内容少贴合、多可滚。
    .constraintSize({ maxHeight: this.rootHeight * 0.65 })
  }

  @Builder
  renameSheet() {
    Column() {
      this.renamePanel()
    }
    .width('100%')
    .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.lg })
    .id('rename_' + this.sheetEpoch)
  }

  /**
   * 读写 / 只读切换（书架「选择操作」面板顶部）。
   * 与阅读页「更多」面板同一套语义：只读 = 锁住改写正文这条路（编辑入口 + 任务勾选），
   * 阅读 / 批注 / 封面 / 导出照常。选中态走 @State cellMenuReadOnly（打开菜单时同步、
   * 切换时立即更新），不再每次渲染去问数据层——那样按钮不会跟着重绘。
   */
  @Builder
  docModeRow() {
    Row({ space: HwSpace.xs }) {
      Text(L10n.t('读写 / 只读'))
        .fontSize(HwType.label)
        .fontColor(this.palette().textPrimary)
        .layoutWeight(1)
      ImmersiveChip({
        palette: this.palette(),
        chipLabel: L10n.t('可写'),
        chipActive: !this.cellMenuReadOnly,
        chipOnTap: () => {
          this.toggleDocReadOnly(false);
        }
      })
      ImmersiveChip({
        palette: this.palette(),
        chipLabel: L10n.t('只读'),
        chipActive: this.cellMenuReadOnly,
        chipOnTap: () => {
          this.toggleDocReadOnly(true);
        }
      })
    }
    .width('100%')
    .height(44)
    .alignItems(VerticalAlign.Center)
  }

  /** 菜单行：整行可点 + 右侧箭头（官方设置列表样式，竖排不怕截断）。 */
  @Builder
  menuRow(label: string, action: () => void) {
    Row() {
      Text(label)
        .fontSize(HwType.label + 1)
        .fontColor(this.palette().textPrimary)
        .layoutWeight(1)
      Image($r('app.media.chevron_right_circle'))
        .width(20)
        .height(20)
        .fillColor(this.palette().textTertiary)
    }
    .width('100%')
    .height(44)
    .borderRadius(HwRadius.inner)
    .onClick(() => {
      action();
    })
  }

  @Builder
  cellMenuPanel() {
    Column({ space: HwSpace.sm }) {
      // ── 文档开头的读写 / 只读开关（文件夹没有这个概念，不显示）──
      if (this.cellMenuKind === 'doc') {
        this.docModeRow()
        Divider().strokeWidth(1).color(this.palette().divider)
      }
      // 操作行：**竖排菜单行**（整行可点 + 箭头），胶囊/窄屏都不会截断
      // （标题栏由 ModalSheet 官方标题区提供，这里不再自绘标题）
      if (this.cellMenuKind === 'doc') {
        this.menuRow('阅读', () => {
          this.closeCellMenu();
          const route: ReaderRoute = { name: this.cellMenuFor };
          this.pushPage('pages/Reader', route);
        })
        // 批量管理（批 5）：进入多选模式，当前这篇默认选中
        if (!this.cellMenuBuiltin) {
          this.menuRow('批量管理', () => {
            this.openMultiSelect(this.cellMenuFor);
          })
        }
        // 收藏 / 取消收藏（书架也能收；信息卡的爱心之外多一个入口——用户反馈自带文件不好收藏）
        this.menuRow(this.cellMenuStarred ? L10n.t('取消收藏') : L10n.t('收藏'), () => {
          const c = this.ctx();
          if (c === null) {
            return;
          }
          const next: boolean = !this.cellMenuStarred;
          if (DocStore.setStarred(c, this.cellMenuFor, next)) {
            this.cellMenuStarred = next;
            this.starredDocs = DocStore.starredList(c, this.starSort);
            // **面板内容不跟随宿主状态刷新**（工程已知问题）→ 递增 sheetEpoch
            // 强制重建面板，否则「收藏 / 取消收藏」文案要点开第二次才变（用户实测）。
            this.sheetEpoch = this.sheetEpoch + 1;
            this.toast(next ? L10n.t('已收藏') : L10n.t('已取消收藏'));
          }
        })
        // （文档编码已改为卡片样式，移到面板最底部 —— 见本 builder 末尾）

        // **预置文档支持修改**（用户要求）：编辑不再限制非内置；
        // 但**只读的文档不给编辑入口**（可在本面板切成「可写」再编辑）
        if (!this.cellMenuReadOnly) {
          this.menuRow('编辑', () => {
            this.closeCellMenu();
            this.editDoc(this.cellMenuFor);
          })
        } else {
          this.menuRow('编辑 · 已锁只读', () => {
            this.toast(L10n.t('该文档是只读的，先在上面切到「可写」'));
          })
        }
        this.menuRow('重命名', () => {
          this.openRename('doc', this.cellMenuFor);
        })
        this.menuRow('导出 / 分享', () => {
          this.openCellExport();
        })
        this.menuRow(this.cellMenuBuiltin ? L10n.t('移除教程') : L10n.t('删除'), () => {
          this.askDeleteDoc(this.cellMenuFor);
        })
        if (this.cellMenuBuiltin) {
          Text(this.cellMenuReadOnly
            ? L10n.t('内置教程默认只读，可在上面切到「可写」后编辑；移除后可在「设置 → 数据管理」恢复')
            : '内置教程已解锁为可写；「重命名 / 删除」对内置文档仍然受限')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')
        } else if (this.cellMenuReadOnly) {
          Text(L10n.t('只读文档不提供编辑入口；「重命名 / 删除 / 封面 / 导出」不受影响'))
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')
        }
      } else {
        this.menuRow('打开', () => {
          this.closeCellMenu();
          // 菜单里没有点击坐标，面板会退回到屏幕中上方的默认位置
          this.openFolderPanel(this.cellMenuFor);
        })
        this.menuRow('重命名', () => {
          this.openRename('folder', this.cellMenuFor);
        })
        this.menuRow('解散', () => {
          const target: string = this.cellMenuFor;
          this.closeCellMenu();
          // 先播"吸入"动画再真正解散 + 动画刷新（之前是硬切，没有过渡）
          this.playAbsorbAnim(target, () => {
            if (DocStore.dissolveFolder(target)) {
              this.animatedRefresh();
              this.toast(L10n.t('文件夹已解散，文档回到书架'));
            }
          });
        })
      }

      // ── 封面外观：底色 / 图片 / 名称显示（**预置文档同样支持**，用户要求）──
      if (this.cellMenuKind === 'folder' || this.cellMenuKind === 'doc') {
        Divider().strokeWidth(1).color(this.palette().divider)

        Text(L10n.t('封面'))
          .fontSize(HwType.label)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.palette().textSecondary)
          .width('100%')

        // 底色：第一颗是「默认」（按名字哈希出的配色），后面是预设色。
        // **横向可滑**（用户反馈：色条滑不动、后面的颜色被遮挡）——
        // 普通 Row 会把超出色板宽度的色块裁掉；套横向 Scroll 才能滑到全部颜色。
        // Scroll 内容不足一屏默认居中，显式 Start 对齐。
        Scroll() {
          Row({ space: HwSpace.sm }) {
            this.coverColorDot('')
            ForEach(COVER_COLORS, (c: string) => {
              this.coverColorDot(c)
            }, (c: string) => 'cc_' + c)
          }
          .justifyContent(FlexAlign.Start)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .align(Alignment.Start)

        Row({ space: HwSpace.xs }) {
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: this.cellMenuHasCoverImage() ? L10n.t('换封面图') : L10n.t('导入封面图'),
            chipOnTap: () => {
              this.pickCoverImage();
            }
          })
          if (this.cellMenuHasCoverImage()) {
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: L10n.t('移除图片'),
              chipOnTap: () => {
                this.clearCoverImage();
              }
            })
          }
        }
        .width('100%')

        Row({ space: HwSpace.xs }) {
          Text(L10n.t('封面显示名称'))
            .fontSize(HwType.label)
            .fontColor(this.palette().textPrimary)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: !this.cellMenuHideName() })
            .onChange((isOn: boolean) => {
              this.toggleCoverName(isOn);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      // ── **文档编码**（用户要求：卡片样式、放在面板最底部）──
      // 用独立组件承载：它内部用 @StorageLink 订阅当前档位，切换时只写 AppStorage，
      // **不重建面板** —— 之前靠 sheetEpoch++ 刷选中态会把半模态面板的滚动位置
      // 一起重置（用户实测："一改编码面板就跳回顶部"）。
      // ── **文档体检**（批 1）：扫描结构性问题（围栏未闭合 / 图片缺失 / 锚点失效 …），
      // 结果用对话框按行号列出。只对文档开放（文件夹没有正文）。
      if (this.cellMenuKind === 'doc') {
        this.menuRow('文档体检', () => {
          this.runLint(this.cellMenuFor);
        })
        this.menuRow('批注汇总', () => {
          this.runAnnotationSummary(this.cellMenuFor);
        })
        this.menuRow('批注汇总导出为文档', () => {
          this.exportAnnotationSummary();
        })
      }

      // **全部待办**（批 2）：跨文档功能，放在这里先给个入口（后续可移到书架顶栏）
      // 模板新建已移到「新建」面板（模板属于新建流程，见 createDoc / newDocSheet）
      this.menuRow('复习卡片 · 今日到期', () => {
        // 1.1.0：改进独立复习页（选文档复习 + 遗忘曲线 + 学习记录）
        this.pushPage('pages/Review');
      })
      this.menuRow('知识图谱 · 文档引用关系', () => {
        this.runGraph();
      })
      this.menuRow('今日笺 · 今天做什么', () => {
        this.runDailyNote();
      })
      this.menuRow('全部待办 · 所有文档', () => {
        this.runTaskBoard();
      })

      if (this.cellMenuKind === 'doc') {
        EncodingChoiceCard({
          docName: this.cellMenuFor,
          palette: this.palette()
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 封面底色色块。传空串 = 「默认」，画成冷调纸白示意 + 一枚复原箭头；
   * 选中态用主题色描边，一眼能看出当前用的是哪一颗。
   */
  @Builder
  coverColorDot(color: string) {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(30)
        .height(30)
        .borderRadius(HwRadius.pill)
        .linearGradient({
          angle: 200,
          colors: color.length > 0
            ? [[coverStyleFromColor(color).top, 0.0], [coverStyleFromColor(color).bottom, 1.0]]
            : [['#FFEDEFF3', 0.0], ['#FFD7DCE4', 1.0]]
        })
        .border({
          width: this.cellMenuColor() === color ? 2 : 1,
          color: this.cellMenuColor() === color ? this.palette().accent : this.palette().divider
        })

      if (color.length === 0) {
        SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
          .fontSize(13)
          .fontColor([this.palette().textSecondary])
      }
    }
    .onClick(() => {
      this.applyCoverColor(color);
    })
  }

  @Builder
  renamePanel() {
    // **固定单行布局：取消 · 输入框 · 保存**。
    //
    // 为什么不再做"键盘弹起就把保存挪到输入框右边"的两态切换：
    // 重命名面板走的是 fitContent（面板高度贴合内容），两态的高度不同，
    // 收起键盘那一刻布局从"两行"变回"一行"，**面板高度突变 = 看得见的跳一下**。
    // 现在一行排开、任何状态都不变：高度恒定 → 没有跳动；
    // 而键盘弹起时两个按钮本来就在输入框左右两侧，天然不会被键盘挡住。
    Row({ space: HwSpace.sm }) {
      this.renameCancelChip()

      TextInput({ text: this.renameText, placeholder: L10n.t('名称') })
        .layoutWeight(1)
        .height(44)
        .fontSize(HwType.label + 1)
        .fontColor(this.palette().textPrimary)
        .backgroundColor(this.palette().quoteBg)
        .borderRadius(HwRadius.inner)
        .onChange((value: string) => {
          this.renameText = value;
        })
        // 键盘上按回车 = 保存
        .onSubmit(() => {
          this.doRename();
        })

      this.renameSaveChip()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 重命名面板：取消（蓝，用户指定配色）。 */
  @Builder
  renameCancelChip() {
    ImmersiveChip({
      palette: this.palette(),
      chipPaddingH: HwSpace.md,
      chipPaddingV: 7,
      chipTint: RENAME_CANCEL_COLOR,
      chipActive: true,
      chipLabel: L10n.t('取消'),
      chipOnTap: () => {
        this.closeRename();
      }
    })
  }

  /** 重命名面板：保存（绿，用户指定配色）。 */
  @Builder
  renameSaveChip() {
    ImmersiveChip({
      palette: this.palette(),
      chipPaddingH: HwSpace.md,
      chipPaddingV: 7,
      chipTint: RENAME_SAVE_COLOR,
      chipActive: true,
      chipLabel: L10n.t('保存'),
      chipOnTap: () => {
        this.doRename();
      }
    })
  }

  // ══════════════════════ 树形视图（文件树形态） ══════════════════════

  /**
   * 列表行小书图标的配色：**自定义封面色优先**（与网格封面观感一致），
   * 没自定义才用文档名哈希色。之前直接用哈希色，改过封面色的文档在列表里
   * 图标颜色对不上（用户反馈"颜色没有跟随封面颜色"）。
   */
  private treeDocColors(meta: DocMeta): CoverStyle {
    const custom: string = DocStore.coverColorOf(meta);
    if (custom.length > 0) {
      return coverStyleFromColor(custom);
    }
    return coverColorsOf(meta.name, meta.builtin);
  }

  @Builder
  treeDocRow(meta: DocMeta, indent: number) {
    Row({ space: HwSpace.sm }) {
      Column()
        .width(indent)
      Column()
        .width(12)
        .height(16)
        // D 型圆角按 12×16 的尺寸等比缩（1/3），与全书封形状语言一致
        .borderRadius({ topLeft: 1, bottomLeft: 1, topRight: 3, bottomRight: 3 })
        .linearGradient({
          angle: 200,
          colors: [[this.treeDocColors(meta).top, 0.0],
            [this.treeDocColors(meta).bottom, 1.0]]
        })
      Text(meta.name)
        .fontSize(HwType.label + 1)
        .fontColor(this.palette().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (meta.progressRatio > 0.001) {
        Text(L10n.t('已读 ') + Math.round(meta.progressRatio * 100) + '%')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
      } else if (!meta.builtin) {
        Text(DocStore.formatTime(meta.mtime))
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
      } else {
        Text(L10n.t('内置'))
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
      }
      if (this.multiSelect) {
        // 批量多选：行首勾选圆点
        if (this.isMultiSelected(meta.name)) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
            .fontSize(20)
            .fontColor([this.palette().accent])
        } else {
          Column()
            .width(20)
            .height(20)
            .borderRadius(10)
            .border({ width: 2, color: this.palette().textTertiary })
        }
      }
      Column() {
        if (!this.multiSelect) {
          ImmersiveIconButton({
            // 26 → 30（同上：右上角按钮整体放大）
            buttonSize: 30,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              this.openCellMenu('doc', meta.name, meta.builtin);
            }
          }) {
            Image($r('app.media.more_dots'))
              // 14 → 18（同上：右上角图标整体放大）
              .width(18)
              .height(18)
              .fillColor(this.palette().textSecondary)
          }
        }
      }
    }
    .width('100%')
    .padding({ left: HwSpace.sm, right: HwSpace.xs, top: 8, bottom: 8 })
    .borderRadius(HwRadius.inner)
    // 行内展开/收起时，插入与移除的行淡入淡出（key 稳定 + animateTo，三者缺一不可）
    .transition({ opacity: 0 })
    .onClick(() => {
      this.openDoc(meta);
    })
    // **树形视图同样支持拖拽**（用户要求）：长按起拖 → 悬停另一文档 1.5 秒换位 /
    // 快速放下合并文件夹 / 拖到文件夹行收进文件夹 —— 与网格 docCell 同一套
    .onDragStart((event: DragEvent) => {
      this.draggingName = meta.name;
      this.cancelSwapHover();
      const info: DragItemInfo = { extraInfo: meta.name };
      return info;
    })
    .onDragEnter((event: DragEvent) => {
      this.hoverDropAt = meta.name;
      this.trackSwapHover(meta.name);
    })
    .onDragLeave((event: DragEvent) => {
      if (this.hoverDropAt === meta.name) {
        this.hoverDropAt = '';
      }
      if (this.swapHoverTarget === meta.name || this.swapReadyName === meta.name) {
        this.cancelSwapHover();
      }
    })
    .onDrop((event: DragEvent) => {
      this.finishSwapOrDrop(meta.name);
    })
    // 悬停换位目标行：accent 描边提示（松手即交换）
    .border({
      width: this.swapReadyName === meta.name ? 1.5 : 0,
      color: this.palette().accent
    })
  }

  @Builder
  treeFolderRow(folder: ShelfFolder) {
    Row({ space: HwSpace.sm }) {
      // 展开箭头：同一个圆形箭头图标，**展开时顺时针旋转 90°**（用户要求）
      Image($r('app.media.chevron_right_circle'))
        .width(20)
        .height(20)
        .fillColor(this.palette().textTertiary)
        .rotate({
          z: 1,
          angle: this.expandedFolders.indexOf(folder.name) >= 0 ? 90 : 0
        })
        .animation({ duration: 200, curve: Curve.FastOutSlowIn })
      SymbolGlyph($r('sys.symbol.folder'))
        .fontSize(16)
        // 文件夹图标颜色**跟随文件夹封面色**（用户要求；自定义色优先，
        // 没设置过才用主题强调色）——之前固定用 accent，改过文件夹颜色的对不上
        .fontColor([this.folderColorOf(folder).length > 0
          ? this.folderColorOf(folder) : this.palette().accent])
      Text(folder.name)
        .fontSize(HwType.label + 1)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.palette().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(this.folderDocs(folder.name).length + ' 篇')
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
      Column() {
        ImmersiveIconButton({
          // 26 → 30（同上：右上角按钮整体放大）
          buttonSize: 30,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            this.openCellMenu('folder', folder.name, false);
          }
        }) {
          Image($r('app.media.more_dots'))
            // 14 → 18（同上：右上角图标整体放大）
            .width(18)
            .height(18)
            .fillColor(this.palette().textSecondary)
        }
      }
    }
    .width('100%')
    .padding({ left: HwSpace.sm, right: HwSpace.xs, top: 8, bottom: 8 })
    .borderRadius(HwRadius.inner)
    .backgroundColor(this.expandedFolders.indexOf(folder.name) >= 0 ? this.palette().quoteBg : '#00000000')
    .onClick(() => {
      // 行内展开也要有动画：状态变更包在弹簧 animateTo 里
      this.toggleFolderExpandAnimated(folder.name);
    })
    // **树形文件夹行也接收拖拽**（用户要求：拖文档到文件夹行 = 收进文件夹）
    .onDragStart((event: DragEvent) => {
      this.draggingName = 'folder:' + folder.name;
      this.cancelSwapHover();
      const info: DragItemInfo = { extraInfo: 'folder:' + folder.name };
      return info;
    })
    .onDragEnter((event: DragEvent) => {
      this.hoverDropAt = folder.name;
    })
    .onDragLeave((event: DragEvent) => {
      if (this.hoverDropAt === folder.name) {
        this.hoverDropAt = '';
      }
    })
    .onDrop((event: DragEvent) => {
      this.handleDropOnFolder(folder.name);
    })
  }

  @Builder
  treeList() {
    List({ space: 0 }) {
      // 首屏留白放在**第一个内容项**上：静止时内容在悬浮胶囊下方，
      // 滚动时能穿到胶囊下面（滚动容器的 padding 是裁剪边界，放那儿就穿不过去）。
      ListItem() {
        Column() {
          this.resumeBanner()
        }
      }
      // bottom 保底间距：与下方文件夹行永远不贴住（网格模式横幅同款保底）
      // ⚠️ 书架页多了标签筛选条时（用户要求），首块内容整体再下移一条，
      // 否则"继续阅读"卡与文档封面会被标签栏压住（实测）。
      .margin({
        top: this.padTop() + HwBar.pill + HwSpace.md
          + (this.shelfPage === 1 && this.allTags().length > 0 ? 34 : 0),
        bottom: HwSpace.md
      })

      // ⚠️ 用 **looseBuiltinDocs()**（已过滤"已收入文件夹"的预置文档）而不是 builtinDocs()：
      // 网格样式同样只列松散预置 —— 之前列表用全量，预置文档已拖进文件夹后
      // 列表顶层还重复显示一份（用户反馈）。与网格口径一致。
      ForEach(this.shelfOrderedLoose(true), (meta: DocMeta, idx: number) => {
        ListItem() {
          this.treeDocRow(meta, 0)
        }
      // ⚠️ 键必须带 themeEpoch：文件夹内的行（'fd'…）一直带着，这两处漏了 →
      // 切深色时这两批行不重建、颜色停在浅色（深底黑字看不清，用户实测）。
      }, (meta: DocMeta, idx: number) => 'tb' + idx + '_' + meta.name
        + '_t' + this.themeEpoch + '_l' + this.languageTick)

      ForEach(this.shelfOrderedFolders(), (folder: ShelfFolder) => {
        ListItem() {
          this.treeFolderRow(folder)
        }
        if (this.expandedFolders.indexOf(folder.name) >= 0) {
          ForEach(this.folderDocs(folder.name), (meta: DocMeta, idx: number) => {
            ListItem() {
              this.treeDocRow(meta, 26)
            }
          }, (meta: DocMeta, idx: number) => 'fd' + idx + '_' + folder.name + '_' + meta.name + '_t' + this.themeEpoch + '_l' + this.languageTick)
        }
      }, (folder: ShelfFolder) => 'f_' + folder.name + '_' + this.folderDocs(folder.name).length)

      ForEach(this.shelfOrderedLoose(false), (meta: DocMeta, idx: number) => {
        ListItem() {
          this.treeDocRow(meta, 0)
        }
      }, (meta: DocMeta, idx: number) => 't' + idx + '_' + meta.name + '_' + meta.mtime
        + '_t' + this.themeEpoch + '_l' + this.languageTick)

      ListItem() {
        Text(L10n.t('树形视图 · 文件夹来自书架拖拽归组'))
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: HwSpace.lg, bottom: HwSpace.xxl })
      }
    }
    .width('100%')
    .layoutWeight(1)
    // 右侧滚动条不显示（用户要求）
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .padding({ left: HwSpace.lg, right: HwSpace.lg })
    .onScrollIndex((first: number, last: number) => {
      this.shelfAtTop = first <= 0;
      if (first <= 0) {
        this.scrollAccum = 0;
        this.toggleBars(true);
      }
    })
    .onDidScroll((offset: number, state: ScrollState) => {
      this.onScrollFrame(offset);
    })
  }

  // ══════════════════════ 底部统计栏（含快捷新建 / 导入按钮） ══════════════════════

  /**
   * 批量操作条（multiSelect 时替换底栏）：已选数 + 全选 + 移入文件夹 + 删除 + 完成。
   * 移入文件夹用 Select 下拉选目标；删除走确认弹窗（内置文档自动跳过）。
   */
  @Builder
  multiBar() {
    ImmersiveBar({ palette: this.palette(), barPaddingH: HwSpace.sm, barPaddingV: HwSpace.xs }) {
      // 统一包一行（带间距）：此前元素直接铺在胶囊里全贴在一起（用户反馈）
      Row({ space: 6 }) {
        Text(L10n.t('已选 ') + this.multiNames.length)
          .fontSize(HwType.caption)
          .fontColor(this.palette().textPrimary)
          .constraintSize({ maxWidth: 64 })
          .maxLines(1)
        ImmersiveChip({
          palette: this.palette(),
          chipLabel: this.multiNames.length >= this.docs.length ? L10n.t('全不选') : L10n.t('全选'),
          chipOnTap: () => {
            this.toggleMultiAll();
          }
        })
        // 移入文件夹：**收窄的下拉**（此前按 value 撑宽显得过大，用户反馈）
        Select(this.folderSelectOptions())
          .selected(-1)
          .value('移入')
          .font({ size: HwType.caption })
          .fontColor(this.palette().textSecondary)
          .backgroundColor('#00000000')
          .height(30)
          .constraintSize({ minWidth: 62, maxWidth: 96 })
          .onSelect((index: number) => {
            if (index >= 0 && index < this.folders.length) {
              this.multiToFolder(this.folders[index].name);
              this.exitMultiSelect();
            }
          })
        Blank()
        // 合并导出：把勾选的这批拼成一篇再导出（面板里还能调顺序）
        ImmersiveChip({
          palette: this.palette(),
          chipActive: true,
          chipLabel: L10n.t('合并导出'),
          chipOnTap: () => {
            if (this.multiNames.length < 2) {
              this.getUIContext().getPromptAction().showToast({
                message: L10n.t('至少选两篇才能合并'), duration: 1600
              });
              return;
            }
            this.openMergeExport();
          }
        })
        ImmersiveChip({
          palette: this.palette(),
          chipTint: '#FFD32F2F',
          chipActive: true,
          chipLabel: L10n.t('删除'),
          chipOnTap: () => {
            this.multiRemove();
          }
        })
        ImmersiveChip({
          palette: this.palette(),
          chipActive: true,
          chipLabel: L10n.t('完成'),
          chipOnTap: () => {
            this.exitMultiSelect();
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  bottomBar() {
    ImmersiveBar({
      palette: this.palette(), barPaddingH: HwSpace.sm, barPaddingV: HwSpace.xs,
      barHeight: HwBar.pill,
      // **平板放屏幕右下角**：宽屏收窄靠右，手机仍整行
      // 宽屏时留出按钮位置（原 340 → 400），否则「篇数 + 字数 + 按钮」会挤在一起
      barWidth: this.isWideShelf() ? 400 : '100%'
    }) {
      // 智感握姿：左手时新建按钮靠左（"几篇"文本左边），右手/默认靠右（"字数"文本右边）
      if (this.gripSide === -1) {
        this.newDocButton()
        this.trailButton()
        // 爱心：收藏快速查看（与新建按钮同侧，一起跟随握姿适配）
        this.starButton()
        // AI 助手入口（1.2.0）：同样跟随握姿换边
        this.aiButton()
      }
      Text(this.docs.length + ' 篇 · ' + this.folders.length + ' 个文件夹')
        .fontSize(HwType.caption)
        .fontColor(this.palette().textSecondary)
        // **弹性中段 + 跑马灯**（用户要求）：空间不够时**文本自身收窄**并滚动，
        // 绝不把两侧按钮顶出去。此前 constraintSize(200) 只是"上限"不是"收缩承诺"——
        // 行内总宽超了照样把按钮推到胶囊外（用户实测）；改 layoutWeight 后文本
        // 优先让位，超长部分交给跑马灯滚动。
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.MARQUEE })
        // step 是"每帧移动的 px"：22 ≈ 每秒千像素级（用户："滚动速度那么快，搞笑吗？"）
        // → 3 ≈ 每秒百像素上下的阅读节奏
        .marqueeOptions({ start: true, step: 3, fromStart: true })
      Text(this.totalWords + ' 字')
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
        .constraintSize({ maxWidth: 100 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.MARQUEE })
        .marqueeOptions({ start: true, step: 3, fromStart: true })
      if (this.gripSide !== -1) {
        this.newDocButton()
        this.trailButton()
        this.starButton()
        this.aiButton()
      }
    }
  }

  /**
   * 胶囊内的「阅读轨迹」按钮：最近打开的文档列表（批 5 之阅读轨迹）。
   * 与新建 / 收藏同一套：圆形小钮 + 时钟图标，跟随智感握姿换边。
   */
  @Builder
  trailButton() {
    Stack() {
      ImmersiveIconButton({
        buttonSize: NEW_BTN_SIZE,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
            this.openTrail();
          });
        }
      }) {
        SymbolGlyph($r('sys.symbol.clock'))
          .fontSize(17)
          .fontColor([this.palette().accent])
      }
    }
    .width(NEW_BTN_SIZE)
    .height(NEW_BTN_SIZE)
    .margin(this.gripSide === -1 ? { right: HwSpace.xs } : { left: HwSpace.xs })
  }

  /**
   * 胶囊内的「收藏」按钮（用户要求：创建按钮旁，点击快速查看收藏的文件）。
   * 与新建按钮同一套：圆形小钮 + 主题色薄底 + 爱心；同样跟随智感握姿换边。
   */
  @Builder
  starButton() {
    Stack() {
      ImmersiveIconButton({
        buttonSize: NEW_BTN_SIZE,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          const c = this.ctx();
          if (c === null) {
            return;
          }
          this.starredDocs = DocStore.starredList(c, this.starSort);
          this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
            this.shelfSheet = 'starred';
            this.shelfVisible = true;
          });
        }
      }) {
        SymbolGlyph(this.starredDocs.length > 0 ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
          .fontSize(17)
          .fontColor([this.starredDocs.length > 0 ? '#FFE5484D' : this.palette().accent])
      }
    }
    .width(NEW_BTN_SIZE)
    .height(NEW_BTN_SIZE)
    .margin(this.gripSide === -1 ? { right: HwSpace.xs } : { left: HwSpace.xs })
  }

  /** 收藏面板：排序 chips + 列表（去掉 ♥ 前缀、加收藏日期——用户要求）。 */
  @Builder
  starredSheet() {
    Column({ space: HwSpace.xs }) {
      // 排序调整（用户要求）
      Row({ space: HwSpace.xs }) {
        ImmersiveChip({
          palette: this.palette(),
          chipLabel: L10n.t('最近收藏'),
          chipActive: this.starSort === 'starred',
          chipOnTap: () => {
            this.applyStarSort('starred');
          }
        })
        ImmersiveChip({
          palette: this.palette(),
          chipLabel: L10n.t('最近打开'),
          chipActive: this.starSort === 'recent',
          chipOnTap: () => {
            this.applyStarSort('recent');
          }
        })
        ImmersiveChip({
          palette: this.palette(),
          chipLabel: L10n.t('按名称'),
          chipActive: this.starSort === 'name',
          chipOnTap: () => {
            this.applyStarSort('name');
          }
        })
      }
      .width('100%')

      if (this.starredDocs.length === 0) {
        Text(L10n.t('还没有收藏的文档：在阅读页信息卡右上角点爱心即可收藏。'))
          .fontSize(HwType.label)
          .fontColor(this.palette().textTertiary)
          .lineHeight(HwType.label * 1.6)
          .width('100%')
      } else {
        ForEach(this.starredDocs, (doc: DocMeta) => {
          // **每条一个独立小卡片**（用户要求：条目多了平铺太乱）；
          // 底色用主题色薄染 + 描边（默认材质底太淡，用户反馈看不清）。
          // 外面的 Column 只用来挂描边/圆角——自定义组件 + 尾随闭包之后
          // **不能再链属性**（直接链 .border 会编译报错）。
          Column() {
          ImmersiveCard({
            cardRadius: HwRadius.card,
            cardPadding: HwSpace.sm,
            cardMaterialShadow: false,
            cardBackground: this.palette().accentSoft,
            palette: this.palette()
          }) {
            Column({ space: 2 }) {
              Text(doc.name)
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(L10n.t('收藏于 ') + Index.starDateLabel(doc.starredAt))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textSecondary)
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .onClick(() => {
              this.closeCellMenu();
              const route: ReaderRoute = { name: doc.name };
              this.pushPage('pages/Reader', route);
            })
          }
          }
          .width('100%')
          .borderRadius(HwRadius.card)
          .border({ width: 1, color: this.palette().divider })
          .margin({ bottom: HwSpace.xs })
        }, (doc: DocMeta) => 'star_' + doc.name)
      }
    }
    .width('100%')
    .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.sm })
    .alignItems(HorizontalAlign.Start)
    // 深浅切换时整棵子树重建（面板不跟随宿主状态刷新 → "切换不完全"）
    .id('starred_' + this.sheetEpoch)
  }

  /** 文档编码在 AppStorage 里的键（按文档名存，与阅读页共用同一份）。 */
  private encodingKeyOf(docName: string): string {
    return 'docEncoding_' + docName;
  }

  /**
   * **批注汇总导出为文档**：把全部文档的标注整理成一篇《批注汇总》——
   * 按文档分组、每组标题用 `[[文档名]]`（点一下就能跳到那篇），
   * 于是它既是一份复习清单，也被「知识图谱」连进了文档网络。
   */
  private exportAnnotationSummary(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    const list: DocMeta[] = DocStore.list(c);
    const lines: string[] = [];
    lines.push('# 批注汇总');
    lines.push('');
    lines.push('> 由「书架封面 ⋯ → 批注汇总导出」自动生成；再导出会新建一篇'
      + '（同名自动加序号），旧的可以自行删除。');
    lines.push('');
    let total: number = 0;
    let docs: number = 0;
    for (let k = 0; k < list.length; k++) {
      const meta: DocMeta = list[k];
      let arr: MdAnnotation[] = [];
      try {
        arr = AnnotationStore.load(c, meta.name);
      } catch (err) {
        arr = [];
      }
      if (arr.length === 0) {
        continue;
      }
      docs++;
      lines.push('## [[' + meta.name + ']]');
      lines.push('');
      for (let j = 0; j < arr.length; j++) {
        const a: MdAnnotation = arr[j];
        const isHand: boolean = a.note.startsWith('hw:');
        const excerpt: string = a.text.trim().replace(/\s+/g, ' ');
        total++;
        lines.push('- ' + (excerpt.length > 60 ? excerpt.substring(0, 60) + '…' : excerpt));
        if (isHand) {
          lines.push('  - ✍️ 手写批注');
        } else if (a.note.length > 0) {
          lines.push('  - 💬 ' + a.note.replace(/\n/g, ' '));
        }
      }
      lines.push('');
    }
    if (total === 0) {
      this.toast(L10n.t('还没有任何批注'));
      return;
    }
    // 在开头说明之后插入一行统计
    lines.splice(3, 0, '**共 ' + total + ' 处标注 · 涉及 ' + docs + ' 篇文档**', '');
    const out: DocMeta | null = DocStore.create(c, '批注汇总', lines.join('\n'));
    this.refresh();
    if (out === null) {
      this.toast(L10n.t('导出失败：无法写入文档'));
      return;
    }
    this.toast('已导出《' + out.name + '》（' + total + ' 处标注）');
  }

  /**
   * 按内置模板新建并**直接打开**（由「新建」面板调用）。
   * 传空模板名 = 打开空白编辑器。
   */
  private createFromTemplate(templateName: string): void {
    if (templateName.length === 0) {
      this.openEditorNew();
      return;
    }
    let body: string = '';
    for (let k = 0; k < DOC_TEMPLATES.length; k++) {
      if (DOC_TEMPLATES[k].name === templateName) {
        body = DOC_TEMPLATES[k].body;
        break;
      }
    }
    if (body.length === 0) {
      this.toast(L10n.t('模板不存在'));
      return;
    }
    this.shelfVisible = false;
    this.animateNextRefresh = true;
    // **不再提前落盘**（用户反馈：选「直接离开 / 不保存」却多出一篇文档）：
    // 模板正文经路由传给编辑器，保存时才真正创建 —— 不保存 = 什么都不留。
    const route: ReaderRoute = { seed: body };
    this.pushPage('pages/Editor', route);
  }

  /**
   * 复习卡片墙（批 3）：把批注派生成卡片，按间隔重复复习。
   * 打开时先 sync（把批注新增/删除同步进卡片，保留已有进度），再取今日到期的。
   */
  private openReview(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    let due: ReviewCard[] = [];
    try {
      const seeds: ReviewSeed[] = this.buildReviewSeeds(c);
      ReviewCardStore.sync(c, seeds);
      due = ReviewCardStore.dueToday(ReviewCardStore.load(c));
    } catch (err) {
      this.toast(L10n.t('读取复习卡片失败'));
      return;
    }
    if (due.length === 0) {
      const s: ReviewStats = ReviewCardStore.stats(ReviewCardStore.load(c));
      this.toast(s.total === 0
        ? L10n.t('还没有卡片：先在文档里划几处荧光笔或写批注')
        : L10n.t('今天没有到期卡片（共 ') + s.total + ' 张，已掌握 ' + s.learned + ' 张）');
      return;
    }
    this.reviewCards = due;
    this.reviewIndex = 0;
    this.reviewFlipped = false;
    this.shelfSheet = 'review';
    this.shelfVisible = true;
  }

  /** 从全部文档的批注里收集卡片素材（手写批注跳过：正反面都是图，复习价值低）。 */
  private buildReviewSeeds(c: common.UIAbilityContext): ReviewSeed[] {
    const out: ReviewSeed[] = [];
    const list: DocMeta[] = DocStore.list(c);
    for (let k = 0; k < list.length; k++) {
      const arr: MdAnnotation[] = AnnotationStore.load(c, list[k].name);
      for (let j = 0; j < arr.length; j++) {
        const a: MdAnnotation = arr[j];
        // **只认「学习卡」**（1.1.0）：批注 / 荧光笔 / 波浪线 / 手写是独立标识，
        // 不混入复习数据（用户明确要求）；手写（hw:）本来也不是学习卡
        if (a.style !== 'card') {
          continue;
        }
        const front: string = a.text.trim();
        if (front.length === 0) {
          continue;
        }
        // ⚠️ **docName 必须用 meta.name**（跨文档服务铁律）：
        // 之前用 fileName 生成 id，与 ReviewPage 的 name 版 id 不同 ——
        // 文房页每次刷新都会把全部卡"重新同步成到期"，掌握记录直接作废（真机实锤）。
        out.push({
          docName: list[k].name, annId: a.id, front: front, back: a.note
        } as ReviewSeed);
      }
    }
    return out;
  }

  /** 给当前卡片评分并推进到下一张。 */
  private gradeCurrent(grade: number): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null || this.reviewIndex >= this.reviewCards.length) {
      return;
    }
    const all: ReviewCard[] = ReviewCardStore.load(c);
    const cur: ReviewCard = this.reviewCards[this.reviewIndex];
    for (let k = 0; k < all.length; k++) {
      if (all[k].id === cur.id) {
        ReviewCardStore.grade(all[k], grade);
        break;
      }
    }
    ReviewCardStore.save(c, all);
    if (this.reviewIndex + 1 >= this.reviewCards.length) {
      this.shelfVisible = false;
      this.toast(L10n.t('今天的卡片复习完了'));
      return;
    }
    this.reviewIndex = this.reviewIndex + 1;
    this.reviewFlipped = false;
  }

  /**
   * **知识图谱**（批 3）：把各篇的 `[[文档链接]]` 汇总成关系图。
   * 本轮以「关系清单」呈现（节点数 / 引用数 / 待补 / 未连接）；
   * mermaid 图形视图需要渲染通道，下一轮接（`KnowledgeGraph.toMermaid` 已备好）。
   */
  private runGraph(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    let r: GraphResult | null = null;
    try {
      r = KnowledgeGraph.build(c);
    } catch (err) {
      this.toast(L10n.t('构建图谱失败'));
      return;
    }
    if (r === null) {
      return;
    }
    const res: GraphResult = r;
    if (res.nodes.length === 0) {
      this.toast(L10n.t('还没有文档之间的 [[链接]]'));
      return;
    }
    // **图形视图**：生成 mermaid 源码，写进一篇《知识图谱》文档 ——
    // 打开它就能看到已有渲染通道画出来的图（不必为图谱再造一个 Web 容器）。
    const src: string = KnowledgeGraph.toMermaid(res);
    const lines: string[] = [];
    lines.push('# 知识图谱');
    lines.push('');
    lines.push('> 由「书架封面 ⋯ → 知识图谱」自动生成；再生成一次会新建一篇'
      + '（同名时自动加序号），旧的可以自行删除。');
    lines.push('');
    lines.push('**' + KnowledgeGraph.summary(res) + '** · 已扫 ' + res.scanned + ' 篇文档');
    lines.push('');
    lines.push('```mermaid');
    lines.push(src);
    lines.push('```');
    if (res.missing.length > 0) {
      lines.push('');
      lines.push('## 待补文档');
      lines.push('');
      lines.push('> 被 [[链接]] 指向、但文档还不存在的条目。');
      lines.push('');
      for (let k = 0; k < res.missing.length; k++) {
        lines.push('- ' + res.missing[k]);
      }
    }
    if (res.isolated.length > 0) {
      lines.push('');
      lines.push('## 未连接');
      lines.push('');
      lines.push('> 在书架里、但没有任何引用关系的文档。');
      lines.push('');
      for (let k = 0; k < res.isolated.length; k++) {
        lines.push('- ' + res.isolated[k]);
      }
    }
    const meta: DocMeta | null = DocStore.create(c, '知识图谱', lines.join('\n'));
    this.refresh();
    if (meta === null) {
      this.toast(L10n.t('生成失败：无法写入文档'));
      return;
    }
    this.toast('已生成《' + meta.name + '》，打开即可查看图谱');
  }

  /**
   * **今日笺**（批 2）：把"今天该干什么"汇总成一页 —— 待办 / 今日修改 / 今日读过 /
   * 读到一半的书。数据全部来自 `DocMeta`（mtime / lastOpen / progressRatio）与
   * TaskBoard，不需要任何额外存储，因此永远不会与真实状态脱节。
   */
  private runDailyNote(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    const day: number = 24 * 60 * 60 * 1000;
    const now: number = Date.now();
    const list: DocMeta[] = DocStore.list(c);
    const changed: string[] = [];
    const opened: string[] = [];
    const reading: string[] = [];
    let chars: number = 0;
    for (let k = 0; k < list.length; k++) {
      const m: DocMeta = list[k];
      chars += m.charCount;
      if (now - m.mtime <= day && changed.length < 4) {
        changed.push(m.name);
      }
      if (m.lastOpen > 0 && now - m.lastOpen <= day && opened.length < 4) {
        opened.push(m.name);
      }
      if (m.progressRatio > 0.01 && m.progressRatio < 0.99 && reading.length < 4) {
        reading.push(m.name + '（' + Math.round(m.progressRatio * 100) + '%）');
      }
    }
    let taskLine: string = '';
    try {
      const t: TaskBoardResult = TaskBoard.collect(c, true);
      taskLine = TaskBoard.summary(t);
      if (t.items.length > 0) {
        taskLine += '\n最紧的：' + t.items[0].text
          + '（《' + t.items[0].docName + '》第 ' + t.items[0].line + ' 行）';
      }
    } catch (err) {
      taskLine = '读取失败';
    }
    // 【复习】今天到期的卡片数 —— 把"该读"和"该记"放在同一页
    let reviewLine: string = '';
    try {
      const st: ReviewStats = ReviewCardStore.stats(ReviewCardStore.load(c));
      reviewLine = ReviewCardStore.summary(st);
    } catch (err) {
      reviewLine = '读取失败';
    }
    const body: string = '书架共 ' + list.length + ' 篇 · ' + chars + ' 字\n\n'
      + '【待办】' + taskLine + '\n\n'
      + '【复习】' + reviewLine + '\n\n'
      + '【今日修改】' + (changed.length > 0 ? changed.join('、') : L10n.t('无')) + '\n\n'
      + '【今日读过】' + (opened.length > 0 ? opened.join('、') : L10n.t('无')) + '\n\n'
      + '【读到一半】' + (reading.length > 0 ? reading.join('、') : L10n.t('无'));
    this.getUIContext().getPromptAction().showDialog({
      title: L10n.t('今日笺'), message: body,
      buttons: [{ text: L10n.t('知道了'), color: this.palette().accent }]
    });
  }

  /**
   * **全部待办**（批 2）：跨文档收集未完成任务清单（对话框形式）。
   * 每条带来源文档与行号，方便回到原文处理。
   */
  /**
   * **拖文件到新建卡片上导入**：从文件管理器 / 桌面拖 .md / .txt
   * 到书架新建卡片松手即导入；成功后打开第一篇（阅读页），多文件 toast 汇总。
   * 拖拽数据走 UDMF；外部拖入兼容不同记录类型和 URI 格式。
   */
  private handleFileDrop(event?: DragEvent): void {
    if (event === undefined || event === null) {
      return;
    }
    const data = event.getData();
    if (data === undefined || data === null) {
      this.toast(L10n.t('请将 .md / .txt 文件拖到新建卡片上'));
      return;
    }
    const c = this.ctx();
    if (c === null) {
      return;
    }
    const records = data.getRecords();
    const uris: string[] = [];
    for (let k = 0; k < records.length; k++) {
      const rec = records[k];
      let found: string = '';
      try {
        const types: string[] = rec.getTypes();
        if (types.includes(uniformTypeDescriptor.UniformDataType.FILE_URI)) {
          const fileUriUds = rec.getEntry(uniformTypeDescriptor.UniformDataType.FILE_URI) as uniformDataStruct.FileUri;
          if (fileUriUds.oriUri !== undefined && fileUriUds.oriUri !== null && fileUriUds.oriUri.length > 0) {
            found = fileUriUds.oriUri;
          }
        }
      } catch (_) { /* 忽略 */ }
      if (found.length > 0) {
        uris.push(found);
      }
    }
    if (uris.length === 0) {
      this.toast(L10n.t('请拖入 .md 或 .txt 文件到新建卡片'));
      return;
    }
    let first: DocMeta | null = null;
    let ok: number = 0;
    let fail: number = 0;
    for (let k = 0; k < uris.length; k++) {
      try {
        const meta: DocMeta | null = DocStore.importFromUri(c, uris[k]);
        if (meta !== null) {
          ok++;
          if (first === null) {
            first = meta;
          }
        } else {
          fail++;
        }
      } catch (err) {
        fail++;
      }
    }
    if (ok === 0) {
      this.toast(fail > 0 ? '导入失败（只支持 md / txt 文件）' : L10n.t('没有导入任何文件'));
      return;
    }
    this.refresh();
    this.animateNextRefresh = true;
    if (first !== null) {
      const route: ReaderRoute = { name: first.name };
      this.pushPage('pages/Reader', route);
    }
    this.toast('已导入 ' + ok + ' 篇' + (fail > 0 ? '，' + fail + ' 篇失败' : ''));
  }

  /** 打开「阅读轨迹」面板：收集最近打开的文档（按 lastOpen 倒序，最多 20 条）。 */
  private openTrail(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    const list: DocMeta[] = DocStore.list(c);
    const items: DocMeta[] = [];
    for (let k = 0; k < list.length; k++) {
      if (list[k].lastOpen > 0) {
        items.push(list[k]);
      }
    }
    // 按 lastOpen 倒序（索引选择排序，避开 Set/for...of 类坑），取前 20 条
    for (let i = 0; i < items.length - 1; i++) {
      let best: number = i;
      for (let j = i + 1; j < items.length; j++) {
        if (items[j].lastOpen > items[best].lastOpen) {
          best = j;
        }
      }
      if (best !== i) {
        const tmp: DocMeta = items[i];
        items[i] = items[best];
        items[best] = tmp;
      }
    }
    this.trailItems = items.slice(0, 20);
    this.shelfSheet = 'trail';
    this.shelfVisible = true;
  }

  /**
   * 轨迹用的时间文案：**具体时间**（用户要求"把具体时间写上"）——
   * 今天 → 「今天 14:22」；昨天 → 「昨天 09:10」；今年更早 → 「09-28 21:05」；跨年 → 「2025-10-28」。
   */
  private trailTime(ts: number): string {
    const d: Date = new Date(ts);
    const hh: string = (d.getHours() < 10 ? '0' : '') + d.getHours();
    const mm: string = (d.getMinutes() < 10 ? '0' : '') + d.getMinutes();
    const now: Date = new Date();
    const dayMs: number = 86400 * 1000;
    const todayStart: number = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    if (ts >= todayStart) {
      return '今天 ' + hh + ':' + mm;
    }
    if (ts >= todayStart - dayMs) {
      return '昨天 ' + hh + ':' + mm;
    }
    const mo: string = (d.getMonth() + 1 < 10 ? '0' : '') + (d.getMonth() + 1);
    const dd: string = (d.getDate() < 10 ? '0' : '') + d.getDate();
    if (d.getFullYear() === now.getFullYear()) {
      return mo + '-' + dd + ' ' + hh + ':' + mm;
    }
    return d.getFullYear() + '-' + mo + '-' + dd;
  }

  /** 「阅读轨迹」面板：**时间轴**（参考用户给的日清单样式）——
   *  左列具体时间 → 圆点竖线 → 两段式胶囊卡（左段进度标签 / 右段文档名），紧凑排列。 */
  @Builder
  trailSheet() {
    Scroll() {
      Column({ space: 0 }) {
        ForEach(this.trailItems, (m: DocMeta, idx: number) => {
          Row({ space: 6 }) {
            // 时间列（轴外，右对齐）
            Text(this.trailTime(m.lastOpen))
              .fontSize(HwType.caption - 1)
              .fontColor(this.palette().textTertiary)
              .width(76)
              .textAlign(TextAlign.End)

            // 轴列：竖线贯通 + 圆点（首条裁上段、末条裁下段）。
            // ⚠️ 只用 alignSelf(Stretch) 拉伸——写 height('100%') 会在未定高的行里
            // 取整个滚动视口的高，把每一行都撑出一屏的间距（实测踩坑）
            Stack({ alignContent: Alignment.Center }) {
              Column()
                .width(2)
                .backgroundColor(this.palette().divider)
                .margin({ top: idx === 0 ? 5 : 0,
                  bottom: idx === this.trailItems.length - 1 ? 5 : 0 })
              Column()
                .width(10)
                .height(10)
                .borderRadius(5)
                .backgroundColor(idx === 0 ? this.palette().accent : this.palette().divider)
            }
            .width(20)
            .alignSelf(ItemAlign.Stretch)

            // 两段式胶囊卡：左段进度标签 / 右段文档名（贴紧凑，参考日清单）。
            // **卡片走沉浸光感承载层**（用户要求）；进度徽章改成圆形独立元素，
            // 不再是"左段色块"——蓝段的直角裁切观感来自色块拼接（用户反馈）。
            Stack() {
              ImmersiveCardLayer({ layerRadius: 12, layerShadow: false })
              Row({ space: 8 }) {
                Text(m.progressRatio > 0.005
                  ? Math.round(m.progressRatio * 100) + '%' : L10n.t('未读'))
                  .width(30)
                  .height(30)
                  .borderRadius(15)
                  .backgroundColor(m.progressRatio > 0.005
                    ? this.palette().accent : this.palette().divider)
                  .fontColor(m.progressRatio > 0.005 ? '#FFFFFFFF' : this.palette().textTertiary)
                  .fontSize(HwType.caption - 2)
                  .textAlign(TextAlign.Center)
                Text(m.name)
                  .fontSize(HwType.label)
                  .fontColor(this.palette().textPrimary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ left: 8, right: 10 })
            }
            .height(44)
            // ⚠️ 占位必须用 layoutWeight（外层 Row 里还有时间列 + 轴列两个固定宽兄弟）——
            // 写 width('100%') 会按整行宽测量、卡片撑出屏幕（此前已踩过两次）
            .layoutWeight(1)
            .borderRadius(12)
            .border({ width: 1, color: this.palette().divider })
            .margin({ top: 2, bottom: 2 })
            .onClick(() => {
              this.shelfVisible = false;
              const route: ReaderRoute = { name: m.name };
              this.pushPage('pages/Reader', route);
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }, (m: DocMeta, idx: number) => 'trail_' + m.name + '_' + m.lastOpen)
        if (this.trailItems.length === 0) {
          Text(L10n.t('还没有阅读记录，打开一篇文档试试'))
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')
            .padding(HwSpace.sm)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .constraintSize({ maxHeight: 460 })
    .width('100%')
    // ⚠️ 半模态内容区不自带内边距（工程铁律）——不加这个，卡片会贴到屏幕边缘
    .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.sm })
  }

  // ══════════════════════ 批量操作（批 5） ══════════════════════
  //
  // 入口：封面「⋯」菜单 →「批量管理」→ 多选模式（点击封面 = 勾选）。
  // 底栏换成操作条：全选 / 移入文件夹 / 删除 / 完成。文件夹与内置文档不参与删除
  //（内置是 rawfile 常驻项），移入文件夹仅对顶层文档生效。

  /** 进入多选（「⋯」菜单入口）：当前这篇默认选中。 */
  private openMultiSelect(first: string): void {
    this.shelfVisible = false;
    this.multiNames = [first];
    this.multiSelect = true;
    this.toast(L10n.t('点封面勾选文档，底栏可批量操作'));
  }

  private exitMultiSelect(): void {
    this.multiSelect = false;
    this.multiNames = [];
  }

  /** 勾选 / 取消一篇（多选模式下点封面）。 */
  private toggleMulti(name: string): void {
    const at: number = this.multiNames.indexOf(name);
    if (at >= 0) {
      const next: string[] = [];
      for (let k = 0; k < this.multiNames.length; k++) {
        if (k !== at) {
          next.push(this.multiNames[k]);
        }
      }
      this.multiNames = next;
    } else {
      this.multiNames = this.multiNames.concat([name]);
    }
  }

  private isMultiSelected(name: string): boolean {
    return this.multiNames.indexOf(name) >= 0;
  }

  /** 全选 / 全不选（只针对当前书架流里的文档）。 */
  private toggleMultiAll(): void {
    if (this.multiNames.length >= this.docs.length) {
      this.multiNames = [];
      return;
    }
    const all: string[] = [];
    for (let k = 0; k < this.docs.length; k++) {
      all.push(this.docs[k].name);
    }
    this.multiNames = all;
  }

  /** 批量删除：内置文档跳过并提示；其余逐个 DocStore.remove（连本地文件）。 */
  private multiRemove(): void {
    if (this.multiNames.length === 0) {
      this.toast(L10n.t('先勾选要删除的文档'));
      return;
    }
    let builtinHit: boolean = false;
    const targets: string[] = [];
    for (let k = 0; k < this.multiNames.length; k++) {
      let isBuiltin: boolean = false;
      for (let j = 0; j < this.docs.length; j++) {
        if (this.docs[j].name === this.multiNames[k]) {
          isBuiltin = this.docs[j].builtin;
          break;
        }
      }
      if (isBuiltin) {
        builtinHit = true;
      } else {
        targets.push(this.multiNames[k]);
      }
    }
    this.getUIContext().getPromptAction().showDialog({
      title: L10n.t('删除 ') + targets.length + ' 篇文档？',
      message: builtinHit ? L10n.t('内置文档不会删除（只能整体移除）；其余的本地文件会一并删除，不可恢复。')
        : L10n.t('本地文件会一并删除，删除后不可恢复。'),
      buttons: [
        { text: L10n.t('取消'), color: this.palette().textSecondary },
        { text: L10n.t('删除'), color: '#FFD93B3B' }
      ]
    }).then((result) => {
      if (result.index !== 1) {
        return;
      }
      const c = this.ctx();
      if (c === null) {
        return;
      }
      let ok: number = 0;
      for (let k = 0; k < targets.length; k++) {
        try {
          if (DocStore.remove(c, targets[k])) {
            ok++;
          }
        } catch (err) {
          // 单篇失败不中断整批
        }
      }
      this.multiNames = [];
      this.multiSelect = false;
      this.refresh();
      this.toast('已删除 ' + ok + ' 篇' + (builtinHit ? L10n.t('（内置文档已跳过）') : ''));
    }).catch(() => {
      this.toast(L10n.t('操作失败'));
    });
  }

  /** 批量移入文件夹：先从原文件夹脱离，再逐篇加入目标文件夹。 */
  private multiToFolder(folderName: string): void {
    const c = this.ctx();
    if (c === null || this.multiNames.length === 0) {
      return;
    }
    let ok: number = 0;
    for (let k = 0; k < this.multiNames.length; k++) {
      try {
        // addToFolder 内部自带 detachFromFolders（一篇只属一个文件夹）
        if (DocStore.addToFolder(folderName, this.multiNames[k])) {
          ok++;
        }
      } catch (err) {
        // 单篇失败不中断
      }
    }
    this.refresh();
    this.toast('已把 ' + ok + ' 篇移入「' + folderName + '」');
  }

  /** 移入文件夹的下拉选项。 */
  private folderSelectOptions(): SelectOption[] {
    const out: SelectOption[] = [];
    for (let k = 0; k < this.folders.length; k++) {
      const opt: SelectOption = { value: this.folders[k].name };
      out.push(opt);
    }
    return out;
  }

  private runTaskBoard(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    let r: TaskBoardResult | null = null;
    try {
      // **收集全部条目**（含已完成的）：勾选后条目**留在列表里**、显示打勾划线，
      // 而不是直接消失 —— 用户要能看到"勾过了什么"（用户反馈改）。
      r = TaskBoard.collect(c, false);
    } catch (err) {
      this.toast(L10n.t('读取任务清单失败'));
      return;
    }
    if (r === null) {
      return;
    }
    const res: TaskBoardResult = r;
    // 空态：清单里一条任务都没有（open+done 皆为 0）
    if (res.open + res.done === 0) {
      this.toast(L10n.t('还没有任务清单'));
      return;
    }
    // **改用可滑动的面板**（用户反馈：对话框里说"另有 N 项"却看不到内容，
    // 等于让人猜）。面板里列出**全部**条目，可滚动、点条目直接进那篇文档。
    this.taskItems = res.items;
    this.taskSummary = TaskBoard.summary(res) + ' · ' + res.docs + ' 篇'
      + (res.truncated ? L10n.t('（已达上限）') : '');
    this.shelfSheet = 'tasks';
    this.shelfVisible = true;
  }

  /**
   * **批注汇总**（批 1）：把这篇文档的标注集中列出（对话框形式），
   * 复习时不必再翻遍全文找标记。手写批注的 `note` 以 `hw:` 开头（存的是手写图路径），
   * 这里只标注形态、不显示路径。逐条带 ①②③ 与高亮文本摘要。
   */
  private runAnnotationSummary(docName: string): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    let items: MdAnnotation[] = [];
    try {
      items = AnnotationStore.load(c, docName);
    } catch (err) {
      this.toast(L10n.t('读取批注失败'));
      return;
    }
    if (items.length === 0) {
      this.toast(L10n.t('这篇文档还没有批注'));
      return;
    }
    // 全量统计（列表只展示前 8 条，但计数要覆盖全部）
    let withNote: number = 0;
    let handCount: number = 0;
    for (let k = 0; k < items.length; k++) {
      if (items[k].note.startsWith('hw:')) {
        handCount++;
      } else if (items[k].note.length > 0) {
        withNote++;
      }
    }
    let body: string = '共 ' + items.length + ' 处标注';
    if (withNote > 0) {
      body += ' · ' + withNote + ' 条文字批注';
    }
    if (handCount > 0) {
      body += ' · ' + handCount + ' 处手写';
    }
    const show: number = Math.min(8, items.length);
    for (let k = 0; k < show; k++) {
      const a: MdAnnotation = items[k];
      const isHand: boolean = a.note.startsWith('hw:');
      const excerpt: string = a.text.trim().replace(/\s+/g, ' ');
      body += '\n\n' + (k + 1) + '. '
        + (excerpt.length > 40 ? excerpt.substring(0, 40) + '…' : excerpt);
      if (isHand) {
        body += '\n   ✍️ 手写批注';
      } else if (a.note.length > 0) {
        body += '\n   💬 ' + (a.note.length > 60 ? a.note.substring(0, 60) + '…' : a.note);
      }
    }
    if (items.length > show) {
      body += '\n\n…另有 ' + (items.length - show) + ' 处标注';
    }
    this.getUIContext().getPromptAction().showDialog({
      title: L10n.t('批注汇总 · ') + docName, message: body,
      buttons: [{ text: L10n.t('知道了'), color: this.palette().accent }]
    });
  }

  /**
   * 文档体检（批 1）：扫描这篇文档的结构性问题，结果用对话框列出（带行号）。
   * 只对**文档**开放（文件夹没有正文）。
   */
  private runLint(docName: string): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    const meta: DocMeta | undefined = DocStore.find(c, docName);
    if (meta === undefined) {
      this.toast(L10n.t('文档不存在'));
      return;
    }
    let report: LintReport | null = null;
    try {
      const content: string = DocStore.readText(c, meta, this.encodingOf(docName));
      report = DocLint.scan(c, docName, content);
    } catch (err) {
      this.toast(L10n.t('体检失败：无法读取文档'));
      return;
    }
    if (report === null) {
      return;
    }
    const r: LintReport = report;
    // 组装对话框内容：摘要 + 前 6 条（其余只报数量，避免对话框过长）
    let body: string = DocLint.summary(r) + '\n'
      + '共 ' + r.lines + ' 行 · ' + r.chars + ' 字'
      + (r.todoOpen > 0 || r.todoDone > 0
        ? '\n任务清单：待办 ' + r.todoOpen + ' · 已完成 ' + r.todoDone : '');
    const show: number = Math.min(6, r.issues.length);
    for (let k = 0; k < show; k++) {
      const it: LintIssue = r.issues[k];
      body += '\n\n' + (it.line > 0 ? L10n.t('第 ') + it.line + ' 行 · ' : '') + it.kind + '\n' + it.message;
    }
    if (r.issues.length > show) {
      body += '\n\n…另有 ' + (r.issues.length - show) + ' 条，修完这些再看';
    }
    this.getUIContext().getPromptAction().showDialog({
      title: L10n.t('文档体检'), message: body, buttons: [{ text: L10n.t('知道了'), color: this.palette().accent }]
    });
  }

  /** 读取某篇文档的编码（没设过 = auto 自动识别）。 */
  private encodingOf(docName: string): string {
    const v: string | undefined = AppStorage.get<string>(this.encodingKeyOf(docName));
    return v === undefined || v.length === 0 ? 'auto' : v;
  }

  /** 下一档编码（循环：自动 → UTF-8 → GBK → GB18030 → Big5 → Latin-1 → 自动）。 */
  private nextEncoding(cur: string): string {
    if (cur === 'auto') {
      return 'utf-8';
    }
    if (cur === 'utf-8') {
      return 'gbk';
    }
    if (cur === 'gbk') {
      return 'gb18030';
    }
    if (cur === 'gb18030') {
      return 'big5';
    }
    if (cur === 'big5') {
      return 'iso-8859-1';
    }
    return 'auto';
  }

  /** 编码档位列表（书架「⋯」面板的下拉用；与阅读页六档一致）。 */
  private encodingValues(): string[] {
    const out: string[] = [];
    out.push('auto');
    out.push('utf-8');
    out.push('gbk');
    out.push('gb18030');
    out.push('big5');
    out.push('iso-8859-1');
    return out;
  }

  /** 编码的显示名。 */
  private encodingLabel(value: string): string {
    if (value === 'utf-8') {
      return 'UTF-8';
    }
    if (value === 'gbk') {
      return 'GBK';
    }
    if (value === 'gb18030') {
      return 'GB18030';
    }
    if (value === 'big5') {
      return 'Big5';
    }
    if (value === 'iso-8859-1') {
      return 'Latin-1';
    }
    return '自动';
  }

  /** 切换收藏排序并即时重排。 */
  private applyStarSort(sort: string): void {    this.starSort = sort;
    const c = this.ctx();
    if (c !== null) {
      this.starredDocs = DocStore.starredList(c, sort);
    }
  }

  /** 收藏时间 → '2026-10-02 12:30'；无记录显示「—」。 */
  private static starDateLabel(ms: number | undefined): string {
    if (ms === undefined || ms <= 0) {
      return '—';
    }
    const d: Date = new Date(ms);
    const pad = (v: number): string => {
      return v < 10 ? '0' + v : '' + v;
    };
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
      + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  /** 封面格式角标：TXT / MD（应用同时支持两种文件，用户要求默认封面带一个淡淡的格式字）。 */
  private static formatLabelOf(fileName: string): string {
    return fileName.toLowerCase().endsWith('.txt') ? 'TXT' : 'MD';
  }

  /**
   * 胶囊内的快捷按钮：圆形小钮 + 主题色薄底 + 加号图标。
   * 点击 = 新建文档；长按 = 导入 .md（与「新建卡」同款，600ms 起效）。
   */
  @Builder
  newDocButton() {
    Stack() {
      ImmersiveIconButton({
        buttonSize: NEW_BTN_SIZE,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          // 文件夹面板展开期间忽略（与「新建卡」同一套保护）
          if (this.openFolderName.length > 0) {
            return;
          }
          this.createDoc();
        }
      }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(18)
          .fontColor([this.palette().accent])
      }
    }
    .width(NEW_BTN_SIZE)
    .height(NEW_BTN_SIZE)
    .margin(this.gripSide === -1 ? { right: HwSpace.xs } : { left: HwSpace.xs })
    .gesture(
      LongPressGesture({ duration: 600 })
        .onAction(() => {
          if (this.openFolderName.length > 0) {
            return;
          }
          this.importDoc();
        })
    )
  }

  // ══════════════════════ 组装 ══════════════════════

  /**
   * 胶囊内的「AI 助手」按钮（1.2.0）：圆形小钮 + 火花图标。
   * 与新建 / 收藏同一套，跟随智感握姿换边；点击进入 AI 对话页。
   */
  @Builder
  aiButton() {
    // **后台生成完成的新事件角标**（用户要求）：红点 + 白描边，画在按钮右上角。
    // ⚠️ 不用官方 Badge 包裹——Badge 会改变子组件的布局尺寸，导致这颗按钮
    // 与底栏其它按钮**高度不一致**（用户实测）；改成与相邻按钮完全同构的
    // Stack(36×36) + 角标覆盖层（有新事件才挂载，count<=0 不出现）。
    Stack({ alignContent: Alignment.TopEnd }) {
      ImmersiveIconButton({
        buttonSize: NEW_BTN_SIZE,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          if (this.openFolderName.length > 0) {
            return;
          }
          // **基础模式（纯离线）拦截**（用户要求）：AI 助手要走网络，离线直接挡在入口
          if (UpdateService.isOffline()) {
            this.toast(L10n.t('基础模式（纯离线）下 AI 助手不可用'));
            return;
          }
          if (this.pathStack !== null) {
            this.pathStack.pushPath({ name: 'pages/AiChat' });
          }
        }
      }) {
        Image($r('app.media.ai_spark'))
          .width(18)
          .height(18)
          .fillColor(this.palette().accent)
          .draggable(false)
      }
      if (this.aiNewReply > 0) {
        Column()
          .width(12)
          .height(12)
          .borderRadius(6)
          .backgroundColor('#FFFF3B30')
          .border({ width: 1.5, color: '#FFFFFFFF' })
          .margin({ top: 2, right: 2 })
          // 出现 / 清零带过渡（凡事带动画）
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 220, curve: Curve.FastOutSlowIn })
            .combine(TransitionEffect.scale({ x: 0.5, y: 0.5 })))
      }
    }
    .width(NEW_BTN_SIZE)
    .height(NEW_BTN_SIZE)
    .margin(this.gripSide === -1 ? { right: HwSpace.xs } : { left: HwSpace.xs })
  }

  /**
   * 书架页：**原地不动**（位移钉 0、不淡出）。
   * 退场/进场的动感由「封面层滑走 + 阅读页从右滑入」承担，
   * 书架自己再动就是两套效果打架。
   */
  /**
   * 转场说明：一镜到底的几何动画由**共享元素（geometryTransition）**承担，
   * 页面本身不做位移/缩放，否则会和共享元素抢时序。
   * 迁移到 Navigation 后，页面进出由 NavDestination 的转场负责（默认右侧滑入）。
   */


  build() {
    // 根节点是 Navigation：书架的 UI 直接作为它的首页内容，
    // 阅读页 / 设置页 / 编辑页作为 NavDestination 挂在同一条 NavPathStack 上。
    // 与 router 的关键差别：所有页面在**同一个 UI 实例**里，
    // geometryTransition / customNavContentTransition 才能跨页生效。
    Navigation(this.pathStack) {
    Stack({ alignContent: Alignment.TopStart }) {
      this.backdrop()

      Row() {
        Column() {
          // ── 横向分页：书架 ⇄ 写作日志 ⇄ 文房（用户要求：左右滑动切换页面）──
          // 顶栏 / 底栏浮在所有页之上（在 Swiper 外），标题随页切换。
          // indicator 关掉：左上角的页名就是当前页的提示，不加多余的点。
          Swiper(this.pageSwiper) {
          // ── 页 1：文房（书架**右滑**到达；跨文档工具的聚合桌面）──
          Column() {
            Scroll() {
              Column({ space: HwSpace.lg }) {
                // 「阅读」统计卡（1.1.0 从写作日志页搬来；用户要求放在文房页）
                this.readingStatsCard()

                // ── 批注速记卡（存在复习卡片时展示）：随手看两条批注，方便学习 ──
                if (this.studyAnnPreview.length > 0) {
                  this.studyCard('批注速记', $r('sys.symbol.highlighter_tip'),
                    this.studyAnnPreview, '去复习', (): void => {
                      this.pushPage('pages/Review');
                    })
                }

                // 今日笺：**原地下拉展示**（用户要求：不要弹窗）——点卡片展开 / 收起
                this.dailyNoteCard()

                // 复习卡片：点击进入独立复习页（选文档复习 + 遗忘曲线 + 学习记录）
                // 复习卡片：点击进入独立复习页（图标用用户指定的自定义 SVG）
                this.studyCard('复习卡片', $r('app.media.study_word_card'),
                  [this.studyDue > 0
                    ? L10n.t('今天到期 ') + this.studyDue + ' 张，该翻卡了'
                    : L10n.t('今天没有到期的卡片'), this.studyReviewSummary],
                  '进入复习', (): void => {
                    this.pushPage('pages/Review');
                  }, true)

                // 全部待办：**原地下拉展示**全部待办（上限 50 条，内部滚动）
                this.taskBoardCard()

                // 批注汇总：把全部标注整理成一篇文档收进书架
                this.studyCard('批注汇总', $r('sys.symbol.square_and_pencil'),
                  ['把全部文档的荧光笔与文字批注整理成一篇《批注汇总》放进书架，方便复盘。'],
                  '生成批注汇总', (): void => {
                    this.exportAnnotationSummary();
                  })
              }
              .width('100%')
              .padding({
                left: HwSpace.lg,
                right: HwSpace.lg,
                // 顶部 = 状态栏 + 悬浮胶囊 + 余量：内容从胶囊底下开始，不顶进状态栏
                top: this.padTop() + HwBar.pill + HwSpace.md,
                bottom: this.padBottom() + 84
              })
            }
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            .width('100%')
            .height('100%')
            .align(Alignment.Top)
            // 搜索展开时整页内容模糊（与书架格子同一程度 = cellBlur，用户要求三页一致）
            .blur(this.cellBlur())
          }
          .width('100%')
          .height('100%')

          // ── 页 2：书架（原网格 / 树形视图原样内联；**默认停在这一页**）──
          Column() {
          if (this.treeMode) {
            this.treeList()
          } else {
            // **恢复 1.0.2 的实现**：面板排在网格流里（跨满三列、高度从 0 长到目标值），
            // 插在「文件夹行」末尾，同行邻居留在原格、下方的图标被推开。
            // 之前的"网格外浮层"方案在真机上定位不稳（面板跑屏幕上方 / 直接不见），
            // 这版是验证过可用的。
            // Scroller 必须走构造参数（Grid 没有 .scroller 属性）
            Grid(this.gridScroller) {
            GridItem() {
              this.resumeBanner()
            }
            .columnStart(0)
            .columnEnd(this.shelfColumns() - 1)
            // 首屏留白放在**第一个内容项**上而不是滚动容器上：
            // 滚动容器的 padding 是裁剪边界，放那儿内容就永远进不了顶栏底下；
            // 放在内容项上，静止时内容在胶囊下方，滚动时能穿到胶囊下面。
            // ⚠️ **不加 bottom margin**（用户反馈"卡片和书籍之间空隙太大"）：
            // 通栏卡与下一行的间距统一交给 rowsGap，和书与书之间的空隙保持一致。
            .margin({
              // 书架页有标签筛选条时再下移一条（否则横幅/封面被标签栏压住，用户实测）
              top: this.padTop() + HwBar.pill + HwSpace.md
                + (this.shelfPage === 1 && this.allTags().length > 0 ? 34 : 0)
            })
            .opacity(this.cellOpacity())
            .blur(this.cellBlur())
            // 淡入淡出：文件夹展开时其他格子是渐隐渐糊，不是硬切
            .animation({ duration: 260, curve: Curve.FastOutSlowIn })

            GridItem() {
              this.newCell()
            }
            .opacity(this.cellOpacity())
            .blur(this.cellBlur())
            .animation({ duration: 260, curve: Curve.FastOutSlowIn })

            ForEach(this.looseBuiltinDocs(), (meta: DocMeta) => {
              GridItem() {
                this.docCell(meta, false)
              }
              .opacity(this.cellOpacity())
              .blur(this.cellBlur())
              .animation({ duration: 260, curve: Curve.FastOutSlowIn })
            }, (meta: DocMeta) => 'b_' + meta.name)

            // ── 文件夹与松散文档**排在同一条流里**（顺序见 DocStore.shelfOrder）──
            // 只有这样，拖拽才能让「文件夹 ↔ 文档」也互换位置。
            ForEach(this.items, (item: ShelfItem, index: number) => {
              GridItem() {
                if (item.kind === 'folder') {
                  // 原文件夹留在原地；打开面板时其他格子淡出 + 模糊
                  if (item.folder !== null) {
                    this.folderCell(item.folder)
                  }
                } else if (item.meta !== null) {
                  this.docCell(item.meta, false)
                }
              }
              .opacity(this.gridItemAlpha(item))
              .blur(item.kind === 'folder' && this.openFolderName === item.name
                ? 0 : this.cellBlur())
              // 悬停轻微缩小 / 合并与吸入缩得更明显：文档格与文件夹格统一在这里施加
              .scale({ x: this.cellScale(item.name), y: this.cellScale(item.name) })
              // 出入场：新出现的格淡入微放，被移走的格淡出微缩（配合 animateTo 生效）
              .transition({
                opacity: 0,
                scale: { x: 0.9, y: 0.9 }
              })
              // 淡入淡出：透明度/模糊的变化要有过渡，否则是硬切、很突兀
              .animation({ duration: 260, curve: Curve.FastOutSlowIn })

              // 展开面板插在「本行最后一个格子」之后（见 panelAfterIndex），
              // 这样同行的左右邻居留在原格，只有下方的图标被推开（1.0.2 的做法）。
              // 条件用 folderPanelMounted（不是 openFolderName）：收起时名字要留到动画
              // 跑完（压暗其他格子用），而节点必须当场摘掉，底部提示文本才不会二次跳。
              //
              // **修复「有文档在文件夹右边，展开的文件夹就消失」**：
              // 原条件带了 `item.kind === 'folder'`，可 panelAfterIndex() 返回的是
              // **本行最后一个格子**的下标——文件夹不在最右列时（比如在第 1 列、
              // 右边还并排放着别的文档），那个下标落在右边的**文档**上，
              // `kind === 'folder'` 判 false → 面板节点**从来没挂载过**，点开等于没反应。
              // 只有文件夹恰好在最右列（after 指向它自己）时才挂得上，所以表现为"时好时坏"。
              // 现在只按「是不是本行最后一格」判定，item 是文件夹还是文档都挂。
              if (this.folderPanelMounted && index === this.panelAfterIndex()) {
                GridItem() {
                  this.folderExpandPanel()
                }
                .columnStart(0)
                .columnEnd(this.shelfColumns() - 1)
                // top 保底间距：面板顶缘与上方一行（横幅/新建卡等）之间永远不贴住
                .margin({ top: HwSpace.md })
                // 量出面板在窗口里的真实位置：展开动画跑完后用它校正滚动幅度
                // （AUTO 只保证"面板顶边可见"，底部常被悬浮胶囊压住——用户反馈滚得不够）。
                .onAreaChange((oldValue: Area, newValue: Area) => {
                  const gp: Position = newValue.globalPosition;
                  const gy: Length | undefined = gp.y;
                  const gh: Length | undefined = newValue.height;
                  if (typeof gy === 'number' && typeof gh === 'number') {
                    this.panelWinTop = gy;
                    this.panelWinBottom = gy + gh;
                  }
                })
              }            }, (item: ShelfItem) => this.itemKey(item))

            if (this.userDocCount === 0) {
              GridItem() {
                Column({ space: HwSpace.xs }) {
                  Text(L10n.t('书架还是空的'))
                    .fontSize(HwType.label)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.palette().textPrimary)
                  // **两段提示合成一段**（用户要求精简）：
                  // 原「怎么新建」与「长按合并文件夹」各占一段，空书架时显得啰嗦
                  Text(L10n.t('点「新建文档」写一篇、或用文件夹按钮导入 .md 文件；长按封面拖到另一张上可合并成文件夹'))
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textTertiary)
                    .textAlign(TextAlign.Center)
                    .lineHeight(HwType.caption * 1.6)
                }
                .padding({ top: HwSpace.lg })
                .width('100%')
              }
              .columnStart(0)
              .columnEnd(this.shelfColumns() - 1)
            }

            // 有文档时才显示这条恒常提示（空书架时上面那段已经涵盖同样的信息）
            if (this.userDocCount > 0) {
            GridItem() {
              Text(L10n.t('长按封面拖到另一张上合并为文件夹 · 封面由文档名生成'))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
                .width('100%')
                .textAlign(TextAlign.Center)
                // 文末留白放在**内容项自身**上（滚动容器 padding 是裁剪边界）：
                // 底栏悬浮后，滚到底时最后一张卡片要能升到栏上方
                .padding({
                  top: HwSpace.lg,
                  bottom: this.padBottom() + HwBar.pill + HwSpace.lg
                })
            }
            .columnStart(0)
            .columnEnd(this.shelfColumns() - 1)
            // **「滚到底」的判据**（用户定义）：这条文末提示浮到顶栏位置、停在底栏上方，
            // 就是当前手动上滑能到达的最低处。展开文件夹时的自动滚动以它为上限，
            // 滚到它上沿贴着底栏就收手，绝不越过去把文件夹顶到屏幕顶端。
            .id('shelfEndHint')
            }
          }
          .columnsTemplate(this.columnsTemplateStr())
          .columnsGap(HwSpace.md)
          .rowsGap(HwSpace.lg)
          // Grid 自己吃 layoutWeight（与 1.0.2 一致：面板在网格流内，外层无 Stack）
          .width('100%')
          .layoutWeight(1)
          // 右侧滚动条不显示（用户要求）
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          // 顶部 padding 为 0：**内容要能画进顶栏底下**（滚动组件的 padding 是裁剪边界，
          // padding 区域不绘制）。顶栏是悬浮材质胶囊，文字从它下面穿过。
          .padding({ left: HwSpace.lg, right: HwSpace.lg })
          // 展开文件夹后，点空白处即收起（用户要求）。
          // 卡片/面板自身都有自己的 onClick，在 ArkUI 里会消费掉点击、
          // 不再传到本节点，所以点它们不会被误关。
          .onClick(() => {
            if (this.openFolderName.length > 0) {
              this.closeFolderPanel();
            }
          })
          .onScrollIndex((first: number, last: number) => {
            if (first <= 0) {
              this.scrollAccum = 0;
              this.toggleBars(true);
            }
          })
          .onDidScroll((offset: number, state: ScrollState) => {
            this.onScrollFrame(offset);
          })
          // **主题纪元拼在 Grid 容器上**：只换条目 key 时，已挂载的卡片（含其中的
          // 按钮）会被列表复用、颜色不跟着变；换容器 key 才会整段重建。
          .key('shelfGrid_' + this.themeEpoch + '_l' + this.languageTick)
          }
          }
          .width('100%')
          .height('100%')

          // ── 页 3：写作日志（设置页同款内容嵌入书架；「回头看看」卡置顶）──
          Column() {
            Scroll() {
              Column({ space: HwSpace.lg }) {
                // 「回头看看」卡从书架搬到这里置顶（随机一篇 / 那年今天）
                this.memoryCard()
                SettingsWriting({ embedded: true })
              }
              .width('100%')
              .padding({
                left: HwSpace.lg,
                right: HwSpace.lg,
                top: this.padTop() + HwBar.pill + HwSpace.md,
                bottom: this.padBottom() + 84
              })
            }
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            .width('100%')
            .height('100%')
            .align(Alignment.Top)
            // 搜索展开时整页内容模糊（与书架格子同一程度 = cellBlur，用户要求三页一致）
            .blur(this.cellBlur())
          }
          .width('100%')
          .height('100%')
          }
          .width('100%')
          .height('100%')
          // **循环滑动**（用户要求）：文房 ↔ 书架 ↔ 写作日志首尾相接
          .loop(true)
          .indicator(false)
          // 默认停在中间的书架页（页序：文房 0 · 书架 1 · 写作日志 2）
          // ⚠️ **必须绑到 shelfPage 而不是写死 1**：切深浅 / 换主题时根部 Navigation 换 key
          // 整树重建（见 applyThemeChange），写死 1 会让 Swiper 回到书架页 —— 用户在
          // 文房 / 写作日志切主题就被弹回书架（用户实测）。绑状态后重建也停在原页。
          .index(this.shelfPage)
          .duration(300)
          .onChange((index: number) => {
            this.shelfPage = index;
            this.lastAppliedPage = index;
            if (index !== 1 && this.searchExpanded) {
              // 离开书架页时顺手收起搜索（搜索框只属于书架页）
              this.collapseSearch();
            }
            this.onShelfPageChanged();
          })

          // ── 搜索展开时的「点任意区域收起」层 ──
          //
          // 这里有两个必须同时满足的约束，缺一个就"点了没反应"：
          //  ① **必须脱离布局流**：本层位于一个纵向 Column 内（同层还有网格、顶栏、底栏），
          //     若用普通的 height('100%')，它会按 Column 的可用高度解析并**再占一份高度**，
          //     把布局挤变形、自己也跑到网格下方 —— 所以必须 `.position` 绝对定位；
          //  ② **绘制顺序要在网格之上、顶栏/底栏之下**：节点顺序就决定了层级 ——
          //     它排在 Grid 之后（盖住网格与格子上那些"点开文档"的手势）、
          //     排在顶栏 / 底栏之前（顶栏按钮、搜索框、关闭钮照常可点）。
          // 于是：点网格 / 文件夹 / 任何空白 → 命中本层 → 收起搜索；
          //       点顶栏按钮、搜索框、结果卡片 → 由它们自己消费，不受影响。
          if (this.searchExpanded) {
            Column()
              .width('100%')
              .height('100%')
              .position({ x: 0, y: 0 })
              .onClick(() => {
                this.collapseSearch();
              })
          }

          // ── 悬浮顶栏 / 底栏（材质胶囊）─────────────────────────
          // 两者都**脱离布局流**（position 定位），内容从它们下面滚过。
          // hitTestBehavior 用 Transparent：胶囊自身的空隙不拦截触摸，
          // 点击会落到下方的卡片上；胶囊上的按钮照常可点。
          Row() {
            // **页名固定在左上角**（平板；不进胶囊、不随内容滚动位置变化），
            // 随分页切换（渐入渐出）；页序：文房 0 · 书架 1 · 写作日志 2
            if (this.isWideShelf()) {
              Column() {
                if (this.shelfPage === 0) {
                  Text(L10n.t('文房'))
                    .fontSize(24)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.palette().textPrimary)
                    .margin({ top: 6 })
                    .transition(TransitionEffect.OPACITY
                      .animation({ duration: 220, curve: Curve.FastOutSlowIn }))
                } else if (this.shelfPage === 2) {
                  Text(L10n.t('写作日志'))
                    .fontSize(24)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.palette().textPrimary)
                    .margin({ top: 6 })
                    .transition(TransitionEffect.OPACITY
                      .animation({ duration: 220, curve: Curve.FastOutSlowIn }))
                } else {
                  Text(L10n.t('书架'))
                    .fontSize(24)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.palette().textPrimary)
                    .margin({ top: 6 })
                    .transition(TransitionEffect.OPACITY
                      .animation({ duration: 220, curve: Curve.FastOutSlowIn }))
                }
              }
              .alignItems(HorizontalAlign.Start)
            }
            this.topBar()
          }
          .width('100%')
          .justifyContent(this.isWideShelf() ? FlexAlign.SpaceBetween : FlexAlign.Start)
          // 右留白 =「整体位移」调参：wideBarInset()（顶层调参区②），宽屏改它可整条左/右移
          .padding({
            left: HwSpace.lg,
            right: this.isWideShelf() ? this.wideBarInset() : HwSpace.lg
          })
          // 只让**胶囊本体**占触摸区（不含 padTop 那条空白），
          // 否则顶部近百 vp 都成了滑动死区，手一放上去就像「滑不动」。
          .position({ x: 0, y: this.padTop() })
          .hitTestBehavior(HitTestMode.Transparent)
          // **顶栏常驻**（用户要求）：不再随滚动淡出 / 上移，
          // 始终可见可点。收起逻辑现在只作用于底栏（同一份 barsVisible 状态）。
          .opacity(1)
          .translate({ y: 0 })

          // ── 书架页的标签筛选条：**胶囊正下方独立一行**（用户要求）──
          // ⚠️ 上一版把 this.tagBar() 塞进上面那个顶栏 Row 里 —— Row 是**横排**，
          // 它会紧挨着胶囊排在右边（被挤没 / 看不见），所以"顶栏下方没有标签栏"。
          // 这里另起一层、绝对定位到胶囊下方；只属书架页，切页随之渐隐（带动画）。
          if (this.shelfPage === 1 && this.allTags().length > 0) {
            // **没有任何文档带标签时不显示标签栏**（用户要求）：空栏没有信息量，
            // 还平白占一行高度。allTags 有缓存开销可控（文档数 × 标签数）。
            Column() {
              this.tagBar()
            }
            .width('100%')
            .position({ x: 0, y: this.padTop() + HwBar.pill + HwSpace.xs })
            .hitTestBehavior(HitTestMode.Transparent)
            .transition(TransitionEffect.OPACITY
              .animation({ duration: 200, curve: Curve.FastOutSlowIn }))
          }

          // ── 页数指示器（用户要求：悬浮底栏上方，**高度压低贴近底栏**）──
          // 三页各一枚圆点，当前页拉长成胶囊并染强调色；点圆点直接滑到对应页。
          Row({ space: HwSpace.xs }) {
            ForEach([0, 1, 2], (page: number) => {
              Column()
                .width(this.shelfPage === page ? 18 : 6)
                .height(6)
                .borderRadius(3)
                .backgroundColor(this.shelfPage === page
                  ? this.palette().accent : this.palette().divider)
                .onClick(() => {
                  if (this.shelfPage !== page) {
                    this.pageSwiper.changeIndex(page, true);
                  }
                })
                .animation({ duration: 220, curve: Curve.FastOutSlowIn })
            }, (page: number) => 'dot_' + page)
          }
          .justifyContent(FlexAlign.Center)
          // **大屏横屏**：与悬浮底栏同一水平区间（右对齐、按「回到书架」胶囊长度取中），
          // 指示器落在底栏正上方的中点；手机 / 竖屏维持整行居中。
          // 区间长度 = 调参区③ homePillWidth()，右留白 = 调参区② wideBarInset()
          .width(this.isWideShelf() ? this.homePillWidth() : '100%')
          .position({
            x: this.isWideShelf() ? this.rootWidth - this.wideBarInset() - this.homePillWidth() : 0,
            y: this.rootHeight - this.padBottom() - HwBar.pill - 16
          })
          .hitTestBehavior(HitTestMode.Transparent)

          // （快捷「新建 / 导入」按钮已经在 bottomBar 的胶囊**内部**，见 bottomBar()）
          // 批量操作：多选时底栏整体换成操作条（不随滚动收起，操作中必须可见）
          // 非书架页（文房 / 写作日志）：底栏整体换成**主页钮**，点了回书架（带过渡动画）
          Row() {
            if (this.shelfPage !== 1) {
              // ── 主页钮胶囊（写作日志 / 文房页）──
              // ⚠️ ImmersiveBar 是「组件 + 尾随闭包」，过渡动画挂在外层 Column 上
              Column() {
                ImmersiveBar({
                  palette: this.palette(),
                  barPaddingH: HwSpace.sm,
                  barPaddingV: 4,
                  barHeight: HwBar.pill,
                  // 底栏「回到书架」胶囊长度（调参区③）
                  barWidth: this.isWideShelf() ? this.homePillWidth() : '100%'
                }) {
                  Row({ space: HwSpace.xs }) {
                    ImmersiveIconButton({
                      buttonSize: 36,
                      buttonMaterialShadow: false,
                      palette: this.palette(),
                      buttonOnTap: () => {
                        this.pageSwiper.changeIndex(1, true);
                      }
                    }) {
                      SymbolGlyph($r('sys.symbol.house'))
                        .fontSize(18)
                        .fontColor([this.palette().textPrimary])
                    }
                    Text(L10n.t('回到书架'))
                      .fontSize(HwType.label)
                      .fontColor(this.palette().textPrimary)
                      .maxLines(1)
                    Blank()
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)
                }
              }
              .transition(TransitionEffect.OPACITY
                .animation({ duration: 220, curve: Curve.FastOutSlowIn })
                .combine(TransitionEffect.translate({ y: 16 })))
            } else if (this.multiSelect) {
              Column() {
                this.multiBar()
              }
              .transition(TransitionEffect.OPACITY
                .animation({ duration: 220, curve: Curve.FastOutSlowIn }))
            } else {
              Column() {
                this.bottomBar()
              }
              .transition(TransitionEffect.OPACITY
                .animation({ duration: 220, curve: Curve.FastOutSlowIn })
                .combine(TransitionEffect.translate({ y: 16 })))
            }
          }
          .width('100%')
          // **大屏横屏一律靠右**（用户要求：切到写作日志 / 文房页底栏保持原位不左移，
          // 主页钮胶囊与书架页底栏同一位置）；多选操作条与手机端维持原对齐
          .justifyContent(this.isWideShelf() && !this.multiSelect
            ? FlexAlign.End : FlexAlign.Start)
          // 右留白与顶栏同一参数（wideBarInset）→ 顶/底栏始终对齐
          .padding({
            left: HwSpace.lg,
            right: this.isWideShelf() ? this.wideBarInset() : HwSpace.lg,
            bottom: this.padBottom()
          })
          .position({ x: 0, y: this.rootHeight - this.padBottom() - HwBar.pill })
          // 主页钮在非书架页**常驻可见**（它就是这页的底栏）；书架页沿用原显隐逻辑
          .hitTestBehavior(this.shelfPage !== 1 || this.multiSelect || this.barsVisible
            ? HitTestMode.Transparent : HitTestMode.None)
          .opacity(this.shelfPage !== 1 || this.multiSelect || this.barsVisible ? 1 : 0)
          .translate({ y: this.shelfPage !== 1 || this.multiSelect || this.barsVisible ? 0 : 16 })
          .animation({ duration: 220, curve: Curve.FastOutSlowIn })
          .enabled(this.barsVisible || this.shelfPage !== 1)
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        
      }
      .width('100%')
      .layoutWeight(1)
      // **平板不居中**：内容靠左排在顶栏（左上角）下方（用户要求）
      .justifyContent(FlexAlign.Start)

      // 搜索结果下拉：非模态，紧跟在顶栏下面
      if (this.searchExpanded && this.searchQuery.trim().length > 0) {
        Column() {
          this.searchResultsPanel()
        }
        .width('100%')
        // **不与搜索条贴住**（用户要求）：顶栏高度之外再留一段间距
        .padding({ left: HwSpace.lg, right: HwSpace.lg, top: this.padTop() + 52 + HwSpace.sm })
        // **自身不拦截触摸**（用户反馈：输入后收起键盘，点搜索框不弹键盘、点关闭也
        // 收不起来）。这个容器全宽、上方留了顶栏高度的 padding —— 那一段本该属于
        // 顶栏的区域把搜索框 / 关闭按钮的点击全挡住了。
        // Transparent = 自己不吃事件、子级（结果行）照常可点。
        .hitTestBehavior(HitTestMode.Transparent)
        // **必须是显式 TransitionEffect（带 animation），不能用隐式对象形式**：
        // 隐式 transition 依赖调用方把状态改动包在 animateTo 里才有动画 ——
        // 点关闭按钮走 collapseSearch()（内部有 animateTo）所以有动画，
        // 而**手动把搜索框删空**走 runShelfSearch()（直接赋值、没有 animateTo），
        // 隐式 transition 于是被跳过，面板「啪」地瞬移消失（用户反馈收起动画生硬）。
        // 显式形式自带时长，两条路径都会播放动画。
        .transition(TransitionEffect.OPACITY
          .animation({ duration: 240, curve: Curve.FastOutSlowIn })
          .combine(TransitionEffect.translate({ y: -12 })))
      }

      // 格子「⋯」菜单 / 重命名：官方规范半模态面板（material/ModalSheet.ets，
      // 挂在本页根节点上，见 build 末尾的 .bindSheet）

      // ── 图片快速查看浮层（搜索结果「图片」组点开）──
      // 就地放大：全屏深色遮罩 + 居中大图 + 底部文件名 / 大小 / 分辨率；
      // 点任意处关闭（右上角另给一颗关闭钮）。返回键 / 侧滑由 onBackPress 先收掉本层。
      if (this.imgPreviewSrc.length > 0) {
        Stack({ alignContent: Alignment.TopStart }) {
          // ① 遮罩 + 大图 + 信息（整层可点：点任意位置关闭）
          Column({ space: HwSpace.md }) {
            Image(this.imgPreviewSrc)
              .width('100%')
              .layoutWeight(1)
              .objectFit(ImageFit.Contain)
              .draggable(false)
              // 图片自身不参与命中测试 → 点图也会落到这一层的 onClick 上（"点任意处关闭"）
              .hitTestBehavior(HitTestMode.None)

            Column({ space: 3 }) {
              Text(this.imgPreviewName)
                .fontSize(HwType.label)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.imgPreviewMeta)
                .fontSize(HwType.caption)
                .fontColor('#B3FFFFFF')
                .maxLines(1)
            }
            .alignItems(HorizontalAlign.Center)
          }
          .width('100%')
          .height('100%')
          .padding({
            left: HwSpace.lg,
            right: HwSpace.lg,
            top: this.padTop() + 56,
            bottom: this.padBottom() + HwSpace.xxl
          })
          .backgroundColor(withAlpha('#000000', 'E0'))
          .onClick(() => {
            this.closeImagePreview();
          })

          // ② 右上角关闭钮（在遮罩之上，点它只关闭，不穿透）
          Column() {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(16)
              .fontColor(['#FFFFFFFF'])
          }
          .width(34)
          .height(34)
          .borderRadius(17)
          .backgroundColor(withAlpha('#FFFFFF', '2E'))
          .justifyContent(FlexAlign.Center)
          .position({ x: this.rootWidth - HwSpace.lg - 34, y: this.padTop() + HwSpace.xs })
          .onClick(() => {
            this.closeImagePreview();
          })
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.FastOutSlowIn }))
      }

      // ── 文档封面的「一镜到底」飞行层：打开 / 返回的第二段 ──
      if (this.docCoverName.length > 0) {
        this.docCoverOverlay()
      }

      // ── 启动页：竹影渐变底 + 应用图标（分层图标的 foreground）+ ChéngJiān ──
      // 首帧即显，约 1.2s 后淡出移除；**纯渐变底**（不画光斑圆，用户要求），
      // 铺满全屏（含状态栏 / 手势条）
      if (this.splashOn) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 180,
              colors: this.isDark()
                ? [['#1E2230', 0.0], ['#0F1219', 1.0]]
                : [['#E7EFE6', 0.0], ['#CFDECC', 1.0]]
            })

          Column({ space: 22 }) {
            Image($r('app.media.foreground'))
              .width(132)
              .height(132)
            Text('ChéngJiān')
              .fontSize(24)
              .fontWeight(FontWeight.Medium)
              .letterSpacing(8)
              .margin({ left: 8 })
              .fontColor(this.isDark() ? '#FFECF1E9' : '#FF3D4A3C')
          }
          .alignItems(HorizontalAlign.Center)
          // 中心靠上：整体上移屏高的 8%
          .translate({ y: -this.rootHeight * 0.08 })
        }
        .width('100%')
        .height('100%')
        .opacity(this.splashOpacity)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }

    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(this.palette().pageBottom)
    // ══════════ 半模态面板：官方规范（material/ModalSheet.ets）══════════
    // 模态型 + 固定 MEDIUM 高 + 官方标题栏 / 关闭按钮 / 拖拽条。
    .bindSheet(this.shelfVisible, this.indexSheet(), modalSheetOptions({
      // **我的收藏固定半屏高**（用户要求）：其余面板（菜单/重命名/导出）保持内容自适应；
      // modalSheetOptions 里非 fitContent 即官方 MEDIUM 档（屏高 60% ≈ 半屏）
      fitContent: this.shelfSheet !== 'starred',
      title: this.sheetTitle(),
      subtitle: this.sheetSubtitle(),
      surface: this.palette().surface,
      // 竖屏（含平板竖屏）按手机形态出底部面板；平板竖屏宽度收一半
      phoneLayout: this.rootWidth <= this.rootHeight,
      screenWidth: this.rootWidth,
      onDismiss: () => {
        // dismiss 完成后才清内容标识（关闭动画期间保持原内容，避免白板）
        this.shelfVisible = false;
        this.shelfSheet = '';
      }
    }))
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const raw: Length = newValue.width;
      if (typeof raw === 'number' && raw > 0 && raw !== this.rootWidth) {
        this.rootWidth = raw;
      }
      const rawH: Length = newValue.height;
      if (typeof rawH === 'number' && rawH > 0 && rawH !== this.rootHeight) {
        this.rootHeight = rawH;
      }
    })
    }
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.navPageBuilder)
    // **主题纪元拼进 key**：系统深浅 / 应用主题一变，整棵组件树重建一次，
    // 材质、壁纸、所有派生色一次刷新到位（不用再"进别的页面"才完全刷新）。
    // key 里必须带真正变化的量（themeEpoch），否则每个节点 key 相同 = 没换 key。
    .key('index_theme_' + this.themeEpoch + '_l' + this.languageTick)
  }

  /**
   * NavDestination 分发：按 path 名创建对应页面。
   * 每个页面拿到三样东西：路由参数、导航栈（用于返回/继续下钻）、
   * 生命周期转发对象（见 NavLifecycle，让页面原有的 onPageShow 逻辑照旧生效）。
   */
  @Builder
  navPageBuilder(name: string, param: object) {
    NavDestination() {
      if (name === 'pages/Reader') {
        Reader({
          route: param as ReaderRoute,
          stack: this.pathStack,
          life: this.readerLife
        })
      } else if (name === 'pages/Editor') {
        Editor({
          route: param as ReaderRoute,
          stack: this.pathStack
        })
      } else if (name === 'pages/Settings') {
        Settings({
          stack: this.pathStack,
          life: this.settingsLife
        })
      } else if (name === 'pages/SettingsAppearance') {
        SettingsAppearance({ stack: this.pathStack })
      } else if (name === 'pages/SettingsData') {
        SettingsData({ stack: this.pathStack })
      } else if (name === 'pages/SettingsReading') {
        SettingsReading({ stack: this.pathStack })
      } else if (name === 'pages/SettingsWriting') {
        SettingsWriting({ stack: this.pathStack })
      } else if (name === 'pages/SettingsEngines') {
        SettingsEngines({ stack: this.pathStack })
      } else if (name === 'pages/SettingsExplore') {
        SettingsExplore({ stack: this.pathStack })
      } else if (name === 'pages/Changelog') {
        Changelog({ stack: this.pathStack })
      } else if (name === 'pages/SettingsHelp') {
        SettingsHelp({ stack: this.pathStack })
      } else if (name === 'pages/Sketch') {
        Sketch({ stack: this.pathStack })
      } else if (name === 'pages/Review') {
        // 复习页（1.1.0）：背书软件式复习 + 遗忘曲线 + 学习记录
        ReviewPage({
          stack: this.pathStack,
          onBackBind: (cb: () => boolean): void => {
            this.reviewBackCb = cb;
          }
        })
      } else if (name === 'pages/AiChat') {
        // AI 助手（1.2.0）：对话页；阅读 / 编辑场景的上下文经 AppStorage 信号传入
        AiChat({
          stack: this.pathStack
        })
      } else if (name === 'pages/AiSettings') {
        // AI 接口配置（API 地址 / Key / 模型 / 系统提示词 / 思考强度）
        AiSettings({
          stack: this.pathStack
        })
      } else if (name === 'pages/AiSettingsEmbedded') {
        // 设置页入口进来的 AI 设置：嵌入形态（SettingsShell 外壳，与其他设置项一致）
        AiSettings({
          stack: this.pathStack,
          embedded: true
        })
      } else if (name === 'pages/HtmlViewer') {
        // 参数安全解析：push 时未带 param 也不能整页空白
        HtmlViewer({
          stack: this.pathStack,
          docName: param !== undefined ? (param as PrintRoute).docName : '',
          content: param !== undefined ? (param as PrintRoute).content : '',
          htmlPath: param !== undefined ? (param as PrintRoute).htmlPath : ''
        })
      } else if (name === 'pages/LegalDoc') {
        LegalDoc({
          stack: this.pathStack,
          doc: (param as LegalDocRoute).doc
        })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(this.palette().pageBottom)
    // **复习页的返回拦截**：刷卡形态中侧滑 / 返回键 = 退回「学习」页签（回调由
    // ReviewPage 在 aboutToAppear 注册），返回 false 时才真正退出页面。
    .onBackPressed(() => {
      if (name !== 'pages/Review') {
        return false;
      }
      if (this.reviewBackCb !== null) {
        return this.reviewBackCb();
      }
      return false;
    })
    // **设置子页的旋转收栈**（用户要求）：竖屏打开的设置子页旋转到横屏时应回到
    // 设置主页的左右分栏，而不是被强行拉伸铺满。主页被本页盖住收不到尺寸回调，
    // 所以由**可见的本页**监听：宽屏（>760 且横屏）且栈深超过进入设置时的基线 →
    // 把被弹板块名写回 settingsInlineSection（主页 @StorageLink 接住，右栏接上）并逐个 pop。
    .onAreaChange((oldValue: Area, newValue: Area) => {
      if (!name.startsWith('pages/Settings')) {
        return;
      }
      const w: Length = newValue.width;
      const h: Length = newValue.height;
      if (typeof w !== 'number' || typeof h !== 'number' || !(w > 760 && w > h)) {
        return;
      }
      const depthBase: number = AppStorage.get<number>('settingsStackDepth') ?? 0;
      if (this.pathStack !== null && this.pathStack.size() > depthBase) {
        while (this.pathStack !== null && this.pathStack.size() > depthBase) {
          const names: string[] = this.pathStack.getAllPathName();
          if (names.length > 0) {
            AppStorage.setOrCreate('settingsInlineSection', names[names.length - 1]);
          }
          this.pathStack.pop();
        }
      }
    })
    // **系统返回手势拦截（编辑页）**：拦截侧滑 / 返回键，把决定权交给 Editor
    // （通过 editorGoBackTick 信号）：它自己持有最准确的未保存状态 ——
    // 没有改动就直接返回，有改动才弹「保存 / 不保存」。
    //
    // ⚠️ 这里**不能**再用 AppStorage 里的 editorDirty 做判据：隐藏页的
    // `@StorageProp` 在真机上不保证随 Editor 的写入回刷，于是"已经点过保存、
    // 退出时仍被拦下弹窗"（用户反馈）。判据下沉到状态真正的主人身上才可靠。
    .onBackPressed(() => {
      if (name === 'pages/Editor') {
        AppStorage.setOrCreate('editorGoBackTick', Date.now());
        return true;
      }
      // **阅读页叠加层**：图表 / 图片放大浮层打开时，侧滑 / 返回键先关闭浮层
      //（此前会直接退回书架，用户反馈"回到阅读页面"应为"关闭浮层"）
      if (name === 'pages/Reader' && this.readerOverlayOpen) {
        AppStorage.setOrCreate('readerOverlayCloseTick', Date.now());
        return true;
      }
      return false;
    })
    .onShown(() => {
      if (name === 'pages/Reader') {
        this.readerLife.onShow();
      } else if (name === 'pages/Settings') {
        this.settingsLife.onShow();
      } else if (name === 'pages/Editor') {
        // **编辑页显示信号**：从手写页返回时触发编辑页检查待插入的手写图
        //（NavDestination 的 onShown 不会自动到 Editor，这里发 tick 转发）
        AppStorage.setOrCreate('editorShownTick', Date.now());
      }
    })
    .onHidden(() => {
      if (name === 'pages/Reader') {
        this.readerLife.onHide();
      }
    })
    // **编辑页离开（保存后返回）必须刷新书架**：
    // 本页是 UIAbility 首页，Navigation 推入 / 弹出子页**不会**触发 onPageShow，
    // 所以以前新建文档保存后书架不显示、要退出应用重开才出现。
    // onWillDisappear 在子页即将销毁（弹出）时触发；延迟一点等返回转场结束，
    // 避免列表重排打断转场动画。
    .onWillDisappear(() => {
      // **Reader 也要刷新**：阅读页退出时已写回阅读进度（封面进度条 / 百分比 / 续读横幅
      // 都读这份数据），不重读列表的话要重启应用才更新（用户实测）。
      // **设置页同样要刷新**：数据管理里"从书架中移除 / 恢复内置""导入备份"等
      // 都会改书架内容 —— 之前只认编辑页与阅读页，导致恢复内置后回到书架看不到，
      // 必须重启应用才出现（用户反馈）。设置类页面统一按前缀匹配。
      const fromSettings: boolean = name === 'pages/Settings'
        || name.indexOf('pages/Settings') === 0;
      if (name === 'pages/Editor' || name === 'pages/Reader' || fromSettings) {
        // 从「全部待办」条目进来的：退出后**重新打开该面板**（用户要求"退出文件时
        // 返回全部待办页面"）。标志由阅读页隐藏时写入，这里读到即清，避免下次误开。
        const backTasks: boolean = name === 'pages/Reader'
          && (AppStorage.get<boolean>('readerExitToTasks') ?? false);
        if (name === 'pages/Reader' && backTasks) {
          AppStorage.setOrCreate('readerExitToTasks', false);
        }
        setTimeout(() => {
          this.refresh();
          if (backTasks) {
            this.runTaskBoard();
          }
        }, 320);
      }
    })
  }

  /** 空书架时第二格的占位（避免 GridItem 空内容）。 */
  private emptyMeta(): DocMeta {
    const meta: DocMeta = {
      name: L10n.t('Markdown 语法教程'),
      fileName: 'README.md',
      builtin: true,
      size: 0,
      mtime: 0,
      charCount: 0,
      wordCount: 0,
      headingCount: 0,
      progressIndex: 0,
      progressRatio: 0,
      lastOpen: 0
    };
    return meta;
  }

  @Builder
  backdrop() {
    // 背景优先级：手选壁纸 → **函数绘制壁纸** → 自定义背景色 → 主题渐变
    if (this.wallpaperPathEffective().length > 0) {
      Image(WallpaperStore.imageSourceOf(this.wallpaperPathEffective()))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .blur(this.wallpaperBlur)

      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.isDark()))
    } else if (this.genWallId.length > 0) {
      // 程序化壁纸（无位图）：见 theme/GenWallpaper.ets
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

    // 光斑两团：**只在没有图片壁纸时绘制**（导入壁纸后不再叠两个圆，用户要求）
    if (this.wallpaperPathEffective().length === 0) {
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
        .translate({ x: -100, y: -80 })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)

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
        .translate({ x: 90, y: 100 })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    }
  }

  @StorageLink('readerCustomBgLight') customBgLight: string = '';
  @StorageLink('readerCustomBgDark') customBgDark: string = '';

  /**
   * 自定义阅读背景色；**没选时用固定默认色（与阅读/编辑页同一套，不再回退主题渐变）**。
   * 「阅读背景」完全独立于主题（用户要求）—— 书架背景在打开文档的一镜到底转场中
   * 会短暂露出，之前回退主题渐变时用户实测转场瞬间闪粉紫（主题染色漂移），现在固定不变。
   */
  private pageBackground(): string {
    if (this.isDark()) {
      return this.customBgDark.length > 0 ? this.customBgDark : READER_BG_DEFAULT_DARK;
    }
    return this.customBgLight.length > 0 ? this.customBgLight : READER_BG_DEFAULT_LIGHT;
  }
}

/**
 * 封面阅读进度：底部居中的细进度条 + 右下角的百分比胶囊。
 *
 * ⚠️ 为什么做成**独立组件**而不是 @Builder：
 * 进度值必须进格子 ForEach 的指纹（否则进度变化根本不刷新），而指纹一变格子就会
 * **整格重建** —— 新建节点不会播放属性动画（初始即终值），用户实测"动画太快、
 * 和直接切换没区别"。独立组件在 `aboutToAppear` 里先取**上次显示的比例**
 * （静态缓存跨重建保留），延迟一帧再 animateTo 到新值 →
 * 进度条从旧值平滑增长、百分比数字随动画逐帧变化。
 */
@Component
export struct CoverProgressBar {
  /** 目标比例（0~1） */
  @Prop target: number = 0;
  /** 文档名：作为跨重建记住"上次显示比例"的键 */
  @Prop docName: string = '';
  /** 调色板：必须由父组件传入（在 Index 内，主题变化会随父重建一起刷新） */
  @Require @Prop palette: ReaderPalette;
  /** 上次显示的比例（静态缓存：格子重建后仍能接着上次的值继续长） */
  private static lastRatio: Map<string, number> = new Map<string, number>();
  /** 当前显示的比例（动画驱动值，数字与条宽都由它算） */
  @State shown: number = 0;

  aboutToAppear(): void {
    const prev: number = CoverProgressBar.lastRatio.get(this.docName) ?? 0;
    CoverProgressBar.lastRatio.set(this.docName, this.target);
    this.shown = prev;
    // 延迟一帧再起动画：挂载当帧直接改值不会产生补间
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: 560, curve: Curve.EaseInOut }, () => {
        this.shown = this.target;
      });
    }, 16);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 底部居中的细进度条（占封面 72%，两端对称留白）
      Stack({ alignContent: Alignment.Start }) {
        Column()
          .width('100%')
          .height(3)
          .borderRadius(1.5)
          .backgroundColor(this.palette.divider)
        Column()
          .width((this.shown * 100) + '%')
          .height(3)
          .borderRadius(1.5)
          .backgroundColor(this.palette.accent)
      }
      .width('72%')
      .margin({ bottom: 6 })

      // 右下角百分比胶囊（沉浸光感，位于进度条上方避免重叠）
      Row() {
        ImmersiveChip({
          palette: this.palette,
          chipPaddingH: 5,
          chipPaddingV: 1,
          chipFontSize: 10,
          chipActive: true,
          chipLabel: Math.round(this.shown * 100) + '%',
          chipOnTap: () => {
          }
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .padding({ right: 6, bottom: 14 })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 书架「⋯」面板里的**文档编码卡**。
 *
 * ⚠️ 为什么单独做成组件：原来靠 `sheetEpoch++` 强制重建面板来刷新选中态，而重建会把
 * 半模态面板的滚动位置一起重置 —— 用户实测「一改编码，面板就跳回顶部」。
 * 这里用 `@StorageLink('cellMenuEncoding')` 让卡片**自己订阅**当前档位：
 * 切换只写 AppStorage 就能自动重绘，面板本身不重建、滚动位置保持不动。
 */
@Component
export struct EncodingChoiceCard {
  /** 目标文档名（写入 `docEncoding_<名字>`，阅读页读同一份） */
  @Prop docName: string = '';
  /** 调色板（由宿主传入） */
  @Require @Prop palette: ReaderPalette;
  /** 当前档位（固定键；打开面板时由宿主写入当前文档的编码） */
  @StorageLink('cellMenuEncoding') current: string = 'auto';

  private values(): string[] {
    const out: string[] = [];
    out.push('auto');
    out.push('utf-8');
    out.push('gbk');
    out.push('gb18030');
    out.push('big5');
    out.push('iso-8859-1');
    return out;
  }

  private labelOf(v: string): string {
    if (v === 'utf-8') {
      return 'UTF-8';
    }
    if (v === 'gbk') {
      return 'GBK';
    }
    if (v === 'gb18030') {
      return 'GB18030';
    }
    if (v === 'big5') {
      return 'Big5';
    }
    if (v === 'iso-8859-1') {
      return 'Latin-1';
    }
    return '自动识别';
  }

  build() {
    ImmersiveCard({
      cardRadius: HwRadius.card,
      cardPadding: HwSpace.lg,
      palette: this.palette
    }) {
      Column({ space: HwSpace.xs }) {
        Text(L10n.t('文档编码'))
          .fontSize(HwType.label + 1)
          .fontColor(this.palette.textPrimary)
          .width('100%')
        Text(L10n.t('非 UTF-8 的文档（例如 GBK 存出来的 txt）按 UTF-8 硬解会整篇乱码；') + '自动识别不准时在这里手动指定。')
          .fontSize(HwType.caption)
          .fontColor(this.palette.textTertiary)
          .lineHeight(HwType.caption * 1.7)
          .width('100%')

        ForEach(this.values(), (enc: string) => {
          Row({ space: HwSpace.sm }) {
            Text(this.labelOf(enc))
              .fontSize(HwType.label)
              .fontColor(this.current === enc
                ? this.palette.accent : this.palette.textPrimary)
              .layoutWeight(1)
              .textAlign(TextAlign.Start)
            if (this.current === enc) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(15)
                .fontColor([this.palette.accent])
            }
          }
          .width('100%')
          .padding({ left: HwSpace.sm, right: HwSpace.sm, top: HwSpace.xs, bottom: HwSpace.xs })
          .borderRadius(HwRadius.inner)
          .backgroundColor(this.current === enc
            ? withAlpha(this.palette.accent, '1F') : '#00000000')
          .onClick(() => {
            // @StorageLink 双向：赋值即写 AppStorage → 卡片自身重绘（**面板不重建**）
            this.current = enc;
            AppStorage.setOrCreate('docEncoding_' + this.docName, enc);
            this.getUIContext().getPromptAction().showToast({
              message: L10n.t('文档编码：') + this.labelOf(enc)
            });
          })
        }, (enc: string) => 'enc_' + enc)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}
