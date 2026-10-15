/**
 * 澄笺 · 图表/公式快照图的**裁切浮层**（用户要求：点击卡片 → 出现原始图片 → 选区裁切）
 * =====================================================================
 *
 * 交互：全屏黑底显示原始快照图（等比适配）→ 手指在图上拖出选区 →
 * 「确认裁切」把选区按图片像素坐标裁出并**原地替换**快照文件 →
 * 宿主刷新后卡片即显示裁切结果。「重选」清空选区重画，「取消」关闭不改动。
 *
 * 坐标换算：图片按 Contain 适配进容器（boxW×boxH，偏移 offX/offY），
 * 选区是显示坐标 → 裁切前按 imgW/boxW 的统一比例换算回图片像素。
 */
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { HwSpace, HwRadius } from '../theme/DesignTokens';

@Component
export struct ImageCropOverlay {
  @Prop imagePath: string = '';
  onConfirm: () => void = () => {};
  onCancel: () => void = () => {};

  @State imgW: number = 0;
  @State imgH: number = 0;
  @State screenW: number = 0;
  @State screenH: number = 0;
  @State boxW: number = 0;
  @State boxH: number = 0;
  @State offX: number = 0;
  @State offY: number = 0;
  @State rectX: number = 0;
  @State rectY: number = 0;
  @State rectW: number = 0;
  @State rectH: number = 0;
  @State hasRect: boolean = false;
  @State busy: boolean = false;
  private sx: number = 0;
  private sy: number = 0;

  aboutToAppear(): void {
    this.loadDims();
  }

  private loadDims(): void {
    try {
      const src: image.ImageSource = image.createImageSource(this.imagePath);
      src.getImageInfo().then((info: image.ImageInfo) => {
        this.imgW = info.size.width;
        this.imgH = info.size.height;
        this.fitBox();
        src.release();
      }).catch(() => {
        src.release();
      });
    } catch (err) {
    }
  }

  /** Contain 适配：算显示盒与居中偏移 */
  private fitBox(): void {
    if (this.screenW <= 0 || this.screenH <= 0 || this.imgW <= 0 || this.imgH <= 0) {
      return;
    }
    const k: number = Math.min(this.screenW / this.imgW, this.screenH / this.imgH);
    this.boxW = Math.floor(this.imgW * k);
    this.boxH = Math.floor(this.imgH * k);
    this.offX = Math.floor((this.screenW - this.boxW) / 2);
    this.offY = Math.floor((this.screenH - this.boxH) / 2);
  }

  /** 选区 → 图片像素裁切区 */
  private cropRegion(): image.Region | null {
    if (!this.hasRect || this.boxW <= 0) {
      return null;
    }
    const k: number = this.imgW / this.boxW;
    const x: number = Math.max(0, Math.round((this.rectX - this.offX) * k));
    const y: number = Math.max(0, Math.round((this.rectY - this.offY) * k));
    const w: number = Math.min(this.imgW - x, Math.round(this.rectW * k));
    const h: number = Math.min(this.imgH - y, Math.round(this.rectH * k));
    if (w < 8 || h < 8) {
      return null;
    }
    const r: image.Region = { x: x, y: y, size: { width: w, height: h } };
    return r;
  }

  private async doCrop(): Promise<void> {
    const r: image.Region | null = this.cropRegion();
    if (r === null || this.busy) {
      this.onCancel();
      return;
    }
    this.busy = true;
    try {
      const src: image.ImageSource = image.createImageSource(this.imagePath);
      const pm: image.PixelMap = await src.createPixelMap();
      await pm.crop(r);
      const packer: image.ImagePacker = image.createImagePacker();
      const bytes: ArrayBuffer = await packer.packToData(pm, { format: 'image/png', quality: 100 });
      const file: fs.File = fs.openSync(this.imagePath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes);
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
        }
      }
      src.release();
      pm.release();
      this.onConfirm();
    } catch (err) {
      this.busy = false;
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#F0000000')
        .onClick(() => {
          this.onCancel();
        })

      if (this.boxW > 0) {
        // 图片：按 Contain 尺寸定位显示
        Image('file://' + this.imagePath)
          .width(this.boxW)
          .height(this.boxH)
          .position({ x: this.offX, y: this.offY })
          .objectFit(ImageFit.Contain)
          .interpolation(ImageInterpolation.High)

        // 选区边框
        if (this.hasRect) {
          Column()
            .width(this.rectW)
            .height(this.rectH)
            .position({ x: this.rectX, y: this.rectY })
            .border({ width: 2, color: '#FF63E8B0' })
            .backgroundColor('#3363E8B0')
        }

        // 手势层：在图片区域内拖出选区
        Column()
          .width(this.boxW)
          .height(this.boxH)
          .position({ x: this.offX, y: this.offY })
          .hitTestBehavior(HitTestMode.Transparent)
          .gesture(PanGesture({ fingers: 1, direction: PanDirection.All, distance: 6 })
            .onActionStart((e: GestureEvent) => {
              this.sx = Math.min(Math.max(e.offsetX !== undefined ? this.offX + e.offsetX : 0, this.offX), this.offX + this.boxW);
              this.sy = Math.min(Math.max(e.offsetY !== undefined ? this.offY + e.offsetY : 0, this.offY), this.offY + this.boxH);
              this.rectX = this.sx;
              this.rectY = this.sy;
              this.rectW = 0;
              this.rectH = 0;
              this.hasRect = false;
            })
            .onActionUpdate((e: GestureEvent) => {
              const cx: number = Math.min(Math.max(this.offX + (e.offsetX !== undefined ? e.offsetX : 0), this.offX), this.offX + this.boxW);
              const cy: number = Math.min(Math.max(this.offY + (e.offsetY !== undefined ? e.offsetY : 0), this.offY), this.offY + this.boxH);
              this.rectX = Math.min(this.sx, cx);
              this.rectY = Math.min(this.sy, cy);
              this.rectW = Math.abs(cx - this.sx);
              this.rectH = Math.abs(cy - this.sy);
              this.hasRect = this.rectW > 12 && this.rectH > 12;
            }))
      }

      // 底部按钮条
      Row({ space: HwSpace.md }) {
        Text('重选')
          .fontSize(14)
          .fontColor('#FFFFFFFF')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(HwRadius.pill)
          .backgroundColor('#FF3A4150')
          .onClick(() => {
            this.hasRect = false;
            this.rectW = 0;
            this.rectH = 0;
          })
        Blank()
        Text('取消')
          .fontSize(14)
          .fontColor('#FFFFFFFF')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(HwRadius.pill)
          .backgroundColor('#FF3A4150')
          .onClick(() => {
            this.onCancel();
          })
        Text('确认裁切')
          .fontSize(14)
          .fontColor('#FF10141A')
          .fontWeight(FontWeight.Bold)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(HwRadius.pill)
          .backgroundColor('#FF63E8B0')
          .opacity(this.hasRect && !this.busy ? 1 : 0.4)
          .onClick(() => {
            this.doCrop();
          })
      }
      .width('100%')
      .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.xl })
      .position({ x: 0, y: this.screenH > 0 ? this.screenH - 64 : 0 })
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
    .onAreaChange((_o: Area, n: Area) => {
      this.screenW = Number(n.width);
      this.screenH = Number(n.height);
      this.fitBox();
    })
  }
}
