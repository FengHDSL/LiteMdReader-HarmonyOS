/**
 * 澄笺 · AI 对话页（1.2.0）
 * ==========================
 *
 * 与正常 AI 对话界面一致的聊天页：
 *   · 悬浮顶栏（与其他页面同款）：返回 + 标题 + 新话题 + 历史 + 设置；
 *   · 消息流：用户右侧主题色气泡 / AI 左侧卡片气泡，长按可复制；
 *   · 输入区：模型切换 + 思考强度 + 附件（应用内文档 / 本地文件 / 相册图片）；
 *   · 未配置接口时中央引导卡「去配置」。
 *
 * 上下文来源（AppStorage 信号，进入本页消费一次）：
 *   · aiChatDocName   —— 携带的应用内文档名（阅读页 / 编辑页进入时设置）；
 *   · aiChatDocContent —— 文档原文（编辑页未保存内容直传；空则按文档名现读）；
 *   · aiChatQuote     —— 长按选择条「发送AI」带来的选中文本。
 * 首条消息发送时把文档正文作为独立 system 注入（AiChatStore 负责），此后不再重复。
 *
 * 会话历史持久化在 filesDir/ai/sessions/（AiChatStore）。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { inputMethod } from '@kit.IMEKit';
import { picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { util } from '@kit.ArkTS';
import { display, KeyboardAvoidMode } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  HwBar, HwFont, HwRadius, HwSpace, HwType, ReaderPalette, paletteFor, isDarkTheme, ReaderThemeMode,
  withAlpha
} from '../theme/DesignTokens';
import { ImmersiveBar, ImmersiveCard, ImmersiveChip, ImmersiveIconButton, ImmersiveSheetPanel } from '../material/ImmersiveCard';
import { modalSheetOptions, SheetKeyboardLift } from '../material/ModalSheet';
import { GenWallpaper } from '../theme/GenWallpaper';
import { WallpaperStore } from '../service/WallpaperStore';
import { WallpaperImage } from '../components/WallpaperImage';
import { DocMeta, DocStore, ReaderRoute } from '../service/DocStore';
import {
  AiChatStore, AiChatConfig, AiChatMessage, AiChatResult, AiChatSession,
  AiChatSessionBrief, AiDocGenResult, AiApiProfile, AI_QUOTE_LIMIT
} from '../service/AiChatStore';
import { MdParser } from '../markdown/MdParser';
import { MdBlock } from '../markdown/MdTypes';
import { MdBlockView } from '../markdown/MdView';
import { InlineFormulaPool } from '../components/InlineFormulaPool';
import { FormulaTask, FormulaTasks } from '../markdown/FormulaTasks';
import { DiagramWeb } from '../components/DiagramWeb';
import { L10n } from '../service/L10n';
import { AppearanceFx } from '../service/AppearanceFx';

/**
 * 外部文件附件（大文件分批上传用）：
 * `content` 非空 = 选择时已整份读入（小文件，一次请求发完）；
 * `content` 为空 = 大文件，只记 uri + size，发送时按块从磁盘流式读取。
 */
interface AiAttachFile {
  name: string;
  uri: string;
  /** 字节数（content 非空时也填，用于体积提示） */
  size: number;
  content: string;
}

/** 分批上传的一批（懒读盘：轮到这一批才从磁盘读这段字节） */
interface AiBatchStep {
  /** 展示用标签，如「README.md 第 3/12 批」 */
  label: string;
  uri: string;
  /** 起始字节 */
  start: number;
  /** 本批字节数 */
  len: number;
  /** 是否为最后一批（末批带收尾说明） */
  last: boolean;
}

/** 内联读取阈值：≤ 此大小在选择时整份读入 */
const FILE_INLINE_LIMIT: number = 128 * 1024;
/** 分批上传每批字节数（按字节切块，避免单次请求体过大） */
const FILE_CHUNK_SIZE: number = 192 * 1024;
/** 分批上限（保护：误选超大文件时不会发出上千次请求） */
const FILE_MAX_BATCHES: number = 400;

/** 毫秒 → 'MM-DD HH:mm'（历史面板用） */
function fmtTime(ms: number): string {
  const d: Date = new Date(ms);
  const mo: string = (d.getMonth() + 1) < 10 ? '0' + (d.getMonth() + 1) : '' + (d.getMonth() + 1);
  const da: string = d.getDate() < 10 ? '0' + d.getDate() : '' + d.getDate();
  const h: string = d.getHours() < 10 ? '0' + d.getHours() : '' + d.getHours();
  const mi: string = d.getMinutes() < 10 ? '0' + d.getMinutes() : '' + d.getMinutes();
  return mo + '-' + da + ' ' + h + ':' + mi;
}

/** 图片 dataURL 的 mime 猜测（按 uri 后缀；猜不出默认 jpeg） */
function imageMime(uri: string): string {
  const low: string = uri.toLowerCase();
  if (low.endsWith('.png')) {
    return 'image/png';
  }
  if (low.endsWith('.webp')) {
    return 'image/webp';
  }
  if (low.endsWith('.gif')) {
    return 'image/gif';
  }
  return 'image/jpeg';
}

// ── 文档生成协议（<doc name="x">…</doc>，与 AiChatStore 注入的约定严格成对）──

interface AiDocSeg {
  isDoc: boolean;
  name: string;
  text: string;
}

/** 拆分回复中的文档标记；未闭合 / 转义不完整时按普通文本处理 */
function splitDocSegs(content: string): AiDocSeg[] {
  const out: AiDocSeg[] = [];
  const openTag: string = '<doc name="';
  const closeTag: string = '</doc>';
  let pos: number = 0;
  while (pos <= content.length) {
    const o: number = content.indexOf(openTag, pos);
    if (o < 0) {
      break;
    }
    const nStart: number = o + openTag.length;
    const nEnd: number = content.indexOf('"', nStart);
    if (nEnd < 0) {
      break;
    }
    const gt: number = content.indexOf('>', nEnd);
    if (gt < 0) {
      break;
    }
    const cAt: number = content.indexOf(closeTag, gt + 1);
    if (cAt < 0) {
      break;
    }
    if (o > pos) {
      out.push({ isDoc: false, name: '', text: content.substring(pos, o) });
    }
    out.push({ isDoc: true, name: content.substring(nStart, nEnd), text: content.substring(gt + 1, cAt) });
    pos = cAt + closeTag.length;
  }
  if (pos < content.length) {
    out.push({ isDoc: false, name: '', text: content.substring(pos) });
  }
  return out;
}

/** 快照文件名的时间戳（M-D HHmm） */
function snapStamp(): string {
  const d: Date = new Date();
  const mm: number = d.getMinutes();
  return '' + (d.getMonth() + 1) + '-' + d.getDate() + ' ' + d.getHours() + ':' + (mm < 10 ? '0' : '') + mm;
}

/**
 * 把回复里的 <doc> 标记落盘成真实文档（DocStore.create 同名自动编号，不覆盖既有文档），
 * 返回替换后的展示文本与实际创建的文档名列表。
 * 同名协议：AI 输出的文档名撞书架已有文档 = 「修改」——
 *   只读（含内置）→ 不动原文，修改版另存新文档；
 *   可写自建 → 原版先落一份快照到书架（回退入口），再覆写原文。
 */
function materializeDocs(reply: string, ctx: common.UIAbilityContext | null): AiDocGenResult {
  const names: string[] = [];
  if (reply.indexOf('<doc name="') < 0) {
    const none: AiDocGenResult = { text: reply, names: names };
    return none;
  }
  const segs: AiDocSeg[] = splitDocSegs(reply);
  let out: string = '';
  for (let i = 0; i < segs.length; i++) {
    const seg: AiDocSeg = segs[i];
    if (!seg.isDoc) {
      out += seg.text;
      continue;
    }
    let docName: string = seg.name.trim();
    if (docName.toLowerCase().endsWith('.md')) {
      docName = docName.substring(0, docName.length - 3);
    }
    if (docName.length > 40) {
      docName = docName.substring(0, 40);
    }
    if (docName.length === 0) {
      docName = 'AI 文档';
    }
    if (ctx === null) {
      // 拿不到上下文：只做文本替换，不落盘
      names.push(docName);
      out += '\n\n〔已生成文档《' + docName + '》，已保存到书架〕\n\n' + seg.text;
      continue;
    }
    const existing: DocMeta | undefined = DocStore.find(ctx, docName);
    if (existing === undefined) {
      // 新文档：直接创建（撞名时 create 自动编号，不覆盖）
      const meta: DocMeta | null = DocStore.create(ctx, docName, seg.text);
      const finalName: string = meta !== null ? meta.name : docName;
      names.push(finalName);
      out += '\n\n〔已生成文档《' + finalName + '》，已保存到书架〕\n\n' + seg.text;
    } else if (DocStore.isReadOnly(ctx, docName)) {
      // **只读防护**（含内置教程）：AI 不得改动原文，修改版一律另存新文档
      const meta: DocMeta | null = DocStore.create(ctx, docName + ' 修改版', seg.text);
      const finalName: string = meta !== null ? meta.name : docName + ' 修改版';
      names.push(finalName);
      out += '\n\n〔《' + docName + '》是只读文档，不能改动原文；修改版已另存为《' + finalName + '》〕\n\n' + seg.text;
    } else {
      // 可写自建文档：原版先落一份快照到书架（回退入口），再覆写原文
      const snapName: string = docName + ' · 快照 ' + snapStamp();
      DocStore.create(ctx, snapName, DocStore.readText(ctx, existing));
      if (DocStore.update(ctx, docName, seg.text)) {
        names.push(docName);
        out += '\n\n〔已修改文档《' + docName + '》；原版快照《' + snapName + '》已存入书架，打开即可回退〕\n\n' + seg.text;
      } else {
        const meta: DocMeta | null = DocStore.create(ctx, docName + ' 修改版', seg.text);
        const finalName: string = meta !== null ? meta.name : docName + ' 修改版';
        names.push(finalName);
        out += '\n\n〔文档《' + docName + '》写入失败，修改内容已另存为《' + finalName + '》〕\n\n' + seg.text;
      }
    }
  }
  const r: AiDocGenResult = { text: out, names: names };
  return r;
}

/** 词元数展示：过万缩写成 k */
function fmtTokens(n: number): string {
  if (n >= 10000) {
    return '' + (Math.round(n / 100) / 10) + 'k';
  }
  return '' + n;
}

/** 消息时间标注：M-D HH:mm */
function fmtMsgTime(ts: number): string {
  const d: Date = new Date(ts);
  const hh: string = '' + d.getHours();
  const mi: string = '' + d.getMinutes();
  return (d.getMonth() + 1) + '-' + d.getDate()
    + ' ' + (hh.length < 2 ? '0' + hh : hh) + ':' + (mi.length < 2 ? '0' + mi : mi);
}

/** 侧边栏历史分组（按日期：今天 / 昨天 / 近 7 天 / 更早） */
interface AiDrawerGroup {
  label: string;
  items: AiChatSessionBrief[];
}

/** 空态问候语（按时段） */
function greetWord(): string {
  const h: number = new Date().getHours();
  if (h >= 5 && h < 11) {
    return '上午好';
  }
  if (h >= 11 && h < 18) {
    return '下午好';
  }
  if (h >= 18 && h < 23) {
    return '晚上好';
  }
  return '夜深了';
}

/** 空态大标语（按时段选一条） */
function greetSlogan(): string {
  const h: number = new Date().getHours();
  if (h >= 5 && h < 11) {
    return '新的一天，从一个小问题开始';
  }
  if (h >= 11 && h < 18) {
    return '午后灵感，正适合聊点什么';
  }
  if (h >= 18 && h < 23) {
    return '夜色正好，想到什么就聊聊';
  }
  return '夜再深，我也在线';
}

/** 从消息内容提炼文档名（取第一条可读文本行，去 Markdown 记号） */
function deriveDocName(text: string): string {
  const lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length && i < 8; i++) {
    let l: string = lines[i].trim();
    while (l.length > 0 && (l.charAt(0) === '#' || l.charAt(0) === '>' || l.charAt(0) === '-'
      || l.charAt(0) === '*' || l.charAt(0) === ' ')) {
      l = l.substring(1).trim();
    }
    if (l.length >= 2) {
      if (l.length > 20) {
        l = l.substring(0, 20);
      }
      return l;
    }
  }
  const d: Date = new Date();
  const pad = (n: number): string => n < 10 ? '0' + n : '' + n;
  return 'AI笔记 ' + (d.getMonth() + 1) + '-' + d.getDate() + ' '
    + pad(d.getHours()) + pad(d.getMinutes());
}

@Component
export struct AiChat {
  stack: NavPathStack | null = null;
  /** 主题档位 / 系统深浅都直接挂本页重建（与阅读页同一套：不依赖别页先应用） */
  @StorageLink('readerThemeMode') @Watch('onThemeTick') themeMode: number = ReaderThemeMode.System;
  /** 回答正文的字体族（MdBlockView 靠 @Prop 收，子组件自读 AppStorage 不回刷） */
  @StorageLink('readerFontFamily') bodyFontKey: string = '';
  @StorageProp('systemDark') @Watch('onThemeTick') systemDark: boolean = false;
  /** **界面字体**（外观设置 → 界面字体）：本页界面文字都从这里取 */
  @StorageProp('appFontFamily') uiFontKey: string = '';
  /** 界面字号缩放系数 / 界面字重相对加粗量（外观设置） */
  @StorageProp('appFontScale') uiFontScale: number = 1;
  @StorageProp('appFontWeightDelta') uiFontWeightDelta: number = 0;
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  @StorageProp('safeBottomPx') safeBottomPx: number = 0;
  @StorageProp('appearanceTick') @Watch('onThemeTick') appearanceTick: number = 0;
  /**
   * 配置纪元（设置页保存后自增）：从 AI 设置返回时重新装载配置，
   * 否则对话页仍按旧配置判定「未配置」，得退出重进才生效（用户反馈）。
   */
  /**
   * 配置纪元（设置页保存后自增）：从 AI 设置返回时重新装载配置，
   * 否则对话页仍按旧配置判定「未配置」，得退出重进才生效（用户反馈）。
   */
  @StorageProp('aiCfgTick') @Watch('onCfgTick') cfgTick: number = 0;
  /** 根容器上一帧高度（键盘收缩期间逐帧钉底用） */
  private lastRootH: number = 0;
  /** 上一次「输入区顶边高度」（rootH − inputH）——列表滚动位置跟随它 */
  private lastSpace: number = 0;
  /** 列表是否贴在底部（onScrollIndex 维护；键盘/面板收起时防双重补偿） */
  private listAtBottom: boolean = false;

  /**
   * **列表跟随输入区顶边**（统一模型）：可用空间（rootH − inputH）变化 Δ →
   * 滚动位置补偿 −Δ，**上移 / 下移用同一条动画**（250ms 缓出，速度一致）。
   *
   * ⚠️ **贴底时的收起方向必须特殊处理**（用户实测「页面下移」）：空间变大时
   * 系统会先把偏移**钳制**到新底部（cur 已是收起后的底部位置），此时再减 Δ
   * 就是双重补偿 → 页面多降一截。贴底时收起方向保持 cur 即可。
   * ⚠️ currentOffset() 可能返回 undefined（项目有崩溃前科），必须判空。
   */
  private syncListToSpace(): void {
    const space: number = this.lastRootH - this.inputH;
    if (this.lastSpace === 0) {
      this.lastSpace = space;
      return;
    }
    const delta: number = space - this.lastSpace;
    if (Math.abs(delta) < 0.5) {
      return;
    }
    this.lastSpace = space;
    try {
      const cur = this.listScroller.currentOffset();
      if (cur === undefined || cur === null || cur.yOffset === undefined) {
        return;
      }
      let target: number = Number(cur.yOffset) - delta;
      if (delta > 0 && this.listAtBottom) {
        // 空间变大且原本贴底：系统钳制已把列表放到新底部，保持即可
        target = Number(cur.yOffset);
      }
      this.listScroller.scrollTo({
        xOffset: 0,
        yOffset: target > 0 ? target : 0,
        // **上移 / 下移同一条动画**（用户要求：速度保持一致，不要不一样）
        animation: { duration: 250, curve: Curve.FastOutSlowIn }
      });
    } catch (err) {
      // 忽略
    }
  }
  // ── 图表放大浮层（与阅读页同一套观感）──
  @State chartOpen: boolean = false;
  /** 语言切换计数：变更时整页重建（key 拼接），文案随词典刷新 */
  @StorageProp('languageTick') languageTick: number = 0;
  @State chartMode: string = 'mermaid';
  @State chartPayload: string = '';
  @State chartTitle: string = '';
  @State chartZoom: number = 1;
  @State chartRefitTick: number = 0;
  /**
   * 外观 / 主题纪元：变更时换**消息列表容器 key** → 已挂载的 Markdown 气泡整批重建。
   * 不换 key 时条目被复用，深浅切换后气泡里的文字会停在旧主题（深底深字看不清，
   * 用户实测；与阅读页正文同一条铁律）。
   */
  @State themeEpoch: number = 0;
  /** 行内公式图任务（气泡里的 $公式$ 与阅读页同款出图） */
  @State formulaTasks: FormulaTask[] = [];
  /** 公式图就绪信号（递增 → 气泡条目 key 重算 → 换成图） */
  @State formulaTick: number = 0;
  /** 已关闭的渲染引擎（设置 → 引擎管理）：MathJax 关闭期间公式回落文字，开关后重收任务 */
  @StorageProp('disabledEngines') @Watch('onEnginesChanged') disabledEngineList: string = '';
  /** 最近一次已应用的深浅（相同则跳过重建，切换更跟手） */
  private lastThemeValid: boolean = false;
  private lastThemeDark: boolean = false;

  // ── 背景（与书架同一优先级）──
  @StorageProp('wallpaperPathLight') wallpaperPathLight: string = '';
  @StorageProp('wallpaperPathDark') wallpaperPathDark: string = '';
  @StorageProp('wallpaperPath') wallpaperPath: string = '';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 4;
  @StorageLink('wallpaperScrim') wallpaperScrim: number = 42;
  @StorageProp('wallpaperGenId') genWallId: string = '';
  @StorageLink('readerCustomBgLight') customBgLight: string = '';
  @StorageLink('readerCustomBgDark') customBgDark: string = '';

  // ── 会话与配置 ──
  @State loaded: boolean = false;
  @State cfg: AiChatConfig = {
    apiUrl: '', apiKey: '', models: [], systemPrompt: '', reasoning: 1, currentModel: '',
    profiles: [], activeProfile: 0
  };
  @State session: AiChatSession = AiChatStore.newSession('');
  @State input: string = '';
  @State sending: boolean = false;
  /**
   * 生成中信号（应用级，AiChatStore 维护）：tick 变化 = 有会话开始 / 结束生成。
   * 用途：① 历史列表给正在生成的会话显示加载动画；
   *      ② 后台跑完的回复回流到界面（离开过页面也能看到结果）。
   */
  @StorageProp('aiGenTick') @Watch('onGenTick') genTick: number = 0;

  // ── 附件 ──
  @State attachDocName: string = '';
  @State attachDocContent: string = '';
  @State attachQuote: string = '';
  /**
   * 外部文件附件列表（**取消大小上限**，用户要求：文件很容易超过 8MB，太大就分批上传）。
   * 小文件（≤ 内联阈值）在选择时就整份读进 `content`；
   * 大文件只记 uri / size，**发送时按块从磁盘流式读取、自动拆成多批请求**。
   */
  @State attachFiles: AiAttachFile[] = [];
  /** 分批上传队列：每项是一批待读待发的文件分片（首批随用户输入一起发，这里存后续） */
  @State batchQueue: AiBatchStep[] = [];
  /** 分批进度（仅用于进度提示） */
  @State batchDone: number = 0;
  @State batchTotal: number = 0;
  @State attachImages: string[] = [];
  // 输入框下方附件选项区展开态（点「+」拉高输入区，再点收起）
  @State attachPanelOpen: boolean = false;
  // 附件选项大按钮按压态（按压缩放/透明度过渡动画）
  @State attachPressIdx: number = -1;
  /** 输入区实测高度（空态引导卡让位用） */
  @State inputH: number = 130;

  // ── 半模态面板 ──
  @State sheetVisible: boolean = false;
  @State sheetKind: string = '';
  @State sheetEpoch: number = 0;
  @State sessionList: AiChatSessionBrief[] = [];
  @State docList: DocMeta[] = [];

  // ── 右滑抽屉（历史对话）与思考过程 ──
  @State drawerOpen: boolean = false;
  // 用户消息原位编辑：editingIdx 指向正在编辑的消息，editText 为编辑框内容
  @State editingIdx: number = -1;
  @State editText: string = '';
  /** 思考过程当前展开的消息下标（-1 = 全部收起；单开模式） */
  @State thinkingOpenIdx: number = -1;
  /** 请求发出时刻（思考耗时 = 回复到达 - reqStart） */
  private reqStart: number = 0;
  /** 生成中占位气泡的 ts（回复到达后按它原位替换） */
  private pendingTs: number = 0;

  /** 根容器实测宽（vp）：随窗口放大 / 分屏 / 自由窗实时更新（多屏窗口适配的事实源） */
  @State private rootWidth: number = 360;

  // ── 窗口模式（大屏横屏 = 历史对话栏固定展开的布局开关）──
  /** 代码放大面板（sheetKind 'code'）的正文与语言标题 */
  @State codeSheetText: string = '';
  @State codeSheetLang: string = '';

  private listScroller: Scroller = new Scroller();
  /** 历史面板「删除」点击标志（子先父后，父级读到即跳过恢复） */
  private deleteTapped: boolean = false;

  aboutToAppear(): void {
    // **键盘避让改 RESIZE**（用户要求：只让对话气泡与输入工具栏抬起，其他元素不动）：
    // 默认 OFFSET 是「整页上移」，悬浮顶栏 / 背景会一起被顶起来；RESIZE 让页面布局高度
    // 直接收缩，钉底的气泡列表与输入区自然贴到键盘上沿，顶部元素原地不动
    //（与编辑页同一条平台级做法）。
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (err) {
      // 旧版本无此能力：忽略
    }
    // 记录进场时的深浅，避免首次外观 tick 触发无谓重建
    this.lastThemeDark = this.isDark();
    this.lastThemeValid = true;
    // **可见性登记 + 角标清零**（用户要求：后台跑完才在书架 AI 入口挂新事件角标；
    // 进到对话页就算已读）。aboutToDisappear 里写回 false。
    AppStorage.setOrCreate('aiChatVisible', true);
    AppStorage.setOrCreate('aiNewReply', 0);
    AppStorage.setOrCreate('aiGenErr', false);
    // 根宽初始化：优先用主窗口真实宽（AppWindow 广播；自由窗 / 分屏下 ≠ 屏宽），
    // 读不到再退回整屏宽；后续由根 Stack 的 onAreaChange 实时接管
    const winWpx: number | undefined = AppStorage.get<number>('windowWpx');
    try {
      if (winWpx !== undefined && winWpx > 0) {
        this.rootWidth = this.getUIContext().px2vp(winWpx);
      } else {
        this.rootWidth = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
      }
    } catch (err) {
      this.rootWidth = 360;
    }
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      this.loaded = true;
      return;
    }
    this.cfg = AiChatStore.loadConfig(c);
    // ── 消费进入信号（阅读页 / 编辑页 / 长按发送）──
    const docName: string = AppStorage.get<string>('aiChatDocName') ?? '';
    const docContent: string = AppStorage.get<string>('aiChatDocContent') ?? '';
    const quote: string = AppStorage.get<string>('aiChatQuote') ?? '';
    AppStorage.setOrCreate('aiChatDocName', '');
    AppStorage.setOrCreate('aiChatDocContent', '');
    AppStorage.setOrCreate('aiChatQuote', '');
    if (docName.length > 0) {
      this.attachDocName = docName;
      if (docContent.length > 0) {
        // 编辑页 / 阅读页直传的原文（可能带未保存修改）
        this.attachDocContent = docContent;
      } else {
        // 只有名字：现场读正文
        const meta: DocMeta | undefined = DocStore.find(c, docName);
        if (meta !== undefined) {
          try {
            this.attachDocContent = DocStore.readText(c, meta);
          } catch (err) {
            this.attachDocContent = '';
          }
        }
      }
    }
    if (quote.length > 0) {
      this.attachQuote = quote.length > AI_QUOTE_LIMIT ? quote.substring(0, AI_QUOTE_LIMIT) : quote;
    }
    // 编辑页 AI 功能预设（摘要 / 续写 / 润色）：非空则进入后自动发送
    const preset: string = AppStorage.get<string>('aiChatPreset') ?? '';
    AppStorage.setOrCreate('aiChatPreset', '');
    if (preset.length > 0) {
      this.input = preset;
    }
    this.loaded = true;
    // 大屏横屏：历史栏固定展开，进场就把列表装好（抽屉形态靠 openDrawer 现载）
    if (this.aiWide()) {
      this.refreshSessionList();
    }
    if (this.input.trim().length > 0) {
      this.send();
    }
  }

  // ── 基础 ──

  private ctx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  private isDark(): boolean {
    return isDarkTheme(this.themeMode, this.systemDark);
  }

  private palette(): ReaderPalette {
    return paletteFor(this.themeMode, this.systemDark);
  }

  private wallpaperPathEffective(): string {
    if (this.isDark()) {
      return this.wallpaperPathDark.length > 0 ? this.wallpaperPathDark : this.wallpaperPath;
    }
    return this.wallpaperPathLight.length > 0 ? this.wallpaperPathLight : this.wallpaperPath;
  }

  private pageBackground(): string {
    if (this.isDark()) {
      return this.customBgDark.length > 0 ? this.customBgDark : '';
    }
    return this.customBgLight.length > 0 ? this.customBgLight : '';
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      // 忽略
    }
  }

  // ── 大屏横屏适配（历史对话栏固定展开）──

  /** 是否大屏横屏形态：根宽 ≥700 且显示横置（平板横屏 / PC；手机自由窗不误判）。 */
  private aiWide(): boolean {
    if (this.rootWidth < 700) {
      return false;
    }
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      return d.width >= d.height;
    } catch (err) {
      return false;
    }
  }

  /** 大屏横屏下历史栏占用的左侧宽度（主内容整体让位）。 */
  private chatInset(): number {
    return this.aiWide() ? 300 : 0;
  }

  /** 主内容区可用宽（大屏横屏扣除历史栏；其余形态铺满）。 */
  private chatContentWidth(): number {
    return this.aiWide() ? Math.max(320, this.rootWidth - this.chatInset()) : this.rootWidth;
  }

  /** 历史抽屉打开时的背景模糊（同书架搜索）：手机端 / 大屏竖屏生效；横屏是固定侧栏无需模糊。 */
  private drawerBlur(): number {
    return this.drawerOpen && !this.aiWide() ? 6 : 0;
  }

  /** 当前模型名（配置未选时取第一个） */
  private currentModel(): string {
    const cm: string = this.cfg.currentModel;
    if (cm.length > 0 && this.cfg.models.indexOf(cm) >= 0) {
      return cm;
    }
    return this.cfg.models.length > 0 ? this.cfg.models[0] : '';
  }

  /** 全部 API 配置的模型总数（模型面板空态判定） */
  private totalModelCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.cfg.profiles.length; i++) {
      n += this.cfg.profiles[i].models.length;
    }
    return n;
  }

  private canSend(): boolean {
    return !this.sending && (this.input.trim().length > 0 || this.attachImages.length > 0
      || this.attachQuote.length > 0 || this.attachFiles.length > 0
      || this.attachDocContent.length > 0);
  }

  private scrollBottom(smooth: boolean): void {
    setTimeout(() => {
      try {
        // 头部占位占 index 0：最后一条消息 index = length；尾占位 index = length + 1
        this.listScroller.scrollToIndex(this.session.messages.length + 1, smooth);
      } catch (err) {
        // 忽略
      }
    }, 80);
  }

  // ── 发送 ──

  private send(): void {
    if (this.sending) {
      return;
    }
    if (!AiChatStore.isConfigured(this.cfg)) {
      this.toast(L10n.t('请先在「AI 设置」里配置接口'));
      this.openSettings();
      return;
    }
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    const text: string = this.input.trim();
    if (!this.canSend()) {
      this.toast(L10n.t('先输入点什么吧'));
      return;
    }
    // 组装本次用户消息正文：外部文件 + 引用 + 输入。
    // **大文件不再截断**（旧代码 20000 字截断 + 512KB 上限都去掉）：按 FILE_CHUNK_SIZE
    // 切成多批，首批随本条输入一起发，其余进 batchQueue，回复到一批就自动发下一批。
    let head: string = '';
    if (this.attachQuote.length > 0) {
      head += '【选中文本】\n' + this.attachQuote + '\n\n';
    }
    const steps: AiBatchStep[] = [];
    let firstChunk: string = '';
    for (let i = 0; i < this.attachFiles.length; i++) {
      const f: AiAttachFile = this.attachFiles[i];
      if (f.content.length > 0) {
        // 小文件：一次发完
        head += '【本地文件：' + f.name + '】\n' + f.content + '\n\n';
      } else {
        // 大文件：切批（轮到自己时才读盘）
        const n: number = Math.max(1, Math.ceil(f.size / FILE_CHUNK_SIZE));
        for (let k = 0; k < n; k++) {
          const start: number = k * FILE_CHUNK_SIZE;
          const len: number = Math.min(FILE_CHUNK_SIZE, f.size - start);
          const step: AiBatchStep = {
            label: f.name + ' 第 ' + (k + 1) + '/' + n + ' 批',
            uri: f.uri, start: start, len: len, last: false
          };
          steps.push(step);
        }
      }
    }
    const tail: string = text.length > 0 ? text : L10n.t('（请看附件内容）');
    if (steps.length > 0) {
      // 首批 = 输入 + 引用 + 小文件 + 第一个分片
      const s0: AiBatchStep = steps[0];
      firstChunk = '【本地文件：' + s0.label + '（分批上传）】\n' + this.readFileChunk(s0.uri, s0.start, s0.len);
      steps.shift();
      if (steps.length > 0) {
        steps[steps.length - 1].last = true;
      }
      if (steps.length + 1 > FILE_MAX_BATCHES) {
        this.toast('文件过大，将分 ' + (steps.length + 1) + ' 批上传，耗时可能较长');
      } else {
        this.toast('文件较大，将分 ' + (steps.length + 1) + ' 批上传');
      }
      this.batchQueue = steps;
      this.batchTotal = steps.length + 1;
      this.batchDone = 1;
    } else {
      this.batchQueue = [];
      this.batchTotal = 0;
      this.batchDone = 0;
    }
    let body: string = head;
    if (firstChunk.length > 0) {
      body += firstChunk + '\n\n';
    }
    body += tail;
    const msg: AiChatMessage = { role: 'user', content: body, ts: Date.now() };
    if (this.attachImages.length > 0) {
      msg.images = this.attachImages.slice();
    }
    const isFirst: boolean = this.session.messages.length === 0;
    const hasDoc: boolean = this.attachDocContent.length > 0 && this.attachDocName.length > 0;
    // 首条消息携带的文档正文：清空附件前先留存（Store 组装为独立 system 注入）
    const docContent: string = isFirst && hasDoc ? this.attachDocContent : '';
    if (isFirst && hasDoc) {
      // 首条消息携带文档正文：会话绑定文档名，气泡上也有标注
      this.session.docName = this.attachDocName;
      msg.docName = this.attachDocName;
    }
    if (this.attachQuote.length > 0) {
      msg.quote = this.attachQuote;
    }
    // 标题：取第一条用户消息前 20 字
    if (this.session.title === '新对话') {
      const base: string = text.length > 0 ? text
        : (this.attachDocName.length > 0 ? L10n.t('关于《') + this.attachDocName + '》' : L10n.t('新对话'));
      this.session.title = base.length > 20 ? base.substring(0, 20) : base;
    }
    this.session.messages.push(msg);
    this.session.updated = Date.now();
    this.syncFormulaTasks();
    // 清空输入与一次性附件（文档正文只注入首条，chip 一并撤下）
    this.input = '';
    this.attachQuote = '';
    this.attachImages = [];
    this.attachFiles = [];
    this.attachDocContent = '';
    this.attachDocName = '';
    this.sending = true;
    this.scrollBottom(true);
    this.requestNow(docContent);
  }

  /**
   * 分批上传：发下一批（读取该批分片→作为一条用户消息→继续请求）。
   * 由 requestNow 的回复回调在队列非空时调用。
   */
  private continueBatch(): void {
    if (this.batchQueue.length === 0) {
      return;
    }
    const step: AiBatchStep = this.batchQueue[0];
    const kept: AiBatchStep[] = [];
    for (let i = 1; i < this.batchQueue.length; i++) {
      kept.push(this.batchQueue[i]);
    }
    this.batchQueue = kept;
    this.batchDone = this.batchDone + 1;
    const part: string = this.readFileChunk(step.uri, step.start, step.len);
    let body: string = '【本地文件：' + step.label + '（分批上传）】\n' + part;
    if (step.last) {
      body += '\n\n（以上为文件全文，请据此继续处理）';
    }
    const msg: AiChatMessage = { role: 'user', content: body, ts: Date.now() };
    this.session.messages.push(msg);
    this.session.updated = Date.now();
    this.syncFormulaTasks();
    this.sending = true;
    this.scrollBottom(true);
    setTimeout(() => {
      this.requestNow('');
    }, 220);
  }

  aboutToDisappear(): void {
    // 离开对话页：登记不可见（后台生成跑完时据此挂书架角标）
    AppStorage.setOrCreate('aiChatVisible', false);
  }

  /** 会话末尾补一条「正在思考」占位（后台生成中回到该会话时用；已有则不重复插）。 */
  private ensurePendingBubble(): void {
    const n: number = this.session.messages.length;
    if (n > 0 && this.session.messages[n - 1].pending === true) {
      return;
    }
    const pm: AiChatMessage = { role: 'assistant', content: '', ts: Date.now(), pending: true };
    this.session.messages.push(pm);
    this.syncFormulaTasks();
  }

  // ── 图表放大浮层（与阅读页同一套：磨砂暗纱 + 标题行 + ± 缩放 + 重排 + 关闭）──

  private openChartEnlarge(mode: string, payload: string, title: string): void {
    this.chartMode = mode;
    this.chartPayload = payload;
    this.chartTitle = title;
    this.chartZoom = 1;
    this.chartRefitTick = 0;
    this.chartOpen = true;
  }

  private closeChartEnlarge(): void {
    this.chartOpen = false;
    this.chartZoom = 1;
  }

  private chartZoomBy(factor: number): void {
    this.chartZoom = Math.min(3, Math.max(0.5, this.chartZoom * factor));
  }

  /**
   * 设置页保存了 AI 配置（应用级信号）：立即重新装载，
   * 否则从设置返回时仍按旧配置判定「未配置」，必须退出对话页重进才生效（用户反馈）。
   */
  private onCfgTick(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    this.cfg = AiChatStore.loadConfig(c);
  }

  /**
   * 外观 / 深浅变化：换消息列表容器 key → Markdown 气泡整批重建，
   * 保证气泡内文字颜色跟随新主题（不换 key 会被复用而停在旧色）。
   * 深浅没变（只是其它外观项）时跳过，避免无谓重建导致切换变慢。
   */
  private onThemeTick(): void {
    const dark: boolean = this.isDark();
    if (this.lastThemeValid && this.lastThemeDark === dark) {
      return;
    }
    this.lastThemeValid = true;
    this.lastThemeDark = dark;
    this.themeEpoch++;
    // 半模态面板内容不跟随宿主刷新：开着的面板也换纪元重建
    if (this.sheetVisible) {
      this.sheetEpoch++;
    }
    // 公式图缓存键含深浅——换主题后重建任务（新墨色的图）
    this.syncFormulaTasks();
  }

  /**
   * 收集 AI 气泡里的行内公式图任务（与阅读页同引擎的公式渲染）。
   *
   * 对话页此前没有任何公式出图通道——气泡里的 $公式$ 一律线性化文字
   * （用户反馈"AI 对话页面也没有正确渲染"）。这里复用 InlineFormulaPool：
   * 只收集**最近 8 条 AI 回复**（视野在底部；历史全量生成没有意义），
   * 消息 / 主题变化时重收，就绪信号 formulaTick 驱动气泡逐条换成公式图。
   */
  private syncFormulaTasks(): void {
    const msgs: AiChatMessage[] = this.session.messages;
    const blocks: MdBlock[] = [];
    let used: number = 0;
    for (let i: number = msgs.length - 1; i >= 0 && used < 8; i--) {
      const m: AiChatMessage = msgs[i];
      if (m.content.length === 0 || m.pending === true) {
        continue;
      }
      used++;
      const parsed: MdBlock[] = MdParser.parse(m.content).blocks;
      for (let k: number = 0; k < parsed.length; k++) {
        blocks.push(parsed[k]);
      }
    }
    this.formulaTasks = FormulaTasks.collect(blocks, this.isDark(), HwType.bodyDefault);
  }

  /** 气泡内某块的"公式就绪位"（key 后缀；图就绪后气泡重建换成图）。 */
  private formulaSuffix(b: MdBlock): string {
    return FormulaTasks.readySuffix(this.ctx(), b, this.isDark(), HwType.bodyDefault);
  }

  /**
   * 「设置 → 引擎管理」里 MathJax 被开关 → 重收行内公式任务并递增就绪信号：
   * 重新开启后补生成图；关闭期间 collect 返回空、气泡回落文字
   * （气泡自身由 MdBlockView 订阅同一 AppStorage 键即时重渲染）。
   */
  onEnginesChanged(): void {
    this.syncFormulaTasks();
    this.formulaTick++;
  }

  /**
   * 生成状态变化（应用级信号）：
   *  · 本页会话**正在生成** → 置 sending + 占位气泡（后台跑着，界面也如实显示）；
   *  · 本页会话**刚生成完**（且请求不是本页发起的）→ 用盘上版本回流刷新，
   *    这样「离开页面 → 后台跑完 → 回来」也能看到完整回复。
   */
  private onGenTick(): void {
    if (this.session.id.length === 0) {
      return;
    }
    const generating: boolean = AiChatStore.isGenerating(this.session.id);
    if (generating) {
      if (!this.sending) {
        this.sending = true;
        this.ensurePendingBubble();
        this.scrollBottom(true);
      }
      // 历史面板开着时换纪元重建内容（bindSheet 内容不跟宿主刷新，见 sheetEpoch 约定）
      if (this.sheetVisible && this.sheetKind === 'history') {
        this.sheetEpoch++;
      }
      return;
    }
    // 不在生成中：若本页还挂着 sending，说明是本页会话刚跑完 → 从盘上回流
    const doneId: string = AppStorage.get<string>('aiGenDoneId') ?? '';
    if (this.sending && doneId === this.session.id) {
      const c: common.UIAbilityContext | null = this.ctx();
      if (c !== null) {
        const s: AiChatSession | null = AiChatStore.loadSession(c, this.session.id);
        if (s !== null) {
          this.session = s;
          this.syncFormulaTasks();
        }
      }
      this.sending = false;
      this.scrollBottom(true);
    }
    if (this.aiWide()) {
      this.refreshSessionList();
    }
    if (this.sheetVisible && this.sheetKind === 'history') {
      this.sheetEpoch++;
    }
  }

  /**
   * 发出请求并把回复落进会话（send 与「重新生成」共用）。
   * docContent：首条消息携带的文档正文（会话已有消息时为空串）。
   */
  private requestNow(docContent: string): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      this.sending = false;
      return;
    }
    // 书架文档名清单：告诉 AI 可以修改哪些文档（文档生成协议引用原文档名）
    const docNames: string[] = [];
    const shelf: DocMeta[] = DocStore.list(c);
    for (let i = 0; i < shelf.length && i < 60; i++) {
      docNames.push(shelf[i].name);
    }
    const model: string = this.currentModel();
    this.reqStart = Date.now();
    // 生成中占位气泡：立即显示加载动画（回复到达后按 ts 原位替换）
    this.pendingTs = Date.now();
    const pendingMsg: AiChatMessage = {
      role: 'assistant', content: '', ts: this.pendingTs, model: model, pending: true
    };
    this.session.messages.push(pendingMsg);
    this.session.updated = Date.now();
    this.scrollBottom(true);
    // 登记「本会话正在生成」：离开页面后请求继续跑，历史列表据此显示加载动画
    AiChatStore.markGenerating(this.session.id);
    AiChatStore.requestChat(this.cfg, model, this.session, docContent, docNames)
      .then((r: AiChatResult) => {
        this.sending = false;
        // 定位占位气泡（请求期间消息可能被删，按 ts 找；找不到就追加到末尾）
        let pos: number = -1;
        for (let i = this.session.messages.length - 1; i >= 0; i--) {
          const pm: AiChatMessage = this.session.messages[i];
          if (pm.pending === true && pm.ts === this.pendingTs) {
            pos = i;
            break;
          }
        }
        // 用户主动停止：撤掉占位气泡，保留已发出的提问（可编辑重发）
        if (r.aborted === true) {
          if (pos >= 0) {
            this.session.messages.splice(pos, 1);
            this.session.updated = Date.now();
            AiChatStore.saveSession(c, this.session);
          }
          this.toast(L10n.t('已停止生成'));
          // 分批上传中止：清掉剩余批次（下次要发就在输入框重新附上文件）
          this.batchQueue = [];
          this.batchTotal = 0;
          // 注销生成中（历史列表的加载动画随之消失）；中止不算「新事件」，不挂角标
          AppStorage.setOrCreate('aiGenErr', true);
          AiChatStore.unmarkGenerating(this.session.id);
          if (this.aiWide()) {
            this.refreshSessionList();
          }
          return;
        }
        // 记录产生本条回复的模型：设置页按模型统计词元消耗的数据源
        const a: AiChatMessage = { role: 'assistant', content: r.text, ts: Date.now(), model: model };
        if (r.ok) {
          // 文档生成协议落地：解析 <doc> 标记 → 真实落盘到书架 → 气泡渲染文档卡
          const gen: AiDocGenResult = materializeDocs(r.text, c);
          a.content = gen.text;
          if (gen.names.length > 0) {
            a.docs = gen.names;
            this.toast('已生成 ' + gen.names.length + ' 份文档，已存入书架');
          }
          // Token 用量（网关 usage 口径；没有则缺省）
          if (r.tokens !== undefined && r.tokens > 0) {
            a.tokens = r.tokens;
          }
          // 思考过程 + 思考耗时（非流式拿不到思考/生成分界，用请求实测总时长）
          if (r.thinking !== undefined && r.thinking.length > 0) {
            a.thinking = r.thinking;
            a.thinkMs = Date.now() - this.reqStart;
          }
        } else {
          a.err = true;
        }
        // 原位替换占位：新 ts → ForEach key 变化 → 气泡节点重建（内容/淡入动画）
        if (pos >= 0) {
          this.session.messages.splice(pos, 1, a);
        } else {
          this.session.messages.push(a);
        }
        this.session.updated = Date.now();
        AiChatStore.saveSession(c, this.session);
        this.syncFormulaTasks();
        // 回复已落盘 → 注销生成中（顺序在保存之后：信号触发时盘上已是最新版本）；
        // 只有**成功**的回复才在「页面不可见」时挂书架角标（失败 / 中止不打扰）
        AppStorage.setOrCreate('aiGenErr', r.ok !== true);
        AiChatStore.unmarkGenerating(this.session.id);
        // 大屏横屏：历史栏常驻展开，新会话/新标题要立刻出现在侧栏
        if (this.aiWide()) {
          this.refreshSessionList();
        }
        this.scrollBottom(true);
        // **分批上传：还有剩余批次就接着发**（成功才继续；失败时清队列并提示）
        if (this.batchQueue.length > 0) {
          if (r.ok === true) {
            this.continueBatch();
            return;
          }
          this.batchQueue = [];
          this.batchTotal = 0;
          this.toast(L10n.t('分批上传已中断（网络或接口报错）'));
        }
      })
      .catch((err: BusinessError) => {
        // **兜底**：页面处理链的任何异常都不该让会话卡在「生成中」、
        // 占位气泡卡在界面、或生成登记泄漏（清状态 + 友好提示）
        this.sending = false;
        this.batchQueue = [];
        this.batchTotal = 0;
        let pos: number = -1;
        for (let i = this.session.messages.length - 1; i >= 0; i--) {
          const pm: AiChatMessage = this.session.messages[i];
          if (pm.pending === true && pm.ts === this.pendingTs) {
            pos = i;
            break;
          }
        }
        if (pos >= 0) {
          const errBubble: AiChatMessage = {
            role: 'assistant',
            content: L10n.t('处理回复时出错：') + (err.message !== undefined ? err.message : L10n.t('未知异常')),
            ts: Date.now(),
            err: true
          };
          this.session.messages.splice(pos, 1, errBubble);
        }
        this.session.updated = Date.now();
        const cc: common.UIAbilityContext | null = this.ctx();
        if (cc !== null) {
          AiChatStore.saveSession(cc, this.session);
          this.syncFormulaTasks();
          AppStorage.setOrCreate('aiGenErr', true);
          AiChatStore.unmarkGenerating(this.session.id);
        }
        this.getUIContext().getPromptAction().showToast({
          message: L10n.t('回复处理出错，已停止'), duration: 2200
        });
      });
  }

  /** 重新生成：撤掉这条 AI 回复，用同样上下文再请求一次 */
  private regenerate(idx: number): void {
    // 用户要求：生成中不再拦「请稍候」——但同会话重发必须先中止在飞请求，
    // 否则两个请求会同时往同一条会话里写回复
    if (this.sending) {
      AiChatStore.abortChat();
      this.sending = false;
    }
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    if (idx < 0 || idx >= this.session.messages.length) {
      return;
    }
    this.session.messages.splice(idx, 1);
    this.session.updated = Date.now();
    AiChatStore.saveSession(c, this.session);
    this.syncFormulaTasks();
    this.sending = true;
    this.requestNow('');
  }

  /** 编辑用户消息：气泡原位进入编辑态（与其他 AI 助手一致，不搬回底部输入框） */
  private editMessage(idx: number): void {
    // 生成中同样允许进入编辑（用户要求）
    const m: AiChatMessage | undefined = this.session.messages[idx];
    if (m === undefined || m.role !== 'user') {
      return;
    }
    // **动画驱动编辑态切换**（用户要求：编辑框出现 / 收起要有过渡、不跳变）：
    // animateTo 让气泡⇄编辑框的高度差也参与补间，配合 editBubble 上的 transition
    this.getUIContext().animateTo(AppearanceFx.anim(240, Curve.FastOutSlowIn), () => {
      this.editingIdx = idx;
      this.editText = m.content;
    });
    // 定位到编辑框（全部走 smooth，滚动过程中不出现瞬时修正造成的跳变）：
    // 悬浮顶栏是**浮层**（不占布局流），把条目顶到视口顶端会让编辑框钻到状态栏 / 胶囊底下
    // （用户反馈：编辑第一条时文本框跑到系统状态栏下）。
    //   · 首条 → 滚到 index 0（首屏占位条目），编辑框自然落在悬浮顶栏下方；
    //   · 其余 → 该条居中显示，既避开顶栏、也不依赖偏移量。
    if (idx === 0) {
      // 首条：缓出滑到顶部（留在悬浮顶栏下方）
      try {
        this.listScroller.scrollTo({
          xOffset: 0,
          yOffset: 0,
          animation: { duration: 240, curve: Curve.FastOutSlowIn, canOverScroll: false }
        });
      } catch (err) {
        // 列表未挂载 / 已销毁：忽略
      }
    } else {
      this.listScroller.scrollToIndex(idx + 1, true, ScrollAlign.CENTER);
    }
  }

  /** 提交原位编辑：改写该条内容、撤掉其后所有消息并从这条重新请求 */
  private commitEdit(idx: number): void {
    // 生成中提交编辑：先中止在飞请求（同会话不能有两份回复在写）
    if (this.sending) {
      AiChatStore.abortChat();
      this.sending = false;
    }
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    const m: AiChatMessage | undefined = this.session.messages[idx];
    if (m === undefined || m.role !== 'user') {
      this.editingIdx = -1;
      return;
    }
    const text: string = this.editText.trim();
    if (text.length === 0) {
      this.toast(L10n.t('先输入点什么吧'));
      return;
    }
    m.content = text;
    m.ts = Date.now();
    this.session.messages.splice(idx + 1);
    this.session.updated = Date.now();
    this.syncFormulaTasks();
    // 首条提问是会话标题来源，编辑后跟随
    if (idx === 0) {
      this.session.title = text.length > 20 ? text.substring(0, 20) : text;
    }
    // 收起编辑框走动画（与展开对称，避免跳变）
    this.getUIContext().animateTo(AppearanceFx.anim(220, Curve.FastOutSlowIn), () => {
      this.editingIdx = -1;
      this.editText = '';
    });
    AiChatStore.saveSession(c, this.session);
    this.sending = true;
    this.scrollBottom(true);
    // 编辑首条时把会话绑定的书架文档正文随 system 重新注入
    let docContent: string = '';
    if (idx === 0 && this.session.docName !== undefined && this.session.docName.length > 0) {
      const meta: DocMeta | undefined = DocStore.find(c, this.session.docName);
      if (meta !== undefined) {
        docContent = DocStore.readText(c, meta);
      }
    }
    this.requestNow(docContent);
  }

  private newChat(): void {
    // 用户要求：生成中也允许开新话题（旧话题继续在后台跑，历史列表里带加载动画）
    this.session = AiChatStore.newSession('');
    this.sending = false;
    this.syncFormulaTasks();
    this.toast(L10n.t('已开启新话题'));
    if (this.aiWide()) {
      this.refreshSessionList();
    }
  }

  private openSettings(): void {
    if (this.stack !== null) {
      this.stack.pushPath({ name: 'pages/AiSettings' }, AppearanceFx.navAnimated());
    }
  }

  // ── 半模态面板 ──

  private openSheet(kind: string): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c !== null) {
      if (kind === 'history') {
        this.sessionList = AiChatStore.listSessions(c);
      } else if (kind === 'doc') {
        this.docList = DocStore.list(c);
      }
    }
    this.sheetKind = kind;
    this.sheetEpoch = this.sheetEpoch + 1;
    this.sheetVisible = true;
  }

  private closeSheet(): void {
    this.sheetVisible = false;
    this.sheetKind = '';
  }

  private sheetTitle(): string {
    if (this.sheetKind === 'history') {
      return '历史对话';
    }
    if (this.sheetKind === 'model') {
      return '选择模型';
    }
    if (this.sheetKind === 'reason') {
      return '思考强度';
    }
    if (this.sheetKind === 'doc') {
      return '附加应用内文档';
    }
    if (this.sheetKind === 'code') {
      return this.codeSheetLang.length > 0 ? this.codeSheetLang : L10n.t('代码块');
    }
    return '';
  }

  /** 历史面板：恢复一个会话 */
  private restoreSession(b: AiChatSessionBrief): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    const s: AiChatSession | null = AiChatStore.loadSession(c, b.id);
    if (s === null) {
      this.toast(L10n.t('会话读取失败'));
      return;
    }
    // 用户要求：生成中也允许切换历史会话（旧会话继续在后台跑，不弹「请稍候」）
    this.session = s;
    this.syncFormulaTasks();
    // 该会话正在**后台生成**（离开页面后又回来）：恢复「正在思考」占位与发送中态，
    // 生成完成后 onGenTick 会把盘上结果回流到界面
    if (AiChatStore.isGenerating(s.id)) {
      this.sending = true;
      this.ensurePendingBubble();
    } else {
      this.sending = false;
    }
    this.closeSheet();
    this.scrollBottom(false);
  }

  private removeSession(b: AiChatSessionBrief): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    AiChatStore.deleteSession(c, b.id);
    this.sessionList = AiChatStore.listSessions(c);
    this.sheetEpoch = this.sheetEpoch + 1;
  }

  // ── 右滑抽屉（历史对话按日期分组）──

  /** 历史会话按日期分组：今天 / 昨天 / 近 7 天 / 更早（listSessions 已按时间倒序） */
  private drawerGroups(list: AiChatSessionBrief[]): AiDrawerGroup[] {
    const groups: AiDrawerGroup[] = [];
    const now: Date = new Date();
    const dayMs: number = 86400000;
    const todayStart: number = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    for (let i = 0; i < list.length; i++) {
      const b: AiChatSessionBrief = list[i];
      let label: string = '更早';
      if (b.updated >= todayStart) {
        label = '今天';
      } else if (b.updated >= todayStart - dayMs) {
        label = '昨天';
      } else if (b.updated >= todayStart - dayMs * 6) {
        label = '近 7 天';
      }
      let g: AiDrawerGroup | undefined = undefined;
      for (let k = 0; k < groups.length; k++) {
        if (groups[k].label === label) {
          g = groups[k];
          break;
        }
      }
      if (g === undefined) {
        const ng: AiDrawerGroup = { label: label, items: [] };
        groups.push(ng);
        g = ng;
      }
      g.items.push(b);
    }
    return groups;
  }

  /** 刷新历史会话列表（抽屉打开 / 大屏横屏常驻侧栏在会话变化后都要保持新鲜）。 */
  private refreshSessionList(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c !== null) {
      this.sessionList = AiChatStore.listSessions(c);
    }
  }

  private openDrawer(): void {
    this.refreshSessionList();
    this.getUIContext().animateTo(AppearanceFx.anim(240, Curve.FastOutSlowIn), () => {
      this.drawerOpen = true;
    });
  }

  private closeDrawer(): void {
    this.getUIContext().animateTo(AppearanceFx.anim(200, Curve.FastOutSlowIn), () => {
      this.drawerOpen = false;
    });
  }

  /** 抽屉里恢复会话（比半模态版多关抽屉一步） */
  private restoreFromDrawer(b: AiChatSessionBrief): void {
    if (this.deleteTapped) {
      this.deleteTapped = false;
      return;
    }
    this.restoreSession(b);
    this.closeDrawer();
  }

  /** 附加应用内文档 */
  private attachInAppDoc(meta: DocMeta): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    try {
      const text: string = DocStore.readText(c, meta);
      this.attachDocName = meta.name;
      this.attachDocContent = text;
      this.closeSheet();
      this.toast('已附加《' + meta.name + '》');
    } catch (err) {
      this.toast(L10n.t('读取文档失败'));
    }
  }

  /** 选择本地文件（文本） */
  private pickFile(): void {
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      // **可多选**（用户要求：不限制数量）
      opts.maxSelectNumber = 10;
      docPicker.select(opts).then((uris: string[]) => {
        if (uris.length === 0) {
          return;
        }
        const added: AiAttachFile[] = [];
        for (let i = 0; i < uris.length; i++) {
          const uri: string = uris[i];
          const size: number = this.fileSizeOf(uri);
          if (size < 0) {
            continue;
          }
          if (size <= FILE_INLINE_LIMIT) {
            // 小文件：选择时整份读入，一次请求发完
            const text: string | null = this.readLocalFileText(uri);
            if (text === null) {
              continue;
            }
            added.push({ name: this.fileNameOf(uri), uri: uri, size: size, content: text });
          } else {
            // **大文件：不读进内存**，只登记 uri + 大小；发送时按块流式读、自动分批上传
            added.push({ name: this.fileNameOf(uri), uri: uri, size: size, content: '' });
          }
        }
        if (added.length === 0) {
          return;
        }
        const list: AiAttachFile[] = this.attachFiles.slice();
        for (let i = 0; i < added.length; i++) {
          list.push(added[i]);
        }
        this.attachFiles = list;
        this.toast('已附加 ' + added.length + ' 个文件');
        this.hintIfAttachLarge();
      }).catch((_err: Error) => {
        // 用户取消
      });
    } catch (err) {
      this.toast(L10n.t('打开文件选择器失败'));
    }
  }

  /** 文件字节数（失败 -1）。 */
  private fileSizeOf(uri: string): number {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat: fs.Stat = fs.statSync(file.fd);
      return stat.size;
    } catch (err) {
      this.toast('读取失败：' + this.fileNameOf(uri));
      return -1;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  /**
   * 按字节范围读取文件分片（分批上传用）：**只读这一段**，不把整个文件读进内存，
   * 所以文件再大也不会 OOM。失败返回空串（该批视作空片，流程继续）。
   */
  private readFileChunk(uri: string, start: number, len: number): string {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const buf: ArrayBuffer = new ArrayBuffer(len);
      // 类型不显式命名（fileIo 命名空间未导出 ReadOptions）——直接传字面量，由参数类型收窄
      const read: number = fs.readSync(file.fd, buf, { offset: start, length: len });
      const u8: Uint8Array = new Uint8Array(buf.slice(0, read > 0 ? read : 0));
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(u8);
    } catch (err) {
      this.toast('读取文件分片失败：' + this.fileNameOf(uri));
      return '';
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  /** uri → 文件名（过长取尾部）。 */
  private fileNameOf(uri: string): string {
    let name: string = uri.substring(uri.lastIndexOf('/') + 1);
    if (name.length > 40) {
      name = name.substring(name.length - 40);
    }
    return name;
  }

  /**
   * 读本地文本文件 → 文本（失败返回 null）。**不设大小上限**：
   * 只有 ≤ FILE_INLINE_LIMIT 的文件走这里；更大的走 readFileChunk 分批上传。
   */
  private readLocalFileText(uri: string): string | null {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat: fs.Stat = fs.statSync(file.fd);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      const u8: Uint8Array = new Uint8Array(buf);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(u8);
    } catch (err) {
      this.toast('读取失败（仅支持文本文件）：' + this.fileNameOf(uri));
      return null;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  /** 选择相册图片（vision 多模态） */
  /**
   * 附件体积提示（用户要求：**不限制图片 / 文件的大小与数量**，但推荐别太大以免等待过久）。
   * 只在附件确实偏大时给一句柔性提示，不做任何拦截。
   */
  private hintIfAttachLarge(): void {
    let bytes: number = 0;
    for (let i = 0; i < this.attachFiles.length; i++) {
      bytes += this.attachFiles[i].size;
    }
    for (let i = 0; i < this.attachImages.length; i++) {
      bytes += this.attachImages[i].length;
    }
    if (bytes > 3 * 1024 * 1024) {
      this.toast('附件较大（约 ' + Math.round(bytes / 1024 / 1024) + ' MB），将分批上传，可能需要较久');
    }
  }

  private pickImages(): void {
    try {
      const p: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const opts: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      opts.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      // **不再限制数量**（用户要求；系统选择器本身的上限即上限）
      opts.maxSelectNumber = 50;
      p.select(opts).then((res: photoAccessHelper.PhotoSelectResult) => {
        for (let i = 0; i < res.photoUris.length; i++) {
          const dataUrl: string = this.readImageAsDataUrl(res.photoUris[i]);
          if (dataUrl.length > 0) {
            this.attachImages.push(dataUrl);
          }
        }
        if (this.attachImages.length > 0) {
          this.toast('已附加 ' + this.attachImages.length + ' 张图片');
          this.hintIfAttachLarge();
        }
      }).catch((_err: Error) => {
        // 用户取消
      });
    } catch (err) {
      this.toast(L10n.t('打开相册失败'));
    }
  }

  private readImageAsDataUrl(uri: string): string {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat: fs.Stat = fs.statSync(file.fd);
      if (stat.size > 8 * 1024 * 1024) {
        this.toast(L10n.t('图片过大（上限 8MB），已跳过'));
        return '';
      }
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      const u8: Uint8Array = new Uint8Array(buf);
      const b64: string = new util.Base64Helper().encodeToStringSync(u8);
      return 'data:' + imageMime(uri) + ';base64,' + b64;
    } catch (err) {
      return '';
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  /** 输入框下方附件选项区：展开/收起（animateTo 驱动输入区拉高过渡） */
  private toggleAttachPanel(): void {
    const opening: boolean = !this.attachPanelOpen;
    if (opening) {
      // **展开面板 = 面板替换键盘**：收起输入法即可——面板开合引起的输入区高度
      // 变化由 syncListToSpace 逐帧跟随（气泡与输入区顶边一起移动），无需手动滚动
      this.hideIme();
    }
    this.getUIContext().animateTo(AppearanceFx.anim(240, Curve.FastOutSlowIn), () => {
      this.attachPanelOpen = !this.attachPanelOpen;
    });
  }

  /** 收起输入法（打开附件面板时调用；失败静默——键盘收不起来也只是多占一屏）。 */
  private hideIme(): void {
    try {
      inputMethod.getInputMethodController().hideTextInput();
    } catch (err) {
      // 无输入法会话：忽略
    }
  }

  private closeAttachPanel(): void {
    if (!this.attachPanelOpen) {
      return;
    }
    this.getUIContext().animateTo(AppearanceFx.anim(200, Curve.FastOutSlowIn), () => {
      this.attachPanelOpen = false;
    });
  }

  /** 拍照附加（系统安全相机，无 camera 权限需求）：拍完读成 dataURL 进附件 */
  private pickCamera(): void {
    // **不再限制张数**（用户要求：不限制数量）
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    try {
      const prof: cameraPicker.PickerProfile = { cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK };
      cameraPicker.pick(c, [cameraPicker.PickerMediaType.PHOTO], prof)
        .then((res: cameraPicker.PickerResult) => {
          if (res.resultCode !== 0 || res.resultUri.length === 0) {
            return; // 用户取消
          }
          const dataUrl: string = this.readImageAsDataUrl(res.resultUri);
          if (dataUrl.length > 0) {
            this.attachImages.push(dataUrl);
            this.toast(L10n.t('已附加拍摄照片'));
            this.hintIfAttachLarge();
          }
        })
        .catch((_err: Error) => {
          // 用户取消或相机不可用
        });
    } catch (err) {
      this.toast(L10n.t('相机不可用'));
    }
  }

  // ══════════════════════ UI ══════════════════════

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // ── 背景：与书架同一套优先级 ──
      if (this.wallpaperPathEffective().length > 0) {
        // 整屏壁纸走 WallpaperImage：模糊**预烘成位图**，转场期间不再每帧重算
        WallpaperImage({ path: this.wallpaperPathEffective(), radiusVp: this.wallpaperBlur })
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.isDark()))
      } else if (this.genWallId.length > 0) {
        GenWallpaper({ styleId: this.genWallId, darkMode: this.isDark() })
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WallpaperStore.scrimColorOf(this.wallpaperScrim, this.isDark()))
      } else if (this.pageBackground().length > 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.pageBackground())
      } else {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [[this.palette().pageTop, 0.0], [this.palette().pageBottom, 1.0]]
          })
      }

      // 行内公式图生成池（MathJax → PNG）：1×1 隐形挂点，气泡里的 $公式$ 出图
      InlineFormulaPool({
        tasks: this.formulaTasks,
        dark: this.isDark(),
        onOneDone: () => {
          this.formulaTick++;
        }
      })

      // ── 消息流：整层铺满，内容可从悬浮顶栏 / 输入区下方穿过（真悬浮）──
      if (this.session.messages.length === 0) {
        Column() {
          this.emptyView()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        // 大屏横屏：历史栏固定展开在左侧，主内容整体让位
        .padding({ left: this.chatInset(), bottom: this.inputH })
        .blur(this.drawerBlur())
      } else {
        this.msgList()
      }

      // ── 输入区：沉底悬浮（Stack alignContent: Bottom），消息从其下方穿过 ──
      Column() {
        this.inputArea()
      }
      .width('100%')
      // 与消息流同一版心：宽窗下输入框与对话流对齐（Stack Bottom = 水平自动居中）；
      // 大屏横屏扣除历史栏宽度并整体右移
      .constraintSize({ maxWidth: Math.min(760, this.chatContentWidth()) })
      .translate({ x: this.chatInset() / 2 })
      .blur(this.drawerBlur())
      .zIndex(2)
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const h: number = Number(newValue.height);
        // 输入区高度变化包动画：空态问候文本（padding.bottom=inputH）随之平滑移动
        if (Math.abs(h - this.inputH) > 0.5) {
          this.getUIContext().animateTo(AppearanceFx.anim(240, Curve.FastOutSlowIn), () => {
            this.inputH = h;
          });
        }
        // 输入区顶边变化（附件面板开合 / 多行增高）→ 列表逐帧跟随（无动画=贴合动画曲线）
        this.syncListToSpace();
      })

      // ── 图表放大浮层（与阅读页同一套观感）──
      // 从 AI 回复里点图表「放大」进入：磨砂暗纱 + 左上标题 + ± 缩放 / 重排 / 关闭，
      // 正文由 DiagramWeb 按原 payload 重渲染（横向纵向都能滚动平移）。
      if (this.chartOpen) {
        Stack({ alignContent: Alignment.TopStart }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#33000000')
            .backgroundBlurStyle(BlurStyle.Regular)
            .hitTestBehavior(HitTestMode.None)

          Column() {
            Row({ space: HwSpace.sm }) {
              if (this.chartTitle.length > 0) {
                Text(this.chartTitle)
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(HwType.label + 1, this.uiFontScale))
                  .fontColor(this.isDark() ? '#FFFFFFFF' : '#E6222226')
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(TextAlign.Start)
              } else {
                Blank()
              }
              // 缩小 / 放大（body 缩放，与阅读页同一口径 0.5~3）
              ImmersiveIconButton({
                buttonSize: 34,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.chartZoomBy(0.8);
                }
              }) {
                SymbolGlyph($r('sys.symbol.minus'))
                  .fontSize(15)
                  .fontColor([this.isDark() ? '#FFFFFFFF' : '#E6222226'])
              }
              ImmersiveIconButton({
                buttonSize: 34,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.chartZoomBy(1.25);
                }
              }) {
                SymbolGlyph($r('sys.symbol.plus'))
                  .fontSize(15)
                  .fontColor([this.isDark() ? '#FFFFFFFF' : '#E6222226'])
              }
              // 重新自适应（按当前容器重排，解决"看着变小了"）
              ImmersiveIconButton({
                buttonSize: 34,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.chartRefitTick = this.chartRefitTick + 1;
                }
              }) {
                Image($r('app.media.arrow_2_circlepath'))
                  .width(18)
                  .height(18)
                  .fillColor(this.isDark() ? '#FFFFFFFF' : '#E6222226')
              }
              ImmersiveIconButton({
                buttonSize: 34,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.closeChartEnlarge();
                }
              }) {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(15)
                  .fontColor([this.isDark() ? '#FFFFFFFF' : '#E6222226'])
              }
            }
            .width('100%')
            .padding({
              left: HwSpace.lg,
              right: HwSpace.lg,
              top: this.getUIContext().px2vp(this.safeTopPx) + HwSpace.sm
            })

            Scroll() {
              Column() {
                DiagramWeb({
                  mode: this.chartMode,
                  payload: this.chartPayload,
                  dark: this.isDark(),
                  // ⚠️ 页面底色不透明（透明 Web 表面合成颜色不可控，同阅读页放大浮层）
                  cardBg: withAlpha(this.palette().codeBlockBg, 'FF'),
                  webZoom: this.chartZoom,
                  refitRequest: this.chartRefitTick
                })
              }
              .width('100%')
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .align(Alignment.Top)
            .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.xl })
          }
          .width('100%')
          .height('100%')
        }
        .width('100%')
        .height('100%')
        .zIndex(9)
        .transition(TransitionEffect.OPACITY.animation(AppearanceFx.anim(200, Curve.FastOutSlowIn)))
      }

      // ── 悬浮顶栏：返回 + 标题 + 新话题 + 历史 + 设置 ──
      Row() {
        ImmersiveBar({
          palette: this.palette(),
          barPaddingH: HwSpace.sm,
          barPaddingV: 4,
          barHeight: HwBar.pill,
          barWidth: '100%'
        }) {
          Row({ space: HwSpace.xs }) {
            ImmersiveIconButton({
              buttonSize: 36,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                if (this.stack !== null) {
                  this.stack.pop(AppearanceFx.navAnimated());
                }
              }
            }) {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                .fontSize(20)
                .fontColor([this.palette().textPrimary])
            }
            Column({ space: 1 }) {
              Text(L10n.t('AI 助手'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
                .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
                .fontColor(this.palette().textPrimary)
                .maxLines(1)
              if (this.currentModel().length > 0) {
                Text(this.currentModel())
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(10, this.uiFontScale))
                  .fontColor(this.palette().textTertiary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin({ left: 2 })

            // 大屏横屏：历史栏固定展开，「新建 / 历史对话」按钮没有存在意义（用户要求隐藏）
            if (!this.aiWide()) {
              ImmersiveIconButton({
                buttonSize: 34,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.newChat();
                }
              }) {
                SymbolGlyph($r('sys.symbol.plus'))
                  .fontSize(17)
                  .fontColor([this.palette().textPrimary])
              }
              ImmersiveIconButton({
                buttonSize: 34,
                buttonMaterialShadow: false,
                palette: this.palette(),
                buttonOnTap: () => {
                  this.openDrawer();
                }
              }) {
                SymbolGlyph($r('sys.symbol.clock'))
                  .fontSize(16)
                  .fontColor([this.palette().textPrimary])
              }
            }
            ImmersiveIconButton({
              buttonSize: 34,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.openSettings();
              }
            }) {
              SymbolGlyph($r('sys.symbol.gearshape'))
                .fontSize(17)
                .fontColor([this.palette().textPrimary])
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
      }
      .width(this.aiWide() ? this.chatContentWidth() : '100%')
      .padding({ left: HwSpace.lg, right: HwSpace.lg })
      .position({ x: this.chatInset(), y: this.getUIContext().px2vp(this.safeTopPx) + HwSpace.sm })
      .hitTestBehavior(HitTestMode.Transparent)
      .blur(this.drawerBlur())
      .zIndex(3)

      // ── 右滑抽屉：历史对话按日期分组（遮罩 + 左侧面板 translate 出入）──
      // 大屏横屏是固定侧栏，无遮罩
      if (this.drawerOpen && !this.aiWide()) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#33000000')
          .onClick(() => {
            this.closeDrawer();
          })
      }
      Column() {
        this.historyDrawer()
      }
      // 大屏横屏固定 300 侧栏；其余形态 78% 宽（上限 330）
      .width(this.aiWide() ? 300 : '78%')
      .constraintSize({ maxWidth: 330 })
      .height('100%')
      .alignItems(HorizontalAlign.Start)
      // 侧边栏贴左边缘（Stack 默认居中会把面板悬在屏幕中间）
      .position({ x: 0, y: 0 })
      // 大屏横屏常驻展开（固定侧栏）；其余形态按 drawerOpen 出入
      .translate({ x: this.drawerOpen || this.aiWide() ? 0 : -(this.rootWidth + 60) })
      .zIndex(5)
    }
    .width('100%')
    .height('100%')
    // **窗口尺寸实时跟踪**（多屏协同 / 分屏 / 自由窗 / PC 放大）：
    // 窗口变大变小时更新根宽，抽屉宽、气泡宽、面板 phoneLayout 随之自适应
    .onAreaChange((_old: Area, now: Area) => {
      const w: number = Number(now.width);
      if (Math.abs(w - this.rootWidth) > 0.5) {
        this.rootWidth = w;
      }
      // **键盘弹出时的同步移动**（用户要求：文本框和气泡一起移动）：
      // RESIZE 模式下页面高度的回调只在收缩结束时到一次 →
      //  · 键盘**弹起**（Δ<0）：不能瞬时补偿（那一下就是跳变）——改为与键盘滑出
      //    **同程的动画**（260ms 缓出）把滚动位置补够 Δ，气泡与输入栏同速上移；
      //  · 键盘**收起**（Δ>0）：用户实测瞬时补偿即是同步的，保持不变。
      // ⚠️ currentOffset() 可能返回 undefined（项目有崩溃前科），必须判空。
      const h: number = Number(now.height);
      if (Math.abs(h - this.lastRootH) > 0.5) {
        const first: boolean = this.lastRootH === 0;
        this.lastRootH = h;
        if (!first) {
          // 根容器高度变化（键盘弹收 / 窗口缩放）→ 列表跟随输入区顶边（带动画）
          this.syncListToSpace();
        }
      }
    })
    .bindSheet(this.sheetVisible, this.aiSheet(), modalSheetOptions({
      title: this.sheetTitle(),
      subtitle: '',
      surface: this.palette().surface,
      phoneLayout: this.rootWidth <= 600,
      screenWidth: this.rootWidth,
      onDismiss: () => {
        // 系统下滑关闭时务必把入口状态一并清空：只清 sheetKind 的话
        // sheetVisible 残留 true，宿主下次状态刷新会把面板重新拉起（空白"添加附件"的根因）
        this.sheetVisible = false;
        this.sheetKind = '';
      }
    }))
    // **右滑手势**：水平 pan 与列表垂直滚动正交不冲突；末端位移判定开合。
    // 大屏横屏历史栏固定展开，手势不再接管开合
    .gesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal })
      .onActionEnd((e: GestureEvent) => {
        if (this.aiWide()) {
          return;
        }
        if (e.offsetX > 60 && !this.drawerOpen) {
          this.openDrawer();
        } else if (e.offsetX < -60 && this.drawerOpen) {
          this.closeDrawer();
        }
      }))
  }

  // ── 空态 ──

  /**
   * 消息列表（抽成 @Builder 是为了让「主题纪元奇偶分支」能整棵重建它）。
   * ⚠️ 两条 if 分支里的调用写法必须完全一致，否则命中"@Builder 跨分支返回不同结构"的编译坑。
   */
  @Builder
  msgList() {
    List({ scroller: this.listScroller, space: HwSpace.sm }) {
      // **顶部占位条目**（与阅读页 topSpacer 同源语义）：只决定首屏起点
      // （首条消息在悬浮顶栏下方），滚动后消息照旧从顶栏底下穿过铺满全屏——
      // 不能用 List padding.top 实现：padding 是永久裁剪边界，内容永远到不了顶栏底下
      ListItem() {
        Column()
          .width('100%')
          .height(this.getUIContext().px2vp(this.safeTopPx) + HwSpace.xs + HwBar.pill + HwSpace.md)
      }

      ForEach(this.session.messages, (m: AiChatMessage, idx: number) => {
        ListItem() {
          this.bubble(m, idx)
        }
      }, (m: AiChatMessage, idx: number) => 'm' + idx + '_' + m.ts
        + (m.err === true ? '_e' : '') + '_t' + this.themeEpoch + '_l' + this.languageTick)

      // **底部占位条目**：末条消息滚到底停在输入栏上方（不被挡），
      // 滚动中其他消息可从输入栏底下穿过。inputH = 输入区实测高（已含安全区让位）
      ListItem() {
        Column()
          .width('100%')
          .height(this.inputH + HwSpace.sm)
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
    .cachedCount(6)
    // **贴底判定**（键盘/面板高度补偿的防双重补偿依据）：底部占位条目
    // （index = messages.length + 1）可见即视为贴底
    .onScrollIndex((first: number, last: number) => {
      this.listAtBottom = last >= this.session.messages.length + 1;
    })
    // 宽窗版心（多屏窗口放大适配）：2in1 / 平板放大窗口后对话流居中限宽，不拉满整屏；
    // 大屏横屏再扣除左侧历史栏宽度
    .constraintSize({ maxWidth: Math.min(760, this.chatContentWidth()) })
    // 大屏横屏：版心居中发生在**剩余区域**（Stack 底部居中基于整宽，右移半个让位量）
    .translate({ x: this.chatInset() / 2 })
    .padding({
      left: HwSpace.md,
      right: HwSpace.md
    })
    // 历史抽屉打开（手机端 / 大屏竖屏）：背景模糊，同书架搜索展开
    .blur(this.drawerBlur())
    // **主题纪元拼在列表容器上**（与阅读页正文同一条铁律，第一批 117 号修复）：
    // 只改条目 key 不够——已挂载的 ListItem / 其中的 Markdown 气泡由列表复用，
    // 换**容器** key 才会把整段回复真正重建、取到新调色板；
    // 否则背景靠 @StorageProp 即时变深、正文停在旧主题 → 深底深字看不清（用户实测）。
    .key('aiMsgs_' + this.themeEpoch + '_l' + this.languageTick)
  }

  @Builder
  emptyView() {
    Column({ space: HwSpace.md }) {
      // 顶部提示：右滑唤出历史抽屉（大屏横屏历史栏常驻展开，提示没有意义）
      if (!this.aiWide()) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(11)
            .fontColor([this.palette().textTertiary])
            .rotate({ angle: 180 })
          Text(L10n.t('右滑查看历史会话'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(11, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      }

      // 问候区：渐变圆头像 + 时段问候（参考主流 AI 助手空态）
      Row({ space: 10 }) {
        Column() {
          Image($r('app.media.ai_spark'))
            .width(19)
            .height(19)
            .fillColor('#FFFFFFFF')
        }
        .width(34)
        .height(34)
        .borderRadius(17)
        .justifyContent(FlexAlign.Center)
        .linearGradient({
          angle: 135,
          colors: [[this.palette().accent, 0.0], ['#FF8E6FF0', 1.0]]
        })

        Text(greetWord())
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(19, this.uiFontScale))
          .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
          .fontColor(this.palette().textPrimary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(greetSlogan())
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(24, this.uiFontScale))
        .fontWeight(HwFont.bump(FontWeight.Bold, this.uiFontWeightDelta))
        .fontColor(this.palette().accent)
        .width('100%')

      if (AiChatStore.isConfigured(this.cfg)) {
        if (this.attachDocName.length > 0) {
          Text(L10n.t('已附加《') + this.attachDocName + '》，可直接提问、让它总结或润色')
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .width('100%')
        }
      } else {
        // 未配置引导（左对齐版式）
        Column({ space: HwSpace.sm }) {
          Text(L10n.t('还没有配置 AI 接口'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontColor(this.palette().textSecondary)
            .width('100%')
          Text(L10n.t('填入 API 地址、Key 与模型名称即可开始对话'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .width('100%')
          // **换成沉浸光感组件**（用户要求）：与全应用按钮同一套材质/降级表现
          ImmersiveChip({
            palette: this.palette(),
            chipTint: this.palette().accent,
            chipActive: true,
            chipLabel: L10n.t('去配置'),
            chipOnTap: () => {
              this.openSettings();
            }
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('92%')
    .alignItems(HorizontalAlign.Start)
  }

  // ── 消息气泡 ──

  @Builder
  bubble(m: AiChatMessage, idx: number) {
    Column({ space: 4 }) {
      // 附注：文档 / 引用（小字标注在气泡外侧，跟随气泡对齐方向）
      if (m.docName !== undefined && m.docName.length > 0) {
        Row() {
          if (m.role === 'user') {
            Blank()
          }
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.doc_text'))
              .fontSize(11)
              .fontColor([this.palette().textTertiary])
            Text(L10n.t('文档《') + m.docName + '》')
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(11, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(VerticalAlign.Center)
          if (m.role !== 'user') {
            Blank()
          }
        }
        .width('100%')
      }
      if (m.quote !== undefined && m.quote.length > 0) {
        Row() {
          if (m.role === 'user') {
            Blank()
          }
          Text('「' + m.quote + '」')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textSecondary)
            .backgroundColor(this.palette().quoteBg)
            .borderRadius(6)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .constraintSize({ maxWidth: '80%' })
          if (m.role !== 'user') {
            Blank()
          }
        }
        .width('100%')
      }

      Row() {
        if (m.role === 'user' && idx === this.editingIdx) {
          // 原位编辑态：气泡替换为编辑框（贴右侧与原气泡对齐；确认后从这条重新发送）
          Blank()
          this.editBubble(idx)
        } else {
        if (m.role === 'user') {
          Blank()
        }
        Column({ space: 6 }) {
          // 附件图片
          if (m.images !== undefined && m.images.length > 0) {
            Row({ space: 6 }) {
              ForEach(m.images, (img: string, i: number) => {
                Image(img)
                  .width(88)
                  .height(88)
                  .borderRadius(10)
                  .objectFit(ImageFit.Cover)
              }, (img: string, i: number) => 'img' + i + '_' + (img.length % 97))
            }
          }
          // 思考过程（默认收起，点击展开；thinkMs = 请求实测耗时）
          if (m.role === 'assistant' && m.thinking !== undefined && m.thinking.length > 0) {
            this.thinkingBlock(m, idx)
          }
          if (m.pending === true) {
            // 生成中：加载动画占位（回复到达后气泡原位替换并淡入）
            Row({ space: 8 }) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color(this.palette().accent)
              Text(L10n.t('正在思考…'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(13, this.uiFontScale))
                .fontColor(this.palette().textSecondary)
            }
            .alignItems(VerticalAlign.Center)
          } else if (m.role === 'assistant' && m.err !== true && m.content.trim().length > 0) {
            // AI 正常回复：Markdown 渲染（代码框 / 表格 / 列表等，与阅读页同引擎）。
            // ⚠️ 外层套**绝对值**宽度上限（bubbleContentMax）：气泡是自适应宽容器，
            // MdBlockView → ImmersiveCard 的多级 '100%' 百分比链会按外部约束解析
            // 溢出气泡（真机「内容超出气泡」），绝对值在此截断，内部百分比全部落定。
            Column() {
              this.assistantContent(m.content)
            }
            .alignItems(HorizontalAlign.Start)
            .constraintSize({ maxWidth: this.bubbleContentMax() })
          } else {
            Text(m.content)
              .fontSize(HwType.bodyDefault)
              .fontColor(m.role === 'user'
                ? '#FFFFFFFF'
                : (m.err === true ? '#FFD32F2F' : this.palette().textPrimary))
              // 默认放开划选：长按文字即可自由选择复制（用户要求）
              .copyOption(CopyOptions.LocalDevice)
              .constraintSize({ maxWidth: '100%' })
          }
          // AI 生成文档卡：点击进阅读页（禁百分比宽，卡片绝对封顶防顶破气泡）
          if (m.docs !== undefined && m.docs.length > 0) {
            Column({ space: 6 }) {
              ForEach(m.docs, (dn: string) => {
                this.docCard(dn)
              }, (dn: string) => 'dcard' + dn)
            }
            .alignItems(HorizontalAlign.Start)
          }
          if (m.role === 'assistant' && m.err !== true && m.tokens !== undefined && m.tokens > 0) {
            Text(L10n.t('本条回复 ') + fmtTokens(m.tokens) + ' 词元')
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(10, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .constraintSize({ maxWidth: '100%' })
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .borderRadius(m.role === 'user' ? 16 : 14)
        .backgroundColor(m.role === 'user'
          ? this.palette().accent
          // ⚠️ AI 回复气泡底色**强制不透明**：调色板 surface 自带 70% 透明度，
          // 透出壁纸会把正文冲淡（用户多次反馈"看不清"）。抬到 FF 保证对比度——
          // 与半模态面板同一口径（withAlpha 在 DesignTokens 里）。
          : (m.err === true ? withAlpha(this.palette().quoteBg, 'FF')
            : withAlpha(this.palette().surface, 'FF')))
        .border(m.role === 'user'
          ? { width: 0 }
          : { width: 0.8, color: this.palette().surfaceBorder })
        // 气泡 ↔ 编辑框互换时淡入淡出（显式 TransitionEffect）
        .transition(TransitionEffect.OPACITY.animation(AppearanceFx.anim(180, Curve.FastOutSlowIn)))
        if (m.role !== 'user') {
          Blank()
        }
        } // else：非编辑态原气泡
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      // 消息出现动画：占位替换为正式回复 / 新消息插入时淡入
      .transition(TransitionEffect.OPACITY.animation(AppearanceFx.anim(260, Curve.FastOutSlowIn)))

      // ── 气泡下方操作行：图标按钮 + 日期（AI 4 钮靠左 / 用户 2 钮靠右）──
      if (m.role === 'user' && idx !== this.editingIdx) {
        Row({ space: 8 }) {
          Blank()
          Text(fmtMsgTime(m.ts))
            .fontSize(HwFont.sx(10, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
          this.msgToolIcon($r('app.media.ic_public_copy'), false, (): void => {
            this.copyText(m.content);
          }, true)
          this.msgToolIcon($r('sys.symbol.square_and_pencil'), false, (): void => {
            this.editMessage(idx);
          }, false)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      } else if (m.pending !== true) {
        Row({ space: 8 }) {
          this.msgToolIcon($r('app.media.ic_public_copy'), false, (): void => {
            this.copyText(m.content);
          }, true)
          this.msgToolIcon($r('sys.symbol.doc_text'), false, (): void => {
            this.menuCreateDoc(m);
          }, false)
          this.msgToolIcon($r('sys.symbol.arrow_counterclockwise'), false, (): void => {
            this.regenerate(idx);
          }, false)
          this.msgToolIcon($r('sys.symbol.trash'), true, (): void => {
            this.deleteMessage(idx);
          }, false)
          Text(fmtMsgTime(m.ts))
            .fontSize(HwFont.sx(10, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .alignItems(m.role === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
  }

  /**
   * 气泡下方小图标钮（透明底轻量；danger = 红色标识删除）。
   * useImage：true = app.media 位图/SVG 走 Image+fillColor；false = sys.symbol 走 SymbolGlyph。
   */
  @Builder
  msgToolIcon(icon: Resource, danger: boolean, onTap: () => void, useImage: boolean) {
    Column() {
      if (useImage) {
        Image(icon)
          .width(15)
          .height(15)
          .fillColor(danger ? '#FFD32F2F' : this.palette().textTertiary)
      } else {
        SymbolGlyph(icon)
          .fontSize(14)
          .fontColor([danger ? '#FFD32F2F' : this.palette().textTertiary])
      }
    }
    .width(26)
    .height(26)
    .justifyContent(FlexAlign.Center)
    .borderRadius(13)
    .onClick(() => {
      onTap();
    })
  }

  /**
   * 气泡内卡片/折叠条/Markdown 层的最大内容宽（vp）。
   * 气泡 maxWidth 100%（List 内容区全宽，左右空隙 = List padding 对称）：
   * 内容上限 = 屏宽 − List 左右 padding 24 − 气泡左右 padding 24。
   * 气泡是自适应宽度容器，内部禁用百分比宽与 layoutWeight（会按外部约束解析顶破气泡），
   * 思考折叠条 / 文档卡 / Markdown 渲染层一律用这个绝对值封顶。
   */
  private bubbleContentMax(): number {
    // ⚠️ 必须以**列表实际可用宽**为基准，不能用窗口宽：
    // 大屏横屏下列表被版心限宽（maxWidth 760）且要让开左侧历史栏，
    // 用 rootWidth 算出来的上限（可达 1200+）远超实际可用宽（≈700），
    // 气泡与「思考过程」块按大值定宽 → 右侧被裁掉一大截（用户实测）。
    // 扣减口径：列表左右内边距 28 + 气泡内边距 24 + 4 余量 = 56。
    const w: number = Math.min(Math.min(this.rootWidth, this.chatContentWidth()), 760);
    return Math.max(180, w - 56);
  }

  /** AI 思考过程折叠条：默认收起；单开模式（同时只展开一条），chevron 旋转指示 */
  @Builder
  thinkingBlock(m: AiChatMessage, idx: number) {
    // 自适应内容宽：收起时是短条；展开时被 Scroll 定宽撑到最大（子项全部左对齐）
    Column({ space: 6 }) {
      Row({ space: 5 }) {
        Image($r('app.media.ai_spark'))
          .width(13)
          .height(13)
          .fillColor(this.palette().accent)
        Text(L10n.t('已深度思考 · ') + Math.max(1, Math.round((m.thinkMs === undefined ? 0 : m.thinkMs) / 1000)) + ' 秒')
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(13, this.uiFontScale))
          .fontColor(this.palette().textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: this.bubbleContentMax() - 49 })
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(13)
          .fontColor([this.palette().textTertiary])
          .rotate({ angle: this.thinkingOpenIdx === idx ? 90 : 0 })
      }
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        // animateTo 驱动展开/收起：折叠条高度平滑拉长/收短
        this.getUIContext().animateTo(AppearanceFx.anim(220, Curve.FastOutSlowIn), () => {
          this.thinkingOpenIdx = this.thinkingOpenIdx === idx ? -1 : idx;
        });
      })

      if (this.thinkingOpenIdx === idx) {
        Scroll() {
          Text(m.thinking === undefined ? '' : m.thinking)
            .fontSize(14)
            .fontColor(this.palette().textSecondary)
            .width('100%')
            .wordBreak(WordBreak.BREAK_ALL)
        }
        .width(this.bubbleContentMax() - 16)
        .constraintSize({ maxHeight: 240 })
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .transition(TransitionEffect.OPACITY.animation(AppearanceFx.anim(220, Curve.FastOutSlowIn)))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
    .borderRadius(10)
    .backgroundColor(this.palette().quoteBg)
  }

  // ── 输入区 ──

  @Builder
  inputArea() {
    Column({ space: HwSpace.xs }) {
      // 附件 chips 行
      if (this.attachDocName.length > 0 || this.attachQuote.length > 0
        || this.attachFiles.length > 0 || this.attachImages.length > 0) {
        Scroll() {
          Row({ space: HwSpace.xs }) {
            if (this.attachDocName.length > 0) {
              this.attachChip($r('sys.symbol.doc_text'), '《' + this.attachDocName + '》', () => {
                this.attachDocName = '';
                this.attachDocContent = '';
              })
            }
            // 文件附件：**逐个成 chip**（可多选、可逐个撤下）；大文件标注「分批」
            ForEach(this.attachFiles, (f: AiAttachFile, i: number) => {
              this.attachChip($r('sys.symbol.doc_plaintext'),
                (f.content.length > 0 ? f.name : f.name + '（' + Math.max(1, Math.round(f.size / 1024 / 1024)) + 'MB·分批）'),
                () => {
                  const kept: AiAttachFile[] = [];
                  for (let k = 0; k < this.attachFiles.length; k++) {
                    if (k !== i) {
                      kept.push(this.attachFiles[k]);
                    }
                  }
                  this.attachFiles = kept;
                })
            }, (f: AiAttachFile, i: number) => 'af' + i + '_' + f.name + '_' + f.size)
            if (this.attachQuote.length > 0) {
              this.attachChip($r('sys.symbol.text_alignleft'), '选中文本 ' + this.attachQuote.length + ' 字', () => {
                this.attachQuote = '';
              })
            }
            ForEach(this.attachImages, (img: string, i: number) => {
              Stack({ alignContent: Alignment.TopEnd }) {
                Image(img)
                  .width(40)
                  .height(40)
                  .borderRadius(8)
                  .objectFit(ImageFit.Cover)
                Circle()
                  .width(14)
                  .height(14)
                  .fill('#FF666666')
                  .margin({ right: -5, top: -5 })
              }
              .onClick(() => {
                this.attachImages.splice(i, 1);
              })
            }, (img: string, i: number) => 'chip' + i + '_' + (img.length % 89))
          }
          .padding({ left: HwSpace.md, right: HwSpace.md, top: 2, bottom: 2 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }

      // 工具行：模型 / 思考强度（添加附件已移到发送钮左侧）
      Row({ space: HwSpace.xs }) {
        ImmersiveChip({
          palette: this.palette(),
          chipLabel: this.currentModel().length > 0 ? this.currentModel() : L10n.t('未选模型'),
          chipOnTap: () => {
            this.openSheet('model');
          }
        })
        ImmersiveChip({
          palette: this.palette(),
          chipLabel: L10n.t('思考 · ') + AiChatStore.reasoningLabel(this.cfg.reasoning),
          chipOnTap: () => {
            this.openSheet('reason');
          }
        })
        Blank()
      }
      .width('100%')
      .padding({ left: HwSpace.xs, right: HwSpace.xs })

      // 输入胶囊
      ImmersiveBar({
        palette: this.palette(),
        barPaddingH: HwSpace.sm,
        barPaddingV: 6,
        barHeight: 0,
        barWidth: '100%'
      }) {
        Row({ space: HwSpace.xs }) {
          TextArea({ text: this.input, placeholder: L10n.t('问问 AI…') })
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.bodyDefault, this.uiFontScale))
            .fontColor(this.palette().textPrimary)
            .placeholderColor(this.palette().textTertiary)
            .placeholderFont({ size: HwType.bodyDefault })
            .backgroundColor(Color.Transparent)
            .constraintSize({ minHeight: 40, maxHeight: 120 })
            .layoutWeight(1)
            .onChange((v: string) => {
              this.input = v;
            })
            // 点输入框获得焦点时：若附件面板开着则收起面板（键盘与面板不共存，
            // 高度差由根容器的高度补偿接管，气泡随之平滑移动）
            .onFocus(() => {
              if (this.attachPanelOpen) {
                this.closeAttachPanel();
              }
            })

          // 附件选项开关：展开/收起输入框下方选项区（图标旋转成 ×）
          ImmersiveIconButton({
            buttonSize: 32,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              this.toggleAttachPanel();
            }
          }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(16)
              .fontColor([this.attachPanelOpen ? this.palette().accent : this.palette().textSecondary])
              .rotate({ angle: this.attachPanelOpen ? 45 : 0 })
              .animation(AppearanceFx.anim(200, Curve.FastOutSlowIn))
          }

          // 发送 / 停止（发送中点按 = 中止本次请求）
          ImmersiveIconButton({
            buttonSize: 36,
            buttonMaterialShadow: false,
            palette: this.palette(),
            buttonOnTap: () => {
              if (this.sending) {
                AiChatStore.abortChat();
              } else {
                this.send();
              }
            }
          }) {
            if (this.sending) {
              Column()
                .width(13)
                .height(13)
                .borderRadius(3)
                .backgroundColor(this.palette().accent)
            } else {
              SymbolGlyph($r('sys.symbol.paperplane'))
                .fontSize(18)
                .fontColor([this.canSend() ? this.palette().accent : this.palette().textTertiary])
            }
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      // 附件选项区（点「+」展开：输入区拉高，选项淡入；再点收起）
      if (this.attachPanelOpen) {
        Column({ space: HwSpace.sm }) {
          Divider()
            .strokeWidth(0.8)
            .color(this.palette().surfaceBorder)
          Row({ space: HwSpace.sm }) {
            this.attachOptionTile($r('sys.symbol.picture'), '图片', 0, false, (): void => {
              this.closeAttachPanel();
              this.pickImages();
            })
            this.attachOptionTile($r('app.media.ai_folder'), '文件', 1, true, (): void => {
              this.closeAttachPanel();
              this.pickFile();
            })
            this.attachOptionTile($r('app.media.ai_camera'), '拍照', 2, true, (): void => {
              this.closeAttachPanel();
              this.pickCamera();
            })
            this.attachOptionTile($r('sys.symbol.doc_text'), '应用内', 3, false, (): void => {
              this.closeAttachPanel();
              this.openSheet('doc');
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY
          .animation(AppearanceFx.anim(240, Curve.FastOutSlowIn))
          .combine(TransitionEffect.translate({ y: 12 })))
      }

      Text(L10n.t('内容由 AI 生成，仅供参考') + (this.totalTokens() > 0 ? L10n.t(' · 共 ') + fmtTokens(this.totalTokens()) + ' 词元' : ''))
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(10, this.uiFontScale))
        .fontColor(this.palette().textTertiary)
        .width('100%')
        .textAlign(TextAlign.Center)
        .opacity(0.85)
    }
    .width('100%')
    .padding({
      left: HwSpace.lg,
      right: HwSpace.lg,
      bottom: this.getUIContext().px2vp(this.safeBottomPx) + HwSpace.sm
    })
  }

  /** 附件小 chip（带 × 移除） */
  @Builder
  attachChip(icon: Resource, label: string, onRemove: () => void) {
    Row({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(12)
        .fontColor([this.palette().textSecondary])
      Text(label)
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
        .fontColor(this.palette().textSecondary)
        .maxLines(1)
        .constraintSize({ maxWidth: 150 })
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(11)
        .fontColor([this.palette().textTertiary])
    }
    .alignItems(VerticalAlign.Center)
    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
    .borderRadius(14)
    .backgroundColor(this.palette().quoteBg)
    .onClick(() => {
      onRemove();
    })
  }

  // ── 半模态面板内容（sheetEpoch 切换重建，bindSheet 不随宿主刷新）──

  @Builder
  aiSheet() {
    // 键盘垫高：BindSheet 不参与平台键盘避让（SDK 的 setKeyboardAvoidMode NOTE
    // 点名排除 BindSheet），对话面板要打字，必须在输入法上方留出可输入区
    SheetKeyboardLift() {
      if (this.sheetEpoch % 2 === 0) {
        this.aiSheetInner()
      } else {
        this.aiSheetInner()
      }
    }
  }

  @Builder
  aiSheetInner() {
    Column() {
      if (this.sheetKind === 'history') {
        this.historySheet()
      } else if (this.sheetKind === 'model') {
        this.modelSheet()
      } else if (this.sheetKind === 'reason') {
        this.reasonSheet()
      } else if (this.sheetKind === 'doc') {
        this.docSheet()
      } else if (this.sheetKind === 'code') {
        this.codeSheet()
      }
    }
    .width('100%')
  }

  /** 代码放大面板内容：等宽字号滚动展示（长代码可滚，底部留白）。 */
  @Builder
  codeSheet() {
    Scroll() {
      Text(this.codeSheetText)
        .fontSize(13)
        .fontFamily('monospace')
        .fontColor(this.palette().textPrimary)
        .width('100%')
    }
    .width('100%')
    .constraintSize({ maxHeight: 420 })
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
    .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.lg })
  }

  /** 面板内列表行壳：统一内边距与滚动 */
  @Builder
  sheetWrap(content: string) {
    Scroll() {
      Column({ space: HwSpace.xs }) {
        if (content === 'history') {
          this.historySheetInner()
        } else if (content === 'doc') {
          this.docSheetInner()
        }
      }
      .width('100%')
      .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.lg })
    }
    .width('100%')
    .constraintSize({ maxHeight: 420 })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
  }

  @Builder
  historySheet() {
    if (this.sessionList.length === 0) {
      Column({ space: HwSpace.sm }) {
        Text(L10n.t('还没有历史对话'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.bodyDefault, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
      }
      .width('100%')
      .padding({ top: 24, bottom: 32 })
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      this.sheetWrap('history')
    }
  }

  @Builder
  historySheetInner() {
    ForEach(this.sessionList, (b: AiChatSessionBrief) => {
      ImmersiveCard({
        palette: this.palette(),
        cardRadius: HwRadius.inline,
        cardPadding: HwSpace.sm,
        cardMaterialShadow: false,
        cardBackground: this.palette().quoteBg,
        cardClickable: true,
        cardOnTap: () => {
          // ArkUI 无 stopPropagation：trash 的 onClick 先执行置位，这里读到即跳过恢复
          if (this.deleteTapped) {
            this.deleteTapped = false;
            return;
          }
          this.restoreSession(b);
        }
      }) {
        Row({ space: HwSpace.sm }) {
          Column({ space: 2 }) {
            Text(b.title)
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.bodyDefault, this.uiFontScale))
              .fontColor(this.palette().textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(b.count + ' 条' + (b.tokens > 0 ? ' · ' + fmtTokens(b.tokens) + ' 词元' : '')
              + ' · ' + fmtTime(b.updated))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          // 正在后台生成的会话：行尾加载动画（用户要求：一眼看出哪条还在写）
          if (AiChatStore.isGenerating(b.id)) {
            LoadingProgress()
              .width(14)
              .height(14)
              .color(this.palette().accent)
          }

          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(16)
            .fontColor([this.palette().textTertiary])
            .onClick(() => {
              this.deleteTapped = true;
              this.removeSession(b);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }, (b: AiChatSessionBrief) => b.id + '_' + b.count)
  }

  @Builder
  modelSheet() {
    Column({ space: HwSpace.xs }) {
      if (this.totalModelCount() === 0) {
        Text(L10n.t('还没有配置模型，请先到「AI 设置」添加'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
          .padding({ top: 12, bottom: 24 })
      }
      // 多 API：按配置分组列模型（小节标题 = API 名称），点击同时切到该 API
      ForEach(this.cfg.profiles, (p: AiApiProfile, pi: number) => {
        if (p.models.length > 0) {
          Text(p.name)
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
            .fontColor(this.palette().textTertiary)
            .padding({ top: 6, bottom: 2, left: 4 })
            .width('100%')
        }
        ForEach(p.models, (m: string) => {
          // 「我的收藏」同款形状：外层 Column 挂圆角+描边，内层 ImmersiveCard 光感 + accentSoft 薄染
          Column() {
            ImmersiveCard({
              palette: this.palette(),
              cardRadius: HwRadius.card,
              cardPadding: HwSpace.sm,
              cardMaterialShadow: false,
              cardBackground: this.palette().accentSoft,
              cardClickable: true,
              cardOnTap: () => {
                this.cfg.currentModel = m;
                // 多 API：选到哪个组的模型就切到哪个 API（镜像顶层，请求链路透明）
                AiChatStore.activateProfile(this.cfg, pi);
                const c: common.UIAbilityContext | null = this.ctx();
                if (c !== null) {
                  AiChatStore.saveConfig(c, this.cfg);
                }
                this.closeSheet();
              }
            }) {
              Row({ space: HwSpace.sm }) {
                Text(m)
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(HwType.bodyDefault, this.uiFontScale))
                  .fontColor(this.currentModel() === m
                    ? this.palette().accent
                    : this.palette().textPrimary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                if (this.currentModel() === m && this.cfg.activeProfile === pi) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(16)
                    .fontColor([this.palette().accent])
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }
          }
          .width('100%')
          .borderRadius(HwRadius.card)
          .border({ width: 1, color: this.palette().divider })
        }, (m: string) => 'mdl_' + pi + '_' + m)
      }, (p: AiApiProfile, pi: number) => 'prof_' + pi + '_' + p.name)
    }
    .width('100%')
    .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.lg })
  }

  @Builder
  reasonSheet() {
    Column({ space: HwSpace.xs }) {
      this.reasonRow(0, '关闭', '不发送思考参数，速度最快')
      this.reasonRow(1, '标准', 'reasoning_effort = medium，常规思考')
      this.reasonRow(2, '深度', 'reasoning_effort = high，复杂问题更缜密但更慢')
    }
    .width('100%')
    .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.lg })
  }

  @Builder
  reasonRow(value: number, label: string, desc: string) {
    // 「我的收藏」同款形状：外层圆角+描边，内层 ImmersiveCard 光感
    Column() {
      ImmersiveCard({
        palette: this.palette(),
        cardRadius: HwRadius.card,
        cardPadding: HwSpace.sm,
        cardMaterialShadow: false,
        cardBackground: this.palette().accentSoft,
        cardClickable: true,
        cardOnTap: () => {
          this.cfg.reasoning = value;
          const c: common.UIAbilityContext | null = this.ctx();
          if (c !== null) {
            AiChatStore.saveConfig(c, this.cfg);
          }
          this.closeSheet();
        }
      }) {
        Row({ space: HwSpace.sm }) {
          Column({ space: 2 }) {
            Text(label)
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.bodyDefault, this.uiFontScale))
              .fontColor(this.cfg.reasoning === value
                ? this.palette().accent
                : this.palette().textPrimary)
            Text(desc)
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (this.cfg.reasoning === value) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(16)
              .fontColor([this.palette().accent])
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .borderRadius(HwRadius.card)
    .border({ width: 1, color: this.palette().divider })
  }

  @Builder
  docSheet() {
    if (this.docList.length === 0) {
      Column() {
        Text(L10n.t('书架还没有文档'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.bodyDefault, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
      }
      .width('100%')
      .padding({ top: 24, bottom: 32 })
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      this.sheetWrap('doc')
    }
  }

  @Builder
  docSheetInner() {
    ForEach(this.docList, (meta: DocMeta) => {
      // 「我的收藏」同款形状：外层圆角+描边，内层 ImmersiveCard 光感
      Column() {
        ImmersiveCard({
          palette: this.palette(),
          cardRadius: HwRadius.card,
          cardPadding: HwSpace.sm,
          cardMaterialShadow: false,
          cardBackground: this.palette().accentSoft,
          cardClickable: true,
          cardOnTap: () => {
            this.attachInAppDoc(meta);
          }
        }) {
          Row({ space: HwSpace.sm }) {
            SymbolGlyph($r('sys.symbol.doc_text'))
              .fontSize(16)
              .fontColor([this.palette().accent])
            Text(meta.name)
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.bodyDefault, this.uiFontScale))
              .fontColor(this.attachDocName === meta.name
                ? this.palette().accent
                : this.palette().textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.attachDocName === meta.name) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(16)
                .fontColor([this.palette().accent])
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')
      .borderRadius(HwRadius.card)
      .border({ width: 1, color: this.palette().divider })
    }, (meta: DocMeta) => 'doc_' + meta.name)
  }

  @Builder
  attachOptionTile(icon: Resource, label: string, idx: number, useImage: boolean, onTap: () => void) {
    Column({ space: 4 }) {
      if (useImage) {
        Image(icon)
          .width(18)
          .height(18)
          .fillColor(this.palette().textPrimary)
      } else {
        SymbolGlyph(icon)
          .fontSize(18)
          .fontColor([this.palette().textPrimary])
      }
      Text(label)
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(11.5, this.uiFontScale))
        .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
        .fontColor(this.palette().textPrimary)
    }
    .layoutWeight(1)
    .height(54)
    .justifyContent(FlexAlign.Center)
    .borderRadius(14)
    .backgroundColor(this.palette().quoteBg)
    // 按压过渡动画：缩小 + 变淡（弹回 150ms）
    .scale({
      x: this.attachPressIdx === idx ? 0.94 : 1,
      y: this.attachPressIdx === idx ? 0.94 : 1
    })
    .opacity(this.attachPressIdx === idx ? 0.78 : 1)
    .animation(AppearanceFx.anim(150, Curve.EaseOut))
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.attachPressIdx = idx;
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        if (this.attachPressIdx === idx) {
          this.attachPressIdx = -1;
        }
      }
    })
    .onClick(() => {
      onTap();
    })
  }

  // ── Token 用量 ──

  /** 会话累计词元（所有 assistant 回复求和） */
  private totalTokens(): number {
    let t: number = 0;
    for (let i = 0; i < this.session.messages.length; i++) {
      const tk: number | undefined = this.session.messages[i].tokens;
      if (tk !== undefined) {
        t += tk;
      }
    }
    return t;
  }

  // ── 消息长按菜单 ──

  private copyText(text: string): void {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.toast(L10n.t('已复制到剪贴板'));
      });
    } catch (err) {
      this.toast(L10n.t('复制失败'));
    }
  }

  /** 「生成文档」：把这条消息的正文存为书架新文档 */
  private menuCreateDoc(m: AiChatMessage): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    const meta: DocMeta | null = DocStore.create(c, deriveDocName(m.content), m.content);
    if (meta === null) {
      this.toast(L10n.t('保存失败：文档名不合法'));
      return;
    }
    this.toast('已保存《' + meta.name + '》');
  }

  private deleteMessage(idx: number): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (idx < 0 || idx >= this.session.messages.length) {
      return;
    }
    const list: AiChatMessage[] = this.session.messages.slice();
    list.splice(idx, 1);
    this.session.messages = list;
    this.session.updated = Date.now();
    if (c !== null) {
      AiChatStore.saveSession(c, this.session);
    }
    this.toast(L10n.t('已删除这条消息'));
  }

  /** 打开 AI 生成 / 保存的文档（与书架同款路由参数） */
  private openDoc(name: string): void {
    if (this.stack === null) {
      return;
    }
    const route: ReaderRoute = { name: name };
    this.stack.pushPath({ name: 'pages/Reader', param: route }, AppearanceFx.navAnimated());
  }

  /** AI 回复正文：与阅读页同引擎的 Markdown 块渲染（标题/列表/表格/代码框/引用等）。
   *  批注 / 任务勾选 / 表格编辑 / 放大 / 图片点击等回调刻意不传（默认空实现 = 点击无反应）。
   *  **长按 = 系统选择菜单**（用户明确要求，两次纠正后实锤）：对话页是只读展示场景，
   *  传 alwaysSystemSelect 让所有块直接走系统选择分支（含代码块），不弹应用批注菜单。 */
  @Builder
  assistantContent(content: string) {
    // ⚠️ 块级 key 必须带主题纪元：深浅切换后 MdBlockView 会被 ForEach 复用、
    // 内部取色停在旧主题（阅读页同源问题），带上纪元即整批重建。
    ForEach(MdParser.parse(content).blocks, (b: MdBlock) => {
      MdBlockView({
        block: b,
        palette: this.palette(),
        bodySize: HwType.bodyDefault,
        fontKey: this.bodyFontKey,
        uiFontKey: this.uiFontKey,
        uiFontScale: this.uiFontScale,
        uiFontWeightDelta: this.uiFontWeightDelta,
        dark: this.isDark(),
        alwaysSystemSelect: true,
        // 代码块 / 图表「放大查看」：**统一走全屏放大浮层**（与阅读页同一套界面）——
        // 代码块也走它（mode='code' 由 render/code.html 渲染带行号的等宽代码），
        // 不再用半模态面板（用户要求：放大界面与阅读页一致）；image 暂不处理。
        enlargeHandler: (mode: string, payload: string, geoKey: string, title: string) => {
          if (mode !== 'image') {
            this.openChartEnlarge(mode, payload, title);
          }
        }
      })
    }, (b: MdBlock) => {
      // 读取公式就绪信号以建立依赖（同阅读页图表条目 key 机制）：
      // 图就绪 → formulaTick 变 → 含该公式的气泡重建 → 线性化文字换成图
      const ft: number = this.formulaTick;
      // 引擎开关（设置 → 引擎管理）变化也要重建：公式回落文字 / 恢复出图
      return 'aib' + b.id + '_t' + this.themeEpoch + (ft >= 0 ? this.formulaSuffix(b) : '')
        + '_e' + this.disabledEngineList;
    })
  }

  /** AI 生成文档卡（气泡内；点击进阅读页）。宽度用绝对封顶，禁百分比/layoutWeight（会顶破气泡） */
  @Builder
  docCard(name: string) {
    Row({ space: 8 }) {
      Image($r('app.media.ai_spark'))
        .width(16)
        .height(16)
        .fillColor(this.palette().accent)
      Column({ space: 1 }) {
        Text(name)
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
          .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
          .fontColor(this.palette().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: this.bubbleContentMax() - 64 })
        Text(L10n.t('已保存到书架 · 点击打开'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(10, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
      }
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(12)
        .fontColor([this.palette().textTertiary])
    }
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor(this.palette().quoteBg)
    .onClick(() => {
      this.openDoc(name);
    })
  }

  /** 用户消息原位编辑框（替代气泡）：取消还原，发送从该条重写历史并重新请求 */
  @Builder
  editBubble(idx: number) {
    Column({ space: 8 }) {
      TextArea({ text: this.editText })
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(HwType.bodyDefault, this.uiFontScale))
        .fontColor(this.palette().textPrimary)
        .placeholderColor(this.palette().textTertiary)
        .backgroundColor(this.palette().quoteBg)
        .borderRadius(10)
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .constraintSize({ minHeight: 72, maxHeight: 180 })
        .onChange((v: string) => {
          this.editText = v;
        })
      Row({ space: 8 }) {
        Text(L10n.t('取消'))
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
          .fontColor(this.palette().textSecondary)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(18)
          .backgroundColor(this.palette().quoteBg)
          .onClick(() => {
            // 收起编辑框也走动画（与展开对称）
            this.getUIContext().animateTo(AppearanceFx.anim(220, Curve.FastOutSlowIn), () => {
              this.editingIdx = -1;
              this.editText = '';
            });
          })
        Blank()
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.paperplane'))
            .fontSize(13)
            .fontColor(['#FFFFFFFF'])
          Text(L10n.t('发送'))
            .fontFamily(HwFont.resolve(this.uiFontKey))
            .fontSize(HwFont.sx(HwType.label, this.uiFontScale))
            .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
            .fontColor('#FFFFFFFF')
        }
        .alignItems(VerticalAlign.Center)
        .padding({ left: 18, right: 18, top: 8, bottom: 8 })
        .borderRadius(18)
        .backgroundColor(this.palette().accent)
        .onClick(() => {
          this.commitEdit(idx);
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(10)
    .borderRadius(16)
    .backgroundColor(this.palette().surface)
    .border({ width: 0.8, color: this.palette().surfaceBorder })
    // **展开 / 收起过渡**：从右上方（原气泡那一侧）放大淡入、反向缩回。
    // 用显式 TransitionEffect.animation 形式，不依赖 animateTo。
    .transition(TransitionEffect.OPACITY
      .animation(AppearanceFx.anim(200, Curve.FastOutSlowIn))
      .combine(TransitionEffect.scale({ x: 0.94, y: 0.94, centerX: '100%', centerY: '0%' })))
  }

  /**
   * 右滑抽屉：历史对话按日期分组（ImmersiveSheetPanel 全高外壳，同阅读页目录抽屉）。
   * openDrawer 已刷新 sessionList；行点击恢复 + 收抽屉，trash 先置 deleteTapped 防误恢复。
   */
  @Builder
  historyDrawer() {
    ImmersiveSheetPanel({
      palette: this.palette(),
      panelRadius: HwRadius.sheet,
      panelPadding: HwSpace.md,
      panelHeight: '100%',
      panelScrollable: false
    }) {
      Column({ space: HwSpace.sm }) {
        Row({ space: HwSpace.sm }) {
          Column({ space: 2 }) {
            Text(L10n.t('历史对话'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.label + 3, this.uiFontScale))
              .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
              .fontColor(this.palette().textPrimary)
            // 大屏横屏是固定侧栏，没有「右滑唤出」的概念
            Text(this.aiWide()
              ? this.sessionList.length + ' 个话题'
              : this.sessionList.length + ' 个话题 · 右滑可随时唤出')
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          // 关闭按钮只在「抽屉形态」出现（大屏横屏固定侧栏常驻展开，无关闭概念）
          if (!this.aiWide()) {
            ImmersiveIconButton({
              buttonSize: 32,
              buttonMaterialShadow: false,
              palette: this.palette(),
              buttonOnTap: () => {
                this.closeDrawer();
              }
            }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(15)
                .fontColor([this.palette().textPrimary])
            }
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 「新建对话」紧凑胶囊（ImmersiveCard 承载层带沉浸光感）。
        // ⚠️ **必须用定尺寸外层 Row 包住**：抽屉内容 Column 是 height('100%') 定高环境，
        // ImmersiveCard 根 Stack 自适应高时其 matchParent 材质层会取「父约束上限」，
        // 把卡片撑到整个抽屉高（巨色胶囊、透出背后页面——真机截图实锤）。
        // 外层 Row 定高 36 掐断高度传导、cardWidth 定值掐断宽度传导，双保险。
        Row() {
          ImmersiveCard({
            palette: this.palette(),
            cardRadius: HwRadius.pill,
            cardPadding: 0,
            cardMaterialShadow: false,
            cardBackground: this.palette().quoteBg,
            cardWidth: 112,
            cardClickable: true,
            cardOnTap: () => {
              this.closeDrawer();
              this.newChat();
            }
          }) {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.plus'))
                .fontSize(14)
                .fontColor([this.palette().textPrimary])
              Text(L10n.t('新建对话'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(13, this.uiFontScale))
                .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
                .fontColor(this.palette().textPrimary)
                .maxLines(1)
            }
            .width('100%')
            .height(36)
            .justifyContent(FlexAlign.Center)
          }
        }
        .height(36)

        if (this.sessionList.length === 0) {
          Column({ space: HwSpace.sm }) {
            Text(L10n.t('还没有历史对话'))
              .fontFamily(HwFont.resolve(this.uiFontKey))
              .fontSize(HwFont.sx(HwType.bodyDefault, this.uiFontScale))
              .fontColor(this.palette().textTertiary)
          }
          .width('100%')
          .padding({ top: 32 })
          .alignItems(HorizontalAlign.Center)
        } else {
          Scroll() {
            Column({ space: HwSpace.sm }) {
              ForEach(this.drawerGroups(this.sessionList), (g: AiDrawerGroup) => {
              Column({ space: HwSpace.xs }) {
                Text(g.label)
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(HwType.caption, this.uiFontScale))
                  .fontColor(this.palette().textTertiary)
                  .width('100%')
                  .padding({ left: 4, top: 6, bottom: 2 })
                ForEach(g.items, (b: AiChatSessionBrief) => {
                  // 纯文字列表行（参考元宝侧边栏）：当前会话 accent + 圆点，行尾淡色删除
                  Row({ space: 8 }) {
                    if (this.session.id === b.id) {
                      Column()
                        .width(5)
                        .height(5)
                        .borderRadius(2.5)
                        .backgroundColor(this.palette().accent)
                    }
                    Text(b.title)
                      .fontFamily(HwFont.resolve(this.uiFontKey))
                      .fontSize(HwFont.sx(15, this.uiFontScale))
                      .fontWeight(HwFont.bump(this.session.id === b.id ? FontWeight.Medium : FontWeight.Normal,
                        this.uiFontWeightDelta))
                      .fontColor(this.session.id === b.id
                        ? this.palette().accent
                        : this.palette().textPrimary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    // 正在后台生成的会话：加载动画（用户要求）
                    if (AiChatStore.isGenerating(b.id)) {
                      LoadingProgress()
                        .width(13)
                        .height(13)
                        .color(this.palette().accent)
                    }
                    Text(b.count + ' 条')
                      .fontFamily(HwFont.resolve(this.uiFontKey))
                      .fontSize(HwFont.sx(11, this.uiFontScale))
                      .fontColor(this.palette().textTertiary)
                    SymbolGlyph($r('sys.symbol.trash'))
                      .fontSize(14)
                      .fontColor(['#E5483D'])
                      .opacity(0.85)
                      .onClick(() => {
                        // 子先父后：trash 先置位，整行 onClick 读到即跳过恢复
                        this.deleteTapped = true;
                        this.removeSession(b);
                      })
                  }
                  .width('100%')
                  .padding({ left: 4, right: 4, top: 10, bottom: 10 })
                  .borderRadius(10)
                  .onClick(() => {
                    this.restoreFromDrawer(b);
                  })
                }, (b: AiChatSessionBrief) => b.id + '_' + b.count)
              }
              .width('100%')
            }, (g: AiDrawerGroup) => g.label + '_' + g.items.length)
            }
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')
      // 顶部让出系统状态栏（全高面板内容此前顶进状态栏里）
      .padding({ top: this.getUIContext().px2vp(this.safeTopPx) })
    }
  }
}
