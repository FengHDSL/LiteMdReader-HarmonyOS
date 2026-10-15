/**
 * 表格工具（TableTool）—— Markdown 表格的**结构化解析与改写**。
 *
 * 这是"可视化表格编辑"的核心：界面层只需要拿到 `MdTable`（行列与对齐），
 * 改完再交给 `toLines()` 变回 Markdown 文本写回源码，不用直接和竖线打交道。
 *
 * 覆盖的能力：解析 / 序列化 / 改单元格 / 增删行列 / 改对齐。
 *
 * 几个必须处理的细节：
 * 1. **单元格里的竖线要转义**：内容写成 `a \| b`，解析时还原为 `a | b`，
 *    序列化时再转义回去 —— 否则一个竖线就会把表格撑坏；
 * 2. **列数不齐时要补齐**：手写 Markdown 常见某行少写一列，直接按行数处理会错位；
 * 3. **对齐行必须保留**：`| --- | :--: |` 决定渲染对齐，产物里不能丢；
 * 4. 首尾竖线可省略（`a | b` 也是合法表格），解析时统一按有无首竖线处理。
 */

/** 表格对齐方式 */
export type TableAlign = 'left' | 'center' | 'right' | 'none';

/** 结构化表格 */
export interface MdTable {
  /** 表头单元格 */
  header: string[];
  /** 数据行 */
  rows: string[][];
  /** 每列对齐（长度与列数一致） */
  align: TableAlign[];
}

export class TableTool {
  /** 该行是否是"表格行"（含竖线且去掉竖线后有内容）。 */
  static isTableRow(line: string): boolean {
    const t: string = line.trim();
    return t.length > 1 && t.indexOf('|') >= 0;
  }

  /** 该行是否是"分隔行"（`| --- | :--: |`）。 */
  static isDelimiterRow(line: string): boolean {
    const t: string = line.trim();
    if (t.indexOf('-') < 0) {
      return false;
    }
    // 去掉竖线、空格、冒号、减号后应什么都不剩
    const rest: string = t.replace(/[|\s:\-]/g, '');
    return rest.length === 0;
  }

  /**
   * 把一行拆成单元格（处理 `\|` 转义与首尾竖线）。
   */
  static splitRow(line: string): string[] {
    let t: string = line.trim();
    if (t.startsWith('|')) {
      t = t.substring(1);
    }
    if (t.endsWith('|')) {
      t = t.substring(0, t.length - 1);
    }
    const out: string[] = [];
    let cur: string = '';
    for (let k = 0; k < t.length; k++) {
      const ch: string = t.charAt(k);
      if (ch === '\\' && k + 1 < t.length && t.charAt(k + 1) === '|') {
        cur += '|';
        k++;
      } else if (ch === '|') {
        out.push(cur.trim());
        cur = '';
      } else {
        cur += ch;
      }
    }
    out.push(cur.trim());
    return out;
  }

  /** 单元格内容 → Markdown 安全文本（竖线转义）。 */
  static escapeCell(s: string): string {
    return s.replace(/\|/g, '\\|').replace(/\n/g, ' ').trim();
  }

  /** 从一行分隔行里解析每列对齐。 */
  private static alignOf(cell: string): TableAlign {
    const t: string = cell.trim();
    const left: boolean = t.startsWith(':');
    const right: boolean = t.endsWith(':');
    if (left && right) {
      return 'center';
    }
    if (left) {
      return 'left';
    }
    if (right) {
      return 'right';
    }
    return 'none';
  }

  private static alignMark(a: TableAlign): string {
    if (a === 'center') {
      return ':---:';
    }
    if (a === 'left') {
      return ':---';
    }
    if (a === 'right') {
      return '---:';
    }
    return '---';
  }

  /**
   * 解析一段表格（至少 2 行：表头 + 分隔行）。不合法返回 null。
   */
  static parse(lines: string[]): MdTable | null {
    if (lines.length < 2) {
      return null;
    }
    if (!TableTool.isDelimiterRow(lines[1])) {
      return null;
    }
    const header: string[] = TableTool.splitRow(lines[0]);
    const marks: string[] = TableTool.splitRow(lines[1]);
    const cols: number = header.length;
    if (cols === 0) {
      return null;
    }
    const align: TableAlign[] = [];
    for (let k = 0; k < cols; k++) {
      align.push(k < marks.length ? TableTool.alignOf(marks[k]) : 'none');
    }
    const rows: string[][] = [];
    for (let i = 2; i < lines.length; i++) {
      if (!TableTool.isTableRow(lines[i])) {
        break;
      }
      const cells: string[] = TableTool.splitRow(lines[i]);
      // 补齐 / 裁齐到列数，避免错位
      const fixed: string[] = [];
      for (let k = 0; k < cols; k++) {
        fixed.push(k < cells.length ? cells[k] : '');
      }
      rows.push(fixed);
    }
    return { header: header, rows: rows, align: align } as MdTable;
  }

  /** 结构化表格 → Markdown 行（表头 / 分隔 / 数据）。 */
  static toLines(t: MdTable): string[] {
    const cols: number = t.header.length;
    const head: string[] = [];
    const del: string[] = [];
    for (let k = 0; k < cols; k++) {
      head.push(TableTool.escapeCell(t.header[k]));
      del.push(TableTool.alignMark(k < t.align.length ? t.align[k] : 'none'));
    }
    const out: string[] = [];
    out.push('| ' + head.join(' | ') + ' |');
    out.push('| ' + del.join(' | ') + ' |');
    for (let i = 0; i < t.rows.length; i++) {
      const cells: string[] = [];
      for (let k = 0; k < cols; k++) {
        cells.push(TableTool.escapeCell(k < t.rows[i].length ? t.rows[i][k] : ''));
      }
      out.push('| ' + cells.join(' | ') + ' |');
    }
    return out;
  }

  /**
   * 表格 → 分隔文本（CSV 传 ','，TSV 传制表符）：粘进 Excel / 表格软件用。
   * 与 `toLines` 的分工：那份是 Markdown 源码形态（带转义与对齐），这份是**字面文本**，
   * 不写 `|`、不转义星号，只按 RFC 4180 处理分隔符与引号。
   */
  static toDelimited(t: MdTable, sep: string): string {
    const out: string[] = [TableTool.delimRow(t.header, sep)];
    for (let i = 0; i < t.rows.length; i++) {
      out.push(TableTool.delimRow(t.rows[i], sep));
    }
    return out.join(String.fromCharCode(10));
  }

  /** 一行分隔文本：含分隔符 / 引号 / 换行的单元格整体加引号，内部引号翻倍；换行压成空格 */
  private static delimRow(cells: string[], sep: string): string {
    const out: string[] = [];
    for (let k = 0; k < cells.length; k++) {
      let v: string = cells[k];
      v = v.split(String.fromCharCode(13)).join(' ');
      v = v.split(String.fromCharCode(10)).join(' ');
      if (v.indexOf('"') >= 0 || v.indexOf(sep) >= 0) {
        out.push('"' + v.split('"').join('""') + '"');
      } else {
        out.push(v);
      }
    }
    return out.join(sep);
  }

  /** 改单元格（越界忽略）。 */
  static setCell(t: MdTable, row: number, col: number, text: string): MdTable {
    if (row < 0 || row >= t.rows.length || col < 0 || col >= t.header.length) {
      return t;
    }
    t.rows[row][col] = text;
    return t;
  }

  /** 改表头单元格。 */
  static setHeader(t: MdTable, col: number, text: string): MdTable {
    if (col >= 0 && col < t.header.length) {
      t.header[col] = text;
    }
    return t;
  }

  /** 在第 at 行前插入空行（at 越界则追加到末尾）。 */
  static addRow(t: MdTable, at: number): MdTable {
    const blank: string[] = [];
    for (let k = 0; k < t.header.length; k++) {
      blank.push('');
    }
    const idx: number = (at < 0 || at > t.rows.length) ? t.rows.length : at;
    t.rows.splice(idx, 0, blank);
    return t;
  }

  /** 删除第 at 行（至少保留一行）。 */
  static removeRow(t: MdTable, at: number): MdTable {
    if (at >= 0 && at < t.rows.length && t.rows.length > 1) {
      t.rows.splice(at, 1);
    }
    return t;
  }

  /** 在第 at 列前插入空列（表头 / 每行 / 对齐都要同步）。 */
  static addCol(t: MdTable, at: number): MdTable {
    const idx: number = (at < 0 || at > t.header.length) ? t.header.length : at;
    t.header.splice(idx, 0, '');
    t.align.splice(idx, 0, 'none');
    for (let i = 0; i < t.rows.length; i++) {
      t.rows[i].splice(idx, 0, '');
    }
    return t;
  }

  /** 删除第 at 列（至少保留一列）。 */
  static removeCol(t: MdTable, at: number): MdTable {
    if (at < 0 || at >= t.header.length || t.header.length <= 1) {
      return t;
    }
    t.header.splice(at, 1);
    t.align.splice(at, 1);
    for (let i = 0; i < t.rows.length; i++) {
      if (at < t.rows[i].length) {
        t.rows[i].splice(at, 1);
      }
    }
    return t;
  }

  /** 改整列对齐。 */
  static setAlign(t: MdTable, col: number, align: TableAlign): MdTable {
    if (col >= 0 && col < t.align.length) {
      t.align[col] = align;
    }
    return t;
  }

  /** 深拷贝（编辑前先拷一份，取消时不影响原文）。 */
  static clone(t: MdTable): MdTable {
    const header: string[] = [];
    for (let k = 0; k < t.header.length; k++) {
      header.push(t.header[k]);
    }
    const rows: string[][] = [];
    for (let i = 0; i < t.rows.length; i++) {
      const r: string[] = [];
      for (let k = 0; k < t.rows[i].length; k++) {
        r.push(t.rows[i][k]);
      }
      rows.push(r);
    }
    const align: TableAlign[] = [];
    for (let k = 0; k < t.align.length; k++) {
      align.push(t.align[k]);
    }
    return { header: header, rows: rows, align: align } as MdTable;
  }
}
