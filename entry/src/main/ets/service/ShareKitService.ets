/**
 * 澄笺 · Share Kit 跨设备分享服务（碰一碰 + 隔空传送）
 * ================================================================
 *
 * 参考 Huawei HarmonyOS Samples（KnockFileShare / GesturesShare）：
 *   · 碰一碰：`harmonyShare.on('knockShare')` 注册监听，回调里
 *     `sharableTarget.share(data)` 传输文件（手机间 / 手机与 PC）；
 *   · 隔空传送：`harmonyShare.on('gesturesShare')` 注册监听，"一抓一放"
 *     触发同样回调（HarmonyOS 6.0.2+，需系统侧开启隔空传送开关）。
 *
 * 使用方式：阅读页进入时 `startListening`（携带当前文档路径提供者），
 * 离开时 `stopListening`。两台设备都装澄笺或接收端为 PC / 手机均可收文件。
 * 无需额外权限（系统能力 SystemCapability.Collaboration.HarmonyShare 守卫）。
 */
import { harmonyShare, systemShare } from '@kit.ShareKit';
import { fileUri } from '@kit.CoreFileKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ShareKitService';

/** 当前可分享的文档路径提供者（返回 null = 无可分享文件，如内置文档）。 */
export type CurrentDocPathProvider = () => string | null;

export class ShareKitService {
  private static listening: boolean = false;
  private static docPathProvider: CurrentDocPathProvider | null = null;

  /** 设备是否支持 HarmonyShare 系统能力。 */
  static supported(): boolean {
    return canIUse('SystemCapability.Collaboration.HarmonyShare');
  }

  /**
   * 注册碰一碰 + 隔空传送监听。重复调用幂等。
   * @param docPathProvider 返回当前文档的沙箱绝对路径（无则 null）。
   */
  static startListening(docPathProvider: CurrentDocPathProvider): void {
    if (!ShareKitService.supported()) {
      hilog.info(0x0000, TAG, 'HarmonyShare not supported on this device');
      return;
    }
    if (ShareKitService.listening) {
      ShareKitService.docPathProvider = docPathProvider;
      return;
    }
    ShareKitService.docPathProvider = docPathProvider;
    try {
      harmonyShare.on('knockShare', (target: harmonyShare.SharableTarget) => {
        ShareKitService.onShareEvent(target);
      });
      harmonyShare.on('gesturesShare', (target: harmonyShare.SharableTarget) => {
        ShareKitService.onShareEvent(target);
      });
      ShareKitService.listening = true;
      hilog.info(0x0000, TAG, 'knockShare / gesturesShare listening');
    } catch (err) {
      hilog.warn(0x0000, TAG, 'listening failed: %{public}s', (err as Error).message);
    }
  }

  /** 取消监听（离开阅读页时）。 */
  static stopListening(): void {
    if (!ShareKitService.listening) {
      return;
    }
    try {
      harmonyShare.off('knockShare');
      harmonyShare.off('gesturesShare');
      ShareKitService.listening = false;
      ShareKitService.docPathProvider = null;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'off failed: %{public}s', (err as Error).message);
    }
  }

  /** 碰一碰 / 隔空传送事件：把当前文档作为文件分享出去。 */
  private static onShareEvent(target: harmonyShare.SharableTarget): void {
    const path: string | null = ShareKitService.docPathProvider !== null
      ? ShareKitService.docPathProvider() : null;
    if (path === null || path.length === 0) {
      hilog.info(0x0000, TAG, 'no shareable doc');
      return;
    }
    try {
      // **URI 用 `file://` + 沙箱绝对路径**：`fileUri.getUriFromPath` 生成的
      // `file://<bundleName>/...` 形式在部分系统组件里取不到文件（用户实测
      // "分享内容获取失败"），绝对路径形式被 Web / 打印等组件一致接受。
      const uri: string = path.startsWith('file://') ? path : 'file://' + path;
      // UTD：按扩展名取；系统不认时兜底 general.file（否则分享记录无效）
      let utd: string =
        uniformTypeDescriptor.getUniformDataTypeByFilenameExtension('.md');
      if (utd === undefined || utd === null || utd.length === 0) {
        utd = 'general.file';
      }
      const record: systemShare.SharedRecord = {
        utd: utd,
        uri: uri,
        title: path.substring(path.lastIndexOf('/') + 1)
      };
      const data: systemShare.SharedData = new systemShare.SharedData(record);
      target.share(data);
      hilog.info(0x0000, TAG, 'shared doc via share kit');
    } catch (err) {
      hilog.warn(0x0000, TAG, 'share failed: %{public}s', (err as Error).message);
    }
  }
}
