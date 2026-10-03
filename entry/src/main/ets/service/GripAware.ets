import { motion } from '@kit.MultimodalAwarenessKit';
import { abilityAccessCtrl, common, PermissionRequestResult } from '@kit.AbilityKit';

/**
 * 智感握姿（参考官方 SmartReach 示例的思路）。
 *
 * 官方示例用 HdsTabs 内建的「悬浮 + 跟手」能力；本工程底栏是自绘胶囊，
 * 所以这里只取**握持手/操作手**这一路信号，用来决定胶囊贴近左边还是右边。
 *
 * 权限：`ohos.permission.DETECT_GESTURE`（API 20 起）。
 * **设备不支持或未授权时全部静默降级**：回调给 0（居中），不抛异常、不影响其它功能。
 *
 * 用法：
 *   GripAware.start((side) => { this.gripSide = side; });   // side: -1 左 / 0 居中 / 1 右
 *   GripAware.stop();
 */
export class GripAware {
  private static running: boolean = false;
  private static notify: (side: number) => void = () => {
  };
  /** 持有回调引用才能在 off 时精确解绑 */
  private static holdingCb: (status: motion.HoldingHandStatus) => void = () => {
  };
  /** 操作手回调引用（同类设备只派发该事件） */
  private static operatingCb: (status: motion.OperatingHandStatus) => void = () => {
  };

  /**
   * **带权限申请的开始**：`ohos.permission.DETECT_GESTURE` 是 user_grant 权限，
   * 必须在运行时申请 —— 之前只声明未申请，`motion.on` 直接抛错被静默吞掉，
   * gripSide 恒为 0，表现为"智感握姿完全失效"（用户反馈底部栏与选择胶囊都不跟手）。
   * 已授权时不会重复弹窗；用户拒绝则本次会话内不再打扰。
   */
  static async startWithPermission(ctx: common.UIAbilityContext,
                                   onChange: (side: number) => void): Promise<void> {
    GripAware.notify = onChange;
    if (GripAware.running) {
      return;
    }
    const asked: boolean = AppStorage.get<boolean>('gripPermissionAsked') ?? false;
    let granted: boolean = false;
    try {
      const mgr: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      // 已授权时 requestPermissionsFromUser 会直接返回授权结果，不弹窗
      const res: PermissionRequestResult =
        await mgr.requestPermissionsFromUser(ctx, ['ohos.permission.DETECT_GESTURE']);
      granted = res.authResults.length > 0 && res.authResults[0] === 0;
      AppStorage.setOrCreate('gripPermissionAsked', true);
    } catch (err) {
      granted = asked; // 申请失败：若此前授权过仍继续尝试监听
    }
    if (!granted && !asked) {
      // 用户本次拒绝：静默降级（gripSide 保持 0，胶囊不偏移）
      return;
    }
    GripAware.start(onChange);
  }

  /** 开始监听。重复调用只保留最后一次回调。 */
  static start(onChange: (side: number) => void): void {
    GripAware.notify = onChange;
    if (GripAware.running) {
      return;
    }
    GripAware.holdingCb = (status: motion.HoldingHandStatus) => {
      GripAware.notify(GripAware.sideOfHolding(status));
    };
    // **操作手监听**：部分设备不派发 holdingHandChanged（只更新"最近操作手"），
    // 只挂持握手事件会出现"智感握姿不跟手"——补一路操作手变化事件。
    GripAware.operatingCb = (status: motion.OperatingHandStatus) => {
      GripAware.notify(GripAware.sideOfOperating(status));
    };
    try {
      motion.on('holdingHandChanged', GripAware.holdingCb);
      GripAware.running = true;
    } catch (err) {
      // 设备无该能力 / 未授权：保持居中，不打扰用户
      GripAware.running = false;
    }
    try {
      motion.on('operatingHandChanged', GripAware.operatingCb);
    } catch (err) {
      // 没有该事件：忽略（持握手事件仍生效）
    }
    try {
      // 首帧先取一次「最近一次操作手」，否则要等用户动一下才有反应
      GripAware.notify(GripAware.sideOfOperating(motion.getRecentOperatingHandStatus()));
    } catch (err) {
      // 忽略
    }
  }

  static stop(): void {
    if (!GripAware.running) {
      return;
    }
    try {
      motion.off('holdingHandChanged', GripAware.holdingCb);
    } catch (err) {
      // 忽略：解绑失败不影响功能
    }
    try {
      motion.off('operatingHandChanged', GripAware.operatingCb);
    } catch (err) {
      // 忽略
    }
    GripAware.running = false;
  }

  /** 当前握持手（不再监听时也可问一次）。 */
  static recentSide(): number {
    try {
      return GripAware.sideOfOperating(motion.getRecentOperatingHandStatus());
    } catch (err) {
      return 0;
    }
  }

  /** 握持手 → 左右：双手握持按「不偏移」处理（居中更稳）。 */
  private static sideOfHolding(status: motion.HoldingHandStatus): number {
    if (status === motion.HoldingHandStatus.LEFT_HAND_HELD) {
      return -1;
    }
    if (status === motion.HoldingHandStatus.RIGHT_HAND_HELD) {
      return 1;
    }
    return 0;
  }

  private static sideOfOperating(status: motion.OperatingHandStatus): number {
    if (status === motion.OperatingHandStatus.LEFT_HAND_OPERATED) {
      return -1;
    }
    if (status === motion.OperatingHandStatus.RIGHT_HAND_OPERATED) {
      return 1;
    }
    return 0;
  }
}
