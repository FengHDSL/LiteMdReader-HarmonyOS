/**
 * 澄笺 · 文档标签的视觉样式
 * =========================
 *
 * 标签**没有预设配色表**——按标签名做确定性哈希取色相，同一个名字在任何页面
 *（阅读页信息卡 / 书架 / 筛选芯片）都是同一种颜色；不同名字自动错开色相。
 * 浅色底配深字、深色底配浅字，保证任何主题下都能读清。
 */

export class TagStyle {
  /** 标签名 → 色相（0..359）。同名恒定、异名分散（黄金角步进 + 名字哈希微扰）。 */
  static hue(tag: string): number {
    let h: number = 7;
    for (let k = 0; k < tag.length; k++) {
      h = (h * 31 + tag.charCodeAt(k)) % 360;
    }
    // 乘黄金角散开，避免相近哈希挤成一堆同色
    return (h * 137) % 360;
  }

  /** 胶囊底色：浅色主题用高亮低饱和，深色主题用低亮高饱和 */
  static bg(tag: string, dark: boolean): string {
    const hue: number = TagStyle.hue(tag);
    return dark
      ? 'hsl(' + hue + ', 42%, 26%)'
      : 'hsl(' + hue + ', 72%, 92%)';
  }

  /** 胶囊文字色：与底色同色相但明暗拉开 */
  static fg(tag: string, dark: boolean): string {
    const hue: number = TagStyle.hue(tag);
    return dark
      ? 'hsl(' + hue + ', 78%, 82%)'
      : 'hsl(' + hue + ', 62%, 34%)';
  }

  /** 胶囊描边（比底略深一档，视觉上把相邻同色系标签分开） */
  static border(tag: string, dark: boolean): string {
    const hue: number = TagStyle.hue(tag);
    return dark
      ? 'hsl(' + hue + ', 40%, 36%)'
      : 'hsl(' + hue + ', 62%, 80%)';
  }
}
