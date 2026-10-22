/**
 * 澄笺 · 函数绘制壁纸
 * ==================
 *
 * **不内置任何 png**：所有壁纸都用「渐变 + 柔光斑 + 细纹」程序化绘制出来，
 * 所以没有位图资源、任意分辨率都清晰，也天然契合「澄笺」的意象
 * （澄 = 澄澈透光；笺 = 文人纸笺）。
 *
 * 配色全部落在宣纸、砚台、松烟、竹影、晚霞、夜笺这组中国传统纸墨色里。
 */

import { L10n } from '../service/L10n';

/** 一款程序化壁纸的定义 */
export interface GenWallpaperDef {
  id: string;
  name: string;
  /** 一句话说明，给设置页做副标题 */
  hint: string;
  /** 底色渐变：上 / 下 */
  top: string;
  bottom: string;
  /** 两团柔光斑 */
  glowA: string;
  glowB: string;
  /** 细纹颜色（透明度已写进 #AARRGGBB） */
  weave: string;
  /**
   * **深色孪生款 id**：深色模式下自动改用这一款，让默认主题深浅都成立。
   * 空串 = 深浅都用自己。竹影（浅）↔ 夜笺（深）就是一对。
   */
  darkId: string;
}

/** AppStorage 键：选中的程序化壁纸 id；空串 = 不用 */
export const GEN_WALLPAPER_KEY: string = 'wallpaperGenId';

/** '#RRGGBB' → [r,g,b]；非法回退默认。 */
function parseRgb(hex: string, fallback: number[]): number[] {
  let s: string = hex.trim();
  if (s.startsWith('#')) {
    s = s.substring(1);
  }
  if (s.length === 6) {
    s = 'FF' + s;
  }
  if (s.length !== 8) {
    return fallback;
  }
  const r: number = parseInt(s.substring(2, 4), 16);
  const g: number = parseInt(s.substring(4, 6), 16);
  const b: number = parseInt(s.substring(6, 8), 16);
  if (isNaN(r) || isNaN(g) || isNaN(b)) {
    return fallback;
  }
  return [r, g, b];
}

function hex2(v: number): string {
  const s: string = Math.round(Math.max(0, Math.min(255, v))).toString(16).toUpperCase();
  return s.length === 1 ? '0' + s : s;
}

/**
 * 内置款式。颜色刻意都带一点「纸」的暖灰或「墨」的冷青，
 * 不要纯色块——纯色在磨砂材质下会显得很塑料。
 */
export const GEN_WALLPAPERS: GenWallpaperDef[] = [
  {
    id: 'cheng',
    name: L10n.t('澄光'),
    hint: L10n.t('冷调纸白 · 两团冷暖环境光'),
    top: '#EEF3F8', bottom: '#DCE5EE',
    glowA: '#8FC4F0', glowB: '#F0D9B8',
    weave: '#0F5A7A99',
    // 澄光：深色用松烟
    darkId: 'song'
  },
  {
    id: 'xuan',
    name: L10n.t('宣纸'),
    hint: L10n.t('暖白宣纸 · 极淡纤维纹'),
    top: '#F6F1E7', bottom: '#E9DFCE',
    glowA: '#E8C89A', glowB: '#CFE0D8',
    weave: '#12857A5A',
    // 宣纸：深色用松烟
    darkId: 'song'
  },
  {
    id: 'yan',
    name: L10n.t('砚青'),
    hint: L10n.t('砚台青灰 · 一点冷光'),
    top: '#DCE3E4', bottom: '#BFCBCD',
    glowA: '#6FA6B8', glowB: '#DDE7E5',
    weave: '#12344B55',
    // 砚青：深色用松烟
    darkId: 'song'
  },
  {
    id: 'song',
    name: L10n.t('松烟'),
    hint: L10n.t('墨色深底 · 暗光斑'),
    top: '#2A2E36', bottom: '#171A20',
    glowA: '#4E6B8A', glowB: '#7A6A55',
    weave: '#14FFFFFF',
    // 松烟：本身是深色，深浅都用自己
    darkId: ''
  },
  {
    id: 'zhu',
    name: L10n.t('竹影'),
    hint: L10n.t('淡青竹叶色 · 竖纹如竹'),
    top: '#E7EFE6', bottom: '#CFDECC',
    glowA: '#8FBF8A', glowB: '#E6EFC9',
    weave: '#10507A44',
    // 竹影：深色用夜笺（默认主题的一对）
    darkId: 'ye'
  },
  {
    id: 'xia',
    name: L10n.t('霞笺'),
    hint: L10n.t('晚霞粉橙 · 暖光晕'),
    top: '#FBEDE4', bottom: '#F0D3C4',
    glowA: '#F2A98A', glowB: '#F6D9A8',
    weave: '#128A5B44',
    // 霞笺：深色用夜笺
    darkId: 'ye'
  },
  {
    id: 'ye',
    name: L10n.t('夜笺'),
    hint: L10n.t('夜读深蓝 · 冷月白'),
    top: '#262B3C', bottom: '#171C26',
    glowA: '#4A5F9E', glowB: '#8E9BC4',
    weave: '#12FFFFFF',
    // 夜笺：本身是深色，深浅都用自己
    darkId: ''
  }
];

/** 按 id 取定义；找不到返回 null（表示不使用程序化壁纸）。 */
export function genWallpaperById(id: string): GenWallpaperDef | null {
  for (let k = 0; k < GEN_WALLPAPERS.length; k++) {
    if (GEN_WALLPAPERS[k].id === id) {
      return GEN_WALLPAPERS[k];
    }
  }
  return null;
}

/** '#RRGGBB'/'#AARRGGBB' 两色按 k∈[0,1] 线性混色，返回 '#AARRGGBB'。 */
function mixHex(a: string, b: string, k: number): string {
  const ca: number[] = parseRgb(a, [0, 0, 0]);
  const cb: number[] = parseRgb(b, [0, 0, 0]);
  const r: number = ca[0] + (cb[0] - ca[0]) * k;
  const g: number = ca[1] + (cb[1] - ca[1]) * k;
  const bl: number = ca[2] + (cb[2] - ca[2]) * k;
  return '#FF' + hex2(r) + hex2(g) + hex2(bl);
}

/**
 * 程序化壁纸在**当前深浅下实际生效那一款**的主底色（渐变上下色的中值）。
 *
 * 用途：关闭沉浸光感时的侧边栏 / 面板底色要「与背景同色」。
 * 只读 `top` 会偏亮、只读 `bottom` 会偏暗，取中值最接近整屏观感。
 * 深浅必须解析**孪生款**（竹影 → 夜笺），否则深色下会拿到浅色款的亮色
 * —— 与 `DesignTokens.autoBackdropLuminance()` 同一套口径。
 *
 * @returns '#AARRGGBB'；返回空串表示找不到该款式（调用方自行回落）。
 */
export function genWallpaperFlatColor(id: string, dark: boolean): string {
  if (id.length === 0) {
    return '';
  }
  const def: GenWallpaperDef | null = genWallpaperById(id);
  if (def === null) {
    return '';
  }
  let use: GenWallpaperDef = def;
  if (dark && def.darkId.length > 0 && def.darkId !== def.id) {
    const twin: GenWallpaperDef | null = genWallpaperById(def.darkId);
    if (twin !== null) {
      use = twin;
    }
  }
  return mixHex(use.top, use.bottom, 0.5);
}

/**
 * 程序化壁纸本体。铺满父容器，纯绘制、无位图。
 *
 * 构图固定四层：底色渐变 → 左上暖光斑 → 右下冷光斑 → 细纹。
 * 光斑用大半径 + 高模糊的圆形叠色，避免出现硬边。
 */
@Component
export struct GenWallpaper {
  @Prop @Watch('onStyleChanged') styleId: string = '';
  /** 深色模式下降一点亮度，避免夜里刺眼 */
  @Prop darkMode: boolean = false;
  /**
   * **纯底模式**：只画渐变 + 细纹，不画两个光斑圆。
   * 设置页等"内容为主"的页面用（用户要求：设置页不要那两个圆）。
   */
  @Prop plain: boolean = false;
  /** 光斑绕屏心公转的角度（两团转速不同 → 相位错开） */
  @State orbitA: number = 0;
  @State orbitB: number = 0;
  /** 光斑呼吸：透明度往复（两团节奏不同 → 错相淡入淡出） */
  @State glowPulseA: number = 0;
  @State glowPulseB: number = 0;
  /** 漂移动画的启动定时器（首帧之后才播；换壁纸 / 重建都要重来） */
  private driftTimer: number = -1;

  aboutToAppear(): void {
    this.startDrift();
  }

  aboutToDisappear(): void {
    if (this.driftTimer >= 0) {
      clearTimeout(this.driftTimer);
      this.driftTimer = -1;
    }
  }

  /**
   * 光斑公转 + 呼吸的启动。三条口径都是这轮修「壁纸完全不动」时定下的，别再改回去：
   *  · **先把状态打回起点再启动**——组件被 `if` 分支重建时 @State 已经是终值
   *    （orbitA=360≡0°、pulse=1），"初始即终值"就没有可播的过渡（工程在别处也总结过同一条）；
   *  · **延迟 600ms**——转场期（一镜到底首帧）会抢主线程把 animateTo 丢掉，
   *    原来只给 50ms 且失败后永不重试，看着就是"完全固定不动"；
   *  · 换壁纸 / 深浅切换由 onStyleChanged 再走一遍，退出时清定时器。
   */
  private startDrift(): void {
    if (this.driftTimer >= 0) {
      clearTimeout(this.driftTimer);
      this.driftTimer = -1;
    }
    this.orbitA = 0;
    this.orbitB = 0;
    this.glowPulseA = 0;
    this.glowPulseB = 0;
    if (this.plain) {
      return;
    }
    this.driftTimer = setTimeout(() => {
      this.driftTimer = -1;
      // **光斑绕屏心公转**：全屏透明容器绕屏心无限旋转，光斑偏心放在容器里 →
      // 沿大圆轨道公转。两团转速不同（40s / 56s）、方向相反 → 永远错开。
      this.getUIContext().animateTo({
        duration: 40000, curve: Curve.Linear, iterations: -1
      }, () => {
        this.orbitA = 360;
      });
      this.getUIContext().animateTo({
        duration: 56000, curve: Curve.Linear, iterations: -1
      }, () => {
        this.orbitB = -360;
      });
      // **呼吸**：亮度 + 尺寸一起往复（9s / 12s 两团错相）。周期太短像闪烁，
      // 幅度太小会被 blur 糊掉。
      this.getUIContext().animateTo({
        duration: 9000, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate
      }, () => {
        this.glowPulseA = 1;
      });
      this.getUIContext().animateTo({
        duration: 12000, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate
      }, () => {
        this.glowPulseB = 1;
      });
    }, 600);
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 165,
          colors: [[this.def().top, 0.0], [this.def().bottom, 1.0]]
        })

      // 左上暖光（plain 模式不画：设置页等内容为主的地方不要两个圆）。
      // **公转结构**：全屏透明容器绕屏心无限旋转（orbitA/orbitB），
      // 光斑中心放在**距屏心约 12~19% 屏宽**的偏心位置 → 沿小半径大圆轨道公转，
      // **始终在屏内**（之前 position 让光斑中心在屏外，一转就转出屏幕看不见）。
      // **径向渐变 + 呼吸透明度**：光斑从中心向边缘渐隐，透明度随 glowPulse 往复。
      if (!this.plain) {
      Stack()
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
        .rotate({
          x: 0, y: 0, z: 1,
          angle: this.orbitA,
          centerX: '50%', centerY: '50%'
        }) {
          Column()
            // **光斑收小**（72% → 46%）：原来是一大团柔光铺满屏心，"移动"被自身面积
            // 完全淹没了；收小之后才看得出是**一枚光点在缓慢游走**（用户反馈"光点移动不明显"）。
            .width('46%')
            .aspectRatio(1)
            .borderRadius('50%')
            .radialGradient({
              center: ['50%', '50%'],
              radius: 62,
              colors: [['#B4' + this.def().glowA.substring(1), 0.0],
                ['#4D' + this.def().glowA.substring(1), 0.55],
                ['#00000000', 1.0]]
            })
            // 亮度呼吸：基础 + 峰值（幅度加大到 0.36 —— 光斑带大模糊，幅度小会被糊掉看不出）
            .opacity((this.darkMode ? 0.18 : 0.30) + this.glowPulseA * 0.36)
            // 尺寸呼吸：0.88 ↔ 1.12（幅度 0.24），与亮度同相
            .scale({ x: 0.88 + this.glowPulseA * 0.24, y: 0.88 + this.glowPulseA * 0.24 })
            .blur(56)
            // **光斑只在角落区域活动**（用户要求：不许出现在屏幕中间）：
            // 光斑 46% 宽 → 中心在 (x+23%, y+23%)；取 (-8%, -8%) 让中心落在 (15%, 15%)，
            // 公转半径约 49% 屏宽 → 光斑边缘距屏心最近也有 26%，扫不到屏心附近。
            .position({ x: '-8%', y: '-8%' })
        }

      // 右下冷光（反向公转：130s 一圈，轨道半径约 15%）
      Stack()
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
        .rotate({
          x: 0, y: 0, z: 1,
          angle: this.orbitB,
          centerX: '50%', centerY: '50%'
        }) {
          Column()
            // 78% → 50%（与上面同理：收小才有"光点在走"的观感）
            .width('50%')
            .aspectRatio(1)
            .borderRadius('50%')
            // **实色圆**（用户要求：删掉灰色光晕，圆和圆心同色）：
            // 原来是「中心亮 → 55% 半透明 → 边缘透明」的径向渐变再加 blur，
            // 观感是一团灰雾；现在直接用圆心那个色做实心圆，呼吸与公转才看得出来。
            .backgroundColor('#B4' + this.def().glowB.substring(1))
            // 亮度呼吸：基础 + 峰值
            .opacity((this.darkMode ? 0.16 : 0.30) + this.glowPulseB * 0.34)
            // 尺寸呼吸：0.82 ↔ 1.18（幅度 0.36，实色圆上更明显）
            .scale({ x: 0.82 + this.glowPulseB * 0.36, y: 0.82 + this.glowPulseB * 0.36 })
            // 同上：光斑 50% 宽 → 中心在 (x+25%, y+25%)；取 (58%, 58%) 让中心落在 (83%, 83%)，
            // 公转半径约 47% 屏宽 → 同样只在角落区域活动，反向公转。
            .position({ x: '58%', y: '58%' })
        }
      }

      // 细纹：等距细线（宣纸纤维 / 竹影竖纹的抽象）
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [[this.def().weave, 0.0], ['#00000000', 0.5], [this.def().weave, 1.0]],
          repeating: true
        })
        .opacity(0.5)
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 换壁纸 → 漂移动画重新起：那四条 animateTo 绑的是这一份组件实例的状态，
   * 内容换了之后旧动画不会跟过来。
   */
  private onStyleChanged(): void {
    this.startDrift();
  }

  /** 取当前定义；id 非法时退到「澄光」，保证一定画得出来。 */
  private def(): GenWallpaperDef {
    const found: GenWallpaperDef | null = this.resolve(this.styleId);
    return found !== null ? found : GEN_WALLPAPERS[0];
  }

  /**
   * 深色孪生解析：深色模式下自动改用该款的 darkId，
   * 于是「默认主题」在浅色是竹影、深色自动变夜笺，深浅都成立。
   */
  private resolve(id: string): GenWallpaperDef | null {
    const found: GenWallpaperDef | null = genWallpaperById(id);
    if (found === null) {
      return null;
    }
    if (this.darkMode && found.darkId.length > 0 && found.darkId !== found.id) {
      const twin: GenWallpaperDef | null = genWallpaperById(found.darkId);
      if (twin !== null) {
        return twin;
      }
    }
    return found;
  }
}
