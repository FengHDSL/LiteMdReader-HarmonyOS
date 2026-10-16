/**
 * LiteMdReader · 「离线铭牌」内核（shields.io 静态徽章）
 * ======================================================
 *
 * 背景（用户实测）：GitHub README 头部那句
 *
 *   [![Version](https://img.shields.io/badge/version-1.4.1-blue)](https://…)
 *
 * 在 GitHub 上显示成一枚小铭牌，进了澄笺却有两种坏结果：
 *   ① 落在普通段落里 → 行内解析把 `[![…](…)](…)` 当"链接"，正文直接印出
 *      原始 Markdown（替代文字都没了）；
 *   ② 落在 HTML 块里（`<p align="center"><a><img src="…shields…"></a></p>`）→
 *      生成 `<img src="https://img.shields.io/…">` 交给 WebView，**要联网**：
 *      国内网络经常拉不到、基础（纯离线）模式下必然失败。
 *
 * 本模块把徽章地址解析成结构化数据，然后在本地画出来（正文芯片 / 内联样式 HTML），
 * 于是它**完全离线**、深色浅色都在、导出与打印同样有效。
 *
 * 语义按 shields 官方口径实现，并用 tools/probe-shields.js 逐条实测校准：
 *   · `/badge/<label>-<message>-<color>`（message / color 可省）
 *   · 转义：`__`→`_`、`--`→`-`、`_` 或 `%20`→空格
 *   · 两段时第二段必须是颜色（shields 会 404）——这里**宽容化**为
 *     "label-message + 默认色"（作者意图几乎必然是 label: message）
 *   · 四段及以上 shields 直接 404 → 本模块也判为非徽章，交回原远程图片路径
 *   · 颜色：命名色（下表是 shields 真实值，橙色不是 CSS 的 orange）+ 十六进制
 *     + rgb()/rgba()；取不到时三段式用 shields 默认色、两段式按上面宽容处理
 *   · `?style=` `?label=` `?color=` `?labelColor=` 生效；`?logo=` 不支持（需要图标库，
 *     保持不画 logo，徽章其余部分照常显示）
 *
 * ⚠️ 颜色表与形态参数是**实测值**（tools/probe-shields.js 的探测输出），
 * 改动前请重跑该脚本，别凭 CSS 直觉填色（比如 shields 的 orange = #ea7233）。
 */

import { MdBadge } from './MdTypes';

/** shields 静态徽章在"没给颜色"时的默认底色（brightgreen，#4b0） */
export const BADGE_DEFAULT_COLOR: string = '#44BB00';
/** 左段（label）默认底色 */
export const BADGE_DEFAULT_LABEL_COLOR: string = '#555555';
/** 支持的形态；其它值一律按 flat 处理 */
export const BADGE_STYLES: string[] = ['flat', 'flat-square', 'plastic', 'for-the-badge', 'social'];

/** 解析中间结果（用对象而不是元组，ArkTS 对联合类型更友好） */
interface MdBadgeResult {
  ok: boolean;
  label: string;
  message: string;
  color: string;
  labelColor: string;
  style: string;
}

/** 结果：徽章地址解析失败时的空对象（避免 ArkTS 里出现 undefined） */
function missBadge(): MdBadgeResult {
  const r: MdBadgeResult = {
    ok: false, label: '', message: '', color: '', labelColor: '', style: ''
  };
  return r;
}

/** shields 命名色 → 实测色值（见 tools/probe-shields.js 输出） */
interface BadgeColorPair {
  name: string;
  hex: string;
}

const NAMED_COLORS: BadgeColorPair[] = [
  // ── shields 自有调色板（与 CSS 同名色**不一致**，必须用实测值）──
  { name: 'brightgreen', hex: '#44BB00' },
  { name: 'green', hex: '#67AC09' },
  { name: 'yellowgreen', hex: '#95991A' },
  { name: 'yellow', hex: '#D8B800' },
  { name: 'orange', hex: '#EA7233' },
  { name: 'red', hex: '#DD4343' },
  { name: 'blue', hex: '#007EC6' },
  { name: 'grey', hex: '#555555' },
  { name: 'gray', hex: '#555555' },
  { name: 'lightgrey', hex: '#939393' },
  { name: 'lightgray', hex: '#939393' },
  // ── 语义别名 ──
  { name: 'success', hex: '#44BB00' },
  { name: 'important', hex: '#EA7233' },
  { name: 'critical', hex: '#DD4343' },
  { name: 'informational', hex: '#007EC6' },
  { name: 'inactive', hex: '#939393' },
  // ── 常见 CSS 命名色（shields 允许直接用，这里给出标准值）──
  { name: 'black', hex: '#000000' },
  { name: 'white', hex: '#FFFFFF' },
  { name: 'silver', hex: '#C0C0C0' },
  { name: 'maroon', hex: '#800000' },
  { name: 'olive', hex: '#808000' },
  { name: 'lime', hex: '#00FF00' },
  { name: 'aqua', hex: '#00FFFF' },
  { name: 'cyan', hex: '#00FFFF' },
  { name: 'teal', hex: '#008080' },
  { name: 'navy', hex: '#000080' },
  { name: 'purple', hex: '#800080' },
  { name: 'fuchsia', hex: '#FF00FF' },
  { name: 'magenta', hex: '#FF00FF' },
  { name: 'pink', hex: '#FFC0CB' },
  { name: 'hotpink', hex: '#FF69B4' },
  { name: 'deeppink', hex: '#FF1493' },
  { name: 'crimson', hex: '#DC143C' },
  { name: 'tomato', hex: '#FF6347' },
  { name: 'coral', hex: '#FF7F50' },
  { name: 'salmon', hex: '#FA8072' },
  { name: 'gold', hex: '#FFD700' },
  { name: 'goldenrod', hex: '#DAA520' },
  { name: 'khaki', hex: '#F0E68C' },
  { name: 'brown', hex: '#A52A2A' },
  { name: 'chocolate', hex: '#D2691E' },
  { name: 'peru', hex: '#CD853F' },
  { name: 'sienna', hex: '#A0522D' },
  { name: 'darkred', hex: '#8B0000' },
  { name: 'darkgreen', hex: '#006400' },
  { name: 'forestgreen', hex: '#228B22' },
  { name: 'seagreen', hex: '#2E8B57' },
  { name: 'limegreen', hex: '#32CD32' },
  { name: 'darkorange', hex: '#FF8C00' },
  { name: 'darkblue', hex: '#00008B' },
  { name: 'royalblue', hex: '#4169E1' },
  { name: 'dodgerblue', hex: '#1E90FF' },
  { name: 'steelblue', hex: '#4682B4' },
  { name: 'skyblue', hex: '#87CEEB' },
  { name: 'turquoise', hex: '#40E0D0' },
  { name: 'darkcyan', hex: '#008B8B' },
  { name: 'darkmagenta', hex: '#8B008B' },
  { name: 'indigo', hex: '#4B0082' },
  { name: 'blueviolet', hex: '#8A2BE2' },
  { name: 'darkviolet', hex: '#9400D3' },
  { name: 'violet', hex: '#EE82EE' },
  { name: 'orchid', hex: '#DA70D6' },
  { name: 'plum', hex: '#DDA0DD' },
  { name: 'mediumpurple', hex: '#9370DB' },
  { name: 'slateblue', hex: '#6A5ACD' },
  { name: 'rebeccapurple', hex: '#663399' }
];

/** 徽章行里的一条构造：图片地址 + 可能的包裹链接（`[![alt](img)](href)`） */
interface BadgeLineHit {
  hit: boolean;
  /** 吃掉的字符数（0 = 这里不是徽章构造） */
  len: number;
  src: string;
  href: string;
  alt: string;
}

/** `![alt](地址)` 这一串的解析结果（链接文字位置上的图片，见 parseImageOnly） */
export interface MdImageInline {
  alt: string;
  src: string;
}

function missLineHit(): BadgeLineHit {
  const r: BadgeLineHit = { hit: false, len: 0, src: '', href: '', alt: '' };
  return r;
}

/** 徽章地址按 `/` 与 `?` 切开后的部件 */
interface BadgeUrlParts {
  /** path（不含 host，不含 query） */
  path: string;
  /** 原始 query（不含 `?`，没有是空串） */
  query: string;
}

/**
 * 离线铭牌内核。全部是纯函数（无状态、无 IO、不联网），
 * 解析期与渲染期共用同一份结果，不会出现"两处口径不一致"。
 */
export class Badge {
  /** 这个地址是不是**本模块能离线画出来**的徽章（目前覆盖 shields.io 静态徽章） */
  static isBadgeUrl(url: string): boolean {
    const parts: BadgeUrlParts | null = Badge.splitUrl(url);
    if (parts === null) {
      return false;
    }
    return Badge.contentOf(parts) !== '';
  }

  /**
   * 徽章地址 → 结构化铭牌；不是徽章（或本模块画不出来）返回 `null`，
   * 调用方据此回落到原来的远程图片路径，**不改变既有行为**。
   */
  static parse(url: string): MdBadge | null {
    const parts: BadgeUrlParts | null = Badge.splitUrl(url);
    if (parts === null) {
      return null;
    }
    const content: string = Badge.contentOf(parts);
    if (content.length === 0) {
      return null;
    }
    const query: string = parts.query;
    const res: MdBadgeResult = Badge.parseContent(content);
    if (!res.ok) {
      return null;
    }
    // query 覆盖（shields 的 ?label= / ?color= / ?labelColor= / ?style=）
    const qLabel: string = Badge.queryValue(query, 'label');
    if (qLabel.length > 0) {
      res.label = Badge.unescapeText(qLabel);
    }
    const qColor: string = Badge.queryValue(query, 'color');
    if (qColor.length > 0) {
      const c: string = Badge.normalizeColor(qColor);
      if (c.length > 0) {
        res.color = c;
      }
    }
    const qLabelColor: string = Badge.queryValue(query, 'labelcolor');
    if (qLabelColor.length > 0) {
      const c: string = Badge.normalizeColor(qLabelColor);
      if (c.length > 0) {
        res.labelColor = c;
      }
    }
    const qStyle: string = Badge.queryValue(query, 'style');
    if (qStyle.length > 0 && BADGE_STYLES.indexOf(qStyle.toLowerCase()) >= 0) {
      res.style = qStyle.toLowerCase();
    }
    const badge: MdBadge = {
      label: res.label,
      message: res.message,
      color: res.color,
      labelColor: res.labelColor,
      style: res.style,
      href: '',
      alt: '',
      src: url.trim()
    };
    return badge;
  }

  /**
   * **整行徽标**识别（GitHub README 常见形态）：
   * 一行里只有一个或多个徽章图片（可带外链），除此之外没有别的字符。
   * 全部认出返回列表；只要有一个不是徽章 / 混进了普通文字就返回 `null`
   * （保持"行内图片仍作替代文本"的既有约定，不半途改变正文排版）。
   */
  static parseLine(line: string): MdBadge[] | null {
    const src: string = line.trim();
    if (src.length === 0) {
      return null;
    }
    const out: MdBadge[] = [];
    let k: number = 0;
    while (k < src.length) {
      const c: string = src.charAt(k);
      if (c === ' ' || c === '\t') {
        k++;
        continue;
      }
      const hit: BadgeLineHit = Badge.hitAt(src, k);
      if (!hit.hit) {
        return null;
      }
      const spec: MdBadge | null = Badge.parse(hit.src);
      if (spec === null) {
        return null;
      }
      spec.href = hit.href;
      spec.alt = hit.alt;
      out.push(spec);
      k += hit.len;
    }
    return out.length > 0 ? out : null;
  }

  /**
   * `k` 处是不是一个「徽章图片」构造：`![alt](地址)` 或 `[![alt](地址)](链接)`。
   *
   * ⚠️ **不能用正则**：地址里允许**成对括号**——XJAU README 的
   * `badge/HarmonyOS%20NEXT%20(API%2026)-orange` 就是这种写法，
   * 用 `[^)]+` 会在 `(API` 处截断、整行识别失败（实测踩过）。
   * 这里按 Markdown 的口径手工扫描，括号按层数配平。
   */
  private static hitAt(src: string, k: number): BadgeLineHit {
    // ── 形态一：`[![alt](图片地址)](链接地址)` ──
    if (src.startsWith('[![', k)) {
      const altEnd: number = src.indexOf(']', k + 3);
      if (altEnd > 0 && src.charAt(altEnd + 1) === '(') {
        const imgEnd: number = Badge.parenEnd(src, altEnd + 1);
        if (imgEnd > 0 && src.charAt(imgEnd + 1) === ']' && src.charAt(imgEnd + 2) === '(') {
          const linkEnd: number = Badge.parenEnd(src, imgEnd + 2);
          if (linkEnd > 0) {
            const r: BadgeLineHit = {
              hit: true,
              len: linkEnd + 1 - k,
              src: Badge.destOf(src.substring(altEnd + 2, imgEnd)),
              href: Badge.destOf(src.substring(imgEnd + 3, linkEnd)),
              alt: src.substring(k + 3, altEnd)
            };
            return r;
          }
        }
      }
      return missLineHit();
    }
    // ── 形态二：`![alt](图片地址)` ──
    if (src.startsWith('![', k)) {
      const altEnd: number = src.indexOf(']', k + 2);
      if (altEnd > 0 && src.charAt(altEnd + 1) === '(') {
        const imgEnd: number = Badge.parenEnd(src, altEnd + 1);
        if (imgEnd > 0) {
          const r: BadgeLineHit = {
            hit: true,
            len: imgEnd + 1 - k,
            src: Badge.destOf(src.substring(altEnd + 2, imgEnd)),
            href: '',
            alt: src.substring(k + 2, altEnd)
          };
          return r;
        }
      }
    }
    return missLineHit();
  }

  /** `open` 处是 `(`，返回与之配平的 `)` 下标（找不到 / 跨行返回 -1）。 */
  private static parenEnd(src: string, open: number): number {
    let depth: number = 0;
    for (let k: number = open; k < src.length; k++) {
      const c: string = src.charAt(k);
      if (c === '(') {
        depth++;
      } else if (c === ')') {
        depth--;
        if (depth === 0) {
          return k;
        }
      } else if (c === '\n') {
        return -1;
      }
    }
    return -1;
  }

  /** 括号内容 → 地址：去掉首尾空白与 `<…>`，并在**第一个空白处**截断（imsize 那种 `url =120x60`）。 */
  private static destOf(raw: string): string {
    let d: string = raw.trim();
    for (let k: number = 0; k < d.length; k++) {
      const c: string = d.charAt(k);
      if (c === ' ' || c === '\t' || c === '\n') {
        d = d.substring(0, k);
        break;
      }
    }
    if (d.length > 1 && d.charAt(0) === '<' && d.charAt(d.length - 1) === '>') {
      d = d.substring(1, d.length - 1);
    }
    return d;
  }

  /**
   * 整串就是 `![alt](图片地址)` 吗？（**链接文字位置上的图片**：
   * `[![alt](图)](链接)` 的 label 就是这一串——旧实现直接把它当链接文字印出来，
   * 正文里于是出现原始 Markdown）。是则返回 alt 与地址。
   */
  static parseImageOnly(s: string): MdImageInline | null {
    const t: string = s.trim();
    const hit: BadgeLineHit = Badge.hitAt(t, 0);
    if (!hit.hit || hit.href.length > 0 || hit.len !== t.length) {
      return null;
    }
    const r: MdImageInline = { alt: hit.alt, src: hit.src };
    return r;
  }

  /**
   * 把 HTML 片段里所有 `<img src="徽章地址">` **就地**换成离线徽标 HTML。
   *
   * 用在整个 HTML 块上（而不是逐行）：`<p align="center"><a href="…"><img …></a></p>`
   * 这种写法图片不在行首，逐行匹配会漏。非徽章图片原样保留。
   */
  static rewriteHtml(html: string): string {
    if (html.indexOf('shields.io') < 0) {
      return html;                         // 快路径：绝大多数 HTML 块没有徽章
    }
    const re: RegExp = new RegExp('<img\\b[^>]*>', 'gi');
    let out: string = '';
    let cursor: number = 0;
    let m: RegExpExecArray | null = re.exec(html);
    while (m !== null) {
      const tag: string = m[0];
      const spec: MdBadge | null = Badge.parse(Badge.srcOfTag(tag));
      out += html.substring(cursor, m.index);
      out += spec === null ? tag : Badge.toHtml(spec);
      cursor = m.index + tag.length;
      m = re.exec(html);
    }
    out += html.substring(cursor);
    return out;
  }

  /** 从 `<img …>` 标签里取 src（三种引号写法都认）。 */
  private static srcOfTag(tag: string): string {
    const m: RegExpMatchArray | null = tag.match(BADGE_SRC_RE);
    if (m === null) {
      return '';
    }
    if (m[1] !== undefined) {
      return m[1];
    }
    if (m[2] !== undefined) {
      return m[2];
    }
    return m[3] !== undefined ? m[3] : '';
  }

  /**
   * 铭牌 → **纯内联样式**的 HTML 片段（不依赖任何外部 CSS）。
   *
   * 为什么坚持内联样式：这段 HTML 有三个去处——阅读页的 `render/html.html` 预览卡、
   * 导出的整页 HTML（含打印）、EPUB 打包。三处模板各不相同，只有内联样式才能
   * "一次生成、处处相同"（也不必去改三份模板的样式表）。
   */
  static toHtml(badge: MdBadge): string {
    const box: string = Badge.boxStyle(badge.style);
    const seg: string = Badge.segStyle(badge.style);
    const upper: boolean = badge.style === 'for-the-badge';
    let inner: string = '';
    const labelText: string = upper ? badge.label.toUpperCase() : badge.label;
    const msgText: string = upper ? badge.message.toUpperCase() : badge.message;
    if (labelText.length > 0) {
      inner += '<span style="' + seg + 'background:' + badge.labelColor + '">'
        + Badge.escHtml(labelText) + '</span>';
    }
    if (msgText.length > 0) {
      inner += '<span style="' + seg + 'background:' + badge.color + '">'
        + Badge.escHtml(msgText) + '</span>';
    }
    if (inner.length === 0) {
      inner = '<span style="' + seg + 'background:' + badge.color + '">&nbsp;</span>';
    }
    return '<span style="' + box + '">' + inner + '</span>';
  }

  /** 外框样式（各形态的高度 / 圆角 / 字距）。 */
  private static boxStyle(style: string): string {
    const h: number = style === 'for-the-badge' ? 28 : 20;
    const radius: string = style === 'flat-square' || style === 'for-the-badge' ? '0'
      : (style === 'social' ? '10px' : (style === 'plastic' ? '4px' : '3px'));
    const size: number = style === 'for-the-badge' ? 10 : 11;
    const weight: number = style === 'for-the-badge' ? 800 : 700;
    const ls: string = style === 'for-the-badge' ? '1.5px' : '0.2px';
    return 'display:inline-block;box-sizing:border-box;height:' + h + 'px;border-radius:' + radius
      + ';overflow:hidden;vertical-align:middle;white-space:nowrap;color:#fff;'
      + 'font-family:Verdana,Geneva,DejaVu Sans,sans-serif;font-size:' + size + 'px;font-weight:'
      + weight + ';line-height:' + h + 'px;letter-spacing:' + ls + ';';
  }

  /** 单段样式（左右内边距）。 */
  private static segStyle(style: string): string {
    const pad: number = style === 'for-the-badge' ? 10 : (style === 'social' ? 8 : 6);
    return 'display:inline-block;height:100%;padding:0 ' + pad + 'px;';
  }

  // ────────────────────────── 地址解析 ──────────────────────────

  /** 拆出 path 与 query；不是 shields.io 的地址返回 null。 */
  private static splitUrl(urlRaw: string): BadgeUrlParts | null {
    const url: string = urlRaw.trim();
    let rest: string = '';
    if (url.startsWith('https://')) {
      rest = url.substring(8);
    } else if (url.startsWith('http://')) {
      rest = url.substring(7);
    } else {
      return null;
    }
    const slash: number = rest.indexOf('/');
    if (slash <= 0) {
      return null;
    }
    const host: string = rest.substring(0, slash).toLowerCase();
    if (host !== 'img.shields.io' && host !== 'shields.io') {
      return null;
    }
    let tail: string = rest.substring(slash);
    const q: number = tail.indexOf('?');
    const parts: BadgeUrlParts = {
      path: q >= 0 ? tail.substring(0, q) : tail,
      query: q >= 0 ? tail.substring(q + 1) : ''
    };
    return parts;
  }

  /**
   * 从 path（必要时含 query）取"徽章内容"：
   * `/badge/<content>` 与 `/static/v1?label=…&message=…&color=…` 两种入口。
   * 不是这两个入口返回空串。
   */
  private static contentOf(parts: BadgeUrlParts): string {
    const path: string = parts.path;
    if (path.startsWith('/badge/')) {
      let content: string = path.substring(7);
      // 常见后缀 `.svg` / `.png`（`badge/PRs-welcome-brightgreen.svg`）
      const lower: string = content.toLowerCase();
      if (lower.endsWith('.svg')) {
        content = content.substring(0, content.length - 4);
      } else if (lower.endsWith('.png')) {
        content = content.substring(0, content.length - 4);
      }
      return content.trim();
    }
    if (path === '/static/v1' || path === '/static/v1/') {
      const label: string = Badge.queryValue(parts.query, 'label');
      const message: string = Badge.queryValue(parts.query, 'message');
      const color: string = Badge.queryValue(parts.query, 'color');
      if (label.length === 0 && message.length === 0) {
        return '';
      }
      const lc: string = Badge.normalizeColor(color);
      return 'STATIC' + String.fromCharCode(1) + Badge.unescapeText(label)
        + String.fromCharCode(1) + Badge.unescapeText(message)
        + String.fromCharCode(1) + (lc.length > 0 ? lc : '');
    }
    return '';
  }

  /**
   * 徽章内容 → 三段。`/static/v1` 的形态在 contentOf 里已经拼成内部格式
   * （用 \u0001 分隔），这里统一处理。
   */
  private static parseContent(content: string): MdBadgeResult {
    const sep: string = String.fromCharCode(1);
    if (content.startsWith('STATIC' + sep)) {
      const seg: string[] = content.split(sep);
      const r: MdBadgeResult = {
        ok: true,
        label: seg.length > 1 ? seg[1] : '',
        message: seg.length > 2 ? seg[2] : '',
        color: seg.length > 3 && seg[3].length > 0 ? seg[3] : BADGE_DEFAULT_COLOR,
        labelColor: BADGE_DEFAULT_LABEL_COLOR,
        style: 'flat'
      };
      return r;
    }
    const joined: string = Badge.decodeSpaces(content);
    const toks: string[] = Badge.splitTokens(joined);
    const r: MdBadgeResult = missBadge();
    r.labelColor = BADGE_DEFAULT_LABEL_COLOR;
    r.style = 'flat';
    if (toks.length === 2) {
      // shields：`message-color`（label 为空）——第二段必须是颜色，否则官方直接 404。
      // 这里宽容化：不是颜色就按 `label-message + 默认色` 解读（作者意图几乎必然是
      // 「label: message」，`badge/version-1.4.1` 就是这种写法）。
      const c: string = Badge.normalizeColor(toks[1]);
      r.ok = true;
      if (c.length > 0) {
        r.label = '';
        r.message = toks[0];
        r.color = c;
      } else {
        r.label = toks[0];
        r.message = toks[1];
        r.color = BADGE_DEFAULT_COLOR;
      }
      return r;
    }
    if (toks.length === 3) {
      r.ok = true;
      r.label = toks[0];
      r.message = toks[1];
      const c: string = Badge.normalizeColor(toks[2]);
      r.color = c.length > 0 ? c : BADGE_DEFAULT_COLOR;
      return r;
    }
    // 1 段（官方 404）与 4 段以上（官方 404）都不认，交回原路径
    return missBadge();
  }

  /** `%20` → 空格（只做这一项百分号解码；`%2D` 之类极少见，留给作者用 `--`）。 */
  private static decodeSpaces(s: string): string {
    let out: string = s;
    for (let guard: number = 0; guard < 8; guard++) {
      if (out.indexOf('%20') < 0) {
        break;
      }
      out = out.split('%20').join(' ');
    }
    return out;
  }

  /**
   * 按 shields 的转义规则切段：
   *  · `--` = 字面连字符（不切）；`__` = 字面下划线；`_` = 空格。
   * 扫描式实现（不能先 split('-')：那样 `--` 会被切碎）。
   */
  private static splitTokens(s: string): string[] {
    const out: string[] = [];
    let cur: string = '';
    let k: number = 0;
    while (k < s.length) {
      const c: string = s.charAt(k);
      if (c === '-') {
        if (k + 1 < s.length && s.charAt(k + 1) === '-') {
          cur += '-';
          k += 2;
          continue;
        }
        out.push(Badge.unescapeText(cur));
        cur = '';
        k++;
        continue;
      }
      if (c === '_') {
        if (k + 1 < s.length && s.charAt(k + 1) === '_') {
          cur += '_';
          k += 2;
          continue;
        }
        cur += ' ';
        k++;
        continue;
      }
      cur += c;
      k++;
    }
    out.push(Badge.unescapeText(cur));
    return out;
  }

  /** `?a=b&c=d` 取值（键名一律小写比较；值是解码后的原文）。 */
  private static queryValue(query: string, key: string): string {
    if (query.length === 0) {
      return '';
    }
    const pairs: string[] = query.split('&');
    const needle: string = key.toLowerCase();
    for (let k: number = 0; k < pairs.length; k++) {
      const p: string = pairs[k];
      const eq: number = p.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      if (p.substring(0, eq).toLowerCase() === needle) {
        return p.substring(eq + 1);
      }
    }
    return '';
  }

  /**
   * 颜色归一化 → `#RRGGBB`；取不到返回空串。
   * 支持：命名色（上表）/ 3·6 位十六进制 / 8 位（取前 6 位，shields 的 RRGGBBAA）
   * / rgb() 与 rgba()。hsl 不支持（极少见，回落到默认色）。
   */
  static normalizeColor(raw: string): string {
    let s: string = raw.trim().toLowerCase();
    if (s.length === 0) {
      return '';
    }
    if (s.charAt(0) === '#') {
      const hex: string = s.substring(1);
      if (Badge.isHex(hex)) {
        if (hex.length === 3) {
          return ('#' + hex.charAt(0) + hex.charAt(0) + hex.charAt(1) + hex.charAt(1)
            + hex.charAt(2) + hex.charAt(2)).toUpperCase();
        }
        if (hex.length === 4) {
          const r: string = hex.charAt(0);
          const g: string = hex.charAt(1);
          const b: string = hex.charAt(2);
          return ('#' + r + r + g + g + b + b).toUpperCase();
        }
        if (hex.length === 6) {
          return ('#' + hex).toUpperCase();
        }
        if (hex.length === 8) {
          return ('#' + hex.substring(0, 6)).toUpperCase();
        }
        return '';
      }
      return '';
    }
    if (s.startsWith('rgb')) {
      return Badge.parseRgb(s);
    }
    for (let k: number = 0; k < NAMED_COLORS.length; k++) {
      if (NAMED_COLORS[k].name === s) {
        return NAMED_COLORS[k].hex;
      }
    }
    // 三位十六进制没写 `#` 的写法（shields 也认），以及命名色全称里的连字符
    if (Badge.isHex(s) && (s.length === 3 || s.length === 6)) {
      return s.length === 3
        ? ('#' + s.charAt(0) + s.charAt(0) + s.charAt(1) + s.charAt(1)
          + s.charAt(2) + s.charAt(2)).toUpperCase()
        : ('#' + s).toUpperCase();
    }
    return '';
  }

  private static isHex(s: string): boolean {
    if (s.length === 0) {
      return false;
    }
    for (let k: number = 0; k < s.length; k++) {
      const c: string = s.charAt(k);
      const isDigit: boolean = c >= '0' && c <= '9';
      // 大小写都认（`%3C` 这种百分号编码里是大写，漏了会把编码原样印在徽章上）
      const isAf: boolean = (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
      if (!isDigit && !isAf) {
        return false;
      }
    }
    return true;
  }

  /** `rgb(1,2,3)` / `rgba(1,2,3,.5)` / `rgb(1 2 3)` → `#RRGGBB`。 */
  private static parseRgb(s: string): string {
    const open: number = s.indexOf('(');
    const close: number = s.indexOf(')');
    if (open < 0 || close < open) {
      return '';
    }
    const body: string = s.substring(open + 1, close).split(',').join(' ').trim();
    const toks: string[] = body.split(' ');
    const nums: number[] = [];
    for (let k: number = 0; k < toks.length && nums.length < 3; k++) {
      const t: string = toks[k].trim();
      if (t.length === 0) {
        continue;
      }
      const v: number = parseInt(t, 10);
      if (isNaN(v)) {
        continue;
      }
      nums.push(v < 0 ? 0 : (v > 255 ? 255 : v));
    }
    if (nums.length < 3) {
      return '';
    }
    return '#' + Badge.hex2(nums[0]) + Badge.hex2(nums[1]) + Badge.hex2(nums[2]);
  }

  private static hex2(v: number): string {
    const s: string = v.toString(16).toUpperCase();
    return s.length === 1 ? '0' + s : s;
  }

  /** 文本转义（徽章文字里 `&`/`<>` 是作者随便写的）。 */
  private static escHtml(s: string): string {
    let out: string = s.split('&').join('&amp;');
    out = out.split('<').join('&lt;');
    out = out.split('>').join('&gt;');
    out = out.split('"').join('&quot;');
    return out.split(String.fromCharCode(39)).join('&#39;');
  }

  /**
   * 百分号解码（**通用**：`%20`、`%3C`、`%25`… 都要还原，否则
   * `badge/a%3Cb%3E-red` 会把这串编码原样印在徽章上）。
   *
   * 两个**不解码**的例外是分段符本身：`%2D`（连字符）与 `%5F`（下划线）——
   * shields 里这两个字符必须写成 `--` / `__` 来转义，解码出来会把
   * label / message 切错。`%25` 走单趟扫描，不会二次解码（`%2520` → `%20`）。
   */
  private static unescapeText(s: string): string {
    let out: string = '';
    let k: number = 0;
    while (k < s.length) {
      const c: string = s.charAt(k);
      if (c === '%' && k + 3 <= s.length) {
        const hex: string = s.substring(k + 1, k + 3);
        const code: number = parseInt(hex, 16);
        if (!isNaN(code) && Badge.isHex(hex) && hex.toLowerCase() !== '2d'
          && hex.toLowerCase() !== '5f') {
          out += String.fromCharCode(code);
          k += 3;
          continue;
        }
      }
      out += c;
      k++;
    }
    return out;
  }
}

/**
 * `<img …>` 标签里的 src（双引号 / 单引号 / 裸值三种写法）。
 * 用字符串构造：字面量里含引号在 ArkTS 会踩转义坑。
 */
const BADGE_SRC_RE: RegExp =
  new RegExp('src\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))', 'i');
