/**
 * 澄笺 · Markdown → 纯文本（导出 TXT 用）
 * ======================================
 *
 * 逐行扫描（不用正则，避免 ArkTS 下不可控的写法）把 Markdown 语法剥掉：
 *   · 代码围栏 ``` 去掉、内部的代码原样保留；
 *   · 标题 # / 引用 > / 列表标记 - * + 1. 去掉；
 *   · 行内 **加粗** *斜体* ~~删除线~~ `代码` 的标记去掉，[文本](链接) 只留文本，
 *     ![说明](图) 只留说明；
 *   · 表格行按单元格拆开、用空格连接；分隔行（|---|）整行丢弃；
 *   · 连续空行压成一个，首尾去空。
 */
export class MdToPlain {
  /** 是否只有 - : 空格（表格分隔行）。 */
  private static isTableSep(line: string): boolean {
    const t: string = line.trim();
    if (t.length === 0 || t.indexOf('|') < 0) {
      return false;
    }
    for (let i = 0; i < t.length; i++) {
      const c: string = t.charAt(i);
      if (c !== '|' && c !== '-' && c !== ':' && c !== ' ') {
        return false;
      }
    }
    return true;
  }

  /** 表格行 → 单元格文本（空格连接）。 */
  private static tableLine(line: string): string {
    let t: string = line.trim();
    if (t.startsWith('|')) {
      t = t.substring(1);
    }
    if (t.endsWith('|')) {
      t = t.substring(0, t.length - 1);
    }
    const cells: string[] = t.split('|');
    const parts: string[] = [];
    for (let i = 0; i < cells.length; i++) {
      const c: string = cells[i].trim();
      if (c.length > 0) {
        parts.push(c);
      }
    }
    return parts.join('    ');
  }

  /** 去掉行首的 # 标题标记。 */
  private static stripHeading(line: string): string {
    let i: number = 0;
    while (i < line.length && line.charAt(i) === ' ') {
      i++;
    }
    let hashes: number = 0;
    while (i + hashes < line.length && line.charAt(i + hashes) === '#') {
      hashes++;
    }
    if (hashes === 0 || hashes > 6) {
      return line;
    }
    let rest: string = line.substring(i + hashes);
    while (rest.startsWith(' ')) {
      rest = rest.substring(1);
    }
    return rest;
  }

  /** 去掉行首的 > 引用标记（支持嵌套）。 */
  private static stripQuote(line: string): string {
    let s: string = line;
    let changed: boolean = true;
    while (changed) {
      changed = false;
      let i: number = 0;
      while (i < s.length && s.charAt(i) === ' ') {
        i++;
      }
      if (i < s.length && s.charAt(i) === '>') {
        let rest: string = s.substring(i + 1);
        if (rest.startsWith(' ')) {
          rest = rest.substring(1);
        }
        s = rest;
        changed = true;
      }
    }
    return s;
  }

  /** 去掉列表 / 任务列表标记（保留任务勾选状态文字）。 */
  private static stripListMarker(line: string): string {
    let i: number = 0;
    while (i < line.length && line.charAt(i) === ' ') {
      i++;
    }
    if (i >= line.length) {
      return line;
    }
    const c: string = line.charAt(i);
    const rest: string = line.substring(i);
    if (c === '-' || c === '*' || c === '+') {
      if (rest.startsWith('- [x] ') || rest.startsWith('- [X] ')) {
        return '[x] ' + rest.substring(6);
      }
      if (rest.startsWith('- [ ] ')) {
        return '[ ] ' + rest.substring(6);
      }
      if (rest.startsWith(c + ' ')) {
        return rest.substring(2);
      }
    }
    // 有序列表：数字 + '. ' 或 ') '
    let digits: number = 0;
    while (i + digits < line.length && line.charAt(i + digits) >= '0' && line.charAt(i + digits) <= '9') {
      digits++;
    }
    if (digits > 0 && i + digits + 1 < line.length) {
      const dot: string = line.charAt(i + digits);
      if ((dot === '.' || dot === ')') && line.charAt(i + digits + 1) === ' ') {
        return line.substring(i + digits + 2);
      }
    }
    return line;
  }

  /** 行内语法：去掉强调与代码标记，链接只留文本，图片只留说明。 */
  private static stripInline(line: string): string {
    let out: string = '';
    let i: number = 0;
    while (i < line.length) {
      const c: string = line.charAt(i);
      // 图片 ![alt](url) → alt
      if (c === '!' && i + 1 < line.length && line.charAt(i + 1) === '[') {
        const close: number = line.indexOf(']', i + 1);
        if (close > 0) {
          out += line.substring(i + 2, close);
          i = close + 1;
          if (i < line.length && line.charAt(i) === '(') {
            const rp: number = line.indexOf(')', i);
            i = rp > 0 ? rp + 1 : i;
          }
          continue;
        }
      }
      // 链接 [text](url) → text
      if (c === '[') {
        const close: number = line.indexOf(']', i);
        if (close > 0 && close + 1 < line.length && line.charAt(close + 1) === '(') {
          const rp: number = line.indexOf(')', close);
          if (rp > 0) {
            out += line.substring(i + 1, close);
            i = rp + 1;
            continue;
          }
        }
      }
      // 行内代码 `code` → code
      if (c === '`') {
        const close: number = line.indexOf('`', i + 1);
        if (close > 0) {
          out += line.substring(i + 1, close);
          i = close + 1;
          continue;
        }
      }
      // 强调标记：** __ ~~ * _（成对去掉，不匹配就原样保留）
      if (c === '*' || c === '_' || c === '~') {
        if (i + 1 < line.length && line.charAt(i + 1) === c) {
          i += 2;
          continue;
        }
        i += 1;
        continue;
      }
      out += c;
      i++;
    }
    return out;
  }

  /** Markdown → 纯文本。 */
  static convert(md: string): string {
    const lines: string[] = md.split('\n');
    const out: string[] = [];
    let inFence: boolean = false;
    for (let i = 0; i < lines.length; i++) {
      const raw: string = lines[i];
      const t: string = raw.trim();
      if (t.startsWith('```')) {
        inFence = !inFence;
        continue;
      }
      if (inFence) {
        out.push(raw);
        continue;
      }
      if (MdToPlain.isTableSep(raw)) {
        continue;
      }
      if (t === '---' || t === '***' || t === '___') {
        out.push('');
        continue;
      }
      let s: string = MdToPlain.stripHeading(raw);
      s = MdToPlain.stripQuote(s);
      s = MdToPlain.stripListMarker(s);
      if (s.indexOf('|') >= 0 && s.trim().startsWith('|')) {
        s = MdToPlain.tableLine(s);
      } else {
        s = MdToPlain.stripInline(s);
      }
      out.push(s);
    }
    // 连续空行压成一个
    const compact: string[] = [];
    let blank: boolean = false;
    for (let k = 0; k < out.length; k++) {
      const isBlank: boolean = out[k].trim().length === 0;
      if (isBlank) {
        if (!blank) {
          compact.push('');
        }
        blank = true;
      } else {
        compact.push(out[k]);
        blank = false;
      }
    }
    const text: string = compact.join('\n').trim();
    return text.length === 0 ? '' : text + '\n';
  }
}
