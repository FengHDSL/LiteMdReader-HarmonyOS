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
import type { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { DocStore } from '../service/DocStore';
import { HwSpace, HwType, ReaderPalette, paletteFor, isDarkTheme } from '../theme/DesignTokens';
import { ImmersiveChip, ImmersiveIconButton } from '../material/ImmersiveCard';

@Component
export struct Sketch {
  stack: NavPathStack | null = null;
  /** Pen Kit 官方画布控制器 */
  private controller: HandwriteController = new HandwriteController();
  /** 手写文件路径 */
  private handwritePath: string = '';
  /** 本轮已把内容交付出去（插入文档 / 完成批注）：退出时不要再存回笔迹，
   *  这样下次进来是**空画布**（用户要求"插入后界面自动清空"）。 */
  private delivered: boolean = false;
  /** 导出中标记（防重复点「插入文档」） */
  @State saving: boolean = false;
  @StorageProp('systemDark') systemDark: boolean = false;
  @StorageProp('readerThemeMode') themeMode: number = 0;
  /** 顶部安全区（px）：顶栏据此避让系统状态栏 */
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  /** 手写页用途：'annotate' = 作为文本批注（返回时回传 sketchAnnotationImage） */
  @StorageProp('sketchMode') sketchMode: string = '';

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

  aboutToAppear(): void {
    // 按官方示例，aboutToAppear 不操作 controller
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx !== null && ctx !== undefined) {
      this.handwritePath = ctx.filesDir + '/sketch.handwrite';
    }
  }

  /**
   * 把手写位图合成到**浅灰底**上（用户要求：避免深色模式下看不清内容）。
   * 按源像素的实际格式解码，做常规 alpha 混合；失败时原样返回。
   */
  private static async composeOnGray(src: image.PixelMap): Promise<image.PixelMap> {
    const BG: number = 244;
    try {
      const info: image.ImageInfo = await src.getImageInfo();
      const w: number = info.size.width;
      const h: number = info.size.height;
      const fmt: image.PixelMapFormat = info.pixelFormat;
      let bpp: number = 0;
      if (fmt === image.PixelMapFormat.RGB_565) {
        bpp = 2;
      } else if (fmt === image.PixelMapFormat.RGB_888) {
        bpp = 3;
      } else if (fmt === image.PixelMapFormat.RGBA_8888) {
        bpp = 4;
      }
      if (bpp === 0) {
        return src;
      }
      let rowBytes: number = w * bpp;
      try {
        rowBytes = src.getBytesNumberPerRow();
      } catch (rowErr) {
        rowBytes = w * bpp;
      }
      const raw: ArrayBuffer = new ArrayBuffer(rowBytes * h);
      await src.readPixelsToBuffer(raw);
      const s8: Uint8Array = new Uint8Array(raw);
      const out: Uint8Array = new Uint8Array(w * h * 4);
      for (let y = 0; y < h; y++) {
        const rowOff: number = y * rowBytes;
        const outOff: number = y * w * 4;
        for (let x = 0; x < w; x++) {
          const i: number = rowOff + x * bpp;
          const o: number = outOff + x * 4;
          let r: number = 0;
          let g: number = 0;
          let b: number = 0;
          let a: number = 255;
          if (bpp === 4) {
            r = s8[i];
            g = s8[i + 1];
            b = s8[i + 2];
            a = s8[i + 3];
          } else if (bpp === 3) {
            r = s8[i];
            g = s8[i + 1];
            b = s8[i + 2];
          } else {
            const v: number = s8[i] | (s8[i + 1] << 8);
            r = ((v >> 11) & 0x1F) * 255 / 31;
            g = ((v >> 5) & 0x3F) * 255 / 63;
            b = (v & 0x1F) * 255 / 31;
          }
          // 常规 over 混合：dst = src*a + bg*(1-a)
          const af: number = a / 255;
          out[o] = Math.round(r * af + BG * (1 - af));
          out[o + 1] = Math.round(g * af + BG * (1 - af));
          out[o + 2] = Math.round(b * af + BG * (1 - af));
          out[o + 3] = 255;
        }
      }
      return await image.createPixelMap(out.buffer, {
        size: { width: w, height: h },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        srcPixelFormat: image.PixelMapFormat.RGBA_8888
      });
    } catch (err) {
      return src;
    }
  }

  aboutToDisappear(): void {
    if (this.delivered) {
      // 内容已交付（插入文档 / 完成批注）：删掉笔迹文件并直接返回，
      // 下次进入手写页就是空画布（用户要求）
      try {
        if (this.handwritePath.length > 0 && fs.accessSync(this.handwritePath)) {
          fs.unlinkSync(this.handwritePath);
        }
      } catch (err) {
        // 忽略：删除失败不影响本次交付
      }
      return;
    }
    // 退出时保存手写笔记（官方示例：aboutToDisappear 中 save）
    try {
      if (this.handwritePath.length > 0) {
        this.controller?.save(this.handwritePath);
      }
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      // 静默
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
        ?.then(async (pm: image.PixelMap) => {
          // **合成浅灰底**（用户要求）：手写图原本可能是透明底黑字，在深色模式的
          // 正文 / 壁纸上"黑字压黑底"看不清；统一垫一层浅灰，任何主题下都读得清。
          const composed: image.PixelMap = await Sketch.composeOnGray(pm);
          const packer: image.ImagePacker = image.createImagePacker();
          const packOpts: image.PackingOption = { format: 'image/png', quality: 100 };
          packer.packToData(composed, packOpts).then((data: ArrayBuffer) => {
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
            // 交付完成：标记（退出时清空笔迹 → 下次是空画布）
            this.delivered = true;
            if (this.sketchMode === 'annotate') {
              // **批注模式**：把图交给阅读页落成"红双下划线"批注（不插入正文）
              AppStorage.setOrCreate('sketchAnnotationImage', rel);
            } else {
              AppStorage.setOrCreate('sketchInsertMd', '\n![手写笔记](' + rel + ')\n');
            }
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

        Text(this.sketchMode === 'annotate' ? '手写批注' : '手写笔记')
          .fontSize(HwType.label + 3)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.palette().textPrimary)
          .layoutWeight(1)

        // **沉浸光感胶囊**（用户要求：按钮要加沉浸光感），与全应用口径一致
        ImmersiveChip({
          chipPaddingH: HwSpace.md,
          chipPaddingV: 7,
          chipActive: !this.saving,
          palette: this.palette(),
          chipLabel: this.saving ? '处理中…'
            : (this.sketchMode === 'annotate' ? '完成批注' : '插入文档'),
          chipOnTap: () => {
            if (!this.saving) {
              this.insertToDoc();
            }
          }
        })
      }
      .width('100%')
      // **顶部避让系统状态栏**（此前顶栏跑到状态栏区域，用户反馈）
      .padding({
        left: HwSpace.md,
        right: HwSpace.md,
        top: this.getUIContext().px2vp(this.safeTopPx) + HwSpace.xs,
        bottom: HwSpace.sm
      })

      // ── 官方手写画布（自带工具栏：笔刷 / 橡皮 / 撤销等）──
      Column() {
        HandwriteComponent({
          handwriteController: this.controller,
          defaultPenType: PenType.PEN,
          widthRatio: 1,
          heightRatio: 1,
          onInit: () => {
            // 画布初始化完成，加载已有笔迹（官方示例：onInit 中 load）
            try {
              if (this.handwritePath.length > 0) {
                this.controller?.load(this.handwritePath);
              }
            } catch (err) {
              const e: BusinessError = err as BusinessError;
              // 静默
            }
          }
        })
      }
      .layoutWeight(1)
      .width('100%')
      // 注：**不给画布容器加 borderRadius + clip** —— 内部绘制坐标与裁剪区域
      // 不一致时会出现"顶部一块空白、画不上"（用户实测）；铺满更稳。
      .margin({ left: HwSpace.sm, right: HwSpace.sm, bottom: HwSpace.sm })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark() ? '#FF17171A' : '#FFF3F1EC')
  }
}
