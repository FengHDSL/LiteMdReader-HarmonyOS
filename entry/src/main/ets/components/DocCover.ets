/**
 * LiteMdReader · 程序化书封
 * ==========================
 *
 * 参考图一（华为笔记书架）的封面形态：文档没有封面图，
 * 用文档名哈希选一组渐变色，画一个「书」——左侧书脊线、居中大标题、底部小签名。
 * 同一篇文档的封面恒定，书架与文档详情头（参考图二）共用这一组件。
 */

import { CoverStyle, HwSpace, coverStyleOf } from '../theme/DesignTokens';
import { ImmersiveCardLayer } from '../material/ImmersiveCard';

/**
 * 由自定义底色推出一组封面配色：
 *  · bottom = 用户选的颜色本身
 *  · top    = 同色往白里提亮（保持"纸面受光"的观感，不变成纯色块）
 *  · ink    = 按底色亮度自动取深墨或白字，保证始终可读
 */
export function coverStyleFromColor(base: string): CoverStyle {
  const hex: string = base.startsWith('#') ? base.substring(1) : base;
  const full: string = hex.length === 3
    ? hex.charAt(0) + hex.charAt(0) + hex.charAt(1) + hex.charAt(1) + hex.charAt(2) + hex.charAt(2)
    : hex;
  const r: number = parseIntSafe(full.substring(0, 2));
  const g: number = parseIntSafe(full.substring(2, 4));
  const b: number = parseIntSafe(full.substring(4, 6));
  const luma: number = (r * 299 + g * 587 + b * 114) / 1000;
  return {
    top: mixWhite(r, g, b, 0.42),
    bottom: mixWhite(r, g, b, 0.06),
    ink: luma > 150 ? '#FF2B2F36' : '#FFF7F9FC'
  };
}

function parseIntSafe(part: string): number {
  const v: number = parseInt(part, 16);
  return isNaN(v) ? 0 : v;
}

/** 与白色混合（amount 0~1，越大越浅）。 */
function mixWhite(r: number, g: number, b: number, amount: number): string {
  return '#' + hex2(r + (255 - r) * amount) + hex2(g + (255 - g) * amount) + hex2(b + (255 - b) * amount);
}

function hex2(v: number): string {
  let n: number = Math.round(v);
  if (n < 0) {
    n = 0;
  }
  if (n > 255) {
    n = 255;
  }
  const s: string = n.toString(16).toUpperCase();
  return s.length === 1 ? '0' + s : s;
}

@Component
export struct DocCover {
  /** 文档名（决定配色哈希与标题文字） */
  @Prop title: string = '';
  /** 内置教程用主题章首样式（调用方把配色传进来即可，组件不感知主题） */
  @Prop coverTop: string = '#FFE8EFF7';
  @Prop coverBottom: string = '#FFD3E2F5';
  @Prop coverInk: string = '#FF2F63E8';
  /** 底部签名行文字 */
  @Prop coverBadge: string = '澄笺';
  /** 轮廓描边色（与新建按钮的 divider 描边同源） */
  @Prop edgeColor: string = '#33808080';
  /** 是否内置教程（角落加「内置」小标） */
  @Prop builtin: boolean = false;
  /**
   * 自定义封面底色（#RRGGBB，空 = 用调用方传入的哈希配色）。
   * 只覆盖色板，仍然走同一套「渐变 + 书脊 + 光感」的画法。
   */
  @Prop coverColor: string = '';
  /** 自定义封面图（Image 可用的路径；非空时整张图铺满封面，压在光感层之下） */
  @Prop coverImage: string = '';
  /** 封面上不显示文档名（图片封面常用） */
  @Prop hideName: boolean = false;

  /** 底色：自定义色优先，其次调用方给的哈希配色 */
  private topColor(): string {
    return this.coverColor.length > 0 ? coverStyleFromColor(this.coverColor).top : this.coverTop;
  }

  private bottomColor(): string {
    return this.coverColor.length > 0 ? coverStyleFromColor(this.coverColor).bottom : this.coverBottom;
  }

  private inkColor(): string {
    return this.coverColor.length > 0 ? coverStyleFromColor(this.coverColor).ink : this.coverInk;
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      // 底：渐变纸面。**圆角要自己带一份**——
      // 外层 Stack 的 borderRadius 只负责画圆角边框，**不裁子节点**，
      // 纸面仍是方块 → 观感就是"只是套了壳、边角没裁掉"。
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 200,
          colors: [[this.topColor(), 0.0], [this.bottomColor(), 1.0]]
        })
        .borderRadius({ topLeft: 5, bottomLeft: 5, topRight: 13, bottomRight: 13 })

      // 自定义封面图（用户导入）：铺满整张封面，压在书脊与光感层之下。
      // 双保险兜底色用 bottomColor()，图片解码中 / 失败时不会露出空白。
      if (this.coverImage.length > 0) {
        Image(this.coverImage)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .borderRadius({ topLeft: 5, bottomLeft: 5, topRight: 13, bottomRight: 13 })
          .backgroundColor(this.bottomColor())
          .draggable(false)
      }

      // 左侧书脊：一道竖向暗线 + 高光，造出「书」的体积感
      // （用图片封面时书脊减淡，避免把照片压暗）
      Column()
        .width(7)
        .height('100%')
        .linearGradient({
          angle: 0,
          colors: [['#26000000', 0.0], ['#0D000000', 0.35], ['#33FFFFFF', 1.0]]
        })
        .borderRadius({ topLeft: 5, bottomLeft: 5 })
        .opacity(this.coverImage.length > 0 ? 0.35 : 1)

      // 沉浸光感层：铺在纸面与书脊之上、文字之下——
      // 玻璃质感盖住封面画料，标题仍保持清晰（文字在玻璃之上）
      ImmersiveCardLayer({
        layerRadius: 9,
        layerRadiusTL: 5,
        layerRadiusTR: 13,
        layerRadiusBL: 5,
        layerRadiusBR: 13,
        layerShadow: false
      })

      if (!this.hideName) {
        Column({ space: 5 }) {
          Blank()

          Text(this.title)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.inkColor())
            .lineHeight(22)
            .textAlign(TextAlign.Center)
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            // 图片封面上的文字加一层同色底影，白字压在浅色照片上也读得出来
            .textShadow(this.coverImage.length > 0
              ? { radius: 6, color: '#66000000', offsetX: 0, offsetY: 1 }
              : { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })

          if (this.builtin) {
            Text('内置 · 只读')
              .fontSize(9.5)
              .fontColor(this.inkColor())
              .opacity(0.75)
          }

          Blank()

          Text(this.coverBadge)
            .fontSize(9)
            .fontColor(this.inkColor())
            .opacity(0.5)
            .maxLines(1)
        }
        .width('100%')
        .height('100%')
        .padding({ left: HwSpace.md, right: HwSpace.md, top: HwSpace.md, bottom: HwSpace.md })
      }
    }
    .width('100%')
    .height('100%')
    // 轮廓与「新建文档」按钮同款：细描边（用户要求：封面轮廓与新建按钮一致）
    .borderRadius({ topLeft: 5, bottomLeft: 5, topRight: 13, bottomRight: 13 })
    // **必须裁切**：不加这句，子节点（渐变纸面 / 书脊 / 光感层）的方角会在圆角外露出来，
    // 封面就只是"方纸 + 圆角描边"。裁剪后右侧两角被真正切掉 → 书的模样。
    .clip(true)
    .border({ width: 1.2, color: this.edgeColor })
  }
}

/** 取文档封面的三色（内置教程固定用第一组）。 */
export function coverColorsOf(name: string, builtin: boolean): CoverStyle {
  const style: CoverStyle = coverStyleOf(builtin ? 'LiteMdReader·内置' : name);
  return style;
}
