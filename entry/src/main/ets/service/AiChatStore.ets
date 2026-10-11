/**
 * 澄笺 · AI 助手数据层（1.2.0）
 * ==============================
 *
 * 三块职责：
 *  ① API 配置持久化（filesDir/ai/config.json）：
 *     API 地址 / API Key / 模型列表 / 系统提示词 / 思考强度；
 *  ② 会话历史持久化（filesDir/ai/sessions/<id>.json）：
 *     多会话、可恢复、可删除，全部走全量备份（BackupStore 拉整个 filesDir）；
 *  ③ 请求封装（非流式 + 图片 vision + 思考强度 + Token 统计 + 文档生成协议）：
 *     · OpenAI 兼容：POST /chat/completions，Bearer 鉴权，reasoning_effort；
 *     · Anthropic：POST /v1/messages，x-api-key + anthropic-version 头，
 *       system 独立字段，图片走 base64 source，思考强度映射 thinking budget。
 *     协议按 API 地址自动探测（含 anthropic 或 /messages 即走 Anthropic）。
 *
 * 实现说明：
 *  · 消息里的图片（dataURL base64）只用于**当次请求**；落盘副本会丢弃 base64，
 *    否则一张几 MB 的图会把历史文件撑爆，历史重发也只需要文字上下文。
 *  · 「文档工具协议」：系统提示词里约定 <doc name="文档名">完整正文</doc> 标记，
 *    AI 要生成/修改文档时用标记输出完整 Markdown；对话页负责解析标记并真正
 *    落盘到书架（DocStore.create 同名自动编号），由此打通「AI 生成文件」闭环。
 *  · Token 用量：OpenAI 取 usage.completion_tokens、Anthropic 取 usage.output_tokens
 *    （即"本条回复的输出词元"），存到消息 tokens 字段随会话落盘；历史面板与
 *    工具行做求和展示。会话总消耗 ≈ 求和（提示词部分各网关口径不一，不重复计）。
 *  · 「思考强度」：OpenAI 映射 reasoning_effort（关闭档不发送该字段）；
 *    Anthropic 映射 thinking budget（关闭档不带 thinking）。
 *  · API 地址自动规整：填 base 地址会按协议补全到 /chat/completions 或 /v1/messages。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';

/** 一份 API 配置（多 API 支持：不同网关各自的地址 / Key / 模型清单） */
export interface AiApiProfile {
  /** 显示名（如「DeepSeek 官方」；默认 API 1/2/3，可在设置页改） */
  name: string;
  /** 接口完整地址（保存时自动补全；含 anthropic 或 /messages 走 Anthropic 协议） */
  apiUrl: string;
  apiKey: string;
  /** 该网关的候选模型 */
  models: string[];
}

/** AI 接口配置（filesDir/ai/config.json） */
export interface AiChatConfig {
  /** 生效镜像 = profiles[activeProfile] 的地址（请求链路都读这三项，保持兼容） */
  apiUrl: string;
  apiKey: string;
  /** 生效镜像 = profiles[activeProfile] 的模型清单 */
  models: string[];
  /** 系统提示词（可空；全局共用，不随 API 切换） */
  systemPrompt: string;
  /** 思考强度：0 关闭 · 1 标准 · 2 深度 */
  reasoning: number;
  /** 当前选中的模型（空 = 用 models 第一个） */
  currentModel: string;
  /** 多 API 配置列表（1.2.x：旧单 API 配置加载时自动迁移成单条 profile） */
  profiles: AiApiProfile[];
  /** 生效的 profile 下标 */
  activeProfile: number;
}

/** 一条消息。err = 展示为错误样式（不进 API 历史） */
export interface AiChatMessage {
  role: string;
  content: string;
  /** 附件图片（dataURL，仅当次请求用，落盘时丢弃） */
  images?: string[];
  ts: number;
  err?: boolean;
  /** 该条消息发送时附加的应用内文档名（气泡上标注） */
  docName?: string;
  /** 该条消息引用的选中文本（气泡上标注） */
  quote?: string;
  /** assistant：本条回复生成的文档名（气泡渲染文档卡，点击进阅读页） */
  docs?: string[];
  /** assistant：本条回复的输出词元数（usage 口径，随会话落盘） */
  tokens?: number;
  /** assistant：产生本条回复的模型名（设置页按模型统计词元消耗的数据源） */
  model?: string;
  /** assistant：思考过程文本（OpenAI 兼容 reasoning_content / Anthropic thinking 块） */
  thinking?: string;
  /** assistant：思考耗时（毫秒，请求发出到回复到达的实测时长） */
  thinkMs?: number;
  /** assistant：生成中占位气泡（气泡内显示加载动画，回复到达后原位替换） */
  pending?: boolean;
}

/** 一个会话 */
export interface AiChatSession {
  id: string;
  title: string;
  created: number;
  updated: number;
  /** 会话关联的应用内文档（空 = 闲聊会话） */
  docName: string;
  messages: AiChatMessage[];
}

/** 会话摘要（历史面板行） */
export interface AiChatSessionBrief {
  id: string;
  title: string;
  updated: number;
  count: number;
  /** 会话累计词元（所有 assistant 回复求和） */
  tokens: number;
}

/** 请求结果：ok=false 时 text 为给用户看的错误说明 */
export interface AiChatResult {
  ok: boolean;
  text: string;
  /** 本条回复的输出词元（网关没回 usage 时为 0/缺省） */
  tokens?: number;
  /** 思考过程文本（网关没返回思考内容时缺省） */
  thinking?: string;
  /** 用户主动停止：不当作错误处理 */
  aborted?: boolean;
}

/** 按模型聚合的词元消耗（AI 设置页统计区） */
export interface AiTokenStat {
  model: string;
  /** 该模型的回复条数 */
  replies: number;
  /** 该模型的输出词元总数 */
  tokens: number;
}

/** 单个时间段的词元消耗（时间维格子） */
export interface AiTokenBucket {
  replies: number;
  tokens: number;
}

/** 单个自然年的词元消耗（历年列表） */
export interface AiTokenYearStat {
  year: number;
  replies: number;
  tokens: number;
}

/** 词元消耗全景（AI 设置页统计区：总计 + 时间维 + 历年 + 按模型） */
export interface AiTokenUsage {
  /** 总计 */
  totalReplies: number;
  totalTokens: number;
  /** 今天 0 点起 */
  today: AiTokenBucket;
  /** 昨天一个自然日 */
  yesterday: AiTokenBucket;
  /** 近 7 天（滑动窗口） */
  week: AiTokenBucket;
  /** 近 30 天 */
  month: AiTokenBucket;
  /** 近半年（183 天） */
  halfYear: AiTokenBucket;
  /** 近一年（365 天） */
  year: AiTokenBucket;
  /** 按年聚合，年降序 */
  years: AiTokenYearStat[];
  /** 按模型聚合，词元降序 */
  models: AiTokenStat[];
}

/** 文档落盘结果（对话页 materializeDocs 用） */
export interface AiDocGenResult {
  /** 替换标记后的展示文本 */
  text: string;
  /** 实际创建的文档名（同名自动编号后的最终名） */
  names: string[];
}

// ── OpenAI 兼容请求 / 响应形状（ArkTS 不认 any，全部显式建模） ──

interface AiApiImageUrl {
  url: string;
}

/** 多模态片段：text 片段不带 image_url，图片片段 text 留空（服务端按 type 取用） */
interface AiApiPart {
  type: string;
  text: string;
  image_url?: AiApiImageUrl;
}

interface AiApiMessage {
  role: string;
  content: string | AiApiPart[];
}

interface AiApiBody {
  model: string;
  messages: AiApiMessage[];
  stream: boolean;
  max_tokens?: number;
  reasoning_effort?: string;
}

interface AiApiRespMessage {
  content?: string;
  /** 思考过程（DeepSeek R1 等 OpenAI 兼容网关的推理内容字段） */
  reasoning_content?: string;
}

interface AiApiRespChoice {
  message?: AiApiRespMessage;
}

interface AiOpenUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
}

interface AiApiResp {
  choices?: AiApiRespChoice[];
  usage?: AiOpenUsage;
}

// ── Anthropic /v1/messages 请求 / 响应形状 ──

interface AiAntSource {
  type: string;
  media_type: string;
  data: string;
}

interface AiAntPart {
  type: string;
  text: string;
  source?: AiAntSource;
}

interface AiAntMessage {
  role: string;
  content: string | AiAntPart[];
}

interface AiAntThinking {
  type: string;
  budget_tokens: number;
}

interface AiAntBody {
  model: string;
  messages: AiAntMessage[];
  system?: string;
  /** Anthropic 必填 */
  max_tokens: number;
  stream: boolean;
  thinking?: AiAntThinking;
}

interface AiAntBlock {
  type: string;
  text: string;
  /** type === 'thinking' 块的思考正文 */
  thinking?: string;
}

interface AiAntUsage {
  input_tokens?: number;
  output_tokens?: number;
}

interface AiAntResp {
  content?: AiAntBlock[];
  usage?: AiAntUsage;
}

interface AiApiErrInner {
  message?: string;
}

interface AiApiErr {
  error?: AiApiErrInner;
}

/** 文档正文注入上限（字符）：超大文档截断，避免请求体失控 */
export const AI_DOC_LIMIT: number = 60000;

/** 引用文本上限（字符） */
export const AI_QUOTE_LIMIT: number = 2000;

/** 文档生成标记（与 AiChat.ets 的解析逻辑严格成对） */
export const AI_DOC_TAG_OPEN: string = '<doc name="';
export const AI_DOC_TAG_CLOSE: string = '</doc>';

/**
 * 预装系统提示词（用户在设置里没写系统提示词时自动启用；写了则完全覆盖）。
 * 定位：澄笺是 Markdown 阅读写作应用 → 助手按 Markdown 优先的方式回答。
 */
export const AI_DEFAULT_SYSTEM_PROMPT: string =
  '你是「澄笺」内置的 AI 写作助手，用户在一款 Markdown 阅读与写作应用中与你对话。默认遵守：\n'
  + '1. 用 Markdown 组织回答：合理使用标题、列表、表格、引用与加粗；\n'
  + '2. 代码一律放进围栏代码块并标注语言，给出完整、可直接使用的示例；\n'
  + '3. 涉及写作任务（大纲、润色、续写、总结、改写）时，直接给出可粘贴到文档的 Markdown 成品；\n'
  + '4. 数学公式用 LaTeX 写法：行内公式夹在 $ 中间，独立公式单独成段用 $$ 包裹；\n'
  + '5. 默认使用简体中文，回答务实、准确，不堆砌客套话。';

/** 文档工具协议（system 注入；标记由对话页解析并落盘到书架） */
function docToolPrompt(docNames: string[]): string {
  let p: string = '【文档能力】你可以直接为用户生成或修改 Markdown 文档。'
    + '当需要给出完整文档正文（生成、修改、润色、续写成文等）时，用以下标记输出：\n'
    + '<doc name="文档名">完整正文</doc>\n'
    + '规则：正文必须是完整 Markdown 全文，不要省略；每个文档一个标记；'
    + '文档名不带路径；修改已有文档沿用原文档名，新建时起简洁标题；'
    + '标记外只写简短说明。用户端会自动把标记保存为书架文档并展示成文档卡。'
    + '注意：只读文档用户端不会改动原文，会自动另存为「xx 修改版」新文档；'
    + '可写文档修改原文前用户端会自动把原版存为快照文档（可在书架回退），无需你在回复中额外说明。';
  if (docNames.length > 0) {
    const max: number = docNames.length > 40 ? 40 : docNames.length;
    let names: string = '';
    for (let i = 0; i < max; i++) {
      names += (i > 0 ? '、' : '') + docNames[i];
    }
    p += '\n用户书架现有文档：' + names + '。';
  }
  return p;
}

export class AiChatStore {
  // ── 目录 ──

  private static aiDir(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/ai';
  }

  private static sessionsDir(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/ai/sessions';
  }

  private static ensureDir(path: string): void {
    try {
      if (!fs.accessSync(path)) {
        fs.mkdirSync(path, true);
      }
    } catch (err) {
      try {
        fs.mkdirSync(path, true);
      } catch (e) {
        // 目录创建失败交由上层写文件时报错
      }
    }
  }

  // ── 配置 ──

  /**
   * 空配置工厂（**每次新建**：migrateConfig 会往 profiles 里 push，
   * 若共用一个模块级常量会被就地改写）。
   */
  private static emptyConfig(): AiChatConfig {
    return {
      apiUrl: '',
      apiKey: '',
      models: [],
      systemPrompt: '',
      reasoning: 1,
      currentModel: '',
      profiles: [],
      activeProfile: 0
    };
  }

  static loadConfig(ctx: common.UIAbilityContext): AiChatConfig {
    const path: string = AiChatStore.aiDir(ctx) + '/config.json';
    let cfg: AiChatConfig = AiChatStore.emptyConfig();
    try {
      if (fs.accessSync(path)) {
        const text: string = fs.readTextSync(path);
        const raw: AiChatConfig = JSON.parse(text) as AiChatConfig;
        // 字段兜底（老文件缺字段不崩）
        cfg = {
          apiUrl: raw.apiUrl === undefined ? '' : raw.apiUrl,
          apiKey: raw.apiKey === undefined ? '' : raw.apiKey,
          models: raw.models === undefined ? [] : raw.models,
          systemPrompt: raw.systemPrompt === undefined ? '' : raw.systemPrompt,
          reasoning: raw.reasoning === undefined ? 1 : raw.reasoning,
          currentModel: raw.currentModel === undefined ? '' : raw.currentModel,
          profiles: raw.profiles === undefined ? [] : raw.profiles,
          activeProfile: raw.activeProfile === undefined ? 0 : raw.activeProfile
        };
      }
    } catch (err) {
      cfg = AiChatStore.emptyConfig();
    }
    // ⚠️ **唯一出口必须过 migrateConfig**（历史 bug：文件不存在 / 解析失败时直接 return
    // 空配置，profiles 为空数组绕过补全 → 设置页 profiles[0] 取到 undefined →
    // 保存 / 测试连接时 `act.apiUrl` 抛 TypeError 直接杀进程，真机 JsCrash 栈实证：
    // formConfig → test → cardOnTap。这里保证 profiles 恒非空。）
    return AiChatStore.migrateConfig(cfg);
  }

  /**
   * 多 API 迁移与生效镜像（loadConfig 出口统一过一遍）：
   * ① 旧单 API 配置（profiles 为空）→ 顶层字段迁移成单条 profile「API 1」；
   * ② activeProfile 越界 → 钳回 0；
   * ③ 把 profiles[activeProfile] 镜像到顶层 apiUrl/apiKey/models——
   *    请求链路（requestOpenAI / requestAnthropic / isConfigured / 测试连接）都读顶层三项，
   *    镜像后多 API 切换对它们完全透明。
   */
  static migrateConfig(cfg: AiChatConfig): AiChatConfig {
    if (cfg.profiles.length === 0) {
      const p: AiApiProfile = {
        name: 'API 1',
        apiUrl: cfg.apiUrl,
        apiKey: cfg.apiKey,
        models: cfg.models
      };
      cfg.profiles.push(p);
      cfg.activeProfile = 0;
    }
    // ⚠️ **逐份 profile 字段兜底**（老版本 / 手改过的 config.json 可能缺字段）：
    // 渲染侧的 Text(p.name) 与设置页 loadProfileToForm 的 models.join(', ')
    // 一旦拿到 undefined 就会抛 JS 异常把进程带崩（用户反馈：横屏保存 / 测试时闪退）。
    // 这里是配置的唯一出口，统一补齐后下游可以放心直接解引用。
    const fixed: AiApiProfile[] = [];
    for (let i = 0; i < cfg.profiles.length; i++) {
      const p: AiApiProfile = cfg.profiles[i];
      const nm: string = p.name !== undefined && p.name.length > 0 ? p.name : 'API ' + (i + 1);
      fixed.push({
        name: nm,
        apiUrl: p.apiUrl === undefined ? '' : p.apiUrl,
        apiKey: p.apiKey === undefined ? '' : p.apiKey,
        models: p.models === undefined ? [] : p.models
      });
    }
    cfg.profiles = fixed;
    if (cfg.activeProfile < 0 || cfg.activeProfile >= cfg.profiles.length) {
      cfg.activeProfile = 0;
    }
    const act: AiApiProfile = cfg.profiles[cfg.activeProfile];
    if (act !== undefined && act !== null) {
      cfg.apiUrl = act.apiUrl;
      cfg.apiKey = act.apiKey;
      cfg.models = act.models;
    }
    return cfg;
  }

  /** 切换生效 API（对话页选模型 / 设置页切换时用）：改 activeProfile 并重新镜像顶层。 */
  static activateProfile(cfg: AiChatConfig, index: number): void {
    if (index < 0 || index >= cfg.profiles.length) {
      return;
    }
    cfg.activeProfile = index;
    const act: AiApiProfile = cfg.profiles[index];
    cfg.apiUrl = act.apiUrl;
    cfg.apiKey = act.apiKey;
    cfg.models = act.models;
  }

  static saveConfig(ctx: common.UIAbilityContext, cfg: AiChatConfig): void {
    AiChatStore.ensureDir(AiChatStore.aiDir(ctx));
    const path: string = AiChatStore.aiDir(ctx) + '/config.json';
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(cfg));
    } finally {
      try {
        fs.closeSync(file);
      } catch (closeErr) {
        // 关闭失败无副作用
      }
    }
  }

  /** 是否已配置（URL + Key + 至少一个模型） */
  static isConfigured(cfg: AiChatConfig): boolean {
    return cfg.apiUrl.length > 0 && cfg.apiKey.length > 0 && cfg.models.length > 0;
  }

  /** Anthropic 协议探测：地址含 anthropic 或 /messages */
  static isAnthropicUrl(raw: string): boolean {
    const u: string = raw.toLowerCase();
    return u.indexOf('anthropic') >= 0 || u.indexOf('/messages') >= 0;
  }

  /** API 地址规整：补协议头 + 按协议补全路径（/chat/completions 或 /v1/messages） */
  static normalizeUrl(raw: string): string {
    let u: string = raw.trim();
    if (u.length === 0) {
      return '';
    }
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://' + u;
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (AiChatStore.isAnthropicUrl(u)) {
      if (u.indexOf('/v1/messages') < 0) {
        u = u + '/v1/messages';
      }
      return u;
    }
    if (u.indexOf('/chat/completions') < 0) {
      u = u + '/chat/completions';
    }
    return u;
  }

  /** 模型名列表解析：逗号 / 空格 / 换行分隔，去空去重 */
  static parseModels(raw: string): string[] {
    const parts: string[] = raw.split(/[,,\s]+/);
    const out: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const p: string = parts[i].trim();
      if (p.length > 0 && out.indexOf(p) < 0) {
        out.push(p);
      }
    }
    return out;
  }

  /** 思考强度展示名 */
  static reasoningLabel(n: number): string {
    if (n === 0) {
      return '关闭';
    }
    if (n === 2) {
      return '深度';
    }
    return '标准';
  }

  /** reasoning_effort 参数值（0 档返回空 = 不发送） */
  private static reasoningParam(n: number): string {
    if (n === 0) {
      return '';
    }
    if (n === 2) {
      return 'high';
    }
    return 'medium';
  }

  // ── 会话 ──

  static newId(): string {
    return 's' + Date.now().toString(36) + Math.floor(Math.random() * 46656).toString(36);
  }

  static newSession(docName: string): AiChatSession {
    const now: number = Date.now();
    const s: AiChatSession = {
      id: AiChatStore.newId(),
      title: '新对话',
      created: now,
      updated: now,
      docName: docName,
      messages: []
    };
    return s;
  }

  private static sessionPath(ctx: common.UIAbilityContext, id: string): string {
    return AiChatStore.sessionsDir(ctx) + '/' + id + '.json';
  }

  static loadSession(ctx: common.UIAbilityContext, id: string): AiChatSession | null {
    const path: string = AiChatStore.sessionPath(ctx, id);
    try {
      if (!fs.accessSync(path)) {
        return null;
      }
      const raw: AiChatSession = JSON.parse(fs.readTextSync(path)) as AiChatSession;
      const s: AiChatSession = {
        id: raw.id === undefined ? id : raw.id,
        title: raw.title === undefined ? '对话' : raw.title,
        created: raw.created === undefined ? Date.now() : raw.created,
        updated: raw.updated === undefined ? Date.now() : raw.updated,
        docName: raw.docName === undefined ? '' : raw.docName,
        messages: raw.messages === undefined ? [] : raw.messages
      };
      return s;
    } catch (err) {
      return null;
    }
  }

  static saveSession(ctx: common.UIAbilityContext, session: AiChatSession): void {
    AiChatStore.ensureDir(AiChatStore.sessionsDir(ctx));
    const path: string = AiChatStore.sessionPath(ctx, session.id);
    // 落盘副本：**丢弃图片 base64**（见文件头说明），保留 docs / tokens
    const slim: AiChatMessage[] = [];
    for (let i = 0; i < session.messages.length; i++) {
      const m: AiChatMessage = session.messages[i];
      // 生成中的占位气泡不落盘（中途退出不会残留"加载中"空气泡）
      if (m.pending === true) {
        continue;
      }
      const c: AiChatMessage = {
        role: m.role,
        content: m.content,
        ts: m.ts
      };
      if (m.err === true) {
        c.err = true;
      }
      if (m.docName !== undefined && m.docName.length > 0) {
        c.docName = m.docName;
      }
      if (m.quote !== undefined && m.quote.length > 0) {
        c.quote = m.quote;
      }
      if (m.docs !== undefined && m.docs.length > 0) {
        c.docs = m.docs;
      }
      if (m.tokens !== undefined && m.tokens > 0) {
        c.tokens = m.tokens;
      }
      // ⚠️ model / thinking / thinkMs 此前漏带落盘 → 词元统计全落「更早的回复」、
      // 重启后思考过程消失（真机反馈实锤），补齐
      if (m.model !== undefined && m.model.length > 0) {
        c.model = m.model;
      }
      if (m.thinking !== undefined && m.thinking.length > 0) {
        c.thinking = m.thinking;
      }
      if (m.thinkMs !== undefined && m.thinkMs > 0) {
        c.thinkMs = m.thinkMs;
      }
      slim.push(c);
    }
    const out: AiChatSession = {
      id: session.id,
      title: session.title,
      created: session.created,
      updated: session.updated,
      docName: session.docName,
      messages: slim
    };
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(out));
      fs.closeSync(file);
    } catch (err) {
      // 写失败静默：下次消息变更再写
    }
  }

  static deleteSession(ctx: common.UIAbilityContext, id: string): void {
    try {
      const path: string = AiChatStore.sessionPath(ctx, id);
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (err) {
      // 忽略
    }
  }

  static listSessions(ctx: common.UIAbilityContext): AiChatSessionBrief[] {
    const dir: string = AiChatStore.sessionsDir(ctx);
    const out: AiChatSessionBrief[] = [];
    try {
      if (!fs.accessSync(dir)) {
        return out;
      }
      const names: string[] = fs.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        const n: string = names[i];
        if (!n.endsWith('.json')) {
          continue;
        }
        const s: AiChatSession | null =
          AiChatStore.loadSession(ctx, n.substring(0, n.length - 5));
        if (s === null) {
          continue;
        }
        let tokens: number = 0;
        for (let k = 0; k < s.messages.length; k++) {
          const t: number | undefined = s.messages[k].tokens;
          if (t !== undefined) {
            tokens += t;
          }
        }
        const b: AiChatSessionBrief = {
          id: s.id,
          title: s.title,
          updated: s.updated,
          count: s.messages.length,
          tokens: tokens
        };
        out.push(b);
      }
    } catch (err) {
      // 忽略
    }
    out.sort((a: AiChatSessionBrief, b2: AiChatSessionBrief) => b2.updated - a.updated);
    return out;
  }

  /**
   * 按模型聚合全部会话的词元消耗（AI 设置页统计区）。
   * 只数带 tokens 的 assistant 消息；旧版本消息没有 model 记录，归入「更早的回复」。
   */
  static tokenStats(ctx: common.UIAbilityContext): AiTokenStat[] {
    const out: AiTokenStat[] = [];
    try {
      const briefs: AiChatSessionBrief[] = AiChatStore.listSessions(ctx);
      for (let i = 0; i < briefs.length; i++) {
        const s: AiChatSession | null = AiChatStore.loadSession(ctx, briefs[i].id);
        if (s === null) {
          continue;
        }
        for (let k = 0; k < s.messages.length; k++) {
          const m: AiChatMessage = s.messages[k];
          if (m.role !== 'assistant' || m.tokens === undefined || m.tokens <= 0) {
            continue;
          }
          const key: string = m.model !== undefined && m.model.length > 0 ? m.model : '更早的回复';
          let hit: AiTokenStat | null = null;
          for (let j = 0; j < out.length; j++) {
            if (out[j].model === key) {
              hit = out[j];
              break;
            }
          }
          if (hit === null) {
            const st: AiTokenStat = { model: key, replies: 0, tokens: 0 };
            out.push(st);
            hit = st;
          }
          hit.replies += 1;
          hit.tokens += m.tokens;
        }
      }
    } catch (err) {
      // 忽略
    }
    out.sort((a: AiTokenStat, b: AiTokenStat) => b.tokens - a.tokens);
    return out;
  }

  /** 全零统计（设置页 @State 初始值，避免可空判链） */
  static emptyTokenUsage(): AiTokenUsage {
    const u: AiTokenUsage = {
      totalReplies: 0,
      totalTokens: 0,
      today: { replies: 0, tokens: 0 },
      yesterday: { replies: 0, tokens: 0 },
      week: { replies: 0, tokens: 0 },
      month: { replies: 0, tokens: 0 },
      halfYear: { replies: 0, tokens: 0 },
      year: { replies: 0, tokens: 0 },
      years: [],
      models: []
    };
    return u;
  }

  /**
   * 词元消耗全景（AI 设置页统计区）：一次全量遍历同时得出
   * 总计 + 今天/昨天/近一周/近一月/近半年/近一年 + 历年 + 按模型。
   * 时间维是独立口径（今天的消耗同时计入近一周），各自按窗口累计，互不扣除。
   */
  static tokenUsageStats(ctx: common.UIAbilityContext): AiTokenUsage {
    const usage: AiTokenUsage = AiChatStore.emptyTokenUsage();
    try {
      const now: Date = new Date();
      const nowMs: number = now.getTime();
      // 今天 0 点（本地时区）
      const dayStart: number =
        new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
      const dayMs: number = 86400000;
      const briefs: AiChatSessionBrief[] = AiChatStore.listSessions(ctx);
      for (let i = 0; i < briefs.length; i++) {
        const s: AiChatSession | null = AiChatStore.loadSession(ctx, briefs[i].id);
        if (s === null) {
          continue;
        }
        for (let k = 0; k < s.messages.length; k++) {
          const m: AiChatMessage = s.messages[k];
          if (m.role !== 'assistant' || m.tokens === undefined || m.tokens <= 0) {
            continue;
          }
          const ts: number = m.ts;
          usage.totalReplies += 1;
          usage.totalTokens += m.tokens;
          // 日历日桶：今天 / 昨天（昨天 = [今日0点-1天, 今日0点)）
          if (ts >= dayStart) {
            usage.today.replies += 1;
            usage.today.tokens += m.tokens;
          } else if (ts >= dayStart - dayMs) {
            usage.yesterday.replies += 1;
            usage.yesterday.tokens += m.tokens;
          }
          // 滑动窗口桶：近一周 / 月 / 半年 / 年
          if (ts >= nowMs - 7 * dayMs) {
            usage.week.replies += 1;
            usage.week.tokens += m.tokens;
          }
          if (ts >= nowMs - 30 * dayMs) {
            usage.month.replies += 1;
            usage.month.tokens += m.tokens;
          }
          if (ts >= nowMs - 183 * dayMs) {
            usage.halfYear.replies += 1;
            usage.halfYear.tokens += m.tokens;
          }
          if (ts >= nowMs - 365 * dayMs) {
            usage.year.replies += 1;
            usage.year.tokens += m.tokens;
          }
          // 按年聚合
          const y: number = new Date(ts).getFullYear();
          let yHit: AiTokenYearStat | null = null;
          for (let j = 0; j < usage.years.length; j++) {
            if (usage.years[j].year === y) {
              yHit = usage.years[j];
              break;
            }
          }
          if (yHit === null) {
            const ys: AiTokenYearStat = { year: y, replies: 0, tokens: 0 };
            usage.years.push(ys);
            yHit = ys;
          }
          yHit.replies += 1;
          yHit.tokens += m.tokens;
          // 按模型聚合（旧消息无 model 记录归入「更早的回复」）
          const key: string = m.model !== undefined && m.model.length > 0 ? m.model : '更早的回复';
          let mHit: AiTokenStat | null = null;
          for (let j = 0; j < usage.models.length; j++) {
            if (usage.models[j].model === key) {
              mHit = usage.models[j];
              break;
            }
          }
          if (mHit === null) {
            const st: AiTokenStat = { model: key, replies: 0, tokens: 0 };
            usage.models.push(st);
            mHit = st;
          }
          mHit.replies += 1;
          mHit.tokens += m.tokens;
        }
      }
    } catch (err) {
      // 忽略
    }
    usage.years.sort((a: AiTokenYearStat, b: AiTokenYearStat) => b.year - a.year);
    usage.models.sort((a: AiTokenStat, b: AiTokenStat) => b.tokens - a.tokens);
    return usage;
  }

  // ── OpenAI 兼容协议 ──

  /**
   * 组装 OpenAI 兼容消息序列：系统提示词 + 文档工具协议 + 文档正文（仅首条）+ 历史。
   * 图片（dataURL）只挂在**最后一条 user 消息**上（历史重发不带图，
   * 省 token 也避免不支持视觉的模型报错）。
   */
  private static apiMessages(session: AiChatSession, cfg: AiChatConfig,
    docContent: string, docNames: string[]): AiApiMessage[] {
    const out: AiApiMessage[] = [];
    // 系统提示词：用户没写就用预装提示词（Markdown 写作助手向）
    const sysText: string = cfg.systemPrompt.length > 0 ? cfg.systemPrompt : AI_DEFAULT_SYSTEM_PROMPT;
    if (sysText.length > 0) {
      const sys: AiApiMessage = { role: 'system', content: sysText };
      out.push(sys);
    }
    const tool: AiApiMessage = { role: 'system', content: docToolPrompt(docNames) };
    out.push(tool);
    // 会话首条消息带了文档正文：单独一条 system 注入（清晰、历史里不重复）
    if (docContent.length > 0 && session.docName.length > 0) {
      let doc: string = docContent;
      if (doc.length > AI_DOC_LIMIT) {
        doc = doc.substring(0, AI_DOC_LIMIT) + '\n\n（文档过长，已截断）';
      }
      const pre: string = '以下是用户提供的文档《' + session.docName + '》的 Markdown 原文，'
        + '回答时如未另行说明，默认围绕这份文档：\n\n' + doc;
      const sysDoc: AiApiMessage = { role: 'system', content: pre };
      out.push(sysDoc);
    }
    for (let i = 0; i < session.messages.length; i++) {
      const m: AiChatMessage = session.messages[i];
      if (m.err === true) {
        // 错误气泡不进 API 历史
        continue;
      }
      if (m.pending === true) {
        // ⚠️ 「正在思考」占位气泡**必须跳过**：它在发请求前就 push 进会话，
        // 不过滤就会把一条 **content 为空** 的 assistant 消息塞进请求体 ——
        // 不少网关（含严格校验的 OpenAI 兼容实现 / Anthropic）直接判请求无效，
        // 表现就是"设置里测试连接能过、一对话就报错"。
        continue;
      }
      const isLast: boolean = i === session.messages.length - 1;
      const hasImages: boolean = isLast && m.role === 'user'
        && m.images !== undefined && m.images.length > 0;
      if (hasImages) {
        const parts: AiApiPart[] = [];
        const t: AiApiPart = { type: 'text', text: m.content };
        parts.push(t);
        const imgs: string[] = m.images === undefined ? [] : m.images;
        for (let k = 0; k < imgs.length; k++) {
          const u: AiApiImageUrl = { url: imgs[k] };
          const p: AiApiPart = { type: 'image_url', text: '', image_url: u };
          parts.push(p);
        }
        const mm: AiApiMessage = { role: 'user', content: parts };
        out.push(mm);
      } else {
        const mm: AiApiMessage = { role: m.role, content: m.content };
        out.push(mm);
      }
    }
    return out;
  }

  /**
   * 发起一次对话请求（按 API 地址自动选 OpenAI 兼容 / Anthropic 协议，非流式）。
   * 永不 reject：失败也 resolve（ok=false + 用户可读的错误说明）。
   */
  /** 当前在飞的请求（发送中点「停止」时 destroy 中断） */
  private static liveReq: http.HttpRequest | null = null;
  /** 主动中止标记：catch 里据此区分「用户停止」与「网络失败」 */
  private static aborting: boolean = false;

  /** 用户主动停止当前请求 */
  static abortChat(): void {
    AiChatStore.aborting = true;
    if (AiChatStore.liveReq !== null) {
      try {
        AiChatStore.liveReq.destroy();
      } catch (e) {
        // 请求可能已自然结束，忽略
      }
      AiChatStore.liveReq = null;
    }
  }

  /** 错误文案里带一小段定位信息（主机名 + 模型名），便于自查地址 / 模型配错；不含密钥。 */
  private static whereOf(url: string, model: string): string {
    let host: string = url;
    const at: number = url.indexOf('://');
    if (at >= 0) {
      host = url.substring(at + 3);
    }
    const slash: number = host.indexOf('/');
    if (slash >= 0) {
      host = host.substring(0, slash);
    }
    return host + ' · ' + model;
  }

  static requestChat(cfg: AiChatConfig, model: string, session: AiChatSession,
    docContent: string, docNames: string[]): Promise<AiChatResult> {
    const url: string = AiChatStore.normalizeUrl(cfg.apiUrl);
    if (url.length === 0 || model.length === 0) {
      const bad: AiChatResult = { ok: false, text: '请先完成 AI 接口配置' };
      return new Promise<AiChatResult>((resolve: (v: AiChatResult) => void) => {
        resolve(bad);
      });
    }
    if (AiChatStore.isAnthropicUrl(url)) {
      return AiChatStore.requestAnthropic(url, cfg, model, session, docContent, docNames);
    }
    return AiChatStore.requestOpenAI(url, cfg, model, session, docContent, docNames);
  }

  private static requestOpenAI(url: string, cfg: AiChatConfig, model: string,
    session: AiChatSession, docContent: string, docNames: string[]): Promise<AiChatResult> {
    return new Promise<AiChatResult>((resolve: (v: AiChatResult) => void) => {
      const body: AiApiBody = {
        model: model,
        messages: AiChatStore.apiMessages(session, cfg, docContent, docNames),
        stream: false
      };
      const rp: string = AiChatStore.reasoningParam(cfg.reasoning);
      if (rp.length > 0) {
        body.reasoning_effort = rp;
      }
      const req = http.createHttp();
      AiChatStore.liveReq = req;
      AiChatStore.aborting = false;
      req.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + cfg.apiKey
        },
        extraData: JSON.stringify(body),
        connectTimeout: 15000,
        readTimeout: 180000,
        expectDataType: http.HttpDataType.STRING
      }).then((resp: http.HttpResponse) => {
        req.destroy();
        AiChatStore.liveReq = null;
        const text: string = typeof resp.result === 'string' ? resp.result : '';
        if (resp.responseCode !== 200) {
          const r: AiChatResult = {
            ok: false,
            text: AiChatStore.friendlyError(resp.responseCode, text)
          };
          resolve(r);
          return;
        }
        const content: string = AiChatStore.extractContent(text);
        if (content.length === 0) {
          const empty: AiChatResult = {
            ok: false,
            text: '模型返回了空内容，请检查模型名称是否正确（或换一个模型试试）'
          };
          resolve(empty);
          return;
        }
        const okR: AiChatResult = { ok: true, text: content, tokens: AiChatStore.extractOpenTokens(text) };
        const th: string = AiChatStore.extractOpenThinking(text);
        if (th.length > 0) {
          okR.thinking = th;
        }
        resolve(okR);
      }).catch((err: Error) => {
        req.destroy();
        AiChatStore.liveReq = null;
        // 主动停止：返回 aborted，让页面静默收尾而不是弹错误
        if (AiChatStore.aborting) {
          const ab: AiChatResult = { ok: false, text: '', aborted: true };
          resolve(ab);
          return;
        }
        const msg: string = err.message !== undefined ? err.message : '';
        const net: AiChatResult = {
          ok: false,
          text: '请求失败' + (msg.length > 0 ? '：' + msg : '，请检查网络与 API 地址')
            + '（' + AiChatStore.whereOf(url, model) + '）'
        };
        resolve(net);
      });
    });
  }

  // ── Anthropic 协议 ──

  /** dataURL → Anthropic base64 source（解析失败返回 null） */
  private static parseDataUrl(dataUrl: string): AiAntSource | null {
    const mark: string = ';base64,';
    const at: number = dataUrl.indexOf(mark);
    if (at < 0) {
      return null;
    }
    let mime: string = dataUrl.substring(5, at);
    if (mime.length === 0) {
      mime = 'image/jpeg';
    }
    const src: AiAntSource = {
      type: 'base64',
      media_type: mime,
      data: dataUrl.substring(at + mark.length)
    };
    return src;
  }

  /** Anthropic 消息序列：跳过错误气泡与「正在思考」占位、末条 user 挂图片、连续同角色合并、首条必须是 user */
  private static antMessages(session: AiChatSession): AiAntMessage[] {
    const out: AiAntMessage[] = [];
    const total: number = session.messages.length;
    for (let i = 0; i < total; i++) {
      const m: AiChatMessage = session.messages[i];
      if (m.err === true) {
        continue;
      }
      if (m.pending === true) {
        // 同 apiMessages：「正在思考」占位不能进请求体（空文本块会被 Anthropic 判无效）
        continue;
      }
      const isLast: boolean = i === total - 1;
      const hasImages: boolean = isLast && m.role === 'user'
        && m.images !== undefined && m.images.length > 0;
      const prev: AiAntMessage | undefined = out.length > 0 ? out[out.length - 1] : undefined;
      if (hasImages) {
        const parts: AiAntPart[] = [];
        const t: AiAntPart = { type: 'text', text: m.content };
        parts.push(t);
        const imgs: string[] = m.images === undefined ? [] : m.images;
        for (let k = 0; k < imgs.length; k++) {
          const src: AiAntSource | null = AiChatStore.parseDataUrl(imgs[k]);
          if (src !== null) {
            const p: AiAntPart = { type: 'image', text: '', source: src };
            parts.push(p);
          }
        }
        const mm: AiAntMessage = { role: 'user', content: parts };
        out.push(mm);
      } else if (prev !== undefined && prev.role === m.role) {
        // 连续同角色合并（Anthropic 期望角色交替）
        if (typeof prev.content === 'string') {
          prev.content = prev.content + '\n\n' + m.content;
        } else {
          const tp: AiAntPart = { type: 'text', text: m.content };
          prev.content.push(tp);
        }
      } else {
        const mm: AiAntMessage = { role: m.role, content: m.content };
        out.push(mm);
      }
    }
    // Anthropic 要求首条消息为 user
    while (out.length > 0 && out[0].role !== 'user') {
      out.shift();
    }
    return out;
  }

  private static requestAnthropic(url: string, cfg: AiChatConfig, model: string,
    session: AiChatSession, docContent: string, docNames: string[]): Promise<AiChatResult> {
    return new Promise<AiChatResult>((resolve: (v: AiChatResult) => void) => {
      // system = 系统提示词（用户没写用预装）+ 文档工具协议 + 文档正文（Anthropic 独立 system 字段）
      let system: string = '';
      if (cfg.systemPrompt.length > 0) {
        system += cfg.systemPrompt + '\n\n';
      } else {
        system += AI_DEFAULT_SYSTEM_PROMPT + '\n\n';
      }
      system += docToolPrompt(docNames);
      if (docContent.length > 0 && session.docName.length > 0) {
        let doc: string = docContent;
        if (doc.length > AI_DOC_LIMIT) {
          doc = doc.substring(0, AI_DOC_LIMIT) + '\n\n（文档过长，已截断）';
        }
        system += '\n\n以下是用户提供的文档《' + session.docName + '》的 Markdown 原文，'
          + '回答时如未另行说明，默认围绕这份文档：\n\n' + doc;
      }
      const body: AiAntBody = {
        model: model,
        messages: AiChatStore.antMessages(session),
        max_tokens: 8192,
        stream: false
      };
      if (system.length > 0) {
        body.system = system;
      }
      // 思考强度 → thinking budget（关闭档不带 thinking；max_tokens 必须大于 budget）
      if (cfg.reasoning === 1) {
        const th: AiAntThinking = { type: 'enabled', budget_tokens: 4096 };
        body.thinking = th;
      } else if (cfg.reasoning === 2) {
        const th: AiAntThinking = { type: 'enabled', budget_tokens: 12288 };
        body.thinking = th;
        body.max_tokens = 16384;
      }
      const req = http.createHttp();
      AiChatStore.liveReq = req;
      AiChatStore.aborting = false;
      req.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'x-api-key': cfg.apiKey,
          'anthropic-version': '2023-06-01'
        },
        extraData: JSON.stringify(body),
        connectTimeout: 15000,
        readTimeout: 180000,
        expectDataType: http.HttpDataType.STRING
      }).then((resp: http.HttpResponse) => {
        req.destroy();
        AiChatStore.liveReq = null;
        const text: string = typeof resp.result === 'string' ? resp.result : '';
        if (resp.responseCode !== 200) {
          const r: AiChatResult = {
            ok: false,
            text: AiChatStore.friendlyError(resp.responseCode, text)
          };
          resolve(r);
          return;
        }
        const content: string = AiChatStore.extractAnthContent(text);
        if (content.length === 0) {
          const empty: AiChatResult = {
            ok: false,
            text: '模型返回了空内容，请检查模型名称是否正确（或换一个模型试试）'
          };
          resolve(empty);
          return;
        }
        const okR: AiChatResult = { ok: true, text: content, tokens: AiChatStore.extractAntTokens(text) };
        const th: string = AiChatStore.extractAnthThinking(text);
        if (th.length > 0) {
          okR.thinking = th;
        }
        resolve(okR);
      }).catch((err: Error) => {
        req.destroy();
        AiChatStore.liveReq = null;
        // 主动停止：返回 aborted，让页面静默收尾而不是弹错误
        if (AiChatStore.aborting) {
          const ab: AiChatResult = { ok: false, text: '', aborted: true };
          resolve(ab);
          return;
        }
        const msg: string = err.message !== undefined ? err.message : '';
        const net: AiChatResult = {
          ok: false,
          text: '请求失败' + (msg.length > 0 ? '：' + msg : '，请检查网络与 API 地址')
            + '（' + AiChatStore.whereOf(url, model) + '）'
        };
        resolve(net);
      });
    });
  }

  /** 连接测试：发一条最小的 "ping" */
  static testConnection(cfg: AiChatConfig): Promise<AiChatResult> {
    const s: AiChatSession = {
      id: '',
      title: '',
      created: 0,
      updated: 0,
      docName: '',
      messages: []
    };
    const m: AiChatMessage = { role: 'user', content: 'ping', ts: 0 };
    s.messages.push(m);
    const model: string = cfg.models.length > 0 ? cfg.models[0] : '';
    return AiChatStore.requestChat(cfg, model, s, '', []);
  }

  private static extractContent(text: string): string {
    try {
      const resp: AiApiResp = JSON.parse(text) as AiApiResp;
      const choices: AiApiRespChoice[] | undefined = resp.choices;
      if (choices === undefined || choices.length === 0) {
        return '';
      }
      const msg: AiApiRespMessage | undefined = choices[0].message;
      // ⚠️ content 可能是 null（网关异常响应），也可能被 vision 网关给成数组——
      // 都按「空内容」处理，交给上层友好提示，绝不让 null 混出去炸 .length
      if (msg === undefined || msg.content === undefined
        || msg.content === null || typeof msg.content !== 'string') {
        return '';
      }
      return msg.content;
    } catch (err) {
      return '';
    }
  }

  /** OpenAI 兼容思考过程：message.reasoning_content（DeepSeek R1 等） */
  private static extractOpenThinking(text: string): string {
    try {
      const resp: AiApiResp = JSON.parse(text) as AiApiResp;
      const choices: AiApiRespChoice[] | undefined = resp.choices;
      if (choices === undefined || choices.length === 0) {
        return '';
      }
      const msg: AiApiRespMessage | undefined = choices[0].message;
      if (msg === undefined || msg.reasoning_content === undefined
        || msg.reasoning_content === null) {
        return '';
      }
      return msg.reasoning_content;
    } catch (err) {
      return '';
    }
  }

  /** Anthropic 思考过程：content 数组里 type === 'thinking' 块的 thinking 正文拼接 */
  private static extractAnthThinking(text: string): string {
    try {
      const resp: AiAntResp = JSON.parse(text) as AiAntResp;
      const blocks: AiAntBlock[] | undefined = resp.content;
      if (blocks === undefined) {
        return '';
      }
      let out: string = '';
      for (let i = 0; i < blocks.length; i++) {
        const b: AiAntBlock = blocks[i];
        if (b.type === 'thinking' && b.thinking !== undefined && b.thinking !== null) {
          out += (out.length > 0 ? '\n\n' : '') + b.thinking;
        }
      }
      return out;
    } catch (err) {
      return '';
    }
  }

  private static extractOpenTokens(text: string): number {
    try {
      const resp: AiApiResp = JSON.parse(text) as AiApiResp;
      const u: AiOpenUsage | undefined = resp.usage;
      if (u === undefined || u.completion_tokens === undefined
        || u.completion_tokens === null) {
        return 0;
      }
      return u.completion_tokens;
    } catch (err) {
      return 0;
    }
  }

  private static extractAnthContent(text: string): string {
    try {
      const resp: AiAntResp = JSON.parse(text) as AiAntResp;
      const blocks: AiAntBlock[] | undefined = resp.content;
      if (blocks === undefined) {
        return '';
      }
      let out: string = '';
      for (let i = 0; i < blocks.length; i++) {
        const b: AiAntBlock = blocks[i];
        if (b.type === 'text' && b.text !== undefined) {
          out += b.text;
        }
      }
      return out;
    } catch (err) {
      return '';
    }
  }

  private static extractAntTokens(text: string): number {
    try {
      const resp: AiAntResp = JSON.parse(text) as AiAntResp;
      const u: AiAntUsage | undefined = resp.usage;
      if (u === undefined || u.output_tokens === undefined) {
        return 0;
      }
      return u.output_tokens;
    } catch (err) {
      return 0;
    }
  }

  private static friendlyError(code: number, body: string): string {
    let detail: string = '';
    try {
      const e: AiApiErr = JSON.parse(body) as AiApiErr;
      const inner: AiApiErrInner | undefined = e.error;
      // ⚠️ 远端 JSON 的字段可能是显式 null（undefined 检查挡不住 null）：
      // 网关返回 {"error":{"message":null}} 时 detail 会变成 null，
      // 下面 detail.length 直接抛 "Cannot read property length of null"（用户实测）。
      if (inner !== undefined && inner !== null
        && inner.message !== undefined && inner.message !== null) {
        detail = inner.message as string;
      }
    } catch (err) {
      // 非 JSON 响应体
    }
    const suffix: string = detail.length > 0 ? '：' + detail : '';
    if (code === 401 || code === 403) {
      return 'API Key 无效或无权限（' + code + '）' + suffix;
    }
    if (code === 404) {
      return '接口不存在（404），请检查 API 地址' + suffix;
    }
    if (code === 429) {
      return '请求过于频繁或额度不足（429）' + suffix;
    }
    if (code >= 400 && code < 500) {
      return '请求被拒绝（' + code + '）。若提示参数错误，可把「思考强度」切到关闭' + suffix;
    }
    return '服务异常（' + code + '）' + suffix;
  }

  // ── 生成中登记（应用级）────────────────────────────────────────────────
  //
  // 请求本体是**静态**的（liveReq）：用户离开对话页后请求仍在跑，回复照样落盘。
  // 这里登记「哪些会话正在生成」，供两处使用：
  //   · 历史会话列表行显示加载动画（知道哪条还在写）；
  //   · 回到该会话时恢复「正在思考」占位，并在完成后把盘上结果回流到界面。
  // 状态变化时自增 AppStorage 'aiGenTick'（UI 订阅刷新），结束时写 'aiGenDoneId'
  // （谁完成的），页面据此把盘上结果拉回当前会话。

  private static genIds: string[] = [];

  /** 登记「该会话正在生成」（重复调用幂等）。 */
  static markGenerating(id: string): void {
    if (id.length === 0 || AiChatStore.genIds.indexOf(id) >= 0) {
      return;
    }
    AiChatStore.genIds.push(id);
    AiChatStore.bumpGenTick('');
  }

  /** 注销「正在生成」（结束 / 中止 / 失败都要调）。 */
  static unmarkGenerating(id: string): void {
    if (id.length === 0) {
      return;
    }
    const kept: string[] = [];
    for (let i = 0; i < AiChatStore.genIds.length; i++) {
      if (AiChatStore.genIds[i] !== id) {
        kept.push(AiChatStore.genIds[i]);
      }
    }
    if (kept.length === AiChatStore.genIds.length) {
      return;
    }
    AiChatStore.genIds = kept;
    // **后台跑完 → 入口角标 +1**（用户要求：对话页不可见时才计；页面自己可见时不打扰）。
    // 页面通过 AppStorage 'aiChatVisible' 登记可见性（aboutToAppear / aboutToDisappear）。
    const visible: boolean = AppStorage.get<boolean>('aiChatVisible') === true;
    const isErr: boolean = AppStorage.get<boolean>('aiGenErr') === true;
    if (!visible && !isErr) {
      const n: number | undefined = AppStorage.get<number>('aiNewReply');
      AppStorage.setOrCreate('aiNewReply', (n === undefined ? 0 : n) + 1);
    }
    AiChatStore.bumpGenTick(id);
  }

  /** 该会话是否正在生成（历史列表加载动画用）。 */
  static isGenerating(id: string): boolean {
    return id.length > 0 && AiChatStore.genIds.indexOf(id) >= 0;
  }

  /** 通知界面：tick 自增；doneId 非空表示「这个会话刚完成」。 */
  private static bumpGenTick(doneId: string): void {
    const t: number | undefined = AppStorage.get<number>('aiGenTick');
    AppStorage.setOrCreate('aiGenTick', (t === undefined ? 0 : t) + 1);
    if (doneId.length > 0) {
      AppStorage.setOrCreate('aiGenDoneId', doneId);
    }
  }
}
