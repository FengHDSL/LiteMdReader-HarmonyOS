/**
 * 澄笺 · 合并导出面板（书架多选 / 阅读页「更多」共用）
 * =====================================================
 *
 * 用法：宿主把可选文档清单（sources）与预选集合（preselect）传进来，
 * 面板负责**选篇 / 排序 / 合并样式**，导出动作全部复用单文档管线
 * （合并成一份 Markdown 后交给 ExportService / MdToPlain / HtmlViewer）。
 *
 * ⚠️ sources / preselect 是**普通成员而不是 @Prop**：面板内容在 bindSheet 里，
 * 宿主状态变化不会重渲染它（工程固定坑），所以只在创建那一刻取值；
 * 宿主每次打开面板都要走 sheetEpoch 分支切换强制重建（见 Reader / Index 的接线）。
 *
 * 排序用 ↑↓ 按钮而不是拖拽：面板本身在可滚列表里，长按拖拽与面板下滑关闭
 * 的手势会打架；↑↓ 一步到位，也保证键盘弹起时仍能操作。
 */
import { common } from '@kit.AbilityKit';
import { ExportService } from '../service/ExportService';
import { MergeExport, MergeItem, MergeOptions, MergeSource } from '../service/MergeExport';
import { MdToPlain } from '../markdown/MdToPlain';
import { PrintRoute } from '../service/DocStore';
import { HwRadius, HwSpace, HwType, LIGHT_PALETTE, ReaderPalette } from '../theme/DesignTokens';
import { ImmersiveChip } from '../material/ImmersiveCard';
import { L10n } from '../service/L10n';

@Component
export struct MergeExportPanel {
  /** 可选文档清单（含是否内置）；创建时取一次 */
  sources: MergeSource[] = [];
  /** 预选文档名（顺序即初始合并顺序） */
  preselect: string[] = [];
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /** 打印入口需要导航栈；未传则不显示打印行 */
  stack: NavPathStack | null = null;
  onClosed: () => void = () => {
  };

  /** 已选文档（按合并顺序排列） */
  @State order: string[] = [];
  /** 「添加文档」清单是否展开 */
  @State addOpen: boolean = false;
  @State withTitle: boolean = true;
  @State withDivider: boolean = true;
  @State busy: boolean = false;

  aboutToAppear(): void {
    const known: string[] = [];
    for (let k = 0; k < this.sources.length; k++) {
      known.push(this.sources[k].name);
    }
    const picked: string[] = [];
    for (let k = 0; k < this.preselect.length; k++) {
      const n: string = this.preselect[k];
      if (known.indexOf(n) >= 0 && picked.indexOf(n) < 0) {
        picked.push(n);
      }
    }
    // 一篇都没预选上（比如从阅读页直接进）就把全部文档排进去，用户再删
    this.order = picked.length > 0 ? picked : known;
  }

  private ctx(): common.UIAbilityContext | null {
    const c = this.getUIContext().getHostContext();
    if (c === undefined || c === null) {
      return null;
    }
    return c as common.UIAbilityContext;
  }

  private notify(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1800 });
    } catch (err) {
      // 提示失败无副作用
    }
    if (this.busy) {
      this.busy = false;
      this.onClosed();
    }
  }

  private withBusy(action: () => void): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    action();
  }

  /** 还没被选进去的文档（「添加文档」清单）。 */
  private remaining(): MergeSource[] {
    const out: MergeSource[] = [];
    for (let k = 0; k < this.sources.length; k++) {
      if (this.order.indexOf(this.sources[k].name) < 0) {
        out.push(this.sources[k]);
      }
    }
    return out;
  }

  private move(from: number, delta: number): void {
    const to: number = from + delta;
    if (from < 0 || from >= this.order.length || to < 0 || to >= this.order.length) {
      return;
    }
    const next: string[] = this.order.slice();
    const tmp: string = next[from];
    next[from] = next[to];
    next[to] = tmp;
    this.order = next;
  }

  private removeAt(i: number): void {
    if (i < 0 || i >= this.order.length) {
      return;
    }
    const next: string[] = this.order.slice();
    next.splice(i, 1);
    this.order = next;
  }

  private addDoc(name: string): void {
    if (this.order.indexOf(name) >= 0) {
      return;
    }
    this.order = this.order.concat([name]);
  }

  /**
   * 读出所有已选文档的正文并组装成合并 Markdown。
   * 读失败/全空时返回 null 并已给出提示（调用方直接返回即可）。
   */
  private buildMerged(): string | null {
    const ctx = this.ctx();
    if (ctx === null) {
      return null;
    }
    if (this.order.length === 0) {
      this.notify('先选择要合并的文档');
      return null;
    }
    const items: MergeItem[] = [];
    for (let k = 0; k < this.order.length; k++) {
      const name: string = this.order[k];
      let builtin: boolean = false;
      for (let s = 0; s < this.sources.length; s++) {
        if (this.sources[s].name === name) {
          builtin = this.sources[s].builtin;
          break;
        }
      }
      const content: string | null = ExportService.readContent(ctx, name, builtin);
      if (content === null) {
        this.notify('读取「' + name + '」失败');
        return null;
      }
      items.push({ name: name, content: content } as MergeItem);
    }
    const opts: MergeOptions = { withTitle: this.withTitle, withDivider: this.withDivider };
    const merged: string = MergeExport.buildMarkdown(items, opts);
    if (merged.length === 0) {
      this.notify('选中的文档都是空的');
      return null;
    }
    return merged;
  }

  private fileName(ext: string): string {
    return MergeExport.mergedName(this.order) + ext;
  }

  private doHtml(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const merged: string | null = this.buildMerged();
    if (merged === null) {
      return;
    }
    this.withBusy(() => {
      ExportService.exportHtmlSmart(ctx, MergeExport.mergedName(this.order), merged,
        (m: string) => {
          this.notify(m);
        });
    });
  }

  private doMd(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const merged: string | null = this.buildMerged();
    if (merged === null) {
      return;
    }
    this.withBusy(() => {
      ExportService.saveText(ctx, this.fileName('.md'), merged, (m: string) => {
        this.notify(m);
      });
    });
  }

  private doTxt(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    const merged: string | null = this.buildMerged();
    if (merged === null) {
      return;
    }
    this.withBusy(() => {
      try {
        const text: string = MdToPlain.convert(merged);
        if (text.length === 0) {
          this.notify('正文为空');
          return;
        }
        ExportService.saveText(ctx, this.fileName('.txt'), text, (m: string) => {
          this.notify(m);
        });
      } catch (err) {
        this.notify('转换纯文本失败');
      }
    });
  }

  /** 打印：合并正文交给打印准备页（页内构建 HTML 并调起系统打印预览）。 */
  private doPrint(): void {
    if (this.stack === null) {
      this.notify('当前环境不支持打印');
      return;
    }
    const merged: string | null = this.buildMerged();
    if (merged === null) {
      return;
    }
    try {
      this.stack.pushPath({
        name: 'pages/HtmlViewer',
        param: {
          docName: MergeExport.mergedName(this.order),
          content: merged,
          htmlPath: ''
        } as PrintRoute
      });
    } catch (err) {
      this.notify('无法打开打印');
    }
  }

  /**
   * 排序行：序号 + 文档名 + 上移 / 下移 / 移除。
   * ⚠️ 三个按钮**刻意内联写**，没有抽成带参数的 @Builder：
   *    · `$r()` 的参数必须是字面量，传变量取不到资源；
   *    · 带参数的 @Builder 按值传参，`dimmed` 变了不会刷新（工程同类坑）。
   *    可用性一律直接读 index / order.length，配合 ForEach 的 key 带上位置，
   *    交换顺序后整行必然重建。
   */
  @Builder
  docRow(name: string, index: number) {
    Row({ space: HwSpace.xs }) {
      Text('' + (index + 1))
        .fontSize(HwType.caption)
        .fontColor(this.palette.textTertiary)
        .width(20)
        .textAlign(TextAlign.Center)
      Text(name)
        .fontSize(HwType.label)
        .fontColor(this.palette.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_up'))
        .fontSize(15)
        .fontColor([this.palette.textSecondary])
        .opacity(index === 0 ? 0.3 : 1)
        .width(30)
        .height(30)
        .onClick(() => {
          this.move(index, -1);
        })
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(15)
        .fontColor([this.palette.textSecondary])
        .opacity(index === this.order.length - 1 ? 0.3 : 1)
        .width(30)
        .height(30)
        .onClick(() => {
          this.move(index, 1);
        })
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(15)
        .fontColor([this.palette.textSecondary])
        .width(30)
        .height(30)
        .onClick(() => {
          this.removeAt(index);
        })
    }
    .width('100%')
    .height(40)
    .borderRadius(HwRadius.inline)
    .backgroundColor(this.palette.quoteBg)
    .padding({ left: HwSpace.xs, right: HwSpace.xs })
  }

  @Builder
  switchRow(label: string, hint: string, on: boolean, setOn: (v: boolean) => void) {
    Row({ space: HwSpace.sm }) {
      Column({ space: 2 }) {
        Text(label)
          .fontSize(HwType.label)
          .fontColor(this.palette.textPrimary)
        Text(hint)
          .fontSize(HwType.caption)
          .fontColor(this.palette.textTertiary)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: on })
        .selectedColor(this.palette.accent)
        .onChange((v: boolean) => {
          setOn(v);
        })
    }
    .width('100%')
  }

  @Builder
  exportRow(label: string, hint: string, action: () => void) {
    Row({ space: HwSpace.sm }) {
      Column({ space: 2 }) {
        Text(label)
          .fontSize(HwType.label + 1)
          .fontColor(this.palette.textPrimary)
        Text(hint)
          .fontSize(HwType.caption)
          .fontColor(this.palette.textTertiary)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([this.palette.textTertiary])
    }
    .width('100%')
    .height(52)
    .borderRadius(HwRadius.inner)
    .onClick(() => {
      action();
    })
  }

  build() {
    Stack() {
      // 面板**不整页可滚**：宿主给的是 fitContent 起档（书架侧）或档位阶梯（阅读页侧），
      // 外层再套一个 Scroll 会让高度测量变成循环（fitContent 问内容要多高、
      // Scroll 问父级要多高 → 塌陷）。会无限变长的只有清单那一块，就只滚它。
      Column({ space: HwSpace.sm }) {
        Text(L10n.t('已选 ') + this.order.length + ' 篇 · 按从上到下的顺序合并')
          .fontSize(HwType.caption)
          .fontColor(this.palette.textTertiary)
          .width('100%')

        Scroll() {
          Column({ space: HwSpace.xs }) {
            ForEach(this.order, (name: string, index: number) => {
              this.docRow(name, index)
            }, (name: string, index: number) => name + '@' + index + '#' + this.order.length)
            if (this.order.length === 0) {
              Text(L10n.t('还没有选中任何文档，点下面「添加文档」。'))
                .fontSize(HwType.label)
                .fontColor(this.palette.textTertiary)
                .width('100%')
                .padding(HwSpace.sm)
            }
          }
          .width('100%')
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Auto)
        .width('100%')
        .constraintSize({ maxHeight: 240 })

        Row({ space: HwSpace.sm }) {
          ImmersiveChip({
            palette: this.palette,
            chipActive: true,
            chipLabel: this.addOpen ? '收起添加' : '添加文档',
            chipOnTap: () => {
              this.addOpen = !this.addOpen;
            }
          })
        }
        .width('100%')

        if (this.addOpen) {
          Column({ space: HwSpace.xs }) {
            ForEach(this.remaining(), (s: MergeSource) => {
              Row({ space: HwSpace.sm }) {
                Text(s.name)
                  .fontSize(HwType.label)
                  .fontColor(this.palette.textPrimary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                SymbolGlyph($r('sys.symbol.plus'))
                  .fontSize(15)
                  .fontColor([this.palette.accent])
              }
              .width('100%')
              .height(40)
              .padding({ left: HwSpace.xs, right: HwSpace.xs })
              .borderRadius(HwRadius.inline)
              .backgroundColor(this.palette.quoteBg)
              .onClick(() => {
                this.addDoc(s.name);
              })
            }, (s: MergeSource) => 'add_' + s.name)
            if (this.remaining().length === 0) {
              Text(L10n.t('所有文档都已选入。'))
                .fontSize(HwType.caption)
                .fontColor(this.palette.textTertiary)
            }
          }
          .width('100%')
        }

        this.switchRow('每篇加标题', '在每篇正文前插入该文档名的一级标题', this.withTitle,
          (v: boolean) => {
            this.withTitle = v;
          })
        this.switchRow('篇间分隔线', '每两篇之间插入一条分割线', this.withDivider,
          (v: boolean) => {
            this.withDivider = v;
          })
        Text(L10n.t('说明：各文档开头的 YAML Front Matter 不参与合并，会被剥掉。'))
          .fontSize(HwType.caption)
          .fontColor(this.palette.textTertiary)
          .width('100%')

        Divider().color(this.palette.divider)

        this.exportRow('导出 HTML', '自包含网页，图表只内联一份', (): void => {
          this.doHtml();
        })
        this.exportRow('打印', '合并结果送进系统打印预览', (): void => {
          this.doPrint();
        })
        this.exportRow('导出 MD', '合并后的 Markdown 原文', (): void => {
          this.doMd();
        })
        this.exportRow('导出 TXT', '剥掉语法后的纯文本', (): void => {
          this.doTxt();
        })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      if (this.busy) {
        Column({ space: HwSpace.sm }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(this.palette.accent)
          Text(L10n.t('正在处理，请稍候…'))
            .fontSize(HwType.caption)
            .fontColor(this.palette.textTertiary)
        }
        .padding({ left: HwSpace.xl, right: HwSpace.xl, top: HwSpace.lg, bottom: HwSpace.lg })
        .borderRadius(HwRadius.card)
        .backgroundColor(this.palette.surface)
      }
    }
    .width('100%')
  }
}
