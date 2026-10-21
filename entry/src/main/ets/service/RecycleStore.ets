/**
 * 澄笺 · 回收站（删除内容可找回）
 * ===============================
 *
 * 删除的文档 / 图片 / 批注（含手写批注）先进回收站，支持：
 *   · 恢复（移回原位置 / 写回批注）；
 *   · 单个彻底删除；
 *   · 一键清空（UI 侧弹窗确认后调用）；
 *   · 自动清空（2 / 5 / 7 / 30 天，按删除时间）。
 *
 * 落盘结构：
 *   <filesDir>/recycle/items.json   条目元数据 + purgeDays
 *   <filesDir>/recycle/files/       移入的文件（文档 / 图片原文件）
 *
 * 语义说明：外部导入的文档，用户目录里的**源文件**应用从未触碰；
 * 沙箱内副本移入回收站，彻底删除才真正删除——满足"外部导入不删原文件"。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

/** 回收站条目 */
export interface RecycleItem {
  id: string;
  /** 'doc' | 'image' | 'anno' */
  kind: string;
  /** 列表标题 */
  title: string;
  /** 副标题（来源文档等） */
  sub: string;
  /** 回收站 files/ 内的文件名（doc / image 有；anno 空） */
  fileName: string;
  /** 原始文件名（恢复时移回的目标名） */
  originName: string;
  /** 批注 JSON（kind=anno）；doc 存 lastOpen 等可缺省 */
  payload: string;
  /** 文档正文（kind=doc，恢复时重建） */
  content: string;
  /** 批注所属文档名（恢复写回用） */
  docName: string;
  deletedAt: number;
}

/** items.json 结构 */
interface RecycleFile {
  purgeDays: number;
  items: RecycleItem[];
}

export class RecycleStore {
  private static dir(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/recycle';
  }
  private static filesDir(ctx: common.UIAbilityContext): string {
    return RecycleStore.dir(ctx) + '/files';
  }
  private static metaPath(ctx: common.UIAbilityContext): string {
    return RecycleStore.dir(ctx) + '/items.json';
  }

  private static ensure(ctx: common.UIAbilityContext): void {
    try {
      if (!fs.accessSync(RecycleStore.dir(ctx))) {
        fs.mkdirSync(RecycleStore.dir(ctx), true);
      }
      if (!fs.accessSync(RecycleStore.filesDir(ctx))) {
        fs.mkdirSync(RecycleStore.filesDir(ctx), true);
      }
    } catch (err) {
      // 已存在
    }
  }

  /** 读全部条目 + 自动清空（惰性：每次读取时按 purgeDays 清过期项） */
  static list(ctx: common.UIAbilityContext): RecycleItem[] {
    RecycleStore.ensure(ctx);
    let purgeDays: number = 7;
    let items: RecycleItem[] = [];
    try {
      const path: string = RecycleStore.metaPath(ctx);
      if (fs.accessSync(path)) {
        const text: string = fs.readTextSync(path, { encoding: 'utf-8' });
        if (text.length > 0) {
          const parsed: RecycleFile = JSON.parse(text) as RecycleFile;
          purgeDays = parsed.purgeDays > 0 ? parsed.purgeDays : 7;
          items = parsed.items ?? [];
        }
      }
    } catch (err) {
      return [];
    }
    // **自动清空**：按删除时间过滤，超期项连同文件一起删除
    const keep: RecycleItem[] = [];
    const deadline: number = purgeDays * 24 * 3600 * 1000;
    const now: number = Date.now();
    for (let k = 0; k < items.length; k++) {
      if (now - items[k].deletedAt > deadline) {
        try {
          if (items[k].fileName.length > 0) {
            fs.unlinkSync(RecycleStore.filesDir(ctx) + '/' + items[k].fileName);
          }
        } catch (err) {
          // 文件可能已不在
        }
        continue;
      }
      keep.push(items[k]);
    }
    if (keep.length !== items.length) {
      RecycleStore.saveAll(ctx, purgeDays, keep);
    }
    return keep.slice().sort((a: RecycleItem, b: RecycleItem) => b.deletedAt - a.deletedAt);
  }

  private static saveAll(ctx: common.UIAbilityContext, purgeDays: number, items: RecycleItem[]): void {
    try {
      const file: fs.File = fs.openSync(RecycleStore.metaPath(ctx),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        const data: RecycleFile = { purgeDays: purgeDays, items: items };
        fs.writeSync(file.fd, JSON.stringify(data));
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          // 忽略
        }
      }
    } catch (err) {
      // 写失败只影响列表持久化
    }
  }

  static getPurgeDays(ctx: common.UIAbilityContext): number {
    RecycleStore.list(ctx);
    try {
      const parsed: RecycleFile = JSON.parse(fs.readTextSync(RecycleStore.metaPath(ctx),
        { encoding: 'utf-8' })) as RecycleFile;
      return parsed.purgeDays > 0 ? parsed.purgeDays : 7;
    } catch (err) {
      return 7;
    }
  }

  static setPurgeDays(ctx: common.UIAbilityContext, days: number): void {
    const items: RecycleItem[] = RecycleStore.list(ctx);
    RecycleStore.saveAll(ctx, days, items);
  }

  /** **移入文件**（文档 / 图片）：物理文件移入回收站 files/，返回回收站内文件名。 */
  private static moveIn(ctx: common.UIAbilityContext, originPath: string, originName: string): string {
    RecycleStore.ensure(ctx);
    const recycleName: string = Date.now() + '_' + originName.replace(/[\\/:*?"<>|]/g, '_');
    try {
      const inF = fs.openSync(originPath, fs.OpenMode.READ_ONLY);
      const size: number = fs.statSync(inF.fd).size;
      const buf = new ArrayBuffer(size);
      fs.readSync(inF.fd, buf);
      fs.closeSync(inF.fd);
      const outF = fs.openSync(RecycleStore.filesDir(ctx) + '/' + recycleName,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(outF.fd, buf);
      fs.closeSync(outF.fd);
      fs.unlinkSync(originPath);
      return recycleName;
    } catch (err) {
      // move 失败（跨卷等）退回字节拷贝 + 删源
      try {
        const src = fs.openSync(originPath, fs.OpenMode.READ_ONLY);
        const size: number = fs.statSync(src.fd).size;
        const buf = new ArrayBuffer(size);
        fs.readSync(src.fd, buf);
        fs.closeSync(src.fd);
        const out = fs.openSync(RecycleStore.filesDir(ctx) + '/' + recycleName,
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(out.fd, buf);
        fs.closeSync(out.fd);
        return recycleName;
      } catch (err2) {
        return '';
      }
    }
  }

  /** **移出文件**（恢复）：移回目标路径。 */
  private static moveOut(ctx: common.UIAbilityContext, recycleName: string, target: string): boolean {
    try {
      const src: string = RecycleStore.filesDir(ctx) + '/' + recycleName;
      if (!fs.accessSync(src)) {
        return false;
      }
      try {
        const inF = fs.openSync(src, fs.OpenMode.READ_ONLY);
        const size: number = fs.statSync(inF.fd).size;
        const buf = new ArrayBuffer(size);
        fs.readSync(inF.fd, buf);
        fs.closeSync(inF.fd);
        const outF = fs.openSync(target,
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(outF.fd, buf);
        fs.closeSync(outF.fd);
        fs.unlinkSync(src);
        return true;
      } catch (err) {
        const f = fs.openSync(src, fs.OpenMode.READ_ONLY);
        const size: number = fs.statSync(f.fd).size;
        const buf = new ArrayBuffer(size);
        fs.readSync(f.fd, buf);
        fs.closeSync(f.fd);
        const out = fs.openSync(target,
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(out.fd, buf);
        fs.closeSync(out.fd);
        fs.unlinkSync(src);
        return true;
      }
    } catch (err) {
      return false;
    }
  }

  /** **文档入回收站**（title=显示名；content=正文；metaJson=原 meta 片段）。 */
  static addDoc(ctx: common.UIAbilityContext, title: string, content: string,
                originName: string, metaJson: string): boolean {
    const recycleName: string = RecycleStore.moveIn(ctx, DocStorePath(ctx, originName), originName);
    if (recycleName.length === 0) {
      return false;
    }
    return RecycleStore.push(ctx, {
      id: 'd' + Date.now() + '_' + Math.floor(Math.random() * 1000),
      kind: 'doc', title: title, sub: '', fileName: recycleName,
      originName: originName, payload: metaJson, content: content,
      docName: title, deletedAt: Date.now()
    });
  }

  /** **图片入回收站**（images 目录内的文件移入）。 */
  static addImage(ctx: common.UIAbilityContext, fileName: string): boolean {
    const recycleName: string = RecycleStore.moveIn(ctx, DocStorePath(ctx, fileName), fileName);
    if (recycleName.length === 0) {
      return false;
    }
    return RecycleStore.push(ctx, {
      id: 'i' + Date.now() + '_' + Math.floor(Math.random() * 1000),
      kind: 'image', title: fileName, sub: '', fileName: recycleName,
      originName: fileName, payload: '', content: '', docName: '', deletedAt: Date.now()
    });
  }

  /** **批注入回收站**（payload=完整批注 JSON；hw 手写图一并移入）。 */
  static addAnno(ctx: common.UIAbilityContext, annJson: string, title: string,
                 docName: string, hwRel: string): boolean {
    let recycleHw: string = '';
    if (hwRel.length > 0) {
      // 手写图移入回收站（恢复时移回 images）
      recycleHw = RecycleStore.moveIn(ctx, HwImagePath(ctx, hwRel), hwRel.replace(/^images\//, ''));
    }
    return RecycleStore.push(ctx, {
      id: 'a' + Date.now() + '_' + Math.floor(Math.random() * 1000),
      kind: 'anno', title: title, sub: docName, fileName: recycleHw,
      originName: hwRel, payload: annJson, content: '', docName: docName, deletedAt: Date.now()
    });
  }

  /** 新条目入列 */
  private static push(ctx: common.UIAbilityContext, item: RecycleItem): boolean {
    const items: RecycleItem[] = RecycleStore.list(ctx);
    items.push(item);
    RecycleStore.saveAll(ctx, RecycleStore.getPurgeDays(ctx), items);
    return true;
  }

  /** **恢复**：文档重建、图片移回 images、批注 JSON 原样返回由调用方写回存储。 */
  static restore(ctx: common.UIAbilityContext, id: string): RecycleItem | null {
    const items: RecycleItem[] = RecycleStore.list(ctx);
    let target: RecycleItem | null = null;
    const rest: RecycleItem[] = [];
    for (let k = 0; k < items.length; k++) {
      if (items[k].id === id) {
        target = items[k];
      } else {
        rest.push(items[k]);
      }
    }
    if (target === null) {
      return null;
    }
    RecycleStore.saveAll(ctx, RecycleStore.getPurgeDays(ctx), rest);
    if (target.kind === 'image' && target.fileName.length > 0) {
      RecycleStore.moveOut(ctx, target.fileName, ImagesPath(ctx) + '/' + target.originName);
    }
    if (target.kind === 'anno' && target.fileName.length > 0) {
      // 手写图移回 images
      RecycleStore.moveOut(ctx, target.fileName, ImagesPath(ctx) + '/' + target.originName.replace(/^images\//, ''));
    }
    return target;
  }

  /** **彻底删除单个**（文件一并删除，不可恢复）。 */
  static purgeOne(ctx: common.UIAbilityContext, id: string): void {
    const items: RecycleItem[] = RecycleStore.list(ctx);
    const rest: RecycleItem[] = [];
    for (let k = 0; k < items.length; k++) {
      if (items[k].id === id) {
        try {
          if (items[k].fileName.length > 0) {
            fs.unlinkSync(RecycleStore.filesDir(ctx) + '/' + items[k].fileName);
          }
        } catch (err) {
          // 忽略
        }
        continue;
      }
      rest.push(items[k]);
    }
    RecycleStore.saveAll(ctx, RecycleStore.getPurgeDays(ctx), rest);
  }

  /** **一键清空**。 */
  static purgeAll(ctx: common.UIAbilityContext): void {
    const items: RecycleItem[] = RecycleStore.list(ctx);
    for (let k = 0; k < items.length; k++) {
      try {
        if (items[k].fileName.length > 0) {
          fs.unlinkSync(RecycleStore.filesDir(ctx) + '/' + items[k].fileName);
        }
      } catch (err) {
        // 忽略
      }
    }
    RecycleStore.saveAll(ctx, RecycleStore.getPurgeDays(ctx), []);
  }

  /** 批注恢复：payload JSON 走 AnnotationStore 公共 API 写回（id 加后缀防冲突）。 */
  static restoreAnno(ctx: common.UIAbilityContext, item: RecycleItem): boolean {
    try {
      const ann = JSON.parse(item.payload) as Record<string, Object>;
      ann['id'] = ann['id'] + '_r' + Date.now();
      const list: Array<Record<string, Object>> =
        JSON.parse(fs.readTextSync(AnnoPath(ctx, item.docName), { encoding: 'utf-8' })) as Array<Record<string, Object>>;
      list.push(ann);
      const f: fs.File = fs.openSync(AnnoPath(ctx, item.docName),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, JSON.stringify(list));
      } finally {
        fs.closeSync(f);
      }
      return true;
    } catch (err) {
      return false;
    }
  }
}

/** 文档沙箱路径（DocStore.dir + /docs 由调用方 init；这里独立计算避免耦合） */
function DocStorePath(ctx: common.UIAbilityContext, name: string): string {
  return ctx.filesDir + '/docs/' + name;
}
function ImagesPath(ctx: common.UIAbilityContext): string {
  return ctx.filesDir + '/docs/images';
}
function HwImagePath(ctx: common.UIAbilityContext, rel: string): string {
  return ImagesPath(ctx) + '/' + rel.replace(/^images\//, '');
}
function AnnoPath(ctx: common.UIAbilityContext, docKey: string): string {
  return ctx.filesDir + '/annotations/' + docKey + '.json';
}
