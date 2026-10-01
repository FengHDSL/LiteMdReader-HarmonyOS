/**
 * LiteMdReader · 全局 UIAbilityContext 持有者
 * ============================================
 *
 * 手写组件（PenKit 的 HandwriteComponent）在部分实现路径上需要拿到 UIAbilityContext，
 * 而组件内部拿不到页面上下文，所以启动时把 context 存到一个全局可访问的位置。
 *
 * 与官方样例的差别：官方样例用 `declare namespace globalThis` 给 globalThis 挂字段，
 * 这里改用**模块级变量**。ESM 模块在同一个应用内是单例，语义完全等价，
 * 但不必依赖 globalThis 的全局类型增强——后者在 ArkTS 的严格检查下容易出问题。
 * 对外 API（GlobalUIAbilityContext.getContext / setContext）与样例保持一致。
 */

import { common } from '@kit.AbilityKit';

let appContext: common.UIAbilityContext | null = null;

export default class GlobalUIAbilityContext {
  /** 取 Ability 上下文。未初始化时返回 null，调用方必须判空。 */
  static getContext(): common.UIAbilityContext | null {
    return appContext;
  }

  /** 在 EntryAbility.onCreate 中调用一次。 */
  static setContext(context: common.UIAbilityContext): void {
    appContext = context;
  }
}
