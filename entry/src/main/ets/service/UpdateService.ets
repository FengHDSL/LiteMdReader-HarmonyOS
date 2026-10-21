/**
 * 澄笺 · 更新服务（检查更新 / 自动检查 / 使用模式）
 * ================================================
 *
 * 三个职责：
 *   ① **两个渠道各查一次，结果一起展示**（用户要求）：
 *      · `checkBeta()` —— **测试版**：拉 HAP 资源站详情页解析版本徽标
 *        （原实现从 SettingsExplore 抽出，手动与自动共用同一份网络与解析逻辑）；
 *      · `checkStore()` —— **正式版**：AppGallery Kit 的 `updateManager.checkAppUpdate()`，
 *        由应用市场自己比对在架版本（市场正式版通常比资源站晚几个版本）；
 *      · `checkAll()` —— 两条并发跑完，拼成逐行文案给页面显示。
 *   ② `maybeAutoCheck()` —— **固定 48 小时自动检查一次**（用户要求）：距上次检查
 *      不足 48h 直接跳过；任一渠道有更新用**默认即时反馈（toast）**提醒，不打扰式弹窗；
 *   ③ 使用模式：`appMode()` 为 'offline'（基础模式 / 纯离线）时，一切联网能力关停。
 *
 * ⚠️ `checkAppUpdate` 只在**从应用市场安装的包**上准；DevEco 直装的调试包多半回
 *    1009400002 / 1009400007，这时正式版那一行写清「查不到（非市场安装常见）」，
 *    不影响测试版那一行照常展示。
 *
 * 键：`lastAutoCheckAt`（毫秒时间戳）、`lastSeenVersion`（已提示过的版本）、
 * `appMode`（'' 未选择 / 'full' 全量 / 'offline' 基础）。
 */

import { common, bundleManager } from '@kit.AbilityKit';
import { updateManager } from '@kit.AppGalleryKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingsMirror } from './SettingsMirror';
import { L10n } from './L10n';

/** HAP 资源站详情页（用户指定）：页面上有版本徽标 vX.Y.Z */
export const UPDATE_SITE: string = 'https://www.sydxky.cn/detail.php?id=956';
/** 单次请求与手动检查的超时（毫秒） */
export const UPDATE_TIMEOUT: number = 8000;
/** 自动检查间隔：48 小时 */
const AUTO_CHECK_INTERVAL: number = 48 * 60 * 60 * 1000;

export const APP_MODE_FULL: string = 'full';
export const APP_MODE_OFFLINE: string = 'offline';

/** 单个渠道的检查结果（测试版 = HAP 资源站；正式版 = 华为应用市场） */
export interface ChannelResult {
  /** 渠道名（已本地化，逐行显示时做前缀） */
  label: string;
  ok: boolean;
  /** 该渠道在架版本（不含 v 前缀）；查不到时为空串 */
  remote: string;
  /** 该渠道比当前版本新 */
  hasUpdate: boolean;
  /** 一行结果文案（弹窗逐行显示与 toast 摘要都用它拼） */
  line: string;
}

/** 两个渠道合并后的结果（用户要求：检查结果两条一起展示） */
export interface UpdateCheckAllResult {
  beta: ChannelResult;
  store: ChannelResult;
  /** 任一渠道有更新 */
  hasUpdate: boolean;
  /** 弹窗正文：测试版一行、正式版一行 */
  lines: string[];
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

  /** 渠道失败行：ok=false、没有版本号，只有一行原因文案 */
  private static fail(label: string, reason: string): ChannelResult {
    return {
      label: label, ok: false, remote: '', hasUpdate: false,
      line: label + '：' + reason
    } as ChannelResult;
  }

  /**
   * 测试版渠道：拉 HAP 资源站详情页解析版本徽标（8 秒超时保护）。
   * 基础模式（纯离线）下不发任何请求，直接返回「离线模式不可用」。
   */
  static checkBeta(): Promise<ChannelResult> {
    const label: string = L10n.t('测试版（HAP 资源站）');
    const current: string = UpdateService.currentVersion();
    if (UpdateService.isOffline()) {
      return Promise.resolve(UpdateService.fail(label, L10n.t('当前是基础模式（纯离线），检查更新不可用')));
    }
    return new Promise<ChannelResult>((resolve) => {
      let finished: boolean = false;
      const timer = setTimeout(() => {
        if (!finished) {
          finished = true;
          resolve(UpdateService.fail(label, L10n.t('检查更新超时，请稍后再试')));
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
          resolve(UpdateService.fail(label, L10n.t('检查更新失败，解析不到版本号')));
          return;
        }
        const cmp: number = UpdateService.compareVersion(current, remote);
        const detail: string = cmp < 0
          ? L10n.t('可更新 v') + remote + L10n.t('（当前 v') + current + '）'
          : (cmp > 0
            ? L10n.t('在架 v') + remote + L10n.t('，当前版本比它更高')
            : L10n.t('已是最新（v') + current + '）');
        resolve({
          label: label, ok: true, remote: remote, hasUpdate: cmp < 0,
          line: label + '：' + detail
        } as ChannelResult);
      }).catch((err: Error) => {
        if (finished) {
          return;
        }
        finished = true;
        clearTimeout(timer);
        httpRequest.destroy();
        resolve(UpdateService.fail(label, L10n.t('检查更新失败，请检查网络后重试')));
      });
    });
  }

  /**
   * 正式版渠道：`updateManager.checkAppUpdate()` —— **由应用市场自己比对**在架版本与
   * 本机安装的 versionCode，只回 `updateAvailable`（0 没有更新 / 1 有更新）。
   * 8 秒超时保护同测试版。
   * ⚠️ 非市场安装的包（DevEco 直装的调试包）通常直接报错，那一行写清原因即可，
   *    不影响测试版那一行展示。
   */
  static checkStore(ctx: common.UIAbilityContext | null): Promise<ChannelResult> {
    const label: string = L10n.t('正式版（华为应用市场）');
    const current: string = UpdateService.currentVersion();
    if (UpdateService.isOffline()) {
      return Promise.resolve(UpdateService.fail(label, L10n.t('当前是基础模式（纯离线），检查更新不可用')));
    }
    if (ctx === null) {
      return Promise.resolve(UpdateService.fail(label, L10n.t('取不到应用上下文')));
    }
    return new Promise<ChannelResult>((resolve) => {
      let finished: boolean = false;
      const timer = setTimeout(() => {
        if (!finished) {
          finished = true;
          resolve(UpdateService.fail(label, L10n.t('应用市场没有响应，请稍后再试')));
        }
      }, UPDATE_TIMEOUT);
      const settle = (res: ChannelResult): void => {
        if (finished) {
          return;
        }
        finished = true;
        clearTimeout(timer);
        resolve(res);
      };
      let call: Promise<updateManager.CheckUpdateResult>;
      try {
        call = updateManager.checkAppUpdate(ctx);
      } catch (err) {
        // 同步抛（缺 syscap、非前台、上下文不合法）：只挂 promise 的 catch 接不到
        settle(UpdateService.fail(label, UpdateService.storeReason(err as BusinessError)));
        return;
      }
      call.then((res: updateManager.CheckUpdateResult) => {
        // **比对是应用市场自己做的**：它拿本机 versionCode 跟在架版本比，只回一个结论。
        // CheckUpdateResult 的 versionName / versionCode 官方注明「只对元服务开放」，
        // 普通应用恒为空 → 这一行只写「有没有更新 + 当前版本」，不假装知道在架版本号。
        const available: boolean = res.updateAvailable === updateManager.UpdateAvailableCode.LATER_VERSION_EXIST;
        hilog.info(0x0000, 'UpdateService', 'store check: available=%{public}d', res.updateAvailable);
        settle({
          label: label, ok: true, remote: '', hasUpdate: available,
          // 市场不回在架版本号（versionName 元服务专用），所以只说「比当前新不新」，
          // 不谎报「已是最新」（用户要求）
          line: label + '：' + (available
            ? L10n.t('有比当前（v') + current + L10n.t('）更新的新版本，在架版本号应用市场不返回')
            : L10n.t('没有比当前（v') + current + L10n.t('）更新的版本，在架版本号应用市场不返回'))
        } as ChannelResult);
      }).catch((err: BusinessError) => {
        hilog.warn(0x0000, 'UpdateService', 'store check failed code=%{public}d',
          err === null || err === undefined ? 0 : err.code);
        settle(UpdateService.fail(label, UpdateService.storeReason(err)));
      });
    });
  }

  /** 应用市场检查更新的官方错误码 → 中文原因 */
  private static storeReason(err: BusinessError): string {
    const code: number = err === null || err === undefined ? 0 : err.code;
    if (code === 1009400003) {
      return L10n.t('网络不通，请检查网络后重试');
    }
    if (code === 1009400004) {
      return L10n.t('应用不在前台，请回到应用后再查');
    }
    if (code === 1009400005) {
      return L10n.t('请先同意应用市场的隐私协议');
    }
    if (code === 1009400006) {
      return L10n.t('查询过于频繁，请稍后再试');
    }
    // 401 / 1009400001 / 2 / 7 与其它：调试直装的包最常见的就是这一类
    return L10n.t('查不到（非应用市场安装的包通常查不到）');
  }

  /**
   * 两个渠道并发跑完，拼成逐行结果（用户要求：检查结果两条一起展示）。
   * 顺序固定：测试版在前、正式版在后。
   */
  static checkAll(ctx: common.UIAbilityContext | null): Promise<UpdateCheckAllResult> {
    const betaP: Promise<ChannelResult> = UpdateService.checkBeta();
    const storeP: Promise<ChannelResult> = UpdateService.checkStore(ctx);
    return Promise.all([betaP, storeP]).then((list: ChannelResult[]) => {
      const beta: ChannelResult = list[0];
      const store: ChannelResult = list[1];
      return {
        beta: beta, store: store,
        hasUpdate: beta.hasUpdate || store.hasUpdate,
        lines: [beta.line, store.line]
      } as UpdateCheckAllResult;
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
    UpdateService.checkAll(ctx).then((res: UpdateCheckAllResult) => {
      if (!res.hasUpdate) {
        return;
      }
      const parts: string[] = [];
      if (res.beta.hasUpdate) {
        parts.push(L10n.t('测试版') + ' v' + res.beta.remote);
      }
      if (res.store.hasUpdate) {
        parts.push(L10n.t('正式版'));
      }
      notify(L10n.t('发现新版本（') + parts.join(' / ') + L10n.t('），可在「探索中心 → 检查更新」查看'));
      hilog.info(0x0000, 'UpdateService', 'auto check: beta=%{public}s store=%{public}s',
        res.beta.remote, res.store.remote);
    }).catch(() => {
      // 自动检查失败静默（不打扰用户）
    });
  }
}
