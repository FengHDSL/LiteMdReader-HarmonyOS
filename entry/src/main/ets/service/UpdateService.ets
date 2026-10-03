/**
 * 澄笺 · 更新服务（检查更新 / 自动检查 / 使用模式）
 * ================================================
 *
 * 三个职责：
 *   ① `check()` —— 拉 HAP 资源站详情页解析最新版本号（原实现从 SettingsExplore 抽出，
 *      手动检查与自动检查共用同一份网络与解析逻辑）；
 *   ② `maybeAutoCheck()` —— **固定 48 小时自动检查一次**（用户要求）：距上次检查
 *      不足 48h 直接跳过；有更新用**默认即时反馈（toast）**提醒，不打扰式弹窗；
 *   ③ 使用模式：`appMode()` 为 'offline'（基础模式 / 纯离线）时，一切联网能力关停。
 *
 * 键：`lastAutoCheckAt`（毫秒时间戳）、`lastSeenVersion`（已提示过的版本）、
 * `appMode`（'' 未选择 / 'full' 全量 / 'offline' 基础）。
 */

import { common, bundleManager } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingsMirror } from './SettingsMirror';

/** HAP 资源站详情页（用户指定）：页面上有版本徽标 vX.Y.Z */
export const UPDATE_SITE: string = 'https://www.sydxky.cn/detail.php?id=956';
/** 单次请求与手动检查的超时（毫秒） */
export const UPDATE_TIMEOUT: number = 8000;
/** 自动检查间隔：48 小时 */
const AUTO_CHECK_INTERVAL: number = 48 * 60 * 60 * 1000;

export const APP_MODE_FULL: string = 'full';
export const APP_MODE_OFFLINE: string = 'offline';

/** 检查结果 */
export interface UpdateCheckResult {
  ok: boolean;
  /** 远端版本（不含 v 前缀）；ok=false 时为空串 */
  remote: string;
  /** 更简洁的提示文案（页面直接用） */
  message: string;
  /** 远端比当前新 */
  hasUpdate: boolean;
}

export class UpdateService {
  /** 当前应用版本名（读不到返回 ''）。 */
  static currentVersion(): string {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName !== undefined && info.versionName.length > 0) {
        return info.versionName;
      }
    } catch (err) {
      // 读不到版本号时按空处理，调用方按失败提示
    }
    return '';
  }

  /** 使用模式：'full' | 'offline' | ''（未选择）。 */
  static appMode(): string {
    const m: string | undefined = AppStorage.get<string>('appMode');
    return m === undefined || m === null ? '' : m;
  }

  /** 是否处于纯离线（基础模式）：一切联网能力都应关停。 */
  static isOffline(): boolean {
    return UpdateService.appMode() === APP_MODE_OFFLINE;
  }

  /** 版本号比较：a>b 返回 1，a<b 返回 -1，相等返回 0（逐段数字比较，缺位补 0）。 */
  static compareVersion(a: string, b: string): number {
    const pa: string[] = a.split('.');
    const pb: string[] = b.split('.');
    const n: number = Math.max(pa.length, pb.length);
    for (let i = 0; i < n; i++) {
      const x: number = i < pa.length ? parseInt(pa[i], 10) : 0;
      const y: number = i < pb.length ? parseInt(pb[i], 10) : 0;
      const xi: number = isNaN(x) ? 0 : x;
      const yi: number = isNaN(y) ? 0 : y;
      if (xi !== yi) {
        return xi > yi ? 1 : -1;
      }
    }
    return 0;
  }

  /**
   * 从资源站 HTML 解析最新版本号。
   * 优先版本徽标锚点（`fa-code-branch` 后 400 字符内），兜底全页第一个 `vX.Y.Z`；
   * 取不到返回空串（调用方按「检查更新失败」处理）。
   */
  static parseRemoteVersion(html: string): string {
    const anchor: number = html.indexOf('fa-code-branch');
    if (anchor >= 0) {
      const seg: string = html.substring(anchor, Math.min(anchor + 400, html.length));
      const m: RegExpMatchArray | null = seg.match(/<span>\s*v(\d+\.\d+(?:\.\d+)?)\s*<\/span>/);
      if (m !== null && m.length > 1) {
        return m[1];
      }
    }
    const m2: RegExpMatchArray | null = html.match(/<span>\s*v(\d+\.\d+(?:\.\d+)?)\s*<\/span>/);
    if (m2 !== null && m2.length > 1) {
      return m2[1];
    }
    return '';
  }

  /**
   * 拉资源站检查最新版本（8 秒超时保护）。
   * 基础模式（纯离线）下直接返回「离线模式不可用」的结果，不发任何请求。
   */
  static check(): Promise<UpdateCheckResult> {
    const current: string = UpdateService.currentVersion();
    if (UpdateService.isOffline()) {
      return Promise.resolve({
        ok: false,
        remote: '',
        message: '当前是基础模式（纯离线），检查更新不可用',
        hasUpdate: false
      } as UpdateCheckResult);
    }
    return new Promise<UpdateCheckResult>((resolve) => {
      let finished: boolean = false;
      const timer = setTimeout(() => {
        if (!finished) {
          finished = true;
          resolve({
            ok: false,
            remote: '',
            message: '检查更新超时，请稍后再试',
            hasUpdate: false
          } as UpdateCheckResult);
        }
      }, UPDATE_TIMEOUT);
      const httpRequest = http.createHttp();
      httpRequest.request(UPDATE_SITE, {
        method: http.RequestMethod.GET,
        connectTimeout: UPDATE_TIMEOUT,
        readTimeout: UPDATE_TIMEOUT,
        header: { 'User-Agent': 'Mozilla/5.0 (HarmonyOS) ChengJian' }
      }).then((resp: http.HttpResponse) => {
        if (finished) {
          return;
        }
        finished = true;
        clearTimeout(timer);
        httpRequest.destroy();
        const html: string = typeof resp.result === 'string' ? resp.result : '';
        const remote: string = UpdateService.parseRemoteVersion(html);
        if (remote.length === 0) {
          resolve({
            ok: false,
            remote: '',
            message: '检查更新失败，请稍后再试',
            hasUpdate: false
          } as UpdateCheckResult);
          return;
        }
        const cmp: number = UpdateService.compareVersion(current, remote);
        resolve({
          ok: true,
          remote: remote,
          message: cmp < 0
            ? '发现新版本 v' + remote + '（当前 v' + current + '）'
            : (cmp > 0 ? '当前版本比最新版本更高' : '已是最新版本（v' + current + '）'),
          hasUpdate: cmp < 0
        } as UpdateCheckResult);
      }).catch((err: Error) => {
        if (finished) {
          return;
        }
        finished = true;
        clearTimeout(timer);
        httpRequest.destroy();
        resolve({
          ok: false,
          remote: '',
          message: '检查更新失败，请检查网络后重试',
          hasUpdate: false
        } as UpdateCheckResult);
      });
    });
  }

  /**
   * 自动检查（**固定 48 小时一次**，用户要求）：
   * 距上次检查不足 48h 直接跳过；发现新版本用 toast 即时反馈（不弹窗打扰）。
   * 建议在应用启动 / 回到前台时调用（本方法内部已做节流与离线判断）。
   */
  static maybeAutoCheck(ctx: common.UIAbilityContext | null, notify: (message: string) => void): void {
    if (UpdateService.isOffline()) {
      return;
    }
    const last: number | undefined = AppStorage.get<number>('lastAutoCheckAt');
    const lastAt: number = last === undefined || last === null ? 0 : last;
    const now: number = Date.now();
    if (now - lastAt < AUTO_CHECK_INTERVAL) {
      return;
    }
    // 先落时间戳再请求：失败也不要在 48h 内反复重试（避免每次启动都打网络）；
    // 同时写一次 settings.json（第二腿，PersistentStorage 在部分设备不落盘）
    AppStorage.setOrCreate('lastAutoCheckAt', now);
    SettingsMirror.save(ctx);
    UpdateService.check().then((res: UpdateCheckResult) => {
      if (res.ok && res.hasUpdate) {
        notify('发现新版本 v' + res.remote + '，可在「探索中心 → 检查更新」查看');
        hilog.info(0x0000, 'UpdateService', 'auto check: new version %{public}s', res.remote);
      }
    }).catch(() => {
      // 自动检查失败静默（不打扰用户）
    });
  }
}
