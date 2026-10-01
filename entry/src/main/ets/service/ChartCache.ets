/**
 * 澄笺 · 图表渲染结果磁盘缓存
 * ============================
 *
 * 公式 / 图表块在阅读页由 DiagramWeb（Web 组件）实时渲染——有三个代价：
 * 滑到位置才加载、每次打开都重渲、**导出快照无法捕获 Web 表面**。
 *
 * 本服务把渲染产物（PixelMap → PNG）按内容哈希写入 `<cacheDir>/charts/`：
 *   · 键 = md5(mode | 深浅 | 源码)——内容或主题变了自动换新键，天然失效；
 *   · 正文的 mathView / chartView 优先用缓存图（Image），没有才回落 DiagramWeb；
 *   · 后台预渲染池（ChartRenderPool）在打开文件时逐个补齐缓存。
 */

import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';

export class ChartCache {
  /** 键 → 路径 的会话内缓存（含「无缓存」的空串），避免每次渲染都 accessSync */
  private static memo: Map<string, string> = new Map();

  /** 内容哈希：mode | 深浅 | 源码 → md5 hex。同步实现（输入都是小文本）。 */
  static keyFor(mode: string, payload: string, dark: boolean): string {
    const raw: string = mode + '|' + (dark ? 'd' : 'l') + '|' + payload;
    try {
      const encoder: util.TextEncoder = new util.TextEncoder();
      const md: cryptoFramework.Md = cryptoFramework.createMd('MD5');
      md.updateSync({ data: encoder.encodeInto(raw) });
      const digest: cryptoFramework.DataBlob = md.digestSync();
      let hex: string = '';
      for (let k = 0; k < digest.data.length; k++) {
        const v: number = digest.data[k];
        hex += (v < 16 ? '0' : '') + v.toString(16);
      }
      return hex;
    } catch (err) {
      // 哈希失败退到简易摘要（几乎不会发生）
      return 'h' + (mode.length * 31 + payload.length * 17 + (dark ? 7 : 0)).toString(16);
    }
  }

  /** 已缓存的图表图片路径；无缓存返回空串（结果记入 memo）。 */
  static path(ctx: common.UIAbilityContext, key: string): string {
    const hit: string | undefined = ChartCache.memo.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const p: string = ctx.cacheDir + '/charts/' + key + '.png';
    let found: string = '';
    try {
      if (fs.accessSync(p)) {
        found = p;
      }
    } catch (err) {
      found = '';
    }
    ChartCache.memo.set(key, found);
    return found;
  }

  /** 把渲染完成的 PixelMap 存成 PNG 并登记。失败返回空串。 */
  static async save(ctx: common.UIAbilityContext, key: string, pixel: image.PixelMap): Promise<string> {
    try {
      const dir: string = ctx.cacheDir + '/charts';
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const packer: image.ImagePacker = image.createImagePacker();
      const bytes: ArrayBuffer = await packer.packToData(pixel, { format: 'image/png', quality: 100 });
      const p: string = dir + '/' + key + '.png';
      const file: fs.File = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes);
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
      ChartCache.memo.set(key, p);
      return p;
    } catch (err) {
      return '';
    }
  }
}
