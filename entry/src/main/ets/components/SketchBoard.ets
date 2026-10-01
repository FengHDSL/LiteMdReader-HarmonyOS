/**
 * 澄笺 · 画板（编辑页「画一画」）
 * ============================
 *
 * 手画一张图 → 导出 PNG → 插入当前文档。
 *
 * **为什么不用 PenKit 的 HandwriteComponent**：
 * PenKit 的 HandwriteController 只能把**笔迹形状数据**存成 `.handwrite` 文件，
 * **没有导出图片的接口**（d.ts 里只有形状 save/load）。
 * 「画完保存成图片」需要像素级导出，所以用官方 ArkUI Canvas：
 *   · 手势采点 → Canvas 2D 画线
 *   · 导出用官方 `getPixelMap` → `image.createImagePacker().packToData`
 *
 * 单位约定：Canvas 画线用 **vp**（组件坐标即 vp）；导出时按屏幕密度换算成 **px**
 * （getPixelMap 的入参是 px）。
 *
 * 撤销 = 保留每笔的路径数组，重画剩余笔画。底色铺白：导出的图在深色阅读页里也是白纸。
 */
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { DocStore } from '../service/DocStore';
import { HwRadius, HwSpace, HwType, LIGHT_PALETTE, ReaderPalette } from '../theme/DesignTokens';
import { ImmersiveChip, ImmersiveIconButton } from '../material/ImmersiveCard';

/** 一笔 = 一串触点（vp 坐标） */
interface StrokePoint {
  x: number;
  y: number;
}

@Component
export struct SketchBoard {
  palette: ReaderPalette = LIGHT_PALETTE;
  /** 画布尺寸（vp） */
  @Prop boardWidth: number = 320;
  @Prop boardHeight: number = 240;
  /** 保存成功后回调（rel = docs/images 下的相对引用路径） */
  onSaved: (rel: string) => void = () => {
  };
  onDismiss: () => void = () => {
  };

  @State strokeCount: number = 0;
  private settings: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  /** 已完成的笔画（撤销时重画） */
  private strokes: StrokePoint[][] = [];
  /** 当前正在画的这一笔 */
  private current: StrokePoint[] = [];
  private density: number = 2;

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1600 });
    } catch (err) {
      // 忽略
    }
  }

  /** 铺白底（初始化与撤销重画前都先铺白） */
  private fillWhite(): void {
    this.settings.fillStyle = '#FFFFFFFF';
    this.settings.fillRect(0, 0, this.boardWidth, this.boardHeight);
  }

  /** 重画所有笔画（撤销用） */
  private redraw(): void {
    this.fillWhite();
    this.settings.strokeStyle = '#FF1F2933';
    this.settings.lineWidth = 3;
    this.settings.lineCap = 'round';
    for (let k = 0; k < this.strokes.length; k++) {
      const pts: StrokePoint[] = this.strokes[k];
      this.settings.beginPath();
      if (pts.length === 1) {
        // 单点画个圆点，别让「点一下」消失
        this.settings.arc(pts[0].x, pts[0].y, 1.6, 0, Math.PI * 2);
      } else {
        this.settings.moveTo(pts[0].x, pts[0].y);
        for (let j = 1; j < pts.length; j++) {
          this.settings.lineTo(pts[j].x, pts[j].y);
        }
      }
      this.settings.stroke();
    }
    this.strokeCount = this.strokes.length;
  }

  /** 导出 PNG → 存进 docs/images → 回调插入引用 */
  private saveAndClose(): void {
    if (this.strokes.length === 0) {
      this.toast('先画点什么吧');
      return;
    }
    try {
      const pxW: number = Math.round(this.boardWidth * this.density);
      const pxH: number = Math.round(this.boardHeight * this.density);
      const pixel: image.PixelMap = this.settings.getPixelMap(0, 0, pxW, pxH);
      const packer: image.ImagePacker = image.createImagePacker();
      const opts: image.PackingOption = { format: 'image/png', quality: 100 };
      packer.packToData(pixel, opts).then((bytes: ArrayBuffer) => {
        const c = this.getUIContext().getHostContext();
        if (c === undefined || c === null) {
          this.toast('拿不到应用上下文');
          return;
        }
        const rel: string | null =
          DocStore.saveImageBytes(c as common.UIAbilityContext, bytes, 'png');
        if (rel === null) {
          this.toast('保存失败');
          return;
        }
        this.onSaved(rel);
      }).catch((err: Error) => {
        this.toast('导出失败：' + err.message);
      });
    } catch (err) {
      this.toast('导出失败');
    }
  }

  build() {
    Column({ space: HwSpace.md }) {
      Row({ space: HwSpace.sm }) {
        Text('画一画')
          .fontSize(HwType.label + 2)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.palette.textPrimary)
        Column()
          .layoutWeight(1)
        Text(this.strokeCount + ' 笔')
          .fontSize(HwType.caption)
          .fontColor(this.palette.textTertiary)
        ImmersiveIconButton({
          buttonSize: 30,
          buttonMaterialShadow: false,
          palette: this.palette,
          buttonOnTap: () => {
            this.onDismiss();
          }
        }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(14)
            .fontColor([this.palette.textPrimary])
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Canvas(this.settings)
        .width(this.boardWidth)
        .height(this.boardHeight)
        .borderRadius(HwRadius.inner)
        .border({ width: 1, color: this.palette.divider })
        .backgroundColor('#FFFFFFFF')
        .onReady(() => {
          try {
            this.density = display.getDefaultDisplaySync().densityPixels;
          } catch (err) {
            this.density = 2;
          }
          this.fillWhite();
        })
        .gesture(
          PanGesture({ fingers: 1, direction: PanDirection.All })
            .onActionStart((event: GestureEvent) => {
              this.current = [{ x: event.offsetX, y: event.offsetY }];
            })
            .onActionUpdate((event: GestureEvent) => {
              const p: StrokePoint = { x: event.offsetX, y: event.offsetY };
              if (this.current.length === 0) {
                this.current = [p];
                return;
              }
              const last: StrokePoint = this.current[this.current.length - 1];
              this.settings.strokeStyle = '#FF1F2933';
              this.settings.lineWidth = 3;
              this.settings.lineCap = 'round';
              this.settings.beginPath();
              this.settings.moveTo(last.x, last.y);
              this.settings.lineTo(p.x, p.y);
              this.settings.stroke();
              this.current.push(p);
            })
            .onActionEnd(() => {
              if (this.current.length > 0) {
                this.strokes.push(this.current);
                this.current = [];
                this.strokeCount = this.strokes.length;
              }
            })
        )

      Row({ space: HwSpace.xs }) {
        ImmersiveChip({
          palette: this.palette,
          chipLabel: '清空',
          chipOnTap: () => {
            this.strokes = [];
            this.fillWhite();
            this.strokeCount = 0;
          }
        })
        ImmersiveChip({
          palette: this.palette,
          chipLabel: '撤销',
          chipOnTap: () => {
            if (this.strokes.length > 0) {
              this.strokes.pop();
              this.redraw();
            }
          }
        })
        Column()
          .layoutWeight(1)
        ImmersiveChip({
          palette: this.palette,
          chipActive: true,
          chipLabel: '插入文档',
          chipOnTap: () => {
            this.saveAndClose();
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(HwSpace.md)
    .alignItems(HorizontalAlign.Center)
  }
}
