import { ComponentContent, UIContext } from '@kit.ArkUI';
import { ToastCard } from '../components/ToastCard';

/**
 * 澄笺 · 带沉浸光感的即时反馈（ToastFx）
 * ====================================
 *
 * 系统 `showToast` 不能自定义外观（用户要求 toast 也要有沉浸光感），所以改走
 * 「ComponentContent + openCustomDialog」：内容是我们自己的 `ToastCard`（ImmersiveCard 承载，
 * 光感开＝系统材质，关＝实色 + 恒定包边），**不需要在页面里挂宿主**，
 * 任何页面（含半模态面板、子组件）都能直接调用。
 *
 * 约定：
 *  · 后一条提示会先关掉前一条（避免两条叠在一起）；
 *  · `isModal: false`：toast 不能拦住用户后续操作；
 *  · 取不到 UIContext 时宿主自己兜底走系统 toast（见各页 toast() 方法）。
 */
interface ToastParams {
  message: string;
}

/** 默认停留时长（与原 showToast 的 1800ms 对齐） */
const TOAST_HOLD: number = 1800;

@Builder
function toastCardBuilder(p: ToastParams) {
  ToastCard({ message: p.message })
}

export class ToastFx {
  private static content: ComponentContent<ToastParams> | null = null;
  private static holdTimer: number = -1;

  /** 显示一条提示（duration 毫秒；<=0 用默认 1800） */
  static show(ui: UIContext, message: string, duration: number = TOAST_HOLD): void {
    if (message.length === 0) {
      return;
    }
    ToastFx.hide(ui);
    const hold: number = duration > 0 ? duration : TOAST_HOLD;
    try {
      const params: ToastParams = { message: message };
      const cc: ComponentContent<ToastParams> = new ComponentContent(ui,
        wrapBuilder(toastCardBuilder), params);
      ToastFx.content = cc;
      ui.getPromptAction().openCustomDialog(cc, {
        alignment: DialogAlignment.Bottom,
        offset: { dx: 0, dy: -86 },
        autoCancel: false,
        // 非模态：提示浮在上面，但不吃掉用户的滚动 / 点击
        isModal: false,
        maskColor: '#00000000'
      }).then(() => {
        ToastFx.holdTimer = setTimeout(() => {
          ToastFx.holdTimer = -1;
          ToastFx.hide(ui);
        }, hold);
      }).catch(() => {
        // 自绘失败 → 退系统 toast，保证提示不丢
        ToastFx.content = null;
        ToastFx.sysToast(ui, message, hold);
      });
    } catch (err) {
      ToastFx.content = null;
      ToastFx.sysToast(ui, message, hold);
    }
  }

  /** 系统 toast 兜底（自绘链路不可用时用） */
  private static sysToast(ui: UIContext, message: string, duration: number): void {
    try {
      ui.getPromptAction().showToast({ message: message, duration: duration });
    } catch (err) {
      // 提示失败无副作用
    }
  }

  /** 立刻收掉当前提示（重复提示 / 页面离开时调用） */
  static hide(ui: UIContext): void {
    if (ToastFx.holdTimer !== -1) {
      clearTimeout(ToastFx.holdTimer);
      ToastFx.holdTimer = -1;
    }
    const cc: ComponentContent<ToastParams> | null = ToastFx.content;
    ToastFx.content = null;
    if (cc === null) {
      return;
    }
    try {
      ui.getPromptAction().closeCustomDialog(cc);
    } catch (err) {
      // 已经关了 / 上下文已销毁：忽略
    }
  }
}
