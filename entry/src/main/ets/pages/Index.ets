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
import {
  FOLDER_SPRING,
  HwBar,
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  paletteFor
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
import { modalSheetOptions } from '../material/ModalSheet';
import { ExportOptionsPanel } from '../components/ExportOptionsPanel';
import { applySystemBarTheme, applyAppColorMode, syncSystemDarkFromContext,
  markThemeApplied, themeChangedSince, startThemeWatchdog, stopThemeWatchdog } from '../service/AppWindow';
import { WallpaperStore } from '../service/WallpaperStore';
import { DocMeta, DocSearchHit, DocStore, ReaderRoute, ShelfFolder } from '../service/DocStore';
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
import { SettingsExplore } from './SettingsExplore';
import { Changelog } from './Changelog';
import { LegalDoc, LegalDocRoute } from './LegalDoc';

/** 搜索结果下拉面板最多显示的条数（更多提示用底部说明） */
const SEARCH_PANEL_MAX: number = 20;

/** 书架底栏胶囊内「新建 / 导入」按钮的直径（vp），不能超过胶囊内高（52 - 8 = 44） */
const NEW_BTN_SIZE: number = 36;

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

  @State docs: DocMeta[] = [];
  @State folders: ShelfFolder[] = [];
  /** 启动页：首帧即显，1.2s 后淡出移除（竹影底 + foreground 图标 + ChengJian） */
  @State splashOn: boolean = true;
  @State splashOpacity: number = 1;
  /**
   * 网格的渲染顺序（文件夹 + 松散文档混排，见 DocStore.shelfOrder）。
   * 由 refresh() 统一构建——build/ForEach 期间只读，不写。
   */
  @State items: ShelfItem[] = [];
  @State userDocCount: number = 0;
  @State totalWords: number = 0;
  @State totalChars: number = 0;
  /** 原地展开的搜索框 */
  @State searchExpanded: boolean = false;
  @State searchQuery: string = '';
  @State searchHits: DocSearchHit[] = [];

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
  /** 函数绘制壁纸的 id（空 = 不用）；见 theme/GenWallpaper.ets */
  @StorageProp('wallpaperGenId') genWallId: string = '';
  /** 导航栈：书架是首页，阅读 / 设置 / 编辑都压在这条栈上 */
  private pathStack: NavPathStack = new NavPathStack();
  /** 页面生命周期转发（见 NavLifecycle）：NavDestination 的 onShown/onHidden 会调它 */
  private readerLife: NavLifecycle = new NavLifecycle();
  private settingsLife: NavLifecycle = new NavLifecycle();
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

  // ── 顶栏 / 底栏收起与展开：累计位移阈值（与阅读页同一套） ──

  private toggleBars(show: boolean): void {
    if (this.barsVisible === show) {
      return;
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.barsVisible = show;
    });
  }

  private onScrollFrame(offset: number): void {
    if (this.searchExpanded || this.shelfSheet !== '') {
      this.toggleBars(true);
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
    });
  }

  private runShelfSearch(text: string): void {
    this.searchQuery = text;
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      this.searchHits = DocStore.searchAll(ctx, text);
    } catch (err) {
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
        this.toast(readOnly ? '已切为只读：编辑入口已锁' : '已切为可写：可以编辑了');
      } else {
        this.toast('切换失败：文档不存在');
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
      this.toast(color.length === 0 ? '已恢复默认配色' : '封面颜色已更新');
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
          this.toast('图片导入失败：格式不支持或超过 20MB');
          return;
        }
        if (DocStore.setCoverImage(ctx, kind, target, rel)) {
          this.refresh();
          this.toast('封面图已更新');
        }
      }).catch((err: BusinessError) => {
        this.toast('选择图片失败：' + err.message);
      });
    } catch (err) {
      this.toast('无法打开图片选择器');
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
      this.toast('已移除封面图');
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
      this.toast(show ? '封面显示名称' : '封面只留图形、隐藏名称');
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

  /** 文档自定义封面底色（空串 = 用名字哈希的默认配色）。 */
  private coverColorOf(meta: DocMeta): string {
    const c: string | undefined = meta.coverColor;
    return c === undefined ? '' : c;
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
    this.closeCellMenu();
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
    // 挂载包在 animateTo 里：其他格子的模糊 / 透明度**渐入**（不再瞬间变糊）。
    // 先挂载（高度 0），下一拍再撑高——同一拍里改两个状态就没有「推开下面图标」的过程
    this.getUIContext().animateTo({ curve: FOLDER_SPRING }, () => {
      this.openFolderName = name;
      // 与 openFolderName 同一拍挂载：下面的格子一次动画被推开，不会二次跳
      this.folderPanelMounted = true;
    });
    this.folderPanelOpen = false;
    setTimeout(() => {
      this.getUIContext().animateTo({ curve: FOLDER_SPRING }, () => {
        this.folderPanelOpen = true;
      });
      // 撑开的同时确保面板可见：**ScrollAlign.AUTO 只做最小滚动**
      // （之前用 CENTER 强制居中，会把列表猛然上滚、最近阅读整段被顶出屏幕——用户反馈）。
      // 目标已在可视区时 AUTO 不滚动，被底栏挡住时才滚一小段。
      setTimeout(() => {
        const idx: number = this.folderPanelGridIndex();
        if (idx >= 0) {
          try {
            this.gridScroller.scrollToIndex(idx, true, ScrollAlign.AUTO);
          } catch (err) {
            // 忽略：滚动失败不影响展开
          }
        }
        // 第一跳之后按实测位置补一次：AUTO 只保证面板顶边可见，
        // 面板底部仍可能压在悬浮胶囊后面 → 这里精确补齐差额。
        // 等 220ms 让展开动画跑完、onAreaChange 报出最终矩形。
        setTimeout(() => {
          this.correctPanelScroll();
        }, 220);
      }, 220);
    }, 40);
  }

  private closeFolderPanel(): void {
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
    return this.cellDimmed() ? 6 : 0;
  }

  /** 树形视图的行内展开也要有动画：状态变更包在弹簧 animateTo 里。 */
  private toggleFolderExpandAnimated(name: string): void {
    this.getUIContext().animateTo({ curve: FOLDER_SPRING }, () => {
      this.toggleFolderExpand(name);
    });
  }

  /** 展开面板的窗口矩形（窗口坐标 vp）。用来校正"滚到刚好看得见面板"。 */
  private panelWinTop: number = 0;
  private panelWinBottom: number = 0;

  /**
   * 面板位置校正（打开文件夹时的第二步滚动）。
   *
   * 为什么需要：`scrollToIndex(..., ScrollAlign.AUTO)` 只保证**面板顶边**进入视口，
   * 面板往往还有一两百 vp 压在底部悬浮胶囊后面 —— 用户反馈"自动滑的幅度太小、
   * 还得手动补一段"。这里按**实测**的面板窗口矩形算还差多少，
   * 再用 scrollBy 精确补上（只往上推，不会来回抖）。
   */
  private correctPanelScroll(): void {
    if (this.panelWinBottom <= 0 || this.panelWinTop <= 0) {
      return;
    }
    // 底部悬浮胶囊的上沿 = 可用高 - 胶囊高 - 底部避让 - 一点呼吸位
    const barTop: number = this.rootHeight - this.padBottom() - HwBar.pill - HwSpace.md;
    const overflow: number = this.panelWinBottom - barTop;
    if (overflow <= 1) {
      return;
    }
    try {
      // 正数 = 内容上移，把面板底部推到胶囊上方。
      // Grid/List 的 Scroller.scrollBy 在本 SDK 只吃两个参数（dx, dy），不要传动画开关。
      this.gridScroller.scrollBy(0, overflow);
    } catch (err) {
      // 校正失败不影响面板本身（它已经展开了）
    }
  }

  onPageShow(): void {
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
    // 返程转场期间**不刷新列表**：refresh 会让 Grid 重排，共享元素（封面）动画
    // 会因目标节点被替换而闪断。等转场结束（350ms + 余量）后再刷新数据。
    setTimeout(() => {
      this.refresh();
    }, 420);
  }

  /** 页面隐藏：停掉深浅探测器（不在本页时没必要问系统）。 */
  onPageHide(): void {
    stopThemeWatchdog();
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
    });
  }

  // ══════════════════════ 数据 ══════════════════════

  private ctx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  private refresh(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      DocStore.init(ctx);
      const list: DocMeta[] = DocStore.list(ctx);
      this.docs = list;
      this.folders = DocStore.folderList();
      // **展开状态要跟着文件夹一起收拾**：解散 / 重命名 / 数据变化后，
      // 若 openFolderName 还指着不存在的文件夹，其他格子会一直保持"退后 + 模糊"
      // （用户看到的"解散后偶尔整屏发糊"就是这个残留状态）。
      if (this.openFolderName.length > 0 && this.folderByName(this.openFolderName) === null) {
        this.openFolderName = '';
        this.folderPanelOpen = false;
        // 文件夹没了，0 高占位的面板也一起摘掉（留着会占一行网格空间）
        this.folderPanelMounted = false;
      }
      // 统一排序 → 网格项（文件夹与文档混排，拖拽才能互相换位）
      this.items = this.buildItems(ctx, list);
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

  /** 某文件夹内的文档元信息列表。 */
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
    if (this.themeMode === ReaderThemeMode.Dark) {
      return true;
    }
    if (this.themeMode === ReaderThemeMode.Light) {
      return false;
    }
    return this.systemDark;
  }

  private palette(): ReaderPalette {
    // 外观刷新计数：主题色 / 灰字 / 沾色是在 paletteFor 里读 AppStorage 的
    // （纯函数读不登记依赖），这里读一下计数，派生色改完当帧就能重算
    const tick: number = this.appearanceTick;
    return paletteFor(this.themeMode, this.systemDark);
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
      this.toast('该文档是只读的，先切成「可写」再编辑');
      return;
    }
    const route: ReaderRoute = { name: name };
    this.pushPage('pages/Editor', route);
  }

  private createDoc(): void {
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
      this.toast('页面跳转失败');
    }
  }

  private importDoc(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      const docPicker = new picker.DocumentViewPicker(ctx);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.md', '.markdown', '.txt'];
      docPicker.select(options).then((uris: string[]) => {
        if (uris.length === 0) {
          return;
        }
        const meta: DocMeta | null = DocStore.importFromUri(ctx, uris[0]);
        if (meta === null) {
          this.toast('导入失败：文件无法读取');
          return;
        }
        this.refresh();
        this.toast('已导入《' + meta.name + '》');
      }).catch((err: BusinessError) => {
        this.toast('选择文件失败：' + err.message);
      });
    } catch (err) {
      this.toast('无法打开文件选择器');
    }
  }

  private doRename(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const target: string = this.renameText.trim();
    if (target.length === 0) {
      this.toast('名称不能为空');
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
        this.toast('文件夹已重命名');
      } else {
        this.toast('重命名失败：名称非法或已存在');
      }
      return;
    }
    if (DocStore.rename(ctx, this.renameFrom, target)) {
      this.closeRename();
      this.refresh();
      this.toast('已重命名为「' + target + '」');
    } else {
      this.toast('重命名失败：名称非法或已存在同名文档');
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
        title: '移除内置教程',
        message: '将从书架移除《' + name + '》。正文不会被删除，随时可在「设置 → 数据管理」恢复。',
        buttons: [
          { text: '取消', color: this.palette().textSecondary },
          { text: '移除', color: '#FFD93B3B' }
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
      title: '删除文档',
      message: '将删除《' + name + '》，此操作不可撤销。',
      buttons: [
        { text: '取消', color: this.palette().textSecondary },
        { text: '删除', color: '#FFD93B3B' }
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
        this.toast('删除失败');
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
  private handleDropOnDoc(targetName: string): void {
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
  private isWideShelf(): boolean {
    return this.rootWidth > 760 && this.rootWidth > this.rootHeight;
  }

  // ══════════════════════ 底栏（统计 + 快捷新建 / 导入） ══════════════════════
  //
  // 用户要求：快捷「新建 / 导入」按钮**放在底部那颗悬浮胶囊里面**（不是旁边另挂一颗），
  // 走沉浸光感材质（材质由 ImmersiveBar 统一承载），点击新建文档、长按导入文档。
  // 按钮本体与统计文字同在胶囊内的那一行里，见 bottomBar()。

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
      // **平板放屏幕右上角**：宽屏胶囊只装按钮（标题固定在左上角，不进胶囊）；
      // 点搜索展开时胶囊加宽到 420 装下搜索框，手机仍整行
      barWidth: this.isWideShelf() ? (this.searchExpanded ? 420 : 190) : '100%'
    }) {
    Row({ space: HwSpace.xs }) {
      if (this.searchExpanded) {
        // 展开态：搜索框占满整行。它与收起态的搜索按钮共享 'shelfSearch'，
        // 所以搜索框是「从那颗按钮长出来的」（两者 if/else 互斥，满足同 id 不共存约束）。
        Row({ space: HwSpace.xs }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(17)
            .fontColor([this.palette().textTertiary])
          TextInput({ text: this.searchQuery, placeholder: '在全部文档中搜索…' })
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
        // **不再铺 quoteBg**：默认调色板的 quoteBg 是 28% 透明的主题蓝，
        // 搜索框整圈发蓝（用户要求去掉）。外层 ImmersiveBar 胶囊本身就是
        // 沉浸光感底，这里保持全透明即可。
        .backgroundColor('#00000000')
        .geometryTransition('shelfSearch', { follow: true })
      } else {
        // **平板：标题不进胶囊**（固定在屏幕左上角，见外层），胶囊只装按钮
        if (!this.isWideShelf()) {
          Column({ space: 1 }) {
            Text('全部文档')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.palette().textPrimary)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        } else {
          Blank()
            .layoutWeight(1)
        }

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

      // 搜索一镜到底的**源**：与展开态搜索框共享 'shelfSearch'。
      // 自定义组件 + 尾随闭包不能链式调属性，所以外面包一层 Stack 再挂 geometryTransition。
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
      .geometryTransition('shelfSearch', { follow: true })

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
    }
    // 注意：ImmersiveBar 是「自定义组件 + 尾随闭包」，不能再链式调属性；
    // 宽度已经用 barWidth 参数传入（'100%'）。
  }

  /** 搜索结果下拉：非模态，盖在网格上方，点结果直达。 */
  @Builder
  searchResultsPanel() {
    Column({ space: HwSpace.xs }) {
      if (this.searchQuery.trim().length === 0) {
        Text('输入关键词，在全部文档正文里查找')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .width('100%')
          .padding({ left: HwSpace.sm, top: HwSpace.xxs, bottom: HwSpace.xxs })
      } else if (this.searchHits.length === 0) {
        Text('没有匹配的内容')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .width('100%')
          .padding({ left: HwSpace.sm, top: HwSpace.xxs, bottom: HwSpace.xxs })
      } else {
        ForEach(this.searchHits, (hit: DocSearchHit, index: number) => {
          Column({ space: 2 }) {
            Row({ space: HwSpace.xs }) {
              Text(hit.name)
                .fontSize(HwType.label)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.palette().textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (hit.builtin) {
                Text('内置')
                  .fontSize(HwType.caption - 1)
                  .fontColor(this.palette().textTertiary)
              }
              Text(hit.count + ' 处')
                .fontSize(HwType.caption - 1)
                .fontColor(this.palette().accent)
            }
            .width('100%')

            Text(hit.snippet)
              .fontSize(HwType.caption)
              .fontColor(this.palette().textSecondary)
              .lineHeight(HwType.caption * 1.5)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .width('100%')
          .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 6, bottom: 6 })
          .borderRadius(HwRadius.inner)
          .onClick(() => {
            this.openSearchHit(hit);
          })
        }, (hit: DocSearchHit, index: number) => 'hit' + index + '_' + hit.name)

        if (this.searchHits.length > SEARCH_PANEL_MAX) {
          Text('共 ' + this.searchHits.length + ' 篇命中，仅显示前 ' + SEARCH_PANEL_MAX + ' 篇')
            .fontSize(HwType.caption - 1)
            .fontColor(this.palette().textTertiary)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(4)
        }
      }
    }
    .width('100%')
    .constraintSize({ maxHeight: 260 })
    .borderRadius(HwRadius.card)
    .backgroundColor(this.palette().surface)
    .backgroundBlurStyle(BlurStyle.Thin)
    .border({ width: 0.8, color: this.palette().surfaceBorder })
    .clip(true)
    .alignItems(HorizontalAlign.Start)
  }

  // ══════════════════════ 封面网格 ══════════════════════

  /**
   * 封面右下角的**圆形百分比徽标**（替代原来的细长进度条）。
   * 圆环 = 已读比例，中心是百分比数字。
   */
  @Builder
  coverProgressBadge(ratio: number) {
    Stack({ alignContent: Alignment.Center }) {
      Progress({ value: Math.round(ratio * 100), total: 100, type: ProgressType.Ring })
        .width(30)
        .height(30)
        .color(this.palette().accent)
        .backgroundColor(this.palette().surface)
        .style({ strokeWidth: 3 })
      Text(Math.round(ratio * 100) + '%')
        .fontSize(9)
        .fontColor(this.palette().accent)
    }
    .width(30)
    .height(30)
    .margin({ right: 6, bottom: 6 })
    .hitTestBehavior(HitTestMode.None)
  }

  /** 封面 + 标题 + 日期的格子本体（拖拽属性在外层 Column 上，内置教程与自建文档同款）。 */
  @Builder
  coverContent(meta: DocMeta, inPanel: boolean) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Column() {
          DocCover({
            title: meta.name,
            builtin: meta.builtin,
            coverTop: coverColorsOf(meta.name, meta.builtin).top,
            coverBottom: coverColorsOf(meta.name, meta.builtin).bottom,
            coverInk: coverColorsOf(meta.name, meta.builtin).ink,
            edgeColor: this.palette().divider,
            // 用户自定义：底色 / 封面图 / 是否显示名称
            coverColor: this.coverColorOf(meta),
            coverImage: this.coverImageSrc(meta.coverImage),
            hideName: meta.hideCoverName === true
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

        Column() {
          ImmersiveIconButton({
            buttonSize: 26,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              if (!inPanel && this.openFolderName.length > 0) {
                return;
              }
              this.openCellMenu('doc', meta.name, meta.builtin);
            }
          }) {
            SymbolGlyph($r('sys.symbol.ellipsis_circle'))
              .fontSize(13)
              .fontColor([this.palette().textSecondary])
          }
        }
        .margin({ top: 4, right: 4 })

        // 阅读进度：**封面右下角的圆形百分比徽标**（细长进度条已删除）
        if (!meta.builtin && meta.progressRatio > 0.001) {
          Stack({ alignContent: Alignment.BottomEnd }) {
            this.coverProgressBadge(meta.progressRatio)
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
              Text('合并为文件夹')
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
        Text(meta.name)
          .fontSize(HwType.label + 1)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.palette().textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
      }

      Text(meta.builtin ? '内置教程' : DocStore.formatTime(meta.mtime))
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
    }
    .width('100%')
    // 系统拖拽：长按起拖；释放到别的文档 / 文件夹上触发 onDrop。
    //  · 只注册 onDragStart（不加 draggable(true)）→ 长按起拖，不与点击 / 网格滚动抢手势
    //  · onDrop 与 onDragStart 同节点 → 释放一定能命中
    .onDragStart((event: DragEvent) => {
      this.draggingName = meta.name;
      const info: DragItemInfo = { extraInfo: meta.name };
      return info;
    })
    // 拖到本格上方 → 轻微缩小，给"可以放这里"的反馈（用户要求）
    .onDragEnter((event: DragEvent) => {
      this.hoverDropAt = meta.name;
    })
    .onDragLeave((event: DragEvent) => {
      if (this.hoverDropAt === meta.name) {
        this.hoverDropAt = '';
      }
    })
    .onDrop((event: DragEvent) => {
      this.handleDropOnDoc(meta.name);
    })
  }

  /** 文件夹格：迷你封面预览（或自定义封面图）+ 名称 + 数量；点开浮层，⋯ 菜单，可接收拖入。 */
  @Builder
  folderCell(folder: ShelfFolder) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
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
              Column({ space: 4 }) {
                Row({ space: 4 }) {
                  ForEach(this.folderPreviewColors(folder).slice(0, 2), (c: string, i: number) => {
                    Column()
                      .layoutWeight(1)
                      .aspectRatio(0.72)
                      .borderRadius(4)
                      .linearGradient({
                        angle: 200,
                        colors: [[c, 0.0], [c, 1.0]]
                      })
                  }, (c: string, i: number) => folder.name + 'a' + i + c)
                }
                .width('100%')

                Row({ space: 4 }) {
                  ForEach(this.folderPreviewColors(folder).slice(2, 4), (c: string, i: number) => {
                    Column()
                      .layoutWeight(1)
                      .aspectRatio(0.72)
                      .borderRadius(4)
                      .linearGradient({
                        angle: 200,
                        colors: [[c, 0.0], [c, 1.0]]
                      })
                  }, (c: string, i: number) => folder.name + 'b' + i + c)
                }
                .width('100%')
              }
              .width('100%')
            }
            // （原先左上角那颗文件夹小图标按用户要求已删除）
          }
          .width('100%')
          .aspectRatio(0.72)
          .padding(this.folderHasImage(folder) ? 0 : 7)
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
            buttonSize: 26,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              this.openCellMenu('folder', folder.name, false);
            }
          }) {
            SymbolGlyph($r('sys.symbol.ellipsis_circle'))
              .fontSize(13)
              .fontColor([this.palette().textSecondary])
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

      Text(folder.docs.length + ' 篇')
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
    const rows: number = Math.ceil(folder.docs.length / cols);
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
    const order: string[] = DocStore.shelfOrder(ctx);
    for (let k = 0; k < order.length; k++) {
      const entry: string = order[k];
      if (entry.startsWith(DocStore.ORDER_FOLDER)) {
        const name: string = entry.substring(DocStore.ORDER_FOLDER.length);
        const folder: ShelfFolder | null = this.folderByName(name);
        if (folder !== null) {
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
        if (meta !== null) {
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
      const n: number = item.folder !== null ? item.folder.docs.length : 0;
      return 'F_' + item.name + '_' + n + '_' + tag + '_t' + this.themeEpoch;
    }
    const mtime: number = item.meta !== null ? item.meta.mtime : 0;
    return 'D_' + item.name + '_' + mtime + '_' + tag + '_t' + this.themeEpoch;
  }

  /** 封面外观指纹（色 / 图 / 名称开关），参与 key。 */
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
      return c + '|' + i + '|' + (f.hideCoverName === true ? '1' : '0');
    }
    const m: DocMeta | null = item.meta;
    if (m === null) {
      return '';
    }
    const rawC2: string | undefined = m.coverColor;
    const rawI2: string | undefined = m.coverImage;
    const c2: string = rawC2 === undefined ? '' : rawC2;
    const i2: string = rawI2 === undefined ? '' : rawI2;
    return c2 + '|' + i2 + '|' + (m.hideCoverName === true ? '1' : '0');
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

  private openFolderColumn(): number {
    const slot: number = this.openFolderIndex();
    return slot < 0 ? 0 : slot % this.shelfColumns();
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

  /**
   * 展开面板在**网格里的绝对下标**（GridItem 序号，含通栏项）。
   *
   * 真实渲染顺序（见 build 里的 Grid）：
   *   0 继续阅读横幅 · 1 新建卡 · 2..n **looseBuiltinDocs()**（不在文件夹里的内置文档）
   *   · 之后是 items（每个 item 后面可能跟一个面板）、空书架提示、文末提示。
   *
   * ⚠️ 必须用 **looseBuiltinDocs().length**，不能用 builtinDocs().length：
   * 内置教程首次启动就被收进「澄笺」文件夹，网格里**一个都不渲染**（报数 2），
   * 于是算出的下标偏大 2 → scrollToIndex 冲过面板，用户看到「打开文件夹后屏幕不滑动」。
   */
  private folderPanelGridIndex(): number {
    const after: number = this.panelAfterIndex();
    if (after < 0) {
      return -1;
    }
    // 空书架提示（userDocCount === 0）通栏插在 items 之前，也要算进去
    const emptyHint: number = this.userDocCount === 0 ? 1 : 0;
    return 2 + this.looseBuiltinDocs().length + emptyHint + after + 1;
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
          SymbolGlyph($r('sys.symbol.chevron_up'))
            .fontSize(15)
            .fontColor([this.palette().textSecondary])
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
          }, (meta: DocMeta) => 'fp_' + meta.name)
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
    const ctx = this.ctx();
    for (let k = 0; k < folder.docs.length && k < 4; k++) {
      let name: string = folder.docs[k];
      // 默认取文档名哈希色；**用户自定义过封面色则优先**（与文档封面观感一致）
      let custom: string = '';
      if (ctx !== null) {
        const meta: DocMeta | undefined = DocStore.find(ctx, folder.docs[k]);
        if (meta !== undefined) {
          name = meta.name;
          const c: string | undefined = meta.coverColor;
          if (c !== undefined && c.length > 0) {
            custom = c;
          }
        }
      }
      out.push(custom.length > 0 ? custom : coverColorsOf(name, false).bottom);
    }
    while (out.length < 4) {
      out.push(this.palette().divider);
    }
    return out;
  }

  /** 沉浸光感开关（AppStorage 强制开启，见 EntryAbility） */
  @StorageProp('immersiveLightEnabled') immersiveOn: boolean = true;
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
            Text('新建文档')
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
        .border({ width: 1.2, color: this.palette().divider })
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

      Text('或长按导入')
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
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
  }

  /** 继续阅读横幅（网格首行通栏） */
  @Builder
  resumeBanner() {
    if (this.resumeName.length > 0) {
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
              Text('继续阅读')
                .fontSize(HwType.caption)
                .fontColor(this.palette().accent)
              Text('已读 ' + Math.round(this.resumeRatio * 100) + '% · '
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

          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(13)
            .fontColor([this.palette().textTertiary])
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
  }

  // ══════════════════════ 格子菜单 / 重命名 ══════════════════════

  // ── 半模态面板的官方标题栏文案（标题区由 ModalSheet 自带，内容不再自绘标题）──

  private sheetTitle(): string {
    if (this.shelfSheet === 'rename') {
      return this.renameKind === 'folder' ? '重命名文件夹' : '重命名文档';
    }
    if (this.shelfSheet === 'export') {
      return '导出与分享';
    }
    return this.cellMenuFor;
  }

  private sheetSubtitle(): string {
    if (this.shelfSheet === 'rename') {
      return this.renameKind === 'folder'
        ? '文件夹只是归组，不影响文档本身'
        : '名称不能包含 / \\ : * ? " < > | 等字符';
    }
    if (this.shelfSheet === 'export') {
      return '「' + this.cellMenuFor + '」';
    }
    return '选择操作';
  }

  /** bindSheet 内容分发：按 shelfSheet 渲染格子菜单 / 重命名 / 导出面板。 */
  @Builder
  indexSheet() {
    if (this.shelfSheet === 'rename') {
      this.renameSheet()
    } else if (this.shelfSheet === 'export') {
      Column() {
        ExportOptionsPanel({
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
    } else {
      this.cellMenuSheet()
    }
  }

  /** bindSheet 内容包装（格子菜单 / 重命名）。菜单内容较高，**整页可滚**（MEDIUM 定高，超出会被裁掉）。 */
  @Builder
  cellMenuSheet() {
    Scroll() {
      Column() {
        this.cellMenuPanel()
      }
      .width('100%')
      .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.sm, bottom: HwSpace.lg })
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  @Builder
  renameSheet() {
    Column() {
      this.renamePanel()
    }
    .width('100%')
    .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.lg })
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
      Text('读写 / 只读')
        .fontSize(HwType.label)
        .fontColor(this.palette().textPrimary)
        .layoutWeight(1)
      ImmersiveChip({
        palette: this.palette(),
        chipLabel: '可写',
        chipActive: !this.cellMenuReadOnly,
        chipOnTap: () => {
          this.toggleDocReadOnly(false);
        }
      })
      ImmersiveChip({
        palette: this.palette(),
        chipLabel: '只读',
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
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([this.palette().textTertiary])
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
        // **预置文档支持修改**（用户要求）：编辑不再限制非内置；
        // 但**只读的文档不给编辑入口**（可在本面板切成「可写」再编辑）
        if (!this.cellMenuReadOnly) {
          this.menuRow('编辑', () => {
            this.closeCellMenu();
            this.editDoc(this.cellMenuFor);
          })
        } else {
          this.menuRow('编辑 · 已锁只读', () => {
            this.toast('该文档是只读的，先在上面切到「可写」');
          })
        }
        this.menuRow('重命名', () => {
          this.openRename('doc', this.cellMenuFor);
        })
        this.menuRow('导出 / 分享', () => {
          this.openCellExport();
        })
        this.menuRow(this.cellMenuBuiltin ? '移除教程' : '删除', () => {
          this.askDeleteDoc(this.cellMenuFor);
        })
        if (this.cellMenuBuiltin) {
          Text(this.cellMenuReadOnly
            ? '内置教程默认只读，可在上面切到「可写」后编辑；移除后可在「设置 → 数据管理」恢复'
            : '内置教程已解锁为可写；「重命名 / 删除」对内置文档仍然受限')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')
        } else if (this.cellMenuReadOnly) {
          Text('只读文档不提供编辑入口；「重命名 / 删除 / 封面 / 导出」不受影响')
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
              this.toast('文件夹已解散，文档回到书架');
            }
          });
        })
      }

      // ── 封面外观：底色 / 图片 / 名称显示（**预置文档同样支持**，用户要求）──
      if (this.cellMenuKind === 'folder' || this.cellMenuKind === 'doc') {
        Divider().strokeWidth(1).color(this.palette().divider)

        Text('封面')
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
            chipLabel: this.cellMenuHasCoverImage() ? '换封面图' : '导入封面图',
            chipOnTap: () => {
              this.pickCoverImage();
            }
          })
          if (this.cellMenuHasCoverImage()) {
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '移除图片',
              chipOnTap: () => {
                this.clearCoverImage();
              }
            })
          }
        }
        .width('100%')

        Row({ space: HwSpace.xs }) {
          Text('封面显示名称')
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
    Column({ space: HwSpace.md }) {
      TextInput({ text: this.renameText, placeholder: '名称' })
        .width('100%')
        .fontSize(HwType.label + 1)
        .fontColor(this.palette().textPrimary)
        .backgroundColor(this.palette().quoteBg)
        .borderRadius(HwRadius.inner)
        .onChange((value: string) => {
          this.renameText = value;
        })

      Row({ space: HwSpace.sm }) {
ImmersiveChip({
            palette: this.palette(),
            chipLabel: '取消',
            chipOnTap: () => {
            this.closeRename();
          }
          })
ImmersiveChip({
            palette: this.palette(),
            chipLabel: '保存',
            chipOnTap: () => {
            this.doRename();
          }
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ══════════════════════ 树形视图（文件树形态） ══════════════════════

  @Builder
  treeDocRow(meta: DocMeta, indent: number) {
    Row({ space: HwSpace.sm }) {
      Column()
        .width(indent)
      Column()
        .width(12)
        .height(16)
        .borderRadius(2)
        .linearGradient({
          angle: 200,
          colors: [[coverColorsOf(meta.name, meta.builtin).top, 0.0],
            [coverColorsOf(meta.name, meta.builtin).bottom, 1.0]]
        })
      Text(meta.name)
        .fontSize(HwType.label + 1)
        .fontColor(this.palette().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (meta.progressRatio > 0.001) {
        Text('已读 ' + Math.round(meta.progressRatio * 100) + '%')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
      } else if (!meta.builtin) {
        Text(DocStore.formatTime(meta.mtime))
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
      } else {
        Text('内置')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
      }
      Column() {
        ImmersiveIconButton({
          buttonSize: 26,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            this.openCellMenu('doc', meta.name, meta.builtin);
          }
        }) {
          SymbolGlyph($r('sys.symbol.ellipsis_circle'))
            .fontSize(13)
            .fontColor([this.palette().textSecondary])
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
  }

  @Builder
  treeFolderRow(folder: ShelfFolder) {
    Row({ space: HwSpace.sm }) {
      SymbolGlyph(this.expandedFolders.indexOf(folder.name) >= 0
        ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
        .fontSize(12)
        .fontColor([this.palette().textTertiary])
      SymbolGlyph($r('sys.symbol.folder'))
        .fontSize(16)
        .fontColor([this.palette().accent])
      Text(folder.name)
        .fontSize(HwType.label + 1)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.palette().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(folder.docs.length + ' 篇')
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
      Column() {
        ImmersiveIconButton({
          buttonSize: 26,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            this.openCellMenu('folder', folder.name, false);
          }
        }) {
          SymbolGlyph($r('sys.symbol.ellipsis_circle'))
            .fontSize(13)
            .fontColor([this.palette().textSecondary])
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
      .margin({ top: this.padTop() + HwBar.pill + HwSpace.md })

      ForEach(this.builtinDocs(), (meta: DocMeta) => {
        ListItem() {
          this.treeDocRow(meta, 0)
        }
      }, (meta: DocMeta) => 'tb_' + meta.name)

      ForEach(this.folders, (folder: ShelfFolder) => {
        ListItem() {
          this.treeFolderRow(folder)
        }
        if (this.expandedFolders.indexOf(folder.name) >= 0) {
          ForEach(this.folderDocs(folder.name), (meta: DocMeta) => {
            ListItem() {
              this.treeDocRow(meta, 26)
            }
          }, (meta: DocMeta) => 'fd_' + folder.name + '_' + meta.name)
        }
      }, (folder: ShelfFolder) => 'f_' + folder.name + '_' + folder.docs.length)

      ForEach(this.looseDocs(), (meta: DocMeta) => {
        ListItem() {
          this.treeDocRow(meta, 0)
        }
      }, (meta: DocMeta) => 't_' + meta.name + '_' + meta.mtime)

      ListItem() {
        Text('树形视图 · 文件夹来自书架拖拽归组')
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
    .edgeEffect(EdgeEffect.Spring)
    .padding({ left: HwSpace.lg, right: HwSpace.lg })
    .onScrollIndex((first: number, last: number) => {
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

  @Builder
  bottomBar() {
    ImmersiveBar({
      palette: this.palette(), barPaddingH: HwSpace.sm, barPaddingV: HwSpace.xs,
      barHeight: HwBar.pill,
      // **平板放屏幕右下角**：宽屏收窄靠右，手机仍整行
      // 宽屏时留出按钮位置（原 340 → 400），否则「篇数 + 字数 + 按钮」会挤在一起
      barWidth: this.isWideShelf() ? 400 : '100%'
    }) {
      Text(this.docs.length + ' 篇 · ' + this.folders.length + ' 个文件夹')
        .fontSize(HwType.caption)
        .fontColor(this.palette().textSecondary)
        // 窄屏优先让按钮可见：统计文字压缩到最多 88vp，超出省略
        .constraintSize({ maxWidth: 88 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Column()
        .layoutWeight(1)
      Text(this.totalWords + ' 字')
        .fontSize(HwType.caption)
        .fontColor(this.palette().textTertiary)
        .constraintSize({ maxWidth: 64 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // **快捷「新建 / 导入」按钮，就在这颗悬浮胶囊里面**（用户要求）：
      // 它是胶囊的第三个子节点、与统计文字同一行，材质由 ImmersiveBar 统一承载
      // （沉浸光感）；点击新建文档、长按导入文档。
      this.newDocButton()
    }
  }

  /**
   * 胶囊内的快捷按钮：圆形小钮 + 主题色薄底 + 加号图标。
   * 点击 = 新建文档；长按 = 导入 .md（与「新建卡」同款，600ms 起效）。
   */
  @Builder
  newDocButton() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .borderRadius(HwRadius.pill)
        .backgroundColor(this.palette().accentSoft)
        .hitTestBehavior(HitTestMode.None)

      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(18)
        .fontColor([this.palette().accent])
    }
    .width(NEW_BTN_SIZE)
    .height(NEW_BTN_SIZE)
    .borderRadius(HwRadius.pill)
    .margin({ left: HwSpace.xs })
    .onClick(() => {
      // 文件夹面板展开期间忽略（与「新建卡」同一套保护）
      if (this.openFolderName.length > 0) {
        return;
      }
      this.createDoc();
    })
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
          if (this.treeMode) {
            this.treeList()
          } else {
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
            .margin({ top: this.padTop() + HwBar.pill + HwSpace.md })
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
              // 这样同行的左右邻居留在原格，只有下方的图标被推开。
              // 条件用 folderPanelMounted（不是 openFolderName）：收起时名字要留到动画
              // 跑完（压暗其他格子用），而节点必须当场摘掉，底部提示文本才不会二次跳。
              if (item.kind === 'folder' && this.folderPanelMounted
                && index === this.panelAfterIndex()) {
                GridItem() {
                  this.folderExpandPanel()
                }
                .columnStart(0)
                .columnEnd(this.shelfColumns() - 1)
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
              }
            }, (item: ShelfItem) => this.itemKey(item))

            if (this.userDocCount === 0) {
              GridItem() {
                Column({ space: HwSpace.xs }) {
                  Text('书架还是空的')
                    .fontSize(HwType.label)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.palette().textPrimary)
                  Text('点「新建文档」写一篇，或用顶栏的文件夹按钮导入 .md 文件；拖动封面到另一张上可以合并成文件夹')
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

            GridItem() {
              Text('长按封面拖到另一张上合并为文件夹 · 封面由文档名生成')
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
          }
          .columnsTemplate(this.columnsTemplateStr())
          .columnsGap(HwSpace.md)
          .rowsGap(HwSpace.lg)
          .width('100%')
          .layoutWeight(1)
          // 右侧滚动条不显示（用户要求）
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
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
          .key('shelfGrid_' + this.themeEpoch)
          }

          // ── 悬浮顶栏 / 底栏（材质胶囊）─────────────────────────
          // 两者都**脱离布局流**（position 定位），内容从它们下面滚过。
          // hitTestBehavior 用 Transparent：胶囊自身的空隙不拦截触摸，
          // 点击会落到下方的卡片上；胶囊上的按钮照常可点。
          Row() {
            // **「全部文档」标题固定在左上角**（平板；不进胶囊、不随内容滚动位置变化）
            if (this.isWideShelf()) {
              Text('全部文档')
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.palette().textPrimary)
                .margin({ top: 6 })
            }
            this.topBar()
          }
          .width('100%')
          .justifyContent(this.isWideShelf() ? FlexAlign.SpaceBetween : FlexAlign.Start)
          .padding({ left: HwSpace.lg, right: HwSpace.lg })
          // 只让**胶囊本体**占触摸区（不含 padTop 那条空白），
          // 否则顶部近百 vp 都成了滑动死区，手一放上去就像「滑不动」。
          .position({ x: 0, y: this.padTop() })
          .hitTestBehavior(HitTestMode.Transparent)
          // **顶栏常驻**（用户要求）：不再随滚动淡出 / 上移，
          // 始终可见可点。收起逻辑现在只作用于底栏（同一份 barsVisible 状态）。
          .opacity(1)
          .translate({ y: 0 })

          // （快捷「新建 / 导入」按钮已经在 bottomBar 的胶囊**内部**，见 bottomBar()）
          Row() {
            this.bottomBar()
          }
          .width('100%')
          // **平板放屏幕右下角**：宽屏胶囊靠右
          .justifyContent(this.isWideShelf() ? FlexAlign.End : FlexAlign.Start)
          .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: this.padBottom() })
          .position({ x: 0, y: this.rootHeight - this.padBottom() - HwBar.pill })
          .hitTestBehavior(this.barsVisible ? HitTestMode.Transparent : HitTestMode.None)
          .opacity(this.barsVisible ? 1 : 0)
          .translate({ y: this.barsVisible ? 0 : 16 })
          .animation({ duration: 220, curve: Curve.FastOutSlowIn })
          .enabled(this.barsVisible)
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
        .padding({ left: HwSpace.lg, right: HwSpace.lg, top: this.padTop() + 52 })
        .transition({ opacity: 0, translate: { y: -12 } })
      }

      // 格子「⋯」菜单 / 重命名：官方规范半模态面板（material/ModalSheet.ets，
      // 挂在本页根节点上，见 build 末尾的 .bindSheet）

      // ── 文档封面的「一镜到底」飞行层：打开 / 返回的第二段 ──
      if (this.docCoverName.length > 0) {
        this.docCoverOverlay()
      }

      // ── 启动页：竹影渐变底 + 应用图标（分层图标的 foreground）+ ChengJian ──
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
            Text('ChengJian')
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
    .key('index_theme_' + this.themeEpoch)
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
      } else if (name === 'pages/SettingsExplore') {
        SettingsExplore({ stack: this.pathStack })
      } else if (name === 'pages/Changelog') {
        Changelog({ stack: this.pathStack })
      } else if (name === 'pages/LegalDoc') {
        LegalDoc({
          stack: this.pathStack,
          doc: (param as LegalDocRoute).doc
        })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(this.palette().pageBottom)
    .onShown(() => {
      if (name === 'pages/Reader') {
        this.readerLife.onShow();
      } else if (name === 'pages/Settings') {
        this.settingsLife.onShow();
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
      if (name === 'pages/Editor') {
        setTimeout(() => {
          this.refresh();
        }, 320);
      }
    })
  }

  /** 空书架时第二格的占位（避免 GridItem 空内容）。 */
  private emptyMeta(): DocMeta {
    const meta: DocMeta = {
      name: 'Markdown 语法教程',
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

  /** 当前主题下的自定义背景色；空串表示用主题默认渐变。 */
  private pageBackground(): string {
    return this.isDark() ? this.customBgDark : this.customBgLight;
  }
}
