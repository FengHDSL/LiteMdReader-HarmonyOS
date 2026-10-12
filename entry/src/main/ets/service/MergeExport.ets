/**
 * 澄笺 · 合并导出（把多篇文档拼成一篇再导出）
 * =============================================
 *
 * **刻意在 Markdown 文本层合并**，而不是把 N 份 HTML 拼起来：
 * 合并结果仍然只是一"篇"普通 Markdown，之后照旧走既有的单文档管线
 * （MdParser → MdToHtml / MdToPlain / PrintService）。于是——
 *  · HTML 里的图表 / 公式渲染库**天然只内联一份**（chartAssets 按块清单去重，
 *    见 MdToHtml.chartAssets）；拼 HTML 则会重复 N 份 <head> 与库脚本；
 *  · 打印、TXT 不需要任何新分支；
 *  · 各文档的锚点、大纲、脚注编号由解析器重新统一编排，不会互相打架。
 *
 * Front Matter：**全部剥掉**。合并后只有最开头那段会被当成元数据，
 * 其余各篇的 `---` 会散在正文里被解析成分隔线（用户看到的就是一堆乱横线）。
 */

/** 一篇待合并的文档（正文已读出）。 */
export interface MergeItem {
  name: string;
  content: string;
}

/** 合并来源（面板列表用：只带名字与是否内置，正文在导出那一刻才读）。 */
export interface MergeSource {
  name: string;
  builtin: boolean;
}

/** 合并样式开关。 */
export interface MergeOptions {
  /** 每篇前加一级标题（文档名） */
  withTitle: boolean;
  /** 篇与篇之间加分隔线 */
  withDivider: boolean;
}

export class MergeExport {
  /**
   * 组装合并后的 Markdown。
   * 顺序 = 传入顺序（面板里用户拖/点出来的那个顺序）。
   */
  static buildMarkdown(items: MergeItem[], opts: MergeOptions): string {
    const parts: string[] = [];
    for (let k = 0; k < items.length; k++) {
      const body: string = MergeExport.stripFrontMatter(items[k].content).trim();
      if (body.length === 0 && !(opts.withTitle && items[k].name.length > 0)) {
        continue;
      }
      let seg: string = '';
      // 分隔线加在"上一篇之后"，所以首篇前不留空横线
      if (opts.withDivider && parts.length > 0) {
        seg += '---\n\n';
      }
      if (opts.withTitle && items[k].name.length > 0) {
        seg += '# ' + items[k].name + '\n\n';
      }
      seg += body;
      parts.push(seg);
    }
    if (parts.length === 0) {
      return '';
    }
    return parts.join('\n\n').trim() + '\n';
  }

  /**
   * 剥掉顶部 YAML Front Matter（判定与 MdParser.parse 一致：首行 `---`，
   * 向后找 `---` 或 `...` 收尾）。找不到闭合就原样交回，让解析器按正文处理。
   */
  static stripFrontMatter(text: string): string {
    const lines: string[] = text.replace(/\r\n?/g, '\n').split('\n');
    if (lines.length < 2 || lines[0].trim() !== '---') {
      return text;
    }
    for (let k = 1; k < lines.length; k++) {
      const t: string = lines[k].trim();
      if (t === '---' || t === '...') {
        return lines.slice(k + 1).join('\n');
      }
    }
    return text;
  }

  /**
   * 合并产物的文件名（不含扩展名）。
   * 一篇时就用那篇的名字，多篇时给个能一眼看懂的默认名，用户仍可在另存为里改。
   */
  static mergedName(names: string[]): string {
    if (names.length === 0) {
      return '合并导出';
    }
    if (names.length === 1) {
      return names[0];
    }
    return '合并-' + names[0] + ' 等 ' + names.length + ' 篇';
  }
}
