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
  Data = 7,
  /** 差异块（```diff）：**整行**按行首符号着色，不是逐 token 扫关键字 */
  Diff = 8
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
  Attr = 7,
  /** diff：新增行 */
  Added = 8,
  /** diff：删除行 */
  Removed = 9,
  /** diff：@@ 段头 */
  Hunk = 10
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
  'primary key foreign references default cascade begin end commit rollback transaction grant revoke execute '
  + 'procedure trigger cursor fetch open close declare case when then top identity if else while return';

const DATA_KEYWORDS: string = 'true false null';

const CSS_KEYWORDS: string =
  'important inherit initial unset auto none block flex grid inline absolute relative fixed sticky';

// ── 逐语言关键字表（对比基线：Qoder 内置渲染器用 Shiki，语言表就是这套东西的工业化版本；
//    澄笺离线、无 C++ 正则引擎，所以按语言族扫描 + 每语言一张关键字表，能覆盖日常阅读）──

const JAVA_KEYWORDS: string =
  'abstract assert boolean break byte case catch char class const continue default do double else enum extends '
  + 'final finally float for goto if implements import instanceof int interface long native new package private '
  + 'protected public return short static strictfp super switch synchronized this throw throws transient try var '
  + 'void volatile while record sealed permits yield';

const KOTLIN_KEYWORDS: string =
  'as break by catch class companion const continue data do else enum external false finally for fun get if '
  + 'import in infix init interface internal is lateinit noinline null object open operator out override package '
  + 'private protected public reified return sealed set suspend this throw try typealias val var vararg when while yield';

const SWIFT_KEYWORDS: string =
  'associatedtype class deinit enum extension fileprivate func import init inout internal let open operator '
  + 'private protocol public rethrows static struct subscript typealias var break case continue default defer do '
  + 'fallthrough for guard if in repeat return switch where while as is nil true false super self';

const GO_KEYWORDS: string =
  'break case chan const continue default defer else fallthrough for func go goto if import interface map package '
  + 'range return select struct switch type var bool byte complex64 complex128 error float32 float64 int int8 int16 '
  + 'int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr true false iota nil append cap close copy delete len make new panic recover';

const RUST_KEYWORDS: string =
  'as async await box break const continue crate dyn else enum extern false fn for if impl in let loop match mod '
  + 'move mut pub ref return self static struct super trait true type unsafe use where while Some None Ok Err vec String Option Result println';

const PHP_KEYWORDS: string =
  'abstract and array as break callable case catch class clone const continue declare default do echo else elseif '
  + 'empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function '
  + 'global goto if implements include include_once instanceof interface isset list match namespace new or print '
  + 'private protected public readonly require require_once return static switch throw trait try unset use var while xor yield true false null';

const CSHARP_KEYWORDS: string =
  'abstract as async await base bool break byte case catch char checked class const continue decimal default '
  + 'delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in '
  + 'int interface internal is lock long namespace new null object operator out override params private protected '
  + 'public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using var virtual void volatile while record init';

const C_KEYWORDS: string =
  'auto break case char const continue default do double else enum extern float for goto if inline int long '
  + 'register return short signed sizeof static struct switch typedef union unsigned void volatile while bool true '
  + 'false nullptr class private public protected template typename namespace using new delete try catch operator '
  + 'virtual override final friend explicit include define ifdef endif pragma vector map string';

const DART_KEYWORDS: string =
  'abstract as assert async await break case catch class const continue covariant default deferred do dynamic else '
  + 'enum extends extension external factory false final finally for get hide if implements import in interface is '
  + 'library mixin new null on operator part required rethrow return set show static super switch sync this throw true try typedef var void while with yield';

const SCALA_KEYWORDS: string =
  'abstract case catch class def do else extends false final finally for forSome if implicit import lazy match new '
  + 'object override package private protected return sealed super this throw trait try type val var while with yield given using enum export then';

const RUBY_KEYWORDS: string =
  'alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or '
  + 'redo rescue retry return self super then true undef unless until when while yield require attr_accessor attr_reader attr_writer puts print lambda proc';

const PERL_KEYWORDS: string =
  'my our local sub use no require if elsif else unless while until for foreach do last next redo return package '
  + 'BEGIN END print say chomp chop scalar shift unshift push pop';

const R_KEYWORDS: string =
  'if else for while repeat function return break next TRUE FALSE NULL Inf NaN NA library require source print '
  + 'c list vector matrix data.frame function';

const JULIA_KEYWORDS: string =
  'function end return if elseif else for while begin let module using import export in isa local global const '
  + 'try catch finally break continue do true false nothing missing struct mutable abstract primitive type where';

const ELIXIR_KEYWORDS: string =
  'do end def defp defmodule defstruct defprotocol defimpl case cond unless with for fn fun if else import use '
  + 'require alias when and or not true false nil receive after try catch rescue raise spawn send';

const DOCKER_KEYWORDS: string =
  'FROM RUN CMD LABEL MAINTAINER EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ONBUILD STOPSIGNAL HEALTHCHECK '
  + 'SHELL AS from run cmd label expose env add copy entrypoint volume user workdir healthcheck shell as';

const MAKE_KEYWORDS: string =
  'ifeq ifneq ifdef ifndef else endif include -include define endef export unexport override vpath .PHONY .DEFAULT '
  + 'MAKE MAKEFILE';

const CMAKE_KEYWORDS: string =
  'set if endif else foreach while function endfunction macro endmacro return message include add_library '
  + 'add_executable target_link_libraries project cmake_minimum_required option find_package install add_test';

const GRAPHQL_KEYWORDS: string =
  'type query mutation subscription input enum interface union schema extend scalar implements directive on '
  + 'repeatable fragment true false null';

const PROTO_KEYWORDS: string =
  'syntax package import message enum service rpc returns option repeated optional required reserved extend oneof '
  + 'map true false';

const GROOVY_KEYWORDS: string =
  'abstract as assert break case catch class const continue def default do else enum extends final finally for if '
  + 'implements import in instanceof interface new package return static super switch this throw throws trait try '
  + 'while true false null';

const SOLIDITY_KEYWORDS: string =
  'abstract address anonymous as assembly assert bool break bytes case catch constant constructor continue contract '
  + 'delete emit enum event external fallback for function if immutable import indexed interface internal mapping '
  + 'memory modifier new payable pragma private public pure returns require storage struct super this throw try type '
  + 'unchecked using view virtual while true false';

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
  // C 系（注释 // 与 /* */、字符串引号一致的语言都归这里，差异只在关键字表）
  if (l === 'js' || l === 'javascript' || l === 'jsx' || l === 'node' || l === 'mjs' || l === 'cjs'
    || l === 'ts' || l === 'typescript' || l === 'tsx' || l === 'mts' || l === 'cts'
    || l === 'java' || l === 'c' || l === 'cpp' || l === 'c++' || l === 'cc' || l === 'cxx'
    || l === 'h' || l === 'hpp' || l === 'cs' || l === 'csharp' || l === 'c#'
    || l === 'kotlin' || l === 'kt' || l === 'kts' || l === 'swift' || l === 'go'
    || l === 'golang' || l === 'rust' || l === 'rs' || l === 'php' || l === 'ets' || l === 'arkts'
    // 仓颉（Cangjie）：func / let / var / class / if 的形状与 C 系同源，走 C 系着色
    || l === 'cangjie' || l === 'cj' || l === '仓颉'
    || l === 'dart' || l === 'scala' || l === 'sc' || l === 'groovy' || l === 'gy'
    || l === 'objc' || l === 'objective-c' || l === 'sol' || l === 'solidity'
    || l === 'haxe' || l === 'vala' || l === 'thrift' || l === 'proto' || l === 'protobuf') {
    return CodeFamily.CLike;
  }
  if (l === 'py' || l === 'python' || l === 'pyi' || l === 'python3' || l === 'ipython') {
    return CodeFamily.Python;
  }
  // # 注释 + 引号字符串这一族里，ruby / perl / julia / elixir / R 的形状与 Python 同源，
  // 差别只有关键字（差别由 keywordsFor 出表）
  if (l === 'rb' || l === 'ruby' || l === 'erb' || l === 'pl' || l === 'pm' || l === 'perl'
    || l === 'jl' || l === 'julia' || l === 'ex' || l === 'exs' || l === 'elixir'
    || l === 'r' || l === 'rd' || l === 'rlang' || l === 'graphql' || l === 'gql'
    || l === 'dockerfile' || l === 'docker' || l === 'makefile' || l === 'make' || l === 'mk'
    || l === 'bsdmake' || l === 'cmake') {
    return CodeFamily.Python;
  }
  if (l === 'sh' || l === 'bash' || l === 'zsh' || l === 'shell' || l === 'console'
    || l === 'powershell' || l === 'ps1' || l === 'psm1' || l === 'bat' || l === 'batch' || l === 'cmd') {
    return CodeFamily.Shell;
  }
  if (l === 'html' || l === 'xml' || l === 'svg' || l === 'vue' || l === 'htm' || l === 'xhtml'
    || l === 'svelte' || l === 'astro'
    || l === 'plist' || l === 'rss' || l === 'atom' || l === 'xsl' || l === 'xsd' || l === 'dtd' || l === 'wsdl') {
    return CodeFamily.Markup;
  }
  if (l === 'css' || l === 'scss' || l === 'sass' || l === 'less' || l === 'styl' || l === 'stylus') {
    return CodeFamily.Css;
  }
  if (l === 'sql' || l === 'mysql' || l === 'postgresql' || l === 'psql' || l === 'plsql'
    || l === 'tsql' || l === 'sqlite' || l === 'hive' || l === 'duckdb' || l === 'clickhouse') {
    return CodeFamily.Sql;
  }
  if (l === 'json' || l === 'json5' || l === 'jsonc' || l === 'jsonl' || l === 'ndjson'
    || l === 'yaml' || l === 'yml' || l === 'toml' || l === 'ini' || l === 'conf' || l === 'cfg'
    || l === 'properties' || l === 'env' || l === 'dotenv' || l === 'gitignore' || l === 'editorconfig') {
    return CodeFamily.Data;
  }
  if (l === 'diff' || l === 'udiff' || l === 'patch') {
    return CodeFamily.Diff;
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

/**
 * 语言 → 该语言的关键字表；空串 = 用所属语言族的默认表。
 *
 * ⚠️ 这里**只登记注释 / 字符串语法与所归语言族一致的语言**：不一致的（Lua 与 Haskell 的
 * `--`、VB 的单引号、LaTeX 的 `%`、Fortran 的 `!`）一律留在 None 里不配色——
 * "关键字上了色、注释整段没上色"比全不上色更难看。
 */
function keywordsFor(lang: string): string {
  const l: string = lang.trim().toLowerCase();
  if (l === 'java') {
    return JAVA_KEYWORDS;
  }
  if (l === 'kotlin' || l === 'kt' || l === 'kts') {
    return KOTLIN_KEYWORDS;
  }
  if (l === 'swift') {
    return SWIFT_KEYWORDS;
  }
  if (l === 'go' || l === 'golang') {
    return GO_KEYWORDS;
  }
  if (l === 'rust' || l === 'rs') {
    return RUST_KEYWORDS;
  }
  if (l === 'php') {
    return PHP_KEYWORDS;
  }
  if (l === 'cs' || l === 'csharp' || l === 'c#') {
    return CSHARP_KEYWORDS;
  }
  if (l === 'c' || l === 'cpp' || l === 'c++' || l === 'cc' || l === 'cxx' || l === 'h' || l === 'hpp') {
    return C_KEYWORDS;
  }
  if (l === 'dart') {
    return DART_KEYWORDS;
  }
  if (l === 'scala' || l === 'sc') {
    return SCALA_KEYWORDS;
  }
  if (l === 'groovy' || l === 'gy') {
    return GROOVY_KEYWORDS;
  }
  if (l === 'rb' || l === 'ruby' || l === 'erb') {
    return RUBY_KEYWORDS;
  }
  if (l === 'pl' || l === 'pm' || l === 'perl') {
    return PERL_KEYWORDS;
  }
  if (l === 'r' || l === 'rd' || l === 'rlang') {
    return R_KEYWORDS;
  }
  if (l === 'jl' || l === 'julia') {
    return JULIA_KEYWORDS;
  }
  if (l === 'ex' || l === 'exs' || l === 'elixir') {
    return ELIXIR_KEYWORDS;
  }
  if (l === 'dockerfile' || l === 'docker') {
    return DOCKER_KEYWORDS;
  }
  if (l === 'makefile' || l === 'make' || l === 'mk' || l === 'bsdmake') {
    return MAKE_KEYWORDS;
  }
  if (l === 'cmake') {
    return CMAKE_KEYWORDS;
  }
  if (l === 'graphql' || l === 'gql') {
    return GRAPHQL_KEYWORDS;
  }
  if (l === 'proto' || l === 'protobuf') {
    return PROTO_KEYWORDS;
  }
  if (l === 'sol' || l === 'solidity') {
    return SOLIDITY_KEYWORDS;
  }
  return '';
}

function kindOfWord(word: string, family: CodeFamily, lang: string): number {
  // 逐语言表优先（java / ruby / dockerfile…），没有才退回语言族的公共表
  const own: string = keywordsFor(lang);
  if (own.length > 0) {
    return inWordList(family === CodeFamily.Sql ? word.toLowerCase() : word, own)
      ? CodeTokenKind.Keyword : CodeTokenKind.Plain;
  }
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
   * `lang` 是围栏上写的原始语言标识：同一个语言族里，java 与 ruby 的关键字不同，
   * 靠它去取逐语言表（留空 = 用语言族公共表）。
   */
  static highlightLine(line: string, family: CodeFamily, state: CodeState, lang: string = ''): CodeToken[] {
    // **diff 是整行语义**：一行的性质由行首符号决定（+ 增、- 删、@@ 段头、+++/--- 文件头），
    // 不是逐 token 扫关键字，所以放在最前面单独处理，整行出一个 token。
    if (family === CodeFamily.Diff) {
      const one: CodeToken[] = [];
      if (line.startsWith('@@')) {
        push(one, line, CodeTokenKind.Hunk);
      } else if (line.startsWith('+++ ') || line.startsWith('--- ')
        || line.startsWith('diff ') || line.startsWith('index ')) {
        push(one, line, CodeTokenKind.Keyword);
      } else if (line.startsWith('+')) {
        push(one, line, CodeTokenKind.Added);
      } else if (line.startsWith('-')) {
        push(one, line, CodeTokenKind.Removed);
      } else {
        push(one, line.length === 0 ? ' ' : line, CodeTokenKind.Plain);
      }
      return one;
    }
    if (family === CodeFamily.None || line.length === 0) {
      const single: CodeToken[] = [];
      push(single, line.length === 0 ? ' ' : line, CodeTokenKind.Plain);
      return single;
    }
    let result: CodeToken[];
    if (family === CodeFamily.Markup) {
      result = CodeHighlighter.markup(line, state);
    } else if (family === CodeFamily.Python) {
      result = CodeHighlighter.hashComment(line, family, state, lang);
    } else if (family === CodeFamily.Shell) {
      result = CodeHighlighter.hashComment(line, family, state, lang);
    } else if (family === CodeFamily.Sql) {
      result = CodeHighlighter.sql(line, family, state, lang);
    } else if (family === CodeFamily.Data) {
      result = CodeHighlighter.data(line, family, state, lang);
    } else {
      result = CodeHighlighter.cLike(line, family, state, lang);
    }
    // 空行也要占一个可见字符的高度，否则代码块的空行会被压扁
    if (result.length === 0) {
      push(result, ' ', CodeTokenKind.Plain);
    }
    return result;
  }

  // ────────────────────── C 系 ──────────────────────

  private static cLike(line: string, family: CodeFamily, state: CodeState, lang: string): CodeToken[] {
    const tokens: CodeToken[] = [];
    const n: number = line.length;
    let i: number = 0;
    let plain: string = '';
    const kw: string = keywordsFor(lang);

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
        let kind: number = kindOfWord(word, family, lang);
        if (kind === CodeTokenKind.Plain) {
          let m: number = k;
          while (m < n && line.charAt(m) === ' ') {
            m++;
          }
          if (m < n && line.charAt(m) === '(' && !inWordList(word, kw.length > 0 ? kw : C_LIKE_KEYWORDS)) {
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

  private static hashComment(line: string, family: CodeFamily, state: CodeState, lang: string): CodeToken[] {
    const tokens: CodeToken[] = [];
    const n: number = line.length;
    const kw: string = keywordsFor(lang);
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
        let kind: number = kindOfWord(word, family, lang);
        if (kind === CodeTokenKind.Plain) {
          let m: number = k;
          while (m < n && line.charAt(m) === ' ') {
            m++;
          }
          if (m < n && line.charAt(m) === '('
            && !inWordList(word, kw.length > 0 ? kw
              : (family === CodeFamily.Shell ? SH_KEYWORDS : PY_KEYWORDS))) {
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

  private static sql(line: string, family: CodeFamily, state: CodeState, lang: string): CodeToken[] {
    const trimmed: string = line.trim();
    if (trimmed.startsWith('--')) {
      const tokens: CodeToken[] = [];
      push(tokens, line, CodeTokenKind.Comment);
      return tokens;
    }
    return CodeHighlighter.cLike(line, family, state, lang);
  }

  // ────────────────────── 数据（JSON / YAML / TOML） ──────────────────────

  private static data(line: string, family: CodeFamily, state: CodeState, lang: string): CodeToken[] {
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
        const rest: CodeToken[] = CodeHighlighter.valueOnly(line.substring(colon + 1), family, lang);
        for (let k = 0; k < rest.length; k++) {
          tokens.push(rest[k]);
        }
        return tokens;
      }
    }
    // TOML / INI / properties / .env 的 `key = value`：键名单独着色（此前只有 `key:` 形式
    // 有色，toml 读起来是一片平色）。已经走过 `key:` 分支的（含 URL 里的冒号）不再进这里。
    const eq: number = line.indexOf('=');
    if (eq > 0 && line.indexOf(':') < 0) {
      const key: string = line.substring(0, eq);
      const kt: string = key.trim();
      if (kt.length > 0 && kt.indexOf(' ') < 0 && /^[A-Za-z0-9_.\-$"']+$/.test(kt)) {
        push(tokens, key, CodeTokenKind.Attr);
        const restEq: CodeToken[] = CodeHighlighter.valueOnly(line.substring(eq), family, lang);
        for (let k = 0; k < restEq.length; k++) {
          tokens.push(restEq[k]);
        }
        return tokens;
      }
    }
    // TOML / INI 的 `[table]` 段头
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      push(tokens, line, CodeTokenKind.Attr);
      return tokens;
    }
    const plain: CodeToken[] = CodeHighlighter.valueOnly(line, family, lang);
    for (let k = 0; k < plain.length; k++) {
      tokens.push(plain[k]);
    }
    return tokens;
  }

  /** 只处理字符串 / 数字 / 字面量，不认关键字之外的词。 */
  private static valueOnly(text: string, family: CodeFamily, lang: string): CodeToken[] {
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
        push(tokens, word, kindOfWord(word, family, lang));
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
