/**
 * LiteMdReader · 编辑 / 新建文档
 * ================================
 *
 * 两种入口复用同一页：
 *   · 从书架点「+」→ 无路由参数 → 新建（正文预填一份小模板）
 *   · 从书架/阅读页点「编辑」→ 带 name 参数 → 载入已有文档
 *
 * 三个要点：
 *  1. **片段插入走光标位置**，而不是简单追加到末尾——写作时才有用。
 *     `TextAreaController.getCaretOffset()` 拿位置，插入后把光标选中占位文字，
 *     用户可以直接改写而不必再拖光标。
 *  2. **改名即重命名**：顶栏那个输入框在保存时统一处理，新建走 create、
 *     已有文档走 rename + update，用户不用区分「另存为」和「重命名」。
 *  3. **预览**用与阅读页同一套渲染器，所见即所得。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { GenWallpaper } from '../theme/GenWallpaper';
import { modalSheetOptions } from '../material/ModalSheet';
import { VersionSnapshot, VersionStore } from '../service/VersionStore';
import { WallpaperStore } from '../service/WallpaperStore';
import {
  HwBar,
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  isDarkTheme,
  paletteFor,
  READER_BG_DEFAULT_DARK,
  READER_BG_DEFAULT_LIGHT
} from '../theme/DesignTokens';
import { applySystemBarTheme, applyAppColorMode } from '../service/AppWindow';
import {
  ImmersiveBar,
  ImmersiveCard,
  ImmersiveCardLayer,
  ImmersiveChip,
  ImmersiveIconButton
} from '../material/ImmersiveCard';
import { DocMeta, DocStore, ReaderRoute } from '../service/DocStore';
import { NavLifecycle } from '../service/NavLifecycle';
import { MdBlock, MdParseResult } from '../markdown/MdTypes';
import { MdParser } from '../markdown/MdParser';
import { MdBlockView } from '../markdown/MdView';

/** 可一键插入的 Markdown 片段 */
interface MdSnippet {
  key: string;
  label: string;
  before: string;
  after: string;
  holder: string;
}

/** 版本对比的一行：tag = same（两边都有）/ del（旧版独有）/ add（当前独有） */
interface DiffRow {
  tag: string;
  text: string;
}

/** 语法速查表的一行 */
interface SyntaxRow {
  syntax: string;
  desc: string;
}

const SNIPPETS: MdSnippet[] = [
  { key: 'h1', label: 'H1', before: '# ', after: '', holder: '一级标题' },
  { key: 'h2', label: 'H2', before: '## ', after: '', holder: '二级标题' },
  { key: 'h3', label: 'H3', before: '### ', after: '', holder: '三级标题' },
  { key: 'bold', label: '粗体', before: '**', after: '**', holder: '粗体文本' },
  { key: 'italic', label: '斜体', before: '*', after: '*', holder: '斜体文本' },
  { key: 'strike', label: '删除线', before: '~~', after: '~~', holder: '删除线' },
  { key: 'mark', label: '高亮', before: '==', after: '==', holder: '高亮标记' },
  { key: 'code', label: '行内代码', before: '`', after: '`', holder: 'code' },
  { key: 'codeblock', label: '代码块', before: '\n```text\n', after: '\n```\n', holder: '代码内容' },
  { key: 'quote', label: '引用', before: '\n> ', after: '', holder: '引用内容' },
  { key: 'callout', label: '提示块', before: '\n> [!NOTE]\n> ', after: '', holder: '提示内容' },
  { key: 'ul', label: '无序列表', before: '\n- ', after: '', holder: '列表项' },
  { key: 'ol', label: '有序列表', before: '\n1. ', after: '', holder: '列表项' },
  { key: 'task', label: '任务', before: '\n- [ ] ', after: '', holder: '待办事项' },
  { key: 'table', label: '表格', before: '\n| 列 A | 列 B |\n| --- | --- |\n| ', after: ' | 内容 |\n', holder: '内容' },
  { key: 'link', label: '链接', before: '[', after: '](https://)', holder: '链接文字' },
  { key: 'image', label: '图片', before: '![', after: '](路径)', holder: '替代文字' },
  { key: 'divider', label: '分割线', before: '\n---\n', after: '', holder: '' },
  { key: 'note', label: '脚注', before: '[^', after: ']', holder: '1' }
];

/**
 * 语法速查的行定义。
 *
 * 每一行的 `syntax` 会被**应用自己的解析器 + 渲染器真实渲染**成效果预览，
 * 所以这里只放"能正确渲染"的写法（旧版把「无序 + 有序」「表格缺分隔行」
 * 「```lang 代码块 ```」「![](路径)」这类无效示例塞进一行，预览自然不正常）。
 *
 * 语法口径与说明参考来源：younghz/Markdown（https://github.com/younghz/Markdown）
 * —— 那是流传最广的中文 Markdown 入门教程，本表按它的分类逐项对照，
 * 并按澄笺支持的范围（含 callout / 脚注 / 公式 / 图表等扩展）做了补充。
 */
const SYNTAX_ROWS: SyntaxRow[] = [
  { syntax: '# 一级标题\n## 二级标题\n### 三级标题', desc: '标题：一到六个 # 表示一到六级；# 后要有空格' },
  { syntax: '**粗体** 与 *斜体* 与 ***粗斜体***', desc: '强调：两侧各一个 * 是斜体、两个是粗体（_ 写法等价）' },
  { syntax: '~~删除线~~  与  ==高亮==', desc: '删除线与高亮标记（扩展语法，两个波浪线 / 两个等号）' },
  { syntax: '`行内代码`', desc: '行内代码：一个反引号包裹，底纹带圆角' },
  { syntax: '> 区块引用\n>> 嵌套引用', desc: '引用：行首写 > ；连续 >> 表示嵌套一层' },
  { syntax: '> [!NOTE]\n> 提示块的正文写在这里', desc: '提示块：NOTE / TIP / IMPORTANT / WARNING / CAUTION 五种' },
  { syntax: '- 第一项\n- 第二项\n  - 缩进两格表示嵌套', desc: '无序列表：- + * 均可，标记后至少一个空格' },
  { syntax: '1. 第一项\n2. 第二项', desc: '有序列表：数字 + . + 空格' },
  { syntax: '- [ ] 待办事项\n- [x] 已完成事项', desc: '任务列表：渲染成勾选框，阅读页可直接点选' },
  { syntax: '| 语法 | 说明 |\n| --- | --- |\n| 表格 | 第二行用 --- 分隔 |', desc: '表格：用 | 分隔单元格，第二行用 --- 分隔表头；用 :-: 控制列对齐' },
  { syntax: '---', desc: '分割线：三个及以上的 - * _ 均可' },
  { syntax: '[链接文字](https://www.harmonyos.com)', desc: '链接：行内式 [文字](地址)；点击链接会复制地址' },
  { syntax: '`![替代文字](图片地址)`', desc: '图片：与链接同理、前面多加一个 !；网络图与本地图（工具条「插图片」）都会真实加载' },
  { syntax: '`[^1]` 与 `[^1]: 脚注内容`', desc: '脚注：引用呈上标，定义在文末成注释卡，阅读页左滑可查看' },
  { syntax: '\\*转义\\*', desc: '反斜杠转义：让 * / # / ` 等符号按普通文字显示' },
  // 公式：**用行内写法做预览**——它走 MathLite 同步自绘，一定能显示；
  // 块级 $$ 在面板里要挂 Web 渲染（体积大、首帧空白），只放在说明里讲写法
  { syntax: '行内公式：$a^2 + b^2 = c^2$ 直接写在句子里', desc: '数学公式：行内用一对 $ 包住（开 $ 后不能紧跟空格）；块级单独起一行、用 $$ 包起来。分数 / 上下标 / 根号 / 矩阵 / 希腊字母等常用子集真实渲染' },
  { syntax: '```mermaid\ngraph TD\n  A[打开澄笺] --> B[开始阅读]\n```', desc: '流程图：graph TD / LR 真实布局渲染，其余图表语言按代码块显示' }
];

/** 速查行语法 → 解析后的块缓存（key = syntax 原文） */
const syntaxBlockCache: Map<string, MdBlock[]> = new Map();

@Component
export struct Editor {
  /** 分屏模式：0 纯编辑/预览切换 1 上下分屏 2 左右分屏 */
  @State splitMode: number = 0;
  /** 背景链（与阅读页/书架一致）：手选壁纸 / 函数壁纸 / 模糊 */
  /** 阅读背景图（阅读页设置的"阅读背景"，编辑页同用，优先于壁纸） */
  @StorageProp('readerBgPath') readerBgPath: string = '';
  /** 阅读背景样式（阅读调整里选的程序化背景），编辑页同用 */
  @StorageProp('readerBgId') readerBgId: string = '';
  @StorageProp('wallpaperPath') wallpaperPath: string = '';
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
  @StorageProp('wallpaperGenId') genWallId: string = '';
  @StorageProp('wallpaperBlur') wallpaperBlur: number = 4;
  /** 可读性遮罩浓度（与阅读页同一键，观感一致） */
  @StorageProp('wallpaperScrim') wallpaperScrim: number = 42;
  /** 外观刷新计数（见 SettingsMirror）：主题色 / 灰字 / 沾色改完后靠它重算派生色 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  /** 键盘是否弹出（AppWindow 的 TYPE_KEYBOARD 避让区广播）；
   *  RESIZE 模式下页面底 = 键盘顶，此时底部只留 6vp，别再叠 padBottom */
  @StorageProp('keyboardPx') keyboardPx: number = 0;
  /** 背景光斑缓慢漂移 */
  @State blobAX: number = 0;
  @State blobAY: number = 0;
  @State blobBX: number = 0;
  @State blobBY: number = 0;
  /**
   * 路由参数（Navigation 迁移后由 navPageBuilder 注入）：
   * name 有值 = 编辑既有文档；为空 = 新建。
   */
  route: ReaderRoute = { name: '' };
  /** 导航栈：用于返回 */
  stack: NavPathStack | null = null;
  @StorageLink('readerFontSize') @Watch('onVisualChanged') fontSize: number = HwType.bodyDefault;
  @StorageLink('readerLineHeight') lineMul: number = HwType.lineDefault;
  @StorageLink('readerThemeMode') @Watch('onThemeChanged') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') @Watch('onThemeChanged') systemDark: boolean = false;
  /** 沉浸布局下的状态栏 / 手势条避让高度（px） */
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  @StorageProp('safeBottomPx') safeBottomPx: number = 0;

  @State docName: string = '';
  @State content: string = '';
  @State isNew: boolean = true;
  /** 已打开的文档是否为「只读」（标记见 DocStore.isReadOnly）：只读时不允许保存回写 */
  @State docReadOnly: boolean = false;
  @State originalName: string = '';
  /**
   * 未保存标记。**用 @StorageLink 而非 @State**：Index 的 NavDestination 需要在
   * 系统返回手势（onBackPressed）里读到它来拦截"误触退出丢内容"——
   * AppStorage 是两个组件共享脏状态的通道。写入点与 @State 完全一致，无需改动。
   */
  @StorageLink('editorDirty') dirty: boolean = false;
  /** Index 的返回拦截发来的信号：系统返回手势触发 → 弹"保存/不保存"窗（与顶栏返回同逻辑） */
  @StorageProp('editorGoBackTick') @Watch('onGoBackTick') goBackTick: number = 0;
  @State preview: boolean = false;
  @State showSyntax: boolean = false;
  /** 画板浮层 */
  @State previewBlocks: MdBlock[] = [];
  @State rootWidth: number = 360;
  /** 窗口实测高度（全屏画板的尺寸依据） */
  @State rootHeight: number = 800;
  /** 渲染纪元：字号变化时自增，拼进预览 ForEach 的 key 强制重建（否则 @Prop 不同步） */
  @State renderEpoch: number = 0;

  onVisualChanged(): void {
    this.renderEpoch++;
  }
  // ── 编辑器查找 / 替换 / 跳转行（移植自参考项目 CodeMirror 的查找替换与跳转行） ──
  @State showFind: boolean = false;
  @State findQuery: string = '';
  @State replaceText: string = '';
  @State findMatches: number[] = [];
  @State findCursor: number = -1;
  @State gotoLineText: string = '';
  // ── 阅读背景自定义色（编辑页与阅读页同一套背景） ──
  @StorageLink('readerCustomBgLight') customBgLight: string = '';
  @StorageLink('readerCustomBgDark') customBgDark: string = '';

  /**
   * 光标位置。
   *
   * 刻意用 `onTextSelectionChange` 记录，而**不用** `TextAreaController.getCaretOffset()`：
   * 该方法的返回类型在不同 SDK 修订版里不一致（有的是 number，有的是 CaretOffset），
   * 用它会出现在某个 SDK 上编不过的问题。onTextSelectionChange 的回调签名则长期稳定。
   */
  @State caret: number = -1;

  private controller: TextAreaController = new TextAreaController();

  // ── 版本历史（用户要求）──
  @StorageLink('versionAutoSave') versionAutoSave: boolean = true;
  @StorageLink('versionAutoSaveInterval') versionInterval: number = 5;
  @State showVersions: boolean = false;
  @State versionList: VersionSnapshot[] = [];
  /** 对比视图：-1 = 快照列表；否则 = 正在对比的快照时间戳 */
  @State diffFor: number = -1;
  @State diffRows: DiffRow[] = [];
  private verTimer: number = -1;
  private lastAutoAt: number = 0;
  private lastAutoContent: string = '';

  aboutToAppear(): void {
    // **键盘避让改 RESIZE**：默认 OFFSET 是「整页上移」，会把悬浮工具层顶到
    // 键盘上方一大截（页面没缩、只是平移）。RESIZE 让页面布局高度直接收缩，
    // 钉底的悬浮层自然贴在键盘上沿，正文区也同步缩小——平台级方案，自己不算高度。
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.startBlobDrift();
    const params: ReaderRoute = this.route;
    if (params !== undefined && params !== null && params.name !== undefined && params.name.length > 0) {
      this.loadExisting(params.name);
    } else {
      this.isNew = true;
      this.docName = '';
      this.content = DocStore.NEW_DOC_TEMPLATE;
      this.dirty = false;
    }
    applySystemBarTheme(this.isDark());
    // 版本历史自动保存：30s 一次节拍，到间隔且内容有变化才真正落快照
    this.verTimer = setInterval(() => {
      this.autoSnapshotTick();
    }, 30000);
  }

  aboutToDisappear(): void {
    if (this.verTimer >= 0) {
      clearInterval(this.verTimer);
      this.verTimer = -1;
    }
  }

  /** 自动保存节拍：开关开 + 到达间隔 + 内容相对上次快照有变化才落盘。 */
  private autoSnapshotTick(): void {
    if (!this.versionAutoSave || this.docName.length === 0) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastAutoAt < this.versionInterval * 60000) {
      return;
    }
    if (this.content === this.lastAutoContent) {
      return;
    }
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    if (VersionStore.snapshot(ctx, this.docName, this.content)) {
      this.lastAutoAt = now;
      this.lastAutoContent = this.content;
      if (this.showVersions) {
        this.versionList = VersionStore.list(ctx, this.docName);
      }
    }
  }

  /** 手动保存成功后也记一份快照（保存历史 = 版本历史）。 */
  private snapshotAfterSave(ctx: common.UIAbilityContext): void {
    if (VersionStore.snapshot(ctx, this.docName, this.content)) {
      this.lastAutoAt = Date.now();
      this.lastAutoContent = this.content;
    }
  }

  /** 打开版本历史面板。 */
  private openVersions(): void {
    if (this.docName.length === 0) {
      this.toast('先保存文档才有版本历史');
      return;
    }
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    this.versionList = VersionStore.list(ctx, this.docName);
    this.diffFor = -1;
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.showVersions = true;
    });
  }

  /** 生成对比行：掐掉公共前后缀后，旧版中段 = 删除、当前中段 = 新增（轻量线性对比）。 */
  private buildDiff(oldContent: string): void {
    const oldLines: string[] = oldContent.split('\n');
    const newLines: string[] = this.content.split('\n');
    let head: number = 0;
    while (head < oldLines.length && head < newLines.length && oldLines[head] === newLines[head]) {
      head++;
    }
    let tailOld: number = oldLines.length - 1;
    let tailNew: number = newLines.length - 1;
    while (tailOld >= head && tailNew >= head && oldLines[tailOld] === newLines[tailNew]) {
      tailOld--;
      tailNew--;
    }
    const rows: DiffRow[] = [];
    for (let k = 0; k < head; k++) {
      rows.push({ tag: 'same', text: oldLines[k] } as DiffRow);
    }
    for (let k = head; k <= tailOld; k++) {
      rows.push({ tag: 'del', text: oldLines[k] } as DiffRow);
    }
    for (let k = head; k <= tailNew; k++) {
      rows.push({ tag: 'add', text: newLines[k] } as DiffRow);
    }
    for (let k = tailOld + 1; k < oldLines.length; k++) {
      rows.push({ tag: 'same', text: oldLines[k] } as DiffRow);
    }
    this.diffRows = rows;
  }

  /** 进入对比视图：选中快照 vs 当前编辑内容。 */
  private startDiff(ts: number): void {
    for (let k = 0; k < this.versionList.length; k++) {
      if (this.versionList[k].ts === ts) {
        this.buildDiff(this.versionList[k].content);
        this.diffFor = ts;
        return;
      }
    }
  }

  /** 把选中的快照恢复为当前内容（恢复前先记一份当前内容快照，恢复错了还能找回）。 */
  private restoreVersion(ts: number): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    for (let k = 0; k < this.versionList.length; k++) {
      if (this.versionList[k].ts === ts) {
        VersionStore.snapshot(ctx, this.docName, this.content);
        this.content = this.versionList[k].content;
        this.dirty = true;
        this.showVersions = false;
        if (this.splitMode > 0) {
          this.refreshPreviewBlocks();
        }
        this.toast('已恢复到 ' + this.versionTime(ts));
        return;
      }
    }
  }

  private versionTime(ts: number): string {
    const d: Date = new Date(ts);
    const pad = (v: number): string => {
      return v < 10 ? '0' + v : '' + v;
    };
    return (d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  /** 主题变化时同步系统栏图标颜色与应用级颜色模式。 */
  onThemeChanged(): void {
    applyAppColorMode(this.themeMode);
    applySystemBarTheme(this.isDark());
  }

  /** 沉浸布局下顶部要避开状态栏（px → vp，用 UIContext 的 px2vp，全局那个已废弃）。 */
  private padTop(): number {
    return this.getUIContext().px2vp(this.safeTopPx) + HwSpace.xs;
  }

  private padBottom(): number {
    return this.getUIContext().px2vp(this.safeBottomPx) + HwSpace.xs;
  }

  /**
   * 首行让位（与阅读页 topSpacerHeight 同源取值）：
   * 状态栏 + 顶栏胶囊 + 一条小缝 —— 第一行文字落在顶栏下方，不被胶囊压住；
   * 正文向上滑动时照样从胶囊底下穿过（顶栏下层正常显示文字）。
   */
  private contentTopInset(): number {
    return this.padTop() + HwBar.pill + HwSpace.xs;
  }

  /**
   * 末行让位（与阅读页文末留白同源思路）：手势条 + 底部悬浮工具层实际高度 + 小缝。
   * 工具层 = 片段工具条（ImmersiveBar 定高 pill=52）+ 间距 xs(6) + 底部状态栏（≈44）；
   * 纯预览态没有片段条，只用让开状态栏那一层。
   * 滚到最底时最后一行停在工具层上方，不被底栏遮挡。
   */
  private contentBottomInset(): number {
    const toolLayer: number = this.preview ? 44 : 52 + HwSpace.xs + 44;
    return this.padBottom() + toolLayer + HwSpace.xs;
  }

  private loadExisting(name: string): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      DocStore.init(ctx);
      const meta: DocMeta | undefined = DocStore.find(ctx, name);
      if (meta === undefined) {
        this.toast('文档不存在');
        return;
      }
      // **预置文档支持修改**（用户要求）：内置文档与普通文档同一编辑链路
      //（保存时 DocStore.update 会把正文写到 docs/<fileName> 覆盖 rawfile 默认内容）；
      // 重命名 / 删除依旧受限。
      this.isNew = false;
      this.originalName = meta.name;
      this.docName = meta.name;
      this.content = DocStore.readText(ctx, meta);
      // 只读文档：正文照常显示，但保存会被拦下（入口侧已隐藏编辑按钮，这里兜底）
      this.docReadOnly = DocStore.isReadOnly(ctx, meta.name);
      this.dirty = false;
    } catch (err) {
      this.toast('读取失败：' + DocStore.describeError(err as BusinessError));
    }
  }

  // ══════════════════════ 基础 ══════════════════════

  private ctx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  private isDark(): boolean {
    // 统一转调 isDarkTheme：**羊皮纸 / 护眼绿是浅色纸底**，
    // 漏判会让编辑器背景 / 系统栏按 systemDark 走，与纸色文字对不上。
    return isDarkTheme(this.themeMode, this.systemDark);
  }

  private palette(): ReaderPalette {
    // 三个来源都要显式读一遍落成局部常量：paletteFor 是纯函数读 AppStorage、不登记依赖，
    // 这里不登记的话主题切换会被 ArkUI 跳过重算（文字变黑、退出重进才恢复）
    const tick: number = this.appearanceTick;
    // 羊皮纸 / 护眼绿有独立调色板，必须按主题模式取色，不能只看明暗
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  private measureWidth(): number {
    // **平板全宽**：不再限宽 760——正文要铺满屏幕，左右不留空白（用户要求）
    return this.rootWidth;
  }

  /** 编辑区水平内边距：**平板留一个字符的空隙**（约 16vp，不贴死屏幕边缘），手机保留页边距 */
  private editorHPad(): number {
    return this.rootWidth > 760 ? HwType.bodyDefault : HwSpace.lg;
  }

  /**
   * 自定义阅读背景色；**没选时用固定默认色（与阅读页同一套，不再回退主题渐变）**。
   * 「阅读背景」完全独立于主题（用户要求），切主题编辑页背景也不变。
   */
  private pageBackground(): string {
    if (this.isDark()) {
      return this.customBgDark.length > 0 ? this.customBgDark : READER_BG_DEFAULT_DARK;
    }
    return this.customBgLight.length > 0 ? this.customBgLight : READER_BG_DEFAULT_LIGHT;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1800 });
    } catch (err) {
      // 提示失败不影响主流程
    }
  }

  private stats(): string {
    let chars: number = 0;
    let words: number = 0;
    try {
      const parsed: MdParseResult = MdParser.parse(this.content);
      chars = parsed.charCount;
      words = parsed.wordCount;
    } catch (err) {
      chars = this.content.length;
    }
    return words + ' 字 · ' + chars + ' 字符';
  }

  // ══════════════════════ 片段插入 ══════════════════════

  private insertSnippet(snippet: MdSnippet): void {
    let offset: number = this.content.length;
    if (this.caret >= 0 && this.caret <= this.content.length) {
      offset = this.caret;
    }
    const inserted: string = snippet.before + snippet.holder + snippet.after;
    this.content = this.content.substring(0, offset) + inserted + this.content.substring(offset);
    this.dirty = true;
    const selStart: number = offset + snippet.before.length;
    const selEnd: number = selStart + snippet.holder.length;
    this.caret = selEnd;
    if (selEnd > selStart) {
      // 选中占位文字，用户可以直接改写而不必再拖光标
      setTimeout(() => {
        try {
          this.controller.setTextSelection(selStart, selEnd);
        } catch (err) {
          // 光标定位失败不影响插入结果
        }
      }, 40);
    }
  }

  /** 在光标处插入一段原文（图片插入用，无占位文字可选中）。 */
  private insertRaw(text: string): void {
    let offset: number = this.content.length;
    if (this.caret >= 0 && this.caret <= this.content.length) {
      offset = this.caret;
    }
    this.content = this.content.substring(0, offset) + text + this.content.substring(offset);
    this.dirty = true;
    this.caret = offset + text.length;
  }

  // ══════════════════════ 插入图片 ══════════════════════
  //
  // 移植自参考项目「编辑时粘贴图片 → 存进 images/ 目录 → 自动插引用」：
  // 端上没有剪贴板图片的可靠入口，用系统图片选择器替代；
  // 图片复制进沙箱 docs/images/（无权限要求），引用相对路径，阅读页可真实加载。

  private insertImage(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    try {
      // **系统图片选择组件**（PhotoViewPicker）：系统级 UI、无需任何媒体库权限，
      // 选中的 URI 带临时授权，复制进沙箱后长期可用。
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
        this.insertRaw('\n![图片](' + rel + ')\n');
        this.toast('已插入 ' + rel + '，预览即可查看');
      }).catch((err: BusinessError) => {
        this.toast('选择图片失败：' + err.message);
      });
    } catch (err) {
      this.toast('无法打开图片选择器');
    }
  }

  // ══════════════════════ 手写插入 ══════════════════════
  //
  // 「手写」进独立页（Pen Kit 官方 HandwriteComponent 画布）；
  // 完成后 PNG 落 docs/images/，Markdown 片段经 AppStorage 回传，光标处插入。
  // 双通道触发：@Watch（同 UI 上下文 setOrCreate 会触发）+ 编辑页 onShown tick 兜底。

  /** 进入手写页。push 前清掉上一次的待插入片段（防旧值重复插入）。 */
  private openSketch(): void {
    AppStorage.setOrCreate('sketchInsertMd', '');
    try {
      if (this.stack !== null) {
        this.stack.pushPath({ name: 'pages/Sketch' });
      }
    } catch (err) {
      this.toast('无法打开手写页');
    }
  }

  /** 待插入的手写片段（Sketch 页写回），非空即在光标处插入并清掉。 */
  @StorageProp('sketchInsertMd') @Watch('onSketchInsert') sketchInsertMd: string = '';
  /** 编辑页 onShown tick（Index 转发），兜底检查待插入片段 */
  @StorageProp('editorShownTick') @Watch('onEditorShownTick') editorShownTick: number = 0;

  /** 吸收待插入的手写片段（两个通道共用，幂等：插入即清键）。 */
  private absorbSketch(): void {
    const md: string = AppStorage.get<string>('sketchInsertMd') ?? '';
    if (md.length > 0) {
      AppStorage.setOrCreate('sketchInsertMd', '');
      this.insertRaw(md);
      this.toast('手写笔记已插入，预览即可查看');
    }
  }

  private onSketchInsert(): void {
    this.absorbSketch();
  }

  private onEditorShownTick(): void {
    this.absorbSketch();
  }

  // ══════════════════════ 查找 / 替换 / 跳转行 ══════════════════════
  //
  // 移植自参考项目 CodeMirror 的查找替换与跳转行。以「匹配位置」为单位导航，
  // 上一处/下一处直接把光标选区设到匹配段上（TextArea 会自动把选区滚进可视区）。

  private openFind(): void {
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.showFind = true;
    });
  }

  private closeFind(): void {
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.showFind = false;
      this.replaceRowOpen = false;
    });
  }

  /** 替换行展开 / 收起 */
  @State replaceRowOpen: boolean = false;

  /** 重新计算全部匹配位置（不区分大小写）。内容或关键词变化后调用。 */
  private recomputeMatches(): void {
    const needle: string = this.findQuery.trim().toLowerCase();
    const out: number[] = [];
    if (needle.length > 0) {
      const hay: string = this.content.toLowerCase();
      let from: number = 0;
      while (from <= hay.length) {
        const at: number = hay.indexOf(needle, from);
        if (at < 0) {
          break;
        }
        out.push(at);
        from = at + needle.length;
      }
    }
    this.findMatches = out;
    this.findCursor = out.length > 0 ? 0 : -1;
  }

  private findLabel(): string {
    if (this.findQuery.trim().length === 0) {
      return '';
    }
    if (this.findMatches.length === 0) {
      return '无匹配';
    }
    return (this.findCursor + 1) + ' / ' + this.findMatches.length;
  }

  /** 把光标选区设到指定区间（TextArea 会滚动到该处），并同步记录 caret。 */
  private selectRange(start: number, end: number): void {
    setTimeout(() => {
      try {
        this.controller.setTextSelection(start, end);
      } catch (err) {
        // 定位失败不影响
      }
    }, 40);
    this.caret = end;
  }

  private stepMatch(delta: number): void {
    if (this.findQuery.trim().length === 0) {
      return;
    }
    // 内容可能已被编辑，导航时惰性重算
    this.recomputeMatches();
    const total: number = this.findMatches.length;
    if (total === 0) {
      this.toast('没有匹配的内容');
      return;
    }
    let next: number = this.findCursor + delta;
    if (next < 0) {
      next = total - 1;
    }
    if (next >= total) {
      next = 0;
    }
    this.findCursor = next;
    const at: number = this.findMatches[next];
    this.selectRange(at, at + this.findQuery.trim().length);
  }

  /** 替换当前匹配：光标必须正好停在一个匹配上，否则先跳到当前匹配。 */
  private replaceCurrent(): void {
    this.recomputeMatches();
    if (this.findMatches.length === 0) {
      this.toast('没有匹配的内容');
      return;
    }
    const needle: string = this.findQuery.trim();
    const at: number = this.findCursor >= 0 && this.findCursor < this.findMatches.length
      ? this.findMatches[this.findCursor] : this.findMatches[0];
    if (this.content.substring(at, at + needle.length).toLowerCase() !== needle.toLowerCase()) {
      this.toast('请先用「上一处/下一处」定位到要替换的词');
      return;
    }
    this.content = this.content.substring(0, at) + this.replaceText
      + this.content.substring(at + needle.length);
    this.dirty = true;
    this.caret = at + this.replaceText.length;
    this.recomputeMatches();
    this.toast('已替换');
  }

  private replaceAll(): void {
    const needle: string = this.findQuery.trim();
    if (needle.length === 0) {
      return;
    }
    this.recomputeMatches();
    const total: number = this.findMatches.length;
    if (total === 0) {
      this.toast('没有匹配的内容');
      return;
    }
    // 不区分大小写的整体替换：按匹配区间从后往前拼
    let out: string = this.content;
    for (let k = total - 1; k >= 0; k--) {
      const at: number = this.findMatches[k];
      out = out.substring(0, at) + this.replaceText + out.substring(at + needle.length);
    }
    this.content = out;
    this.dirty = true;
    this.caret = -1;
    this.recomputeMatches();
    this.toast('已替换 ' + total + ' 处');
  }

  /** 跳转到指定行（1 起）：行号 → 字符偏移，光标落上去。 */
  private gotoLine(): void {
    const line: number = parseInt(this.gotoLineText.trim(), 10);
    if (isNaN(line) || line < 1) {
      this.toast('请输入大于 0 的行号');
      return;
    }
    const lines: string[] = this.content.split('\n');
    if (line > lines.length) {
      this.toast('全文共 ' + lines.length + ' 行');
      return;
    }
    let offset: number = 0;
    for (let k = 0; k < line - 1; k++) {
      offset += lines[k].length + 1;
    }
    this.selectRange(offset, offset);
    this.toast('已跳到第 ' + line + ' 行');
  }

  // ══════════════════════ 粘贴图片 ══════════════════════
  //
  // 移植自参考项目的「编辑时粘贴图片 → 存 images/ → 自动插链接」：
  // 拦截 TextArea 的粘贴事件，剪贴板里是图片就落到 docs/images/ 并插入引用；
  // 是文本则不拦截，走系统默认粘贴。

  private onEditorPaste(): void {
    try {
      pasteboard.getSystemPasteboard().getData().then((data: pasteboard.PasteData) => {
        if (data.getRecordCount() === 0) {
          return;
        }
        const record: pasteboard.PasteDataRecord = data.getRecord(0);
        const pixel: image.PixelMap | undefined = record.pixelMap;
        if (pixel === undefined || pixel === null) {
          return; // 文本粘贴交给默认行为
        }
        const packer: image.ImagePacker = image.createImagePacker();
        const opts: image.PackingOption = { format: 'image/png', quality: 100 };
        packer.packToData(pixel, opts).then((buf: ArrayBuffer) => {
          const ctx = this.ctx();
          if (ctx === null) {
            return;
          }
          const rel: string | null = DocStore.saveImageBytes(ctx, buf, '.png');
          if (rel === null) {
            this.toast('图片保存失败');
            return;
          }
          this.insertRaw('\n![粘贴图片](' + rel + ')\n');
          this.toast('已插入 ' + rel);
        }).catch((err: BusinessError) => {
          this.toast('图片编码失败：' + err.message);
        });
      }).catch((err: BusinessError) => {
        // 读不到剪贴板按普通文本粘贴处理
      });
    } catch (err) {
      // 拦截失败走默认粘贴
    }
  }

  // ══════════════════════ 保存与返回 ══════════════════════

  private save(): boolean {
    const ctx = this.ctx();
    if (ctx === null) {
      return false;
    }
    const wanted: string = this.docName.trim();
    if (wanted.length === 0) {
      this.toast('请先填写文档名');
      return false;
    }
    // 只读文档不允许回写（正常入口已隐藏编辑按钮，这里兜底挡住深层路径）
    if (this.docReadOnly && !this.isNew) {
      this.toast('该文档是只读的，先切成「可写」再编辑');
      return false;
    }
    try {
      DocStore.init(ctx);
      if (this.isNew) {
        const meta: DocMeta | null = DocStore.create(ctx, wanted, this.content);
        if (meta === null) {
          this.toast('保存失败：名称非法或已存在同名文档');
          return false;
        }
        this.isNew = false;
        this.originalName = meta.name;
        this.docName = meta.name;
        this.dirty = false;
        this.snapshotAfterSave(ctx);
        this.toast('已保存《' + meta.name + '》');
        return true;
      }
      if (wanted !== this.originalName) {
        if (!DocStore.rename(ctx, this.originalName, wanted)) {
          this.toast('重命名失败：名称非法或已存在同名文档');
          return false;
        }
        this.originalName = DocStore.sanitizeName(wanted);
        this.docName = this.originalName;
      }
      if (!DocStore.update(ctx, this.originalName, this.content)) {
        this.toast('保存失败');
        return false;
      }
      this.dirty = false;
      this.snapshotAfterSave(ctx);
      this.toast('已保存《' + this.originalName + '》');
      return true;
    } catch (err) {
      this.toast('保存失败：' + DocStore.describeError(err as BusinessError));
      return false;
    }
  }

  /** 统一包一层 try/catch：路由返回是被标记「可能抛异常」的接口。 */
  private closePage(): void {
    try {
      if (this.stack !== null) {
        this.stack.pop();
      }
    } catch (err) {
      this.toast('返回失败');
    }
  }

  private goBack(): void {
    if (!this.dirty) {
      this.closePage();
      return;
    }
    this.getUIContext().getPromptAction().showDialog({
      title: '还有未保存的修改',
      message: '离开前要先保存吗？',
      buttons: [
        { text: '取消', color: this.palette().textSecondary },
        { text: '不保存', color: '#FFD93B3B' },
        { text: '保存', color: this.palette().accent }
      ]
    }).then((result) => {
      if (result.index === 0) {
        return;
      }
      if (result.index === 2) {
        if (this.save()) {
          this.closePage();
        }
        return;
      }
      this.closePage();
    }).catch((err: BusinessError) => {
      this.toast('操作失败：' + err.message);
    });
  }

  /** Index 的系统返回拦截发来信号（editorGoBackTick 变化）→ 走与顶栏返回相同的弹窗逻辑。 */
  private onGoBackTick(): void {
    if (this.goBackTick > 0) {
      this.goBack();
    }
  }

  private togglePreview(): void {
    if (!this.preview) {
      try {
        const parsed: MdParseResult = MdParser.parse(this.content);
        this.previewBlocks = parsed.blocks;
      } catch (err) {
        this.previewBlocks = [];
      }
    }
    // 切换包在 animateTo 里：配合两侧的 .transition，预览/编辑互切有淡入淡出 + 轻微缩放
    this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
      this.preview = !this.preview;
    });
  }

  /** 语法浮层的开关。条件挂载包在 animateTo 里，进出场动画才会播放。 */
  private openSyntax(): void {
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.showSyntax = true;
    });
  }

  private closeSyntax(): void {
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.showSyntax = false;
    });
  }

  // ══════════════════════ 顶栏 ══════════════════════

  @Builder
  topBar() {
    ImmersiveBar({ palette: this.palette(), barPaddingH: HwSpace.xs, barPaddingV: HwSpace.xs }) {
      ImmersiveIconButton({
        buttonSize: 34,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          this.goBack();
        }
      }) {
        SymbolGlyph($r('sys.symbol.arrow_left'))
          .fontSize(17)
          .fontColor([this.palette().textPrimary])
      }

      TextInput({ text: this.docName, placeholder: this.isNew ? '给文档起个名字' : '文档名' })
        .layoutWeight(1)
        .fontSize(HwType.label)
        .fontColor(this.palette().textPrimary)
        .placeholderColor(this.palette().textTertiary)
        .backgroundColor('#00000000')
        .padding({ left: HwSpace.sm, right: HwSpace.sm })
        .maxLines(1)
        .onChange((value: string) => {
          this.docName = value;
          this.dirty = true;
        })

      // 三颗按钮包进带间距的 Row：ImmersiveBar 内部 Row 没有 space，会贴在一起
      Row({ space: HwSpace.xs }) {
        // 版本历史（用户要求）：实时预览按钮左边
        ImmersiveIconButton({
          buttonSize: 34,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            this.openVersions();
          }
        }) {
          SymbolGlyph($r('sys.symbol.doc_text_badge_clock'))
            .fontSize(16)
            .fontColor([this.palette().textPrimary])
        }

        ImmersiveIconButton({
          buttonSize: 34,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            this.togglePreview();
          }
        }) {
          SymbolGlyph(this.preview ? $r('sys.symbol.highlighter_line') : $r('sys.symbol.eye'))
            .fontSize(17)
            .fontColor([this.palette().textPrimary])
        }

        ImmersiveIconButton({
          buttonSize: 34,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            this.openFind();
          }
        }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(16)
            .fontColor([this.palette().textPrimary])
        }

        ImmersiveIconButton({
          buttonSize: 34,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            this.save();
          }
        }) {
          SymbolGlyph(this.dirty ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.checkmark_circle'))
            .fontSize(18)
            .fontColor([this.palette().accent])
        }
      }
      .alignItems(VerticalAlign.Center)
    }
  }

  // ══════════════════════ 片段工具条 ══════════════════════

  // ── 工具条边缘淡入淡出 + 模糊（胶囊弧线裁切与视口内缩互斥，改用软过渡）──
  private barScroller: Scroller = new Scroller();
  private barScrollX: number = 0;
  /** 每颗芯片在内容坐标系里的左缘 / 宽度（onAreaChange 实测） */
  private chipLefts: number[] = [];
  private chipWidths: number[] = [];
  /** 每颗芯片的透明度（滚动时逐帧重算） */
  @State chipAlphas: number[] = [];

  /** 工具条横向滚动：更新滚动量并重算边缘淡出。 */
  private onBarScroll(): void {
    this.barScrollX = this.barScroller.currentOffset().xOffset;
    this.updateChipFade();
  }

  /** 记录芯片几何（onAreaChange 实测），随后重算淡出。 */
  private rememberChipGeo(index: number, area: Area): void {
    const lw: Length = area.width;
    if (typeof lw !== 'number' || lw <= 0) {
      return;
    }
    this.chipWidths[index] = lw;
    const px: Position = area.position;
    const lx: Length | undefined = px.x;
    if (typeof lx === 'number') {
      // position.x 相对父 Row；Row 自身还有 30 的左 padding，一并算进内容坐标
      this.chipLefts[index] = lx + 20;
    }
    this.updateChipFade();
  }

  /** 芯片总数（手写 + 插图片 + SNIPPETS）。 */
  private chipCount(): number {
    return 2 + SNIPPETS.length;
  }

  /**
   * 重算每颗芯片的透明度：**按已滑出胶囊边缘的量**淡出（zone = 30vp）。
   * 左侧看芯片右缘 (left+w)、右侧看芯片左缘 (W-left)——
   * 这样静止时贴边 / 出屏一半的芯片不会被整体误淡出。
   */
  private updateChipFade(): void {
    const n: number = this.chipCount();
    const next: number[] = [];
    for (let i = 0; i < n; i++) {
      const cl: number | undefined = this.chipLefts[i];
      const cw: number | undefined = this.chipWidths[i];
      const left: number = (cl === undefined ? 0 : cl) - this.barScrollX;
      const w: number = cw === undefined ? 0 : cw;
      const leftFade: number = (left + w) / 20;
      const rightFade: number = (this.rootWidth - left) / 20;
      const raw: number = Math.min(leftFade, rightFade);
      next.push(Math.max(0, Math.min(1, raw)));
    }
    this.chipAlphas = next;
  }

  /** 指定芯片的透明度（未测量时按 1 处理）。 */
  private chipAlphaAt(index: number): number {
    const a: number | undefined = this.chipAlphas[index];
    return a === undefined ? 1 : a;
  }

  /** 指定芯片的模糊度：越靠近边缘越模糊（淡出 + 模糊 = "融进胶囊"的观感）。 */
  private chipBlurAt(index: number): number {
    return (1 - this.chipAlphaAt(index)) * 6;
  }

  @Builder
  snippetBar() {
    // 边缘处理 = **模糊 + 淡入淡出**（胶囊弧线裁切与视口内缩互斥，弃用）。
    // barPaddingH 保持 0：视口铺满整个胶囊，芯片在滑出过程中透明度/模糊度
    // 按"已滑出胶囊边缘的量"逐帧变化（见上方 chipAlphas 一组方法），
    // 静止时的缩进由 Row 自己的 padding 承担。
    ImmersiveBar({ palette: this.palette(), barPaddingH: 0, barPaddingV: 4, barHeight: HwBar.pill }) {
      Scroll(this.barScroller) {
        Row({ space: HwSpace.xs }) {
        // **手写**（用户要求）：进入独立手写页（Pen Kit 官方 HandwriteComponent 画布），
        // 完成后 PNG 落进 docs/images/、Markdown 片段经 AppStorage 传回，光标处插入
        Column() {
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: '手写',
            chipOnTap: () => {
              this.openSketch();
            }
          }) {
            SymbolGlyph($r('sys.symbol.paintbrush'))
              .fontSize(13)
              .fontColor([this.palette().accent])
          }
        }
        .opacity(this.chipAlphaAt(0))
        .blur(this.chipBlurAt(0))
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.rememberChipGeo(0, newValue);
        })

        // 插入图片：从系统选择器选图，复制进文档图片目录后插入相对引用
        // 注意：ImmersiveChip 带**尾随闭包**，闭包之后不能再链式属性（编译错误），
        // 淡出用的 opacity/blur/onAreaChange 挂在外层包装容器上
        Column() {
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: '插图片',
            chipOnTap: () => {
              this.insertImage();
            }
          }) {
            SymbolGlyph($r('sys.symbol.picture'))
              .fontSize(13)
              .fontColor([this.palette().accent])
          }
        }
        .opacity(this.chipAlphaAt(1))
        .blur(this.chipBlurAt(1))
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.rememberChipGeo(1, newValue);
        })

        ForEach(SNIPPETS, (item: MdSnippet, index: number) => {
          ImmersiveChip({
            palette: this.palette(),
            chipLabel: item.label,
            chipOnTap: () => {
              this.insertSnippet(item);
            }
          })
          .opacity(this.chipAlphaAt(index + 2))
          .blur(this.chipBlurAt(index + 2))
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.rememberChipGeo(index + 2, newValue);
          })
        }, (item: MdSnippet) => item.key)
      }
      // 静止时首/尾芯片**完全落在胶囊直段内**、不与两端弧线重合
      .padding({ left: 20, right: 20 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .onDidScroll(() => {
      // 滚动逐帧重算边缘淡出（透明度 + 模糊）
      this.onBarScroll();
    })
    .width('100%')
    .height(40)
    }
  }

  // ══════════════════════ 底部状态栏 ══════════════════════

  @Builder
  bottomBar() {
    ImmersiveBar({ palette: this.palette(), barPaddingH: HwSpace.md, barPaddingV: HwSpace.xs }) {
      Text(this.stats())
        .fontSize(HwType.caption)
        .fontColor(this.palette().textSecondary)
      Column()
        .layoutWeight(1)
      // 右侧芯片包进带间距的 Row：ImmersiveBar 内部 Row 没有 space，会贴在一起。
      // 保存状态（未保存/新文档/已保存）也做成胶囊，与分屏/语法同一排、同一观感
      Row({ space: HwSpace.xs }) {
        ImmersiveChip({
          palette: this.palette(),
          chipActive: this.dirty,
          chipLabel: this.dirty ? '未保存' : (this.isNew ? '新文档' : '已保存'),
          chipOnTap: () => {
            this.save();
          }
        })

        ImmersiveChip({
          palette: this.palette(),
          chipActive: this.splitMode > 0,
          chipLabel: this.splitMode === 1 ? '上下分屏' : (this.splitMode === 2 ? '左右分屏' : '分屏'),
          chipOnTap: () => {
            this.cycleSplit();
          }
        })

        ImmersiveChip({
          palette: this.palette(),
          chipLabel: '语法',
          chipOnTap: () => {
            this.openSyntax();
          }
        }) {
          SymbolGlyph($r('sys.symbol.book'))
            .fontSize(13)
            .fontColor([this.palette().accent])
        }
      }
      .alignItems(VerticalAlign.Center)
    }
  }

  // ══════════════════════ 语法速查 ══════════════════════

  /** 速查行语法 → 解析后的块（按 syntax 缓存，避免每次渲染重复解析） */
  private syntaxBlocks(syntax: string): MdBlock[] {
    const hit: MdBlock[] | undefined = syntaxBlockCache.get(syntax);
    if (hit !== undefined) {
      return hit;
    }
    let out: MdBlock[] = [];
    try {
      out = MdParser.parse(syntax).blocks;
    } catch (err) {
      out = [];
    }
    syntaxBlockCache.set(syntax, out);
    return out;
  }

  /** 版本历史面板：自动保存设置 + 快照列表 / **分屏对比视图**（挂在内层 Row 的 bindSheet 上）。 */
  @Builder
  versionsSheet() {
    if (this.diffFor < 0) {
      // ── 快照列表（竖向滚动）──
      Scroll() {
      Column({ space: HwSpace.md }) {
        // ── 自动保存设置 ──
        Row({ space: HwSpace.sm }) {
          Column({ space: 2 }) {
            Text('自动保存版本')
              .fontSize(HwType.label + 1)
              .fontColor(this.palette().textPrimary)
            Text('按下面的间隔记录快照，内容没变化不重复记')
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Toggle({ type: ToggleType.Switch, isOn: this.versionAutoSave })
            .onChange((isOn: boolean) => {
              this.versionAutoSave = isOn;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.versionAutoSave) {
          Row({ space: HwSpace.xs }) {
            Text('间隔')
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.versionInterval === 1,
              chipLabel: '1 分钟',
              chipOnTap: () => {
                this.versionInterval = 1;
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.versionInterval === 5,
              chipLabel: '5 分钟',
              chipOnTap: () => {
                this.versionInterval = 5;
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.versionInterval === 10,
              chipLabel: '10 分钟',
              chipOnTap: () => {
                this.versionInterval = 10;
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.versionInterval === 30,
              chipLabel: '30 分钟',
              chipOnTap: () => {
                this.versionInterval = 30;
              }
            })
          }
          .width('100%')
        }

        Divider().strokeWidth(1).color(this.palette().divider)

        if (this.versionList.length === 0) {
          Text('还没有快照。手动保存或自动保存后会出现在这里')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')
        }
        ForEach(this.versionList, (v: VersionSnapshot) => {
          Row({ space: HwSpace.sm }) {
            Column({ space: 2 }) {
              Text(this.versionTime(v.ts))
                .fontSize(HwType.label + 1)
                .fontColor(this.palette().textPrimary)
              Text(this.versionMeta(v.ts))
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '对比',
              chipOnTap: () => {
                this.startDiff(v.ts);
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '恢复',
              chipOnTap: () => {
                this.restoreVersion(v.ts);
              }
            })
          }
          .width('100%')
          .padding({ top: HwSpace.xs, bottom: HwSpace.xs })
        }, (v: VersionSnapshot) => 'v' + v.ts)
      }
      .width('100%')
      .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.sm, bottom: HwSpace.lg })
      .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    } else {
      // ── 对比视图（**恢复单栏**，用户要求）：旧快照 vs 当前内容，一行一行带红绿标记 ──
      // ⚠️ 必须有外层 Scroll + Column 包裹：@Builder 多根并列在 bindSheet 里渲染为空白（踩过）
      Scroll() {
      Column({ space: HwSpace.xs }) {
      Row({ space: HwSpace.xs }) {
        ImmersiveChip({
          palette: this.palette(),
          chipLabel: '返回列表',
          chipOnTap: () => {
            this.diffFor = -1;
          }
        })
        Text('红色 = 旧版独有 · 绿色 = 当前独有')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')

      ForEach(this.diffRows, (r: DiffRow, index: number) => {
        Row({ space: HwSpace.xs }) {
          Text(r.tag === 'del' ? '−' : (r.tag === 'add' ? '+' : ' '))
            .fontSize(HwType.caption)
            .fontWeight(FontWeight.Bold)
            .fontColor(r.tag === 'del' ? '#FFD93B3B' : (r.tag === 'add' ? '#FF2E7D4F' : this.palette().textTertiary))
            .width(14)
            .textAlign(TextAlign.Center)
          Text(r.text.length > 0 ? r.text : ' ')
            .fontSize(HwType.caption)
            .fontColor(r.tag === 'same' ? this.palette().textSecondary : this.palette().textPrimary)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: HwSpace.xs, right: HwSpace.xs, top: 3, bottom: 3 })
        .borderRadius(HwRadius.inner)
        .backgroundColor(r.tag === 'del' ? '#1AD93B3B' : (r.tag === 'add' ? '#1A2E7D4F' : '#00000000'))
        .alignItems(VerticalAlign.Top)
      }, (r: DiffRow, index: number) => 'd' + index + '_' + r.tag)
      }
      .width('100%')
      .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.sm, bottom: HwSpace.lg })
      .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    }
  }

  /** 快照条目的副标题：N 字 + 相对上一条（更旧的）快照的行数增减。 */
  private versionMeta(ts: number): string {
    let out: string = '';
    let cur: VersionSnapshot | null = null;
    let older: VersionSnapshot | null = null;
    for (let k = 0; k < this.versionList.length; k++) {
      if (this.versionList[k].ts === ts) {
        cur = this.versionList[k];
        if (k + 1 < this.versionList.length) {
          older = this.versionList[k + 1];
        }
        break;
      }
    }
    if (cur !== null) {
      out += cur.chars + ' 字';
    }
    if (cur !== null && older !== null) {
      const curLines: number = cur.content.split('\n').length;
      const olderLines: number = older.content.split('\n').length;
      const delta: number = curLines - olderLines;
      if (delta > 0) {
        out += ' · +' + delta + ' 行';
      } else if (delta < 0) {
        out += ' · −' + (-delta) + ' 行';
      }
    }
    return out;
  }

  /** bindSheet 的内容包装：语法速查整页滚动。
   *  **左右内边距 + 底部留白**：之前内容铺满整宽，卡片直接贴到屏幕边缘
   *  （用户反馈）；底部留白避免最后一张卡被手势条 / 面板圆角压住。 */
  @Builder
  syntaxSheet() {
    Scroll() {
      Column() {
        this.syntaxPanel()
      }
      .width('100%')
      .padding({
        left: HwSpace.lg,
        right: HwSpace.lg,
        top: HwSpace.sm,
        bottom: HwSpace.xl
      })
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  @Builder
  syntaxPanel() {
    // 标题栏由 ModalSheet 官方标题区提供，这里只输出语法行内容。
    Column({ space: HwSpace.md }) {
        // **操作提示放在内容里**：官方标题栏的副标题在手机端只有一行、
        // 长句会被截断（用户反馈「看不到全部内容」）——这里完整显示。
        Text('点任意一行即可插入到光标位置；末尾的「语法教程」有完整示例。')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .lineHeight(HwType.caption * 1.6)
          .width('100%')

        // 语法口径与示例说明的参考来源（用户要求注明）
        Text('语法分类与说明参考：younghz/Markdown（github.com/younghz/Markdown），' +
          '并按澄笺支持的范围补充了提示块 / 脚注 / 公式 / 图表等扩展语法。')
          .fontSize(HwType.caption - 0.5)
          .fontColor(this.palette().textTertiary)
          .lineHeight(HwType.caption * 1.6)
          .width('100%')
          .padding(HwSpace.xs)
          .borderRadius(HwRadius.inner)
          .backgroundColor(this.palette().quoteBg)

        ForEach(SYNTAX_ROWS, (row: SyntaxRow, index: number) => {
          Column({ space: HwSpace.xxs }) {
            Text(row.syntax)
              .fontSize(HwType.label)
              .fontColor(this.palette().accent)
              .width('100%')
            Text(row.desc)
              .fontSize(HwType.caption)
              .fontColor(this.palette().textSecondary)
              .lineHeight(HwType.caption * 1.6)
              .width('100%')

            // **效果预览**：用应用自己的解析器 + 渲染器把该行语法真实渲染出来
            // （解析结果按 syntax 缓存，只解析一次）
            Column({ space: HwSpace.xxs }) {
              Text('效果')
                .fontSize(HwType.caption - 1)
                .fontColor(this.palette().textTertiary)
              ForEach(this.syntaxBlocks(row.syntax), (b: MdBlock) => {
                MdBlockView({
                  block: b,
                  palette: this.palette(),
                  bodySize: HwType.label,
                  lineMul: 1.4,
                  dark: this.isDark()
                })
                .width('100%')
              }, (b: MdBlock) => row.syntax + '_' + b.id)
            }
            .width('100%')
            .padding(HwSpace.sm)
            .borderRadius(HwRadius.inline)
            .backgroundColor(this.palette().pageTop)
          }
          .width('100%')
          .padding(HwSpace.sm)
          .borderRadius(HwRadius.inline)
          .backgroundColor(this.palette().quoteBg)
        }, (row: SyntaxRow, index: number) => 's' + index)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
  }

  // （旧 findPanel 大面板已删除：查找替换改为顶栏下方的胶囊浮窗）

  // ══════════════════════ 组装 ══════════════════════

  /** 页面转场：标准滑入/滑出（替代默认交叉淡化——两页半透明叠加会出双影）。 */
  /** 页面转场：标准滑入/滑出（交叉淡化会让两页半透明叠成双影）。 */
  pageTransition() {
    // push：新页从右滑入；旧页向左视差退场
    PageTransitionEnter({ type: RouteType.Push, duration: 300, curve: Curve.FastOutSlowIn })
      .translate({ x: '100%' })
    PageTransitionExit({ type: RouteType.Push, duration: 300, curve: Curve.FastOutSlowIn })
      .translate({ x: '-30%' })
    // pop：本页从左滑回；被返回的页向右退场
    PageTransitionEnter({ type: RouteType.Pop, duration: 280, curve: Curve.FastOutSlowIn })
      .translate({ x: '-30%' })
    PageTransitionExit({ type: RouteType.Pop, duration: 280, curve: Curve.FastOutSlowIn })
      .translate({ x: '100%' })
  }


  // ══════════════════════ 分屏实时预览 ══════════════════════

  /**
   * 编辑区（纯编辑与分屏共用）。
   *
   * **首尾空白跟随页面滚动**（用户要求，不是固定内边距）：
   * `Scroll { 顶部空白 + 自适应高度的 TextArea + 底部空白 }`。
   * SDK 明确语义：TextArea **不设高度时高度随内容自适应**（见 text_area.d.ts：
   * "If the component does not have its height set, it adapts its height to the content"），
   * 所以整块内容只有一个滚动条，两段空白属于内容、跟着一起滑走：
   *   · 初始第一行落在顶栏胶囊下方（不被压住）；
   *   · 滚到最底时最后一行停在底部工具层上方（不被遮挡）；
   *   · 滑动过程中文字从两条悬浮栏底下穿过显示（玻璃透字）。
   */
  @Builder
  editorArea() {
    Scroll() {
      Column() {
        // 顶部空白：随内容滚动（滚上去就让出胶囊区域）
        Column()
          .width('100%')
          .height(this.contentTopInset())

        TextArea({ text: this.content, placeholder: '在这里写 Markdown……' })
          .width('100%')
          // **刻意不设高度 / layoutWeight**：由 TextArea 按内容自适应撑开，
          // 内部不再有第二个滚动条，空白才能真正"跟着滑动"
          .fontSize(this.fontSize * 0.94)
          .fontColor(this.palette().textPrimary)
          .placeholderColor(this.palette().textTertiary)
          .backgroundColor('#00000000')
          .borderRadius(0)
          .padding({ left: this.editorHPad(), right: this.editorHPad() })
          .onChange((value: string) => {
            this.content = value;
            this.dirty = true;
            // 分屏模式下实时刷新预览（纯编辑模式的预览在切换时才解析）
            if (this.splitMode > 0) {
              this.refreshPreviewBlocks();
            }
          })
          .onTextSelectionChange((selectionStart: number, selectionEnd: number) => {
            this.caret = selectionStart;
          })
          .onPaste((value: string, event: PasteEvent) => {
            this.onEditorPaste();
          })

        // 底部空白：随内容滚动（滚到底再往上滑一段，末行离开工具层）
        Column()
          .width('100%')
          .height(this.contentBottomInset())
      }
      .width('100%')
      // 内容不足一屏时也要撑满，且**顶对齐**（Scroll 默认把不足一屏的内容垂直居中）
      .constraintSize({ minHeight: '100%' })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    // **撑满高度**：左右分屏时本组件挂在 Row 里，没有显式高度会被 Row
    // 按内容高居中（用户反馈：分屏预览内容「居中」而非从上往下）。
    // 上下分屏 / 纯预览里 layoutWeight 在主轴优先生效，height('100%') 不冲突。
    .height('100%')
    .align(Alignment.Top)
  }

  /** 预览区（纯预览与分屏共用） */
  @Builder
  previewArea() {
    List({ space: 0 }) {
      // 顶部空白：**随内容滚动**的留白（不是固定 padding）。
      // 与阅读页首屏占位条目同款：初始第一块落在顶栏胶囊下方，
      // 滑走之后正文占满胶囊区域、从顶栏底下穿过显示
      ListItem() {
        Column()
          .width('100%')
          .height(this.contentTopInset())
      }

      ForEach(this.previewBlocks, (block: MdBlock) => {
        ListItem() {
          MdBlockView({
            block: block,
            palette: this.palette(),
            bodySize: this.fontSize,
            lineMul: this.lineMul
          })
        }
      }, (block: MdBlock) => 'p_' + block.id + '_' + this.renderEpoch)
      ListItem() {
        Text('—— 预览结束 ——')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .width('100%')
          .textAlign(TextAlign.Center)
          // 文末留白放在条目自身（与阅读页一致）：List 的 padding 是裁剪边界，
          // 留白必须属于内容才跟着滑动；滚到最底时末行停在底部工具层上方
          .padding({ top: HwSpace.xl, bottom: this.contentBottomInset() })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    // **撑满高度**：左右分屏时挂在 Row 里，内容不足一屏会被居中（同上）；
    // List 撑满后内容天然从顶部往下排（用户反馈）
    .height('100%')
    .alignListItem(ListItemAlign.Start)
    .padding({ left: this.editorHPad(), right: this.editorHPad() })
  }

  /** 解析当前内容供预览区渲染 */
  private refreshPreviewBlocks(): void {
    try {
      const parsed: MdParseResult = MdParser.parse(this.content);
      this.previewBlocks = parsed.blocks;
    } catch (err) {
      this.previewBlocks = [];
    }
  }

  /** 分屏模式：0 纯编辑/预览 1 上下 2 左右。进入分屏时立即解析一次。 */
  private cycleSplit(): void {
    this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
      // 分屏顺序（用户要求）：纯编辑 → **左右分屏** → 上下分屏 → 纯编辑
      this.splitMode = this.splitMode === 0 ? 2 : (this.splitMode === 2 ? 1 : 0);
    });
    if (this.splitMode > 0) {
      this.refreshPreviewBlocks();
      // 分屏时退出纯预览态，编辑区必须可见
      this.preview = false;
    }
  }

  /** 背景光斑缓慢漂移（与阅读页同款：无限往复、时长错开） */
  private startBlobDrift(): void {
    this.getUIContext().animateTo({
      duration: 15000, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate
    }, () => {
      this.blobAX = 64;
      this.blobAY = 42;
    });
    this.getUIContext().animateTo({
      duration: 20000, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate
    }, () => {
      this.blobBX = -52;
      this.blobBY = -58;
    });
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 背景：**与阅读页完全同一套优先级与遮罩**——
      //   ① 阅读背景图 → ② 阅读背景样式（readerBgId）→ ③ 外观壁纸
      //   → ④ 函数壁纸 → ⑤ 自定义背景色 → ⑥ 主题渐变
      // 每层都压与阅读页同浓度的可读性遮罩，两个页面观感一致
      if (this.readerBgPath.length > 0) {
        Image(WallpaperStore.imageSourceOf(this.readerBgPath))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(this.wallpaperBlur)

        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.isDark()))
      } else if (this.readerBgId.length > 0) {
        GenWallpaper({ styleId: this.readerBgId, darkMode: this.isDark() })

        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.isDark()))
      } else if (this.wallpaperPathEffective().length > 0) {
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

      // 光斑两团（与阅读页同款）：**有图片壁纸 / 阅读背景图时不再绘制**（用户要求）
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

      Row() {
        Column() {
          if (this.splitMode === 1) {
            // 上下分屏：上编辑下预览，改动实时刷新
            Column({ space: HwSpace.xs }) {
              this.editorArea()
              this.previewArea()
            }
            .width('100%')
            .layoutWeight(1)
          } else if (this.splitMode === 2) {
            // 左右分屏：左编辑右预览
            Row({ space: HwSpace.xs }) {
              this.editorArea()
              this.previewArea()
            }
            .width('100%')
            .layoutWeight(1)
          } else if (this.preview) {
            this.previewArea()
          } else {
            this.editorArea()
          }

        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .constraintSize({ maxWidth: this.measureWidth() })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      // 版本历史面板：根节点已有语法速查的 bindSheet（一节点只认一条），
      // 这里挂在内容 Row 上（用户要求：顶栏「版本历史」按钮 → 快照列表 / 对比 / 恢复）
      .bindSheet(this.showVersions, this.versionsSheet(), modalSheetOptions({
        title: '版本历史',
        subtitle: this.docName.length > 0 ? '《' + this.docName + '》的编辑快照' : '',
        surface: this.palette().surface,
        phoneLayout: this.rootWidth <= this.rootHeight,
        screenWidth: this.rootWidth,
        onDismiss: () => {
          this.showVersions = false;
        }
      }))

      // ── 悬浮顶栏：材质胶囊，内容从它底下穿过 ──
      Column() {
        this.topBar()
      }
      .width('100%')
      .padding({ left: HwSpace.lg, right: HwSpace.lg, top: this.padTop() })

      // ── 悬浮底部工具层：片段条 + 底栏，固定在键盘之上 ──
      // 页面走系统键盘避让：键盘弹起时整页高度收缩，钉在底部的那层自然抬到键盘上沿
      Stack({ alignContent: Alignment.BottomStart }) {
        Column({ space: HwSpace.xs }) {
          if (!this.preview) {
            this.snippetBar()
          }
          this.bottomBar()
        }
        .width('100%')
        .padding({
          left: HwSpace.lg,
          right: HwSpace.lg,
          bottom: this.keyboardPx > 0 ? 6 : this.padBottom()
        })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)

      // 语法速查：**官方 bindSheet**（居中卡片，高度自适应 + 88% 封顶内滚）
      if (this.showSyntax) {
        // （内容已迁移到根节点的 bindSheet）
      }

      // （画板浮层已删除：手写/画板功能以后重做）

      // 查找替换：**胶囊浮窗**（悬浮在顶栏下方，替代原 52% 底部大面板）
      if (this.showFind) {
        Column({ space: 8 }) {
          // 主胶囊：查找输入 + 匹配数 + 上/下 + 替换开关 + 关闭
          ImmersiveBar({
            palette: this.palette(),
            barPaddingH: HwSpace.sm,
            barPaddingV: 4,
            barHeight: HwBar.pill,
            barWidth: '100%'
          }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(14)
              .fontColor([this.palette().textTertiary])
            TextInput({ text: this.findQuery, placeholder: '查找内容' })
              .layoutWeight(1)
              .height('100%')
              .fontSize(HwType.label)
              .fontColor(this.palette().textPrimary)
              .placeholderColor(this.palette().textTertiary)
              .backgroundColor('#00000000')
              .padding({ left: HwSpace.xs, right: HwSpace.xs, top: 0, bottom: 0 })
              .maxLines(1)
              .onChange((value: string) => {
                this.findQuery = value;
                this.recomputeMatches();
              })
            Text(this.findLabel())
              .fontSize(HwType.caption)
              .fontColor(this.palette().textTertiary)
            ImmersiveIconButton({
              buttonSize: 28,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.stepMatch(-1);
              }
            }) {
              SymbolGlyph($r('sys.symbol.chevron_up'))
                .fontSize(13)
                .fontColor([this.palette().accent])
            }
            // ↑↓ 之间的空隙：漏了这层两颗圆钮会贴在一起
            Column()
              .width(HwSpace.xs)
            ImmersiveIconButton({
              buttonSize: 28,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.stepMatch(1);
              }
            }) {
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(13)
                .fontColor([this.palette().accent])
            }
            // 与「替换」开关之间再留一点空隙
            Column()
              .width(HwSpace.xs)
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.replaceRowOpen,
              chipLabel: this.replaceRowOpen ? '收起' : '替换',
              chipOnTap: () => {
                this.replaceRowOpen = !this.replaceRowOpen;
              }
            })
            // 与关闭钮之间再留一点空隙
            Column()
              .width(HwSpace.xs)
            ImmersiveIconButton({
              buttonSize: 28,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.closeFind();
              }
            }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(13)
                .fontColor([this.palette().textSecondary])
            }
          }
          // 替换胶囊（点「替换」展开）：替换为 + 替换 + 全部替换
          if (this.replaceRowOpen) {
            ImmersiveBar({
              palette: this.palette(),
              barPaddingH: HwSpace.sm,
              barPaddingV: 4,
              barHeight: HwBar.pill,
              barWidth: '100%'
            }) {
              TextInput({ text: this.replaceText, placeholder: '替换为' })
                .layoutWeight(1)
                .height('100%')
                .fontSize(HwType.label)
                .fontColor(this.palette().textPrimary)
                .placeholderColor(this.palette().textTertiary)
                .backgroundColor('#00000000')
                .padding({ left: HwSpace.xs, right: HwSpace.xs, top: 0, bottom: 0 })
                .maxLines(1)
                .onChange((value: string) => {
                  this.replaceText = value;
                })
              ImmersiveChip({
                palette: this.palette(),
                chipLabel: '替换',
                chipOnTap: () => {
                  this.replaceCurrent();
                }
              })
              ImmersiveChip({
                palette: this.palette(),
                chipLabel: '全部替换',
                chipOnTap: () => {
                  this.replaceAll();
                }
              })
            }
            // 跳转行胶囊（与替换一起收纳）
            ImmersiveBar({
              palette: this.palette(),
              barPaddingH: HwSpace.sm,
              barPaddingV: 4,
              barHeight: HwBar.pill,
              barWidth: '100%'
            }) {
              TextInput({ text: this.gotoLineText, placeholder: '行号' })
                .layoutWeight(1)
                .height('100%')
                .fontSize(HwType.label)
                .fontColor(this.palette().textPrimary)
                .placeholderColor(this.palette().textTertiary)
                .backgroundColor('#00000000')
                .padding({ left: HwSpace.xs, right: HwSpace.xs, top: 0, bottom: 0 })
                .maxLines(1)
                .type(InputType.Number)
                .onChange((value: string) => {
                  this.gotoLineText = value;
                })
              ImmersiveChip({
                palette: this.palette(),
                chipLabel: '跳转到行',
                chipOnTap: () => {
                  this.gotoLine();
                }
              })
            }
          }
        }
        .width('100%')
        .padding({
          top: this.contentTopInset() + 4,
          // **与顶部悬浮胶囊对齐**：顶栏胶囊容器左右内边距是 lg，
          // 查找胶囊原来用 sm，平板上查找条比胶囊长出一截（用户反馈）
          left: HwSpace.lg,
          right: HwSpace.lg
        })
      }
    }
    .width('100%')
    .height('100%')
    // 语法速查：**官方规范半模态面板**（material/ModalSheet.ets：模态型 + MEDIUM 高
    // + 官方标题栏 / 关闭按钮 / 拖拽条，内部滚动）
    .bindSheet(this.showSyntax, this.syntaxSheet(), modalSheetOptions({
      title: 'Markdown 语法速查',
      subtitle: '点任意一行即可插入到光标位置',
      surface: this.palette().surface,
      // 竖屏（含平板竖屏）按手机形态出底部面板；平板竖屏宽度收一半
      phoneLayout: this.rootWidth <= this.rootHeight,
      screenWidth: this.rootWidth,
      onDismiss: () => {
        this.showSyntax = false;
      }
    }))
    // 根节点铺满整个窗口（含状态栏与手势条区域），避让由 padTop / padBottom 统一负责
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(this.palette().pageBottom)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      // Area.width / height 的类型是 Length（number | string | Resource），必须收窄后再用
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
}
