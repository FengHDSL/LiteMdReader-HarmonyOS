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
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { MdParseResult } from '../markdown/MdTypes';
import { MdParser } from '../markdown/MdParser';
import { SettingsMirror } from './SettingsMirror';
import { WritingLog } from './WritingLog';

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
  /** 「澄笺」文件夹的一次性播种标记（把两本内置教程收进文件夹，只做一次） */
  seededFolder?: boolean;
}

/**
 * 路由参数：书架 → 阅读页 / 编辑页。
 * 放在数据层而不是页面文件里，避免页面之间互相 import 造成循环依赖。
 * `query` 可选：全库搜索跳进来时带上搜索词，阅读页自动打开查找并定位首个命中。
 */
export interface ReaderRoute {
  name: string;
  query?: string;
}

/** 全库搜索的一条命中 */
export interface DocSearchHit {
  /** 文档名 */
  name: string;
  /** 命中上下文片段（首尾各留一段正文） */
  snippet: string;
  /** 该文档内的命中次数 */
  count: number;
  /** 是否内置文档 */
  builtin: boolean;
  /** 修改时间，用于结果排序 */
  mtime: number;
}

/** 文件时间（毫秒；0 = 取不到） */
export interface DocTimes {
  created: number;
  modified: number;
}

export class DocStore {
  /** 内置文档清单（展示名 + rawfile），常驻书架最前。
   *  coverColor = 预置封面色（用户要求：教程蓝、示例绿；用户改封面会覆盖此值）。 */
  static readonly BUILTINS: DocBuiltin[] = [
    { name: 'Markdown 语法教程', raw: 'README.md', coverColor: '#5B7FBF' },
    { name: '澄笺示例 · 全功能演示', raw: 'chengjian.md', coverColor: '#4E8E7E' }
  ];
  /** 兼容旧引用：第一个内置文档名 */
  static readonly BUILTIN_NAME: string = 'Markdown 语法教程';
  static readonly BUILTIN_RAW: string = 'README.md';
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
    // **首次启动**：把两本内置教程收进「澄笺」文件夹（一次性，之后可自行解散）
    DocStore.seedChengjianFolder();
  }

  /** 把两本内置教程收进「澄笺」文件夹（只做一次；被隐藏的内置文档不参与）。 */
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
        // ⚠️ **builtin 必须保留在 docs 里**：这段过滤的本意是清掉"md 文件已删"的
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
      out.push(alive[k]);
    }

    if (alive.length !== DocStore.docs.length) {
      DocStore.docs = alive;
      DocStore.persist();
    }
    return out;
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
   */
  static readText(ctx: common.UIAbilityContext, meta: DocMeta): string {
    if (meta.builtin) {
      const override: string = DocStore.pathOf(meta.fileName);
      try {
        if (fs.accessSync(override)) {
          return fs.readTextSync(override, { encoding: 'utf-8' });
        }
      } catch (err) {
        // 覆盖文件读不到就回落 rawfile
      }
      const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync(meta.fileName);
      return util.TextDecoder.create('utf-8').decodeToString(bytes);
    }
    return fs.readTextSync(DocStore.pathOf(meta.fileName), { encoding: 'utf-8' });
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
    const name: string = DocStore.sanitizeName(rawName);
    if (name.length === 0 || DocStore.isBuiltinName(name)) {
      return null;
    }
    if (DocStore.exists(ctx, name)) {
      return null;
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
  static searchAll(ctx: common.UIAbilityContext, rawQuery: string): DocSearchHit[] {
    DocStore.init(ctx);
    const query: string = rawQuery.trim();
    if (query.length === 0) {
      return [];
    }
    const needle: string = query.toLowerCase();
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
      if (count === 0) {
        continue;
      }
      const head: number = firstAt > 32 ? firstAt - 32 : 0;
      const tail: number = firstAt + needle.length + 32;
      let snippet: string = text.substring(head, tail > text.length ? text.length : tail);
      snippet = snippet.replace(/[\r\n]+/g, ' ');
      const hit: DocSearchHit = {
        name: meta.name,
        snippet: (head > 0 ? '…' : '') + snippet + (tail < text.length ? '…' : ''),
        count: count,
        builtin: meta.builtin,
        mtime: meta.mtime
      };
      hits.push(hit);
    }
    hits.sort((a: DocSearchHit, b: DocSearchHit) => {
      if (a.count !== b.count) {
        return b.count - a.count;
      }
      return b.mtime - a.mtime;
    });
    return hits;
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
      ? err.message : '未知错误';
  }
}
