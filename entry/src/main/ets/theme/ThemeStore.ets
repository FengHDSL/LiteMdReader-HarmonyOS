/**
 * 澄笺 · 主题工具（照搬 xjau 项目的 ThemeUtil）
 * =============================================
 * 主题色：**澄光 / 宣纸 / 砚青 / 竹影 / 霞笺**（与 5 款程序化壁纸同源同名的取色）
 * + 自定义 #RRGGBB。AppStorage key: themeColor（默认 '' = 跟随主题默认色）
 * 持久化走 PersistentStorage（EntryAbility 注册），广播由 DesignTokens.paletteFor 消费。
 *
 * 旧键 red/blue/orange/purple/cheng（朱砂印/砚池青…）保留解析，只是不再出现在选择项里，
 * 免得老用户升级后主题色突然失效。
 */
export class ThemeStore {
  static readonly KEY_AS: string = 'themeColor';

  /** 内置主题色键：5 款澄笺色 + 4 个历史键（仅作兼容解析） */
  static readonly BUILTIN_KEYS: string[] = [
    'cheng', 'xuan', 'yan', 'zhu', 'xia',
    'red', 'blue', 'orange', 'purple'
  ];

  static isHex(t: string): boolean {
    return /^#[0-9a-fA-F]{6}$/.test(t);
  }

  static isBuiltin(t: string): boolean {
    return ThemeStore.BUILTIN_KEYS.indexOf(t) >= 0;
  }

  static current(): string {
    const t: string | undefined = AppStorage.get<string>(ThemeStore.KEY_AS);
    return t === undefined ? '' : t;
  }

  /**
   * 指定主题的强调色（5 款内置色 + 历史键 + 自定义 hex；空串回落默认）。
   * 取色原则：中明度、中饱和 —— 浅色底上够清楚，深色底上不刺眼。
   */
  static colorOf(theme: string): string {
    if (ThemeStore.isHex(theme)) {
      return theme;
    }
    if (theme === 'cheng') {
      return '#3D6B99'; // 澄光：冷调纸白配一抹澄澈蓝
    }
    if (theme === 'xuan') {
      return '#A97C3F'; // 宣纸：暖白纸面上的赭石
    }
    if (theme === 'yan') {
      return '#3F7D8C'; // 砚青：砚台青灰里的冷青
    }
    if (theme === 'zhu') {
      return '#4E8E5F'; // 竹影：淡青竹叶的竹绿
    }
    if (theme === 'xia') {
      return '#C4703F'; // 霞笺：晚霞粉橙的暖橘
    }
    // ── 历史键（兼容，不再出现在选择项）──
    if (theme === 'red') {
      return '#B94848'; // 朱砂印
    }
    if (theme === 'blue') {
      return '#3D6B99'; // 砚池青
    }
    if (theme === 'orange') {
      return '#E0603A'; // 落日橙
    }
    if (theme === 'purple') {
      return '#7C5CE0'; // 紫罗兰
    }
    return ''; // 未设置：跟随五档主题默认色
  }

  /** 当前主题显示名 */
  static label(): string {
    const t: string = ThemeStore.current();
    if (ThemeStore.isHex(t)) {
      return t.toUpperCase();
    }
    if (t === 'cheng') {
      return '澄光';
    }
    if (t === 'xuan') {
      return '宣纸';
    }
    if (t === 'yan') {
      return '砚青';
    }
    if (t === 'zhu') {
      return '竹影';
    }
    if (t === 'xia') {
      return '霞笺';
    }
    if (t === 'red') {
      return '朱砂印';
    }
    if (t === 'blue') {
      return '砚池青';
    }
    if (t === 'orange') {
      return '落日橙';
    }
    if (t === 'purple') {
      return '紫罗兰';
    }
    return '跟随主题';
  }

  /** #RRGGBB → rgba(r,g,b,a)，供渐变用（非法值回落澄金） */
  static rgba(color: string, alpha: number): string {
    let hex: string = color;
    if (!/^#[0-9a-fA-F]{6}$/.test(hex)) {
      hex = '#B07A2E';
    }
    const r: number = parseInt(hex.substring(1, 3), 16);
    const g: number = parseInt(hex.substring(3, 5), 16);
    const b: number = parseInt(hex.substring(5, 7), 16);
    return 'rgba(' + r + ',' + g + ',' + b + ',' + alpha + ')';
  }

  /**
   * 指定背景色上「可读性最优」的文字色（WCAG 相对亮度）。
   * 照搬 xjau ThemeUtil.onColor：亮度 > 0.179 用深色文字，否则浅色。
   */
  static onColor(bg: string): string {
    let hex: string = bg;
    if (!/^#[0-9a-fA-F]{6}$/.test(hex)) {
      hex = '#B07A2E';
    }
    const r: number = parseInt(hex.substring(1, 3), 16);
    const g: number = parseInt(hex.substring(3, 5), 16);
    const b: number = parseInt(hex.substring(5, 7), 16);
    const toLin = (c: number): number => {
      const s: number = c / 255;
      return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
    };
    const lum: number = 0.2126 * toLin(r) + 0.7152 * toLin(g) + 0.0722 * toLin(b);
    return lum > 0.179 ? '#101413' : '#FFFFFF';
  }

  /** 切换主题（写 AppStorage；持久化由 PersistentStorage 键完成） */
  static apply(theme: string): void {
    AppStorage.setOrCreate(ThemeStore.KEY_AS, theme);
  }
}
