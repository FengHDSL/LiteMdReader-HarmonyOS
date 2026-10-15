/**
 * 澄笺 · 图表/公式快照图的**裁切浮层**（相册式交互，按用户反馈重做）
 * =====================================================================
 *
 * 交互（与普通相册裁切一致）：
 *   · 选区常驻（初始 = 整张图）；**拖框内移动**、**拖四角手柄缩放**；
 *   · 「确认裁切」按选区的图片像素坐标裁出并**原地替换**快照文件；
 *   · 「恢复原图」：首次裁切前自动留档（.orig 边车），随时可一键还原；
 *   · 「取消」关闭不改动。
 *
 * 坐标换算：图片按 Contain 适配进容器（boxW×boxH，偏移 offX/offY），
 * 触摸事件坐标是手势层（与图片盒同位同尺寸）的相对坐标 → 加 offX/offY 即浮层坐标。
 */
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
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
  /** 裁切底色：黑/白可切（用户要求），浅色图在白底上看得更清 */
  @State bgDark: boolean = true;
  private touchMode: string = 'none';
  private anchorX: number = 0;
  private anchorY: number = 0;
  private grabX: number = 0;
  private grabY: number = 0;

  /** 读图字节（fs 自读，路径形式无关） */
  private readBytes(p: string): ArrayBuffer | null {
    try {
      const file: fs.File = fs.openSync(p, fs.OpenMode.READ_ONLY);
      try {
        const stat: fs.Stat = fs.statSync(p);
        const buf: ArrayBuffer = new ArrayBuffer(stat.size);
        const n: number = fs.readSync(file.fd, buf);
        if (n > 0) {
          return buf;
        }
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
        }
      }
    } catch (err) {
    }
    return null;
  }

  /** 原图留档是否存在（存在 = 可一键恢复） */
  private hasOrig(): boolean {
    try {
      return fs.accessSync(this.imagePath + '.orig');
    } catch (err) {
      return false;
    }
  }

  aboutToAppear(): void {
    const buf: ArrayBuffer | null = this.readBytes(this.imagePath);
    if (buf === null) {
      return;
    }
    try {
      const src: image.ImageSource = image.createImageSource(buf);
      src.getImageInfo().then((info: image.ImageInfo) => {
        this.imgW = info.size.width;
        this.imgH = info.size.height;
        this.fitBox();
        // 选区初始 = 整张图（相册式：先全选再收）
        this.rectX = this.offX;
        this.rectY = this.offY;
        this.rectW = this.boxW;
        this.rectH = this.boxH;
        this.hasRect = true;
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
      return;
    }
    this.busy = true;
    try {
      // **首次裁切前留档**：原图存 .orig 边车，「恢复原图」随时可还原
      if (!this.hasOrig()) {
        const orig: ArrayBuffer | null = this.readBytes(this.imagePath);
        if (orig !== null) {
          const of: fs.File = fs.openSync(this.imagePath + '.orig',
            fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          try {
            fs.writeSync(of.fd, orig);
          } finally {
            try {
              fs.closeSync(of);
            } catch (ce) {
            }
          }
        }
      }
      const src: image.ImageSource = image.createImageSource(this.readBytes(this.imagePath));
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

  /** 恢复原图：.orig 写回快照路径（宿主确认回调会把页面里的图换回去） */
  private doRestore(): void {
    if (!this.hasOrig() || this.busy) {
      return;
    }
    const buf: ArrayBuffer | null = this.readBytes(this.imagePath + '.orig');
    if (buf === null) {
      return;
    }
    try {
      const file: fs.File = fs.openSync(this.imagePath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, buf);
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
        }
      }
      this.busy = true;
      this.onConfirm();
    } catch (err) {
    }
  }

  /** 触摸分派（相册式）：四角手柄 = 缩放，框内 = 移动 */
  private onTouchStart(x: number, y: number): void {
    const hx: number = 26;
    const corners: number[][] = [
      [this.rectX, this.rectY],
      [this.rectX + this.rectW, this.rectY],
      [this.rectX, this.rectY + this.rectH],
      [this.rectX + this.rectW, this.rectY + this.rectH]
    ];
    for (let k = 0; k < corners.length; k++) {
      if (Math.abs(x - corners[k][0]) <= hx && Math.abs(y - corners[k][1]) <= hx) {
        this.touchMode = 'resize';
        // 锚点 = 对角
        this.anchorX = corners[3 - k][0];
        this.anchorY = corners[3 - k][1];
        return;
      }
    }
    if (x >= this.rectX && x <= this.rectX + this.rectW && y >= this.rectY && y <= this.rectY + this.rectH) {
      this.touchMode = 'move';
      this.grabX = x - this.rectX;
      this.grabY = y - this.rectY;
      return;
    }
    this.touchMode = 'none';
  }

  private onTouchMove(x: number, y: number): void {
    // 钳制在图片盒内
    const cx: number = Math.min(Math.max(x, this.offX), this.offX + this.boxW);
    const cy: number = Math.min(Math.max(y, this.offY), this.offY + this.boxH);
    if (this.touchMode === 'move') {
      this.rectX = Math.min(Math.max(cx - this.grabX, this.offX), this.offX + this.boxW - this.rectW);
      this.rectY = Math.min(Math.max(cy - this.grabY, this.offY), this.offY + this.boxH - this.rectH);
    } else if (this.touchMode === 'resize') {
      this.rectX = Math.min(this.anchorX, cx);
      this.rectY = Math.min(this.anchorY, cy);
      this.rectW = Math.abs(cx - this.anchorX);
      this.rectH = Math.abs(cy - this.anchorY);
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.bgDark ? '#F0000000' : '#F0FFFFFF')

      if (this.boxW > 0) {
        // 图片：按 Contain 尺寸定位显示
        Image(this.imagePath)
          .width(this.boxW)
          .height(this.boxH)
          .position({ x: this.offX, y: this.offY })
          .objectFit(ImageFit.Contain)
          .interpolation(ImageInterpolation.High)

        // 选区暗化遮罩（四条）+ 边框
        if (this.hasRect) {
          Column()
            .width(this.boxW)
            .height(this.rectY - this.offY)
            .position({ x: this.offX, y: this.offY })
            .backgroundColor('#99000000')
          Column()
            .width(this.boxW)
            .height(Math.max(0, this.offY + this.boxH - (this.rectY + this.rectH)))
            .position({ x: this.offX, y: this.rectY + this.rectH })
            .backgroundColor('#99000000')
          Column()
            .width(Math.max(0, this.rectX - this.offX))
            .height(this.rectH)
            .position({ x: this.offX, y: this.rectY })
            .backgroundColor('#99000000')
          Column()
            .width(Math.max(0, this.offX + this.boxW - (this.rectX + this.rectW)))
            .height(this.rectH)
            .position({ x: this.rectX + this.rectW, y: this.rectY })
            .backgroundColor('#99000000')
          Column()
            .width(this.rectW)
            .height(this.rectH)
            .position({ x: this.rectX, y: this.rectY })
            .border({ width: 2, color: '#FFFFFFFF' })
        }

        // 四角手柄
        if (this.hasRect) {
          ForEach([[this.rectX, this.rectY], [this.rectX + this.rectW, this.rectY],
            [this.rectX, this.rectY + this.rectH], [this.rectX + this.rectW, this.rectY + this.rectH]],
            (c: number[]) => {
              Column()
                .width(18)
                .height(18)
                .position({ x: c[0] - 9, y: c[1] - 9 })
                .borderRadius(9)
                .backgroundColor('#FFFFFFFF')
                .border({ width: 2, color: '#FF63E8B0' })
            }, (c: number[]) => c[0] + '_' + c[1])
        }

        // 手势层：与图片盒同位同尺寸，触摸坐标即图片盒相对坐标
        Column()
          .width(this.boxW)
          .height(this.boxH)
          .position({ x: this.offX, y: this.offY })
          .hitTestBehavior(HitTestMode.Transparent)
          .onTouch((e: TouchEvent) => {
            if (e.type === TouchType.Down) {
              this.onTouchStart(this.offX + e.touches[0].x, this.offY + e.touches[0].y);
            } else if (e.type === TouchType.Move) {
              this.onTouchMove(this.offX + e.touches[0].x, this.offY + e.touches[0].y);
            }
          })
      }

      // 底部按钮条：重选 / 黑白 / 恢复原图 / 退出 / 确认裁切
      Row({ space: HwSpace.md }) {
        Text('黑白')
          .fontSize(14)
          .fontColor('#FFFFFFFF')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(HwRadius.pill)
          .backgroundColor('#FF3A4150')
          .onClick(() => {
            this.bgDark = !this.bgDark;
          })
        Text('重选')
          .fontSize(14)
          .fontColor('#FFFFFFFF')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(HwRadius.pill)
          .backgroundColor('#FF3A4150')
          .onClick(() => {
            this.rectX = this.offX;
            this.rectY = this.offY;
            this.rectW = this.boxW;
            this.rectH = this.boxH;
            this.hasRect = true;
          })
        if (this.hasOrig()) {
          Text('恢复原图')
            .fontSize(14)
            .fontColor('#FFFFFFFF')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .borderRadius(HwRadius.pill)
            .backgroundColor('#FF3A4150')
            .onClick(() => {
              this.doRestore();
            })
        }
        Blank()
        Text('退出')
          .fontSize(14)
          .fontColor('#FFFFFFFF')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
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
