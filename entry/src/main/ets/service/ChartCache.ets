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
   * 清空三份会话内缓存，让下次查询按磁盘重建。
   * 备份恢复与清缓存后必须调它：memo 里记的是**恢复前**的路径与尺寸，
   * 不清的话界面上还会拿旧条目显示（新导入的 PNG / .dim 明明在盘上却读不到）。
   */
  static invalidate(): void {
    ChartCache.memo.clear();
    ChartCache.uriMemo.clear();
    ChartCache.dimMemo.clear();
  }

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
   *  · v15（2026-10-13 十二次升级）：mermaid 10.9.3→11.4.1（新图种 packet/kanban/architecture）
   *    与 KaTeX 挂载 mhchem 化学扩展——旧引擎时代的错误渲染图（kanban/架构图/数据包图/
   *    化学式的报错 SVG）全部作废，按新引擎重生成。
   *  · v16（2026-10-13 十三次升级）：mermaid 11.4.1→11.17.2（architecture-beta 的中文标签
   *    在旧构建里是词法层直接拒收）。**这条同时是"引擎升级必须升键"的又一例**：缓存键里
   *    没有引擎版本，用户机上就会留着旧引擎烘出来的"Syntax error in text"报错图，
   *    卡片读缓存、放大走实时渲染 → "卡片显示错误、放大后正常"（用户实测）。
   *  · v14（2026-10-11 十一次升级）：跟随公式卡片撤回**键升盐**——v13 那批
   *    "按公式自身尺寸"的 PNG 与 .dim 和撤回后的模板产物尺寸口径不同，
   *    两代混存会让卡片高度忽高忽低，必须一并作废重生成。
   *  · v17（2026-10-13 十四次升级）：修「**空白图能被写进持久缓存**」——卡片快照刻意
   *    烘焙不透明卡片底色，而池子的空白自检只看了 alpha，一片底色 alpha=255 直接过关，
   *    于是"什么都没画出来"的失败快照永久落盘；正文命中缓存键就一直显示同色矩形，
   *    重开文档也不恢复（放大浮层走实时 Web，所以"卡片空白、放大正常"，
   *    用户实测 chart.js「数据可视化卡片上不显示，浅色模式也不显示」正是这一条）。
   *    自检改成"整张同色才算空白"，同时升键把已经躺在用户机上的空白图作废重生成。
   *  · v18（2026-10-14 十五次升级）：mermaid 浅色主题 **neutral → default**（实测时序图
   *    参与者框 neutral 是灰框黑字、default 才是淡紫；用户对比别家渲染说"图表没颜色"）。
   *    主题只改渲染产物、不改缓存键 → 不升键就会出现"卡片还是灰的、放大才有色"，
   *    与 v16 那条"引擎升级必须升键"是同一个坑。
   *  · v19（2026-10-14 十六次升级）：**新增 Vega-Lite 引擎**（vega 6.4.0 + vega-lite 6.5.0，
   *    围栏 ```vega-lite / ```vl，模板 render/vega.html 走 vegaLite.compile → vega.View 出 SVG）。
   *    新引擎本来没有旧缓存，仍按"引擎有变动就升键"的统一口径升一次。
   *  · v20（2026-10-14 十七次升级）：**Chart.js 4.4.7 → 4.5.1**（全库版本巡检里唯一
   *    "小版本可安全升"的一项；升级后浏览器实测 chart.html 仍然正常出图）。
   *    同批巡检结论：KaTeX / markmap / d3 / ECharts / abcjs / Viz.js / WaveDrom /
   *    nomnoml / vega / turndown 都已是最新；mermaid 停 11.17.2（12 实测回归）、
   *    flowchart.js 停 1.17.1（1.18 不再发浏览器包）、MathJax 停 3.2.2（v4 要 API 适配）。
   *  · v21（2026-10-14 十八次升级）：**PlantUML 换成离线内核 @plantuml/core 1.2026.8**
   *    （模板 render/plantuml.html，阅读侧不再桥成 mermaid）。同一份源码在旧键里是
   *    "mermaid 桥出来的图"，新键才是"内核原生图"，不升盐就会**卡片读旧桥图、放大才变**
   *    （v17 那轮 blank 图的同款坑）。
   *  · v22（2026-10-14 十九次升级）：**新增 ZenUML 引擎**（当时走 mermaid 外部图种插件，
   *    模板 render/zenuml.html）。⚠️ 插件路线后来废掉了（真机报 Syntax error，
   *    zenuml.html 与 3.14MB 插件已从包里删，现在由 ZenumlBridge 在解析层转成 mermaid 时序图），
   *    这条盐只是当时的记录。
   *  · v23（2026-10-14 二十次升级）：**PlantUML 内核模板由 ES module 改成普通脚本**。
   *    module 版在真机上整族画不出（用例/活动/组件/部署/mindmap/WBS/甘特/JSON/YAML/
   *    Archimate/ER），而失败态的**错误文字会被预渲染池烘成 PNG**（"PlantUML 引擎未就绪"
   *    那张红字卡），键不升就会一直拿那张坏卡当缓存图显示——修好了也看不见。
   */
  static keyFor(mode: string, payload: string, dark: boolean, bg: string = ''): string {
    return ChartCache.hashOf('v23|' + bg + '|' + mode + '|' + (dark ? 'd' : 'l') + '|' + payload);
  }

  private static hashOf(raw: string): string {
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
      return raw.length.toString(16);
    }
  }

  /**
   * **payload 索引**（导出反查用）：池子每烘成一张图，就登记
   * `md5(mode|payload) → 实际缓存 key`。
   * key 里混着 bg 与深浅位，导出侧拿不到渲染当时的准确组合 —— 有了这份索引，
   * 导出只凭 (mode, payload) 就能反查到图（用户实测：bg 对不上时导出全是代码块）。
   */
  static rememberPayloadKey(ctx: common.UIAbilityContext, mode: string, payload: string, key: string): void {
    try {
      const dir: string = ctx.cacheDir + '/charts/payload';
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const p: string = dir + '/' + ChartCache.hashOf(mode + '|' + payload) + '.txt';
      const file: fs.File = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, key);
      fs.closeSync(file);
    } catch (err) {
      // 索引写失败不影响缓存本体
    }
  }

  /** payload 索引反查：拿到该 (mode, payload) 实际落盘的缓存 key（没有返回空串）。 */
  static payloadKey(ctx: common.UIAbilityContext, mode: string, payload: string): string {
    try {
      const p: string = ctx.cacheDir + '/charts/payload/'
        + ChartCache.hashOf(mode + '|' + payload) + '.txt';
      if (!fs.accessSync(p)) {
        return '';
      }
      const file: fs.File = fs.openSync(p, fs.OpenMode.READ_ONLY);
      let key: string = '';
      try {
        const buf: ArrayBuffer = new ArrayBuffer(128);
        const n: number = fs.readSync(file.fd, buf);
        if (n > 0) {
          key = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, n)).trim();
        }
      } finally {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
        }
      }
      return key;
    } catch (err) {
      return '';
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
  /**
   * 导出用：把阅读页预渲染池**已烘好的缓存 PNG**读成 base64 dataURL。
   * 深浅两个 key 都试（导出时的主题与渲染时不一定一致）。都没有返回空串。
   */
  static pngBase64(ctx: common.UIAbilityContext, mode: string, payload: string,
    dark: boolean, bg: string): string {
    // 先按 (dark, bg) 组合直查；miss 再走 payload 索引反查（bg/深浅对不上也能命中）
    const idxKey: string = ChartCache.payloadKey(ctx, mode, payload);
    const variants: string[] = [];
    const ds: boolean[] = dark ? [true, false] : [false, true];
    for (let k = 0; k < ds.length; k++) {
      variants.push(ChartCache.keyFor(mode, payload, ds[k], bg));
    }
    if (idxKey.length > 0) {
      variants.push(idxKey);
    }
    for (let k = 0; k < variants.length; k++) {
      const key: string = variants[k];
      const path: string = ChartCache.srcPath(ctx, key);
      if (path.length === 0) {
        continue;
      }
      try {
        const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
        let dataUrl: string = '';
        try {
          const stat: fs.Stat = fs.statSync(path);
          const buf: ArrayBuffer = new ArrayBuffer(stat.size);
          const n: number = fs.readSync(file.fd, buf);
          if (n > 0) {
            const b64: string = new util.Base64Helper()
              .encodeToStringSync(new Uint8Array(buf, 0, n));
            dataUrl = 'data:image/png;base64,' + b64;
          }
        } finally {
          try {
            fs.closeSync(file);
          } catch (closeErr) {
          }
        }
        if (dataUrl.length > 0) {
          return dataUrl;
        }
      } catch (err) {
        // 读失败 → 试下一个变体
      }
    }
    return '';
  }

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
