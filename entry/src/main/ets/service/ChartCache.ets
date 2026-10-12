/**
 * 澄笺 · 图表渲染结果磁盘缓存
 * ============================
 *
 * 公式 / 图表块在阅读页由 DiagramWeb（Web 组件）实时渲染——有三个代价：
 * 滑到位置才加载、每次打开都重渲、**导出快照无法捕获 Web 表面**。
 *
 * 本服务把渲染产物（PixelMap → PNG）按内容哈希写入 `<cacheDir>/charts/`：
 *   · 键 = md5(mode | 深浅 | 源码)——内容或主题变了自动换新键，天然失效；
 *   · 正文的 mathView / chartView 优先用缓存图（Image），没有才回落 DiagramWeb；
 *   · 后台预渲染池（ChartRenderPool）在打开文件时逐个补齐缓存。
 */

import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';

export class ChartCache {
  /** 键 → 路径 的会话内缓存（含「无缓存」的空串），避免每次渲染都 accessSync */
  private static memo: Map<string, string> = new Map();
  /** 键 → **Image/ImageSpan 可用源**（`file://` 前缀）的会话内缓存 */
  private static uriMemo: Map<string, string> = new Map();
  /** 键 → 'w|h'（**逻辑尺寸** = 期望显示的 vp 值）的会话内缓存 */
  private static dimMemo: Map<string, string> = new Map();

  /**
   * 内容哈希：mode | 深浅 | **卡片底色** | 源码 → md5 hex。同步实现（输入都是小文本）。
   *
   * **键盐代际**（历史包袱的教训，别再往回调）：
   *  · v2（首轮快照管线修复）：清掉"快照竞速"可能存下的空白图；
   *  · v3（2026-10-10 二度升级）：清掉"快照黑底"图（webPageSnapshot 不含
   *    alpha，透明被合成成黑——块级公式显示黑块）与"无尺寸 sidecar"的行内图。
   *  · v4（2026-10-10 三度升级）：键里加入**卡片底色 bg**——块级图的页面底色
   *    就是 codeBlockBg，而五档主题的深色孪生款（Sepia/Green）底色是暖棕/墨绿，
   *    旧键只有 dark 布尔 → 换深色主题后复用别主题烘焙的图 = **"深色下背景发红/发绿"**
   *   （用户实测）。
   *  · v5（2026-10-10 四度升级）：修**烘焙底色被 CSS 误解析**——cardBg 以项目
   *    #AARRGGBB 格式直接进 CSS，被按 #RRGGBBAA 解析成 10% 红罩，烘焙出的
   *    PNG 全部带暗红底（用户实测截图实锤）。DiagramWeb 现已转 rgba() 再进页面，
   *    键升盐让带红罩的旧图全部失效重生成。
   *  · v6（2026-10-11 五度升级）：修**快照高度上限 1200 截断高图**——类图/大型
   *    流程图在整窗宽下烘焙高度超限，PNG 被拦腰截断、显示端当完整图展示
   *    （用户实测"类图显示不完整"）。块级图上限提到 4096，键升盐让截断旧图失效。
   *  · v7（2026-10-11 六度升级）：块级公式改**品红底拍摄 + 键控抠透明**——
   *    公式卡片挂沉浸光感承载层，透明图让材质透出（不透明烘焙底会盖住材质）。
   *  · v8（2026-10-11 七度升级）：①键控改**预乘写法**；②图表模板页应用卡片底色
   *    （o.bg，修浅色图表卡黑背景）。
   *  · v9（2026-10-11 八度升级）：**公式键控透明方案整体回退**——真机上透明 PNG
   *    在 Image 组件里渲染不可靠（卡片全黑），公式恢复烘焙卡片底色不透明图。
   *  · v10（2026-10-11 九度升级）：markmap 高度回传改**画布实际高度**——此前
   *    scrollHeight 被 svg 内部尺寸虚高，脑图快照成"上方一条 + 下方空白"、
   *    卡片按虚高拉满（用户实测"显示面积异常"）。键升盐作废虚高期脑图缓存。
   *  · v11～v12：放大浮层画布形态与模板统一（markmap-card 一份模板管两种形态）。
   *  · v13（2026-10-11 十度升级）：修**超宽公式快照被裁断**——katex 块级路径此前是
   *    `#app{overflow:auto}`，#app 自己吞掉溢出，文档宽度恒等于视口宽
   *    （实测 2195px 的公式 documentElement.scrollWidth 仍只有 617），整页快照
   *    只拍得到左边一截 → 烘焙出的 PNG 天生缺一段，卡片里怎么滑都补不回来
   *    （用户实测"部分内容被裁切显示不完全"）。当时改为溢出可见 + body max-content；
   *    ⚠️ 但这批改动让用户实测更差（卡片被拉得一屏长、有的公式内容反而变小），
   *    已**整体撤回**，katex.html 恢复原状。
   *  · v14（2026-10-11 十一次升级）：跟随公式卡片撤回**键升盐**——v13 那批
   *    "按公式自身尺寸"的 PNG 与 .dim 和撤回后的模板产物尺寸口径不同，
   *    两代混存会让卡片高度忽高忽低，必须一并作废重生成。
   */
  static keyFor(mode: string, payload: string, dark: boolean, bg: string = ''): string {
    const raw: string = 'v14|' + bg + '|' + mode + '|' + (dark ? 'd' : 'l') + '|' + payload;
    try {
      const encoder: util.TextEncoder = new util.TextEncoder();
      const md: cryptoFramework.Md = cryptoFramework.createMd('MD5');
      md.updateSync({ data: encoder.encodeInto(raw) });
      const digest: cryptoFramework.DataBlob = md.digestSync();
      let hex: string = '';
      for (let k = 0; k < digest.data.length; k++) {
        const v: number = digest.data[k];
        hex += (v < 16 ? '0' : '') + v.toString(16);
      }
      return hex;
    } catch (err) {
      // 哈希失败退到简易摘要（几乎不会发生）
      return 'h' + (mode.length * 31 + payload.length * 17 + (dark ? 7 : 0)).toString(16);
    }
  }

  /** 已缓存的图表图片路径；无缓存返回空串（结果记入 memo）。 */
  static path(ctx: common.UIAbilityContext, key: string): string {
    const hit: string | undefined = ChartCache.memo.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const p: string = ctx.cacheDir + '/charts/' + key + '.png';
    let found: string = '';
    try {
      if (fs.accessSync(p)) {
        found = p;
      }
    } catch (err) {
      found = '';
    }
    ChartCache.memo.set(key, found);
    return found;
  }

  /**
   * **行内公式图的缓存键**（v3：MathJax 光栅化的紧凑公式图）。
   *
   * 与旧键（`iminl2_` = 快照裁出的整页图）区分；**含字号**：公式图按正文
   * 字号排版，用户改字号后应重新生成（旧实现没有字号维度，公式大小不随
   * 正文字号联动——顺带修复）。
   */
  static inlineKey(latex: string, dark: boolean, size: number): string {
    return 'iminl3_' + ChartCache.keyFor('katex', size + '|' + latex, dark);
  }

  /**
   * 记录"逻辑尺寸"（生成端按正文字号排版后回传的设计尺寸）。
   *
   * ⚠️ 为什么必须有：PNG 是"逻辑尺寸 × 屏幕密度"的高清像素（保清晰度）。
   * 显示端 Image/ImageSpan 对图片像素的默认换算不可依赖（实测像素被 1:1
   * 当 vp 用 → 图放大 density 倍——用户实测"公式渲染放大这么大"）。
   * 显示时**显式**把宽高设为这里的逻辑尺寸（vp），尺寸精确、像素仍高清。
   */
  static setDim(key: string, w: number, h: number): void {
    if (w > 0 && h > 0) {
      ChartCache.dimMemo.set(key, Math.round(w) + '|' + Math.round(h));
    }
  }

  /** 读取逻辑尺寸（'w|h'；无记录返回空串）。会话内走内存，重启后读 sidecar。 */
  static dimOf(ctx: common.UIAbilityContext, key: string): string {
    const hit: string | undefined = ChartCache.dimMemo.get(key);
    if (hit !== undefined) {
      return hit;
    }
    let v: string = '';
    try {
      const p: string = ctx.cacheDir + '/charts/' + key + '.dim';
      if (fs.accessSync(p)) {
        const file: fs.File = fs.openSync(p, fs.OpenMode.READ_ONLY);
        try {
          const buf: ArrayBuffer = new ArrayBuffer(64);
          const n: number = fs.readSync(file.fd, buf);
          if (n > 0) {
            v = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, n)).trim();
          }
        } finally {
          try {
            fs.closeSync(file);
          } catch (closeErr) {
            // 关闭失败无副作用
          }
        }
      }
    } catch (err) {
      v = '';
    }
    ChartCache.dimMemo.set(key, v);
    return v;
  }

  /**
   * 行内公式图落盘：PNG dataURL（base64）→ 文件 + memo 更新 + 逻辑尺寸 sidecar。
   *
   * 与 `save()`（PixelMap 打包）的区别：那个走 image packer（快照链路），
   * 这个直接写字节（MathJax 光栅化链路回传的就是 PNG base64）。
   */
  static savePngBase64(ctx: common.UIAbilityContext, key: string, dataUrl: string,
                       w: number, h: number): boolean {
    try {
      const comma: number = dataUrl.indexOf(',');
      if (comma < 0) {
        return false;
      }
      const bytes: Uint8Array =
        new util.Base64Helper().decodeSync(dataUrl.substring(comma + 1));
      if (bytes.length < 32) {
        return false;
      }
      const dir: string = ctx.cacheDir + '/charts';
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const p: string = dir + '/' + key + '.png';
      const file: fs.File = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes.buffer as ArrayBuffer);
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
      ChartCache.memo.set(key, p);
      ChartCache.uriMemo.set(key, 'file://' + p);
      // 逻辑尺寸：内存 + sidecar（重启后显示端仍能取到，不必反推像素/密度）
      if (w > 0 && h > 0) {
        const dim: string = Math.round(w) + '|' + Math.round(h);
        ChartCache.dimMemo.set(key, dim);
        try {
          const dp: string = dir + '/' + key + '.dim';
          const df: fs.File = fs.openSync(dp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          try {
            fs.writeSync(df.fd, new util.TextEncoder().encodeInto(dim).buffer as ArrayBuffer);
          } finally {
            try {
              fs.closeSync(df);
            } catch (e2) {
              // 关闭失败无副作用
            }
          }
        } catch (err2) {
          // sidecar 写失败：内存仍有效（本次会话）；重启后回退自然尺寸
        }
      }
      return true;
    } catch (err) {
      return false;
    }
  }

  /**
   * 缓存图 → **Image / ImageSpan 组件可用的源**（`file://` 前缀）。
   *
   * ⚠️ 为什么必须单独有它（2026-10-10 用户实测"全部空白"的直接根因）：
   * Image / ImageSpan 传入**裸沙箱路径**时**加载失败且静默空白**——官方 FAQ：
   * string 路径要么带 `file:///` 前缀、要么用 `fileUri.getUriFromPath` 转 URI；
   * 项目的 `DocStore.resolveImagePath`（封面 / 正文插图，一直显示正常）也正是
   * 先拼了 `file://` 才交给 Image。而此前的 ChartCache.path 返回裸路径直接喂给
   * Image/ImageSpan —— 公式/图表缓存图**第一次真正批量生成**后（后台池修复后），
   * 所有切到图片的位置全部空白。文件系统读写（EpubExport 读字节等）仍用
   * `path()` 的裸路径，两者不可互相替换。
   */
  static srcPath(ctx: common.UIAbilityContext, key: string): string {
    const hit: string | undefined = ChartCache.uriMemo.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const p: string = ChartCache.path(ctx, key);
    const uri: string = p.length > 0 ? 'file://' + p : '';
    ChartCache.uriMemo.set(key, uri);
    return uri;
  }

  /**
   * 把渲染完成的 PixelMap 存成 PNG 并登记。失败返回空串。
   *
   * w/h（可选）：页面的**逻辑尺寸**（css px = vp，DiagramWeb 的 postWidth/Height
   * 回传值）。传入时写 `<key>.dim` sidecar——显示端据此**按自然尺寸 + 横向滚动**
   * 展示超宽公式（"卡片内左右滑动、不限制大小"），不再被 objectFit.Contain
   * 压扁成"全部重叠到一起"（用户实测）。
   */
  static async save(ctx: common.UIAbilityContext, key: string, pixel: image.PixelMap,
                    w: number = 0, h: number = 0): Promise<string> {
    try {
      const dir: string = ctx.cacheDir + '/charts';
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const packer: image.ImagePacker = image.createImagePacker();
      const bytes: ArrayBuffer = await packer.packToData(pixel, { format: 'image/png', quality: 100 });
      const p: string = dir + '/' + key + '.png';
      const file: fs.File = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes);
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          // 关闭失败无副作用
        }
      }
      ChartCache.memo.set(key, p);
      // **同步刷新 URI 缓存**：图就绪前若已查询过 srcPath（缓存里是空串），
      // 这里必须换新——否则图生成了、组件仍拿到空源（持续空白）
      ChartCache.uriMemo.set(key, 'file://' + p);
      // 逻辑尺寸 sidecar（与 savePngBase64 同款；重启后显示端仍能取到）
      if (w > 0 && h > 0) {
        ChartCache.setDim(key, w, h);
        try {
          const dim: string = Math.round(w) + '|' + Math.round(h);
          const dp: string = dir + '/' + key + '.dim';
          const df: fs.File = fs.openSync(dp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          try {
            fs.writeSync(df.fd, new util.TextEncoder().encodeInto(dim).buffer as ArrayBuffer);
          } finally {
            try {
              fs.closeSync(df);
            } catch (e2) {
              // sidecar 写失败：内存仍有效（本次会话）
            }
          }
        } catch (err2) {
          // 忽略
        }
      }
      return p;
    } catch (err) {
      return '';
    }
  }
}
