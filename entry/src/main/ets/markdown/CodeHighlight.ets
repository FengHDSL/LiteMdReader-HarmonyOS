/**
 * LiteMdReader · 轻量代码高亮
 * ============================
 *
 * 参考项目 MD Reader 用 highlight.js 做 30+ 语言高亮。ArkTS 侧无法直接移植那个库，
 * 这里做一个**刻意轻量**的替代：按语言族扫描关键字 / 字符串 / 注释 / 数字 / 函数名，
 * 覆盖日常阅读代码块所需的效果，代码量控制在可维护范围内。
 *
 * 设计取舍：
 *  · **按「语言族」而不是逐语言**实现——js/ts/java/c/go/rust 等共用一套 C 系扫描器，
 *    差异只在关键字表；
 *  · 状态跨行传递：块注释（斜杠星号开、星号斜杠收）要在下一行继续，
 *    所以调用方必须持有 `CodeState`；
 *  · 未识别的语言返回单个 Plain token，调用方按纯文本渲染，**不会**退化成乱码。
 */

import { BusinessError } from '@kit.BasicServicesKit';

/** 语言族 */
export enum CodeFamily {
  None = 0,
  CLike = 1,
  Python = 2,
  Shell = 3,
  Markup = 4,
  Css = 5,
  Sql = 6,
  Data = 7
}

/** token 类型 */
export enum CodeTokenKind {
  Plain = 0,
  Keyword = 1,
  Str = 2,
  Comment = 3,
  Number = 4,
  Func = 5,
  Tag = 6,
  Attr = 7
}

export interface CodeToken {
  text: string;
  kind: number;
}

/** 跨行状态 */
export interface CodeState {
  inBlockComment: boolean;
}

export function newCodeState(): CodeState {
  const s: CodeState = { inBlockComment: false };
  return s;
}

const C_LIKE_KEYWORDS: string =
  'abstract as async await break case catch class const continue declare default delete do else enum export ' +
  'extends false final finally for from function get if implements import in instanceof interface let new null ' +
  'of package private protected public readonly return set static super switch this throw true try type typeof ' +
  'undefined var void while with yield struct impl fn mut pub use match loop trait where defer func go chan ' +
  'map range package int string bool float64 error nil byte rune uint interface any';

const PY_KEYWORDS: string =
  'and as assert async await break class continue def del elif else except False finally for from global if ' +
  'import in is lambda None nonlocal not or pass raise return True try while with yield match case self print';

const SH_KEYWORDS: string =
  'if then else elif fi for while do done case esac function return in export source local readonly echo cd ' +
  'set unset exit test true false sudo mkdir rm cp mv cat grep sed awk';

const SQL_KEYWORDS: string =
  'select from where insert into values update set delete create table alter drop index view join left right ' +
  'inner outer on group by order having limit offset as and or not null distinct count sum avg min max union ' +
  'primary key foreign references default cascade';

const DATA_KEYWORDS: string = 'true false null';

const CSS_KEYWORDS: string =
  'important inherit initial unset auto none block flex grid inline absolute relative fixed sticky';

function inWordList(word: string, list: string): boolean {
  if (word.length === 0) {
    return false;
  }
  const padded: string = ' ' + list + ' ';
  return padded.indexOf(' ' + word + ' ') >= 0;
}

/** 语言标识 → 语言族 */
export function resolveFamily(lang: string): CodeFamily {
  const l: string = lang.trim().toLowerCase();
  if (l.length === 0) {
    return CodeFamily.None;
  }
  // C 系
  if (l === 'js' || l === 'javascript' || l === 'jsx' || l === 'ts' || l === 'typescript'
    || l === 'tsx' || l === 'java' || l === 'c' || l === 'cpp' || l === 'c++' || l === 'cs'
    || l === 'csharp' || l === 'kotlin' || l === 'kt' || l === 'swift' || l === 'go'
    || l === 'golang' || l === 'rust' || l === 'rs' || l === 'php' || l === 'ets' || l === 'arkts') {
    return CodeFamily.CLike;
  }
  if (l === 'py' || l === 'python') {
    return CodeFamily.Python;
  }
  if (l === 'sh' || l === 'bash' || l === 'zsh' || l === 'shell' || l === 'console' || l === 'powershell') {
    return CodeFamily.Shell;
  }
  if (l === 'html' || l === 'xml' || l === 'svg' || l === 'vue' || l === 'htm') {
    return CodeFamily.Markup;
  }
  if (l === 'css' || l === 'scss' || l === 'less') {
    return CodeFamily.Css;
  }
  if (l === 'sql' || l === 'mysql' || l === 'postgresql') {
    return CodeFamily.Sql;
  }
  if (l === 'json' || l === 'json5' || l === 'yaml' || l === 'yml' || l === 'toml' || l === 'ini') {
    return CodeFamily.Data;
  }
  return CodeFamily.None;
}

function isDigit(ch: string): boolean {
  const c: number = ch.charCodeAt(0);
  return c >= 48 && c <= 57;
}

function isIdentStart(ch: string): boolean {
  const c: number = ch.charCodeAt(0);
  return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || ch === '_' || ch === '$';
}

function isIdentChar(ch: string): boolean {
  return isIdentStart(ch) || isDigit(ch);
}

function kindOfWord(word: string, family: CodeFamily): number {
  if (family === CodeFamily.CLike) {
    return inWordList(word, C_LIKE_KEYWORDS) ? CodeTokenKind.Keyword : CodeTokenKind.Plain;
  }
  if (family === CodeFamily.Python) {
    return inWordList(word, PY_KEYWORDS) ? CodeTokenKind.Keyword : CodeTokenKind.Plain;
  }
  if (family === CodeFamily.Shell) {
    return inWordList(word, SH_KEYWORDS) ? CodeTokenKind.Keyword : CodeTokenKind.Plain;
  }
  if (family === CodeFamily.Sql) {
    return inWordList(word.toLowerCase(), SQL_KEYWORDS) ? CodeTokenKind.Keyword : CodeTokenKind.Plain;
  }
  if (family === CodeFamily.Data) {
    return inWordList(word.toLowerCase(), DATA_KEYWORDS) ? CodeTokenKind.Keyword : CodeTokenKind.Plain;
  }
  if (family === CodeFamily.Css) {
    return inWordList(word.toLowerCase(), CSS_KEYWORDS) ? CodeTokenKind.Keyword : CodeTokenKind.Plain;
  }
  return CodeTokenKind.Plain;
}

function push(tokens: CodeToken[], text: string, kind: number): void {
  if (text.length === 0) {
    return;
  }
  const t: CodeToken = { text: text, kind: kind };
  tokens.push(t);
}

export class CodeHighlighter {
  /** 该块是否需要着色（用于决定是否走 token 渲染路径）。 */
  static isHighlightable(lang: string): boolean {
    return resolveFamily(lang) !== CodeFamily.None;
  }

  /**
   * 着色一行。`state.inBlockComment` 会在多行注释的开始 / 结束处更新，
   * 所以调用方必须**按行顺序**调用并复用同一个 state。
   */
  static highlightLine(line: string, family: CodeFamily, state: CodeState): CodeToken[] {
    if (family === CodeFamily.None || line.length === 0) {
      const single: CodeToken[] = [];
      push(single, line.length === 0 ? ' ' : line, CodeTokenKind.Plain);
      return single;
    }
    let result: CodeToken[];
    if (family === CodeFamily.Markup) {
      result = CodeHighlighter.markup(line, state);
    } else if (family === CodeFamily.Python) {
      result = CodeHighlighter.hashComment(line, family, state);
    } else if (family === CodeFamily.Shell) {
      result = CodeHighlighter.hashComment(line, family, state);
    } else if (family === CodeFamily.Sql) {
      result = CodeHighlighter.sql(line, family, state);
    } else if (family === CodeFamily.Data) {
      result = CodeHighlighter.data(line, family, state);
    } else {
      result = CodeHighlighter.cLike(line, family, state);
    }
    // 空行也要占一个可见字符的高度，否则代码块的空行会被压扁
    if (result.length === 0) {
      push(result, ' ', CodeTokenKind.Plain);
    }
    return result;
  }

  // ────────────────────── C 系 ──────────────────────

  private static cLike(line: string, family: CodeFamily, state: CodeState): CodeToken[] {
    const tokens: CodeToken[] = [];
    const n: number = line.length;
    let i: number = 0;
    let plain: string = '';

    while (i < n) {
      // 续上一行的块注释
      if (state.inBlockComment) {
        const end: number = line.indexOf('*/', i);
        if (end < 0) {
          push(tokens, plain, CodeTokenKind.Plain);
          plain = '';
          push(tokens, line.substring(i), CodeTokenKind.Comment);
          return tokens;
        }
        push(tokens, plain, CodeTokenKind.Plain);
        plain = '';
        push(tokens, line.substring(i, end + 2), CodeTokenKind.Comment);
        state.inBlockComment = false;
        i = end + 2;
        continue;
      }

      const ch: string = line.charAt(i);

      // 行注释
      if (ch === '/' && i + 1 < n && line.charAt(i + 1) === '/') {
        push(tokens, plain, CodeTokenKind.Plain);
        plain = '';
        push(tokens, line.substring(i), CodeTokenKind.Comment);
        return tokens;
      }
      // 块注释
      if (ch === '/' && i + 1 < n && line.charAt(i + 1) === '*') {
        push(tokens, plain, CodeTokenKind.Plain);
        plain = '';
        const end: number = line.indexOf('*/', i + 2);
        if (end < 0) {
          push(tokens, line.substring(i), CodeTokenKind.Comment);
          state.inBlockComment = true;
          return tokens;
        }
        push(tokens, line.substring(i, end + 2), CodeTokenKind.Comment);
        i = end + 2;
        continue;
      }
      // 字符串
      if (ch === '"' || ch === '\'' || ch === '`') {
        push(tokens, plain, CodeTokenKind.Plain);
        plain = '';
        let k: number = i + 1;
        while (k < n) {
          const c: string = line.charAt(k);
          if (c === '\\') {
            k += 2;
            continue;
          }
          if (c === ch) {
            k++;
            break;
          }
          k++;
        }
        push(tokens, line.substring(i, k > n ? n : k), CodeTokenKind.Str);
        i = k;
        continue;
      }
      // 数字
      if (isDigit(ch) && !isIdentChar(i > 0 ? line.charAt(i - 1) : ' ')) {
        push(tokens, plain, CodeTokenKind.Plain);
        plain = '';
        let k: number = i;
        while (k < n) {
          const c: string = line.charAt(k);
          if (isDigit(c) || c === '.' || c === 'x' || c === 'X' || c === '_'
            || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
            k++;
          } else {
            break;
          }
        }
        push(tokens, line.substring(i, k), CodeTokenKind.Number);
        i = k;
        continue;
      }
      // 标识符 / 关键字 / 函数名
      if (isIdentStart(ch)) {
        push(tokens, plain, CodeTokenKind.Plain);
        plain = '';
        let k: number = i;
        while (k < n && isIdentChar(line.charAt(k))) {
          k++;
        }
        const word: string = line.substring(i, k);
        // 后面紧跟 ( 视为函数调用
        let kind: number = kindOfWord(word, family);
        if (kind === CodeTokenKind.Plain) {
          let m: number = k;
          while (m < n && line.charAt(m) === ' ') {
            m++;
          }
          if (m < n && line.charAt(m) === '(' && !inWordList(word, C_LIKE_KEYWORDS)) {
            kind = CodeTokenKind.Func;
          }
        }
        push(tokens, word, kind);
        i = k;
        continue;
      }

      plain = plain + ch;
      i++;
    }

    push(tokens, plain, CodeTokenKind.Plain);
    return tokens;
  }

  // ────────────────────── # 注释系（Python / Shell） ──────────────────────

  private static hashComment(line: string, family: CodeFamily, state: CodeState): CodeToken[] {
    const tokens: CodeToken[] = [];
    const n: number = line.length;
    let i: number = 0;
    let plain: string = '';

    while (i < n) {
      const ch: string = line.charAt(i);
      if (ch === '#') {
        push(tokens, plain, CodeTokenKind.Plain);
        plain = '';
        push(tokens, line.substring(i), CodeTokenKind.Comment);
        return tokens;
      }
      if (ch === '"' || ch === '\'') {
        push(tokens, plain, CodeTokenKind.Plain);
        plain = '';
        let k: number = i + 1;
        let closed: boolean = false;
        while (k < n) {
          const c: string = line.charAt(k);
          if (c === '\\') {
            k += 2;
            continue;
          }
          if (c === ch) {
            closed = true;
            k++;
            break;
          }
          k++;
        }
        // 三引号：Python docstring 在同一行内闭合时整段都是字符串
        if (family === CodeFamily.Python && i + 2 < n && line.charAt(i + 1) === ch && line.charAt(i + 2) === ch) {
          const tripleEnd: number = line.indexOf(ch + ch + ch, i + 3);
          if (tripleEnd > 0) {
            push(tokens, line.substring(i, tripleEnd + 3), CodeTokenKind.Str);
            i = tripleEnd + 3;
            continue;
          }
        }
        push(tokens, line.substring(i, closed ? k : n), CodeTokenKind.Str);
        i = closed ? k : n;
        continue;
      }
      if (isDigit(ch) && !isIdentChar(i > 0 ? line.charAt(i - 1) : ' ')) {
        push(tokens, plain, CodeTokenKind.Plain);
        plain = '';
        let k: number = i;
        while (k < n && (isDigit(line.charAt(k)) || line.charAt(k) === '.')) {
          k++;
        }
        push(tokens, line.substring(i, k), CodeTokenKind.Number);
        i = k;
        continue;
      }
      if (isIdentStart(ch)) {
        push(tokens, plain, CodeTokenKind.Plain);
        plain = '';
        let k: number = i;
        while (k < n && isIdentChar(line.charAt(k))) {
          k++;
        }
        const word: string = line.substring(i, k);
        let kind: number = kindOfWord(word, family);
        if (kind === CodeTokenKind.Plain) {
          let m: number = k;
          while (m < n && line.charAt(m) === ' ') {
            m++;
          }
          if (m < n && line.charAt(m) === '(' && !inWordList(word, PY_KEYWORDS)) {
            kind = CodeTokenKind.Func;
          }
        }
        push(tokens, word, kind);
        i = k;
        continue;
      }
      plain = plain + ch;
      i++;
    }
    push(tokens, plain, CodeTokenKind.Plain);
    return tokens;
  }

  // ────────────────────── SQL ──────────────────────

  private static sql(line: string, family: CodeFamily, state: CodeState): CodeToken[] {
    const trimmed: string = line.trim();
    if (trimmed.startsWith('--')) {
      const tokens: CodeToken[] = [];
      push(tokens, line, CodeTokenKind.Comment);
      return tokens;
    }
    return CodeHighlighter.cLike(line, family, state);
  }

  // ────────────────────── 数据（JSON / YAML / TOML） ──────────────────────

  private static data(line: string, family: CodeFamily, state: CodeState): CodeToken[] {
    const trimmed: string = line.trim();
    const tokens: CodeToken[] = [];
    // JSON 不支持注释；YAML / TOML 的 # 是注释
    if (trimmed.startsWith('#')) {
      push(tokens, line, CodeTokenKind.Comment);
      return tokens;
    }
    // `key:` 形式的键（YAML / TOML）单独着色，便于扫结构
    const colon: number = line.indexOf(':');
    const n: number = line.length;
    if (colon > 0) {
      let onlyKey: boolean = true;
      for (let k = 0; k < colon; k++) {
        const c: string = line.charAt(k);
        if (!isIdentChar(c) && c !== ' ' && c !== '"' && c !== '\'') {
          onlyKey = false;
          break;
        }
      }
      if (onlyKey) {
        let head: string = line.substring(0, colon);
        // 引号包起来的键：连引号一起着色
        const firstQuote: number = head.indexOf('"') >= 0 ? head.indexOf('"') : head.indexOf('\'');
        if (firstQuote > 0) {
          push(tokens, head.substring(0, firstQuote), CodeTokenKind.Plain);
          head = head.substring(firstQuote);
        }
        push(tokens, head, CodeTokenKind.Attr);
        push(tokens, ':', CodeTokenKind.Plain);
        const rest: CodeToken[] = CodeHighlighter.valueOnly(line.substring(colon + 1), family);
        for (let k = 0; k < rest.length; k++) {
          tokens.push(rest[k]);
        }
        return tokens;
      }
    }
    const plain: CodeToken[] = CodeHighlighter.valueOnly(line, family);
    for (let k = 0; k < plain.length; k++) {
      tokens.push(plain[k]);
    }
    return tokens;
  }

  /** 只处理字符串 / 数字 / 字面量，不认关键字之外的词。 */
  private static valueOnly(text: string, family: CodeFamily): CodeToken[] {
    const tokens: CodeToken[] = [];
    const n: number = text.length;
    let i: number = 0;
    let plain: string = '';
    while (i < n) {
      const ch: string = text.charAt(i);
      if (ch === '"' || ch === '\'') {
        push(tokens, plain, CodeTokenKind.Plain);
        plain = '';
        let k: number = i + 1;
        while (k < n) {
          const c: string = text.charAt(k);
          if (c === '\\') {
            k += 2;
            continue;
          }
          if (c === ch) {
            k++;
            break;
          }
          k++;
        }
        push(tokens, text.substring(i, k > n ? n : k), CodeTokenKind.Str);
        i = k;
        continue;
      }
      if (isDigit(ch)) {
        push(tokens, plain, CodeTokenKind.Plain);
        plain = '';
        let k: number = i;
        while (k < n && (isDigit(text.charAt(k)) || text.charAt(k) === '.' || text.charAt(k) === '-')) {
          k++;
        }
        push(tokens, text.substring(i, k), CodeTokenKind.Number);
        i = k;
        continue;
      }
      if (isIdentStart(ch)) {
        push(tokens, plain, CodeTokenKind.Plain);
        plain = '';
        let k: number = i;
        while (k < n && isIdentChar(text.charAt(k))) {
          k++;
        }
        const word: string = text.substring(i, k);
        push(tokens, word, kindOfWord(word, family));
        i = k;
        continue;
      }
      plain = plain + ch;
      i++;
    }
    push(tokens, plain, CodeTokenKind.Plain);
    return tokens;
  }

  // ────────────────────── HTML / XML ──────────────────────

  private static markup(line: string, state: CodeState): CodeToken[] {
    const tokens: CodeToken[] = [];
    const n: number = line.length;
    let i: number = 0;
    let plain: string = '';

    while (i < n) {
      // 注释
      if (line.startsWith('<!--', i)) {
        push(tokens, plain, CodeTokenKind.Plain);
        plain = '';
        const end: number = line.indexOf('-->', i + 4);
        if (end < 0) {
          push(tokens, line.substring(i), CodeTokenKind.Comment);
          return tokens;
        }
        push(tokens, line.substring(i, end + 3), CodeTokenKind.Comment);
        i = end + 3;
        continue;
      }
      const ch: string = line.charAt(i);
      // 标签
      if (ch === '<') {
        push(tokens, plain, CodeTokenKind.Plain);
        plain = '';
        let k: number = i + 1;
        let tagEnd: number = -1;
        let inQuote: string = '';
        while (k < n) {
          const c: string = line.charAt(k);
          if (inQuote.length > 0) {
            if (c === inQuote) {
              inQuote = '';
            }
          } else if (c === '"' || c === '\'') {
            inQuote = c;
          } else if (c === '>') {
            tagEnd = k;
            break;
          }
          k++;
        }
        const stop: number = tagEnd >= 0 ? tagEnd + 1 : n;
        const tag: string = line.substring(i, stop);
        CodeHighlighter.markupTag(tag, tokens);
        i = stop;
        continue;
      }
      plain = plain + ch;
      i++;
    }
    push(tokens, plain, CodeTokenKind.Plain);
    return tokens;
  }

  /** 把一整段 `<a href="x">` 拆成标签名 / 属性名 / 字符串。 */
  private static markupTag(tag: string, tokens: CodeToken[]): void {
    const n: number = tag.length;
    let i: number = 0;
    let buf: string = '';
    while (i < n) {
      const ch: string = tag.charAt(i);
      if (ch === '"' || ch === '\'') {
        push(tokens, buf, CodeTokenKind.Plain);
        buf = '';
        let k: number = i + 1;
        while (k < n && tag.charAt(k) !== ch) {
          k++;
        }
        push(tokens, tag.substring(i, k < n ? k + 1 : n), CodeTokenKind.Str);
        i = k < n ? k + 1 : n;
        continue;
      }
      if (ch === '<' || ch === '>' || ch === '/') {
        push(tokens, buf, CodeTokenKind.Plain);
        buf = '';
        push(tokens, ch, CodeTokenKind.Tag);
        i++;
        continue;
      }
      if (isIdentStart(ch)) {
        push(tokens, buf, CodeTokenKind.Plain);
        buf = '';
        let k: number = i;
        while (k < n && (isIdentChar(tag.charAt(k)) || tag.charAt(k) === '-')) {
          k++;
        }
        push(tokens, tag.substring(i, k), CodeTokenKind.Attr);
        i = k;
        continue;
      }
      buf = buf + ch;
      i++;
    }
    push(tokens, buf, CodeTokenKind.Plain);
  }
}
