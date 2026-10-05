/**
 * 澄笺 · EPUB 导出（EpubExport）
 * ================================
 *
 * 把 Markdown 文档导出为 EPUB 3 电子书（批 5 之 EPUB 导出）。
 *
 * 组包策略（刻意"全 STORED 不压缩"）：
 *  · @ohos.zlib 只暴露 zip/unzip 整目录接口，条目内的相对路径不可控；
 *    EPUB 对条目名结构有硬性要求（mimetype 必须第一个且不压缩），
 *    所以这里**手写 zip 容器**：所有条目 STORED（compression method 0）。
 *  · zip 规范允许全部条目不压缩（只是体积大些），EPUB 规范只强制
 *    mimetype STORED —— 全 STORED 完全合法，Calibre / Apple Books / 系统图书均可打开。
 *
 * 结构：
 *   mimetype                              application/epub+zip（第一个、STORED）
 *   META-INF/container.xml                指向 OEBPS/content.opf
 *   OEBPS/content.opf                     EPUB 3 包描述（manifest + spine）
 *   OEBPS/nav.xhtml                       EPUB 3 导航文档
 *   OEBPS/chapter.xhtml                   正文（整篇一章；HTML 片段做 XHTML 闭合修复）
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MdParser } from '../markdown/MdParser';
import { MdParseResult, MdBlock, MdBlockKind } from '../markdown/MdTypes';
import { MdToHtml } from '../markdown/MdToHtml';
import { ChartCache } from './ChartCache';

/** zip 里的一个条目（原始字节 + 归档内路径） */
interface ZipEntry {
  name: string;
  data: Uint8Array;
}

export class EpubExport {
  // ────────────────────── CRC32（zip 必需，表驱动） ──────────────────────

  private static crcTable: number[] | null = null;

  private static crcTableInit(): number[] {
    const table: number[] = [];
    for (let n = 0; n < 256; n++) {
      let c: number = n;
      for (let k = 0; k < 8; k++) {
        c = (c & 1) !== 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[n] = c >>> 0;
    }
    return table;
  }

  private static crc32(bytes: Uint8Array): number {
    if (EpubExport.crcTable === null) {
      EpubExport.crcTable = EpubExport.crcTableInit();
    }
    let c: number = 0xFFFFFFFF;
    for (let i = 0; i < bytes.length; i++) {
      c = EpubExport.crcTable![(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
    }
    return (c ^ 0xFFFFFFFF) >>> 0;
  }

  /**
   * UTF-8 编码（手写：ArkTS 环境没有 TextEncoder，且要正确处理中文与代理对）。
   */
  private static bytesOf(text: string): Uint8Array {
    const out: number[] = [];
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code < 0x80) {
        out.push(code);
      } else if (code < 0x800) {
        out.push(0xC0 | (code >> 6), 0x80 | (code & 0x3F));
      } else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
        // 代理对 → 4 字节
        const lo: number = text.charCodeAt(i + 1);
        const cp: number = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00);
        i++;
        out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
          0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
      } else {
        out.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
      }
    }
    return new Uint8Array(out);
  }

  // ────────────────────── zip 容器（全 STORED） ──────────────────────

  /**
   * 组一个全 STORED 的 zip。条目顺序 = 数组顺序（mimetype 必须第一个）。
   * 结构：Local File Header + 数据 × N → Central Directory → EOCD。
   */
  private static buildZip(entries: ZipEntry[]): Uint8Array {
    const put32 = (view: DataView, off: number, v: number): void => {
      view.setUint32(off, v >>> 0, true);
    };
    const put16 = (view: DataView, off: number, v: number): void => {
      view.setUint16(off, v & 0xFFFF, true);
    };

    // 先算总长：每条 local(30 + name) + data；central(46 + name)；EOCD 22
    let total: number = 22;
    for (let i = 0; i < entries.length; i++) {
      total += 30 + entries[i].name.length + entries[i].data.length;
      total += 46 + entries[i].name.length;
    }
    const out: Uint8Array = new Uint8Array(total);
    const view: DataView = new DataView(out.buffer);
    let off: number = 0;
    const centralOffsets: number[] = [];

    for (let i = 0; i < entries.length; i++) {
      const e: ZipEntry = entries[i];
      const crc: number = EpubExport.crc32(e.data);
      centralOffsets.push(off);
      // Local File Header（STORED：无数据描述符，尺寸直接写）
      put32(view, off, 0x04034B50);
      put16(view, off + 4, 20);          // version needed
      put16(view, off + 6, 0x0800);      // flags: UTF-8 文件名
      put16(view, off + 8, 0);           // method: STORED
      put16(view, off + 10, 0);          // time
      put16(view, off + 12, 0x21);       // date（合法占位：1980-01-01）
      put32(view, off + 14, crc);
      put32(view, off + 18, e.data.length);   // compressed = stored 原长
      put32(view, off + 22, e.data.length);   // uncompressed
      put16(view, off + 26, e.name.length);
      put16(view, off + 28, 0);          // extra len
      off += 30;
      for (let k = 0; k < e.name.length; k++) {
        out[off + k] = e.name.charCodeAt(k);
      }
      off += e.name.length;
      out.set(e.data, off);
      off += e.data.length;
    }

    // Central Directory
    const cdStart: number = off;
    for (let i = 0; i < entries.length; i++) {
      const e: ZipEntry = entries[i];
      const crc: number = EpubExport.crc32(e.data);
      put32(view, off, 0x02014B50);
      put16(view, off + 4, 20);          // version made by
      put16(view, off + 6, 20);          // version needed
      put16(view, off + 8, 0x0800);
      put16(view, off + 10, 0);
      put16(view, off + 12, 0);
      put16(view, off + 14, 0x21);
      put32(view, off + 16, crc);
      put32(view, off + 20, e.data.length);
      put32(view, off + 24, e.data.length);
      put16(view, off + 28, e.name.length);
      put16(view, off + 30, 0);          // extra
      put16(view, off + 32, 0);          // comment
      put16(view, off + 34, 0);          // disk start
      put16(view, off + 36, 0);          // internal attrs
      put32(view, off + 38, 0);          // external attrs
      put32(view, off + 42, centralOffsets[i]);
      off += 46;
      for (let k = 0; k < e.name.length; k++) {
        out[off + k] = e.name.charCodeAt(k);
      }
      off += e.name.length;
    }
    const cdSize: number = off - cdStart;

    // EOCD
    put32(view, off, 0x06054B50);
    put16(view, off + 4, 0);
    put16(view, off + 6, 0);
    put16(view, off + 8, entries.length);
    put16(view, off + 10, entries.length);
    put32(view, off + 12, cdSize);
    put32(view, off + 16, cdStart);
    put16(view, off + 20, 0);

    return out;
  }

  // ────────────────────── XHTML 组装 ──────────────────────

  /**
   * Markdown → XHTML 正文片段。
   * 用自研 MdToHtml 出整页后截取 body 内容，再做**最小 XHTML 闭合修复**。
   * **图表 / 公式块**：EPUB 阅读器禁 JS，渲染库方案全不可行 —— 改用
   * **应用内已生成的缓存图**（ChartRenderPool 在阅读时后台渲染、ChartCache 落盘）：
   * 有缓存就把占位 div 替换成 `<img>` 并把 PNG 打进包；没缓存给占位说明。
   * **表格**：补上完整的表格 CSS（此前无边框导致"表格显示不正确"，用户反馈）。
   */
  private static buildChapterXhtml(ctx: common.UIAbilityContext, docName: string,
                                   content: string, imagesOut: ZipEntry[]): string {
    const parsed: MdParseResult = MdParser.parse(content);
    const page: string =
      MdToHtml.export(docName, parsed.meta, parsed.blocks, true, null);
    let body: string = '';
    const open: number = page.indexOf('<body');
    const close: number = page.lastIndexOf('</body>');
    if (open >= 0 && close > open) {
      const gt: number = page.indexOf('>', open);
      body = page.substring(gt + 1, close);
    } else {
      body = '<p>' + EpubExport.esc(content) + '</p>';
    }
    body = body.replace(/<br\s*>/gi, '<br/>')
      .replace(/<hr\s*>/gi, '<hr/>')
      .replace(/<img([^>]*[^/])>/gi, '<img$1/>');

    // 图表 / 公式块 → 缓存 PNG（按块序在 body 里定位同源的 data-b64 占位 div 整体替换）
    let imgSeq: number = 0;
    for (let k = 0; k < parsed.blocks.length; k++) {
      const b: MdBlock = parsed.blocks[k];
      let mode: string = '';
      if (b.kind === MdBlockKind.Math) {
        mode = 'katex';
      } else if (b.kind === MdBlockKind.Chart) {
        mode = b.lang.toLowerCase();
      }
      if (mode.length === 0) {
        continue;
      }
      const key: string = ChartCache.keyFor(mode, b.code, false);
      const pngPath: string = ChartCache.path(ctx, key);
      const b64: string = EpubExport.b64Of(b.code);
      const at: number = body.indexOf('data-b64="' + b64 + '"');
      if (at < 0) {
        continue;
      }
      let imgTag: string = '';
      if (pngPath.length > 0) {
        const bytes: Uint8Array | null = EpubExport.readBytes(pngPath);
        if (bytes !== null) {
          imgSeq++;
          const name: string = 'OEBPS/images/c' + imgSeq + '.png';
          imagesOut.push({ name: name, data: bytes } as ZipEntry);
          imgTag = '<img src="images/c' + imgSeq + '.png" alt="图表"/>';
        }
      }
      if (imgTag.length === 0) {
        imgTag = '<p><em>（图表「' + EpubExport.esc(mode) + '」请在澄笺内打开本文档一次以生成图片，再重新导出）</em></p>';
      }
      const divOpen: number = body.lastIndexOf('<div', at);
      const divClose: number = body.indexOf('</div>', at);
      if (divOpen >= 0 && divClose > divOpen) {
        body = body.substring(0, divOpen) + imgTag + body.substring(divClose + 6);
      }
    }

    return '<?xml version="1.0" encoding="utf-8"?>\n'
      + '<!DOCTYPE html>\n'
      + '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN">\n<head>\n'
      + '<meta charset="utf-8"/>\n<title>' + EpubExport.esc(docName) + '</title>\n'
      + '<style>body{margin:1.2em;line-height:1.7;}img{max-width:100%;}'
      + 'pre{white-space:pre-wrap;}'
      + 'table{border-collapse:collapse;width:100%;margin:0.6em 0;}'
      + 'th,td{border:1px solid #999;padding:4px 8px;font-size:0.95em;}'
      + 'th{background:#f0f0f0;}</style>\n'
      + '</head>\n<body>\n' + body + '\n</body>\n</html>\n';
  }

  /** base64（与 MdToHtml.b64 同功能：图表占位 div 的 data-b64 属性值定位用）。 */
  private static b64Of(text: string): string {
    const bytes: Uint8Array = EpubExport.bytesOf(text);
    const chars: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let out: string = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const b0: number = bytes[i];
      const b1: number = i + 1 < bytes.length ? bytes[i + 1] : 0;
      const b2: number = i + 2 < bytes.length ? bytes[i + 2] : 0;
      out += chars[b0 >> 2];
      out += chars[((b0 & 3) << 4) | (b1 >> 4)];
      out += i + 1 < bytes.length ? chars[((b1 & 15) << 2) | (b2 >> 6)] : '=';
      out += i + 2 < bytes.length ? chars[b2 & 63] : '=';
    }
    return out;
  }

  /** 读整个文件为字节（图表缓存 PNG）；失败返回 null。 */
  private static readBytes(path: string): Uint8Array | null {
    try {
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const stat: fs.Stat = fs.statSync(path);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      return new Uint8Array(buf);
    } catch (err) {
      return null;
    }
  }

  private static esc(s: string): string {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  // ────────────────────── 对外入口 ──────────────────────

  /**
   * 导出 EPUB：拉系统「另存为」（预填 文档名.epub），返回提示文案（空串 = 用户取消）。
   */
  static async exportEpub(ctx: common.UIAbilityContext, docName: string,
                          content: string, notify: (m: string) => void): Promise<void> {
    let uri: string = '';
    try {
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [docName + '.epub'];
      const viewPicker = new picker.DocumentViewPicker(ctx);
      const uris: string[] = await viewPicker.save(options);
      if (uris === undefined || uris === null || uris.length === 0) {
        return;
      }
      uri = uris[0];
    } catch (err) {
      notify('打开保存位置失败');
      return;
    }

    try {
      const id: string = docName.replace(/[^A-Za-z0-9]/g, '') || 'doc';
      const images: ZipEntry[] = [];
      const chapter: string = EpubExport.buildChapterXhtml(ctx, docName, content, images);
      // 图表图片登记进 manifest（缓存图有多少张登记多少张）
      let imageManifest: string = '';
      for (let i = 0; i < images.length; i++) {
        imageManifest += '<item id="img' + (i + 1) + '" href="'
          + images[i].name.substring('OEBPS/'.length) + '" media-type="image/png"/>\n';
      }
      const entries: ZipEntry[] = [
        { name: 'mimetype', data: EpubExport.bytesOf('application/epub+zip') },
        {
          name: 'META-INF/container.xml',
          data: EpubExport.bytesOf('<?xml version="1.0" encoding="utf-8"?>\n'
            + '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
            + '<rootfiles><rootfile full-path="OEBPS/content.opf" '
            + 'media-type="application/oebps-package+xml"/></rootfiles>\n</container>\n')
        },
        {
          name: 'OEBPS/content.opf',
          data: EpubExport.bytesOf('<?xml version="1.0" encoding="utf-8"?>\n'
            + '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">\n'
            + '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
            + '<dc:identifier id="uid">urn:uuid:litemd-' + id + '</dc:identifier>\n'
            + '<dc:title>' + EpubExport.esc(docName) + '</dc:title>\n'
            + '<dc:language>zh-CN</dc:language>\n'
            + '<dc:creator>澄笺</dc:creator>\n'
            + '<meta property="dcterms:modified">' + new Date().toISOString().replace(/\.\d+Z$/, 'Z') + '</meta>\n'
            + '</metadata>\n'
            + '<manifest>\n'
            + '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\n'
            + '<item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>\n'
            + imageManifest
            + '</manifest>\n'
            + '<spine><itemref idref="chapter"/></spine>\n'
            + '</package>\n')
        },
        {
          name: 'OEBPS/nav.xhtml',
          data: EpubExport.bytesOf('<?xml version="1.0" encoding="utf-8"?>\n'
            + '<!DOCTYPE html>\n'
            + '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">\n'
            + '<head><meta charset="utf-8"/><title>目录</title></head>\n'
            + '<body><nav epub:type="toc" id="toc"><h1>目录</h1><ol><li>'
            + '<a href="chapter.xhtml">' + EpubExport.esc(docName) + '</a></li></ol></nav></body>\n'
            + '</html>\n')
        },
        { name: 'OEBPS/chapter.xhtml', data: EpubExport.bytesOf(chapter) }
      ];
      // 图表图片条目排在最后（zip 内顺序无关紧要，仅 mimetype 必须第一）
      for (let i = 0; i < images.length; i++) {
        entries.push(images[i]);
      }

      const zipBytes: Uint8Array = EpubExport.buildZip(entries);
      const file: fs.File = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, zipBytes.buffer);
      fs.closeSync(file);
      notify('EPUB 已导出（' + docName + '.epub）');
    } catch (err) {
      notify('导出失败：' + (err as BusinessError).message);
    }
  }
}
