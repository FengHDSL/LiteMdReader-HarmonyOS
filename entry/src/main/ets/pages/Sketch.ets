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
import { display } from '@kit.ArkUI';
import { DocStore } from '../service/DocStore';
import { HwRadius, HwSpace, HwType, ReaderPalette, paletteFor, isDarkTheme } from '../theme/DesignTokens';
import { ImmersiveChip, ImmersiveIconButton } from '../material/ImmersiveCard';
import { modalSheetOptions } from '../material/ModalSheet';

/** 手写画布背景候选：淡色暖色系纯色 +「跟随主题」（空串表示跟随） */
interface SketchBgOption {
  name: string;
  /** 8 位 hex（#AARRGGBB）；空串 = 跟随主题默认底色 */
  color: string;
}

/** 「主题色」选项的特殊标记：底色动态取当前主题强调色的淡色版（见 accentTintBg）。 */
const SKETCH_BG_ACCENT: string = '@accent';

const SKETCH_BG_COLORS: SketchBgOption[] = [
  { name: '跟随主题', color: '' },
  // 动态：跟随「主题色」设置（accent），深浅模式各自混出合适的淡底
  { name: '主题色', color: SKETCH_BG_ACCENT },
  { name: '米白', color: '#FFFDF8F1' },
  { name: '暖沙', color: '#FFF6EBD9' },
  { name: '浅杏', color: '#FFFAEFE2' },
  { name: '藕粉', color: '#FFF9EDEA' },
  { name: '淡黄', color: '#FFFBF4DA' },
  { name: '天蓝', color: '#FFE9F2F9' },
  { name: '嫩绿', color: '#FFEDF7E8' },
  { name: '阴天灰', color: '#FFEFF0F2' },
  { name: '夕阳红', color: '#FFFCEFE7' },
  // 后两款由需求方留白：「雾紫」偏冷、与藕粉同族但更清透；「浅茶」是低饱和茶褐，
  // 写钢笔字（黑墨）时纸感最接近真实便签。12 款正好每排 3 个、排满 4 行。
  { name: '雾紫', color: '#FFF0EDF6' },
  { name: '浅茶', color: '#FFF3ECE3' },
  // **澄笺壁纸色系**：取自 GEN_WALLPAPERS 浅色款的 top 值（澄光 / 宣纸 / 砚青 /
  // 竹影 / 霞笺），与主题色同名 —— 手写笔记的底子与所选壁纸同源，一眼能对上。
  { name: '澄光', color: '#FFEEF3F8' },
  { name: '宣纸', color: '#FFF6F1E7' },
  { name: '砚青', color: '#FFDCE3E4' },
  { name: '竹影', color: '#FFE7EFE6' },
  { name: '霞笺', color: '#FFFBEDE4' }
];

/** 底纹候选：无 / 小方格 / 单行线 / 点阵（全部由 Canvas 自绘）。 */
interface SketchPatternOption {
  name: string;
  value: string;
}

const SKETCH_PATTERNS: SketchPatternOption[] = [
  { name: '无底纹', value: 'none' },
  { name: '小方格', value: 'grid' },
  { name: '单行线', value: 'lines' },
  { name: '点阵', value: 'dots' }
];

/** 底纹线条粗细候选（vp）：方格 / 单行线 / 点阵共用同一档。 */
interface SketchLineOption {
  name: string;
  value: number;
}

const SKETCH_LINE_WIDTHS: SketchLineOption[] = [
  { name: '细', value: 1 },
  { name: '标准', value: 2 },
  { name: '粗', value: 3 }
];

/** 底纹间距（vp）：方格与点阵 26、单行线 34 */
const SKETCH_GRID_GAP: number = 26;
const SKETCH_LINE_GAP: number = 34;

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

  // ── 画布背景（色 + 底纹）：持久化，重进手写页保持上次选择 ──
  // 三键共挂一个 @Watch：任一变化都要**主动重绘**画布与面板预览（见 onBgChanged）。
  /** 背景色（'' = 跟随主题底色） */
  @StorageLink('sketchBgColor') @Watch('onBgChanged') bgColor: string = '';
  /** 底纹：none / grid（小方格）/ lines（单行线）/ dots（点阵） */
  @StorageLink('sketchBgPattern') @Watch('onBgChanged') bgPattern: string = 'none';
  /** 底纹线条粗细（vp）：1 细 / 2 标准 / 3 粗 */
  @StorageLink('sketchBgLineWidth') @Watch('onBgChanged') bgLineWidth: number = 1;
  /** 背景面板是否展开 */
  @State bgSheetOpen: boolean = false;
  /**
   * **画布重建纪元**。Pen Kit 的 `HandwriteController` **没有 clear()**
   * （只有 save / load / onLoad / getContentRange / getThumbnail / scrollTo），
   * 所以「一键清空」= 换一个 controller 实例 + 递增此值换掉 HandwriteComponent 的 key，
   * 由框架销毁重建组件，画布随之回到空白。
   */
  @State canvasEpoch: number = 0;
  /**
   * 底纹画布上下文：画布自身一个，外加背景面板里**每个底纹选项的预览画布**一个
   * （顺序与 SKETCH_PATTERNS 一致：无底纹 / 小方格 / 单行线）。
   */
  private patternCtx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private previewCtxs: CanvasRenderingContext2D[] = [
    new CanvasRenderingContext2D(new RenderingContextSettings(true)),
    new CanvasRenderingContext2D(new RenderingContextSettings(true)),
    new CanvasRenderingContext2D(new RenderingContextSettings(true)),
    new CanvasRenderingContext2D(new RenderingContextSettings(true)),
    new CanvasRenderingContext2D(new RenderingContextSettings(true)),
    new CanvasRenderingContext2D(new RenderingContextSettings(true)),
    new CanvasRenderingContext2D(new RenderingContextSettings(true))
  ];
  /** 根尺寸（背景半模态面板宽度 / 横竖判定用） */
  @State rootWidth: number = 360;
  @State rootHeight: number = 800;

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

  // ══════════════════ 画布背景（色 + 底纹）与清空 ══════════════════

  /** 主题默认画布底色（未选背景色时用；与页面底色同源，浅色不刺眼、深色不反白） */
  private defaultCanvasBg(): string {
    return this.isDark() ? '#FF17171A' : '#FFF3F1EC';
  }

  /**
   * 「主题色」这一项的实际色值：当前主题强调色与底色的混合（18% 主题色）。
   * 浅色模式往白靠、深色模式往深底靠，所以深浅两套观感都成立。
   */
  private accentTintBg(): string {
    const rgb: number[] = Sketch.rgbOfHex8(this.palette().accent);
    const mix: number = 0.18;
    const base: number = this.isDark() ? 23 : 255;
    const r: number = Math.round(rgb[0] * mix + base * (1 - mix));
    const g: number = Math.round(rgb[1] * mix + base * (1 - mix));
    const b: number = Math.round(rgb[2] * mix + base * (1 - mix));
    return '#' + Sketch.hex2(r) + Sketch.hex2(g) + Sketch.hex2(b);
  }

  /** 当前生效的画布底色；「主题色」这一项动态解析。 */
  private effectiveBgColor(): string {
    if (this.bgColor === SKETCH_BG_ACCENT) {
      return this.accentTintBg();
    }
    return this.bgColor.length > 0 ? this.bgColor : this.defaultCanvasBg();
  }

  /** 色卡预览用的实际颜色（「跟随主题」→ 主题底色；「主题色」→ 动态淡色版）。 */
  private bgOptionColor(opt: SketchBgOption): string {
    if (opt.color === SKETCH_BG_ACCENT) {
      return this.accentTintBg();
    }
    return opt.color.length > 0 ? opt.color : this.defaultCanvasBg();
  }

  /** 底色是否偏暗（决定底纹线条画黑的还是白的） */
  private darkCanvasBg(): boolean {
    const rgb: number[] = Sketch.rgbOfHex8(this.effectiveBgColor());
    // Rec.601 感知亮度
    const lum: number = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2];
    return lum < 128;
  }

  /**
   * **一键清空画布**。
   * Pen Kit 的控制器没有 clear()，所以走「换 controller + 换 key 重建组件」；
   * 同时置 skipLoad，让重建后的 onInit 不要把旧笔迹又读回来（否则等于没清）。
   */
  private clearCanvas(): void {
    // 换控制器实例 + canvasEpoch 递增 → 画布区的 if/else 分支互换，
    // 框架把旧的 HandwriteComponent 连同它绘制的内容一起销毁、重建为空画布。
    // （首版只换 key、不改结构，实测组件根本不重建，所以"清空没生效"。）
    this.controller = new HandwriteController();
    this.canvasEpoch = this.canvasEpoch + 1;
    this.toast('已清空画布');
  }

  /**
   * 画布初始化回调（官方示例在 onInit 里 load 已有笔迹）。
   * **清空引起的重建不加载**（canvasEpoch > 0）：否则刚清空的画布会被旧笔迹填回来。
   */
  private onCanvasInit(): void {
    if (this.canvasEpoch > 0) {
      return;
    }
    try {
      if (this.handwritePath.length > 0) {
        this.controller?.load(this.handwritePath);
      }
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      // 静默
    }
  }

  /** 屏幕像素密度（导出时把 vp 间距换算成像素；取不到按 2 兜底）。 */
  private densityPixels(): number {
    try {
      return display.getDefaultDisplaySync().densityPixels;
    } catch (err) {
      return 2;
    }
  }

  /**
   * 自绘底纹（用户要求：小方格 / 单行线，自己绘制）。
   * 线条颜色按底色明暗自动取（浅底 8% 黑 / 深底 10% 白）——既能看清，
   * 又足够淡、不抢手写笔迹；间距见 SKETCH_GRID_GAP / SKETCH_LINE_GAP。
   */
  private drawPattern(): void {
    const ctx: CanvasRenderingContext2D = this.patternCtx;
    const w: number = ctx.width;
    const h: number = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    if (this.bgPattern === 'none') {
      return;
    }
    const lineColor: string = this.darkCanvasBg()
      ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.08)';
    // 线宽用用户选的档位（1 细 / 2 标准 / 3 粗），点阵的半径也跟它走
    const lineW: number = Math.max(1, this.bgLineWidth);
    // **点阵**：在每个格点画一枚小圆点
    if (this.bgPattern === 'dots') {
      ctx.fillStyle = lineColor;
      const r: number = Math.max(1, lineW * 0.7);
      for (let x = SKETCH_GRID_GAP; x < w; x = x + SKETCH_GRID_GAP) {
        for (let y = SKETCH_GRID_GAP; y < h; y = y + SKETCH_GRID_GAP) {
          ctx.beginPath();
          ctx.arc(x, y, r, 0, Math.PI * 2);
          ctx.fill();
        }
      }
      return;
    }
    ctx.strokeStyle = lineColor;
    ctx.lineWidth = lineW;
    ctx.beginPath();
    if (this.bgPattern === 'grid') {
      for (let x = SKETCH_GRID_GAP; x < w; x = x + SKETCH_GRID_GAP) {
        ctx.moveTo(x, 0);
        ctx.lineTo(x, h);
      }
      for (let y = SKETCH_GRID_GAP; y < h; y = y + SKETCH_GRID_GAP) {
        ctx.moveTo(0, y);
        ctx.lineTo(w, y);
      }
    } else {
      for (let y = SKETCH_LINE_GAP; y < h; y = y + SKETCH_LINE_GAP) {
        ctx.moveTo(0, y);
        ctx.lineTo(w, y);
      }
    }
    ctx.stroke();
  }

  /**
   * 画背景面板里某个底纹选项的**大方格预览**（用户要求：给个大方格看清具体样式）。
   * 预览方块本身就是「按当前底色 + 该底纹」的小样，所见即所得。
   * @param index 0 无底纹 / 1 小方格 / 2 单行线（与 SKETCH_PATTERNS 同序）
   */
  private drawPatternPreview(index: number): void {
    const ctx: CanvasRenderingContext2D = this.previewCtxs[index];
    const w: number = ctx.width;
    const h: number = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    if (index === 0) {
      // 无底纹：只留底色（底色由下面的方块提供，画布保持透明）
      return;
    }
    const lineColor: string = this.darkCanvasBg()
      ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.08)';
    const lineW: number = Math.max(1, this.bgLineWidth);
    // 预览用固定的 12vp 小间距：方块里能一眼看出"格 / 行 / 点"的区别
    const gap: number = 12;
    // index 3 = 点阵（与 SKETCH_PATTERNS 同序：0 无 / 1 方格 / 2 单行线 / 3 点阵）
    if (index === 3) {
      ctx.fillStyle = lineColor;
      const r: number = Math.max(1, lineW * 0.7);
      for (let x = gap; x < w; x = x + gap) {
        for (let y = gap; y < h; y = y + gap) {
          ctx.beginPath();
          ctx.arc(x, y, r, 0, Math.PI * 2);
          ctx.fill();
        }
      }
      return;
    }
    ctx.strokeStyle = lineColor;
    ctx.lineWidth = lineW;
    ctx.beginPath();
    if (index === 1) {
      for (let x = gap; x < w; x = x + gap) {
        ctx.moveTo(x, 0);
        ctx.lineTo(x, h);
      }
      for (let y = gap; y < h; y = y + gap) {
        ctx.moveTo(0, y);
        ctx.lineTo(w, y);
      }
    } else {
      for (let y = gap; y < h; y = y + gap) {
        ctx.moveTo(0, y);
        ctx.lineTo(w, y);
      }
    }
    ctx.stroke();
  }

  /**
   * 画「线条粗细」某个档位的大方格预览：方块里画三条横线，
   * 线的粗细就是该档的值（细 / 标准 / 粗），一眼能比出差别。
   * @param idx 0 细 / 1 标准 / 2 粗
   */
  private drawLineWidthPreview(idx: number): void {
    const ctx: CanvasRenderingContext2D = this.previewCtxs[4 + idx];
    const w: number = ctx.width;
    const h: number = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    ctx.strokeStyle = this.darkCanvasBg() ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.08)';
    ctx.lineWidth = SKETCH_LINE_WIDTHS[idx].value;
    ctx.beginPath();
    for (let k = 0; k < 3; k++) {
      const y: number = h * (0.32 + k * 0.18);
      ctx.moveTo(w * 0.12, y);
      ctx.lineTo(w * 0.88, y);
    }
    ctx.stroke();
  }

  /**
   * 背景设置（底色 / 底纹 / 线宽）变化的统一重绘入口。
   *
   * ⚠️ **不能靠 Canvas 的 `.key()` 触发重绘**：`.key()` 只是"测试用标识"，
   * 改它并不会让 Canvas 重建 —— 真机表现就是"换底纹、调线宽后画布毫无变化，
   * 必须先切回「无底纹」把 Canvas 卸载、再选一次才生效"（卸载重挂才会走 onReady）。
   * 所以这里在状态变化后**主动重画**：延迟一帧是为了等新挂载的 Canvas 就绪
   * （未挂载时 ctx 尺寸为 0，两个 draw 方法内部会直接返回，天然安全）。
   */
  private onBgChanged(): void {
    setTimeout(() => {
      this.drawPattern();
      this.drawAllPreviews();
    }, 16);
  }

  /** 重画面板里的全部预览（未挂载的 Canvas 尺寸为 0，draw 方法会早退）。 */
  private drawAllPreviews(): void {
    for (let k = 0; k < SKETCH_PATTERNS.length; k++) {
      this.drawPatternPreview(k);
    }
    for (let k = 0; k < SKETCH_LINE_WIDTHS.length; k++) {
      this.drawLineWidthPreview(k);
    }
  }

  /**
   * hex → [r, g, b]。**7 位（#RRGGBB）与 8 位（#AARRGGBB）都收** ——
   * 主题色（palette.accent）是 7 位、画布底色是 8 位，两者都要能解析；
   * 其余长度按浅灰兜底。
   */
  private static rgbOfHex8(hex: string): number[] {
    let h: string = 'F4F4F4';
    if (hex.length === 9) {
      h = hex.substring(3);
    } else if (hex.length === 7) {
      h = hex.substring(1);
    }
    const out: number[] = [];
    out.push(Sketch.hexPair(h, 0));
    out.push(Sketch.hexPair(h, 2));
    out.push(Sketch.hexPair(h, 4));
    return out;
  }

  /** 0~255 → 两位大写 hex。 */
  private static hex2(v: number): string {
    const s: string = Math.round(Math.max(0, Math.min(255, v))).toString(16).toUpperCase();
    return s.length === 1 ? '0' + s : s;
  }

  private static hexPair(h: string, at: number): number {
    const v: number = parseInt(h.substring(at, at + 2), 16);
    return isNaN(v) ? 244 : v;
  }

  /**
   * 把手写位图合成到**指定的画布底色**上。
   * 原先固定用浅灰（244）：手写图本身是透明底，而深色模式下"黑字压黑底"看不清，
   * 所以统一垫一层浅灰。现在底色**跟着画布所选背景走** ——
   * 插入正文的手写图与手写页上看到的底色保持一致。
   * 按源像素的实际格式解码做常规 alpha 混合；失败时原样返回。
   */
  private static async composeOnBgColor(src: image.PixelMap, bgHex: string,
                                        pattern: string, lineWidth: number,
                                        density: number): Promise<image.PixelMap> {
    const rgb: number[] = Sketch.rgbOfHex8(bgHex);
    const bgr: number = rgb[0];
    const bgg: number = rgb[1];
    const bgb: number = rgb[2];
    // **底纹也要画进导出图**（用户要求：插入文档时背景要保留 —— 光有颜色不够，
    // 方格 / 横线也得在，否则插进正文的图和画布上看到的不是一回事）。
    // 线色口径与画布上的 Canvas 自绘一致：底色中混入 8% 黑（浅底）/ 10% 白（深底）。
    const dark: boolean = (0.299 * bgr + 0.587 * bgg + 0.114 * bgb) < 128;
    const mix: number = dark ? 0.10 : 0.08;
    const target: number = dark ? 255 : 0;
    const lineR: number = Math.round(bgr * (1 - mix) + target * mix);
    const lineG: number = Math.round(bgg * (1 - mix) + target * mix);
    const lineB: number = Math.round(bgb * (1 - mix) + target * mix);
    const gapPx: number = (pattern === 'grid' || pattern === 'dots')
      ? Math.max(2, Math.round(SKETCH_GRID_GAP * density))
      : Math.max(2, Math.round(SKETCH_LINE_GAP * density));
    const drawPattern: boolean = pattern !== 'none';
    // 线宽 → 像素：线条按宽度向一侧加粗；点阵半径用 0.7×线宽（与画布上 Canvas 的口径一致）
    const linePx: number = Math.max(1, Math.round(Math.max(1, lineWidth) * density));
    const dotR: number = Math.max(1, linePx * 0.7);
    const dotR2: number = dotR * dotR;
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
          // 底色：先判这个像素是否落在底纹线上（方格 = 横竖都算，单行线 = 只算横线）
          let dr: number = bgr;
          let dg: number = bgg;
          let db: number = bgb;
          if (drawPattern) {
            let onInk: boolean = false;
            if (pattern === 'grid') {
              onInk = (x % gapPx) < linePx || (y % gapPx) < linePx;
            } else if (pattern === 'lines') {
              onInk = (y % gapPx) < linePx;
            } else {
              // 点阵：到最近格点的距离 ≤ 半径（min 取法保证点在格点四周对称）
              const rx: number = x % gapPx;
              const ry: number = y % gapPx;
              const mx: number = Math.min(rx, gapPx - rx);
              const my: number = Math.min(ry, gapPx - ry);
              onInk = (mx * mx + my * my) <= dotR2;
            }
            if (onInk) {
              dr = lineR;
              dg = lineG;
              db = lineB;
            }
          }
          out[o] = Math.round(r * af + dr * (1 - af));
          out[o + 1] = Math.round(g * af + dg * (1 - af));
          out[o + 2] = Math.round(b * af + db * (1 - af));
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
          // 底色 + 底纹都跟着画布走（未选则用主题默认底色）
          const composed: image.PixelMap = await Sketch.composeOnBgColor(
            pm, this.effectiveBgColor(), this.bgPattern, this.bgLineWidth,
            this.densityPixels());
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

        // **右上角三颗胶囊**（用户要求：清空 / 背景 放右上角，"插入文档"改名"插入"），
        // 全部走沉浸光感，与全应用口径一致
        ImmersiveChip({
          chipPaddingH: HwSpace.sm,
          chipPaddingV: 7,
          chipActive: false,
          palette: this.palette(),
          chipLabel: '清空',
          chipOnTap: () => {
            this.clearCanvas();
          }
        })

        ImmersiveChip({
          chipPaddingH: HwSpace.sm,
          chipPaddingV: 7,
          // 选了纯色底或底纹时高亮，一眼看出"画布被改过"
          chipActive: this.bgColor.length > 0 || this.bgPattern !== 'none',
          palette: this.palette(),
          chipLabel: '背景',
          chipOnTap: () => {
            this.bgSheetOpen = true;
          }
        })

        ImmersiveChip({
          chipPaddingH: HwSpace.md,
          chipPaddingV: 7,
          chipActive: !this.saving,
          palette: this.palette(),
          chipLabel: this.saving ? '处理中…'
            : (this.sketchMode === 'annotate' ? '完成批注' : '插入'),
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

      // ── 画布区：背景色层 + 底纹层（自绘）+ 官方手写组件 ──
      // 为什么这样分层：官方 HandwriteComponent **没有背景相关属性**（只有
      // controller / pen 配置 / 宽高比例 / 回调），底色只能由它**下面的兄弟层**提供，
      // 再让组件自身透明 —— 所以用 Stack，而不是试图给它挂 backgroundColor。
      Stack({ alignContent: Alignment.TopStart }) {
        // ① 背景色（选中的纯色，或主题默认底色）
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.effectiveBgColor())

        // ② 底纹（小方格 / 单行线 / 点阵，Canvas 自绘）。
        //    **不加 key**：改 key 并不会让 Canvas 重建（见 onBgChanged 注释），
        //    底纹 / 线宽 / 底色的变化一律由 onBgChanged 主动重绘来生效。
        if (this.bgPattern !== 'none') {
          Canvas(this.patternCtx)
            .width('100%')
            .height('100%')
            .onReady(() => {
              this.drawPattern();
            })
        }

        // ③ 官方手写画布（自带工具栏：笔刷 / 橡皮 / 撤销等），放最上层。
        //
        // **为什么写成两个内容一致的 if/else 分支**：Pen Kit 的控制器没有 clear()，
        // 「一键清空」只能靠"销毁并重建组件"实现。而 ArkUI 里改 `.key()` **并不保证**
        // 自定义组件重建（首版正是这么写的，实测清空没生效）——
        // 只有 `if` 条件的分支切换才是确定的"销毁旧节点 + 创建新节点"。
        // 两个分支写法相同、只是所处分支不同，所以框架一定会重建。
        if (this.canvasEpoch % 2 === 0) {
          HandwriteComponent({
            handwriteController: this.controller,
            defaultPenType: PenType.PEN,
            widthRatio: 1,
            heightRatio: 1,
            onInit: () => {
              this.onCanvasInit();
            }
          })
            .width('100%')
            .height('100%')
            // 底色交给下面的 ①②，组件自身透明
            .backgroundColor(Color.Transparent)
        } else {
          HandwriteComponent({
            handwriteController: this.controller,
            defaultPenType: PenType.PEN,
            widthRatio: 1,
            heightRatio: 1,
            onInit: () => {
              this.onCanvasInit();
            }
          })
            .width('100%')
            .height('100%')
            .backgroundColor(Color.Transparent)
        }
      }
      .layoutWeight(1)
      .width('100%')
      // 注：**不给画布容器加 borderRadius + clip** —— 内部绘制坐标与裁剪区域
      // 不一致时会出现"顶部一块空白、画不上"（用户实测）；铺满更稳。
      .margin({ left: HwSpace.sm, right: HwSpace.sm, bottom: HwSpace.sm })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.defaultCanvasBg())
    // 根尺寸：背景面板的宽度（平板竖屏收一半）与横竖判定要用
    .onAreaChange((oldArea: Area, newArea: Area) => {
      const w: Length = newArea.width;
      const h: Length = newArea.height;
      // **只在真的变了才写状态**：尺寸回调可能高频触发，无条件回写会与渲染竞争
      if (typeof w === 'number' && typeof h === 'number'
        && (w !== this.rootWidth || h !== this.rootHeight)) {
        this.rootWidth = w;
        this.rootHeight = h;
      }
    })
    // 背景选择面板：统一走应用内唯一的半模态实现（material/ModalSheet.ets）
    .bindSheet(this.bgSheetOpen, this.bgSheet(), modalSheetOptions({
      title: '画布背景',
      // 副标题留空（用户要求删掉"底色与底纹只作书写参考…"那句）
      subtitle: '',
      surface: this.palette().surface,
      phoneLayout: this.rootHeight >= this.rootWidth,
      // **半屏高**（用户要求）：不传 fitContent 即官方中档位 = 屏高 60%，
      // 内容超出时面板内部可滚动（fitContent 会贴内容高度，太矮）。
      screenWidth: this.rootWidth,
      onDismiss: () => {
        this.bgSheetOpen = false;
      }
    }))
  }

  /**
   * 背景面板内容：底色（淡色暖色系 + 跟随主题）+ 底纹（无 / 小方格 / 单行线）。
   * ⚠️ 半模态里的 @Builder 必须**单根包裹**（这里是 Column）——多根并列会渲染成空白。
   */
  @Builder
  bgSheet() {
    Column({ space: HwSpace.md }) {
      // ── ① 底色：每排 3 个大方格（31% × 3 + 均分间隙），方块大小随面板自适应 ──
      Text('底色')
        .fontSize(HwType.label + 1)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.palette().textPrimary)
        .width('100%')

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        ForEach(SKETCH_BG_COLORS, (opt: SketchBgOption) => {
          Column({ space: 6 }) {
            Stack() {
              // 大方格：「跟随主题」铺当前主题底色，其余铺该纯色
              Column()
                .width('100%')
                .height('100%')
                .borderRadius(HwRadius.inner)
                .backgroundColor(this.bgOptionColor(opt))
                .border({ width: 1, color: this.palette().divider })
              if (this.bgColor === opt.color) {
                Column()
                  .width('100%')
                  .height('100%')
                  .borderRadius(HwRadius.inner)
                  .border({ width: 2.5, color: this.palette().accent })
              }
            }
            .width('100%')
            .aspectRatio(1)

            Text(opt.name)
              .fontSize(HwType.caption)
              .fontColor(this.bgColor === opt.color
                ? this.palette().accent : this.palette().textSecondary)
              .maxLines(1)
          }
          .width('31%')
          .alignItems(HorizontalAlign.Center)
          .margin({ bottom: HwSpace.sm })
          .onClick(() => {
            this.bgColor = opt.color;
          })
        }, (opt: SketchBgOption) => 'sheetbg_' + opt.name)
      }
      .width('100%')

      // ── ② 底纹：同样每排 3 个大方格，方块里是「当前底色 + 该底纹」的小样 ──
      Text('底纹')
        .fontSize(HwType.label + 1)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.palette().textPrimary)
        .width('100%')
        .margin({ top: HwSpace.xs })

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        ForEach(SKETCH_PATTERNS, (p: SketchPatternOption, idx: number) => {
          Column({ space: 6 }) {
            Stack() {
              Column()
                .width('100%')
                .height('100%')
                .borderRadius(HwRadius.inner)
                .backgroundColor(this.effectiveBgColor())
              // 预览同样不加 key：变化由 onBgChanged → drawAllPreviews() 重绘
              Canvas(this.previewCtxs[idx])
                .width('100%')
                .height('100%')
                .borderRadius(HwRadius.inner)
                .onReady(() => {
                  this.drawPatternPreview(idx);
                })
              if (this.bgPattern === p.value) {
                Column()
                  .width('100%')
                  .height('100%')
                  .borderRadius(HwRadius.inner)
                  .border({ width: 2.5, color: this.palette().accent })
              }
            }
            .width('100%')
            .aspectRatio(1)

            Text(p.name)
              .fontSize(HwType.caption)
              .fontColor(this.bgPattern === p.value
                ? this.palette().accent : this.palette().textSecondary)
              .maxLines(1)
          }
          .width('31%')
          .alignItems(HorizontalAlign.Center)
          .margin({ bottom: HwSpace.sm })
          .onClick(() => {
            this.bgPattern = p.value;
          })
        }, (p: SketchPatternOption) => 'sheetpat_' + p.value)
      }
      .width('100%')

      // ── ③ 线条粗细：三档，同样用大方格预览（方块里三条横线，粗细即该档） ──
      Text('线条粗细')
        .fontSize(HwType.label + 1)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.palette().textPrimary)
        .width('100%')
        .margin({ top: HwSpace.xs })

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        ForEach(SKETCH_LINE_WIDTHS, (lw: SketchLineOption, idx: number) => {
          Column({ space: 6 }) {
            Stack() {
              Column()
                .width('100%')
                .height('100%')
                .borderRadius(HwRadius.inner)
                .backgroundColor(this.effectiveBgColor())
              Canvas(this.previewCtxs[4 + idx])
                .width('100%')
                .height('100%')
                .borderRadius(HwRadius.inner)
                .onReady(() => {
                  this.drawLineWidthPreview(idx);
                })
              if (this.bgLineWidth === lw.value) {
                Column()
                  .width('100%')
                  .height('100%')
                  .borderRadius(HwRadius.inner)
                  .border({ width: 2.5, color: this.palette().accent })
              }
            }
            .width('100%')
            .aspectRatio(1)

            Text(lw.name)
              .fontSize(HwType.caption)
              .fontColor(this.bgLineWidth === lw.value
                ? this.palette().accent : this.palette().textSecondary)
              .maxLines(1)
          }
          .width('31%')
          .alignItems(HorizontalAlign.Center)
          .margin({ bottom: HwSpace.sm })
          .onClick(() => {
            this.bgLineWidth = lw.value;
          })
        }, (lw: SketchLineOption) => 'sheetlw_' + lw.name)
      }
      .width('100%')
    }
    .width('100%')
    // **四周留白**（用户反馈：此前内容贴到面板边缘，不符合设计审美）——
    // 半模态的内容区不会自带内边距，必须自己给。
    .padding({
      left: HwSpace.lg,
      right: HwSpace.lg,
      top: HwSpace.md,
      bottom: HwSpace.xl
    })
    .alignItems(HorizontalAlign.Start)
  }
}
