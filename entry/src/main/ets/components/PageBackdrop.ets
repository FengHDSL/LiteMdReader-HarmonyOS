/**
 * 澄笺 · 页面背景（与设置页同一套优先级）
 * ======================================
 *
 * 优先级：手选壁纸（深浅分档）→ 函数壁纸（plain 纯底）→ 主题渐变。
 * 从 SettingsShell 的同一段背景逻辑抽出，**法务页（隐私政策 / 用户协议）也用它**——
 * 此前法务页只铺了一层纯色 pageBottom，与探索中心的背景对不上（用户反馈）。
 *
 * 用法：宿主页面根 Stack 的第一个子节点传本组件，给 palette + dark 即可。
 */
import { GenWallpaper } from '../theme/GenWallpaper';
import { WallpaperStore } from '../service/WallpaperStore';
import { LIGHT_PALETTE, ReaderPalette } from '../theme/DesignTokens';

@Component
export struct PageBackdrop {
  /**
   * 调色板（由宿主传入，避免组件内重复读全局态）。
   * ⚠️ **必须 @Prop**：普通成员只在组件创建时赋值一次，主题切换后不更新 →
   * 背景渐变停留在旧配色（深色下发灰、浅色下发白）。
   */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /** 是否深色（决定取哪一档手选壁纸与遮罩） */
  @Prop dark: boolean = false;
  /** 纯底模式：设置类页面不画两个光斑圆（与设置页一致） */
  @Prop plain: boolean = true;
  @StorageProp('wallpaperPath') wallpaperPath: string = '';
  @StorageProp('wallpaperPathLight') wallpaperPathLight: string = '';
  @StorageProp('wallpaperPathDark') wallpaperPathDark: string = '';
  @StorageProp('wallpaperGenId') genWallId: string = '';
  @StorageProp('wallpaperBlur') wallpaperBlur: number = 4;
  @StorageProp('wallpaperScrim') wallpaperScrim: number = 42;

  /** 当前生效的手选壁纸路径（深浅各自回落全局项）。 */
  private effectivePath(): string {
    if (this.dark) {
      return this.wallpaperPathDark.length > 0 ? this.wallpaperPathDark : this.wallpaperPath;
    }
    return this.wallpaperPathLight.length > 0 ? this.wallpaperPathLight : this.wallpaperPath;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.effectivePath().length > 0) {
        Image(WallpaperStore.imageSourceOf(this.effectivePath()))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(this.wallpaperBlur)

        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.dark))
      } else if (this.genWallId.length > 0) {
        GenWallpaper({ styleId: this.genWallId, darkMode: this.dark, plain: this.plain })

        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.dark))
      } else {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [[this.palette.pageTop, 0.0], [this.palette.pageBottom, 1.0]]
          })
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }
}
