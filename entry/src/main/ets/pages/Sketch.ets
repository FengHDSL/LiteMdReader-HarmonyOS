/**
 * 澄笺 · 手写笔记（独立页，编辑页「手写」入口进入）
 * ============================
 *
 * **全部使用官方组件**（用户要求）：华为手写笔套件 Pen Kit 的
 * `HandwriteComponent`（画布 + 官方工具栏）与 `HandwriteController`。
 * 官方画布自带：手写笔 / 手指书写、报点预测、一笔成形、笔刷与编辑工具栏。
 *
 * 流程：手写 → 点「插入文档」→ `getThumbnail(getContentRange())` 取内容位图 →
 * `image.createImagePacker().packToData` 打成 PNG 字节 → `DocStore.saveImageBytes`
 * 落进 docs/images/（阅读器 / 预览的相对路径解析直接可用）→ 通过 AppStorage
 * `sketchInsertMd` 把 Markdown 片段传回编辑页 → 编辑页在光标处插入。
 *
 * 说明：Pen Kit 的 save() 只能存私有 .handwrite 格式（笔迹形状数据），
 * 「保存的图片插入文本」走的是缩略图位图导出，与手写源文件是两条通道。
 */
import { HandwriteComponent, HandwriteController, PenType } from '@kit.Penkit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DocStore } from '../service/DocStore';
import { HwSpace, HwType, ReaderPalette, paletteFor, isDarkTheme } from '../theme/DesignTokens';
import { ImmersiveIconButton } from '../material/ImmersiveCard';

@Component
export struct Sketch {
  stack: NavPathStack | null = null;
  /** Pen Kit 官方画布控制器 */
  controller: HandwriteController = new HandwriteController();
  /** 导出中标记（防重复点「插入文档」） */
  @State saving: boolean = false;
  @StorageProp('systemDark') systemDark: boolean = false;
  @StorageProp('readerThemeMode') themeMode: number = 0;

  private isDark(): boolean {
    return isDarkTheme(this.themeMode, this.systemDark);
  }

  private palette(): ReaderPalette {
    return paletteFor(this.themeMode, this.systemDark);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1800 });
    } catch (err) {
      // 忽略
    }
  }

  /**
   * 导出内容位图 → PNG → 落盘 docs/images/ → 通知编辑页插入。
   * 位图导出用官方 `getThumbnail(getContentRange())`（Pen Kit 提供的唯一
   * 像素级导出通道）；PNG 打包用官方 `image.createImagePacker()`。
   */
  private insertToDoc(): void {
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      this.controller.getThumbnail(this.controller.getContentRange())
        ?.then((pm: image.PixelMap) => {
          const packer: image.ImagePacker = image.createImagePacker();
          const packOpts: image.PackingOption = { format: 'image/png', quality: 100 };
          packer.packToData(pm, packOpts).then((data: ArrayBuffer) => {
            const c = this.getUIContext().getHostContext();
            if (c === undefined || c === null) {
              this.saving = false;
              this.toast('无法获取应用上下文');
              return;
            }
            const rel: string | null =
              DocStore.saveImageBytes(c as common.UIAbilityContext, data, '.png');
            packer.release();
            pm.release();
            if (rel === null) {
              this.saving = false;
              this.toast('手写图保存失败');
              return;
            }
            AppStorage.setOrCreate('sketchInsertMd', '\n![手写笔记](' + rel + ')\n');
            this.saving = false;
            if (this.stack !== null) {
              this.stack.pop();
            }
          }).catch((err: BusinessError) => {
            this.saving = false;
            this.toast('图片打包失败：' + err.message);
          });
        }).catch((err: BusinessError) => {
          this.saving = false;
          this.toast('获取手写内容失败：' + err.message);
        });
    } catch (err) {
      this.saving = false;
      this.toast('导出失败：' + (err as Error).message);
    }
  }

  build() {
    Column() {
      // ── 顶栏：返回 + 标题 + 插入按钮 ──
      Row({ space: HwSpace.sm }) {
        ImmersiveIconButton({
          buttonSize: 34,
          buttonMaterialShadow: false,
          palette: this.palette(),
          buttonOnTap: () => {
            if (this.stack !== null) {
              this.stack.pop();
            }
          }
        }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(20)
            .fontColor([this.palette().textPrimary])
        }

        Text('手写笔记')
          .fontSize(HwType.label + 3)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.palette().textPrimary)
          .layoutWeight(1)

        Text(this.saving ? '导出中…' : '插入文档')
          .fontSize(HwType.label)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDark() ? '#FF101014' : '#FFFFFFFF')
          .padding({ left: HwSpace.md, right: HwSpace.md, top: 7, bottom: 7 })
          .borderRadius(16)
          .backgroundColor(this.saving ? this.palette().divider : this.palette().accent)
          .onClick(() => {
            this.insertToDoc();
          })
      }
      .width('100%')
      .padding({ left: HwSpace.md, right: HwSpace.md, top: HwSpace.sm, bottom: HwSpace.sm })

      // ── 官方手写画布（自带工具栏：笔刷 / 橡皮 / 撤销等）──
      Column() {
        HandwriteComponent({
          handwriteController: this.controller,
          defaultPenType: PenType.PEN,
          widthRatio: 1,
          heightRatio: 1
        })
      }
      .layoutWeight(1)
      .width('100%')
      .borderRadius(12)
      .clip(true)
      .margin({ left: HwSpace.sm, right: HwSpace.sm, bottom: HwSpace.sm })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark() ? '#FF17171A' : '#FFF3F1EC')
  }
}
