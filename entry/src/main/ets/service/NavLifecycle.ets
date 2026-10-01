/**
 * 页面生命周期转发。
 *
 * 迁移到 Navigation 之后，`@Entry` 页的 `onPageShow` / `onPageHide` 不再触发，
 * 改由 `NavDestination` 的 `onShown` / `onHidden` 提供。
 * 但页面组件的生命周期方法无法被父组件直接调用，所以用一个极小的转发对象：
 *
 *   · 页面在 `aboutToAppear` 里把回调挂上来：`this.life.onShow = () => { ... }`
 *   · `NavDestination` 的 `onShown` 调用 `life.onShow()`
 *
 * 这样页面内部的原有生命周期逻辑一行都不用改。
 */
export class NavLifecycle {
  /** 页面显示（含从下级页面返回） */
  onShow: () => void = () => {
  };
  /** 页面隐藏（被下级页面盖住） */
  onHide: () => void = () => {
  };
}
