/**
 * LiteMdReader · 设计令牌（Design Tokens）
 * ========================================
 *
 * 本文件是阅读器全部卡片元素的「唯一尺寸与色彩事实来源」。
 * 任何卡片、芯片、弹窗的圆角 / 间距 / 字号都必须取自此处，
 * 不允许在组件里写魔法数字——否则沉浸光感的承载层与外壳圆角会不同步，
 * 卡片四角会露出直角或内嵌边框（见 docs 中 Toggle 承载方案第 4 节的层级规则）。
 *
 * 卡片元素清单（本轮已实现 = ✅，后续迭代 = ⏳）
 * -------------------------------------------------
 * 基础层
 *   ✅ ImmersiveCardLayer  材质承载层（隐形 Toggle 画布，五条必需属性）
 *   ✅ ImmersiveCard       通用光感卡片外壳
 *   ✅ ImmersiveIconButton 圆形图标按钮（Toggle 承载 + SymbolGlyph）
 *   ✅ ImmersiveChip       小尺寸芯片（关闭材质自带投影）
 *   ✅ ImmersiveSheetPanel 半模态面板光感外壳
 * 阅读器业务层
 *   ✅ ReaderTopBar        顶部导航卡片（打开文件 / 文档名 / 目录 / 设置）
 *   ✅ DocMetaCard         文档信息卡片（字数 / 标题 / 代码块 / 表格 / 脚注 / 诊断）
 *   ✅ ReaderProgressBar   底部阅读进度胶囊（进度条 + 置顶）
 *   ✅ TocSheet            目录面板（多级标题 + 当前位置高亮 + 跳转）
 *   ✅ SettingsSheet       阅读设置面板（字号 / 行高 / 段距 / 版心 / 字体 / 主题 / 亮度）
 *   ✅ ResumeDocCard       继续阅读卡片（最近读过且有进度的文档）
 *   ✅ EmptyStateCard      空状态卡片
 *   ✅ ImageCard           独立成段的图片卡（网络 / Base64 / 沙箱文件）
 * 正文内嵌层
 *   ✅ HeadingBlock        标题块（主题色刻度线）
 *   ✅ InlineText          行内富文本（Span 段落）
 *   ✅ CodeBlockCard       代码块卡片（语言徽标 + 复制）
 *   ✅ QuoteCard           引用卡片（主题色竖线）
 *   ✅ CalloutCard         提示卡片（NOTE / TIP / IMPORTANT / WARNING / CAUTION）
 *   ✅ TableCard           表格卡片（横向滚动 + 列对齐）
 *   ✅ ListItemBlock       列表项（圆点 / 序号 / 任务勾选 + 缩进层级）
 *   ✅ FootnoteCard        脚注卡片（标号 + 缩进）
 *   ✅ DividerBlock        分割线块
 */

/** 阅读主题调色板。沉浸光感生效时，材质渲染在 surface 之上，surface 只作为降级底色。 */
import { curves } from '@kit.ArkUI';
import { ThemeStore } from './ThemeStore';

/**
 * 弹簧动画曲线：文件夹展开、标签切换这类「要 Q 弹」的过渡统一用它。
 * FastOutSlowIn 是「到位就停」，弹簧会过冲一点再回落，观感灵动。
 */
export const FOLDER_SPRING: ICurve = curves.springMotion(0.25, 0.9);

export interface ReaderPalette {
  /** 页面渐变起点 */
  pageTop: string;
  /** 页面渐变终点 */
  pageBottom: string;
  /** 环境光斑 · 冷色 */
  glowCool: string;
  /** 环境光斑 · 暖色 */
  glowWarm: string;
  /** 正文主色 */
  textPrimary: string;
  /** 次级文字 */
  textSecondary: string;
  /** 三级文字（徽标、脚注） */
  textTertiary: string;
  /** 主题强调色 */
  accent: string;
  /** 主题色淡底 */
  accentSoft: string;
  /** 卡片降级底色（必须带透明度，否则毛玻璃会被完全盖住） */
  surface: string;
  /** 卡片描边（发丝线） */
  surfaceBorder: string;
  /** 行内代码底色 / 文字色 */
  inlineCodeBg: string;
  inlineCodeText: string;
  /** 代码块卡片底色 */
  codeBlockBg: string;
  /** 引用卡片底色 / 竖线 */
  quoteBg: string;
  quoteBar: string;
  /** 表格表头与斑马纹 */
  tableHeadBg: string;
  tableStripeBg: string;
  /** 高亮标记底色 */
  markBg: string;
  /** 搜索命中底色。刻意用琥珀色，与荧光笔的黄色拉开区别 */
  searchHitBg: string;
  /** 代码高亮：关键字 / 字符串 / 注释 / 数字 / 函数名 / 标签 / 属性 */
  codeKeyword: string;
  codeString: string;
  codeComment: string;
  codeNumber: string;
  codeFunc: string;
  codeTag: string;
  codeAttr: string;
  /** 分割线 */
  divider: string;
  /** 材质不可用时兜底投影色 */
  shadow: string;
}

/**
 * 浅色主题「素纸」。
 * 底色刻意带一点冷调，配合冷 / 暖两团环境光，让沉浸光感有可折射的内容，
 * 否则纯白底上材质会显得像一块灰色补丁。
 */
export const LIGHT_PALETTE: ReaderPalette = {
  pageTop: '#F3F6FBFF',
  pageBottom: '#EDF0F7FF',
  glowCool: '#3D7BA8FF',
  glowWarm: '#3DFFC08A',
  textPrimary: '#FF1B1F27',
  textSecondary: '#FF525A68',
  textTertiary: '#FF8B93A1',
  accent: '#FF2F63E8',
  accentSoft: '#1F2F63E8',
  surface: '#B3FFFFFF',
  surfaceBorder: '#24FFFFFF',
  inlineCodeBg: '#142F63E8',
  inlineCodeText: '#FF2350C4',
  codeBlockBg: '#8CFFFFFF',
  quoteBg: '#472F63E8',
  quoteBar: '#FF2F63E8',
  tableHeadBg: '#1F1B1F27',
  tableStripeBg: '#0D1B1F27',
  markBg: '#FFE8F0A0',
  searchHitBg: '#80FF9A3D',
  codeKeyword: '#FFCF222E',
  codeString: '#FF0A3069',
  codeComment: '#FF6E7781',
  codeNumber: '#FF0550AE',
  codeFunc: '#FF8250DF',
  codeTag: '#FF116329',
  codeAttr: '#FF0550AE',
  divider: '#1F1B1F27',
  shadow: '#26000000'
};

/**
 * 「羊皮纸」主题。移植自参考项目「自定义阅读背景色」的能力：
 * 暖黄纸色 + 棕色系文字，配一团暖光斑；整体色温偏暖，适合长时间阅读。
 */
export const SEPIA_PALETTE: ReaderPalette = {
  pageTop: '#F6EEDDFF',
  pageBottom: '#F0E5CEFF',
  glowCool: '#3DC08A5C',
  glowWarm: '#4DE0A45CFF',
  textPrimary: '#FF43342A',
  textSecondary: '#FF6E5A48',
  textTertiary: '#FF9C8A72',
  accent: '#FFA8683A',
  accentSoft: '#26A8683A',
  surface: '#B3FFFDF4FF',
  surfaceBorder: '#2AE0C89AFF',
  inlineCodeBg: '#2EA8683A',
  inlineCodeText: '#FF7A4A22',
  codeBlockBg: '#8CFFFCEDFF',
  quoteBg: '#40A8683A',
  quoteBar: '#FFA8683A',
  tableHeadBg: '#26A8683A',
  tableStripeBg: '#12A8683A',
  markBg: '#FFE8D89A',
  searchHitBg: '#80FF9A3D',
  codeKeyword: '#FF9A3B1F',
  codeString: '#FF6B4E1B',
  codeComment: '#FFA08F76',
  codeNumber: '#FF7A5A18',
  codeFunc: '#FF8A4A6B',
  codeTag: '#FF4E7A32',
  codeAttr: '#FF7A5A18',
  divider: '#2E6E5A48',
  shadow: '#26433326'
};

/**
 * 「护眼绿」主题。低饱和豆绿底色 + 深绿文字，历史上是电子墨水屏风格的延伸；
 * 光斑用两团冷绿，让材质有东西可采样。
 */
export const GREEN_PALETTE: ReaderPalette = {
  pageTop: '#E8F0E2FF',
  pageBottom: '#DDEBDAFF',
  glowCool: '#3D5A8A66FF',
  glowWarm: '#3DA8C09AFF',
  textPrimary: '#FF24382C',
  textSecondary: '#FF4E6455',
  textTertiary: '#FF7E9284',
  accent: '#FF2E7D4F',
  accentSoft: '#1F2E7D4F',
  surface: '#B3FBFFF5FF',
  surfaceBorder: '#26B2D0A8FF',
  inlineCodeBg: '#1F2E7D4F',
  inlineCodeText: '#FF1C5F3A',
  codeBlockBg: '#8CF2FBEFFF',
  quoteBg: '#402E7D4F',
  quoteBar: '#FF2E7D4F',
  tableHeadBg: '#2624382C',
  tableStripeBg: '#0D24382C',
  markBg: '#FFD8F0C2',
  searchHitBg: '#80FF9A3D',
  codeKeyword: '#FFB03A2E',
  codeString: '#FF0A5E42',
  codeComment: '#FF7E9284',
  codeNumber: '#FF1C5F8A',
  codeFunc: '#FF7A3A8A',
  codeTag: '#FF2E7D4F',
  codeAttr: '#FF1C5F8A',
  divider: '#1F24382C',
  shadow: '#261A3226'
};

/** 深色主题「夜墨」 */
export const DARK_PALETTE: ReaderPalette = {
  pageTop: '#15181EFF',
  pageBottom: '#0B0D11FF',
  glowCool: '#3D2F63E8',
  glowWarm: '#3D8A5416',
  textPrimary: '#FFECEFF4',
  textSecondary: '#FFA6AEBB',
  textTertiary: '#FF767E8C',
  accent: '#FF8AA8FF',
  accentSoft: '#2E8AA8FF',
  surface: '#B3161A21',
  surfaceBorder: '#1FFFFFFF',
  inlineCodeBg: '#2E8AA8FF',
  inlineCodeText: '#FFB9CBFF',
  codeBlockBg: '#8C10131A',
  quoteBg: '#408AA8FF',
  quoteBar: '#FF8AA8FF',
  tableHeadBg: '#1FFFFFFF',
  tableStripeBg: '#0FFFFFFF',
  markBg: '#59E8C86A',
  searchHitBg: '#80C9752A',
  codeKeyword: '#FFFF7B72',
  codeString: '#FFA5D6FF',
  codeComment: '#FF8B949E',
  codeNumber: '#FF79C0FF',
  codeFunc: '#FFD2A8FF',
  codeTag: '#FF7EE787',
  codeAttr: '#FF79C0FF',
  divider: '#1FFFFFFF',
  shadow: '#4D000000'
};

/** 按明暗取调色板。 */
export function paletteOf(dark: boolean): ReaderPalette {
  return dark ? DARK_PALETTE : LIGHT_PALETTE;
}

// ══════════════════════ 全局主题色机制（参考 miha_hm：AppStorage 广播刷新） ══════════════════════
//
// accentColor       自定义主题色（'#RRGGBB' 或 '#AARRGGBB'；空串 = 跟随五档主题）
// accentTintCards   卡片沾色：surface/quoteBg/codeBlockBg 向主题色轻微染色
// 由 paletteFor 在每次取色时套用，所有页面自动生效（等价于 miha_hm 的 HwColor + AppStorage 广播）。

/** 归一化颜色：补全 alpha 前缀，输出 '#AARRGGBB'。非法返回空串。 */
export function normalizeHex8(raw: string): string {
  let s: string = raw.trim();
  if (s.length === 0) {
    return '';
  }
  if (s.charAt(0) !== '#') {
    s = '#' + s;
  }
  if (s.length === 7) {
    return '#FF' + s.substring(1);
  }
  if (s.length === 9) {
    return s;
  }
  return '';
}

/** 读 8 位 hex 的 rgb 分量为数值。 */
function hexRgb(hex: string): number[] {
  const r: number = parseInt(hex.substring(3, 5), 16);
  const g: number = parseInt(hex.substring(5, 7), 16);
  const b: number = parseInt(hex.substring(7, 9), 16);
  return [isNaN(r) ? 0 : r, isNaN(g) ? 0 : g, isNaN(b) ? 0 : b];
}

function toHex2(v: number): string {
  const v2: number = Math.round(v < 0 ? 0 : v > 255 ? 255 : v);
  const s: string = v2.toString(16).toUpperCase();
  return s.length === 1 ? '0' + s : s;
}

/** 把主题色的 alpha 换成指定档（磨砂层用），返回 '#AARRGGBB'。 */
export function withAlpha(hex: string, alphaHex: string): string {
  const n: string = normalizeHex8(hex);
  if (n.length === 0) {
    return hex;
  }
  // n 形如 #AARRGGBB，substring(3) 取到 RRGGBB。
  // **前面的 '#' 不能省**：ArkUI 只认带 # 前缀的颜色串，少了它整串是非法色值 ——
  // 卡片沾色层、按压流光都因此完全失效（有的机型还会把非法色当黑处理，整卡发黑）。
  return '#' + alphaHex + n.substring(3);
}

/** rgb 混合（保留 base 的 alpha）。 */
function blendRgb(base: string, over: string, t: number): string {
  const b: string = normalizeHex8(base);
  const o: string = normalizeHex8(over);
  if (b.length === 0 || o.length === 0) {
    return base;
  }
  const br: number[] = hexRgb(b);
  const or: number[] = hexRgb(o);
  return b.substring(0, 3) + toHex2(br[0] + (or[0] - br[0]) * t)
    + toHex2(br[1] + (or[1] - br[1]) * t) + toHex2(br[2] + (or[2] - br[2]) * t);
}

function copyPalette(p: ReaderPalette): ReaderPalette {
  const q: ReaderPalette = {
    pageTop: p.pageTop, pageBottom: p.pageBottom, glowCool: p.glowCool, glowWarm: p.glowWarm,
    textPrimary: p.textPrimary, textSecondary: p.textSecondary, textTertiary: p.textTertiary,
    accent: p.accent, accentSoft: p.accentSoft, surface: p.surface, surfaceBorder: p.surfaceBorder,
    inlineCodeBg: p.inlineCodeBg, inlineCodeText: p.inlineCodeText, codeBlockBg: p.codeBlockBg,
    quoteBg: p.quoteBg, quoteBar: p.quoteBar, tableHeadBg: p.tableHeadBg, tableStripeBg: p.tableStripeBg,
    markBg: p.markBg, searchHitBg: p.searchHitBg, codeKeyword: p.codeKeyword, codeString: p.codeString,
    codeComment: p.codeComment, codeNumber: p.codeNumber, codeFunc: p.codeFunc, codeTag: p.codeTag,
    codeAttr: p.codeAttr, divider: p.divider, shadow: p.shadow
  };
  return q;
}

/** 按主题模式取调色板，并套用全局主题色 / 卡片沾色 / 页面染色（照搬 xjau AppearanceStore 语义）。 */
export function paletteFor(mode: number, systemDark: boolean): ReaderPalette {
  const p: ReaderPalette = copyPalette(basePalette(mode, systemDark));
  const themeKey: string | undefined = AppStorage.get<string>('themeColor');
  const key: string = themeKey !== undefined && themeKey !== null ? themeKey : '';
  const accent: string = ThemeStore.colorOf(key);
  if (accent.length > 0) {
    p.accent = accent;
    p.accentSoft = withAlpha(accent, '2E');
    p.quoteBar = accent;
    p.inlineCodeText = blendRgb(p.textPrimary, accent, 0.55);
  }
  // 卡片沾色：底色混入 10% 主题色（xjau CARD_TINT_RATIO）
  if (AppStorage.get<boolean>('cardTint') === true && accent.length > 0) {
    p.surface = blendRgb(p.surface, accent, 0.10);
    p.quoteBg = blendRgb(p.quoteBg, accent, 0.12);
    p.codeBlockBg = blendRgb(p.codeBlockBg, accent, 0.10);
    p.tableStripeBg = blendRgb(p.tableStripeBg, accent, 0.06);
    p.accentSoft = withAlpha(accent, '2E');
  }
  // 页面背景跟随主题色：内置主题始终允许；自定义 hex 需「高权限自定义主题色」
  const bgTintOff: boolean = AppStorage.get<boolean>('pageBgTint') === false;
  const allowed: boolean = ThemeStore.isBuiltin(key)
    || (ThemeStore.isHex(key) && AppStorage.get<boolean>('customAccentFull') === true);
  if (!bgTintOff && allowed && accent.length > 0) {
    p.pageTop = blendRgb(p.pageTop, accent, 0.10);
    p.pageBottom = blendRgb(p.pageBottom, accent, 0.10);
  }
  // 灰体文本显示增强（移植自 xjau 的灰字覆盖）：把「次级 / 三级」灰字统一换掉，
  // 壁纸很花时能显著提升可读性。auto = 不改（跟随主题）。
  const themeDark: boolean = mode === ReaderThemeMode.Dark
    || (mode === ReaderThemeMode.System && systemDark);
  const gray: string = grayTextOverride(themeDark);
  if (gray.length > 0) {
    p.textSecondary = gray;
    p.textTertiary = gray;
  }
  return p;
}

/**
 * 灰体文本覆盖色（空串 = 不覆盖，跟随主题）。
 *
 * **深浅两套独立配置**（用户要求）：深色模式用什么颜色、浅色模式用什么颜色分别设，
 * 各自默认「自动」。取值：
 *   · 现代键（按当前主题取其中一套）
 *       grayTextModeLight / grayTextModeDark：auto | gray | black | white | custom
 *       grayTextColorLight / grayTextColorDark：custom 时的自定义 #RRGGBB
 *   · 旧键（兼容老安装）：grayTextMode / grayTextColor —— 两个现代键都还是 auto 时生效
 *
 * **「黑 / 白」按字面值**（用户要求：选白就是白、选黑就是黑——之前按主题自适应翻转，
 * 结果浅色主题选白出来的是深色）。现在由用户分别给深浅两套指定，语义不再含糊：
 *   · 黑 = 近黑 #1A1D21（浅色主题下对比增强）
 *   · 白 = 纯白 #FFFFFF（深色壁纸 + 浅色主题的组合用）
 *   · 灰 = #9AA0A6（两种主题下都够用）
 *
 * 注意：纯函数内读 AppStorage **不登记依赖**，所以改设置后由 SettingsAppearance 里的
 * appearanceTick 触发整树重算（见各页面 palette()）。
 */
export function grayTextOverride(themeDark: boolean): string {
  const modernKey: string = themeDark ? 'grayTextModeDark' : 'grayTextModeLight';
  const modernColorKey: string = themeDark ? 'grayTextColorDark' : 'grayTextColorLight';
  const modernRaw: string | undefined = AppStorage.get<string>(modernKey);
  let mode: string = modernRaw === undefined || modernRaw === null ? '' : modernRaw;
  let colorKey: string = modernColorKey;
  // 现代键没设过（老安装）→ 回落旧键；旧键默认 'auto'，等价于"跟随主题"
  if (mode.length === 0) {
    const legacyRaw: string | undefined = AppStorage.get<string>('grayTextMode');
    mode = legacyRaw === undefined || legacyRaw === null ? 'auto' : legacyRaw;
    colorKey = 'grayTextColor';
  }
  if (mode.length === 0 || mode === 'auto') {
    return '';
  }
  if (mode === 'gray') {
    return '#9AA0A6';
  }
  if (mode === 'black') {
    return '#1A1D21';
  }
  if (mode === 'white') {
    return '#FFFFFF';
  }
  if (mode === 'custom') {
    const c: string | undefined = AppStorage.get<string>(colorKey);
    const hex: string = c === undefined || c === null ? '' : c.trim();
    const norm: string = normalizeHex8(hex);
    return norm.length > 0 ? '#' + norm.substring(3) : '';
  }
  return '';
}

/** 顶栏磨砂底色：surface 降不透明度，透明度随「玻璃通透程度」（0~100）反向变化。 */
export function barFrostColor(surface: string): string {
  const kRaw: number | undefined = AppStorage.get<number>('glassStrength');
  const k: number = kRaw === undefined || isNaN(kRaw) ? 0.7 : Math.max(0, Math.min(100, kRaw)) / 100;
  const a: number = 0.85 - 0.6 * k; // 越通透越透明
  // 主题色可见性：条栏底色向主题色偏移 18%。之前只染 accent 的少量点缀，
  // 顶栏/底栏/按钮完全不变色，用户调主题色等于白调。
  const key: string | undefined = AppStorage.get<string>('themeColor');
  const accent: string = key !== undefined && key !== null ? ThemeStore.colorOf(key) : '';
  let base: string = surface;
  if (accent.length > 0) {
    base = blendRgb(surface, accent, 0.18);
  }
  return withAlpha(base, toHex2(a * 255));
}

function basePalette(mode: number, systemDark: boolean): ReaderPalette {
  if (mode === ReaderThemeMode.Sepia) {
    return SEPIA_PALETTE;
  }
  if (mode === ReaderThemeMode.Green) {
    return GREEN_PALETTE;
  }
  const dark: boolean = mode === ReaderThemeMode.Dark
    || (mode === ReaderThemeMode.System && systemDark);
  return paletteOf(dark);
}

/** 间距刻度（vp） */
export class HwSpace {
  static readonly xxs: number = 2;
  static readonly xs: number = 6;
  static readonly sm: number = 10;
  static readonly md: number = 14;
  static readonly lg: number = 20;
  static readonly xl: number = 28;
  static readonly xxl: number = 40;
}

/**
 * 顶栏 / 底栏胶囊的固定高度。
 * 收起动画要把外层容器高度折叠到「仅系统栏避让」，胶囊高度必须是确定值，
 * 否则 intrinsic 高度到 0 的过渡不动画。改胶囊内容尺寸时同步改这里。
 */
export class HwBar {
  /**
   * 48 → 52：胶囊内高（52 - 2×6 = 40）要**大于**最大按钮直径（36），
   * 否则按钮的材质描边被胶囊内沿切平——用户看到的「圆钮底部被截了一点」。
   */
  static readonly pill: number = 52;
  /** 标签栏高度（多标签时显示在顶栏胶囊下方） */
  static readonly tabs: number = 34;
  /** 收起态底栏胶囊宽度（阅读百分比 + 设置入口）。高度与原胶囊一致，都是 pill */
  static readonly miniBottom: number = 96;
  /** 收起态顶栏胶囊基础宽度（返回 + 搜索 + 左右内边距 + 8 余量），标签序号区另计 */
  static readonly miniTop: number = 116;
}

/** 背景色板的一项 */
export interface NamedColor {
  name: string;
  value: string;
}

/**
 * 阅读背景预设色板（移植自参考项目的「亮/暗主题分别自定义背景色 + 预设 + 恢复默认」）。
 * value 为空串表示「默认」（用主题自带渐变），存进 AppStorage 的
 * readerCustomBgLight / readerCustomBgDark。
 */
export const LIGHT_BG_PRESETS: NamedColor[] = [
  { name: '默认', value: '' },
  { name: '纸白', value: '#FFFEFEFC' },
  { name: '米黄', value: '#FFFAF3E3' },
  { name: '浅杏', value: '#FFF8EDE2' },
  { name: '豆绿', value: '#FFE7F0E4' },
  { name: '雾蓝', value: '#FFE8EFF7' },
  { name: '浅灰', value: '#FFF1F2F4' },
  { name: '樱粉', value: '#FFF9ECEE' }
];

export const DARK_BG_PRESETS: NamedColor[] = [
  { name: '默认', value: '' },
  { name: '纯黑', value: '#FF000000' },
  { name: '碳灰', value: '#FF121417' },
  { name: '暖黑', value: '#FF1A1611' },
  { name: '墨绿', value: '#FF0F1A14' },
  { name: '藏蓝', value: '#FF0E1420' },
  { name: '深棕', value: '#FF181310' },
  { name: '暗紫', value: '#FF151221' }
];

/** 按值取预设名，找不到（自定义值）返回「自定义」。 */
export function bgPresetName(presets: NamedColor[], value: string): string {
  for (let k = 0; k < presets.length; k++) {
    if (presets[k].value === value) {
      return presets[k].name;
    }
  }
  return '自定义';
}

/**
 * 程序化书封配色（参考图一书架形态）。
 * 文档没有封面图，用文档名哈希从固定色板里取一组渐变，保证同一篇文档封面稳定、
 * 不同文档色彩有区分。墨色是同系的深一档，保证标题可读。
 */
export interface CoverStyle {
  top: string;
  bottom: string;
  ink: string;
}

export const COVER_STYLES: CoverStyle[] = [
  { top: '#FFE8EFF7', bottom: '#FFD3E2F5', ink: '#FF2F63E8' },
  { top: '#FFFCEFE0', bottom: '#FFF7DDC4', ink: '#FFB26218' },
  { top: '#FFE7F3EA', bottom: '#FFD2E9D8', ink: '#FF2E7D4F' },
  { top: '#FFF3ECF9', bottom: '#FFE2D6F2', ink: '#FF8A5AF0' },
  { top: '#FFFDF1E0', bottom: '#FFFAE0BE', ink: '#FFC25E0A' },
  { top: '#FFECF0F4', bottom: '#FFDAE0E8', ink: '#FF4A5462' },
  { top: '#FFF9E9EE', bottom: '#FFF3D2DC', ink: '#FFC2446A' },
  { top: '#FFE6F2F2', bottom: '#FFCFE6E5', ink: '#FF1F7A78' }
];

/** 文档名 → 封面配色。简单字符哈希，同名恒定。 */
export function coverStyleOf(name: string): CoverStyle {
  let hash: number = 0;
  for (let k = 0; k < name.length; k++) {
    hash = (hash * 31 + name.charCodeAt(k)) & 0x7FFFFFFF;
  }
  return COVER_STYLES[hash % COVER_STYLES.length];
}

/** 圆角刻度（vp）。承载层圆角必须与外壳圆角取自同一个常量。 */
export class HwRadius {
  /** 胶囊（芯片、按钮） */
  static readonly pill: number = 999;
  /** 卡片 */
  static readonly card: number = 22;
  /** 卡片内部小块（代码块、表格、图片） */
  static readonly inner: number = 14;
  /** 半模态面板 */
  static readonly sheet: number = 30;
  /** 行内代码 */
  static readonly inline: number = 5;
}

/** 排版刻度 */
export class HwType {
  /** 正文最小 / 最大 / 默认字号（fp） */
  static readonly bodyMin: number = 13;
  static readonly bodyMax: number = 22;
  static readonly bodyDefault: number = 16;
  /** 行高倍数 */
  static readonly lineMin: number = 1.4;
  static readonly lineMax: number = 2.2;
  static readonly lineDefault: number = 1.75;
  /** 版心宽度（每行字数） */
  static readonly measureMin: number = 30;
  static readonly measureMax: number = 56;
  static readonly measureDefault: number = 40;
  /** 辅助文字 */
  static readonly caption: number = 11.5;
  static readonly label: number = 13;
  /** 代码相对正文的缩放 */
  static readonly codeScale: number = 0.88;
  /** 脚注相对正文的缩放 */
  static readonly footnoteScale: number = 0.86;
}

/**
 * 标题字号系数（相对正文字号）。
 * 阅读设置里改字号时，标题会按同一比例整体缩放，避免「正文放大、标题不动」的失衡。
 */
const HEADING_RATIO: number[] = [1.75, 1.42, 1.21, 1.09, 1.0, 0.94];

export function headingFontSize(level: number, body: number): number {
  const idx: number = Math.min(Math.max(level, 1), 6) - 1;
  return Math.round(body * HEADING_RATIO[idx] * 10) / 10;
}

/** 标题上下留白（vp），随层级递减。 */
export function headingSpaceTop(level: number): number {
  const map: number[] = [22, 20, 17, 14, 12, 11];
  const idx: number = Math.min(Math.max(level, 1), 6) - 1;
  return map[idx];
}

/** 表格列宽：按最长单元格估算，避免长中文被压成一列两字。 */
export function tableColumnWidth(cells: string[]): number {
  let max: number = 4;
  for (const c of cells) {
    const len: number = c.length;
    if (len > max) {
      max = len;
    }
  }
  const w: number = 42 + max * 13;
  return w > 260 ? 260 : w;
}

/** 代码块按行数估算卡片高度上限，超出即内部滚动。 */
export function codeBlockHeight(lineCount: number, body: number): number {
  const lineH: number = body * HwType.codeScale * 1.6;
  const h: number = lineH * lineCount + 62;
  return h > 460 ? 460 : h;
}

/** 沉浸光感材质档位 → 可读文案，用于诊断行。 */
export function materialLevelLabel(level: number): string {
  if (level === 0) {
    return '高（EXQUISITE）';
  }
  if (level === 1) {
    return '中（GENTLE）';
  }
  if (level === 2) {
    return '低（SMOOTH）';
  }
  return '未知';
}

/**
 * 阅读主题模式。
 * System/Light/Dark 是基础三档；Sepia（羊皮纸）与 Green（护眼绿）是
 * 从参考项目「自定义阅读背景色」移植进来的两档固定纸色，都是浅色系。
 */
export enum ReaderThemeMode {
  System = 0,
  Light = 1,
  Dark = 2,
  Sepia = 3,
  Green = 4
}

export function themeModeLabel(mode: number): string {
  if (mode === ReaderThemeMode.Light) {
    return '浅色';
  }
  if (mode === ReaderThemeMode.Dark) {
    return '深色';
  }
  if (mode === ReaderThemeMode.Sepia) {
    return '羊皮纸';
  }
  if (mode === ReaderThemeMode.Green) {
    return '护眼绿';
  }
  return '跟随系统';
}

/**
 * 取调色板统一走文件上方的 paletteFor(mode, systemDark)——
 * 它套用了全局主题色与卡片沾色，页面不要绕过它直接用 paletteOf。
 * isDark() 仍保留：决定系统栏图标颜色与批注底色取浅/深档。
 */

/**
 * 正文字体。设备自带字体在各机型上不可靠（衬线/等宽不保证存在），
 * 所以只有「默认」，其余键都是**用户导入的自定义字体 familyName**
 * （FontStore 注册时用文件名当 familyName，键即名，直接回传即可）。
 */
export class HwFont {
  static readonly DEFAULT: string = '';

  /** 按设置键取 fontFamily：空串 = 系统默认；非空 = 用户导入的字体 familyName。 */
  static resolve(key: string): string {
    return key;
  }

  static label(key: string): string {
    if (key.length === 0) {
      return '默认';
    }
    return key;
  }
}

/**
 * 荧光笔颜色（批注底色）。
 * 底色必须带透明度——不透明会把正文文字盖住，而这层底色是画在字后面的。
 * 深色主题用更低亮度的一档，否则在暗背景上过曝、文字反而看不清。
 */
export interface AnnotationColor {
  name: string;
  light: string;
  dark: string;
}

export const ANNOTATION_COLORS: AnnotationColor[] = [
  { name: '黄', light: '#66FFE066', dark: '#59C9A83C' },
  { name: '绿', light: '#6600E08A', dark: '#59009E5F' },
  { name: '粉', light: '#66FF9EB5', dark: '#59C2637F' },
  { name: '蓝', light: '#6600B4FF', dark: '#59007FB8' }
];

/** 取某个荧光笔颜色在当前主题下的色值。索引越界时退回首色。 */
export function annotationColor(index: number, dark: boolean): string {
  if (index < 0 || index >= ANNOTATION_COLORS.length) {
    return dark ? ANNOTATION_COLORS[0].dark : ANNOTATION_COLORS[0].light;
  }
  return dark ? ANNOTATION_COLORS[index].dark : ANNOTATION_COLORS[index].light;
}
