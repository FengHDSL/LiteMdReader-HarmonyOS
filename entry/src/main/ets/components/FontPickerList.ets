import { ImmersiveCard } from '../material/ImmersiveCard';
/**
 * 澄笺 · 字体列表选择器（阅读正文与界面字体共用）
 * ==============================================
 *
 * 一行一款字体，**字体名与预览句都用该字体本身绘制**（所见即所得），选中项打勾 + 高亮。
 * 三段：默认 → 导入的字体（长按可删除）→ 系统已安装（系统字体管理器 INSTALLED 类型，
 * 由 `FontStore.loadInstalled()` 查列表 + 取 descriptor.fontFamily）。
 * 整块限高 260vp 可上下滑（用户装的字体可能几十款，不能把面板撑出屏幕），四角圆角裁切。
 *
 * 选择结果通过 `onPick` 交回宿主写设置键 —— 本组件不碰 AppStorage：
 * 真机上子组件自己读 AppStorage 不保证回刷（正文字体那条就是栽在这里）。
 */
import { L10n } from '../service/L10n';
import { UserFont, SystemFont, FontStore } from '../service/FontStore';
import { AppearanceFx } from '../service/AppearanceFx';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import {
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  LIGHT_PALETTE,
  HwFont
} from '../theme/DesignTokens';

/**
 * 每行第二句的预览样本：**只用拉丁字母与数字**。
 * 有些用户导入的字体 CJK 码位映射是坏的（或缺中文字形），拿中文做预览就是一片
 * 方块/乱码，看着像"这个列表坏了"；拉丁与数字几乎每款字体都覆盖，能稳定看出字形差别。
 */
const PREVIEW_LINE: string = 'Aa Bb 123 abcdefg';

/** 字体总数超过这个数就提示一次（几十款同时按各自字形画预览，首帧明显发涩） */
const FONT_MANY: number = 40;
/** 提示里给出的"只列前 N 款"的 N */
const FONT_TRIM_TO: number = 30;

@Component
export struct FontPickerList {
  /** 调色板：**必须 @Prop**，否则换肤后不更新 */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /** 当前选中的字体族（空串 = 默认） */
  @Prop chosen: string = '';
  /** 沉浸光感总开关：关闭时列表要加一圈实色包边（用户要求） */
  @Prop fxLookOn: boolean = false;
  /** 是否列「默认」这一项（阅读正文与界面字体都要，卡片等窄面板可以省） */
  @Prop showDefault: boolean = true;
  /** 导入的字体是否允许长按删除（外观页不给删，避免在两个地方做同一件危险操作） */
  @Prop allowRemove: boolean = true;
  /** 选中回调：宿主把它写进自己的设置键 */
  onPick: (key: string) => void = () => {
  };
  /** 删除回调（仅导入的字体可删；宿主没接就只是不给长按动作） */
  onRemove: (family: string) => void = () => {
  };
  /** 宿主导入 / 删除字体后把这个值自增，列表重新取一遍（否则要等下次打开面板才更新） */
  @Prop @Watch('reload') rev: number = 0;

  /** 用户导入进沙箱的字体 */
  @State userFonts: UserFont[] = [];
  /** 系统字体表里的一款（**含每个样式**，按类型分组显示） */
  @State systemFonts: SystemFont[] = [];
  /** 注册完成计数：拼进 ForEach 的 key，注册完强制重画一遍（否则预览行停在系统默认字） */
  @State regTick: number = 0;
  /** 刷新进行中（转圈 + 防重复点） */
  @State refreshing: boolean = false;
  /** 字体过多时是否只列前 `FONT_TRIM_TO` 款（由提示弹窗里用户选） */
  @State trimToMax: boolean = false;
  /** 一次面板生命周期里只提示一次"字体较多"，不反复打扰 */
  private warnedMany: boolean = false;
  /** **收藏的字体 key**（逗号分隔，AppStorage 持久化；长按行收藏 / 取消，用户要求） */
  @State favRaw: string = '';

  aboutToAppear(): void {
    const fav: string | undefined = AppStorage.get<string>('favFonts');
    this.favRaw = fav === undefined || fav === null ? '' : fav;
    this.reload();
  }

  /** 收藏键列表 */
  private favKeys(): string[] {
    if (this.favRaw.length === 0) {
      return [];
    }
    const parts: string[] = this.favRaw.split(',');
    const out: string[] = [];
    for (let k = 0; k < parts.length; k++) {
      if (parts[k].length > 0) {
        out.push(parts[k]);
      }
    }
    return out;
  }

  private isFav(key: string): boolean {
    return key.length > 0 && this.favKeys().indexOf(key) >= 0;
  }

  /** 收藏 / 取消收藏（长按行触发） */
  private toggleFav(key: string): void {
    if (key.length === 0) {
      return;
    }
    const list: string[] = this.favKeys();
    const at: number = list.indexOf(key);
    if (at >= 0) {
      list.splice(at, 1);
    } else {
      list.push(key);
    }
    this.favRaw = list.join(',');
    AppStorage.setOrCreate('favFonts', this.favRaw);
    this.getUIContext().getPromptAction().showToast({
      message: at >= 0 ? L10n.t('已取消收藏：') + key : L10n.t('已收藏：') + key,
      duration: 1400
    });
  }

  /** 收藏项的显示名（从两份列表里查；查不到就用 key 本身） */
  private nameOfKey(key: string): string {
    for (let k = 0; k < this.userFonts.length; k++) {
      if (this.userFonts[k].family === key) {
        return this.showName(key, '');
      }
    }
    for (let k = 0; k < this.systemFonts.length; k++) {
      if (this.systemFonts[k].key === key || this.systemFonts[k].family === key) {
        return this.sysTitle(this.systemFonts[k]);
      }
    }
    return key;
  }

  /** 重新取两份列表（导入 / 删除后宿主可再调一次；列表里的「刷新」按钮走 refreshFonts） */
  reload(): void {
    const c = this.getUIContext().getHostContext();
    if (c !== undefined && c !== null) {
      const ctx = c as common.UIAbilityContext;
      FontStore.registerAll(ctx);
      this.userFonts = FontStore.list(ctx);
    }
    // 列表先出（内存 / 磁盘索引命中就是当帧画完），注册放后面慢慢做：
    // 逐款 registerFont 是打开面板那一下卡顿的大头，没必要让列表等它。
    FontStore.loadInstalled().then((list: SystemFont[]) => {
      this.systemFonts = list;
      this.checkTooMany();
      return FontStore.registerInstalledAll();
    }).then(() => {
      // 注册完再画一遍：没注册时 fontFamily 解析不到，预览行是系统默认字
      this.regTick++;
    }).catch(() => {
      // 取不到就只留导入的那份
    });
  }

  /** 「刷新字体数据」：强制重扫系统字体表并重写磁盘索引 */
  private refreshFonts(): void {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    FontStore.refreshInstalled().then((n: number) => {
      return FontStore.registerInstalledAll().then(() => {
        return n;
      });
    }).then((n: number) => {
      this.systemFonts = FontStore.sysCache.slice();
      this.regTick++;
      this.warnedMany = false;
      this.trimToMax = false;
      this.refreshing = false;
      this.getUIContext().getPromptAction().showToast({
        message: L10n.t('字体列表已刷新，共 ') + n + L10n.t(' 款系统字体'),
        duration: 1800
      });
      this.checkTooMany();
    }).catch(() => {
      this.refreshing = false;
      this.getUIContext().getPromptAction().showToast({
        message: L10n.t('刷新失败，稍后再试'),
        duration: 1600
      });
    });
  }

  /** 按类型分组（installed = 用户在系统字体管理器里装的 / generic = 系统自带 / stylish = 样式字体） */
  private sysOfType(tag: string): SystemFont[] {
    const out: SystemFont[] = [];
    const list: SystemFont[] = this.trimToMax && this.systemFonts.length > FONT_TRIM_TO
      ? this.systemFonts.slice(0, FONT_TRIM_TO) : this.systemFonts;
    for (let k = 0; k < list.length; k++) {
      if (list[k].type === tag) {
        out.push(list[k]);
      }
    }
    return out;
  }

  /** 导入 + 系统已安装的总数（决定要不要提示"字体较多"） */
  private totalFonts(): number {
    return this.userFonts.length + this.systemFonts.length;
  }

  /** 按「只列前 N 款」开关裁剪后的两份列表 */
  private shownUserFonts(): UserFont[] {
    return this.trimToMax && this.userFonts.length > FONT_TRIM_TO
      ? this.userFonts.slice(0, FONT_TRIM_TO) : this.userFonts;
  }

  /**
   * 字体几十款时先问一句：每一款都要按自己的字形画预览，列表首帧会明显发涩
   * （用户要求"检测到可能会卡就弹窗提示"）。选「只列前 30 款」后仍可再展开看全部。
   */
  private checkTooMany(): void {
    // **用户要求：删除「字体较多」弹窗，直接展示全部字体**（加载提示由宿主管）
    return;
    const n: number = this.totalFonts();
    if (this.warnedMany || n < FONT_MANY) {
      return;
    }
    this.warnedMany = true;
    const btns: promptAction.Button[] = [
      { text: L10n.t('只列前 30 款'), color: this.palette.accent },
      { text: L10n.t('全部显示'), color: this.palette.textSecondary }
    ];
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: L10n.t('字体较多'),
        message: L10n.t('检测到 ') + n + L10n.t(' 款字体：每一款都要按自己的字形画预览，列表会有点卡。')
          + L10n.t('可以先只列前 30 款，需要时再全部显示。'),
        buttons: btns
      }).then((dr: promptAction.ShowDialogSuccessResponse) => {
        if (dr.index === 0) {
          this.trimToMax = true;
        }
      }).catch(() => {
        // 手势关掉弹窗：保持全部显示
      });
    } catch (err) {
      // 弹窗不可用就不打扰
    }
  }

  /**
   * 字体名消毒：个别字体描述符里的名字带控制字符 / 替换符（编码异常），直接显示就是一串
   * 方块 —— 看着像列表坏了。这类款式退回用另一个名字显示，两个都不可读时用占位。
   */
  private showName(primary: string, fallback: string): string {
    const a: string = this.cleanName(primary);
    if (a.length > 0) {
      return a;
    }
    const b: string = this.cleanName(fallback);
    return b.length > 0 ? b : L10n.t('未命名');
  }

  private cleanName(s: string): string {
    let out: string = '';
    for (let k = 0; k < s.length; k++) {
      const code: number = s.charCodeAt(k);
      // 控制字符与替换符（U+FFFD）就是"乱码"的直接来源，丢掉
      if (code < 0x20 || code === 0xFFFD) {
        continue;
      }
      out += s.charAt(k);
    }
    return out.trim();
  }

  @Builder
  row(key: string, name: string, sub: string, removable: boolean, active: boolean, seq: number) {
    Row({ space: HwSpace.sm }) {
      // **序号**（用户要求）：字体左边编号，便于按位查找
      Text(String(seq))
        .fontSize(HwType.caption)
        .fontColor(this.palette.textTertiary)
        .width(22)
        .textAlign(TextAlign.End)
      Column({ space: 1 }) {
        Text(name)
          .fontSize(HwType.label + 3)
          .fontFamily(HwFont.resolve(key))
          .fontColor(this.palette.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(sub)
          .fontSize(HwType.caption)
          .fontFamily(HwFont.resolve(key))
          .fontColor(this.palette.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // **收藏星标**（用户要求：长按可收藏）
      if (this.isFav(key)) {
        SymbolGlyph($r('sys.symbol.heart_fill'))
          .fontSize(14)
          .fontColor(['#FFE91E63'])
      }
      if (active) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(18)
          .fontColor([this.palette.accent])
      }
    }
    .width('100%')
    .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 7, bottom: 7 })
    .borderRadius(HwRadius.inner)
    .backgroundColor(active ? this.palette.accentSoft : '#00000000')
    .onClick(() => {
      this.onPick(key);
      // 后台那轮注册可能还没跑到这一款：点中就按需补一次，别等（新格式下正文解析不到会停在默认字）
      if (key.length > 0) {
        FontStore.ensureRegisteredByName(key).catch(() => {
          // 补注册失败交给下面的"读不到文件"提示与后台那轮
        });
      }
      // 系统字体注册不上（沙箱读不到那个字体文件）时，选了也不会有效果 —— 直说，
      // 并给出可行的路：把同一个字体文件用「导入字体」导进来（那条已验证生效）
      if (!FontStore.installedUsable(key)) {
        this.getUIContext().getPromptAction().showToast({
          message: L10n.t('这款系统字体读不到文件，暂时用不了；可以把字体文件用「导入字体」导进来'),
          duration: 2200
        });
      }
    })
    // 手势总要挂（条件挂要写两套分支）：不可删除的行在回调里直接忽略
    .gesture(
      LongPressGesture()
        .onAction(() => {
          if (key.length === 0) {
            return;
          }
          if (removable && this.allowRemove) {
            // 导入的字体：长按给「收藏 / 删除」二选一（保留原有删除能力）
            this.getUIContext().getPromptAction().showDialog({
              title: this.isFav(key) ? L10n.t('取消收藏') : L10n.t('收藏字体'),
              message: name,
              buttons: [
                { text: this.isFav(key) ? L10n.t('取消收藏') : L10n.t('收藏'),
                  color: '#FFE91E63' },
                { text: L10n.t('删除字体'), color: '#FFD32F2F' }
              ]
            }).then((dr: promptAction.ShowDialogSuccessResponse) => {
              if (dr.index === 0) {
                this.toggleFav(key);
              } else if (dr.index === 1) {
                this.onRemove(key);
              }
            }).catch(() => {
              // 手势关闭不动作
            });
          } else {
            this.toggleFav(key);
          }
        })
    )
  }

  /**
   * 系统字体的一行。键用 **fullName**（一款字体的 Regular / Bold / Italic 家族名相同，
   * 只有全名能定位到具体样式），标题显示「家族 · 样式」，预览行用这一款自己画。
   */
  @Builder
  sysRow(f: SystemFont, seq: number) {
    this.row(f.key, this.sysTitle(f), f.fullName + ' · ' + PREVIEW_LINE, false,
      this.chosen === f.key || this.chosen === f.family, seq)
  }

  private sysTitle(f: SystemFont): string {
    const fam: string = this.showName(f.family, f.fullName);
    if (f.style.length === 0) {
      return fam;
    }
    return fam + ' · ' + f.style;
  }

  @Builder
  groupTitle(label: string) {
    Text(label)
      .fontSize(HwType.caption)
      .fontColor(this.palette.textTertiary)
      .width('100%')
      .padding({ left: HwSpace.sm, top: 6, bottom: 2 })
  }

  build() {
    // **沉浸光感**（用户要求）：列表用 ImmersiveCard 承载——
    // 光感开时是玻璃材质、关时自动降级实色不透明；Scroll 自身底色透明让材质透出。
    ImmersiveCard({
      cardRadius: HwRadius.inner,
      cardPadding: 0,
      cardMaterialShadow: false,
      palette: this.palette
    }) {
    Scroll() {
      Column({ space: 2 }) {
        // ── 顶部：总数 + 刷新（重扫系统字体表并写回磁盘索引）──
        Row({ space: HwSpace.xs }) {
          Text(L10n.t('共 ') + this.totalFonts() + L10n.t(' 款可换字体'))
            .fontSize(HwType.caption)
            .fontColor(this.palette.textTertiary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(15)
            .fontColor([this.refreshing ? this.palette.textTertiary : this.palette.accent])
          Text(this.refreshing ? L10n.t('刷新中…') : L10n.t('刷新'))
            .fontSize(HwType.caption)
            .fontColor(this.refreshing ? this.palette.textTertiary : this.palette.accent)
            .onClick(() => {
              this.refreshFonts();
            })
        }
        .width('100%')
        .padding({ left: HwSpace.sm, right: HwSpace.sm, top: 6, bottom: 6 })

        if (this.showDefault) {
          this.row('', L10n.t('默认'), L10n.t('系统默认字形 · ') + PREVIEW_LINE, false,
            this.chosen === '', 1)
        }
        // **收藏分组置顶**（用户要求：长按收藏后能快速找到）
        if (this.favKeys().length > 0) {
          this.groupTitle(L10n.t('收藏'))
          ForEach(this.favKeys(), (k: string, fi: number) => {
            this.row(k, this.nameOfKey(k), PREVIEW_LINE, false, this.chosen === k, fi + 1)
          }, (k: string) => 'fav_' + k + '_' + this.regTick)
        }
        if (this.userFonts.length > 0) {
          this.groupTitle(L10n.t('导入的字体（长按收藏或删除）'))
          ForEach(this.shownUserFonts(), (f: UserFont, ui: number) => {
            this.row(f.family, this.showName(f.family, ''), PREVIEW_LINE, this.allowRemove,
              this.chosen === f.family, ui + 2)
          }, (f: UserFont) => f.family)
        }
        // ── 系统字体按类型分三段；**每个样式单独一行**（家族名分不出 Bold / Italic）──
        if (this.sysOfType('installed').length > 0) {
          this.groupTitle(L10n.t('系统已安装（字体管理器导入的）'))
          ForEach(this.sysOfType('installed'), (f: SystemFont, si: number) => {
            this.sysRow(f, this.userFonts.length + si + 2)
          }, (f: SystemFont) => 'sys_' + f.key + '_' + this.regTick)
        }
        if (this.sysOfType('generic').length > 0) {
          this.groupTitle(L10n.t('系统自带字体'))
          ForEach(this.sysOfType('generic'), (f: SystemFont, si: number) => {
            this.sysRow(f, this.userFonts.length + this.sysOfType('installed').length + si + 2)
          }, (f: SystemFont) => 'gen_' + f.key + '_' + this.regTick)
        }
        if (this.sysOfType('stylish').length > 0) {
          this.groupTitle(L10n.t('样式字体'))
          ForEach(this.sysOfType('stylish'), (f: SystemFont, si: number) => {
            this.sysRow(f, this.userFonts.length + this.sysOfType('installed').length
              + this.sysOfType('generic').length + si + 2)
          }, (f: SystemFont) => 'sty_' + f.key + '_' + this.regTick)
        }
        if (this.trimToMax) {
          // 裁短了要留一个反悔入口：说清"还有多少没列出来"，点一下就全展开
          Text(L10n.t('只列了前 ') + FONT_TRIM_TO + L10n.t(' 款（共 ') + this.totalFonts()
            + L10n.t(' 款）· 点此全部显示'))
            .fontSize(HwType.caption)
            .fontColor(this.palette.accent)
            .width('100%')
            .padding({ left: HwSpace.sm, top: 6, bottom: 6 })
            .onClick(() => {
              this.trimToMax = false;
            })
        }
      }
      .width('100%')
      .padding(4)
      .alignItems(HorizontalAlign.Start)
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .width('100%')
    .constraintSize({ maxHeight: 260 })
    .borderRadius(HwRadius.inner)
    .clip(true)
    // 透明底：材质由 ImmersiveCard 承载（光感关时卡片本身是实色）
    .backgroundColor('#00000000')
    // **包边恒定 1.5vp**（与字体选择按钮同款，光感开关不影响）
    .border({ width: 1.5, color: this.palette.surfaceBorder })
    // **展开 / 收起动画**：淡入 + 竖向轻微缩放。挂在组件自己这层 Scroll 上，
    // 宿主只管用 if 控制出现与消失，阅读设置与外观设置两处共用同一份动效。
    .transition(TransitionEffect.OPACITY
      .combine(TransitionEffect.scale({ x: 0.98, y: 0.86 }))
      .animation(AppearanceFx.anim(200, Curve.FastOutSlowIn)))
    }
  }
}
