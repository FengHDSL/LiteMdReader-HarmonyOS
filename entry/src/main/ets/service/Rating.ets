/**
 * 澄笺 · 好评鼓励（应用市场应用内评分）
 * =====================================
 *
 * 用 AppGallery Kit 的 `commentManager.showCommentDialog()` 在**应用内**弹官方评分框，
 * 不跳市场详情页（用户要求）。两个入口：
 *   ① 探索中心「好评鼓励」芯片 —— 用户主动点，失败一定给一句明确提示；
 *   ② `maybeAutoAsk()` —— **安装满 24 小时自动弹一次**（用户要求，避免打扰）：
 *      安装时间取 `bundleManager` 的 `installTime`；真弹出来过就写 `ratingPrompted`
 *      落盘，本机从此不再自动弹。弹窗**没**真正出现（未登录 / 连不上市场 / 系统错误）
 *      时不记账，下次启动还有一次机会 —— 没打扰到任何人，不算「弹过」。
 *      基础模式（纯离线）不自动弹。
 *
 * ⚠️ 这个 API 只有真机 + 已登录华为账号才有效（`@stagemodelonly`，since 6.0.0(20)），
 *    模拟器、无应用市场的设备会直接报错；错误码全部按官方表格映射成中文提示，
 *    异常一律 try/catch 兜住，绝不让它冒到调用方。
 */

import { commentManager } from '@kit.AppGalleryKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { L10n } from './L10n';
import { SettingsMirror } from './SettingsMirror';
import { UpdateService } from './UpdateService';

/** 自动求好评的安装时长门槛：24 小时 */
const RATE_AFTER_INSTALL_MS: number = 24 * 60 * 60 * 1000;

/**
 * ⚠️ **测试开关**（用户要求先立刻弹，方便真机验证）：
 * true = 跳过 24 小时门槛，进书架 2.5 秒后就弹。
 * **验证完改回 false**，自动询问即恢复「安装满 24 小时才弹、且只弹一次」。
 */
const RATE_TEST_IMMEDIATE: boolean = true;

/** 自动弹窗的启动延迟（毫秒）：等书架首帧与「本次更新内容」弹窗收场，别叠一层 */
const RATE_START_DELAY: number = 2500;

/** 本会话内是否已经安排过自动询问（书架 aboutToAppear / onShow 会重复触发） */
let autoScheduled: boolean = false;

export class Rating {
  /** 「本机已经自动弹过一次好评」的持久化键（EntryAbility 注册，SettingsMirror 带走） */
  static readonly PROMPTED_KEY: string = 'ratingPrompted';

  /**
   * 弹出应用市场评分框。
   * @returns true = 弹窗真的出现过，或本机已经评过分（自动询问就此收工，别再打扰）
   */
  static ask(ctx: common.UIAbilityContext, notify: (message: string) => void): Promise<boolean> {
    return commentManager.showCommentDialog(ctx).then(() => {
      hilog.info(0x0000, 'Rating', 'comment dialog shown');
      return true;
    }).catch((err: BusinessError) => {
      const code: number = err === null || err === undefined ? 0 : err.code;
      notify(Rating.messageFor(code));
      hilog.warn(0x0000, 'Rating', 'showCommentDialog failed code=%{public}d', code);
      // 「这个版本评过了」/「一年内评过了」= 用户已经支持过，自动询问不必再来
      return code === 1021500007 || code === 1021500009;
    });
  }

  /**
   * 自动求好评：安装满 24 小时 + 本机没弹过 → 延迟一会儿弹一次。
   * 与 `UpdateService.maybeAutoCheck` 同形，由书架 `aboutToAppear` 调用。
   */
  static maybeAutoAsk(ctx: common.UIAbilityContext | null, notify: (message: string) => void): void {
    if (autoScheduled || ctx === null) {
      return;
    }
    if (Rating.prompted()) {
      return;
    }
    // 基础模式（纯离线）：一切联网能力关停，评分框也走应用市场，直接跳过
    if (UpdateService.isOffline()) {
      return;
    }
    if (!RATE_TEST_IMMEDIATE && !Rating.installedLongEnough()) {
      return;
    }
    autoScheduled = true;
    setTimeout(() => {
      Rating.ask(ctx, notify).then((done: boolean) => {
        if (done) {
          Rating.markPrompted(ctx);
        }
      });
    }, RATE_START_DELAY);
  }

  /** 安装时长是否已满门槛（读不到 installTime 就当作未满，宁可不弹） */
  private static installedLongEnough(): boolean {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const at: number = info.installTime;
      return at > 0 && Date.now() - at >= RATE_AFTER_INSTALL_MS;
    } catch (err) {
      return false;
    }
  }

  private static prompted(): boolean {
    const v: boolean | undefined = AppStorage.get<boolean>(Rating.PROMPTED_KEY);
    return v === true;
  }

  /** 记账：AppStorage + settings.json 第二腿（PersistentStorage 在部分设备不真正落盘） */
  private static markPrompted(ctx: common.UIAbilityContext): void {
    AppStorage.setOrCreate(Rating.PROMPTED_KEY, true);
    SettingsMirror.save(ctx);
  }

  /** 官方错误码 → 中文提示（未列出的码统一走最后那句） */
  private static messageFor(code: number): string {
    if (code === 1021500006) {
      return L10n.t('请先登录华为账号，再给澄笺评分');
    }
    if (code === 1021500007) {
      return L10n.t('这个版本你已经评价过澄笺了，谢谢支持');
    }
    if (code === 1021500008) {
      return L10n.t('评价次数已达上限，谢谢你的支持');
    }
    if (code === 1021500009) {
      return L10n.t('你最近评价过澄笺，满一年后可以再次评分');
    }
    if (code === 1021500003) {
      return L10n.t('连不上应用市场，请稍后再试');
    }
    // 1021500000 / 1 / 2 / 4 / 5 与未知码：统一一句，不把系统内部错误码甩给用户
    return L10n.t('评分弹窗暂时不可用，请稍后再试');
  }
}
