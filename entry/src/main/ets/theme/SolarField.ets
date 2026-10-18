/**
 * 澄笺 · 恒星系壁纸的模拟场（小宇宙）
 * =================================
 *
 * 壁纸不是循环动画，是**一个一直在往前走的迷你宇宙**：
 *  · 星系之间互相吸引，近距离会**被弹弓甩出去**（快的穿过去被拐弯，慢的才互斥分开）；
 *  · 靠得足够近 → 大的一方把小的一方**螺旋吞下** → 塌成黑洞（吸积盘亮起、核心变黑）；
 *  · 两个黑洞相遇会**合并**，攒够质量就**超新星爆炸**，炸出一片星尘；
 *  · 星尘搁一段时间会**凝成流浪行星**，流浪行星撞在一起**点亮成恒星**（新的星系），
 *    从任何星系旁边路过就会被**捕获**成它的一颗行星，也会被别的星系**抢走**一颗；
 *  · 天上偶尔还有彗星横穿。
 *
 * 三条口径：
 *  1. **全场一个时钟**：模拟只跑在这个模块里（一个 setInterval），页面组件都是订阅者。
 *     书架和阅读页同时挂着壁纸也不会各算各的。
 *  2. **坐标一律归一化（0~1）**：竖屏、横屏、平板、分屏看到的是同一片天，渲染时再乘容器尺寸。
 *  3. **没有"回原位"这回事**：星系不绑基准点，被甩到哪就在哪，状态存 AppStorage，
 *     杀掉重开接着演。唯一的手脚是屏幕正中那条正文区留一层**软墙**（只推不吸），
 *     免得星体长期压在文字上；屏幕边缘允许滑出去再飘回来。
 *
 * 性能：20Hz 一帧，一次最多 5 个星系 + 24 粒星尘 + 6 颗流浪行星；
 * 所有量都靠 `approach()` 平滑逼近目标，不做瞬间赋值（上一版"跳变"的根因）。
 */

/** 星尘 / 流浪行星 / 被抢途中那颗行星，共用一种"游离小天体" */
export class SolarDust {
  x: number = 0;
  y: number = 0;
  vx: number = 0;
  vy: number = 0;
  /** 0 星尘（会凝成行星）/ 1 流浪行星（会被捕获或撞成恒星）/ 2 正在被转移的行星 */
  kind: number = 0;
  /** 已经活了多久（ms） */
  age: number = 0;
  /** 打算活多久（ms） */
  life: number = 8000;
  /** 亮度 0~1 */
  glow: number = 1;
  /** 颜色（#RRGGBB） */
  hex: string = '#FFFFFF';
  /** 大小（× 短边） */
  size: number = 0.006;
  /** kind=2 时：投奔的目标星系下标 */
  target: number = -1;
}

/** 一颗恒星系 */
export class SolarBody {
  x: number = 0.5;
  y: number = 0.5;
  vx: number = 0;
  vy: number = 0;
  /** 当前尺寸 / 目标尺寸：所有变化都靠平滑逼近 */
  scale: number = 0.2;
  tgtScale: number = 0.2;
  mass: number = 1;
  /** 自转相位（行星公转的驱动源，转速由 params.speed 调） */
  spin: number = 0;
  dir: number = 1;
  /** 新生时长出来的比例 0→1 */
  grow: number = 1;
  /** 0 常态 / 1 吸积 / 2 黑洞 / 3 爆炸后消散 */
  st: number = 0;
  stT: number = 0;
  dark: number = 0;
  ring: number = 0;
  /** 这一颗的行星数与随机星色 */
  planets: number = 3;
  hex: string = '#FFF4DC';
  /** 流浪星（被点去撞别人）/ 正在被谁吞 */
  hunt: boolean = false;
  dead: boolean = false;
  big: SolarBody | null = null;
  swT: number = 0;
  swR0: number = 0;
  swA0: number = 0;
  swS0: number = 0;
  swDir: number = 1;

  swallowing(): boolean {
    return this.big !== null;
  }
}

/** 一次爆炸的冲击环 */
export class SolarFlash {
  x: number = 0;
  y: number = 0;
  t: number = 0;
  /** 强度：黑洞合并的"巨大爆炸"比单颗超新星大得多 */
  power: number = 1;
}

/** 一颗彗星 */
export class SolarComet {
  x: number = 0;
  y: number = 0;
  vx: number = 0;
  vy: number = 0;
  life: number = 0;
}

/** 设置页可调的那组参数 */
export class SolarParams {
  /** 恒星亮度倍率 0.4 ~ 1.8 */
  bright: number = 1;
  /** 公转转速倍率 0.2 ~ 3 */
  speed: number = 1;
  /** 星色：random = 每系随机；其余为统一色 */
  color: string = 'random';
  /** 公转轨道画不画 */
  rings: boolean = true;
  /** 行星大小倍率 0.5 ~ 2 */
  planetSize: number = 1;
  /** 每个星系几颗行星 1 ~ 5 */
  planetCount: number = 3;
  /** 天空里几个星系 1 ~ 5 */
  systemCount: number = 5;
  comet: boolean = true;
  /** 引力（含弹弓、抢行星、碰撞） */
  gravity: boolean = true;
  /** 星尘演化（星尘→流浪行星→碰撞成恒星→捕获） */
  evolve: boolean = true;
}

/** AppStorage 键 */
export const SOLAR_STATE_KEY: string = 'solarFieldState';
/** 参数键（EntryAbility 里逐个 persistProp，SettingsMirror 里逐个镜像） */
export const SOLAR_KEYS_BRIGHT: string = 'solarBright';
export const SOLAR_KEYS_SPEED: string = 'solarSpeed';
export const SOLAR_KEYS_COLOR: string = 'solarColor';
export const SOLAR_KEYS_RINGS: string = 'solarRings';
export const SOLAR_KEYS_PSIZE: string = 'solarPlanetSize';
export const SOLAR_KEYS_PCOUNT: string = 'solarPlanetCount';
export const SOLAR_KEYS_SCOUNT: string = 'solarSystemCount';
export const SOLAR_KEYS_COMET: string = 'solarComet';
export const SOLAR_KEYS_GRAVITY: string = 'solarGravity';
export const SOLAR_KEYS_EVOLVE: string = 'solarEvolve';

/** 统一色候选（'random' 之外，用户选的色） */
export const SOLAR_COLOR_CHOICES: string[] = ['random', '#F2A93B', '#EAF2FF', '#6FC7E8', '#FF7A45', '#B07CF0'];

/** 出生位：一开始铺在边缘带（之后随演化自由飞），中间那条是正文区 */
const BIRTH: number[][] = [
  [0.20, 0.14], [0.84, 0.20], [0.11, 0.73], [0.87, 0.68], [0.47, 0.93]
];
const BIRTH_SCALES: number[] = [0.34, 0.22, 0.26, 0.30, 0.18];
/** 正文软墙（只推不吸）：压进这一条就被慢慢挤出去 */
const KEEP_X0: number = 0.26;
const KEEP_X1: number = 0.74;
const KEEP_Y0: number = 0.20;
const KEEP_Y1: number = 0.80;
const KEEP_PUSH: number = 0.30;
/** 屏幕外的软边界：滑出去一点会被拽回来，不会永远丢失 */
const EDGE: number = 0.14;
const EDGE_PULL: number = 0.5;

const GRAVITY_G: number = 0.0034;
const GRAVITY_SOFT: number = 0.05;
/** 相对速度低于这个值才互斥（快的直接穿过去 → 才有弹弓甩飞） */
const SLOW_SWAP: number = 0.16;
const DRAG: number = 0.06;
const HUNT_SPEED: number = 0.42;
const SWALLOW_MS: number = 1500;
/** 黑洞存活到合并/爆炸的时间 */
const HOLE_MS: number = 9000;
const FADE_MS: number = 1200;
const GROW_MS: number = 1400;
const CRASH_MIN_MS: number = 26000;
const CRASH_SPAN_MS: number = 46000;
const COMET_MIN_MS: number = 7000;
const COMET_SPAN_MS: number = 11000;
const COMET_SPEED: number = 0.55;
const DUST_MAX: number = 24;
const ROGUE_MAX: number = 6;
/** 星尘凝成流浪行星、流浪行星点亮成恒星的时间尺度 */
const DUST_CONDENSE_MS: number = 14000;
const ROGUE_IGNITE_MS: number = 26000;
const TICK_MS: number = 50;

function clamp(v: number, a: number, b: number): number {
  return v < a ? a : (v > b ? b : v);
}
function rnd(a: number, b: number): number {
  return a + Math.random() * (b - a);
}
function approach(cur: number, tgt: number, dt: number, tau: number): number {
  return cur + (tgt - cur) * clamp(dt / tau, 0, 1);
}
function hex2(v: number): string {
  const s: string = Math.round(clamp(v, 0, 255)).toString(16).toUpperCase();
  return s.length === 1 ? '0' + s : s;
}
/** hsl → '#RRGGBB'（自己写，省得为壁纸引一个颜色库） */
function hslHex(h: number, s: number, l: number): string {
  const c: number = (1 - Math.abs(2 * l - 1)) * s;
  const x: number = c * (1 - Math.abs(((h * 6) % 2) - 1));
  const m: number = l - c / 2;
  const seg: number = Math.floor(h * 6) % 6;
  let r: number = 0;
  let g: number = 0;
  let b: number = 0;
  if (seg === 0) {
    r = c; g = x; b = 0;
  } else if (seg === 1) {
    r = x; g = c; b = 0;
  } else if (seg === 2) {
    r = 0; g = c; b = x;
  } else if (seg === 3) {
    r = 0; g = x; b = c;
  } else if (seg === 4) {
    r = x; g = 0; b = c;
  } else {
    r = c; g = 0; b = x;
  }
  return '#' + hex2((r + m) * 255) + hex2((g + m) * 255) + hex2((b + m) * 255);
}
/** 随机星色：偏纸墨的低饱和，亮度压在 0.55~0.78，避免刺眼的大红大绿 */
function randomStarHex(): string {
  return hslHex(Math.random(), rnd(0.34, 0.62), rnd(0.55, 0.78));
}

/**
 * 模拟场。全部静态：整个应用只有一片天，谁要看谁来订阅。
 */
export class SolarField {
  static bodies: SolarBody[] = [];
  static dust: SolarDust[] = [];
  static flashes: SolarFlash[] = [];
  static comets: SolarComet[] = [];
  static params: SolarParams = new SolarParams();

  private static subs: Array<() => void> = [];
  private static timer: number = -1;
  private static refs: number = 0;
  private static lastAt: number = 0;
  private static clock: number = 0;
  private static nextCrashAt: number = 0;
  private static nextCometAt: number = 0;
  private static saveAt: number = 0;

  // ══════════════════════ 参数 ══════════════════════

  /** 参数从 AppStorage 读回来（设置页改完也调一次，立刻生效） */
  static reloadParams(): void {
    const p: SolarParams = SolarField.params;
    p.bright = SolarField.getNum(SOLAR_KEYS_BRIGHT, 1, 0.4, 1.8);
    p.speed = SolarField.getNum(SOLAR_KEYS_SPEED, 1, 0.2, 3);
    const c: string | undefined = AppStorage.get<string>(SOLAR_KEYS_COLOR);
    p.color = c === undefined || c === null || c.length === 0 ? 'random' : c;
    p.rings = SolarField.getBool(SOLAR_KEYS_RINGS, true);
    p.planetSize = SolarField.getNum(SOLAR_KEYS_PSIZE, 1, 0.5, 2);
    p.planetCount = Math.round(SolarField.getNum(SOLAR_KEYS_PCOUNT, 3, 1, 5));
    p.systemCount = Math.round(SolarField.getNum(SOLAR_KEYS_SCOUNT, 5, 1, 5));
    p.comet = SolarField.getBool(SOLAR_KEYS_COMET, true);
    p.gravity = SolarField.getBool(SOLAR_KEYS_GRAVITY, true);
    p.evolve = SolarField.getBool(SOLAR_KEYS_EVOLVE, true);
    SolarField.applyColor();
    SolarField.syncCount();
  }

  /** 统一色 / 随机色：随机时给每颗保留自己那份色，不重新摇 */
  private static applyColor(): void {
    const p: SolarParams = SolarField.params;
    if (p.color === 'random') {
      return;
    }
    for (let i = 0; i < SolarField.bodies.length; i++) {
      SolarField.bodies[i].hex = p.color;
    }
  }

  private static getNum(key: string, def: number, lo: number, hi: number): number {
    const v: number | undefined = AppStorage.get<number>(key);
    if (v === undefined || v === null || isNaN(v)) {
      return def;
    }
    return clamp(v, lo, hi);
  }

  private static getBool(key: string, def: boolean): boolean {
    const v: boolean | undefined = AppStorage.get<boolean>(key);
    return v === undefined || v === null ? def : v;
  }

  // ══════════════════════ 订阅与节拍 ══════════════════════

  static subscribe(cb: () => void): void {
    SolarField.subs.push(cb);
    SolarField.refs++;
    if (SolarField.refs === 1) {
      SolarField.load();
      SolarField.reloadParams();
      SolarField.lastAt = Date.now();
      SolarField.timer = setInterval(() => {
        SolarField.tick();
      }, TICK_MS);
    }
  }

  static unsubscribe(cb: () => void): void {
    const at: number = SolarField.subs.indexOf(cb);
    if (at >= 0) {
      SolarField.subs.splice(at, 1);
    }
    SolarField.refs = Math.max(0, SolarField.refs - 1);
    if (SolarField.refs === 0 && SolarField.timer >= 0) {
      clearInterval(SolarField.timer);
      SolarField.timer = -1;
      SolarField.save();
    }
  }

  private static notify(): void {
    for (let i = 0; i < SolarField.subs.length; i++) {
      SolarField.subs[i]();
    }
  }

  private static tick(): void {
    const now: number = Date.now();
    const dt: number = Math.min(120, now - SolarField.lastAt);
    SolarField.lastAt = now;
    SolarField.clock += dt;
    SolarField.step(dt);
    SolarField.notify();
    if (now - SolarField.saveAt > 6000) {
      SolarField.saveAt = now;
      SolarField.save();
    }
  }

  // ══════════════════════ 生成 ══════════════════════

  private static makeBody(slot: number, x: number, y: number): SolarBody {
    const b: SolarBody = new SolarBody();
    const i: number = clamp(slot, 0, BIRTH.length - 1);
    b.x = x;
    b.y = y;
    b.vx = rnd(-0.012, 0.012);
    b.vy = rnd(-0.012, 0.012);
    b.scale = BIRTH_SCALES[i];
    b.tgtScale = BIRTH_SCALES[i];
    b.spin = rnd(0, 6.28);
    b.dir = Math.random() < 0.5 ? 1 : -1;
    b.planets = SolarField.params.planetCount;
    b.hex = SolarField.params.color === 'random' ? randomStarHex() : SolarField.params.color;
    return b;
  }

  /** 星系个数变了就补齐 / 裁掉 */
  static syncCount(): void {
    const want: number = SolarField.params.systemCount;
    while (SolarField.bodies.length > want) {
      SolarField.bodies.pop();
    }
    while (SolarField.bodies.length < want) {
      const i: number = SolarField.bodies.length;
      const at: number[] = BIRTH[i % BIRTH.length];
      const b: SolarBody = SolarField.makeBody(i, at[0], at[1]);
      b.grow = 0;
      SolarField.bodies.push(b);
    }
  }

  /** 重置整片天（设置页那颗按钮） */
  static reset(): void {
    SolarField.bodies = [];
    SolarField.dust = [];
    SolarField.flashes = [];
    SolarField.comets = [];
    SolarField.clock = 0;
    SolarField.syncCount();
    SolarField.nextCrashAt = rnd(CRASH_MIN_MS, CRASH_MIN_MS + CRASH_SPAN_MS);
    SolarField.nextCometAt = rnd(2000, 6000);
    SolarField.save();
  }

  /** 手动来一次碰撞（设置页的预览按钮） */
  static chargeCrash(): void {
    const free: SolarBody[] = [];
    for (let i = 0; i < SolarField.bodies.length; i++) {
      const b: SolarBody = SolarField.bodies[i];
      if (!b.swallowing() && b.st < 2) {
        free.push(b);
      }
    }
    if (free.length < 2) {
      return;
    }
    const a: SolarBody = free[Math.floor(Math.random() * free.length)];
    let tgt: SolarBody | null = null;
    for (let i = 0; i < free.length; i++) {
      if (free[i] !== a) {
        tgt = free[i];
        break;
      }
    }
    if (tgt === null) {
      return;
    }
    const dx: number = tgt.x - a.x;
    const dy: number = tgt.y - a.y;
    const d: number = Math.max(0.01, Math.sqrt(dx * dx + dy * dy));
    a.hunt = true;
    a.vx = dx / d * (d / 1.5);
    a.vy = dy / d * (d / 1.5);
  }

  /** 半径（归一化）：核心直径的一半，再乘新生长度 */
  static radius(b: SolarBody): number {
    return 0.15 * b.scale * (0.35 + 0.65 * b.grow);
  }

  /** 第 i 条轨道的半径（归一化） */
  static orbitR(b: SolarBody, i: number): number {
    return (0.21 + i * 0.12) * b.scale * (0.35 + 0.65 * b.grow);
  }

  /**
   * 第 i 颗行星的公转角速度系数 —— **内圈快、外圈慢**（开普勒：ω ∝ r^-1.5）。
   * 归一化到最内圈 = 1，渲染端再乘 params.speed。
   */
  static kepler(b: SolarBody, i: number): number {
    const inner: number = Math.max(0.02, SolarField.orbitR(b, 0));
    const r: number = Math.max(0.02, SolarField.orbitR(b, i));
    return Math.pow(inner / r, 1.5);
  }

  // ══════════════════════ 演化一步 ══════════════════════

  private static step(dt: number): void {
    const t: number = dt / 1000;
    const p: SolarParams = SolarField.params;
    const bodies: SolarBody[] = SolarField.bodies;

    // ── 万有引力：慢的互斥、快的穿过（穿过才有弹弓） ──
    for (let i = 0; i < bodies.length; i++) {
      for (let j = i + 1; j < bodies.length; j++) {
        const a: SolarBody = bodies[i];
        const b: SolarBody = bodies[j];
        const dx: number = b.x - a.x;
        const dy: number = b.y - a.y;
        const d2: number = dx * dx + dy * dy + GRAVITY_SOFT * GRAVITY_SOFT;
        const d: number = Math.sqrt(d2);
        if (p.gravity) {
          const f: number = GRAVITY_G * t / d2;
          a.vx += dx * f * b.mass;
          a.vy += dy * f * b.mass;
          b.vx -= dx * f * a.mass;
          b.vy -= dy * f * a.mass;
          const rel: number = Math.abs(a.vx - b.vx) + Math.abs(a.vy - b.vy);
          const min: number = (SolarField.radius(a) + SolarField.radius(b)) * 2.0;
          if (d < min && rel < SLOW_SWAP && !a.hunt && !b.hunt && !a.swallowing() && !b.swallowing()) {
            const push: number = (min - d) * 3.4 * t;
            a.vx -= dx / d * push;
            a.vy -= dy / d * push;
            b.vx += dx / d * push;
            b.vy += dy / d * push;
          }
        }
        if (d < (SolarField.radius(a) + SolarField.radius(b)) * 1.4) {
          SolarField.meet(a, b, d, dx, dy);
        }
      }
    }

    // ── 每颗：积分、软墙、软边界、阶段 ──
    for (let i = 0; i < bodies.length; i++) {
      const b: SolarBody = bodies[i];
      b.scale = approach(b.scale, b.tgtScale, dt, 420);
      b.grow = clamp(b.grow + dt / GROW_MS, 0, 1);
      if (b.big !== null) {
        SolarField.fallInto(b, dt);
        continue;
      }
      if (b.hunt) {
        SolarField.steerHunter(b, t);
      }
      b.x += b.vx * t;
      b.y += b.vy * t;
      const drag: number = Math.max(0, 1 - DRAG * t);
      b.vx *= drag;
      b.vy *= drag;
      SolarField.softWall(b, t);
      b.spin += t * b.dir * p.speed * 0.9;
      SolarField.phase(b, dt);
    }
    for (let i = bodies.length - 1; i >= 0; i--) {
      if (bodies[i].dead) {
        bodies.splice(i, 1);
      }
    }

    SolarField.stepDust(dt, t);
    SolarField.stepEvents(t);
    for (let i = SolarField.flashes.length - 1; i >= 0; i--) {
      SolarField.flashes[i].t += dt;
      if (SolarField.flashes[i].t > 1400) {
        SolarField.flashes.splice(i, 1);
      }
    }
  }

  /** 被吞的那颗：绕着对方螺旋下落，一边掉一边被撕碎 */
  private static fallInto(b: SolarBody, dt: number): void {
    const o: SolarBody = b.big as SolarBody;
    b.swT += dt;
    const k: number = clamp(b.swT / SWALLOW_MS, 0, 1);
    const e: number = k < 0.5 ? 2 * k * k : 1 - Math.pow(-2 * k + 2, 2) / 2;
    const cx: number = o.x + (b.x - o.x) * (1 - e);
    const cy: number = o.y + (b.y - o.y) * (1 - e);
    const rr: number = b.swR0 * (1 - Math.pow(1 - k, 3));
    const ang: number = b.swA0 + k * 7.5 * b.swDir;
    b.x = cx + Math.cos(ang) * rr;
    b.y = cy + Math.sin(ang) * rr;
    b.vx = 0;
    b.vy = 0;
    b.tgtScale = b.swS0 * (1 - e);
    o.st = 1;
    o.stT = 0;
    if (k >= 1) {
      b.dead = true;
      b.big = null;
      o.tgtScale = Math.min(0.36, o.tgtScale * 1.2);
      o.planets = clamp(o.planets + 1, 1, 5);
      o.mass += 0.6;
      o.hunt = false;
    }
  }

  /** 正文软墙 + 屏幕软边界：都只推不吸，绝不把星系拽回"初始位置" */
  private static softWall(b: SolarBody, t: number): void {
    if (b.x > KEEP_X0 && b.x < KEEP_X1 && b.y > KEEP_Y0 && b.y < KEEP_Y1) {
      const l: number = b.x - KEEP_X0;
      const r: number = KEEP_X1 - b.x;
      const u: number = b.y - KEEP_Y0;
      const dn: number = KEEP_Y1 - b.y;
      const m: number = Math.min(l, r, u, dn);
      if (m === l) {
        b.vx -= KEEP_PUSH * t;
      } else if (m === r) {
        b.vx += KEEP_PUSH * t;
      } else if (m === u) {
        b.vy -= KEEP_PUSH * t;
      } else {
        b.vy += KEEP_PUSH * t;
      }
    }
    if (b.x < -EDGE) {
      b.vx += EDGE_PULL * t;
    } else if (b.x > 1 + EDGE) {
      b.vx -= EDGE_PULL * t;
    }
    if (b.y < -EDGE) {
      b.vy += EDGE_PULL * t;
    } else if (b.y > 1 + EDGE) {
      b.vy -= EDGE_PULL * t;
    }
  }

  private static steerHunter(b: SolarBody, t: number): void {
    let tgt: SolarBody | null = null;
    let best: number = 1e9;
    const bodies: SolarBody[] = SolarField.bodies;
    for (let i = 0; i < bodies.length; i++) {
      const o: SolarBody = bodies[i];
      if (o === b || o.swallowing() || o.st >= 3) {
        continue;
      }
      const dd: number = (o.x - b.x) * (o.x - b.x) + (o.y - b.y) * (o.y - b.y);
      if (dd < best) {
        best = dd;
        tgt = o;
      }
    }
    if (tgt === null) {
      b.hunt = false;
      return;
    }
    const d: number = Math.max(0.01, Math.sqrt(best));
    const wantX: number = (tgt.x - b.x) / d * HUNT_SPEED;
    const wantY: number = (tgt.y - b.y) / d * HUNT_SPEED;
    const k: number = clamp(t / 0.45, 0, 1);
    b.vx += (wantX - b.vx) * k;
    b.vy += (wantY - b.vy) * k;
  }

  /** 两个星系照面：黑洞遇黑洞 → 合并；被点去撞人的 → 开吞；只是路过 → 可能抢一颗行星 */
  private static meet(a: SolarBody, b: SolarBody, d: number, dx: number, dy: number): void {
    if (!SolarField.params.gravity) {
      return;
    }
    if (a.st === 2 && b.st === 2) {
      SolarField.mergeHoles(a, b, dx, dy);
      return;
    }
    if (a.hunt || b.hunt) {
      SolarField.startSwallow(a, b, d, dx, dy);
      return;
    }
    if (a.swallowing() || b.swallowing() || a.st !== 0 || b.st !== 0) {
      return;
    }
    SolarField.stealPlanet(a, b);
  }

  private static startSwallow(a: SolarBody, b: SolarBody, d: number, dx: number, dy: number): void {
    const big: SolarBody = a.mass >= b.mass ? a : b;
    const small: SolarBody = big === a ? b : a;
    if (big.st >= 3 || small.st === 2) {
      return;
    }
    big.mass += small.mass * 0.8;
    small.big = big;
    small.swT = 0;
    small.swR0 = d;
    small.swA0 = Math.atan2(small.y - big.y, small.x - big.x);
    small.swS0 = small.scale;
    small.swDir = small.x > big.x ? 1 : -1;
    big.st = 1;
    big.stT = 0;
    big.hunt = false;
  }

  /** 路过时抢一颗行星：被抢的那颗少一颗，抢的那颗多一颗，中间画一段转移轨迹 */
  private static stealPlanet(a: SolarBody, b: SolarBody): void {
    const rich: SolarBody = a.planets >= b.planets ? a : b;
    const poor: SolarBody = rich === a ? b : a;
    if (rich.planets >= 5 || poor.planets <= 1 || SolarField.dust.length >= DUST_MAX) {
      return;
    }
    if (Math.random() > 0.25) {
      return;
    }
    poor.planets -= 1;
    rich.planets += 1;
    const d: SolarDust = new SolarDust();
    d.kind = 2;
    d.x = poor.x;
    d.y = poor.y;
    d.vx = (rich.x - poor.x) * 0.6;
    d.vy = (rich.y - poor.y) * 0.6;
    d.age = 0;
    d.life = 1600;
    d.glow = 1;
    d.size = 0.008 * rich.scale * 3;
    d.hex = rich.hex;
    d.target = SolarField.bodies.indexOf(rich);
    SolarField.dust.push(d);
  }

  /** 两个黑洞合并：攒到极限就一次大爆炸 */
  private static mergeHoles(a: SolarBody, b: SolarBody, dx: number, dy: number): void {
    const big: SolarBody = a.mass >= b.mass ? a : b;
    const small: SolarBody = big === a ? b : a;
    big.mass += small.mass;
    big.tgtScale = Math.min(0.42, big.tgtScale * 1.25);
    small.dead = true;
    const d: number = Math.sqrt(dx * dx + dy * dy);
    SolarField.boom(big, 1 + d * 2);
    if (big.mass > 3.4) {
      // 合并到极限：整个塌回去，炸完重生为更大的一颗
      big.mass = 1.2;
      big.planets = clamp(big.planets + 1, 1, 5);
    }
    big.st = 3;
    big.stT = 0;
  }

  /** 阶段推进：吸积 → 长期停在黑洞（等合并或到点自爆）→ 消散 */
  private static phase(b: SolarBody, dt: number): void {
    if (b.st === 1) {
      b.ring = approach(b.ring, 1, dt, 420);
      if (!SolarField.anyoneEating(b)) {
        b.st = 2;
        b.stT = 0;
      }
    } else if (b.st === 2) {
      b.stT += dt;
      b.ring = approach(b.ring, 1, dt, 300);
      b.dark = approach(b.dark, 1, dt, 620);
      if (b.stT > HOLE_MS) {
        SolarField.boom(b, 1);
        b.tgtScale = rnd(0.16, 0.26);
        b.mass = 1;
        b.grow = 0;
        b.dark = 0.85;
        b.st = 3;
        b.stT = 0;
      }
    } else if (b.st === 3) {
      b.stT += dt;
      b.dark = approach(b.dark, 0, dt, 620);
      b.ring = approach(b.ring, 0, dt, 900);
      if (b.stT > FADE_MS) {
        b.st = 0;
        b.stT = 0;
      }
    }
  }

  /** 爆炸：冲击环 + 一片星尘（星尘之后会凝成行星） */
  private static boom(b: SolarBody, power: number): void {
    const f: SolarFlash = new SolarFlash();
    f.x = b.x;
    f.y = b.y;
    f.t = 0;
    f.power = clamp(power, 1, 2.4);
    SolarField.flashes.push(f);
    const n: number = Math.round(8 * f.power);
    for (let i = 0; i < n && SolarField.dust.length < DUST_MAX; i++) {
      const a: number = Math.random() * 6.2832;
      const sp: number = rnd(0.02, 0.10) * f.power;
      const d: SolarDust = new SolarDust();
      d.kind = 0;
      d.x = b.x;
      d.y = b.y;
      d.vx = Math.cos(a) * sp;
      d.vy = Math.sin(a) * sp;
      d.age = 0;
      d.life = rnd(DUST_CONDENSE_MS * 1.4, DUST_CONDENSE_MS * 2.6);
      d.glow = 1;
      d.size = rnd(0.004, 0.010);
      d.hex = SolarField.params.color === 'random' ? randomStarHex() : b.hex;
      SolarField.dust.push(d);
    }
  }

  private static anyoneEating(big: SolarBody): boolean {
    const bodies: SolarBody[] = SolarField.bodies;
    for (let i = 0; i < bodies.length; i++) {
      if (bodies[i].big === big) {
        return true;
      }
    }
    return false;
  }

  /** 星尘 → 流浪行星 → 撞成恒星；流浪行星路过星系就被捕获 */
  private static stepDust(dt: number, t: number): void {
    const p: SolarParams = SolarField.params;
    const list: SolarDust[] = SolarField.dust;
    for (let i = list.length - 1; i >= 0; i--) {
      const d: SolarDust = list[i];
      d.age += dt;
      // 星尘也会被星系拽着走
      if (p.gravity) {
        for (let k = 0; k < SolarField.bodies.length; k++) {
          const b: SolarBody = SolarField.bodies[k];
          const dx: number = b.x - d.x;
          const dy: number = b.y - d.y;
          const d2: number = dx * dx + dy * dy + 0.004;
          const f: number = 0.0016 * t / d2 * b.mass;
          d.vx += dx * f;
          d.vy += dy * f;
        }
      }
      d.x += d.vx * t;
      d.y += d.vy * t;
      d.vx *= Math.max(0, 1 - 0.25 * t);
      d.vy *= Math.max(0, 1 - 0.25 * t);
      d.glow = clamp(1 - d.age / d.life, 0, 1);

      if (d.kind === 2) {
        // 被抢走的那颗行星：一路飞向目标星系，落定（或超时）就消失
        const to: SolarBody | undefined = SolarField.bodies[d.target];
        if (to === undefined) {
          list.splice(i, 1);
          continue;
        }
        const tx: number = to.x - d.x;
        const ty: number = to.y - d.y;
        const td: number = Math.max(0.005, Math.sqrt(tx * tx + ty * ty));
        const want: number = 0.34;
        d.vx += (tx / td * want - d.vx) * clamp(t * 4, 0, 1);
        d.vy += (ty / td * want - d.vy) * clamp(t * 4, 0, 1);
        if (td < SolarField.radius(to) * 1.2 || d.age > d.life) {
          list.splice(i, 1);
        }
        continue;
      }
      if (d.kind === 0) {
        if (p.evolve && d.age > DUST_CONDENSE_MS && SolarField.countRogues() < ROGUE_MAX) {
          d.kind = 1;
          d.age = 0;
          d.life = ROGUE_IGNITE_MS;
          d.size = 0.010;
          d.glow = 1;
        } else if (d.age > d.life) {
          list.splice(i, 1);
        }
        continue;
      }
      // 流浪行星：被捕获 / 互相撞成恒星 / 老了消散
      const cap: SolarBody | null = SolarField.nearestBody(d.x, d.y, 0.055);
      if (cap !== null && cap.planets < 5) {
        cap.planets += 1;
        list.splice(i, 1);
        continue;
      }
      const mate: SolarDust | null = SolarField.nearestRogue(d, 0.022);
      if (mate !== null && p.evolve) {
        const mx: number = (d.x + mate.x) / 2;
        const my: number = (d.y + mate.y) / 2;
        list.splice(i, 1);
        const at: number = list.indexOf(mate);
        if (at >= 0) {
          list.splice(at, 1);
        }
        SolarField.birthStar(mx, my);
        continue;
      }
      if (d.age > d.life) {
        list.splice(i, 1);
      }
    }
  }

  private static countRogues(): number {
    let n: number = 0;
    for (let i = 0; i < SolarField.dust.length; i++) {
      if (SolarField.dust[i].kind === 1) {
        n++;
      }
    }
    return n;
  }

  private static nearestBody(x: number, y: number, within: number): SolarBody | null {
    let best: SolarBody | null = null;
    let bd: number = within;
    for (let i = 0; i < SolarField.bodies.length; i++) {
      const b: SolarBody = SolarField.bodies[i];
      const d: number = Math.sqrt((b.x - x) * (b.x - x) + (b.y - y) * (b.y - y));
      if (d < bd + SolarField.radius(b)) {
        bd = d;
        best = b;
      }
    }
    return best;
  }

  private static nearestRogue(d: SolarDust, within: number): SolarDust | null {
    let best: SolarDust | null = null;
    let bd: number = within;
    for (let i = 0; i < SolarField.dust.length; i++) {
      const o: SolarDust = SolarField.dust[i];
      if (o === d || o.kind !== 1) {
        continue;
      }
      const dd: number = Math.sqrt((o.x - d.x) * (o.x - d.x) + (o.y - d.y) * (o.y - d.y));
      if (dd < bd) {
        bd = dd;
        best = o;
      }
    }
    return best;
  }

  /** 两颗流浪行星撞上了 → 点亮成一颗新的恒星系 */
  private static birthStar(x: number, y: number): void {
    const f: SolarFlash = new SolarFlash();
    f.x = x;
    f.y = y;
    f.t = 0;
    f.power = 0.7;
    SolarField.flashes.push(f);
    if (SolarField.bodies.length >= SolarField.params.systemCount + 1) {
      return;
    }
    const b: SolarBody = SolarField.makeBody(SolarField.bodies.length, x, y);
    b.grow = 0;
    b.tgtScale = rnd(0.14, 0.22);
    b.scale = 0.03;
    SolarField.bodies.push(b);
  }

  /** 随机事件：碰撞冲刺、彗星 */
  private static stepEvents(t: number): void {
    const p: SolarParams = SolarField.params;
    if (p.gravity && SolarField.clock > SolarField.nextCrashAt && !SolarField.eating()) {
      SolarField.chargeCrash();
      SolarField.nextCrashAt = SolarField.clock + rnd(CRASH_MIN_MS, CRASH_MIN_MS + CRASH_SPAN_MS);
    }
    if (!p.comet) {
      SolarField.comets = [];
      return;
    }
    if (SolarField.clock > SolarField.nextCometAt) {
      const c: SolarComet = new SolarComet();
      const fromLeft: boolean = Math.random() < 0.5;
      c.x = fromLeft ? -0.06 : 1.06;
      c.y = rnd(0.05, 0.95);
      c.vx = (fromLeft ? 1 : -1) * COMET_SPEED * rnd(0.85, 1.25);
      c.vy = rnd(-0.06, 0.06);
      c.life = 0;
      SolarField.comets.push(c);
      SolarField.nextCometAt = SolarField.clock + rnd(COMET_MIN_MS, COMET_MIN_MS + COMET_SPAN_MS);
    }
    for (let i = SolarField.comets.length - 1; i >= 0; i--) {
      const c: SolarComet = SolarField.comets[i];
      c.x += c.vx * t;
      c.y += c.vy * t;
      c.life += t * 1000;
      if (c.x < -0.12 || c.x > 1.12 || c.life > 7000) {
        SolarField.comets.splice(i, 1);
      }
    }
  }

  private static eating(): boolean {
    const bodies: SolarBody[] = SolarField.bodies;
    for (let i = 0; i < bodies.length; i++) {
      if (bodies[i].swallowing()) {
        return true;
      }
    }
    return false;
  }

  // ══════════════════════ 存与取 ══════════════════════

  /**
   * 存：位置、速度、尺寸、行星数、星色都存 —— 这是**连续的天**，
   * 重开应用接着往下演，不回初始位置。正在吞 / 正在塌缩的那几瞬按常态存。
   */
  static save(): void {
    try {
      const rows: string[] = [];
      for (let i = 0; i < SolarField.bodies.length; i++) {
        const b: SolarBody = SolarField.bodies[i];
        if (b.swallowing() || b.st !== 0) {
          continue;
        }
        rows.push([b.x, b.y, b.vx, b.vy, b.scale, b.mass, b.spin, b.dir, b.planets, b.hex].join(','));
      }
      const rogues: string[] = [];
      for (let i = 0; i < SolarField.dust.length; i++) {
        const d: SolarDust = SolarField.dust[i];
        if (d.kind === 1) {
          rogues.push([d.x, d.y, d.vx, d.vy, d.age, d.hex].join(','));
        }
      }
      AppStorage.setOrCreate<string>(SOLAR_STATE_KEY, rows.join(';') + '#' + rogues.join(';'));
    } catch (err) {
      // 存不上只影响下次从哪开始，不影响这一轮显示
    }
  }

  static load(): void {
    let raw: string = '';
    try {
      const v: string | undefined = AppStorage.get<string>(SOLAR_STATE_KEY);
      raw = v === undefined || v === null ? '' : v;
    } catch (err) {
      raw = '';
    }
    SolarField.bodies = [];
    SolarField.dust = [];
    if (raw.length === 0) {
      SolarField.nextCrashAt = rnd(CRASH_MIN_MS, CRASH_MIN_MS + CRASH_SPAN_MS);
      SolarField.nextCometAt = rnd(2000, 6000);
      return;
    }
    const cut: number = raw.indexOf('#');
    const bodyPart: string = cut < 0 ? raw : raw.substring(0, cut);
    const roguePart: string = cut < 0 ? '' : raw.substring(cut + 1);
    const rows: string[] = bodyPart.split(';');
    for (let i = 0; i < rows.length && i < BIRTH.length + 1; i++) {
      const f: string[] = rows[i].split(',');
      if (f.length < 10) {
        continue;
      }
      const b: SolarBody = SolarField.makeBody(i, Number(f[0]), Number(f[1]));
      b.vx = Number(f[2]);
      b.vy = Number(f[3]);
      b.scale = Number(f[4]);
      b.tgtScale = b.scale;
      b.mass = Number(f[5]);
      b.spin = Number(f[6]);
      b.dir = Number(f[7]);
      b.planets = Math.round(Number(f[8]));
      b.hex = f[9];
      if (isNaN(b.x) || isNaN(b.y) || isNaN(b.scale)) {
        continue;
      }
      SolarField.bodies.push(b);
    }
    const rr: string[] = roguePart.length === 0 ? [] : roguePart.split(';');
    for (let i = 0; i < rr.length && i < ROGUE_MAX; i++) {
      const f: string[] = rr[i].split(',');
      if (f.length < 6) {
        continue;
      }
      const d: SolarDust = new SolarDust();
      d.kind = 1;
      d.x = Number(f[0]);
      d.y = Number(f[1]);
      d.vx = Number(f[2]);
      d.vy = Number(f[3]);
      d.age = Number(f[4]);
      d.life = ROGUE_IGNITE_MS;
      d.size = 0.010;
      d.hex = f[5];
      if (isNaN(d.x) || isNaN(d.y)) {
        continue;
      }
      SolarField.dust.push(d);
    }
    SolarField.nextCrashAt = SolarField.clock + rnd(CRASH_MIN_MS, CRASH_MIN_MS + CRASH_SPAN_MS);
    SolarField.nextCometAt = SolarField.clock + rnd(2000, 6000);
  }
}
