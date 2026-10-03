/**
 * 澄笺 · 面板内的「开关磁贴」（自持状态，翻开关当帧刷新）
 * ========================================================
 *
 * 根因：`bindSheet` 的 builder 不会跟随宿主 @StorageLink 重渲染——把开关直接写在
 * 宿主的 @Builder 里时，点了开关标签不变、要退出面板重进才更新（用户反馈，
 * 换容器 key 的写法也不稳）。
 *
 * 解法：把「读状态 + 显示 + 切换」放进**独立子组件**。组件自己订阅 @StorageLink，
 * 自己写状态 → 自己重渲染，与宿主 builder 是否重建无关。
 *
 * 三个键各一个实例：
 *   · kind='meta'   → readerShowMeta（信息卡显示 / 隐藏）
 *   · kind='drawer' → drawerImmersive（目录 / 批注侧边栏沉浸光感）
 *   · kind='tabbar' → readerTabBarAtBottom（标签栏在顶栏下 / 底部悬浮栏上方，
 *                     图标用 chevron_up.svg / chevron_down_l.svg，跟随状态实时切换）
 */
import { HwRadius, HwType, LIGHT_PALETTE, ReaderPalette } from '../theme/DesignTokens';

@Component
export struct ReaderFlagTile {
  /** 'meta' = 信息卡；'drawer' = 侧边栏光感；'tabbar' = 标签栏位置 */
  @Prop kind: string = 'meta';
  /** 调色板：**必须 @Prop**，否则主题切换后不更新（普通成员只在创建时赋值一次） */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /** 切换后回调（宿主弹 toast 用；传新值） */
  onChanged: (on: boolean) => void = (on: boolean) => {
  };
  @StorageLink('readerShowMeta') showMeta: boolean = true;
  @StorageLink('drawerImmersive') drawerOn: boolean = true;
  @StorageLink('readerTabBarAtBottom') tabBarBottom: boolean = false;

  /** 当前是否开启（按 kind 取对应键）。 */
  private isOn(): boolean {
    return this.kind === 'meta' ? this.showMeta
      : (this.kind === 'drawer' ? this.drawerOn : this.tabBarBottom);
  }

  /** 磁贴文案（读数在本组件内，切换当帧刷新）。 */
  private label(): string {
    if (this.kind === 'meta') {
      return this.showMeta ? '隐藏信息卡' : '显示信息卡';
    }
    if (this.kind === 'drawer') {
      return this.drawerOn ? '侧边栏光感：开' : '侧边栏光感：关';
    }
    return this.tabBarBottom ? '标签栏：底部' : '标签栏：顶部';
  }

  build() {
    Column({ space: 6 }) {
      // 标签栏位置用用户提供的 SVG（顶 / 底两张），其余两种用系统符号
      if (this.kind === 'tabbar') {
        Image(this.tabBarBottom ? $r('app.media.chevron_down_l') : $r('app.media.chevron_up'))
          .width(22)
          .height(22)
          .fillColor(this.palette.accent)
          .objectFit(ImageFit.Contain)
      } else {
        SymbolGlyph(this.kind === 'meta' ? $r('sys.symbol.info_circle') : $r('sys.symbol.square_grid_2x2'))
          .fontSize(22)
          .fontColor([this.isOn() ? this.palette.accent : this.palette.textTertiary])
      }
      Text(this.label())
        .fontSize(HwType.caption)
        .fontColor(this.palette.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .height(72)
    .justifyContent(FlexAlign.Center)
    .borderRadius(HwRadius.inner)
    .backgroundColor(this.palette.quoteBg)
    .onClick(() => {
      const next: boolean = !this.isOn();
      if (this.kind === 'meta') {
        this.showMeta = next;
      } else if (this.kind === 'drawer') {
        this.drawerOn = next;
      } else {
        this.tabBarBottom = next;
      }
      this.onChanged(next);
    })
  }
}
