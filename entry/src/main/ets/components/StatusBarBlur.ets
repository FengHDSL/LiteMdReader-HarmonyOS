/**
 * 澄笺 · 状态栏模糊垫层
 * ====================
 *
 * 阅读页最早加过这个效果（`Reader.ets` 根 Stack 里那段 `backdropBlur(6)`），
 * 现在所有**带悬浮顶栏**的页面共用同一份实现。
 *
 * **为什么需要**：页面根容器开了 `expandSafeArea`，内容会一路铺到屏幕顶端，
 * 悬浮胶囊顶栏上方的状态栏那一条等于直接压在文字 / 列表上，滚动时尤其脏。
 *
 * **为什么只吃这一段高度**：整屏实时模糊是《模糊场景性能优化》点名导致转场卡顿的
 * 写法（见 components/WallpaperImage.ets 的说明），这里只糊状态栏那条窄带，
 * 强度取 6 —— 与书架 cellBlur、长按面板遮罩同一档。
 *
 * **摆放规矩**：必须放在悬浮顶栏**之前**（同一层 Stack 里），这样顶栏画在模糊之上，
 * 胶囊本身不会被糊到；放在最后会把顶栏一起盖住。层本身 `hitTestBehavior(None)`，
 * 不吃任何点击，状态栏区域的手势照旧。
 */
@Component
export struct StatusBarBlur {
  /** 层的高度（vp）：传各页面自己的状态栏避让高度（padTop / safeTopVp 那一类） */
  @Prop heightVp: number = 0;
  /** 模糊强度，默认与阅读页同档 */
  @Prop strength: number = 6;

  build() {
    // 不用 if 包根节点：height 给 0 时这一层本来就不占位也不可见，
    // 而 build 的根写成 if 在自定义组件里是多出来的分支复杂度。
    Column()
      .width('100%')
      .height(this.heightVp)
      .position({ x: 0, y: 0 })
      .backdropBlur(this.strength)
      .hitTestBehavior(HitTestMode.None)
  }
}
