/**
 * LiteMdReader · 文档库（书架的数据层）
 * ======================================
 *
 * 存储布局（全部落在应用沙箱内，无需任何权限）：
 *   <filesDir>/docs/<文档名>.md   用户创建 / 导入的 Markdown 正文
 *   <filesDir>/shelf.json         书架索引：元信息 + 阅读进度 + 最近打开时间
 *
 * 内置语法教程不落盘，直接读 `resources/rawfile/README.md`，但它的**阅读进度**
 * 同样记在索引里，所以「上次读到哪」对内置文档也生效。
 *
 * 索引整体读进内存（文档数量是几十的量级），任何写操作后立即整体落盘——
 * 比逐条维护增量一致得多，也避免半写状态。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { MdParseResult } from '../markdown/MdTypes';
import { MdParser } from '../markdown/MdParser';
import { SettingsMirror } from './SettingsMirror';
import { WritingLog } from './WritingLog';
import { L10n } from './L10n';

/** 书架里的一条文档记录 */
/** Web 阅读器 / 打印路由参数：文档名 + 全文（HTML 在页内构建）；htmlPath 非空时直接打开该文件。 */
export interface PrintRoute {
  docName: string;
  content: string;
  htmlPath: string;
}

export interface DocMeta {
  /** 文档名（不含扩展名），同时作为唯一标识 */
  name: string;
  /** 磁盘文件名 */
  fileName: string;
  /** 是否为内置文档（不可编辑 / 删除 / 重命名） */
  builtin: boolean;
  /** 字节数 */
  size: number;
  /** 修改时间（ms） */
  mtime: number;
  charCount: number;
  wordCount: number;
  headingCount: number;
  /** 上次读到的块下标与整体比例，用于恢复阅读位置 */
  progressIndex: number;
  progressRatio: number;
  /** 最近打开时间，用于排序 */
  lastOpen: number;
  /**
   * 自定义封面底色（#RRGGBB）。空 / 未设置 = 用文档名哈希出的配色。
   * 与 coverImage 同时存在时，图片优先。
   */
  coverColor?: string;
  /** 自定义封面图（相对 docs/ 的路径，如 images/xx.png）。空 = 用程序化封面 */
  coverImage?: string;
  /** 封面上不显示文档名（用户可切换） */
  hideCoverName?: boolean;
  /**
   * 只读标记（用户可切换，见 setReadOnly）。
   * true = 只读：编辑入口禁用、任务勾选框不写盘，其余（阅读 / 批注 / 封面 / 导出）照常。
   * 未设置时按「内置教程只读、自建文档可写」兜底（见 isReadOnly）。
   */
  readOnly?: boolean;
  /** 收藏标记（阅读页信息卡的爱心 / 书架悬浮栏爱心快速查看） */
  starred?: boolean;
  /** 收藏时间（毫秒；列表按它倒序，还能显示「收藏日期」） */
  starredAt?: number;
  /**
   * ── Front Matter 提取结果（文首 `---` 之间的元数据）──
   *
   * 存在这里的理由：封面显示名 / 封面色 / 日期都靠它，而**每次渲染书架都去读正文
   * 文件是不可接受的**（几百篇文档 = 几百次磁盘读）。所以解析一次就缓存在索引里，
   * 用 `fmAt`（= 解析时的 mtime）判断是否过期，正文一改动自然重算。
   */
  /** `title:` 指定的显示名（空 = 用文件名） */
  fmTitle?: string;
  /** `cover:` / `color:` 指定的封面色（#RRGGBB） */
  fmColor?: string;
  /** `date:` 指定的日期文案（原样显示，如 2026-10-06） */
  fmDate?: string;
  /** `tags:` 指定的标签（已按逗号 / 顿号拆开） */
  fmTags?: string[];
  /** 上次提取 Front Matter 时的 mtime（等于当前 mtime 说明缓存有效） */
  fmAt?: number;
}

/** 文件实况信息（信息卡展示用）：磁盘字节数 + 正文 MD5。 */
export interface DocFileInfo {
  sizeBytes: number;
  md5: string;
  /** SHA-256（信息卡的「文件哈希」行；算不出时为空串） */
  sha256: string;
}

/** 书架文件夹（参考华为笔记的拖拽归组）：只做归组，不移动磁盘文件 */
export interface ShelfFolder {
  name: string;
  /** 文件夹内的文档名列表 */
  docs: string[];
  /** 自定义文件夹底色（#RRGGBB）；空 = 主题默认 */
  coverColor?: string;
  /** 自定义文件夹封面图（相对 docs/ 的路径） */
  coverImage?: string;
  /** 文件夹格上不显示名称 */
  hideCoverName?: boolean;
}

/** 内置文档条目 */
export interface DocBuiltin {
  name: string;
  raw: string;
  /** 预置封面色（用户要求：教程蓝 / 示例绿）。用户改封面后以 shelf.json 为准 */
  coverColor?: string;
}

/**
 * 索引文件的反序列化结构
 */
interface ShelfIndex {
  docs: DocMeta[];
  folders?: ShelfFolder[];
  /**
   * 书架统一排序：`F|<文件夹名>` / `D|<文档名>` 的列表。
   * 文件夹与松散文档**排在同一条流里**，所以「文件夹 ↔ 文档」也能互相换位。
   * 缺失 / 新增的条目由 normalizeOrder() 兜底补齐（老索引无此字段也能平滑升级）。
   */
  order?: string[];
  /** 被用户删掉的内置教程名（内置文档不落盘，只能用这份名单"删"；设置页可一键恢复） */
  hiddenBuiltins?: string[];
  /** 「澄笺」文件夹的一次性播种标记（把内置教程收进文件夹，只做一次；老安装新增的内置文档会以散件出现，可手动拖入） */
  seededFolder?: boolean;
}

/**
 * 路由参数：书架 → 阅读页 / 编辑页。
 * 放在数据层而不是页面文件里，避免页面之间互相 import 造成循环依赖。
 * `query` 可选：全库搜索跳进来时带上搜索词，阅读页自动打开查找并定位首个命中。
 */
export interface ReaderRoute {
  /** 文档名（阅读页 = 要打开的文档；编辑页 = 要编辑的文档）。从模板新建时不传（seed 携带内容）。 */
  name?: string;
  query?: string;
  /**
   * 「全部待办」点条目进来时要定位的**原文行号**（1 起）。
   * 阅读页首帧布局完成后按行号找块并滚动过去（见 Reader.routeFocusLine）。
   */
  focusLine?: number;
  /**
   * 是否从「全部待办」面板进来。
   * true = 退出阅读页后自动回到该面板（用户反馈"退出文件时返回全部待办页面"）。
   */
  fromTasks?: boolean;
  /**
   * 从模板新建：模板正文经路由传给编辑器（**不提前落盘**）——
   * 否则编辑页点「直接离开 / 不保存」也会留下一篇已创建的文档（用户反馈修复）。
   */
  seed?: string;
}

/** 全库搜索的一条命中 */
export interface DocSearchHit {
  /** 文档名 */
  name: string;
  /** 命中上下文片段（首尾各留一段正文） */
  snippet: string;
  /** 该文档内的命中次数（文件名命中为 0） */
  count: number;
  /** 是否内置文档 */
  builtin: boolean;
  /** 修改时间，用于结果排序 */
  mtime: number;
  /** 文档字节数（结果行里显示大小） */
  size: number;
  /** 'name' = 文件名命中；'content' = 正文命中（两类**分开展示**，用户要求） */
  kind: string;
  /**
   * 正文片段按关键词切分后的分片：**偶数下标 = 普通文本、奇数下标 = 命中片段**
   * （UI 直接用它做关键词加粗高亮，避免在 ForEach 里再算）
   */
  snippetParts: string[];
}

/** 图片命中（搜索图片文件名）：文档插图 / 手写笔记 */
export interface DocImageHit {
  /** 图片文件名 */
  name: string;
  /** 绝对路径（file:// 由 UI 自己拼） */
  path: string;
  /** 字节数 */
  size: number;
  /** 像素宽（0 = 读取失败，UI 显示「尺寸未知」） */
  width: number;
  /** 像素高（0 = 读取失败） */
  height: number;
}

/** 搜索结果：文件名 / 正文 / 图片 三组（用户要求分开呈现） */
export interface DocSearchResult {
  names: DocSearchHit[];
  contents: DocSearchHit[];
  images: DocImageHit[];
}

/** 文件时间（毫秒；0 = 取不到） */
export interface DocTimes {
  created: number;
  modified: number;
}

export class DocStore {
  /** 内置文档清单（展示名 + rawfile），常驻书架最前。
   *  coverColor = 预置封面色（用户要求：教程蓝、示例绿、能力总览紫；用户改封面会覆盖此值）。
   *  知识图谱 / 待办的演示文档已删除——两个功能用自建文档即可体验，无内置依赖。 */
  static readonly BUILTINS: DocBuiltin[] = [
    { name: L10n.t('Markdown 语法教程'), raw: 'README.md', coverColor: '#5B7FBF' },
    { name: L10n.t('澄笺示例 · 全功能演示'), raw: 'chengjian.md', coverColor: '#4E8E7E' },
    { name: L10n.t('澄笺 · 渲染能力总览'), raw: 'capabilities.md', coverColor: '#7A5FA8' }
  ];
  /** 兼容旧引用：第一个内置文档名 */
  static readonly BUILTIN_NAME: string = 'Markdown 语法教程';
  static readonly BUILTIN_RAW: string = 'README.md';
  /** 内置文档用到的那张插图（`rawfile/builtin/` 下同名，首启释放到 docs/images/） */
  static readonly BUILTIN_IMAGE: string = 'chengjian-icon.png';
  /** 新建文档的默认正文 */
  static readonly NEW_DOC_TEMPLATE: string =
    '# 未命名文档\n\n在「阅读设置」里可以调整字号与行高。\n\n## 支持的全部语法\n\n- **加粗** / *斜体* / ~~删除线~~ / `行内代码`\n- 列表、表格、引用、代码块、脚注、提示块\n\n> 点右上角的「语法」可以查看语法速查表。\n';

  private static dir: string = '';
  private static indexPath: string = '';
  private static docs: DocMeta[] = [];
  private static folders: ShelfFolder[] = [];
  /** 书架统一排序（文件夹 + 松散文档混排），见 ShelfIndex.order */
  private static ord: string[] = [];
  /** 被用户删掉的内置教程（内置文档不落盘，删除 = 记进这份名单；设置页可恢复） */
  private static hiddenBuiltins: string[] = [];
  /** 「澄笺」文件夹是否已播种（一次性） */
  private static seededFolder: boolean = false;
  private static ready: boolean = false;

  /** 排序项前缀：F| = 文件夹，D| = 松散文档 */
  static readonly ORDER_FOLDER: string = 'F|';
  static readonly ORDER_DOC: string = 'D|';

  /**
   * **从磁盘重新载入索引**（备份恢复之后必须调用一次）。
   *
   * 为什么需要：docs / folders / ord 是内存缓存，init() 又有 ready 门闩 ——
   * 恢复完文件后再调 init() 什么都不做，于是回到书架时第一次 list() 就把
   * **恢复前的旧索引** persist() 回 shelf.json：解压进来的文档正文还在磁盘上，
   * 但书架按旧索引显示，重启后看到的还是旧数据（用户反馈的"导入备份没生效"）。
   * 先把内存清空，再按磁盘内容重建，后续任何 persist 写的都是恢复后的状态。
   */
  static reload(ctx: common.UIAbilityContext): void {
    DocStore.docs = [];
    DocStore.folders = [];
    DocStore.ord = [];
    DocStore.hiddenBuiltins = [];
    DocStore.seededFolder = false;
    DocStore.ready = false;
    DocStore.init(ctx);
  }

  /** 初始化。必须在任何其它方法之前调用一次；重复调用是安全的。 */
  static init(ctx: common.UIAbilityContext): void {
    if (DocStore.ready) {
      return;
    }
    DocStore.dir = ctx.filesDir + '/docs';
    DocStore.indexPath = ctx.filesDir + '/shelf.json';
    try {
      if (!fs.accessSync(DocStore.dir)) {
        fs.mkdirSync(DocStore.dir, true);
      }
    } catch (err) {
      // 目录已存在或创建失败都在后续读写时报错，这里不阻断
    }
    DocStore.docs = DocStore.loadIndex();
    DocStore.ready = true;
    // **首次启动**：把内置教程收进「澄笺」文件夹（一次性，之后可自行解散）
    DocStore.seedChengjianFolder();
    // 内置文档用到的插图释放到沙箱（只读 rawfile 里的图片，正文才能用常规 ![]() 引用）
    DocStore.ensureBuiltinImages(ctx);
  }

  /**
   * **内置插图释放**（一次性）：把 `rawfile/builtin/` 下的图片拷进沙箱 `docs/images/`。
   *
   * 为什么需要：内置文档正文存在只读 rawfile 里，而 `resolveImagePath()` 只认沙箱里的
   * `docs/` 与 `docs/images/` 两处 —— 不放一份到沙箱，文档里的 `![](图标.png)` 永远
   * 解析不到（会显示「找不到本地图片文件」）。**已存在就跳过**，所以用户在图片管理里
   * 删掉它之后不会被重新塞回来。
   */
  private static ensureBuiltinImages(ctx: common.UIAbilityContext): void {
    const name: string = DocStore.BUILTIN_IMAGE;
    try {
      const dir: string = DocStore.imagesDirPath();
      const target: string = dir + '/' + name;
      if (fs.accessSync(target)) {
        return;
      }
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync('builtin/' + name);
      const file: fs.File = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      fs.writeSync(file.fd, bytes.buffer);
      fs.closeSync(file);
    } catch (err) {
      // 释放失败不影响使用：文档里那张图会走"找不到本地图片"的占位
    }
  }

  /**
   * **内置内容在沙箱里的残留文件**（绝对路径清单）——备份**打包**时应当跳过。
   * （导入侧不跳：判定要看书架索引，而索引正是备份包要恢复的东西，见 BackupStore。）
   *
   * 为什么会有残留：`update()` 保存正文时无条件写 `docs/<fileName>`，内置文档也不例外；
   * 而 `readText()` 对 builtin 一律回头读应用包里的 rawfile（沙箱那份旧覆盖正文会把
   * 更新后的内置教程压住，所以**故意不读**）。于是 `docs/README.md`、`docs/chengjian.md`、
   * `docs/capabilities.md` 写下去就再没人读；`docs/images/chengjian-icon.png` 同理，
   * 首启会从 rawfile 重新释放一份。
   *
   * 它们能从安装包 100% 复原，却是「备份包里一堆我根本没有的文件」的主要来源
   * （文件名还是英文的，看着像演示文件——它们本来也就是演示文件的死副本）。
   * **用户自建的同名文档不算残留**：那种在索引里 builtin=false，应用真的要读它。
   */
  static builtinResidue(ctx: common.UIAbilityContext): string[] {
    DocStore.init(ctx);
    const out: string[] = [];
    for (let k = 0; k < DocStore.BUILTINS.length; k++) {
      const raw: string = DocStore.BUILTINS[k].raw;
      if (!DocStore.isUserDocFile(raw)) {
        out.push(DocStore.pathOf(raw));
      }
    }
    out.push(DocStore.imagesDirPath() + '/' + DocStore.BUILTIN_IMAGE);
    return out;
  }

  /** 索引里有没有一篇**非内置**文档正用着这个文件名（有就是用户文档，不是残留） */
  private static isUserDocFile(fileName: string): boolean {
    for (let k = 0; k < DocStore.docs.length; k++) {
      if (!DocStore.docs[k].builtin && DocStore.docs[k].fileName === fileName) {
        return true;
      }
    }
    return false;
  }

  /** 把内置教程收进「澄笺」文件夹（只做一次；被隐藏的内置文档不参与）。 */
  private static seedChengjianFolder(): void {
    if (DocStore.seededFolder) {
      return;
    }
    const names: string[] = [];
    for (let b = 0; b < DocStore.BUILTINS.length; b++) {
      if (DocStore.hiddenBuiltins.indexOf(DocStore.BUILTINS[b].name) < 0) {
        names.push(DocStore.BUILTINS[b].name);
      }
    }
    if (names.length < 2) {
      return;
    }
    const folder: ShelfFolder | null = DocStore.createFolderWith(names);
    if (folder !== null) {
      DocStore.renameFolder(folder.name, '澄笺');
    }
    DocStore.seededFolder = true;
    DocStore.persistFolders();
  }

  // ────────────────────────── 文件夹 ──────────────────────────

  /** 文件夹列表（快照）。 */
  static folderList(): ShelfFolder[] {
    const out: ShelfFolder[] = [];
    for (let k = 0; k < DocStore.folders.length; k++) {
      out.push(DocStore.folders[k]);
    }
    return out;
  }

  /** 文档所属文件夹名；不在任何文件夹返回空串。 */
  static folderOfDoc(docName: string): string {
    for (let k = 0; k < DocStore.folders.length; k++) {
      if (DocStore.folders[k].docs.indexOf(docName) >= 0) {
        return DocStore.folders[k].name;
      }
    }
    return '';
  }

  private static persistFolders(): void {
    DocStore.persist();
  }

  /**
   * 把一组文档合并成文件夹（拖 A 到 B 上时传两者）。
   * 名字冲突自动追加 (2)(3)；若被拖文档已在别的文件夹会先从原文件夹移出。
   */
  static createFolderWith(docNames: string[]): ShelfFolder | null {
    let name: string = '新建文件夹';
    let seq: number = 2;
    while (DocStore.folderExists(name)) {
      name = '新建文件夹（' + seq + '）';
      seq++;
      if (seq > 100) {
        return null;
      }
    }
    const folder: ShelfFolder = { name: name, docs: [] };
    for (let k = 0; k < docNames.length; k++) {
      DocStore.detachFromFolders(docNames[k]);
      folder.docs.push(docNames[k]);
    }
    // 统一排序：新文件夹要落在「目标文档」（docNames[0]）原来的位置——
    // 视觉上就是那两张合并成了文件夹，而不是凭空跳到列表末尾。
    // 目标文档自己的条目会随合并被丢弃，所以插入位置要减去它前面的被丢弃项。
    const anchorEntry: string = docNames.length > 0 ? DocStore.ORDER_DOC + docNames[0] : '';
    const anchor: number = anchorEntry.length > 0 ? DocStore.ord.indexOf(anchorEntry) : -1;
    let droppedBefore: number = 0;
    if (anchor > 0) {
      for (let k = 0; k < anchor; k++) {
        for (let j = 0; j < docNames.length; j++) {
          if (DocStore.ord[k] === DocStore.ORDER_DOC + docNames[j]) {
            droppedBefore++;
          }
        }
      }
    }
    DocStore.folders.push(folder);
    DocStore.normalizeOrder();
    const entry: string = DocStore.ORDER_FOLDER + folder.name;
    const at: number = DocStore.ord.indexOf(entry);
    if (at >= 0) {
      DocStore.ord.splice(at, 1);
    }
    let insertAt: number = anchor >= 0 ? anchor - droppedBefore : DocStore.ord.length;
    if (insertAt < 0) {
      insertAt = 0;
    }
    if (insertAt > DocStore.ord.length) {
      insertAt = DocStore.ord.length;
    }
    DocStore.ord.splice(insertAt, 0, entry);
    DocStore.persistFolders();
    return folder;
  }

  /** 把文档加入文件夹（自动从原文件夹移出）。目标不存在返回 false。 */
  static addToFolder(folderName: string, docName: string): boolean {
    const folder: ShelfFolder | null = DocStore.findFolder(folderName);
    if (folder === null || folder.docs.indexOf(docName) >= 0) {
      return false;
    }
    DocStore.detachFromFolders(docName);
    folder.docs.push(docName);
    DocStore.persistFolders();
    return true;
  }

  /** 把文档从文件夹移回书架。 */
  static removeFromFolder(folderName: string, docName: string): boolean {
    const folder: ShelfFolder | null = DocStore.findFolder(folderName);
    if (folder === null) {
      return false;
    }
    const at: number = folder.docs.indexOf(docName);
    if (at < 0) {
      return false;
    }
    folder.docs.splice(at, 1);
    // 移出的文档回到书架顶部，用户立刻看得到
    DocStore.promoteEntry(DocStore.ORDER_DOC + docName);
    // 空文件夹自动解散
    if (folder.docs.length === 0) {
      DocStore.dropFolder(folderName);
    }
    DocStore.persistFolders();
    return true;
  }

  static renameFolder(oldName: string, newName: string): boolean {
    const target: string = DocStore.sanitizeName(newName);
    if (target.length === 0 || DocStore.folderExists(target)) {
      return false;
    }
    const folder: ShelfFolder | null = DocStore.findFolder(oldName);
    if (folder === null) {
      return false;
    }
    folder.name = target;
    // 统一排序里的条目跟着改名，否则换位记录会指向不存在的文件夹
    const ordAt: number = DocStore.ord.indexOf(DocStore.ORDER_FOLDER + oldName);
    if (ordAt >= 0) {
      DocStore.ord[ordAt] = DocStore.ORDER_FOLDER + target;
    }
    DocStore.persistFolders();
    return true;
  }

  /** 解散文件夹：文档全部回到书架顶层，文件夹删除。 */
  static dissolveFolder(folderName: string): boolean {
    const folder: ShelfFolder | null = DocStore.findFolder(folderName);
    if (folder === null) {
      return false;
    }
    const members: string[] = [];
    for (let k = 0; k < folder.docs.length; k++) {
      members.push(folder.docs[k]);
    }
    DocStore.dropFolder(folderName);
    // 回到书架的文档提到最前（倒序插，保持文件夹内的原顺序）
    for (let k = members.length - 1; k >= 0; k--) {
      DocStore.promoteEntry(DocStore.ORDER_DOC + members[k]);
    }
    DocStore.persistFolders();
    return true;
  }

  static folderExists(name: string): boolean {
    return DocStore.findFolder(name) !== null;
  }

  // ────────────────────── 内置教程的「删除 / 恢复」──────────────────────
  //
  // 内置文档的正文来自 rawfile、不落盘，所以「删除」只能是把它记进一份隐藏名单，
  // list() 渲染书架时跳过；设置页「恢复内置教程」清空名单即可复原（数据零风险）。

  /** 该内置文档是否已被用户删除（隐藏）。 */
  static isBuiltinHidden(name: string): boolean {
    return DocStore.hiddenBuiltins.indexOf(name) >= 0;
  }

  /** 删除内置教程（记进隐藏名单）。 */
  static hideBuiltin(ctx: common.UIAbilityContext, name: string): boolean {
    DocStore.init(ctx);
    if (!DocStore.isBuiltinName(name) || DocStore.isBuiltinHidden(name)) {
      return false;
    }
    DocStore.hiddenBuiltins.push(name);
    DocStore.persist();
    return true;
  }

  /** 被删除的内置教程名列表（设置页展示用）。 */
  static hiddenBuiltinList(): string[] {
    const out: string[] = [];
    for (let k = 0; k < DocStore.hiddenBuiltins.length; k++) {
      out.push(DocStore.hiddenBuiltins[k]);
    }
    return out;
  }

  /** 恢复全部内置教程（清空隐藏名单）。返回被恢复的条数。 */
  static restoreBuiltins(ctx: common.UIAbilityContext): number {
    DocStore.init(ctx);
    const n: number = DocStore.hiddenBuiltins.length;
    DocStore.hiddenBuiltins = [];
    DocStore.persist();
    return n;
  }

  /**
   * 把文件夹挪到另一个文件夹的位置（拖拽换位）。
   * 顺序就是 `DocStore.folders` 的数组顺序，落盘后书架按同一顺序渲染。
   */
  static moveFolder(from: string, to: string): boolean {
    if (from === to) {
      return false;
    }
    let fromAt: number = -1;
    let toAt: number = -1;
    for (let k = 0; k < DocStore.folders.length; k++) {
      if (DocStore.folders[k].name === from) {
        fromAt = k;
      }
      if (DocStore.folders[k].name === to) {
        toAt = k;
      }
    }
    if (fromAt < 0 || toAt < 0) {
      return false;
    }
    const moved: ShelfFolder = DocStore.folders[fromAt];
    DocStore.folders.splice(fromAt, 1);
    DocStore.folders.splice(toAt, 0, moved);
    DocStore.persistFolders();
    return true;
  }

  // ────────────────────── 书架统一排序（文件夹 ↔ 文档 可互换位置） ──────────────────────

  /**
   * 归一化排序：丢掉已不存在的条目，把新出现的（新文件夹 / 回到书架的文档）
   * 追加到末尾。老索引里没有 order 字段时也会在这里补出完整顺序。
   */
  private static normalizeOrder(): void {
    const valid: string[] = [];
    for (let k = 0; k < DocStore.folders.length; k++) {
      valid.push(DocStore.ORDER_FOLDER + DocStore.folders[k].name);
    }
    for (let k = 0; k < DocStore.docs.length; k++) {
      const d: DocMeta = DocStore.docs[k];
      if (d.builtin) {
        continue;
      }
      if (DocStore.folderOfDoc(d.name).length === 0) {
        valid.push(DocStore.ORDER_DOC + d.name);
      }
    }
    const kept: string[] = [];
    for (let k = 0; k < DocStore.ord.length; k++) {
      if (valid.indexOf(DocStore.ord[k]) >= 0) {
        kept.push(DocStore.ord[k]);
      }
    }
    for (let k = 0; k < valid.length; k++) {
      if (kept.indexOf(valid[k]) < 0) {
        kept.push(valid[k]);
      }
    }
    DocStore.ord = kept;
  }

  /** 书架统一排序快照（已归一化）：`F|文件夹名` / `D|文档名`。 */
  static shelfOrder(ctx: common.UIAbilityContext): string[] {
    DocStore.init(ctx);
    DocStore.normalizeOrder();
    const out: string[] = [];
    for (let k = 0; k < DocStore.ord.length; k++) {
      out.push(DocStore.ord[k]);
    }
    return out;
  }

  /**
   * 把某条排序项提到最前。
   * 新建 / 导入的文档用它「插到书架最前面」——排序改成人手排之后，
   * 新文档若追加在末尾，书一多就会被顶到屏幕外，看起来像"没保存上"。
   */
  private static promoteEntry(entry: string): void {
    DocStore.normalizeOrder();
    const at: number = DocStore.ord.indexOf(entry);
    if (at >= 0) {
      DocStore.ord.splice(at, 1);
    }
    DocStore.ord.unshift(entry);
  }

  /**
   * 把一条排序项挪到另一条的位置（拖拽换位）。
   * from / to 形如 `F|名字` 或 `D|名字`——**文件夹与文档之间也能互换**，
   * 这就是「文件夹只能和文件夹换位」那条限制的解法。
   */
  /**
   * **交换两篇文档在书架上的位置**（用户要求：拖到另一篇上方悬停 1.5 秒 → 换位）。
   * 两篇都是散文档 → 交换 order 里的位置；同在一个文件夹内 → 交换 folder.docs。
   * 跨文件夹 / 涉及文件夹的换位不支持（返回 false，调用方走原有归组逻辑）。
   */
  static swapShelfDocs(nameA: string, nameB: string): boolean {
    if (nameA === nameB || nameA.length === 0 || nameB.length === 0) {
      return false;
    }
    const ia: number = DocStore.ord.indexOf(DocStore.ORDER_DOC + nameA);
    const ib: number = DocStore.ord.indexOf(DocStore.ORDER_DOC + nameB);
    if (ia >= 0 && ib >= 0) {
      DocStore.ord[ia] = DocStore.ORDER_DOC + nameB;
      DocStore.ord[ib] = DocStore.ORDER_DOC + nameA;
      DocStore.normalizeOrder();
      DocStore.persist();
      return true;
    }
    const fa: string = DocStore.folderOfDoc(nameA);
    if (fa.length > 0 && fa === DocStore.folderOfDoc(nameB)) {
      let folder: ShelfFolder | null = null;
      const flist: ShelfFolder[] = DocStore.folderList();
      for (let k = 0; k < flist.length; k++) {
        if (flist[k].name === fa) {
          folder = flist[k];
          break;
        }
      }
      if (folder === null) {
        return false;
      }
      const pa: number = folder.docs.indexOf(nameA);
      const pb: number = folder.docs.indexOf(nameB);
      if (pa < 0 || pb < 0) {
        return false;
      }
      folder.docs[pa] = nameB;
      folder.docs[pb] = nameA;
      DocStore.persistFolders();
      return true;
    }
    return false;
  }

  static moveShelfEntry(from: string, to: string): boolean {
    if (from === to || from.length === 0 || to.length === 0) {
      return false;
    }
    DocStore.normalizeOrder();
    const fromAt: number = DocStore.ord.indexOf(from);
    const toAt: number = DocStore.ord.indexOf(to);
    if (fromAt < 0 || toAt < 0) {
      return false;
    }
    DocStore.ord.splice(fromAt, 1);
    DocStore.ord.splice(toAt, 0, from);
    DocStore.persist();
    return true;
  }

  // ────────────────────── 封面外观（底色 / 图片 / 是否显示名称） ──────────────────────

  /** 设置封面底色。color 传空串 = 恢复「按名字哈希」的默认配色。 */
  static setCoverColor(ctx: common.UIAbilityContext, kind: string, name: string, color: string): boolean {
    DocStore.init(ctx);
    if (kind === 'folder') {
      const folder: ShelfFolder | null = DocStore.findFolder(name);
      if (folder === null) {
        return false;
      }
      folder.coverColor = color;
      DocStore.persist();
      return true;
    }
    const meta: DocMeta | undefined = DocStore.find(ctx, name);
    // **预置文档也支持改封面**（用户要求）：封面存在 shelf.json 的 builtin meta 上
    if (meta === undefined) {
      return false;
    }
    meta.coverColor = color;
    DocStore.persist();
    return true;
  }

  /** 设置封面图（相对 docs/ 的路径，如 images/xx.png）。空串 = 移除图片、回到程序化封面。 */
  static setCoverImage(ctx: common.UIAbilityContext, kind: string, name: string, image: string): boolean {
    DocStore.init(ctx);
    if (kind === 'folder') {
      const folder: ShelfFolder | null = DocStore.findFolder(name);
      if (folder === null) {
        return false;
      }
      folder.coverImage = image;
      DocStore.persist();
      return true;
    }
    const meta: DocMeta | undefined = DocStore.find(ctx, name);
    // 预置文档同样支持改封面图
    if (meta === undefined) {
      return false;
    }
    meta.coverImage = image;
    DocStore.persist();
    return true;
  }

  /** 封面上是否显示名称（false = 只留图形，图片封面常用）。 */
  static setCoverHideName(ctx: common.UIAbilityContext, kind: string, name: string, hide: boolean): boolean {
    DocStore.init(ctx);
    if (kind === 'folder') {
      const folder: ShelfFolder | null = DocStore.findFolder(name);
      if (folder === null) {
        return false;
      }
      folder.hideCoverName = hide;
      DocStore.persist();
      return true;
    }
    const meta: DocMeta | undefined = DocStore.find(ctx, name);
    // 预置文档同样支持改「显示名称」开关
    if (meta === undefined) {
      return false;
    }
    meta.hideCoverName = hide;
    DocStore.persist();
    return true;
  }

  // ────────────────────── 读写 / 只读（每篇文档一个持久标记） ──────────────────────

  /**
   * 文档是否为只读。
   * 未显式设过 readOnly 时兜底：**内置教程只读、自建 / 导入文档可写**；
   * 用户切过一次（true / false）之后，就以标记为准。
   */
  static isReadOnly(ctx: common.UIAbilityContext, name: string): boolean {
    const meta: DocMeta | undefined = DocStore.find(ctx, name);
    if (meta === undefined) {
      return false;
    }
    const flag: boolean | undefined = meta.readOnly;
    if (flag === undefined) {
      return meta.builtin;
    }
    return flag;
  }

  /**
   * 切换读写 / 只读。只读只锁「改写正文」这条路：
   * 编辑页入口、任务勾选框不写盘；阅读 / 批注 / 封面 / 导出不受影响。
   * 写进 shelf.json（预置文档的标记同样存在这份索引上）。
   */
  static setReadOnly(ctx: common.UIAbilityContext, name: string, readOnly: boolean): boolean {
    DocStore.init(ctx);
    const meta: DocMeta | undefined = DocStore.find(ctx, name);
    if (meta === undefined) {
      return false;
    }
    meta.readOnly = readOnly;
    DocStore.persist();
    return true;
  }

  /**
   * 收藏 / 取消收藏（阅读页信息卡右上角爱心、书架爱心列表共用）。
   * 标记落 shelf.json，正文保存与重命名都会一并搬运（见 update / rename）。
   */
  static setStarred(ctx: common.UIAbilityContext, name: string, starred: boolean): boolean {
    DocStore.init(ctx);
    const meta: DocMeta | undefined = DocStore.find(ctx, name);
    if (meta === undefined) {
      return false;
    }
    meta.starred = starred;
    // 收藏时间：收藏时记下，取消收藏清掉
    meta.starredAt = starred ? Date.now() : 0;
    DocStore.persist();
    // **第二腿持久化**：shelf.json 之外再镜像一份到 settings.json
    //（真机上出现过重启后收藏丢失——多一条腿更稳）
    DocStore.syncStarredMirror(ctx);
    return true;
  }

  /** 把「收藏名单 + 收藏时间」写进 AppStorage 镜像键（SettingsMirror 会落 settings.json）。 */
  private static syncStarredMirror(ctx: common.UIAbilityContext): void {
    const names: string[] = [];
    const times: number[] = [];
    for (let k = 0; k < DocStore.docs.length; k++) {
      const m: DocMeta = DocStore.docs[k];
      if (m.starred === true) {
        names.push(m.name);
        times.push(m.starredAt === undefined ? 0 : m.starredAt);
      }
    }
    AppStorage.setOrCreate('starredDocsJson', JSON.stringify(names));
    AppStorage.setOrCreate('starredTimesJson', JSON.stringify(times));
    SettingsMirror.save(ctx);
  }

  /**
   * 启动时按镜像恢复收藏标记（shelf.json 丢失 / 被覆盖时的兜底）。
   * 在 EntryAbility.onCreate 里 SettingsMirror.restore 之后调用。
   */
  static applyStarredMirror(ctx: common.UIAbilityContext): void {
    DocStore.init(ctx);
    const raw: string | undefined = AppStorage.get<string>('starredDocsJson');
    if (raw === undefined || raw === null || raw.length === 0) {
      return;
    }
    try {
      const names: string[] = JSON.parse(raw) as string[];
      const timesRaw: string | undefined = AppStorage.get<string>('starredTimesJson');
      const times: number[] = (timesRaw === undefined || timesRaw === null || timesRaw.length === 0)
        ? [] : JSON.parse(timesRaw) as number[];
      let changed: boolean = false;
      for (let k = 0; k < names.length; k++) {
        const meta: DocMeta | undefined = DocStore.find(ctx, names[k]);
        if (meta !== undefined && meta.starred !== true) {
          meta.starred = true;
          meta.starredAt = k < times.length ? times[k] : 0;
          changed = true;
        }
      }
      if (changed) {
        DocStore.persist();
      }
    } catch (err) {
      // 镜像损坏不影响启动
    }
  }

  /** 是否已收藏。 */
  static isStarred(ctx: common.UIAbilityContext, name: string): boolean {
    DocStore.init(ctx);
    const meta: DocMeta | undefined = DocStore.find(ctx, name);
    return meta !== undefined && meta.starred === true;
  }

  /**
   * 全部收藏文档。排序（用户要求可调）：
   *   'starred' = 最近收藏在前（默认）/ 'name' = 按名称 / 'recent' = 按最近打开。
   */
  static starredList(ctx: common.UIAbilityContext, sort: string = 'starred'): DocMeta[] {
    DocStore.init(ctx);
    const out: DocMeta[] = [];
    for (let k = 0; k < DocStore.docs.length; k++) {
      if (DocStore.docs[k].starred === true) {
        out.push(DocStore.docs[k]);
      }
    }
    const at = (m: DocMeta): number => m.starredAt === undefined ? 0 : m.starredAt;
    if (sort === 'name') {
      out.sort((a: DocMeta, b: DocMeta): number => a.name.localeCompare(b.name));
    } else if (sort === 'recent') {
      out.sort((a: DocMeta, b: DocMeta): number => b.lastOpen - a.lastOpen);
    } else {
      out.sort((a: DocMeta, b: DocMeta): number => at(b) - at(a));
    }
    return out;
  }

  /**
   * 文件创建 / 修改时间（毫秒）。内置文档没有独立的创建时间，created 返回 0；
   * 取不到一律返回 0，调用方显示「—」。
   */
  static fileTimes(ctx: common.UIAbilityContext, name: string): DocTimes {
    DocStore.init(ctx);
    const meta: DocMeta | undefined = DocStore.find(ctx, name);
    if (meta === undefined) {
      return { created: 0, modified: 0 } as DocTimes;
    }
    if (meta.builtin) {
      return { created: 0, modified: meta.mtime } as DocTimes;
    }
    try {
      const st: fs.Stat = fs.statSync(DocStore.pathOf(meta.fileName));
      return { created: st.ctime * 1000, modified: st.mtime * 1000 } as DocTimes;
    } catch (err) {
      return { created: 0, modified: meta.mtime } as DocTimes;
    }
  }

  private static findFolder(name: string): ShelfFolder | null {    for (let k = 0; k < DocStore.folders.length; k++) {
      if (DocStore.folders[k].name === name) {
        return DocStore.folders[k];
      }
    }
    return null;
  }

  private static detachFromFolders(docName: string): void {
    for (let k = 0; k < DocStore.folders.length; k++) {
      const at: number = DocStore.folders[k].docs.indexOf(docName);
      if (at >= 0) {
        DocStore.folders[k].docs.splice(at, 1);
      }
    }
  }

  private static dropFolder(name: string): void {
    const kept: ShelfFolder[] = [];
    for (let k = 0; k < DocStore.folders.length; k++) {
      if (DocStore.folders[k].name !== name) {
        kept.push(DocStore.folders[k]);
      }
    }
    DocStore.folders = kept;
  }

  /**
   * 书架列表。内置文档永远排第一，其余按「最近打开 → 修改时间」降序。
   * 同时做一次磁盘校正：文件被外部删掉的记录会被剔除。
   */
  static list(ctx: common.UIAbilityContext): DocMeta[] {
    DocStore.init(ctx);
    const out: DocMeta[] = [];
    for (let b = 0; b < DocStore.BUILTINS.length; b++) {
      // 被用户删掉的内置教程不再出现在书架上（设置页可一键恢复）
      if (DocStore.isBuiltinHidden(DocStore.BUILTINS[b].name)) {
        continue;
      }
      out.push(DocStore.refreshBuiltin(ctx, b));
    }

    const alive: DocMeta[] = [];
    for (let k = 0; k < DocStore.docs.length; k++) {
      const d: DocMeta = DocStore.docs[k];
      if (d.builtin) {
        // ⚠️ **builtin 必须保留在索引里**：这段过滤的本意是清掉"md 文件已删"的
        // 用户文档，但之前 builtin 被 continue 排除后，alive.length 永远 ≠ docs.length
        // → 每次 list() 都把 builtin 从索引剔除并落盘 → **预置文档的封面色 / 只读标记 /
        // 阅读进度在下次 list 时全部丢失重置**（用户反馈：改封面色退出就重置）。
        alive.push(d);
        continue;
      }
      if (DocStore.fileExists(DocStore.pathOf(d.fileName))) {
        alive.push(d);
      }
    }
    alive.sort((a: DocMeta, b: DocMeta) => {
      if (a.lastOpen !== b.lastOpen) {
        return b.lastOpen - a.lastOpen;
      }
      return b.mtime - a.mtime;
    });
    for (let k = 0; k < alive.length; k++) {
      // ⚠️ **内置文档在这里不能再输出一次**：它上面已经由 BUILTINS 循环出过一遍，
      // 而索引里也存着同一篇（ensureBuiltin 会把它 push 进 docs），两边都推就会翻倍——
      // 表现为"只内置 2 篇却说共 4 篇"（用户反馈）。索引里留着它是为了存封面色 /
      // 只读标记 / 阅读进度，与"出现在书架上"是两件事。
      if (!alive[k].builtin) {
        out.push(alive[k]);
      }
    }

    if (alive.length !== DocStore.docs.length) {
      DocStore.docs = alive;
      DocStore.persist();
    }
    // 文件夹名单自愈（见 pruneFolders 的说明）：顺手清掉不存在的文档名，
    // 否则「澄笺」文件夹会一直显示 4 篇，而实际只有 2 篇
    DocStore.pruneFolders();
    // Front Matter 缓存补齐（只在缺失 / 正文改动过时读文件，见 ensureFrontMatter）
    DocStore.syncFrontMatter(ctx);
    return out;
  }

  /**
   * 补齐 Front Matter 缓存。
   *
   * 只处理**自建文档**：内置文档正文在应用包里、也不该被元数据改封面。
   * 过期判据是 `fmAt !== mtime` —— 正文一改就重算，没改过一个字节都不读。
   */
  private static syncFrontMatter(ctx: common.UIAbilityContext): void {
    let changed: boolean = false;
    for (let k: number = 0; k < DocStore.docs.length; k++) {
      const meta: DocMeta = DocStore.docs[k];
      if (meta.builtin) {
        continue;
      }
      if (meta.fmAt !== undefined && meta.fmAt === meta.mtime) {
        continue;
      }
      try {
        const text: string = DocStore.readText(ctx, meta);
        DocStore.applyFrontMatter(meta, text);
      } catch (err) {
        // 读不到（文件被外部删了等）：标记为已处理，别每次都重试
        // ArkTS 不鼓励 delete：可选字段一律赋 undefined（判空口径不变）
        meta.fmAt = meta.mtime;
        meta.fmTitle = undefined;
        meta.fmColor = undefined;
        meta.fmDate = undefined;
        meta.fmTags = undefined;
      }
      changed = true;
    }
    if (changed) {
      DocStore.persist();
    }
  }

  /**
   * 把一段正文里的 Front Matter 写进 文档记录（**只认文首**的 `---` 区块）。
   *
   * 认的键：`title`（显示名）、`cover` / `color`（封面色）、`date`（日期文案）、
   * `tags`（标签，逗号 / 顿号分隔，也支持 YAML 的 `- xxx` 列表）。
   */
  private static applyFrontMatter(meta: DocMeta, text: string): void {
    meta.fmAt = meta.mtime;
    meta.fmTitle = undefined;
    meta.fmColor = undefined;
    meta.fmDate = undefined;
    meta.fmTags = undefined;
    const lines: string[] = text.replace(/\r\n?/g, '\n').split('\n');
    if (lines.length < 3 || lines[0].trim() !== '---') {
      return;
    }
    let end: number = -1;
    for (let k: number = 1; k < lines.length && k < 60; k++) {
      const t: string = lines[k].trim();
      if (t === '---' || t === '...') {
        end = k;
        break;
      }
    }
    if (end < 0) {
      return;
    }
    const tags: string[] = [];
    let lastKey: string = '';
    for (let k: number = 1; k < end; k++) {
      const t: string = lines[k].trim();
      if (t.length === 0 || t.startsWith('#')) {
        continue;
      }
      // YAML 列表项：`- xxx` 归给上一个键（tags 常用这种写法）
      if (t.startsWith('- ') && lastKey === 'tags') {
        const piece: string = t.substring(2).trim().replace(/^["']|["']$/g, '');
        if (piece.length > 0) {
          tags.push(piece);
        }
        continue;
      }
      const colon: number = t.indexOf(':');
      if (colon <= 0) {
        continue;
      }
      const key: string = t.substring(0, colon).trim().toLowerCase();
      let value: string = t.substring(colon + 1).trim();
      if (value.length >= 2
        && ((value.startsWith('"') && value.endsWith('"'))
          || (value.startsWith('\'') && value.endsWith('\'')))) {
        value = value.substring(1, value.length - 1);
      }
      lastKey = key;
      if (key === 'title' && value.length > 0) {
        meta.fmTitle = value;
      } else if ((key === 'cover' || key === 'color') && DocStore.isHexColor(value)) {
        meta.fmColor = value;
      } else if (key === 'date' && value.length > 0) {
        meta.fmDate = value;
      } else if (key === 'tags') {
        const parts: string[] = value.split(/[,，、]/);
        for (let p: number = 0; p < parts.length; p++) {
          const one: string = parts[p].trim();
          if (one.length > 0) {
            tags.push(one);
          }
        }
      }
    }
    if (tags.length > 0) {
      meta.fmTags = tags;
    }
  }

  /** `#RRGGBB` / `#RGB` 校验（只接受以 # 开头的颜色，避免把 "red" 之类塞进调色板）。 */
  private static isHexColor(v: string): boolean {
    if (!v.startsWith('#')) {
      return false;
    }
    const body: string = v.substring(1);
    if (body.length !== 3 && body.length !== 6) {
      return false;
    }
    for (let k: number = 0; k < body.length; k++) {
      const c: string = body.charAt(k).toLowerCase();
      const isNum: boolean = c >= '0' && c <= '9';
      const isHex: boolean = c >= 'a' && c <= 'f';
      if (!isNum && !isHex) {
        return false;
      }
    }
    return true;
  }

  /** 文档的**显示名**：Front Matter 里有 `title:` 就用它，否则用文件名。 */
  static displayName(meta: DocMeta): string {
    if (meta.fmTitle !== undefined && meta.fmTitle.length > 0) {
      return meta.fmTitle;
    }
    return meta.name;
  }

  /** 文档的**封面色**：用户手动设的优先，其次是 Front Matter 的 `cover:`。 */
  static coverColorOf(meta: DocMeta): string {
    if (meta.coverColor !== undefined && meta.coverColor.length > 0) {
      return meta.coverColor;
    }
    if (meta.fmColor !== undefined && meta.fmColor.length > 0) {
      return meta.fmColor;
    }
    return '';
  }

  /**
   * **文件夹名单自愈**：清掉文件夹里"已经不存在的文档名"并去重。
   *
   * 为什么需要：文件夹只记文档名。内置文档曾从 4 篇减到 2 篇、示例文档也删过，
   * 那些名字会一直留在文件夹里，于是「澄笺」文件夹明明只有 2 篇却显示 4 篇（用户反馈）。
   * 判据：内置名单里的名字一律保留（**即使当前被隐藏**，恢复回书架时还要回到文件夹里），
   * 自建文档必须在索引中且文件仍在。
   */
  private static pruneFolders(): void {
    let changed: boolean = false;
    for (let f = 0; f < DocStore.folders.length; f++) {
      const folder: ShelfFolder = DocStore.folders[f];
      const keep: string[] = [];
      for (let k = 0; k < folder.docs.length; k++) {
        const n: string = folder.docs[k];
        let ok: boolean = false;
        for (let b = 0; b < DocStore.BUILTINS.length; b++) {
          if (DocStore.BUILTINS[b].name === n) {
            ok = true;
            break;
          }
        }
        if (!ok) {
          for (let d = 0; d < DocStore.docs.length; d++) {
            const m: DocMeta = DocStore.docs[d];
            if (!m.builtin && m.name === n && DocStore.fileExists(DocStore.pathOf(m.fileName))) {
              ok = true;
              break;
            }
          }
        }
        if (!ok) {
          continue;
        }
        let dup: boolean = false;
        for (let q = 0; q < keep.length; q++) {
          if (keep[q] === n) {
            dup = true;
            break;
          }
        }
        if (!dup) {
          keep.push(n);
        }
      }
      if (keep.length !== folder.docs.length) {
        folder.docs = keep;
        changed = true;
      }
    }
    if (changed) {
      DocStore.persist();
    }
  }

  /** 按名字取文档记录。 */
  static find(ctx: common.UIAbilityContext, name: string): DocMeta | undefined {
    DocStore.init(ctx);
    for (let b = 0; b < DocStore.BUILTINS.length; b++) {
      if (name === DocStore.BUILTINS[b].name) {
        return DocStore.ensureBuiltin(b);
      }
    }
    for (let k = 0; k < DocStore.docs.length; k++) {
      if (DocStore.docs[k].name === name) {
        return DocStore.docs[k];
      }
    }
    return undefined;
  }

  /**
   * 文件实况信息（信息卡展示）：磁盘字节数 + 正文 MD5（用户要求）。
   * 内置文档不落盘，从 rawfile 读原字节；普通文档 stat + 整读一次。
   * 同步实现（md 文件都是小文件）；任何一步失败返回 null，展示层显示「—」。
   */
  static fileInfo(ctx: common.UIAbilityContext, name: string): DocFileInfo | null {
    DocStore.init(ctx);
    const meta: DocMeta | undefined = DocStore.find(ctx, name);
    if (meta === undefined) {
      return null;
    }
    try {
      let bytes: Uint8Array;
      if (meta.builtin) {
        let raw: string = '';
        for (let b = 0; b < DocStore.BUILTINS.length; b++) {
          if (DocStore.BUILTINS[b].name === name) {
            raw = DocStore.BUILTINS[b].raw;
          }
        }
        if (raw.length === 0) {
          return null;
        }
        bytes = ctx.resourceManager.getRawFileContentSync(raw);
      } else {
        const path: string = DocStore.dir + '/' + meta.fileName;
        const st: fs.Stat = fs.statSync(path);
        const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
        const buf: ArrayBuffer = new ArrayBuffer(st.size);
        fs.readSync(file.fd, buf);
        fs.closeSync(file);
        bytes = new Uint8Array(buf);
      }
      const md: cryptoFramework.Md = cryptoFramework.createMd('MD5');
      md.updateSync({ data: bytes });
      const digest: cryptoFramework.DataBlob = md.digestSync();
      let hex: string = '';
      for (let k = 0; k < digest.data.length; k++) {
        const v: number = digest.data[k];
        hex += (v < 16 ? '0' : '') + v.toString(16);
      }
      // **SHA-256**（信息卡的「文件哈希」行）：与 MD5 一并算出，
      // 避免同一份文件读两遍
      let sha: string = '';
      try {
        const md256: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
        md256.updateSync({ data: bytes });
        const d256: cryptoFramework.DataBlob = md256.digestSync();
        for (let k = 0; k < d256.data.length; k++) {
          const v: number = d256.data[k];
          sha += (v < 16 ? '0' : '') + v.toString(16);
        }
      } catch (shaErr) {
        sha = '';
      }
      const info: DocFileInfo = { sizeBytes: bytes.length, md5: hex, sha256: sha };
      return info;
    } catch (err) {
      return null;
    }
  }

  /**
   * 内部文档链接定位：优先按文档名，其次按磁盘文件名（都忽略大小写）。
   * `./notes/todo.md#anch` 这类链接先剥掉路径与锚点、去掉扩展名再进来找。
   */
  static findByLinkTarget(ctx: common.UIAbilityContext, base: string): DocMeta | undefined {
    DocStore.init(ctx);
    const want: string = base.toLowerCase();
    for (let k = 0; k < DocStore.docs.length; k++) {
      const meta: DocMeta = DocStore.docs[k];
      if (meta.name.toLowerCase() === want || meta.fileName.toLowerCase() === want
        || meta.fileName.toLowerCase() === want + '.md'
        || meta.fileName.toLowerCase() === want + '.markdown') {
        return meta;
      }
    }
    // 内置文档的文件名是 README.md（不落盘），单独兜底
    if (want === 'readme' || want === 'readme.md') {
      return DocStore.find(ctx, DocStore.BUILTIN_NAME);
    }
    return undefined;
  }

  /** 把粘贴 / 打包出的图片字节落进 docs/images/，返回相对引用路径。 */
  static saveImageBytes(ctx: common.UIAbilityContext, bytes: ArrayBuffer, ext: string): string | null {
    DocStore.init(ctx);
    const imgDir: string = DocStore.imagesDirPath();
    try {
      if (!fs.accessSync(imgDir)) {
        fs.mkdirSync(imgDir, true);
      }
    } catch (err) {
      // 目录可能已存在
    }
    let fileName: string = 'paste-' + Date.now() + ext;
    let seq: number = 2;
    while (DocStore.fileExists(imgDir + '/' + fileName)) {
      fileName = 'paste-' + Date.now() + '-' + seq + ext;
      seq++;
      if (seq > 100) {
        return null;
      }
    }
    try {
      const target: fs.File = fs.openSync(imgDir + '/' + fileName,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(target.fd, bytes);
      } finally {
        try {
          fs.closeSync(target);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
    } catch (err) {
      return null;
    }
    return 'images/' + fileName;
  }

  /**
   * 读取文档正文。内置文档走 rawfile，其余走沙箱文件。
   * **预置文档支持修改**（用户要求）：改过一次后正文落在 docs/<fileName>
   * （覆盖文件），读取时优先用覆盖文件，没改过才回落 rawfile。
   * ⚠️ **编码**：默认按 UTF-8 读取；用户可在阅读页「更多」里手动指定
   * （GBK / GB18030 / Big5 / Latin-1）—— 非 UTF-8 文件按 UTF-8 硬解会乱码。
   */
  static readText(ctx: common.UIAbilityContext, meta: DocMeta, encoding: string = 'utf-8'): string {
    const enc: string = encoding.length > 0 ? encoding : 'utf-8';
    if (meta.builtin) {
      // **内置文档始终读应用包内的 rawfile**。
      // 用户实测「内置文档明明更新了、应用里却看不到新内容」：沙箱里残留的旧覆盖文件
      // `docs/<名字>` 会一直优先于 rawfile，把更新后的内容压住。内置文档是只读示例，
      // 这里不再支持"改过即覆盖"——想改内容请新建一份自己的文档。
      const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync(meta.fileName);
      return DocStore.decodeBytesAs(bytes, enc);
    }
    return DocStore.readBytesAs(DocStore.pathOf(meta.fileName), enc);
  }

  /** 按指定编码读文件（读字节 → TextDecoder）；失败回落 UTF-8。 */
  private static readBytesAs(path: string, enc: string): string {
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const st = fs.statSync(path);
      const buf: ArrayBuffer = new ArrayBuffer(st.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      return DocStore.decodeBytesAs(new Uint8Array(buf), enc);
    } catch (err) {
      return '';
    }
  }

  /**
   * 按编码解码字节。
   * · 自动（enc = 'auto'）：有 BOM 按 BOM；否则先按 UTF-8 解，若出现替换符
   *   （U+FFFD，说明不是合法 UTF-8）再按 GB18030 重试 —— 覆盖绝大多数中文文档。
   * · 指定编码：直接用 TextDecoder；失败回落 UTF-8。
   */
  static decodeBytesAs(bytes: Uint8Array, enc: string): string {
    // BOM 优先
    if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
      return DocStore.tryDecode(bytes, 'utf-8');
    }
    if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE) {
      return DocStore.tryDecode(bytes, 'utf-16le');
    }
    if (enc === 'auto') {
      const u: string = DocStore.tryDecode(bytes, 'utf-8');
      // 替换符占比高 → 不是 UTF-8（中文文档按 GB18030 兜底）
      let bad: number = 0;
      for (let k = 0; k < u.length; k++) {
        if (u.charCodeAt(k) === 0xFFFD) {
          bad++;
        }
      }
      if (bad > 0 && bad > u.length / 500) {
        const g: string = DocStore.tryDecode(bytes, 'gb18030');
        return g.length > 0 ? g : u;
      }
      return u;
    }
    return DocStore.tryDecode(bytes, enc);
  }

  /** TextDecoder 解码（失败回落 UTF-8；再失败返回空串）。 */
  private static tryDecode(bytes: Uint8Array, enc: string): string {
    try {
      return util.TextDecoder.create(enc).decodeToString(bytes);
    } catch (err) {
      try {
        return util.TextDecoder.create('utf-8').decodeToString(bytes);
      } catch (err2) {
        return '';
      }
    }
  }

  /** 名字是否为任一内置文档名。 */
  static isBuiltinName(name: string): boolean {
    for (let b = 0; b < DocStore.BUILTINS.length; b++) {
      if (DocStore.BUILTINS[b].name === name) {
        return true;
      }
    }
    return false;
  }

  /** 文档名是否已被占用。 */
  static exists(ctx: common.UIAbilityContext, name: string): boolean {
    return DocStore.find(ctx, name) !== undefined;
  }

  /**
   * 新建文档。名字非法或已存在时返回 null。
   * 内容为空则写入内置模板，避免新文档是一片空白。
   */
  static create(ctx: common.UIAbilityContext, rawName: string, content: string): DocMeta | null {
    DocStore.init(ctx);
    let name: string = DocStore.sanitizeName(rawName);
    if (name.length === 0 || DocStore.isBuiltinName(name)) {
      return null;
    }
    // **同名自动编号**（用户要求）：新建 / 从模板创建遇同名不再直接报失败，
    // 而是自动变成「xx (1)」「xx (2)」……直到找到可用名（上限 100 防呆）。
    // 编号只发生在 create（新建语义）；rename 的同名冲突仍由用户自己改。
    if (DocStore.exists(ctx, name)) {
      let seq: number = 1;
      let candidate: string = name + ' (' + seq + ')';
      while (DocStore.exists(ctx, candidate) && seq < 100) {
        seq++;
        candidate = name + ' (' + seq + ')';
      }
      if (DocStore.exists(ctx, candidate)) {
        return null;
      }
      name = candidate;
    }
    const fileName: string = name + '.md';
    const body: string = content.length > 0 ? content : DocStore.NEW_DOC_TEMPLATE;
    DocStore.writeFile(DocStore.pathOf(fileName), body);
    const meta: DocMeta = DocStore.buildMeta(name, fileName, body, Date.now());
    DocStore.docs.push(meta);
    // **新文档放到书架最后**（用户要求）：排序改成人手排之后，插到最前会把
    // 用户排好的顺序整体推后一位（"打乱排序"）。这里不 promote，
    // normalizeOrder 会把这个新条目追加到顺序表末尾。
    DocStore.persist();
    // 写作日志：新建也算今天有产出
    DocStore.noteWriting(ctx);
    return meta;
  }

  /**
   * 覆盖保存已有文档。
   * **预置文档支持修改**（用户要求）：builtin 也走覆盖保存——正文写到
   * docs/<fileName>（readText 优先读覆盖文件）；builtin 标记保留，
   * 删除 / 重命名依旧受限，恢复 rawfile 原文 = 清掉覆盖文件（暂未暴露入口）。
   */
  static update(ctx: common.UIAbilityContext, name: string, content: string): boolean {
    DocStore.init(ctx);
    const meta: DocMeta | undefined = DocStore.find(ctx, name);
    if (meta === undefined) {
      return false;
    }
    DocStore.writeFile(DocStore.pathOf(meta.fileName), content);
    const rebuilt: DocMeta = DocStore.buildMeta(meta.name, meta.fileName, content, Date.now());
    rebuilt.builtin = meta.builtin;
    rebuilt.progressIndex = meta.progressIndex;
    rebuilt.progressRatio = meta.progressRatio;
    rebuilt.lastOpen = meta.lastOpen;
    // **封面外观要一并保留**：buildMeta 只认识正文统计，不带上这些字段，
    // 不显式搬过来的话，每次保存正文都会把用户设的封面颜色 / 图片 / 名称开关抹掉
    rebuilt.coverColor = meta.coverColor;
    rebuilt.coverImage = meta.coverImage;
    rebuilt.hideCoverName = meta.hideCoverName;
    // 收藏标记同样要跟着走（buildMeta 不认它）；收藏时间一起搬，否则排序会退化
    rebuilt.starred = meta.starred;
    rebuilt.starredAt = meta.starredAt;
    // 读写 / 只读标记同样要跟着走，否则保存一次正文就把只读锁丢了
    rebuilt.readOnly = meta.readOnly;
    DocStore.replace(rebuilt);
    DocStore.persist();
    // **写作日志**：写盘是"今天动过字"的唯一收口，在这里落一条当日快照。
    // 改内置教程不计入（那是预置内容，不是用户产出）。
    if (!rebuilt.builtin) {
      DocStore.noteWriting(ctx);
    }
    return true;
  }

  /**
   * 记一条当日写作快照（供 WritingLog 热力图 / 写作日志页统计）。
   *
   * 记的是**自建文档的累计字数**与**自建文档数**：
   *  - 累计值语义 → 同一天保存多次只覆盖当天那一格，跨天/被杀都不会算错；
   *  - 区间字数由 WritingLog 用"每日累计值求差"还原成当天实际写了多少。
   */
  static noteWriting(ctx: common.UIAbilityContext): void {
    try {
      let words: number = 0;
      let docs: number = 0;
      for (let k = 0; k < DocStore.docs.length; k++) {
        const m: DocMeta = DocStore.docs[k];
        if (m.builtin) {
          continue;
        }
        words += m.wordCount;
        docs++;
      }
      WritingLog.record(ctx, words, docs);
    } catch (err) {
      // 统计失败绝不能影响保存正文
    }
  }

  /** 删除文档。内置文档返回 false。 */
  static remove(ctx: common.UIAbilityContext, name: string): boolean {
    DocStore.init(ctx);
    const meta: DocMeta | undefined = DocStore.find(ctx, name);
    if (meta === undefined || meta.builtin) {
      return false;
    }
    try {
      fs.unlinkSync(DocStore.pathOf(meta.fileName));
    } catch (err) {
      // 文件可能已被外部删除，索引照样要清理
    }
    DocStore.detachFromFolders(name);
    DocStore.drop(name);
    DocStore.persist();
    return true;
  }

  /** 重命名。新名字非法或已存在时返回 false。 */
  static rename(ctx: common.UIAbilityContext, oldName: string, rawNewName: string): boolean {
    DocStore.init(ctx);
    const meta: DocMeta | undefined = DocStore.find(ctx, oldName);
    if (meta === undefined || meta.builtin) {
      return false;
    }
    const newName: string = DocStore.sanitizeName(rawNewName);
    if (newName.length === 0 || newName === oldName || DocStore.isBuiltinName(newName)) {
      return false;
    }
    if (DocStore.exists(ctx, newName)) {
      return false;
    }
    const newFileName: string = newName + '.md';
    try {
      fs.renameSync(DocStore.pathOf(meta.fileName), DocStore.pathOf(newFileName));
    } catch (err) {
      return false;
    }
    const rebuilt: DocMeta = DocStore.buildMeta(newName, newFileName, DocStore.readText(ctx, meta), meta.mtime);
    rebuilt.progressIndex = meta.progressIndex;
    rebuilt.progressRatio = meta.progressRatio;
    rebuilt.lastOpen = meta.lastOpen;
    // 封面外观跟着文档走（同 update()：buildMeta 不带这些字段）
    rebuilt.coverColor = meta.coverColor;
    rebuilt.coverImage = meta.coverImage;
    rebuilt.hideCoverName = meta.hideCoverName;
    // 收藏标记同样要跟着走（buildMeta 不认它）；收藏时间一起搬，否则排序会退化
    rebuilt.starred = meta.starred;
    rebuilt.starredAt = meta.starredAt;
    rebuilt.readOnly = meta.readOnly;
    DocStore.replace(rebuilt);
    // 同步文件夹成员里的旧名字（顺带同步统一排序里的 D| 条目）
    for (let k = 0; k < DocStore.folders.length; k++) {
      const at: number = DocStore.folders[k].docs.indexOf(oldName);
      if (at >= 0) {
        DocStore.folders[k].docs[at] = newName;
      }
    }
    const ordAt: number = DocStore.ord.indexOf(DocStore.ORDER_DOC + oldName);
    if (ordAt >= 0) {
      DocStore.ord[ordAt] = DocStore.ORDER_DOC + newName;
    }
    DocStore.persist();
    return true;
  }

  /**
   * 从外部 URI 导入一份 Markdown 到书架。
   * 名字冲突时自动追加 (2)、(3)……，不覆盖已有文档。
   */
  static importFromUri(ctx: common.UIAbilityContext, uri: string): DocMeta | null {
    DocStore.init(ctx);
    let content: string = '';
    let file: fs.File | null = null;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat: fs.Stat = fs.statSync(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      content = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer));
    } catch (err) {
      return null;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
    }
    const slash: number = uri.lastIndexOf('/');
    let base: string = slash >= 0 ? uri.substring(slash + 1) : uri;
    base = decodeURIComponent(base);
    if (base.endsWith('.markdown')) {
      base = base.substring(0, base.length - 9);
    } else if (base.endsWith('.md')) {
      base = base.substring(0, base.length - 3);
    } else if (base.endsWith('.txt')) {
      base = base.substring(0, base.length - 4);
    }
    let name: string = DocStore.sanitizeName(base);
    if (name.length === 0) {
      name = '导入的文档';
    }
    if (DocStore.isBuiltinName(name)) {
      name = name + '（导入）';
    }
    let candidate: string = name;
    let seq: number = 2;
    while (DocStore.exists(ctx, candidate)) {
      candidate = name + '（' + seq + '）';
      seq++;
      if (seq > 200) {
        return null;
      }
    }
    return DocStore.create(ctx, candidate, content);
  }

  /** 记录阅读进度。 */
  static saveProgress(ctx: common.UIAbilityContext, name: string, blockIndex: number, ratio: number): void {
    const meta: DocMeta | undefined = DocStore.find(ctx, name);
    if (meta === undefined) {
      return;
    }
    meta.progressIndex = blockIndex;
    meta.progressRatio = ratio;
    DocStore.replace(meta);
    DocStore.persist();
  }

  /** 标记最近打开，用于书架排序。 */
  static touch(ctx: common.UIAbilityContext, name: string): void {
    const meta: DocMeta | undefined = DocStore.find(ctx, name);
    if (meta === undefined) {
      return;
    }
    meta.lastOpen = Date.now();
    DocStore.replace(meta);
    DocStore.persist();
  }

  // ────────────────────────── 图片 ═─────────────────────────
  //
  // Markdown 里 `![]()` 的本地图片统一落在 <filesDir>/docs/images/ 下，
  // 与具体文档解耦（两篇文档引用同一张图不会重复占空间）。
  // 删除文档时不清理图片——无法可靠判断图片是否仍被其它文档引用，宁多勿缺。

  /** 文档图片目录。 */
  /** 图片目录（docs/images）：数据管理的图片列表用。 */
  static imagesDirPath(): string {
    return DocStore.dir + '/images';
  }

  /**
   * 从外部 URI 导入一张图片到 docs/images/，返回相对引用路径 `images/<文件名>`。
   * 重名自动追加 (2)、(3)……。扩展名不在白名单时返回 null。
   */
  static importImageFromUri(ctx: common.UIAbilityContext, uri: string): string | null {
    DocStore.init(ctx);
    const imgDir: string = DocStore.imagesDirPath();
    try {
      if (!fs.accessSync(imgDir)) {
        fs.mkdirSync(imgDir, true);
      }
    } catch (err) {
      // 目录可能已存在
    }
    const slash: number = uri.lastIndexOf('/');
    let base: string = slash >= 0 ? uri.substring(slash + 1) : uri;
    base = decodeURIComponent(base);
    const lower: string = base.toLowerCase();
    const exts: string[] = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.svg'];
    let ext: string = '';
    for (let k = 0; k < exts.length; k++) {
      if (lower.endsWith(exts[k])) {
        ext = exts[k];
        break;
      }
    }
    if (ext.length === 0) {
      return null;
    }
    let stem: string = DocStore.sanitizeName(base.substring(0, base.length - ext.length));
    if (stem.length === 0) {
      stem = 'image';
    }
    let fileName: string = stem + ext;
    let seq: number = 2;
    while (DocStore.fileExists(imgDir + '/' + fileName)) {
      fileName = stem + '（' + seq + '）' + ext;
      seq++;
      if (seq > 200) {
        return null;
      }
    }
    let file: fs.File | null = null;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat: fs.Stat = fs.statSync(file.fd);
      // 上限 20MB，防止把书架目录塞爆
      if (stat.size > 20 * 1024 * 1024) {
        return null;
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      const target: fs.File = fs.openSync(imgDir + '/' + fileName,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(target.fd, buffer);
      } finally {
        try {
          fs.closeSync(target);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
    } catch (err) {
      return null;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
    }
    return 'images/' + fileName;
  }

  /**
   * 把 Markdown 里的图片地址解析成 Image 组件可用的源。
   *   http(s)/data:/file://     原样返回（Image 组件直接支持）
   *   相对路径                  依次尝试 <docs>/<src> 与 <docs>/images/<文件名>
   * 解析不到返回空串，渲染层显示占位卡。
   */
  /**
   * 图片地址 → **磁盘绝对路径**（拿不到就返回空串）。
   *
   * 与 `resolveImagePath` 的区别：那个返回 `file://` 前缀给 Image 组件用，
   * 而分享 / 另存为需要真实文件路径（ShareKit 只认路径）。
   */
  static resolveAbsImagePath(src: string): string {
    const uri: string = DocStore.resolveImagePath(src);
    if (uri.length === 0 || !uri.startsWith('file://')) {
      return '';
    }
    return uri.substring('file://'.length);
  }

  static resolveImagePath(src: string): string {
    const s: string = src.trim();
    if (s.length === 0) {
      return '';
    }
    if (s.startsWith('http://') || s.startsWith('https://') || s.startsWith('data:')
      || s.startsWith('file://') || s.startsWith('internal:')) {
      return s;
    }
    let rel: string = s;
    if (rel.startsWith('./')) {
      rel = rel.substring(2);
    }
    if (rel.startsWith('/') || rel.indexOf('..') >= 0) {
      // 绝对路径与越级路径越出沙箱目录，直接拒绝，不做假实现
      return '';
    }
    const dir: string = DocStore.dir;
    const candidates: string[] = [dir + '/' + rel];
    const slashAt: number = rel.lastIndexOf('/');
    const base: string = slashAt >= 0 ? rel.substring(slashAt + 1) : rel;
    candidates.push(DocStore.imagesDirPath() + '/' + base);
    for (let k = 0; k < candidates.length; k++) {
      if (DocStore.fileExists(candidates[k])) {
        return 'file://' + candidates[k];
      }
    }
    return '';
  }

  // ────────────────────────── 全库搜索 ──────────────────────────

  /**
   * 跨文档全文搜索（移植自参考项目的 Ctrl+Shift+F）。
   * 逐文档扫描纯文本（正文是几十 KB 的量级，直接扫足够快），以「出现次数」排序。
   * 片段取首个命中前后各 32 字符，换行折叠成空格。
   */
  static searchAll(ctx: common.UIAbilityContext, rawQuery: string): DocSearchResult {
    DocStore.init(ctx);
    const empty: DocSearchResult = { names: [], contents: [], images: [] };
    const query: string = rawQuery.trim();
    if (query.length === 0) {
      return empty;
    }
    const needle: string = query.toLowerCase();
    const nameHits: DocSearchHit[] = [];
    const hits: DocSearchHit[] = [];
    const names: string[] = [];
    for (let b = 0; b < DocStore.BUILTINS.length; b++) {
      names.push(DocStore.BUILTINS[b].name);
    }
    for (let k = 0; k < DocStore.docs.length; k++) {
      if (!DocStore.docs[k].builtin) {
        names.push(DocStore.docs[k].name);
      }
    }
    for (let k = 0; k < names.length; k++) {
      const meta: DocMeta | undefined = DocStore.find(ctx, names[k]);
      if (meta === undefined) {
        continue;
      }
      let text: string = '';
      try {
        text = DocStore.readText(ctx, meta);
      } catch (err) {
        continue;
      }
      const lower: string = text.toLowerCase();
      let count: number = 0;
      let firstAt: number = -1;
      let from: number = 0;
      while (from <= lower.length) {
        const at: number = lower.indexOf(needle, from);
        if (at < 0) {
          break;
        }
        count++;
        if (firstAt < 0) {
          firstAt = at;
        }
        from = at + needle.length;
      }
      // ① 文件名命中（用户要求）：按修改时间排序即可
      if (meta.name.toLowerCase().indexOf(needle) >= 0) {
        const nameHit: DocSearchHit = {
          name: meta.name,
          snippet: '',
          count: 0,
          builtin: meta.builtin,
          mtime: meta.mtime,
          size: meta.size,
          kind: 'name',
          snippetParts: []
        };
        nameHits.push(nameHit);
      }
      // ② 正文命中
      if (count === 0) {
        continue;
      }
      const head: number = firstAt > 32 ? firstAt - 32 : 0;
      const tail: number = firstAt + needle.length + 32;
      let snippet: string = text.substring(head, tail > text.length ? text.length : tail);
      snippet = snippet.replace(/[\r\n]+/g, ' ');
      const snippetText: string = (head > 0 ? '…' : '') + snippet + (tail < text.length ? '…' : '');
      const hit: DocSearchHit = {
        name: meta.name,
        snippet: snippetText,
        count: count,
        builtin: meta.builtin,
        mtime: meta.mtime,
        size: meta.size,
        kind: 'content',
        snippetParts: DocStore.splitByNeedle(snippetText, query)
      };
      hits.push(hit);
    }
    hits.sort((a: DocSearchHit, b: DocSearchHit) => {
      if (a.count !== b.count) {
        return b.count - a.count;
      }
      return b.mtime - a.mtime;
    });
    nameHits.sort((a: DocSearchHit, b: DocSearchHit) => b.mtime - a.mtime);
    // ③ 图片文件名命中（用户要求：展示图片名称 + 缩略图）
    const imageHits: DocImageHit[] = [];
    try {
      const dir: string = DocStore.imagesDirPath();
      if (fs.accessSync(dir)) {
        const files: string[] = fs.listFileSync(dir);
        for (let k = 0; k < files.length; k++) {
          const nm: string = files[k];
          if (nm.startsWith('.')) {
            continue;
          }
          if (nm.toLowerCase().indexOf(needle) < 0) {
            continue;
          }
          let imgSize: number = 0;
          try {
            imgSize = fs.statSync(dir + '/' + nm).size;
          } catch (statErr) {
            imgSize = 0;
          }
          // 像素尺寸（分辨率）：同步读图片头。**只对已命中的图片读**（前面已按关键词过滤），
          // 避免为整个图片目录付解码开销；损坏 / 非图片文件读失败就留 0，UI 显示「尺寸未知」。
          let imgW: number = 0;
          let imgH: number = 0;
          try {
            const src: image.ImageSource = image.createImageSource(dir + '/' + nm);
            const info: image.ImageInfo = src.getImageInfoSync();
            imgW = info.size.width;
            imgH = info.size.height;
            src.release();
          } catch (dimErr) {
            imgW = 0;
            imgH = 0;
          }
          const imgHit: DocImageHit = {
            name: nm, path: dir + '/' + nm, size: imgSize, width: imgW, height: imgH
          };
          imageHits.push(imgHit);
        }
      }
    } catch (err) {
      // 图片目录不存在 / 读取失败：跳过
    }
    const result: DocSearchResult = { names: nameHits, contents: hits, images: imageHits };
    return result;
  }

  /** 字节数 → 易读文本（B / KB / MB）。 */
  static formatSize(bytes: number): string {
    if (bytes <= 0) {
      return '0 B';
    }
    if (bytes < 1024) {
      return '' + bytes + ' B';
    }
    if (bytes < 1024 * 1024) {
      return (bytes / 1024).toFixed(1) + ' KB';
    }
    return (bytes / (1024 * 1024)).toFixed(2) + ' MB';
  }

  /**
   * 把片段按关键词切成分片：偶数下标 = 普通文本、奇数下标 = 命中片段
   *（UI 据此给关键词加粗高亮）。大小写不敏感，最多切 24 段防超长。
   */
  static splitByNeedle(text: string, needle: string): string[] {
    const parts: string[] = [];
    if (needle.length === 0 || text.length === 0) {
      parts.push(text);
      return parts;
    }
    const lower: string = text.toLowerCase();
    const key: string = needle.toLowerCase();
    let from: number = 0;
    let guard: number = 0;
    while (from < text.length && guard < 24) {
      const at: number = lower.indexOf(key, from);
      if (at < 0) {
        break;
      }
      if (at > from) {
        parts.push(text.substring(from, at));
      }
      parts.push(text.substring(at, at + key.length));
      from = at + key.length;
      guard++;
    }
    if (from < text.length) {
      parts.push(text.substring(from));
    }
    if (parts.length === 0) {
      parts.push(text);
    }
    return parts;
  }

  // ────────────────────────── 内部实现 ──────────────────────────

  /** docs 目录根（打印 HTML 的图片绝对路径拼接用）。init 后才有值。 */
  static docsRoot(): string {
    return DocStore.dir;
  }

  /** 文档正文的沙箱绝对路径（Share Kit 跨设备分享等外部消费者用）。 */
  static docAbsolutePath(ctx: common.UIAbilityContext, meta: DocMeta): string {
    DocStore.init(ctx);
    return DocStore.dir + '/' + meta.fileName;
  }

  private static pathOf(fileName: string): string {
    return DocStore.dir + '/' + fileName;
  }

  private static fileExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (err) {
      return false;
    }
  }

  private static ensureBuiltin(index: number): DocMeta {
    const def: DocBuiltin = DocStore.BUILTINS[index];
    for (let k = 0; k < DocStore.docs.length; k++) {
      if (DocStore.docs[k].builtin && DocStore.docs[k].name === def.name) {
        return DocStore.docs[k];
      }
    }
    const builtin: DocMeta = {
      name: def.name,
      fileName: def.raw,
      builtin: true,
      size: 0,
      mtime: 0,
      charCount: 0,
      wordCount: 0,
      headingCount: 0,
      progressIndex: 0,
      progressRatio: 0,
      lastOpen: 0,
      // 内置教程默认只读（可在书架 / 阅读页的「更多」里切成读写）
      readOnly: true
    };
    // **预置封面色**（用户要求：蓝色 / 绿色）：首次出现时带上，用户改封面后以 shelf.json 为准
    if (def.coverColor !== undefined) {
      builtin.coverColor = def.coverColor;
    }
    // 预置文档默认只读（用户可切「可写」）。显式落一次标记，
    // 免得 isReadOnly() 一直走「未设过」的兜底分支——兜底只是兼容老索引的保险。
    builtin.readOnly = true;
    DocStore.docs.push(builtin);
    return builtin;
  }

  /**
   * 内置文档不落盘，字数等统计项需要现算一次并缓存进索引——
   * 否则书架上它永远显示 0 字。只在统计为空时算，改动索引后落盘。
   */
  private static refreshBuiltin(ctx: common.UIAbilityContext, index: number): DocMeta {
    const def: DocBuiltin = DocStore.BUILTINS[index];
    const builtin: DocMeta = DocStore.ensureBuiltin(index);
    if (builtin.charCount > 0) {
      return builtin;
    }
    try {
      const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync(def.raw);
      const text: string = util.TextDecoder.create('utf-8').decodeToString(bytes);
      builtin.size = text.length;
      const parsed: MdParseResult = MdParser.parse(text);
      builtin.charCount = parsed.charCount;
      builtin.wordCount = parsed.wordCount;
      builtin.headingCount = parsed.headingCount;
      DocStore.replace(builtin);
      DocStore.persist();
    } catch (err) {
      // 读不到内置文档时统计留 0，不影响书架渲染
    }
    return builtin;
  }

  /** 时间戳格式化为「MM-DD HH:mm」；同一天只显示时分。 */
  static formatTime(ms: number): string {
    if (ms <= 0) {
      return '内置';
    }
    const d: Date = new Date(ms);
    const now: Date = new Date();
    const hh: string = DocStore.pad2(d.getHours());
    const mm: string = DocStore.pad2(d.getMinutes());
    if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth()
      && d.getDate() === now.getDate()) {
      return '今天 ' + hh + ':' + mm;
    }
    return DocStore.pad2(d.getMonth() + 1) + '-' + DocStore.pad2(d.getDate()) + ' ' + hh + ':' + mm;
  }

  private static pad2(v: number): string {
    return v < 10 ? '0' + v : '' + v;
  }

  /** 由正文内容构建（或重建）一条元信息，统计项走同一套解析器，保证与阅读页一致。 */
  private static buildMeta(name: string, fileName: string, content: string, mtime: number): DocMeta {
    let charCount: number = 0;
    let wordCount: number = 0;
    let headingCount: number = 0;
    try {
      const parsed: MdParseResult = MdParser.parse(content);
      charCount = parsed.charCount;
      wordCount = parsed.wordCount;
      headingCount = parsed.headingCount;
    } catch (err) {
      // 解析失败不阻断保存，统计留 0
    }
    const meta: DocMeta = {
      name: name,
      fileName: fileName,
      builtin: false,
      size: content.length,
      mtime: mtime,
      charCount: charCount,
      wordCount: wordCount,
      headingCount: headingCount,
      progressIndex: 0,
      progressRatio: 0,
      lastOpen: mtime
    };
    return meta;
  }

  private static replace(meta: DocMeta): void {
    for (let k = 0; k < DocStore.docs.length; k++) {
      if (DocStore.docs[k].name === meta.name) {
        DocStore.docs[k] = meta;
        return;
      }
    }
    DocStore.docs.push(meta);
  }

  private static drop(name: string): void {
    const kept: DocMeta[] = [];
    for (let k = 0; k < DocStore.docs.length; k++) {
      if (DocStore.docs[k].name !== name) {
        kept.push(DocStore.docs[k]);
      }
    }
    DocStore.docs = kept;
  }

  private static writeFile(path: string, content: string): void {
    const file: fs.File =
      fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content);
    } finally {
      try {
        fs.closeSync(file);
      } catch (closeErr) {
        // 关闭失败无副作用
      }
    }
  }

  private static loadIndex(): DocMeta[] {
    const path: string = DocStore.indexPath;
    try {
      if (!fs.accessSync(path)) {
        return [];
      }
      const text: string = fs.readTextSync(path, { encoding: 'utf-8' });
      if (text.length === 0) {
        return [];
      }
      const parsed: ShelfIndex = JSON.parse(text) as ShelfIndex;
      if (parsed === null || parsed === undefined || parsed.docs === undefined) {
        return [];
      }
      if (parsed.folders !== undefined && parsed.folders !== null) {
        DocStore.folders = parsed.folders;
      }
      if (parsed.order !== undefined && parsed.order !== null) {
        DocStore.ord = parsed.order;
      }
      if (parsed.hiddenBuiltins !== undefined && parsed.hiddenBuiltins !== null) {
        DocStore.hiddenBuiltins = parsed.hiddenBuiltins;
      }
      if (parsed.seededFolder === true) {
        DocStore.seededFolder = true;
      }
      return parsed.docs;
    } catch (err) {
      // 索引损坏时按空书架处理，磁盘上的 md 文件不会被删除
      return [];
    }
  }

  private static persist(): void {
    try {
      // 落盘前先归一化排序，保证新文档 / 新文件夹一定在顺序里
      DocStore.normalizeOrder();
      const index: ShelfIndex = {
        docs: DocStore.docs,
        folders: DocStore.folders,
        order: DocStore.ord,
        hiddenBuiltins: DocStore.hiddenBuiltins,
        seededFolder: DocStore.seededFolder
      };
      DocStore.writeFile(DocStore.indexPath, JSON.stringify(index));
    } catch (err) {
      // 落盘失败只是丢排序/进度，不影响正文
    }
  }

  /**
   * 规范化文档名。
   * 去掉路径分隔符与文件系统敏感字符，并去掉首尾空白——
   * 文档名会直接变成磁盘文件名，不能带这些字符。
   */
  static sanitizeName(raw: string): string {
    let s: string = raw.trim();
    const illegal: string = '/\\:*?"<>|';
    let out: string = '';
    for (let k = 0; k < s.length; k++) {
      const c: string = s.charAt(k);
      if (illegal.indexOf(c) >= 0) {
        out = out + '_';
      } else if (c.charCodeAt(0) < 32) {
        out = out + '_';
      } else {
        out = out + c;
      }
    }
    out = out.trim();
    if (out.length > 60) {
      out = out.substring(0, 60);
    }
    if (out === '.' || out === '..') {
      return '';
    }
    return out;
  }

  /** 供界面显示的错误文案。 */
  static describeError(err: BusinessError): string {
    return err.message !== undefined && err.message !== null && err.message.length > 0
      ? err.message : L10n.t('未知错误');
  }
}
