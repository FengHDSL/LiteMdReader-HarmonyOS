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
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DocStore } from './DocStore';
import { MdParser } from '../markdown/MdParser';
import { MdToHtml } from '../markdown/MdToHtml';

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

  /** 渲染自包含 HTML（与阅读页导出 HTML 同一渲染器）。 */
  static buildHtml(docName: string, content: string): string {
    const parsed = MdParser.parse(content);
    return MdToHtml.export(docName, parsed.meta, parsed.blocks);
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
