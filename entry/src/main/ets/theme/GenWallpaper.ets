/**
 * 澄笺 · 程序化壁纸（恒星系统）
 * ============================
 *
 * **不内置任何 png**：壁纸全部用声明式节点画出来（渐变 + 圆形 + 径向渐变），
 * 所以没有位图资源、任意分辨率都清晰。
 *
 * 构图是**最多五组恒星系**：每组一颗恒星、两三条轨道、几颗小星球绕着恒星公转，
 * 整组还会**自己慢慢漫游**。基准点全部落在边缘带（上两角、下两角、底部中央），
 * 屏幕正中那一条留给正文。深色模式下再叠一层会闪烁的满天星。
 * 七款预设只换配色（天空上下色、恒星的光色、轨道与星球的取色），构图完全一致。
 *
 * 两条实现口径，改之前先读完：
 *  · **位置与进度不写盘**：公转相位和漫游位移都由**绝对时间**算出来 ——
 *    同一时刻在任何页面实例上都是同一个值，所以冷启动、切页、杀进程重开都
 *    自动接上进度，既不用存，也不会出现两个页面各走各的。
 *  · **每帧零 JS**：旋转 / 位移 / 透明度全部交给 `animateTo`，插值发生在渲染线程；
 *    漫游是一趟一趟续上的（一趟 18 秒），只在换目标时跑一次函数。
 *    旧版那两个整屏 `.blur(56)` 光斑层是转场卡顿率报告点名的开销，已撤。
 *
 * 配色沿用宣纸、砚台、松烟、竹影、晚霞、夜笺这组中国传统纸墨色。
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
  /** 恒星与多数星球的取色 / 第二取色 */
  glowA: string;
  glowB: string;
  /** 轨道线颜色（透明度已写进 #AARRGGBB） */
  weave: string;
  /**
   * **深色孪生款 id**：深色模式下自动改用这一款，让默认主题深浅都成立。
   * 空串 = 深浅都用自己。竹影（浅）↔ 夜笺（深）就是一对。
   */
  darkId: string;
}

/** AppStorage 键：选中的程序化壁纸 id；空串 = 不用 */
export const GEN_WALLPAPER_KEY: string = 'wallpaperGenId';

/** '#RRGGBB'/'#AARRGGBB' → [r,g,b]；非法回退默认。 */
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

/**
 * 深色孪生解析：深色模式下改用该款的 darkId（竹影 → 夜笺）。
 * id 为空或找不到都返回 null，由调用方回落。
 */
export function resolveGenWallpaper(id: string, dark: boolean): GenWallpaperDef | null {
  const found: GenWallpaperDef | null = genWallpaperById(id);
  if (found === null) {
    return null;
  }
  if (dark && found.darkId.length > 0 && found.darkId !== found.id) {
    const twin: GenWallpaperDef | null = genWallpaperById(found.darkId);
    if (twin !== null) {
      return twin;
    }
  }
  return found;
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

/** 换掉一个颜色的透明度字节（aa 是两位十六进制，如 '8C' ≈ 0.55）。 */
function withAlpha(hex: string, aa: string): string {
  const c: number[] = parseRgb(hex, [128, 128, 128]);
  return '#' + aa + hex2(c[0]) + hex2(c[1]) + hex2(c[2]);
}

// ══════════════════════ 恒星系的构图参数 ══════════════════════

/** 一个恒星系的参数（长度类数值一律按 短边 × scale 换算，横竖屏都是正圆） */
interface SolarSpec {
  /** 恒星中心的基准位置（占屏宽 / 屏高）——刻意都在边缘带，不占正文那一条 */
  x: number;
  y: number;
  /** 整体大小（× 短边） */
  scale: number;
  /** 轨道直径、星球直径（都 × 短边 × scale） */
  rings: number[];
  planets: number[];
  /** 初始相位（度）、公转一圈毫秒、方向（1 顺 / -1 逆） */
  angles: number[];
  periods: number[];
  dirs: number[];
  /** 漫游幅度（× 短边）与三段正弦的周期（ms）/ 初相 */
  roam: number;
  roamP: number[];
  roamQ: number[];
}

/** 时间原点：所有相位 / 位移都相对它算，改这个数等于把整个星空拨回起点 */
const SOLAR_EPOCH: number = 1730000000000;
/** 一次漫游目标的持续时长；到点再取下一个 */
const ROAM_LEG_MS: number = 18000;
/** 恒星核心 / 光晕直径（× 短边 × scale） */
const STAR_CORE: number = 0.30;
const STAR_HALO: number = 1.15;

/** 五组恒星系：一大四小，周期 / 方向 / 相位 / 漫游节奏全部错开 */
const SOLAR_SYSTEMS: SolarSpec[] = [
  {
    x: 0.20, y: 0.14, scale: 0.34, rings: [0.42, 0.66, 0.92], planets: [0.052, 0.040, 0.062],
    angles: [38, 214, 322], periods: [30000, 52000, 84000], dirs: [1, -1, 1],
    roam: 0.055, roamP: [47000, 113000, 233000], roamQ: [0.0, 1.7, 3.1]
  },
  {
    x: 0.84, y: 0.20, scale: 0.22, rings: [0.46, 0.74], planets: [0.055, 0.038],
    angles: [150, 300], periods: [38000, 66000], dirs: [-1, 1],
    roam: 0.070, roamP: [53000, 127000, 199000], roamQ: [2.3, 0.4, 4.6]
  },
  {
    x: 0.11, y: 0.73, scale: 0.26, rings: [0.44, 0.72], planets: [0.046, 0.034],
    angles: [72, 250], periods: [44000, 29000], dirs: [1, -1],
    roam: 0.062, roamP: [61000, 149000, 271000], roamQ: [4.1, 2.6, 0.9]
  },
  {
    x: 0.87, y: 0.68, scale: 0.30, rings: [0.40, 0.64, 0.90], planets: [0.048, 0.036, 0.058],
    angles: [12, 168, 244], periods: [34000, 58000, 92000], dirs: [-1, 1, -1],
    roam: 0.058, roamP: [43000, 107000, 223000], roamQ: [1.2, 5.0, 3.3]
  },
  {
    x: 0.47, y: 0.93, scale: 0.18, rings: [0.50], planets: [0.060],
    angles: [206], periods: [41000], dirs: [1],
    roam: 0.085, roamP: [59000, 131000, 251000], roamQ: [3.7, 1.1, 5.4]
  }
];

/**
 * 某一时刻、某个恒星系相对基准点的漫游位移（±1 之内，乘上 roam 才是屏占比）。
 * 三段互质周期的正弦叠加 = 有机的漫游，且天然有界（漂不出屏幕）。
 * axis 只用来给 x / y 两个方向错开初相，否则整组星会沿对角线来回。
 */
function roamAt(t: number, s: SolarSpec, axis: number): number {
  const weight: number[] = [1.0, 0.5, 0.333];
  let v: number = 0;
  let norm: number = 0;
  for (let i = 0; i < s.roamP.length; i++) {
    v += Math.sin((t / s.roamP[i]) * Math.PI * 2 + s.roamQ[i] + axis * 2.1) * weight[i];
    norm += weight[i];
  }
  return v / norm;
}

/** 一颗背景星：位置按整屏百分比算，d 是直径（vp），g 是闪烁相位组 */
interface TwinkleSpec {
  x: number;
  y: number;
  d: number;
  g: number;
}

/** 深色模式的满天星：铺在四角与上下边缘，避开正文那一条竖向区域 */
const TWINKLE_STARS: TwinkleSpec[] = [
  { x: 0.12, y: 0.10, d: 2.0, g: 0 }, { x: 0.78, y: 0.06, d: 1.4, g: 1 },
  { x: 0.30, y: 0.18, d: 1.2, g: 2 }, { x: 0.62, y: 0.14, d: 2.2, g: 0 },
  { x: 0.90, y: 0.26, d: 1.3, g: 1 }, { x: 0.06, y: 0.34, d: 1.8, g: 2 },
  { x: 0.44, y: 0.05, d: 1.3, g: 3 }, { x: 0.70, y: 0.40, d: 1.5, g: 1 },
  { x: 0.20, y: 0.52, d: 1.2, g: 4 }, { x: 0.86, y: 0.60, d: 2.0, g: 0 },
  { x: 0.10, y: 0.74, d: 1.4, g: 1 }, { x: 0.55, y: 0.68, d: 1.2, g: 2 },
  { x: 0.34, y: 0.88, d: 1.7, g: 3 }, { x: 0.78, y: 0.86, d: 1.3, g: 4 },
  { x: 0.04, y: 0.94, d: 1.2, g: 2 }, { x: 0.62, y: 0.96, d: 1.6, g: 0 }
];

/** 五组闪烁周期（ms）：星星分给五组、每组再按直径给一点幅度差，看着就是各闪各的 */
const TWINKLE_PHASE_MS: number[] = [2300, 2900, 3400, 4100, 4800];

/** 当前时刻（相对 SOLAR_EPOCH 的毫秒数）——所有动画都从这里取时间基准 */
function solarNow(): number {
  return Date.now() - SOLAR_EPOCH;
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
  const use: GenWallpaperDef | null = resolveGenWallpaper(id, dark);
  if (use === null) {
    return '';
  }
  return mixHex(use.top, use.bottom, 0.5);
}

// ══════════════════════ 一个恒星系 ══════════════════════

/**
 * 一个恒星系：恒星（光晕 + 核心）、几条轨道、几颗绕转的小星球。
 *
 * 盒子只有**最大那条轨道**那么大（不是整屏），旋转的是盒子内部那圈小容器 ——
 * 五组星系就是五层小图层，比整屏图层便宜得多；位移走 translate、旋转走 rotate，
 * 都是合成层属性，不参与每帧重排。
 */
@Component
struct SolarSystem {
  /** 取 SOLAR_SYSTEMS 里的哪一组（传下标：数组对象不适合当 @Prop 传） */
  @Prop idx: number = 0;
  /** 父容器实测尺寸（vp） */
  @Prop boxW: number = 0;
  @Prop boxH: number = 0;
  @Prop styleId: string = '';
  @Prop darkMode: boolean = false;
  /** 纯底模式：照样画，但一样都不动 */
  @Prop plain: boolean = false;
  /** 漫游位移（vp，相对基准点） */
  @State rx: number = 0;
  @State ry: number = 0;
  /** 三颗星球各自的公转进度（不足三颗的系用不到后面那几个槽） */
  @State orb1: number = 0;
  @State orb2: number = 0;
  @State orb3: number = 0;
  /** 恒星呼吸 */
  @State pulse: number = 0;
  /** 启动定时器 + 存活标记（漫游是一趟一趟续上的，销毁后不能再续） */
  private startTimer: number = -1;
  private alive: boolean = true;

  aboutToAppear(): void {
    // 首帧就落在"此刻该在的地方"：这一步不带动画，不需要等 UI 就绪
    this.snapToNow();
    if (this.plain) {
      return;
    }
    // 延迟 600ms：转场期会抢主线程把 animateTo 丢掉（上一轮"壁纸完全不动"的根因）
    this.startTimer = setTimeout(() => {
      this.startTimer = -1;
      if (!this.alive) {
        return;
      }
      this.startMotion();
    }, 600);
  }

  aboutToDisappear(): void {
    this.alive = false;
    if (this.startTimer >= 0) {
      clearTimeout(this.startTimer);
      this.startTimer = -1;
    }
  }

  private spec(): SolarSpec {
    return SOLAR_SYSTEMS[this.idx >= 0 && this.idx < SOLAR_SYSTEMS.length ? this.idx : 0];
  }

  private def(): GenWallpaperDef {
    const found: GenWallpaperDef | null = resolveGenWallpaper(this.styleId, this.darkMode);
    return found !== null ? found : GEN_WALLPAPERS[0];
  }

  /** 短边（vp）：半径都以它为基准，横屏 / 平板上才是正圆 */
  private short(): number {
    return this.boxW < this.boxH ? this.boxW : this.boxH;
  }

  /** 第 i 条轨道的直径（vp） */
  private ringD(i: number): number {
    return this.spec().rings[i] * this.short() * this.spec().scale;
  }

  /** 第 i 颗星球的直径（vp） */
  private planetD(i: number): number {
    return this.spec().planets[i] * this.short() * this.spec().scale;
  }

  /** 盒子边长 = 最大那条轨道再留一点余量 */
  private size(): number {
    const s: SolarSpec = this.spec();
    let maxRing: number = s.rings[0];
    for (let i = 1; i < s.rings.length; i++) {
      if (s.rings[i] > maxRing) {
        maxRing = s.rings[i];
      }
    }
    return maxRing * this.short() * s.scale * 1.25;
  }

  /** 恒星中心的基准位置（vp） */
  private baseX(): number {
    return this.spec().x * this.boxW;
  }

  private baseY(): number {
    return this.spec().y * this.boxH;
  }

  /** 第 i 颗星球当前这一圈的进度 */
  private orbOf(i: number): number {
    return i === 0 ? this.orb1 : i === 1 ? this.orb2 : this.orb3;
  }

  private setOrb(i: number, v: number): void {
    if (i === 0) {
      this.orb1 = v;
    } else if (i === 1) {
      this.orb2 = v;
    } else {
      this.orb3 = v;
    }
  }

  /** 星球取色：深色往白里提、浅色往墨里压，否则在底色上根本看不见 */
  private planetColor(i: number): string {
    const base: string = i === 1 ? this.def().glowB : this.def().glowA;
    return mixHex(base, this.darkMode ? '#FFFFFF' : '#20252D', this.darkMode ? 0.58 : 0.74);
  }

  /**
   * 恒星核心的边缘色。浅色底（纸白 / 淡青）直接用款色会被吞掉，
   * 所以固定往暖金里靠；深色本来就是夜空，给月白。
   */
  private starCore(): string {
    return this.darkMode ? '#FFFFF4DC' : mixHex(this.def().glowA, '#F2A93B', 0.62);
  }

  /** 把位移与公转相位拨到"此刻"的值——时间函数，所以不需要任何持久化 */
  private snapToNow(): void {
    const s: SolarSpec = this.spec();
    const t: number = solarNow();
    this.rx = roamAt(t, s, 0) * s.roam * this.boxW;
    this.ry = roamAt(t, s, 1) * s.roam * this.boxH;
    for (let i = 0; i < s.periods.length; i++) {
      this.setOrb(i, (t % s.periods[i]) / s.periods[i] * 360);
    }
  }

  /** 公转 + 呼吸 + 漫游。全部交给 animateTo，只有换漫游目标时才跑一次 JS。 */
  private startMotion(): void {
    const s: SolarSpec = this.spec();
    for (let i = 0; i < s.periods.length; i++) {
      this.loopOrbit(i, s.periods[i]);
    }
    this.getUIContext().animateTo({
      duration: 5500, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate
    }, () => {
      this.pulse = 1;
    });
    this.nextRoam();
  }

  /**
   * 一颗星球的无限公转。
   * ⚠️ 起点是"此刻的相位"、终点是它 +360：直接写 0→360 会让每次打开都从初相
   *    重来（用户要求记住进度）。360 与 0 视觉同位，所以循环接缝看不出来。
   */
  private loopOrbit(i: number, period: number): void {
    const to: number = this.orbOf(i) + 360;
    this.getUIContext().animateTo({
      duration: period, curve: Curve.Linear, iterations: -1
    }, () => {
      this.setOrb(i, to);
    });
  }

  /** 漫游：朝"18 秒后该在的地方"匀速挪过去，到点再取下一个目标。 */
  private nextRoam(): void {
    if (!this.alive) {
      return;
    }
    const s: SolarSpec = this.spec();
    const t1: number = solarNow() + ROAM_LEG_MS;
    this.getUIContext().animateTo({
      duration: ROAM_LEG_MS, curve: Curve.Linear,
      onFinish: () => {
        this.nextRoam();
      }
    }, () => {
      this.rx = roamAt(t1, s, 0) * s.roam * this.boxW;
      this.ry = roamAt(t1, s, 1) * s.roam * this.boxH;
    });
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 轨道：只描边、不填充，透明度压得很低，读起来是"纸上一条淡线"
      ForEach(this.spec().rings, (r: number, ri: number) => {
        Circle({ width: this.ringD(ri), height: this.ringD(ri) })
          .fillOpacity(0)
          .stroke(withAlpha(this.def().weave, this.darkMode ? '8C' : '9E'))
          .strokeWidth(1)
          .position({ x: this.size() / 2 - this.ringD(ri) / 2, y: this.size() / 2 - this.ringD(ri) / 2 })
      }, (r: number, ri: number) => 'r' + ri)

      // 恒星光晕：径向渐变从款色向外透明，与核心一起呼吸（尺寸 + 亮度同相）
      Circle({ width: STAR_HALO * this.short() * this.spec().scale,
        height: STAR_HALO * this.short() * this.spec().scale })
        .radialGradient({
          center: [STAR_HALO * this.short() * this.spec().scale / 2,
            STAR_HALO * this.short() * this.spec().scale / 2],
          radius: STAR_HALO * this.short() * this.spec().scale / 2,
          colors: [[withAlpha(this.def().glowA, this.darkMode ? 'B8' : '80'), 0.0],
            [withAlpha(this.def().glowA, this.darkMode ? '48' : '33'), 0.42],
            ['#00000000', 1.0]]
        })
        .position({
          x: this.size() / 2 - STAR_HALO * this.short() * this.spec().scale / 2,
          y: this.size() / 2 - STAR_HALO * this.short() * this.spec().scale / 2
        })
        .opacity(0.72 + this.pulse * 0.30)
        .scale({ x: 0.94 + this.pulse * 0.10, y: 0.94 + this.pulse * 0.10 })

      // 恒星核心
      Circle({ width: STAR_CORE * this.short() * this.spec().scale,
        height: STAR_CORE * this.short() * this.spec().scale })
        .radialGradient({
          center: [STAR_CORE * this.short() * this.spec().scale / 2,
            STAR_CORE * this.short() * this.spec().scale / 2],
          radius: STAR_CORE * this.short() * this.spec().scale / 2,
          colors: [[this.darkMode ? '#FFFFFFFF' : '#FFFFF7E4', 0.26],
            [this.starCore(), 0.62],
            ['#00000000', 1.0]]
        })
        .position({
          x: this.size() / 2 - STAR_CORE * this.short() * this.spec().scale / 2,
          y: this.size() / 2 - STAR_CORE * this.short() * this.spec().scale / 2
        })
        .opacity(0.88 + this.pulse * 0.12)

      // 小星球：每颗一个**轨道那么大**的透明容器绕自己的心转，星球摆在正上方，
      // 转起来就是沿那条轨道公转（相位乘 dirs → 有的顺转、有的逆转）。
      ForEach(this.spec().planets, (p: number, pi: number) => {
        Stack() {
          Circle({ width: this.planetD(pi), height: this.planetD(pi) })
            .fill(this.planetColor(pi))
            .position({ x: this.ringD(pi) / 2 - this.planetD(pi) / 2, y: -this.planetD(pi) / 2 })
        }
        .width(this.ringD(pi))
        .height(this.ringD(pi))
        .position({ x: this.size() / 2 - this.ringD(pi) / 2, y: this.size() / 2 - this.ringD(pi) / 2 })
        .hitTestBehavior(HitTestMode.None)
        .rotate({
          x: 0, y: 0, z: 1, angle: this.orbOf(pi) * this.spec().dirs[pi],
          centerX: '50%', centerY: '50%'
        })
      }, (p: number, pi: number) => 'p' + pi)
    }
    .width(this.size())
    .height(this.size())
    .position({ x: this.baseX() - this.size() / 2, y: this.baseY() - this.size() / 2 })
    .translate({ x: this.rx, y: this.ry })
    .hitTestBehavior(HitTestMode.None)
  }
}

// ══════════════════════ 壁纸本体 ══════════════════════

/**
 * 程序化壁纸本体：底色渐变 + 最多五组恒星系（+ 深色的满天星），铺满父容器。
 * 纯声明式节点绘制、无位图、每帧零 JS。
 */
@Component
export struct GenWallpaper {
  @Prop @Watch('onStyleChanged') styleId: string = '';
  /** 深色模式：改用深色孪生款配色，并叠满天星 */
  @Prop darkMode: boolean = false;
  /**
   * **纯底模式**：恒星系照画，但**一样都不动**（不启动任何动画）。
   * 设置页等"内容为主"的页面用（用户要求：设置页背景不要动来动去）。
   */
  @Prop plain: boolean = false;
  /** 实测尺寸（vp）：半径按短边换算，量到之前只铺底色渐变 */
  @State boxW: number = 0;
  @State boxH: number = 0;
  /** 满天星的五组闪烁相位：一组一条无限往复动画，星星按 g 取自己那组 */
  @State tw0: number = 0;
  @State tw1: number = 0;
  @State tw2: number = 0;
  @State tw3: number = 0;
  @State tw4: number = 0;
  /** 闪烁动画的启动定时器（首帧之后才播） */
  private twTimer: number = -1;

  aboutToAppear(): void {
    this.startTwinkle();
  }

  aboutToDisappear(): void {
    if (this.twTimer >= 0) {
      clearTimeout(this.twTimer);
      this.twTimer = -1;
    }
  }

  /** 深色满天星：五组 2.3s ~ 4.8s 的往复淡入淡出。 */
  private startTwinkle(): void {
    if (this.twTimer >= 0) {
      clearTimeout(this.twTimer);
      this.twTimer = -1;
    }
    this.tw0 = 0;
    this.tw1 = 0;
    this.tw2 = 0;
    this.tw3 = 0;
    this.tw4 = 0;
    if (this.plain || !this.darkMode) {
      return;
    }
    this.twTimer = setTimeout(() => {
      this.twTimer = -1;
      for (let g = 0; g < TWINKLE_PHASE_MS.length; g++) {
        this.getUIContext().animateTo({
          duration: TWINKLE_PHASE_MS[g], curve: Curve.EaseInOut,
          iterations: -1, playMode: PlayMode.Alternate
        }, () => {
          this.setTw(g, 1);
        });
      }
    }, 600);
  }

  private setTw(g: number, v: number): void {
    if (g === 0) {
      this.tw0 = v;
    } else if (g === 1) {
      this.tw1 = v;
    } else if (g === 2) {
      this.tw2 = v;
    } else if (g === 3) {
      this.tw3 = v;
    } else {
      this.tw4 = v;
    }
  }

  /** 一颗背景星的透明度：所在相位 × 自己那点幅度差 */
  private twinkleOf(s: TwinkleSpec): number {
    const p: number = s.g === 0 ? this.tw0 : s.g === 1 ? this.tw1
      : s.g === 2 ? this.tw2 : s.g === 3 ? this.tw3 : this.tw4;
    return 0.16 + p * (0.40 + s.d * 0.16);
  }

  /** 换壁纸 / 深浅切换 → 满天星重新起（恒星系随 @Prop 自己更新） */
  private onStyleChanged(): void {
    this.startTwinkle();
  }

  private def(): GenWallpaperDef {
    const found: GenWallpaperDef | null = resolveGenWallpaper(this.styleId, this.darkMode);
    return found !== null ? found : GEN_WALLPAPERS[0];
  }

  /** 记下容器尺寸（vp）。没变就不写，省掉一次全组件重绘。 */
  private rememberSize(area: Area): void {
    const w: Length = area.width;
    const h: Length = area.height;
    if (typeof w === 'number' && typeof h === 'number'
      && (w !== this.boxW || h !== this.boxH)) {
      this.boxW = w;
      this.boxH = h;
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 165,
          colors: [[this.def().top, 0.0], [this.def().bottom, 1.0]]
        })

      // 半径按短边算，所以必须先量到尺寸；量不到就只留上面那层渐变（不影响可读性）。
      if (this.boxW > 0 && this.boxH > 0) {
        // 深色模式的满天星：小圆点 + 五组相位交替淡入淡出
        if (this.darkMode) {
          ForEach(TWINKLE_STARS, (s: TwinkleSpec, idx: number) => {
            Circle({ width: s.d, height: s.d })
              .fill('#FFFFFFFF')
              .position({ x: s.x * this.boxW, y: s.y * this.boxH })
              .opacity(this.twinkleOf(s))
          }, (s: TwinkleSpec, idx: number) => 'tw' + idx)
        }

        // 五组恒星系：各自公转 + 各自漫游
        ForEach(SOLAR_SYSTEMS, (s: SolarSpec, idx: number) => {
          SolarSystem({
            idx: idx, boxW: this.boxW, boxH: this.boxH,
            styleId: this.styleId, darkMode: this.darkMode, plain: this.plain
          })
        }, (s: SolarSpec, idx: number) => 'sys' + idx)
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.rememberSize(newArea);
    })
  }
}
