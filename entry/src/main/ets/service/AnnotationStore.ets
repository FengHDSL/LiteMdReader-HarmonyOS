/**
 * LiteMdReader · 批注存储
 * ========================
 *
 * 每篇文档一个文件：`<filesDir>/annotations/<文档名>.json`。
 * 与书架索引分开存放，原因是批注条数可能很多且只在阅读时用得到，
 * 不想让书架加载去反序列化一堆批注。
 *
 * 这里只做「读写整份列表」，增删逻辑（区间重叠判断等）留在页面侧——
 * 存储层不承担业务规则，职责更清楚。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { MdAnnotation } from '../markdown/MdTypes';
import { DocStore } from './DocStore';

/** 批注文件的反序列化结构 */
interface AnnotationIndex {
  items: MdAnnotation[];
}

export class AnnotationStore {
  private static dirOf(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/annotations';
  }

  private static pathOf(ctx: common.UIAbilityContext, docKey: string): string {
    return AnnotationStore.dirOf(ctx) + '/' + DocStore.sanitizeName(docKey) + '.json';
  }

  private static ensureDir(ctx: common.UIAbilityContext): void {
    try {
      const dir: string = AnnotationStore.dirOf(ctx);
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (err) {
      // 目录已存在或创建失败，后续读写会报错
    }
  }

  /** 读取某文档的全部批注。文件不存在或损坏时返回空列表，不抛异常。 */
  static load(ctx: common.UIAbilityContext, docKey: string): MdAnnotation[] {
    AnnotationStore.ensureDir(ctx);
    const path: string = AnnotationStore.pathOf(ctx, docKey);
    try {
      if (!fs.accessSync(path)) {
        return [];
      }
      const text: string = fs.readTextSync(path, { encoding: 'utf-8' });
      if (text.length === 0) {
        return [];
      }
      const parsed: AnnotationIndex = JSON.parse(text) as AnnotationIndex;
      if (parsed === null || parsed === undefined || parsed.items === undefined) {
        return [];
      }
      return parsed.items;
    } catch (err) {
      return [];
    }
  }

  /** 保存某文档的全部批注。空列表也会落盘（表示用户已清空）。 */
  static save(ctx: common.UIAbilityContext, docKey: string, items: MdAnnotation[]): void {
    AnnotationStore.ensureDir(ctx);
    const path: string = AnnotationStore.pathOf(ctx, docKey);
    try {
      const index: AnnotationIndex = { items: items };
      const file: fs.File =
        fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(index));
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
    } catch (err) {
      // 落盘失败只影响批注持久化，不阻断阅读
    }
  }

  /** 某文档是否已有批注文件（书架/阅读页可据此显示标识）。 */
  static hasAny(ctx: common.UIAbilityContext, docKey: string): boolean {
    try {
      return fs.accessSync(AnnotationStore.pathOf(ctx, docKey));
    } catch (err) {
      return false;
    }
  }
}
