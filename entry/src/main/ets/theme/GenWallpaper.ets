/**
 * 澄笺 · 程序化壁纸（恒星系统 / 小宇宙）
 * ====================================
 *
 * **不内置任何 png**：天空、恒星、轨道、行星、星尘、彗星全部用声明式节点画出来。
 *
 * 分工：
 *  · `SolarField` —— 唯一的模拟场（一个 setInterval）：引力、弹弓、吞并、黑洞合并、
 *    超新星、星尘凝聚、行星捕获、彗星。坐标归一化，状态存 AppStorage，
 *    **杀掉重开接着演，不回初始位置**。
 *  · 本文件 —— 只负责把场上那份天画出来。每个星系一个 `SolarSystem`，
 *    位置/尺寸/黑洞量由订阅回调同步进 @State（位移小于阈值就不写，静止时零开销）；
 *    行星公转继续走 `animateTo` 的无限循环（合成层插值、每帧零 JS），
 *    起步相位取场上那颗星当前的 spin，所以转速可调且重开不从头开始。
 *  · 深色模式额外叠一层会闪烁的满天星（五组相位、各闪各的）。
 *
 * 旧版的两个整屏 `.blur(56)` 光斑层与逐格 Canvas 已撤 —— 那是转场卡顿率报告点名的开销。
 */

import { L10n } from '../service/L10n';
import { SolarBody, SolarComet, SolarDust, SolarField, SolarFlash } from './SolarField';

/** 一款程序化壁纸的定义 */
export interface GenWallpaperDef {
  id: string;
  name: string;
  /** 一句话说明，给设置页做副标题 */
  hint: string;
  /** 底色渐变：上 / 下 */
  top: string;
  bottom: string;
  /** 环境光两色（深色孪生款也各有一套） */
  glowA: string;
  glowB: string;
  /** 轨道线颜色（透明度已写进 #AARRGGBB） */
  weave: string;
  /** **深色孪生款 id**：空串 = 深浅都用自己 */
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

function mixHex(a: string, b: string, k: number): string {
  const ca: number[] = parseRgb(a, [0, 0, 0]);
  const cb: number[] = parseRgb(b, [0, 0, 0]);
  const r: number = ca[0] + (cb[0] - ca[0]) * k;
  const g: number = ca[1] + (cb[1] - ca[1]) * k;
  const bl: number = ca[2] + (cb[2] - ca[2]) * k;
  return '#FF' + hex2(r) + hex2(g) + hex2(bl);
}

/** 换掉一个颜色的透明度字节（aa 是两位十六进制，如 '8C' ≈ 0.55） */
function withAlpha(hex: string, aa: string): string {
  const c: number[] = parseRgb(hex, [128, 128, 128]);
  return '#' + aa + hex2(c[0]) + hex2(c[1]) + hex2(c[2]);
}

/** 亮度倍率压进透明度字节（0.4~1.8 的滑杆就靠这个生效） */
function brightAlpha(hex: string, base: number, bright: number): string {
  const a: number = Math.max(0, Math.min(255, Math.round(base * bright)));
  return '#' + hex2(a) + hex2(parseRgb(hex, [255, 255, 255])[0])
    + hex2(parseRgb(hex, [255, 255, 255])[1]) + hex2(parseRgb(hex, [255, 255, 255])[2]);
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
    darkId: 'song'
  },
  {
    id: 'xuan',
    name: L10n.t('宣纸'),
    hint: L10n.t('暖白宣纸 · 极淡纤维纹'),
    top: '#F6F1E7', bottom: '#E9DFCE',
    glowA: '#E8C89A', glowB: '#CFE0D8',
    weave: '#12857A5A',
    darkId: 'song'
  },
  {
    id: 'yan',
    name: L10n.t('砚青'),
    hint: L10n.t('砚台青灰 · 一点冷光'),
    top: '#DCE3E4', bottom: '#BFCBCD',
    glowA: '#6FA6B8', glowB: '#DDE7E5',
    weave: '#12344B55',
    darkId: 'song'
  },
  {
    id: 'song',
    name: L10n.t('松烟'),
    hint: L10n.t('墨色深底 · 暗光斑'),
    top: '#2A2E36', bottom: '#171A20',
    glowA: '#4E6B8A', glowB: '#7A6A55',
    weave: '#14FFFFFF',
    darkId: ''
  },
  {
    id: 'zhu',
    name: L10n.t('竹影'),
    hint: L10n.t('淡青竹叶色 · 竖纹如竹'),
    top: '#E7EFE6', bottom: '#CFDECC',
    glowA: '#8FBF8A', glowB: '#E6EFC9',
    weave: '#10507A44',
    darkId: 'ye'
  },
  {
    id: 'xia',
    name: L10n.t('霞笺'),
    hint: L10n.t('晚霞粉橙 · 暖光晕'),
    top: '#FBEDE4', bottom: '#F0D3C4',
    glowA: '#F2A98A', glowB: '#F6D9A8',
    weave: '#128A5B44',
    darkId: 'ye'
  },
  {
    id: 'ye',
    name: L10n.t('夜笺'),
    hint: L10n.t('夜读深蓝 · 冷月白'),
    top: '#262B3C', bottom: '#171C26',
    glowA: '#4A5F9E', glowB: '#8E9BC4',
    weave: '#12FFFFFF',
    darkId: ''
  }
];

/** 按 id 取定义；找不到返回 null */
export function genWallpaperById(id: string): GenWallpaperDef | null {
  for (let k = 0; k < GEN_WALLPAPERS.length; k++) {
    if (GEN_WALLPAPERS[k].id === id) {
      return GEN_WALLPAPERS[k];
    }
  }
  return null;
}

/** 深色孪生解析：深色模式下改用该款的 darkId（竹影 → 夜笺） */
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

/**
 * 程序化壁纸在当前深浅下实际生效那一款的主底色（渐变上下色的中值）。
 * 用途：关闭沉浸光感时的侧边栏 / 面板底色要「与背景同色」。
 */
export function genWallpaperFlatColor(id: string, dark: boolean): string {
  const use: GenWallpaperDef | null = resolveGenWallpaper(id, dark);
  if (use === null) {
    return '';
  }
  return mixHex(use.top, use.bottom, 0.5);
}

/** 一颗背景星：位置按整屏百分比算，d 是直径（vp），g 是闪烁相位组 */
interface TwinkleSpec {
  x: number;
  y: number;
  d: number;
  g: number;
}

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

const TWINKLE_PHASE_MS: number[] = [2300, 2900, 3400, 4100, 4800];
/** 行星公转的基准周期（ms）：转速滑杆就是除在它上面 */
const ORBIT_BASE_MS: number = 30000;
/** AppStorage：转速 / 参数变化时自增，让各星系的公转循环重新起 */
export const SOLAR_MOTION_KEY: string = 'solarMotionTick';

// ══════════════════════ 一个恒星系 ══════════════════════

@Component
struct SolarSystem {
  /** 场上第几颗（下标，不传对象） */
  @Prop slot: number = 0;
  @Prop boxW: number = 0;
  @Prop boxH: number = 0;
  @Prop styleId: string = '';
  @Prop darkMode: boolean = false;
  /** 纯底模式：行星不自转（位置仍跟着场子走） */
  @Prop plain: boolean = false;
  @StorageProp(SOLAR_MOTION_KEY) @Watch('onMotionChanged') motionTick: number = 0;
  /** 同步自模拟场的量（位移小于阈值不写，静止时零重绘） */
  @State px: number = 0.5;
  @State py: number = 0.5;
  @State sc: number = 0.2;
  @State gr: number = 1;
  @State dk: number = 0;
  @State rg: number = 0;
  @State pl: number = 3;
  @State hex: string = '#FFF4DC';
  /** 本地公转相位（0→360 无限循环，合成层插值） */
  @State orb: number = 0;
  @State pulse: number = 0;
  private timer: number = -1;
  private alive: boolean = true;
  private readonly onTick: () => void = (): void => {
    this.syncFromField();
  };

  aboutToAppear(): void {
    SolarField.subscribe(this.onTick);
    this.syncFromField(true);
    if (this.plain) {
      return;
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      if (this.alive) {
        this.startLoops();
      }
    }, 600);
  }

  aboutToDisappear(): void {
    this.alive = false;
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    SolarField.unsubscribe(this.onTick);
  }

  onMotionChanged(): void {
    if (!this.plain && this.alive) {
      this.startLoops();
    }
  }

  private body(): SolarBody | null {
    return this.slot >= 0 && this.slot < SolarField.bodies.length ? SolarField.bodies[this.slot] : null;
  }

  /** 把场上那颗的数值抄进 @State；几乎没动就别写 */
  private syncFromField(force: boolean = false): void {
    const b: SolarBody | null = this.body();
    if (b === null) {
      return;
    }
    if (force || Math.abs(b.x - this.px) > 0.0004 || Math.abs(b.y - this.py) > 0.0004
      || Math.abs(b.scale - this.sc) > 0.002 || Math.abs(b.grow - this.gr) > 0.01
      || Math.abs(b.dark - this.dk) > 0.01 || Math.abs(b.ring - this.rg) > 0.01
      || b.planets !== this.pl || b.hex !== this.hex) {
      this.px = b.x;
      this.py = b.y;
      this.sc = b.scale;
      this.gr = b.grow;
      this.dk = b.dark;
      this.rg = b.ring;
      this.pl = b.planets;
      this.hex = b.hex;
    }
  }

  /** 公转 / 呼吸的循环：起点用场上当前的 spin，转速由 params.speed 决定 */
  private startLoops(): void {
    const b: SolarBody | null = this.body();
    const speed: number = Math.max(0.2, SolarField.params.speed);
    this.orb = b === null ? 0 : b.spin % 360;
    this.pulse = 0;
    this.getUIContext().animateTo({
      duration: ORBIT_BASE_MS / speed, curve: Curve.Linear, iterations: -1
    }, () => {
      this.orb = this.orb + 360;
    });
    this.getUIContext().animateTo({
      duration: 5500, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate
    }, () => {
      this.pulse = 1;
    });
  }

  private short(): number {
    return this.boxW < this.boxH ? this.boxW : this.boxH;
  }

  private scaleNow(): number {
    return this.sc * (0.35 + 0.65 * this.gr);
  }

  /** 盒子边长：装得下最外圈轨道（**不能取名 size** —— CustomComponent 已有 size 属性方法） */
  private boxSize(): number {
    let maxR: number = 0.21;
    for (let i = 0; i < this.pl; i++) {
      const r: number = (0.21 + i * 0.12);
      if (r > maxR) {
        maxR = r;
      }
    }
    return maxR * 2 * this.short() * this.scaleNow() * 1.35;
  }

  private orbitD(i: number): number {
    return (0.21 + i * 0.12) * 2 * this.short() * this.scaleNow();
  }

  private coreD(): number {
    return 0.30 * this.short() * this.scaleNow();
  }

  private haloD(): number {
    return 1.15 * this.short() * this.scaleNow();
  }

  /** 内圈快、外圈慢：角度增量按开普勒 r^-1.5 缩放 */
  private planetAngle(i: number): number {
    const b: SolarBody | null = this.body();
    const inner: number = 0.21;
    const r: number = Math.max(0.05, inner + i * 0.12);
    const k: number = Math.pow(inner / r, 1.5);
    const dir: number = b === null ? 1 : b.dir;
    return this.orb * k * dir;
  }

  private planetD(i: number): number {
    return 0.05 * this.short() * this.scaleNow() * SolarField.params.planetSize * (0.72 + 0.28 * ((i + 1) % 3));
  }

  private planetColor(i: number): string {
    const base: string = i === 1 ? this.def().glowB : this.hex;
    return mixHex(base, this.darkMode ? '#FFFFFF' : '#20252D', this.darkMode ? 0.58 : 0.74);
  }

  private def(): GenWallpaperDef {
    const found: GenWallpaperDef | null = resolveGenWallpaper(this.styleId, this.darkMode);
    return found !== null ? found : GEN_WALLPAPERS[0];
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 轨道（可在设置里关掉；黑洞阶段淡出）
      if (SolarField.params.rings && this.dk < 0.2) {
        ForEach(this.ringSlots(), (i: number) => {
          Circle({ width: this.orbitD(i), height: this.orbitD(i) })
            .fillOpacity(0)
            .stroke(withAlpha(this.def().weave, this.darkMode ? '8C' : '9E'))
            .strokeWidth(1)
            .position({ x: this.boxSize() / 2 - this.orbitD(i) / 2, y: this.boxSize() / 2 - this.orbitD(i) / 2 })
        }, (i: number) => 'r' + i)
      }

      // 光晕
      Circle({ width: this.haloD(), height: this.haloD() })
        .radialGradient({
          center: [this.haloD() / 2, this.haloD() / 2],
          radius: this.haloD() / 2,
          colors: [[brightAlpha(this.hex, 184, SolarField.params.bright * (1 - this.dk * 0.7)), 0.0],
            [brightAlpha(this.hex, 72, SolarField.params.bright * (1 - this.dk * 0.7)), 0.42],
            ['#00000000', 1.0]]
        })
        .position({ x: this.boxSize() / 2 - this.haloD() / 2, y: this.boxSize() / 2 - this.haloD() / 2 })
        .opacity(0.72 + this.pulse * 0.30)
        .scale({ x: 0.94 + this.pulse * 0.10, y: 0.94 + this.pulse * 0.10 })

      // 吸积盘：黑洞阶段才亮，压扁的椭圆 + 旋转
      if (this.rg > 0.02) {
        Ellipse()
          .width(this.coreD() * (0.9 + this.rg * 1.1))
          .height(this.coreD() * (0.9 + this.rg * 1.1) * 0.34)
          .fillOpacity(0)
          .stroke(withAlpha('#FFC178', 'BF'))
          .strokeWidth(2.2 * this.rg + 0.6)
          .position({
            x: this.boxSize() / 2 - this.coreD() * (0.9 + this.rg * 1.1) / 2,
            y: this.boxSize() / 2 - this.coreD() * (0.9 + this.rg * 1.1) * 0.17
          })
          .rotate({ x: 0, y: 0, z: 1, angle: this.orb * 1.6, centerX: '50%', centerY: '50%' })
      }

      // 恒星核心（dark → 1 时变黑，就是黑洞）
      Circle({ width: this.coreD(), height: this.coreD() })
        .radialGradient({
          center: [this.coreD() / 2, this.coreD() / 2],
          radius: this.coreD() / 2,
          colors: [[this.darkMode ? '#FFFFFFFF' : '#FFFFF7E4', 0.26],
            [mixHex(this.hex, '#05060A', this.dk), 0.62],
            ['#00000000', 1.0]]
        })
        .position({ x: this.boxSize() / 2 - this.coreD() / 2, y: this.boxSize() / 2 - this.coreD() / 2 })
        .opacity(0.88 + this.pulse * 0.12)

      // 行星：每颗一个轨道大小的容器绕自己的心转（合成层，每帧零 JS）
      if (this.dk < 0.35) {
        ForEach(this.planetSlots(), (i: number) => {
          Stack() {
            Circle({ width: this.planetD(i), height: this.planetD(i) })
              .fill(this.planetColor(i))
              .position({ x: this.orbitD(i) / 2 - this.planetD(i) / 2, y: -this.planetD(i) / 2 })
          }
          .width(this.orbitD(i))
          .height(this.orbitD(i))
          .position({ x: this.boxSize() / 2 - this.orbitD(i) / 2, y: this.boxSize() / 2 - this.orbitD(i) / 2 })
          .hitTestBehavior(HitTestMode.None)
          .rotate({
            x: 0, y: 0, z: 1, angle: this.planetAngle(i),
            centerX: '50%', centerY: '50%'
          })
        }, (i: number) => 'p' + i)
      }
    }
    .width(this.boxSize())
    .height(this.boxSize())
    .position({
      x: this.px * this.boxW - this.boxSize() / 2,
      y: this.py * this.boxH - this.boxSize() / 2
    })
    .hitTestBehavior(HitTestMode.None)
  }

  /** ForEach 要有稳定数组：轨道 / 行星的下标数组（随行星数变化） */
  private ringSlots(): number[] {
    const out: number[] = [];
    for (let i = 0; i < this.pl; i++) {
      out.push(i);
    }
    return out;
  }

  private planetSlots(): number[] {
    return this.ringSlots();
  }
}

// ══════════════════════ 星尘 / 流浪行星 / 彗星 / 爆炸 ══════════════════════

@Component
struct SolarSkyLayer {
  @Prop boxW: number = 0;
  @Prop boxH: number = 0;
  @Prop plain: boolean = false;
  /** 场子每次通知都自增；只有场上有东西时才写（否则静止时零重绘） */
  @State tick: number = 0;
  @State dust: SolarDust[] = [];
  @State comets: SolarComet[] = [];
  @State flashes: SolarFlash[] = [];
  private readonly onTick: () => void = (): void => {
    const busy: boolean = SolarField.dust.length > 0 || SolarField.comets.length > 0
      || SolarField.flashes.length > 0;
    if (busy) {
      this.dust = SolarField.dust.slice();
      this.comets = SolarField.comets.slice();
      this.flashes = SolarField.flashes.slice();
      this.tick = this.tick + 1;
    }
  };

  aboutToAppear(): void {
    SolarField.subscribe(this.onTick);
  }

  aboutToDisappear(): void {
    SolarField.unsubscribe(this.onTick);
  }

  private short(): number {
    return this.boxW < this.boxH ? this.boxW : this.boxH;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 星尘 / 流浪行星 / 被抢途中那颗
      ForEach(this.dust, (d: SolarDust, i: number) => {
        Circle({ width: d.size * this.short(), height: d.size * this.short() })
          .fill(d.hex)
          .opacity(0.20 + d.glow * (d.kind === 0 ? 0.55 : 0.80))
          .position({
            x: d.x * this.boxW - d.size * this.short() / 2,
            y: d.y * this.boxH - d.size * this.short() / 2
          })
      }, (d: SolarDust, i: number) => 'd' + i + '_' + this.tick)

      // 彗星：一条渐变尾巴 + 一颗头（ForEach 的每一项只能有一个根节点，所以套 Stack）
      ForEach(this.comets, (c: SolarComet, i: number) => {
        Stack({ alignContent: Alignment.TopStart }) {
          Column()
            .width(this.short() * 0.30)
            .height(2.4)
            .linearGradient({
              angle: 90,
              colors: [[withAlpha('#FFFFFF', 'D8'), 0.0], ['#00000000', 1.0]]
            })
            .position({ x: -this.short() * 0.30, y: -1.2 })
          Circle({ width: 5, height: 5 })
            .fill('#FFFFFFFF')
            .position({ x: -2.5, y: -2.5 })
        }
        .width(0.1)
        .height(0.1)
        .position({ x: c.x * this.boxW, y: c.y * this.boxH })
        .rotate({
          x: 0, y: 0, z: 1,
          angle: Math.atan2(c.vy * this.boxH, c.vx * this.boxW) * 180 / Math.PI + 180,
          centerX: 0, centerY: 0
        })
      }, (c: SolarComet, i: number) => 'c' + i)

      // 爆炸：冲击环 + 中心闪光（黑洞合并的 power 更大）
      ForEach(this.flashes, (f: SolarFlash, i: number) => {
        Stack({ alignContent: Alignment.TopStart }) {
          Circle({ width: this.ringSize(f), height: this.ringSize(f) })
            .fillOpacity(0)
            .stroke(withAlpha('#FFE7B0', this.aa(this.ringLevel(f))))
            .strokeWidth(2.6 * (1 - f.t / 1400) + 0.5)
            .position({ x: -this.ringSize(f) / 2, y: -this.ringSize(f) / 2 })
          Circle({ width: this.flashSize(f), height: this.flashSize(f) })
            .radialGradient({
              center: [this.flashSize(f) / 2, this.flashSize(f) / 2],
              radius: this.flashSize(f) / 2,
              colors: [[withAlpha('#FFF3D6', this.aa(this.ringLevel(f))), 0.0],
                [withAlpha('#FFC178', this.aa(this.ringLevel(f) * 0.4)), 0.5],
                ['#00000000', 1.0]]
            })
            .position({ x: -this.flashSize(f) / 2, y: -this.flashSize(f) / 2 })
        }
        .width(0.1)
        .height(0.1)
        .position({ x: f.x * this.boxW, y: f.y * this.boxH })
      }, (f: SolarFlash, i: number) => 'f' + i + '_' + this.tick)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  private ringSize(f: SolarFlash): number {
    const k: number = Math.min(1, f.t / 1100);
    return this.short() * (0.06 + k * 0.45) * f.power;
  }

  private flashSize(f: SolarFlash): number {
    const k: number = Math.min(1, f.t / 1100);
    return this.short() * (0.10 + k * 0.30) * f.power;
  }

  private ringLevel(f: SolarFlash): number {
    return Math.max(0, 1 - f.t / 1400);
  }

  /** 0~1 的亮度 → '#AARRGGBB' 里那两位透明度 */
  private aa(level: number): string {
    const v: number = Math.max(0, Math.min(1, level));
    return hex2(Math.round(v * 255));
  }
}

// ══════════════════════ 壁纸本体 ══════════════════════

/**
 * 程序化壁纸本体：底色渐变 + 场上的星系 + 星尘/彗星/爆炸 + 深色满天星。
 * 铺满父容器（设置页那张实时预览就是同一个组件套在小盒子里）。
 */
@Component
export struct GenWallpaper {
  @Prop @Watch('onStyleChanged') styleId: string = '';
  /** 深色模式：改用深色孪生款配色，并叠满天星 */
  @Prop darkMode: boolean = false;
  /** 纯底模式：行星不自转、满天星不闪（设置页等内容为主的页面） */
  @Prop plain: boolean = false;
  /** 实测尺寸（vp） */
  @State boxW: number = 0;
  @State boxH: number = 0;
  /** 场上星系个数（只在真的变了时写，避免每帧重建子组件） */
  @State count: number = 0;
  /** 满天星的五组闪烁相位 */
  @State tw0: number = 0;
  @State tw1: number = 0;
  @State tw2: number = 0;
  @State tw3: number = 0;
  @State tw4: number = 0;
  private twTimer: number = -1;
  private readonly onTick: () => void = (): void => {
    if (SolarField.bodies.length !== this.count) {
      this.count = SolarField.bodies.length;
    }
  };

  aboutToAppear(): void {
    SolarField.subscribe(this.onTick);
    this.count = SolarField.bodies.length;
    this.startTwinkle();
  }

  aboutToDisappear(): void {
    SolarField.unsubscribe(this.onTick);
    if (this.twTimer >= 0) {
      clearTimeout(this.twTimer);
      this.twTimer = -1;
    }
  }

  /** 深色满天星：五组 2.3s ~ 4.8s 的往复淡入淡出 */
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

  private twinkleOf(s: TwinkleSpec): number {
    const p: number = s.g === 0 ? this.tw0 : s.g === 1 ? this.tw1
      : s.g === 2 ? this.tw2 : s.g === 3 ? this.tw3 : this.tw4;
    return 0.16 + p * (0.40 + s.d * 0.16);
  }

  private onStyleChanged(): void {
    this.startTwinkle();
  }

  private def(): GenWallpaperDef {
    const found: GenWallpaperDef | null = resolveGenWallpaper(this.styleId, this.darkMode);
    return found !== null ? found : GEN_WALLPAPERS[0];
  }

  private slots(): number[] {
    const out: number[] = [];
    for (let i = 0; i < this.count; i++) {
      out.push(i);
    }
    return out;
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

      if (this.boxW > 0 && this.boxH > 0) {
        if (this.darkMode) {
          ForEach(TWINKLE_STARS, (s: TwinkleSpec, idx: number) => {
            Circle({ width: s.d, height: s.d })
              .fill('#FFFFFFFF')
              .position({ x: s.x * this.boxW, y: s.y * this.boxH })
              .opacity(this.twinkleOf(s))
          }, (s: TwinkleSpec, idx: number) => 'tw' + idx)
        }

        SolarSkyLayer({ boxW: this.boxW, boxH: this.boxH, plain: this.plain })

        ForEach(this.slots(), (i: number) => {
          SolarSystem({
            slot: i, boxW: this.boxW, boxH: this.boxH,
            styleId: this.styleId, darkMode: this.darkMode, plain: this.plain
          })
        }, (i: number) => 'sys' + i)
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.rememberSize(newArea);
    })
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
}
