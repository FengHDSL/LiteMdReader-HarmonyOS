/**
 * 澄笺 · 设置 · 探索中心
 * ====================
 *
 * 从设置中心拆出来的独立页：关于应用、法务文本（隐私政策 / 用户协议）、
 * 参考项目致谢。把「介绍与法务」从设置主线里分离出来，
 * 让设置中心只剩实用项。
 *
 * 法务文本直接从 Settings.ets 导入（那两份常量已 export），避免维护两份。
 */
import { NavLifecycle } from '../service/NavLifecycle';
import { ImmersiveCard, ImmersiveChip, ImmersiveIconButton } from '../material/ImmersiveCard';
import { SettingsShell } from './SettingsShell';
import { webview } from '@kit.ArkWeb';
import { LegalDoc } from './LegalDoc';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { promptAction } from '@kit.ArkUI';
import {
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  paletteFor
} from '../theme/DesignTokens';

/**
 * 澄笺在 HAP 资源站上的详情页（用户指定）。
 * 「检查更新」直接拉这个页面、解析版本徽标（fa-code-branch 后的 vX.Y.Z）来比对。
 */
const UPDATE_SITE: string = 'https://www.sydxky.cn/detail.php?id=956';

/** 检查更新超时（毫秒）：网络不可达 / 域名解析失败时给个明确提示，不要一直转 */
const UPDATE_TIMEOUT: number = 8000;

/** 平板分栏内嵌法务文档的 Web 高度（vp）：420 在横屏下太矮，正文只剩几行 */
const EMBEDDED_LEGAL_HEIGHT: number = 560;

/** 参考项目（名称 + 地址 + 一句话说明） */
interface CreditItem {
  name: string;
  url: string;
  note: string;
}

const CREDITS: CreditItem[] = [
  {
    name: 'MrCashmere / miha_hm',
    url: 'https://github.com/MrCashmere/miha_hm',
    note: '沉浸光感承载层（Toggle + attributeModifier）方案参考'
  },
  {
    name: 'skadjhljhas / zhumo-reader',
    url: 'https://github.com/skadjhljhas/zhumo-reader',
    note: '注释卡片式阅读形态参考'
  },
  {
    name: 'HarmonyOS Samples · transitions-collection',
    url: 'https://gitcode.com/HarmonyOS_Samples/transitions-collection',
    note: '一镜到底 / 多模态转场动效参考'
  }
];

@Component
export struct SettingsExplore {
  stack: NavPathStack | null = null;
  life: NavLifecycle = new NavLifecycle();

  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 外观刷新计数：主题色 / 灰字 / 沾色改动后由它触发重算 */
  @StorageProp('appearanceTick') appearanceTick: number = 0;
  @State versionName: string = '1.0.0';
  /** 「检查更新」进行中（按钮转圈 + 文案变「检查中…」，期间重复点击直接忽略） */
  @State checkingUpdate: boolean = false;
  /** 平板分栏嵌入模式：true = 由设置分栏的右栏承载，法务在卡片内展开 */
  @Prop embedded: boolean = false;
  /** 嵌入模式下正在展示的法务文档：'' / 'privacy' / 'terms' */
  @State legalDoc: string = '';
  /**
   * 嵌入式法务 Web 的控制器：**两份文档各一个**。
   * 之前共用一个 controller 给两个 if/else 分支的 Web 组件——同一个起始终结的
   * WebviewController 被两个组件抢绑，横屏分栏下切到另一份文档时新组件拿不到控制权，
   * 表现就是「点了没反应，要连点好几次」。一文档一控制器后即点即换。
   */
  private legalCtrlPrivacy: webview.WebviewController = new webview.WebviewController();
  private legalCtrlTerms: webview.WebviewController = new webview.WebviewController();

  /** **全屏覆盖层**（从下往上滑出，用户要求）：是否展示法务文档 */
  @State coverShow: boolean = false;
  /** 覆盖层正在展示的法务文档：'privacy' / 'terms' */
  @State coverDoc: string = 'privacy';

  /**
   * 打开法务文档：
   *  · **默认：全屏覆盖层，从下往上滑出**（bindContentCover + DEFAULT 转场，用户要求）；
   *  · 平板分栏嵌入模式（embedded）：在当前卡片内展开 Web，不全屏弹出。
   */
  private openLegal(doc: string): void {
    if (this.embedded) {
      if (this.legalDoc !== doc) {
        this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
          this.legalDoc = doc;
        });
      } else {
        this.legalDoc = '';
      }
      return;
    }
    this.coverDoc = doc;
    this.coverShow = true;
  }

  /** 覆盖层承载的法务文档页（LegalDoc 的返回回调收起覆盖层）。 */
  @Builder
  legalCover() {
    LegalDoc({
      doc: this.coverDoc,
      onBack: () => {
        this.coverShow = false;
      }
    })
  }

  aboutToAppear(): void {
    this.loadVersion();
    this.life.onShow = () => {
      this.loadVersion();
    };
  }

  private loadVersion(): void {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName !== undefined && info.versionName.length > 0) {
        this.versionName = info.versionName;
      }
    } catch (err) {
      // 读不到就沿用默认值
    }
  }

  private palette(): ReaderPalette {
    // 读一下外观刷新计数，主题色 / 灰字 / 沾色改完**当帧**就能重算
    const tick: number = this.appearanceTick;
    return paletteFor(this.themeMode, this.systemDark);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1600 });
    } catch (err) {
      // 忽略
    }
  }

  /** 打开外部链接：失败时提示，别让点击毫无反馈 */
  private openLink(url: string): void {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      this.toast('打不开浏览器：' + url);
      return;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: url
    };
    try {
      (c as common.UIAbilityContext).startAbility(want).catch(() => {
        this.toast('打不开浏览器：' + url);
      });
    } catch (err) {
      this.toast('打不开浏览器：' + url);
    }
  }

  // ══════════════════════ 检查更新 ══════════════════════
  //
  // 做法与参考项目 xjau 的 AboutPage 一致：拉取 HAP 资源站详情页 HTML，
  // 解析版本徽标（`fa-code-branch` 后紧跟的 `<span>vX.Y.Z</span>`）作为最新版本，
  // 再与 bundleManager 读到的当前版本逐段比对：
  //   远端更高 → 弹「发现新版本」并可跳转资源站；当前更高 → 「版本超前」；相等 → toast 已是最新。

  /** 检查更新：8 秒超时保护 + 重复点击忽略（网络不通时给明确提示，不一直转圈）。 */
  private checkUpdate(): void {
    if (this.checkingUpdate) {
      return;
    }
    this.checkingUpdate = true;
    let finished: boolean = false;
    const timer = setTimeout(() => {
      if (!finished) {
        finished = true;
        this.checkingUpdate = false;
        this.toast('检查更新超时，请稍后再试');
      }
    }, UPDATE_TIMEOUT);
    const httpRequest = http.createHttp();
    httpRequest.request(UPDATE_SITE, {
      method: http.RequestMethod.GET,
      connectTimeout: UPDATE_TIMEOUT,
      readTimeout: UPDATE_TIMEOUT,
      header: { 'User-Agent': 'Mozilla/5.0 (HarmonyOS) ChengJian' }
    }).then((resp: http.HttpResponse) => {
      if (finished) {
        return;
      }
      finished = true;
      clearTimeout(timer);
      httpRequest.destroy();
      this.checkingUpdate = false;
      const html: string = typeof resp.result === 'string' ? resp.result : '';
      const remote: string = this.parseRemoteVersion(html);
      if (remote.length === 0) {
        this.toast('检查更新失败，请稍后再试');
        return;
      }
      const cmp: number = this.compareVersion(this.versionName, remote);
      if (cmp < 0) {
        this.getUIContext().getPromptAction().showDialog({
          title: '发现新版本',
          message: '发现新版本 v' + remote + '（当前 v' + this.versionName + '）。' +
            '可前往 HAP 资源站查看更新说明并下载安装包。',
          buttons: [
            { text: '前往更新', color: this.palette().accent },
            { text: '稍后再说', color: this.palette().textSecondary }
          ]
        }).then((res: promptAction.ShowDialogSuccessResponse) => {
          if (res.index === 0) {
            this.openLink(UPDATE_SITE);
          }
        }).catch(() => {
          // 用户手势取消对话框，无需提示
        });
      } else if (cmp > 0) {
        this.getUIContext().getPromptAction().showDialog({
          title: '版本超前',
          message: '当前版本（v' + this.versionName + '）比最新版本（v' + remote + '）更高！',
          buttons: [
            { text: '知道了', color: this.palette().accent }
          ]
        }).catch(() => {
          // 关闭失败无副作用
        });
      } else {
        this.toast('已是最新版本（v' + this.versionName + '）');
      }
    }).catch(() => {
      if (finished) {
        return;
      }
      finished = true;
      clearTimeout(timer);
      httpRequest.destroy();
      this.checkingUpdate = false;
      this.toast('检查更新失败，请检查网络后重试');
    });
  }

  /**
   * 从资源站 HTML 解析最新版本号。
   * 优先版本徽标锚点（`fa-code-branch` 后 400 字符内），兜底全页第一个 `vX.Y.Z`；
   * 取不到返回空串（调用方按「检查更新失败」处理）。
   */
  private parseRemoteVersion(html: string): string {
    const anchor: number = html.indexOf('fa-code-branch');
    if (anchor >= 0) {
      const seg: string = html.substring(anchor, Math.min(anchor + 400, html.length));
      const m: RegExpMatchArray | null = seg.match(/<span>\s*v(\d+\.\d+(?:\.\d+)?)\s*<\/span>/);
      if (m !== null && m.length > 1) {
        return m[1];
      }
    }
    const m2: RegExpMatchArray | null = html.match(/<span>\s*v(\d+\.\d+(?:\.\d+)?)\s*<\/span>/);
    if (m2 !== null && m2.length > 1) {
      return m2[1];
    }
    return '';
  }

  /** 版本号比较：a>b 返回 1，a<b 返回 -1，相等返回 0（按数字段逐段比较，缺位补 0）。 */
  private compareVersion(a: string, b: string): number {
    const pa: string[] = a.split('.');
    const pb: string[] = b.split('.');
    const n: number = Math.max(pa.length, pb.length);
    for (let i = 0; i < n; i++) {
      const x: number = i < pa.length ? parseInt(pa[i], 10) : 0;
      const y: number = i < pb.length ? parseInt(pb[i], 10) : 0;
      const xi: number = isNaN(x) ? 0 : x;
      const yi: number = isNaN(y) ? 0 : y;
      if (xi !== yi) {
        return xi > yi ? 1 : -1;
      }
    }
    return 0;
  }

  build() {
    Column() {
      SettingsShell({
        shellTitle: '探索中心',
        shellSubtitle: '关于应用 · 法务 · 参考与致谢',
        stack: this.stack,
        life: this.life
      }) {
      // ── 关于应用 ──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.md }) {
          Row({ space: HwSpace.md }) {
            Stack() {
              Image($r('app.media.background'))
                .width(60)
                .height(60)
              Image($r('app.media.foreground'))
                .width(60)
                .height(60)
            }
            .width(60)
            .height(60)
            .borderRadius(15)
            .clip(true)
            .border({ width: 0.8, color: this.palette().divider })

            Column({ space: 2 }) {
              Text('澄笺')
                .fontSize(HwType.label + 6)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.palette().textPrimary)
              Text('版本 ' + this.versionName + ' · 项目代号 LiteMdReader · HarmonyOS 原生')
                .fontSize(HwType.caption)
                .fontColor(this.palette().textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text('一款沉浸光感 Markdown 阅读器：卡片化排版、荧光笔批注、多标签阅读、' +
            '函数绘制壁纸，数据留在本机。')
            .fontSize(HwType.label)
            .fontColor(this.palette().textSecondary)
            .lineHeight(HwType.label * 1.7)
            .width('100%')

          Text('「澄」是澄澈透光——磨砂与光感玻璃；「笺」是文人读写的纸笺。')
            .fontSize(HwType.label)
            .fontColor(this.palette().textSecondary)
            .lineHeight(HwType.label * 1.7)
            .width('100%')

          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipActive: true,
              chipLabel: '项目主页',
              chipOnTap: () => {
                this.openLink('https://github.com/FengHDSL/LiteMdReader-HarmonyOS');
              }
            })
            // 检查更新：拉资源站详情页解析最新版本（见 checkUpdate）。
            // 进行中芯片变成高亮态 + 文案「检查中…」，重复点击在方法内部直接忽略。
            ImmersiveChip({
              palette: this.palette(),
              chipActive: this.checkingUpdate,
              chipLabel: this.checkingUpdate ? '检查中…' : '检查更新',
              chipOnTap: () => {
                this.checkUpdate();
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '更新日志',
              chipOnTap: () => {
                if (this.stack === null) {
                  return;
                }
                this.stack.pushPath({ name: 'pages/Changelog' });
              }
            })
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── 参考与致谢 ──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Text('设计与实现参考')
            .fontSize(HwType.label + 1)
            .fontColor(this.palette().textPrimary)
            .width('100%')

          // 只写参考项目的名称（用户要求）
          ForEach(CREDITS, (item: CreditItem) => {
            Row({ space: HwSpace.sm }) {
              Text(item.name)
                .fontSize(HwType.label)
                .fontColor(this.palette().textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .onClick(() => {
                  this.openLink(item.url);
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }, (item: CreditItem) => item.url)

          Text('澄笺 · 光 · 美 · 舒 · 开源')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: HwSpace.sm })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ── 法务（页面底部，按钮居中）：点击跳转**新页面**查看（跟随系统深浅色）──
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          Row({ space: HwSpace.xs }) {
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '隐私政策',
              chipOnTap: () => {
                this.openLegal('privacy');
              }
            })
            ImmersiveChip({
              palette: this.palette(),
              chipLabel: '用户协议',
              chipOnTap: () => {
                this.openLegal('terms');
              }
            })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)

          // 嵌入模式（平板分栏）：法务 Web 直接在卡片内展开，不全屏跳转。
          // **一份文档一个 Web + 一个 controller**：换成同一个 controller 服务两个分支时，
          // 横屏分栏里切换文档会出现「点了没反应、要连点几次」。
          // 高度给到 560（原来 420）：横屏下 420 太矮，正文只剩几行、得一直滚。
          if (this.embedded && this.legalDoc === 'privacy') {
            Web({ src: $rawfile('legal_privacy.html'), controller: this.legalCtrlPrivacy })
              .width('100%')
              .height(EMBEDDED_LEGAL_HEIGHT)
              .borderRadius(HwRadius.inner)
              .backgroundColor(this.palette().pageTop)
          } else if (this.embedded && this.legalDoc === 'terms') {
            Web({ src: $rawfile('legal_terms.html'), controller: this.legalCtrlTerms })
              .width('100%')
              .height(EMBEDDED_LEGAL_HEIGHT)
              .borderRadius(HwRadius.inner)
              .backgroundColor(this.palette().pageTop)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    }
    .width('100%')
    .height('100%')
    // **法务文档：全屏覆盖层，从下往上滑出**（ModalTransition.DEFAULT =
    // 进场向上 / 退场向下，用户要求）。挂在包裹 Column 上（SettingsShell 是
    // 尾随闭包组件，不能再链属性）。
    .bindContentCover(this.coverShow, this.legalCover(), {
      modalTransition: ModalTransition.DEFAULT,
      onDisappear: () => {
        this.coverShow = false;
      }
    })
  }
}
