/**
 * 澄笺 · AI 设置页（1.2.0）
 * ==========================
 *
 * AI 助手的接口配置：
 *   · API 地址（OpenAI 兼容 /chat/completions，填 base 地址也自动补全）
 *   · API Key
 *   · 模型名称（可多个，逗号分隔；对话页可切换）
 *   · 系统提示词（可空）
 *   · 思考强度（关闭 / 标准 / 深度）
 * 另有「测试连接」：保存前先试一发，避免配错了到处碰壁。
 *
 * 配置持久化在 filesDir/ai/config.json（AiChatStore），全量备份会带上。
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NavLifecycle } from '../service/NavLifecycle';
import {
  HwBar, HwRadius, HwSpace, HwType, ReaderPalette, paletteFor, isDarkTheme, ReaderThemeMode, HwFont
} from '../theme/DesignTokens';
import { SettingsShell } from './SettingsShell';
import { ImmersiveBar, ImmersiveCard, ImmersiveChip, ImmersiveIconButton } from '../material/ImmersiveCard';
import {
  AiChatStore, AiChatConfig, AiChatResult, AiApiProfile, AiTokenStat, AiTokenUsage,
  AiTokenBucket, AiTokenYearStat
} from '../service/AiChatStore';
import { GenWallpaper } from '../theme/GenWallpaper';
import { WallpaperStore } from '../service/WallpaperStore';
import { WallpaperImage } from '../components/WallpaperImage';
import { StatusBarBlur } from '../components/StatusBarBlur';
import { L10n } from '../service/L10n';
import { AppearanceFx } from '../service/AppearanceFx';

const TAG: string = 'AiSettings';

@Component
export struct AiSettings {
  stack: NavPathStack | null = null;
  /** true = 设置分栏 / 设置入口的嵌入形态（SettingsShell 外壳）；false = 对话页齿轮进入的全屏形态 */
  @Prop embedded: boolean = false;
  /** 生命周期转发（NavDestination.onShown/onHidden）：回来时刷新词元统计 */
  life: NavLifecycle = new NavLifecycle();
  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  /** 沉浸光感总开关：光感关时输入框 / 按钮包装卡补包边（cardOutline，材质开着不画） */
  @StorageProp('immersiveLook') fxLookOn: boolean = false;
  @StorageProp('safeBottomPx') safeBottomPx: number = 0;
  /** **界面字体**（外观设置 → 界面字体）：本页界面文字都从这里取 */
  @StorageProp('appFontFamily') uiFontKey: string = '';
  /** 界面字号缩放系数 / 界面字重相对加粗量（外观设置） */
  @StorageProp('appFontScale') uiFontScale: number = 1;
  @StorageProp('appFontWeightDelta') uiFontWeightDelta: number = 0;

  // ── 表单 ──
  @State apiUrl: string = '';
  /** 语言切换计数：变更时整页重建（key 拼接），文案随词典刷新 */
  @StorageProp('languageTick') languageTick: number = 0;
  @State apiKey: string = '';
  @State modelsText: string = '';
  @State systemPrompt: string = '';
  @State reasoning: number = 1;
  @State testing: boolean = false;
  /** 词元消耗全景：总计 + 今天/昨天/近一周/近一月/近半年/近一年 + 历年 + 按模型（onShow 刷新） */
  @State usage: AiTokenUsage = AiChatStore.emptyTokenUsage();
  /** 已保存配置里的当前模型（保存时不丢用户在对话页选过的模型） */
  private savedCurrentModel: string = '';
  /** 是否已从磁盘装载过配置（ctx 未就绪时会推迟，见 ensureConfigLoaded） */
  private loadedCfg: boolean = false;
  /** 多 API 配置（表单编辑的是 profiles[activeIdx]，切换前写回内存） */
  @State profiles: AiApiProfile[] = [];
  @State activeIdx: number = 0;
  /** 当前编辑 profile 的显示名（表单可改） */
  @State profileName: string = '';

  // ── 背景（与 AI 对话页同一套优先级：外观壁纸 → 生成壁纸 → 阅读纯色 → 主题渐变）──
  @StorageProp('wallpaperPathLight') wallpaperPathLight: string = '';
  @StorageProp('wallpaperPathDark') wallpaperPathDark: string = '';
  @StorageProp('wallpaperPath') wallpaperPath: string = '';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 4;
  @StorageLink('wallpaperScrim') wallpaperScrim: number = 42;
  @StorageProp('wallpaperGenId') genWallId: string = '';
  @StorageLink('readerCustomBgLight') customBgLight: string = '';
  @StorageLink('readerCustomBgDark') customBgDark: string = '';

  /**
   * 从磁盘装载配置（幂等）。**ctx 为空时必须返回 false 而不是静默跳过**——
   * 大屏横屏 / 分栏右栏 / 横竖屏切换的瞬间 getHostContext() 可能拿不到，
   * 这时若直接 return，`profiles` 会一直是空数组，之后保存 / 测试连接索引
   * `profiles[0]` 就是 undefined → `act.apiUrl` 抛 TypeError 把进程带崩
   * （真机 JsCrash 栈实证：formConfig → test → cardOnTap）。
   */
  private ensureConfigLoaded(): boolean {
    if (this.loadedCfg) {
      return true;
    }
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return false;
    }
    const cfg: AiChatConfig = AiChatStore.loadConfig(c);
    // 多 API：深拷贝 profiles 到表单态（编辑互不影响落盘值），再载入生效的一份
    const list: AiApiProfile[] = [];
    for (let i = 0; i < cfg.profiles.length; i++) {
      const p: AiApiProfile = cfg.profiles[i];
      list.push({
        name: p.name !== undefined ? p.name : 'API ' + (i + 1),
        apiUrl: p.apiUrl !== undefined ? p.apiUrl : '',
        apiKey: p.apiKey !== undefined ? p.apiKey : '',
        models: p.models !== undefined ? p.models : []
      });
    }
    // **恒非空**：至少留一份空配置 → 索引 0 永远有效、表单永远可编辑
    if (list.length === 0) {
      list.push({ name: 'API 1', apiUrl: '', apiKey: '', models: [] });
    }
    this.profiles = list;
    this.activeIdx = cfg.activeProfile >= 0 && cfg.activeProfile < list.length
      ? cfg.activeProfile : 0;
    this.loadProfileToForm(this.activeIdx);
    this.systemPrompt = cfg.systemPrompt;
    this.reasoning = cfg.reasoning;
    this.savedCurrentModel = cfg.currentModel;
    this.loadedCfg = true;
    return true;
  }

  aboutToAppear(): void {
    if (!this.ensureConfigLoaded()) {
      // 宿主上下文此刻尚未就绪：先塞一份占位配置保证 profiles 非空（防索引崩溃），
      // 真正的磁盘配置在 onShow / 保存前补载（见 ensureLoadedBeforeAction）
      if (this.profiles.length === 0) {
        this.profiles = [{ name: 'API 1', apiUrl: '', apiKey: '', models: [] }];
        this.activeIdx = 0;
      }
    }
    this.refreshStats();
    // 设置页 onShow：从对话页返回 / 分栏切换回来时统计跟随刷新（顺便补载未装载的配置）
    this.life.onShow = () => {
      this.ensureConfigLoaded();
      this.refreshStats();
    };
  }

  /** 保存 / 测试前的补载：仅在表单还是一片空白时补（避免覆盖用户刚输入的内容）。 */
  private ensureLoadedBeforeAction(): void {
    if (this.loadedCfg) {
      return;
    }
    if (this.apiUrl.trim().length === 0 && this.apiKey.trim().length === 0) {
      this.ensureConfigLoaded();
    }
  }

  /** 重新聚合词元消耗全景（总计 / 时间维 / 历年 / 按模型，一次遍历） */
  private refreshStats(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    this.usage = AiChatStore.tokenUsageStats(c);
  }

  /** 词元数展示：过万缩写成 k */
  private fmtStatNum(n: number): string {
    if (n >= 10000) {
      return '' + (Math.round(n / 100) / 10) + 'k';
    }
    return '' + n;
  }

  /** 词元时间维格子：数字在上，时段与次数在下 */
  @Builder
  usageCell(label: string, b: AiTokenBucket) {
    Column({ space: 2 }) {
      Text(this.fmtStatNum(b.tokens))
        .fontSize(HwFont.sx(15, this.uiFontScale))
        .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
        .fontColor(this.palette().textPrimary)
      Text(label + ' · ' + b.replies + ' 次')
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(10.5, this.uiFontScale))
        .fontColor(this.palette().textTertiary)
        .maxLines(1)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

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

  /** 外观壁纸按深浅取对应路径（与 AI 对话页同一套解析） */
  private wallpaperPathEffective(): string {
    if (this.isDark()) {
      return this.wallpaperPathDark.length > 0 ? this.wallpaperPathDark : this.wallpaperPath;
    }
    return this.wallpaperPathLight.length > 0 ? this.wallpaperPathLight : this.wallpaperPath;
  }

  /** 阅读自定义纯色背景 */
  private pageBackground(): string {
    if (this.isDark()) {
      return this.customBgDark.length > 0 ? this.customBgDark : '';
    }
    return this.customBgLight.length > 0 ? this.customBgLight : '';
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 });
    } catch (err) {
      // 忽略
    }
  }

  /** 把第 idx 份 profile 载入表单（无有效 profile 时清空；字段缺失逐项兜底不抛异常） */
  private loadProfileToForm(idx: number): void {
    if (idx < 0 || idx >= this.profiles.length) {
      this.profileName = '';
      this.apiUrl = '';
      this.apiKey = '';
      this.modelsText = '';
      return;
    }
    const p: AiApiProfile = this.profiles[idx];
    this.profileName = p.name !== undefined ? p.name : '';
    this.apiUrl = p.apiUrl !== undefined ? p.apiUrl : '';
    this.apiKey = p.apiKey !== undefined ? p.apiKey : '';
    this.modelsText = p.models !== undefined ? p.models.join(', ') : '';
  }

  /** 表单当前值写回当前编辑的 profile（切换前 / 保存前调用；只动内存不落盘） */
  private collectFormToProfile(): void {
    if (this.activeIdx < 0 || this.activeIdx >= this.profiles.length) {
      return;
    }
    const p: AiApiProfile = this.profiles[this.activeIdx];
    p.apiUrl = AiChatStore.normalizeUrl(this.apiUrl);
    p.apiKey = this.apiKey.trim();
    p.models = AiChatStore.parseModels(this.modelsText);
    if (this.profileName.trim().length > 0) {
      p.name = this.profileName.trim();
    }
  }

  /** 切换到另一份 API 配置（当前表单值先写回内存） */
  private switchProfile(idx: number): void {
    if (idx === this.activeIdx) {
      return;
    }
    this.collectFormToProfile();
    this.activeIdx = idx;
    this.loadProfileToForm(idx);
  }

  /** 添加一份新的 API 配置（空表单，填完按「保存」落盘） */
  private addProfile(): void {
    this.collectFormToProfile();
    const p: AiApiProfile = {
      name: 'API ' + (this.profiles.length + 1), apiUrl: '', apiKey: '', models: []
    };
    this.profiles.push(p);
    this.activeIdx = this.profiles.length - 1;
    this.loadProfileToForm(this.activeIdx);
    this.toast(L10n.t('已添加，填写后按「保存」生效'));
  }

  /** 删除当前编辑的 API 配置（至少保留一份；按「保存」落盘） */
  private removeProfile(): void {
    if (this.profiles.length <= 1) {
      this.toast(L10n.t('至少保留一份配置'));
      return;
    }
    this.profiles.splice(this.activeIdx, 1);
    this.activeIdx = Math.min(this.activeIdx, this.profiles.length - 1);
    this.loadProfileToForm(this.activeIdx);
    this.toast(L10n.t('已删除，按「保存」生效'));
  }

  /** 由表单构造配置（不做落盘）：当前表单写回 profile，顶层镜像生效 profile。
   *  ⚠️ **全程不得抛异常**（保存 / 测试都走它）：索引越界时用表单值兜底，绝不直接解引用。 */
  private formConfig(): AiChatConfig {
    this.collectFormToProfile();
    const idx: number = this.activeIdx >= 0 && this.activeIdx < this.profiles.length
      ? this.activeIdx : 0;
    const act: AiApiProfile | undefined = this.profiles[idx];
    const url: string = act !== undefined ? act.apiUrl : AiChatStore.normalizeUrl(this.apiUrl);
    const key: string = act !== undefined ? act.apiKey : this.apiKey.trim();
    const models: string[] = act !== undefined ? act.models : AiChatStore.parseModels(this.modelsText);
    const list: AiApiProfile[] = this.profiles.length > 0 ? this.profiles : [{
      name: 'API 1', apiUrl: url, apiKey: key, models: models
    }];
    const cfg: AiChatConfig = {
      apiUrl: url,
      apiKey: key,
      models: models,
      systemPrompt: this.systemPrompt,
      reasoning: this.reasoning,
      currentModel: this.savedCurrentModel,
      profiles: list,
      activeProfile: idx
    };
    return cfg;
  }

  private save(): void {
    try {
      this.ensureLoadedBeforeAction();
      if (this.apiUrl.trim().length === 0) {
        this.toast(L10n.t('请填写 API 地址'));
        return;
      }
      if (this.apiKey.trim().length === 0) {
        this.toast(L10n.t('请填写 API Key'));
        return;
      }
      if (AiChatStore.parseModels(this.modelsText).length === 0) {
        this.toast(L10n.t('请至少填写一个模型名称'));
        return;
      }
      const c: common.UIAbilityContext | null = this.ctx();
      if (c === null) {
        return;
      }
      AiChatStore.saveConfig(c, this.formConfig());
      // **通知其它页面配置已更新**（用户反馈：保存后回对话页仍显示「请先去配置」，
      // 要退出重进才生效）——对话页 / 编辑页据此重新装载配置。
      const t: number | undefined = AppStorage.get<number>('aiCfgTick');
      AppStorage.setOrCreate('aiCfgTick', (t === undefined ? 0 : t) + 1);
      this.refreshStats();
      this.toast(L10n.t('已保存'));
      // 不自动 pop：嵌入形态（分栏右栏）pop 会误弹整个设置页；全屏态用户自行返回
    } catch (err) {
      // **兜底**（用户反馈：横屏保存 / 测试连接时闪退 —— 宁可提示也不让进程挂掉），
      // 同时把真实异常写进 hilog，便于定位
      const msg: string = (err as Error).message !== undefined ? (err as Error).message : '';
      hilog.error(0x0000, TAG, 'save failed: %{public}s', msg);
      this.toast('保存失败：' + msg);
    }
  }

  private test(): void {
    if (this.testing) {
      return;
    }
    this.ensureLoadedBeforeAction();
    if (this.apiUrl.trim().length === 0 || this.apiKey.trim().length === 0
      || AiChatStore.parseModels(this.modelsText).length === 0) {
      this.toast(L10n.t('请先填写完整地址 / Key / 模型'));
      return;
    }
    try {
      this.testing = true;
      const cfg: AiChatConfig = this.formConfig();
      AiChatStore.testConnection(cfg).then((r: AiChatResult) => {
        try {
          this.testing = false;
          if (r.ok) {
            this.toast(L10n.t('连接成功 ✓'));
          } else {
            this.toast(r.text);
          }
        } catch (e2) {
          hilog.error(0x0000, TAG, 'test callback failed: %{public}s',
            (e2 as Error).message !== undefined ? (e2 as Error).message : '');
        }
      }).catch((e3: Error) => {
        this.testing = false;
        hilog.error(0x0000, TAG, 'test promise failed: %{public}s',
          e3.message !== undefined ? e3.message : '');
      });
    } catch (err) {
      this.testing = false;
      const msg: string = (err as Error).message !== undefined ? (err as Error).message : '';
      hilog.error(0x0000, TAG, 'test failed: %{public}s', msg);
      this.toast('测试失败：' + msg);
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.embedded) {
        // 嵌入形态（设置分栏 / 设置入口）：与其他设置项同一套 SettingsShell 外壳
        SettingsShell({
          shellTitle: L10n.t('助手设置'),
          shellSubtitle: L10n.t('API 地址 · 模型 · 思考强度 · 词元消耗'),
          stack: this.stack,
          life: this.life
        }) {
          // **裸内容**：SettingsShell 自带 Scroll 与上下让位，这里再包 Scroll 会在页顶/页底压出空白
          this.settingContent()
        }
      } else {
        // 全屏形态（对话页齿轮进入）：自绘壁纸背景 + 悬浮顶栏
        // 背景：与 AI 对话页完全同一套优先级（壁纸 → 生成壁纸 → 纯色 → 渐变兜底）
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
        this.settingScroll()
        StatusBarBlur({ heightVp: Math.round(this.getUIContext().px2vp(this.safeTopPx)) })
        // ── 悬浮顶栏：返回 + 标题（与其他页面同款；仅全屏形态）──
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
              Text(L10n.t('助手设置'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(17, this.uiFontScale))
                .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
                .fontColor(this.palette().textPrimary)
              Blank()
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
        }
        .width('100%')
        .padding({ left: HwSpace.lg, right: HwSpace.lg })
        .position({ x: 0, y: this.getUIContext().px2vp(this.safeTopPx) + HwSpace.sm })
        .hitTestBehavior(HitTestMode.Transparent)
        .zIndex(2)
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 表单内容主体：裸内容（嵌入态直接塞进 SettingsShell 的滚动区；全屏态由 settingScroll 包 Scroll） */
  @Builder
  settingContent() {
    Column({ space: HwSpace.md }) {
        // ── 接口信息卡 ──
        ImmersiveCard({ palette: this.palette() }) {
            Column({ space: HwSpace.sm }) {
              // ── API 配置选择（多 API；chips 横向滚动 + 添加 / 删除）──
              Row({ space: HwSpace.sm }) {
                Text(L10n.t('API 配置'))
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(13, this.uiFontScale))
                  .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
                  .fontColor(this.palette().textPrimary)
                Blank()
                if (this.profiles.length > 1) {
                  Text(L10n.t('删除当前'))
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(12, this.uiFontScale))
                    .fontColor('#FFD32F2F')
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .borderRadius(HwRadius.pill)
                    .backgroundColor(this.palette().quoteBg)
                    .onClick(() => {
                      this.removeProfile();
                    })
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              Scroll() {
                Row({ space: HwSpace.xs }) {
                  ForEach(this.profiles, (p: AiApiProfile, i: number) => {
                    // 名称兜底：配置缺 name 时用序号（Text(undefined) 会抛异常把进程带崩）
                    Text(p.name !== undefined && p.name.length > 0 ? p.name : 'API ' + (i + 1))
                      .fontFamily(HwFont.resolve(this.uiFontKey))
                      .fontSize(HwFont.sx(12.5, this.uiFontScale))
                      .fontColor(i === this.activeIdx ? '#FFFFFFFF' : this.palette().textPrimary)
                      .backgroundColor(i === this.activeIdx
                        ? this.palette().accent
                        : this.palette().quoteBg)
                      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                      .borderRadius(HwRadius.pill)
                      .maxLines(1)
                      .onClick(() => {
                        this.switchProfile(i);
                      })
                  }, (p: AiApiProfile, i: number) => 'api' + i + '_'
                    + (p.name !== undefined ? p.name : ''))
                  Text(L10n.t('+ 新增'))
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(12.5, this.uiFontScale))
                    .fontColor(this.palette().accent)
                    .border({ width: 1, color: this.palette().accent })
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .borderRadius(HwRadius.pill)
                    .onClick(() => {
                      this.addProfile();
                    })
                }
                .padding({ right: HwSpace.sm })
                .alignItems(VerticalAlign.Center)
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .width('100%')
              .align(Alignment.Start)

              this.fieldLabel('配置名称', '方便区分多个 API（如「DeepSeek 官方」）')
              ImmersiveCard({
                palette: this.palette(),
                cardRadius: HwRadius.pill,
                cardPadding: 0,
                cardMaterialShadow: false,
                cardOutline: true
              }) {
                TextInput({ text: this.profileName, placeholder: 'API 1' })
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .width('100%')
                  .height(46)
                  .fontSize(HwFont.sx(15, this.uiFontScale))
                  .fontColor(this.palette().textPrimary)
                  .placeholderColor(this.palette().textTertiary)
                  .placeholderFont({ size: 14 })
                  .backgroundColor(Color.Transparent)
                  .padding({ left: 16, right: 16 })
                  .onChange((v: string) => {
                    this.profileName = v;
                  })
              }

              this.fieldLabel('API 地址',
                'OpenAI 兼容（/chat/completions）或 Anthropic（/v1/messages）；填 https://api.xxx.com/v1 会自动补全')
              ImmersiveCard({
                palette: this.palette(),
                cardRadius: HwRadius.pill,
                cardPadding: 0,
                cardMaterialShadow: false,
                cardOutline: true
              }) {
                TextInput({ text: this.apiUrl,
                  placeholder: L10n.t('https://api.deepseek.com/v1 或 https://api.anthropic.com') })
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .width('100%')
                  .height(46)
                  .fontSize(HwFont.sx(15, this.uiFontScale))
                  .fontColor(this.palette().textPrimary)
                  .placeholderColor(this.palette().textTertiary)
                  .placeholderFont({ size: 14 })
                  .backgroundColor(Color.Transparent)
                  .padding({ left: 16, right: 16 })
                  .onChange((v: string) => {
                    this.apiUrl = v;
                  })
              }

              this.fieldLabel('API Key', '')
              ImmersiveCard({
                palette: this.palette(),
                cardRadius: HwRadius.pill,
                cardPadding: 0,
                cardMaterialShadow: false,
                cardOutline: true
              }) {
                TextInput({ text: this.apiKey, placeholder: 'sk-…' })
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .width('100%')
                  .height(46)
                  .fontSize(HwFont.sx(15, this.uiFontScale))
                  .fontColor(this.palette().textPrimary)
                  .placeholderColor(this.palette().textTertiary)
                  .placeholderFont({ size: 14 })
                  .type(InputType.Password)
                  .backgroundColor(Color.Transparent)
                  .padding({ left: 16, right: 16 })
                  .onChange((v: string) => {
                    this.apiKey = v;
                  })
              }

              this.fieldLabel('模型名称',
                '可填多个（逗号分隔），对话时可切换；第一个为默认')
              ImmersiveCard({
                palette: this.palette(),
                cardRadius: HwRadius.pill,
                cardPadding: 0,
                cardMaterialShadow: false,
                cardOutline: true
              }) {
                TextInput({ text: this.modelsText,
                  placeholder: 'deepseek-chat, claude-sonnet-4-5' })
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .width('100%')
                  .height(46)
                  .fontSize(HwFont.sx(15, this.uiFontScale))
                  .fontColor(this.palette().textPrimary)
                  .placeholderColor(this.palette().textTertiary)
                  .placeholderFont({ size: 14 })
                  .backgroundColor(Color.Transparent)
                  .padding({ left: 16, right: 16 })
                  .onChange((v: string) => {
                    this.modelsText = v;
                  })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          // ── 提示词与思考强度卡 ──
          ImmersiveCard({ palette: this.palette() }) {
            Column({ space: HwSpace.sm }) {
              this.fieldLabel('系统提示词', '告诉 AI 它是谁、怎么回答；留空则不发送')
              ImmersiveCard({
                palette: this.palette(),
                cardRadius: 20,
                cardPadding: 6,
                cardMaterialShadow: false,
                cardOutline: true
              }) {
                TextArea({ text: this.systemPrompt,
                  placeholder: L10n.t('例：你是我的阅读助手，回答简洁准确，用中文。') })
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .width('100%')
                  .fontSize(HwFont.sx(15, this.uiFontScale))
                  .fontColor(this.palette().textPrimary)
                  .placeholderColor(this.palette().textTertiary)
                  .placeholderFont({ size: 14 })
                  .backgroundColor(Color.Transparent)
                  .constraintSize({ minHeight: 96, maxHeight: 168 })
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .onChange((v: string) => {
                    this.systemPrompt = v;
                  })
              }

              this.fieldLabel('思考强度',
                '映射为 reasoning_effort；关闭 = 不发送该字段（模型不支持时选关闭）')
              Row({ space: HwSpace.xs }) {
                ImmersiveChip({
                  palette: this.palette(),
                  chipActive: this.reasoning === 0,
                  chipLabel: L10n.t('关闭'),
                  chipOnTap: () => {
                    this.reasoning = 0;
                  }
                })
                ImmersiveChip({
                  palette: this.palette(),
                  chipActive: this.reasoning === 1,
                  chipLabel: L10n.t('标准'),
                  chipOnTap: () => {
                    this.reasoning = 1;
                  }
                })
                ImmersiveChip({
                  palette: this.palette(),
                  chipActive: this.reasoning === 2,
                  chipLabel: L10n.t('深度'),
                  chipOnTap: () => {
                    this.reasoning = 2;
                  }
                })
                Blank()
              }
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          // ── 测试连接行 ──
          ImmersiveCard({ palette: this.palette(), cardOutline: true, cardClickable: true, cardOnTap: () => {
            this.test();
          } }) {
            Row({ space: HwSpace.sm }) {
              Text(this.testing ? L10n.t('正在测试…') : L10n.t('测试连接'))
                .fontFamily(HwFont.resolve(this.uiFontKey))
                .fontSize(HwFont.sx(15, this.uiFontScale))
                .fontColor(this.palette().accent)
              Blank()
              if (this.testing) {
                LoadingProgress()
                  .width(18)
                  .height(18)
                  .color(this.palette().accent)
              } else {
                SymbolGlyph($r('sys.symbol.paperplane'))
                  .fontSize(16)
                  .fontColor([this.palette().accent])
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }

          // ── 保存按钮（胶囊 + 沉浸光感）──
          Column() {
            ImmersiveCard({
              palette: this.palette(),
              cardRadius: HwRadius.pill,
              cardPadding: 0,
              cardMaterialShadow: true,
              cardOutline: true,
              cardClickable: true,
              cardOnTap: () => {
                this.save();
              }
            }) {
              Row() {
                Text(L10n.t('保 存'))
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(16, this.uiFontScale))
                  .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
                  .fontColor(this.palette().accent)
              }
              .width('100%')
              .height(48)
              .justifyContent(FlexAlign.Center)
            }
          }
          .width('100%')
          .margin({ bottom: HwSpace.md })
          // ── 词元消耗统计（总计 + 时间维 + 历年 + 按模型）──
          ImmersiveCard({ palette: this.palette() }) {
            Column({ space: HwSpace.sm }) {
              Row({ space: HwSpace.sm }) {
                Text(L10n.t('词元消耗'))
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(15, this.uiFontScale))
                  .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
                  .fontColor(this.palette().textPrimary)
                Blank()
                if (this.usage.totalReplies > 0) {
                  Text(L10n.t('共 ') + this.usage.totalReplies + ' 次 · '
                    + this.fmtStatNum(this.usage.totalTokens) + ' 词元')
                    .fontFamily(HwFont.resolve(this.uiFontKey))
                    .fontSize(HwFont.sx(12.5, this.uiFontScale))
                    .fontColor(this.palette().textTertiary)
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              if (this.usage.totalReplies === 0) {
                Text(L10n.t('暂无记录 · 与 AI 对话后这里会按时间与模型统计'))
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(12.5, this.uiFontScale))
                  .fontColor(this.palette().textTertiary)
              }
              if (this.usage.totalReplies > 0) {
                // 时间维网格（两行三列）：独立口径，今天的消耗同时计入近一周
                Row({ space: HwSpace.xs }) {
                  this.usageCell('今天', this.usage.today)
                  this.usageCell('昨天', this.usage.yesterday)
                  this.usageCell('近一周', this.usage.week)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                Row({ space: HwSpace.xs }) {
                  this.usageCell('近一月', this.usage.month)
                  this.usageCell('近半年', this.usage.halfYear)
                  this.usageCell('近一年', this.usage.year)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                Divider()
                  .strokeWidth(0.6)
                  .color(this.palette().divider)
                Text(L10n.t('历年'))
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(12, this.uiFontScale))
                  .fontColor(this.palette().textTertiary)
                ForEach(this.usage.years, (ys: AiTokenYearStat) => {
                  Row({ space: HwSpace.sm }) {
                    Text(ys.year + ' 年')
                      .fontFamily(HwFont.resolve(this.uiFontKey))
                      .fontSize(HwFont.sx(13, this.uiFontScale))
                      .fontColor(this.palette().textPrimary)
                    Blank()
                    Text(ys.replies + ' 次 · ' + this.fmtStatNum(ys.tokens) + ' 词元')
                      .fontFamily(HwFont.resolve(this.uiFontKey))
                      .fontSize(HwFont.sx(12, this.uiFontScale))
                      .fontColor(this.palette().textSecondary)
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)
                }, (ys: AiTokenYearStat) => '' + ys.year)
                Divider()
                  .strokeWidth(0.6)
                  .color(this.palette().divider)
                Text(L10n.t('按模型'))
                  .fontFamily(HwFont.resolve(this.uiFontKey))
                  .fontSize(HwFont.sx(12, this.uiFontScale))
                  .fontColor(this.palette().textTertiary)
                ForEach(this.usage.models, (st: AiTokenStat) => {
                  Row({ space: HwSpace.sm }) {
                    Text(st.model)
                      .fontFamily(HwFont.resolve(this.uiFontKey))
                      .fontSize(HwFont.sx(13, this.uiFontScale))
                      .fontColor(this.palette().textPrimary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Blank()
                    Text(st.replies + ' 次 · ' + this.fmtStatNum(st.tokens) + ' 词元')
                      .fontFamily(HwFont.resolve(this.uiFontKey))
                      .fontSize(HwFont.sx(12, this.uiFontScale))
                      .fontColor(this.palette().textSecondary)
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)
                }, (st: AiTokenStat) => st.model)
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

  /** 全屏形态滚动区：自带滚动与让位。嵌入态**不用**它——SettingsShell 已有自己的
   * Scroll 与上下让位，再包一层 Scroll（height 100% + 底部让位）会在页顶/页底各压出一段空白 */
  @Builder
  settingScroll() {
    Scroll() {
      this.settingContent()
    }
    .width('100%')
    .height('100%')
    // 铺进状态栏（与书架同一写法）：不展开的话那条带里没有可糊的内容
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
    .padding({
      left: HwSpace.lg,
      right: HwSpace.lg,
      top: this.getUIContext().px2vp(this.safeTopPx) + HwBar.pill + HwSpace.lg,
      bottom: this.getUIContext().px2vp(this.safeBottomPx) + HwSpace.lg
    })
  }

  /** 表单小节标签 + 说明（1.2.0 加大字号） */
  @Builder
  fieldLabel(title: string, desc: string) {
    Column({ space: 3 }) {
      Text(title)
        .fontFamily(HwFont.resolve(this.uiFontKey))
        .fontSize(HwFont.sx(15, this.uiFontScale))
        .fontWeight(HwFont.bump(FontWeight.Medium, this.uiFontWeightDelta))
        .fontColor(this.palette().textPrimary)
      if (desc.length > 0) {
        Text(desc)
          .fontFamily(HwFont.resolve(this.uiFontKey))
          .fontSize(HwFont.sx(12.5, this.uiFontScale))
          .fontColor(this.palette().textTertiary)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .key('aiset_l' + this.languageTick)
  }
}
