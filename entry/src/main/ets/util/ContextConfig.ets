/**
 * LiteMdReader · 全局 UIAbilityContext 持有者
 * ============================================
 *
 * 手写组件（PenKit 的 HandwriteComponent）在部分实现路径上需要拿到 UIAbilityContext，
 * 而组件内部拿不到页面上下文，所以启动时把 context 存到一个全局可访问的位置。
 *
 * 官方 PenKit 示例要求使用 `globalThis` 存储 —— PenKit 原生引擎内通过
 * `globalThis._brushEngineContext` 查找 ability 上下文，模块级变量找不到会闪退。
 */
import { common } from '@kit.AbilityKit';

declare namespace globalThis {
  let _brushEngineContext: common.UIAbilityContext | undefined;
}

export default class GlobalUIAbilityContext {
  /** 取 Ability 上下文。未初始化时返回 null，调用方必须判空。 */
  static getContext(): common.UIAbilityContext | null {
    return globalThis._brushEngineContext ?? null;
  }

  /** 在 EntryAbility.onWindowStageCreate 中调用一次。 */
  static setContext(context: common.UIAbilityContext): void {
    globalThis._brushEngineContext = context;
  }
}
