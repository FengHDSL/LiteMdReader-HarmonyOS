/**
 * 澄笺 · 导出服务（HTML / MD / 分享 的文件层）
 * ================================================================
 *
 * 职责只到「拿到字节 / 文件」为止：
 *   · saveText / saveBytes —— 系统另存为（DocumentViewPicker），写入用户选择的
 *     URI，无需任何权限（与阅读页导出 HTML 同一套通道）。
 *   · shareFile —— 系统分享（SystemShare：general.file + 文件 URI）。
 *
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DocStore } from './DocStore';
import { MdParser } from '../markdown/MdParser';
import { MdBlockKind } from '../markdown/MdTypes';
import { MdToHtml, InlineRuntime } from '../markdown/MdToHtml';
import { ChartRuntimeService } from './ChartRuntimeService';

const TAG: string = 'ExportService';

/** 轻提示回调：面板把 toast 传进来，服务层不直接依赖 UI。 */
export type Notify = (message: string) => void;

export class ExportService {
  /** 取文档正文（内置文档走 rawfile）。失败返回 null。 */
  static readContent(ctx: common.UIAbilityContext, docName: string, builtin: boolean): string | null {
    try {
      DocStore.init(ctx);
      const meta = DocStore.find(ctx, docName);
      if (meta === undefined) {
        return null;
      }
      return DocStore.readText(ctx, meta);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'readContent failed: %{public}s', (err as Error).message);
      return null;
    }
  }

  /** 渲染自包含 HTML（与阅读页导出 HTML 同一渲染器）。rich = 预装图表渲染工具。 */
  static buildHtml(docName: string, content: string, rich: boolean = false): string {
    const parsed = MdParser.parse(content);
    return MdToHtml.export(docName, parsed.meta, parsed.blocks, rich);
  }

  /**
   * **把 HTML 里的本地图片内联成 data URI**（用户要求：手写笔记、插入的图片都要
   * 跟着导出文件走，不留在外面）。仅处理相对路径（images/xxx.png 等）——
   * 网络图 / 已是 data URI 的原样保留。
   */
  static inlineLocalImages(ctx: common.UIAbilityContext, html: string): string {
    const root: string = DocStore.docsRoot();
    if (root.length === 0) {
      return html;
    }
    let out: string = '';
    let i: number = 0;
    while (i < html.length) {
      const k: number = html.indexOf('src="', i);
      if (k < 0) {
        out += html.substring(i);
        break;
      }
      const e: number = html.indexOf('"', k + 5);
      if (e < 0) {
        out += html.substring(i);
        break;
      }
      const srcRaw: string = html.substring(k + 5, e);
      out += html.substring(i, k + 5);
      let rep: string = srcRaw;
      const isRemote: boolean = srcRaw.startsWith('http://') || srcRaw.startsWith('https://')
        || srcRaw.startsWith('data:');
      if (!isRemote && srcRaw.length > 0) {
        // **file: 开头的也算本地文件**（可能是上一轮处理写入的），剥掉前缀后读文件
        let relPath: string = srcRaw;
        if (relPath.startsWith('file://')) {
          relPath = relPath.substring('file://'.length);
          if (relPath.startsWith(root + '/')) {
            relPath = relPath.substring(root.length + 1);
          }
        }
        if (relPath.startsWith('./')) {
          relPath = relPath.substring(2);
        }
        let uri: string | null = null;
        if (relPath.startsWith('/')) {
          uri = ExportService.fileToDataUri(relPath);
        } else {
          // **候选路径**：docs 根下 / images 目录下（basename）——手写图两种位置都可能
          uri = ExportService.fileToDataUri(root + '/' + relPath);
          if (uri === null) {
            const slash: number = relPath.lastIndexOf('/');
            const base: string = slash >= 0 ? relPath.substring(slash + 1) : relPath;
            uri = ExportService.fileToDataUri(root + '/images/' + base);
          }
        }
        if (uri !== null) {
          rep = uri;
        }
      }
      out += rep;
      i = e;
    }
    return out;
  }

  /** 读本地文件 → data URI（按扩展名给 MIME）；失败返回 null。 */
  private static fileToDataUri(path: string): string | null {
    try {
      if (!fs.accessSync(path)) {
        return null;
      }
      const size: number = fs.statSync(path).size;
      if (size <= 0 || size > 12 * 1024 * 1024) {
        // 过大不内联（避免导出文件失控）
        return null;
      }
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buf: ArrayBuffer = new ArrayBuffer(size);
      try {
        fs.readSync(file.fd, buf);
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          // 忽略
        }
      }
      const bytes: Uint8Array = new Uint8Array(buf);
      const b64: string = new util.Base64Helper().encodeToStringSync(bytes);
      const lower: string = path.toLowerCase();
      let mime: string = 'image/png';
      if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
        mime = 'image/jpeg';
      } else if (lower.endsWith('.gif')) {
        mime = 'image/gif';
      } else if (lower.endsWith('.webp')) {
        mime = 'image/webp';
      } else if (lower.endsWith('.bmp')) {
        mime = 'image/bmp';
      } else if (lower.endsWith('.svg')) {
        mime = 'image/svg+xml';
      }
      return 'data:' + mime + ';base64,' + b64;
    } catch (err) {
      return null;
    }
  }

  /**
   * **智能 HTML 导出**（用户要求「提前下载到应用内，导出时预转进去」）：
   * · 无图表 → 普通导出；
   * · 有图表 → 渲染库已缓存的直接**内联进 HTML**（自包含、离线可渲染）；
   *   缺失的自动从 CDN 下载一次并缓存（首次需联网，之后离线可用）；
   * · 下载失败 → 回退 CDN 引用模式并提示。
   * 完成后自行走 saveText（用户选保存位置），notify 全程汇报。
   */
  static async exportHtmlSmart(ctx: common.UIAbilityContext, docName: string,
                               content: string, notify: Notify): Promise<void> {
    const parsed = MdParser.parse(content);
    const chartCount: number = MdToHtml.countCharts(parsed.blocks);
    if (chartCount === 0) {
      const plain: string =
        ExportService.inlineLocalImages(ctx,
          MdToHtml.export(docName, parsed.meta, parsed.blocks, false, null));
      ExportService.saveText(ctx, docName + '.html', plain, notify);
      return;
    }
    // 收集所需库文件（Chart 块按语言；Math 公式块需要 katex）
    const needed: string[] = [];
    for (let k = 0; k < parsed.blocks.length; k++) {
      const b = parsed.blocks[k];
      let files: string[] = [];
      if (b.kind === MdBlockKind.Chart) {
        files = ChartRuntimeService.filesForLang(b.lang.trim().toLowerCase());
      } else if (b.kind === MdBlockKind.Math) {
        files = ChartRuntimeService.filesForLang('katex');
      }
      for (let f = 0; f < files.length; f++) {
        if (needed.indexOf(files[f]) < 0) {
          needed.push(files[f]);
        }
      }
    }
    notify('正在导入图表组件…');
    const inline: InlineRuntime[] | null =
      await ChartRuntimeService.loadRuntimes(ctx, needed, notify);
    if (inline !== null) {
      // katex 字体：把内联 CSS 里的 url(fonts/xx) 替换成 data URI（公式字形不退化）
      for (let k = 0; k < inline.length; k++) {
        if (inline[k].name === 'katex.min.css') {
          let css: string = inline[k].code;
          for (const font of ChartRuntimeService.katexFontFiles()) {
            const b64: string | null =
              await ChartRuntimeService.readFontDataUri(ctx, font);
            if (b64 !== null) {
              css = css.split('fonts/' + font + ')').join(b64 + ')');
            }
          }
          const fixed: InlineRuntime = {
            name: inline[k].name, code: css, isCss: inline[k].isCss
          };
          inline[k] = fixed;
        }
      }
    }
    if (inline === null) {
      notify('图表组件导入失败，改用在线渲染（打开时需联网）');
    }
    const html: string =
      ExportService.inlineLocalImages(ctx,
        MdToHtml.export(docName, parsed.meta, parsed.blocks, true, inline));
    ExportService.saveText(ctx, docName + '.html', html, notify);
  }

  /** 系统另存为：文本内容（md / html）。 */
  static saveText(ctx: common.UIAbilityContext, fileName: string, content: string, notify: Notify): void {
    const docPicker = new picker.DocumentViewPicker(ctx);
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [fileName];
    docPicker.save(options).then((uris: string[]) => {
      if (uris.length === 0) {
        // 用户在另存为对话框取消：也要通知，面板据此收起
        notify('已取消保存');
        return;
      }
      let file: fs.File | null = null;
      try {
        file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, content);
        notify('已导出 ' + fileName);
      } catch (err) {
        notify('写入文件失败');
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
      notify('保存失败：' + err.message);
    });
  }

  /** 系统另存为：二进制内容（pdf / png）。 */
  static saveBytes(ctx: common.UIAbilityContext, fileName: string, bytes: ArrayBuffer, notify: Notify): void {
    ExportService.saveBytesMulti(ctx, [fileName], [bytes], notify);
  }

  /**
   * 系统另存为：**一次对话框保存多个文件**（分页导出用）。
   * newFileNames 与 bytes 一一对应；用户选一次目录，多页文件全部落在同一目录。
   * 部分写入失败只提示，不回滚已写成功的页。
   */
  static saveBytesMulti(ctx: common.UIAbilityContext, fileNames: string[], byteList: ArrayBuffer[], notify: Notify): void {
    const docPicker = new picker.DocumentViewPicker(ctx);
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = fileNames;
    docPicker.save(options).then((uris: string[]) => {
      if (uris.length === 0) {
        // 用户在另存为对话框取消：也要通知，面板据此收起
        notify('已取消保存');
        return;
      }
      let written: number = 0;
      let failed: number = 0;
      for (let k = 0; k < uris.length && k < byteList.length; k++) {
        let file: fs.File | null = null;
        try {
          file = fs.openSync(uris[k], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
          fs.writeSync(file.fd, byteList[k]);
          written++;
        } catch (err) {
          failed++;
        } finally {
          if (file !== null) {
            try {
              fs.closeSync(file);
            } catch (closeErr) {
              // 关闭失败无副作用
            }
          }
        }
      }
      if (failed === 0) {
        notify('已导出 ' + written + ' 个文件');
      } else {
        notify('已导出 ' + written + ' 个，' + failed + ' 个写入失败');
      }
    }).catch((err: BusinessError) => {
      notify('保存失败：' + err.message);
    });
  }

  /** bytesToCache 的异步薄封装（打印链路用）。 */
  static async bytesToCacheAsync(ctx: common.UIAbilityContext, fileName: string,
                                 bytes: ArrayBuffer): Promise<string> {
    return ExportService.bytesToCache(ctx, fileName, bytes);
  }

  /** 把字节落进应用缓存（打印用：系统打印组件从文件 URI 读）。返回文件路径。 */
  static bytesToCache(ctx: common.UIAbilityContext, fileName: string, bytes: ArrayBuffer): string {
    const dir: string = ctx.cacheDir + '/export';
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (err) {
      // 目录已存在
    }
    const path: string = dir + '/' + fileName;
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, bytes);
    } finally {
      try {
        fs.closeSync(file);
      } catch (closeErr) {
        // 关闭失败无副作用
      }
    }
    return path;
  }

  /**
   * **系统分享（官方 SystemShare）**：把缓存里的文件交给系统分享面板。
   * 文件用 `general.file` UTD + 沙箱路径转出的 file URI；
   * 面板由系统渲染（ShareController.show），取消/完成都走 Promise 结束。
   */
  static shareFile(ctx: common.UIAbilityContext, path: string, notify: Notify): void {
    try {
      const uri: string = fileUri.getUriFromPath(path);
      const record: systemShare.SharedRecord = {
        utd: 'general.file',
        uri: uri,
        title: path.substring(path.lastIndexOf('/') + 1)
      };
      const data: systemShare.SharedData = new systemShare.SharedData(record);
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      const options: systemShare.ShareControllerOptions = {};
      // **调起即收尾**：show 的 Promise 要等用户关闭分享面板才 resolve，
      // 不能用它驱动面板收尾——否则「正在处理」会一直挂到分享结束（真机踩过）。
      // 晚到的失败只记日志。
      controller.show(ctx, options).then(() => {
        hilog.info(0x0000, TAG, 'share panel closed');
      }).catch((err: BusinessError) => {
        hilog.warn(0x0000, TAG, 'share failed: %{public}s', err.message);
      });
      notify('已调起分享');
    } catch (err) {
      notify('分享失败');
    }
  }
}
