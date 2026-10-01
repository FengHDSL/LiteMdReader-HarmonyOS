import { motion } from '@kit.MultimodalAwarenessKit';

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

  /** 开始监听。重复调用只保留最后一次回调。 */
  static start(onChange: (side: number) => void): void {
    GripAware.notify = onChange;
    if (GripAware.running) {
      return;
    }
    GripAware.holdingCb = (status: motion.HoldingHandStatus) => {
      GripAware.notify(GripAware.sideOfHolding(status));
    };
    try {
      motion.on('holdingHandChanged', GripAware.holdingCb);
      GripAware.running = true;
      // 首帧先取一次「最近一次操作手」，否则要等用户动一下才有反应
      GripAware.notify(GripAware.sideOfOperating(motion.getRecentOperatingHandStatus()));
    } catch (err) {
      // 设备无该能力 / 未授权：保持居中，不打扰用户
      GripAware.running = false;
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
