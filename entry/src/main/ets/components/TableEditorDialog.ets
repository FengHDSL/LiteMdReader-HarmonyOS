/**
 * 澄笺 · 表格编辑弹窗（TableEditorDialog）
 * ==========================================
 *
 * 点击阅读页里的表格打开：结构化编辑（网格单元格 + 行列增删 + 对齐），
 * 保存时由宿主把 `MdTable` 经 `TableTool.toLines()` 写回原文对应行段。
 *
 * 实现要点（工程踩过的坑，逐条对齐）：
 *  · **@Link 而不是 @Prop 快照**：CustomDialogController 的 builder 参数只在
 *    创建时绑定一次，传普通值弹窗永远显示旧表；@Link 指向宿主 @State 同一引用，
 *    宿主点表格时覆盖内容、弹窗立即看到新表；
 *  · **TextInput 的 ForEach key 不能含单元格内容**：key 随输入变化 = 每敲一个字
 *    重建一次 = 焦点丢失。key 只含 epoch（行列增删 / 对齐切换时才 ++），
 *    onChange 直接写 `this.tbl` 嵌套值（V1 不触发刷新，正好保住焦点）；
 *  · **可变长内容必须限高 + 内部滚动**（更新弹窗踩过：内容顶爆屏幕、按钮看不见），
 *    网格区 constraintSize maxHeight = 屏高 50%，按钮永远固定在底部；
 *  · **@Builder 不传回调**（ArkTS 不稳）：按钮全部内联画，不走 @Builder 参数。
 */
import { common } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import {
  LIGHT_PALETTE, ReaderPalette, ReaderThemeMode, paletteFor, withAlpha
} from '../theme/DesignTokens';
import { HwSpace, HwRadius } from '../theme/DesignTokens';
import { MdTable, TableTool } from '../service/TableTool';
import { L10n } from '../service/L10n';

/** 单元格列宽（vp）：够放下常用短语，网格横向滚动看更多列 */
const CELL_W: number = 132;
const CELL_H: number = 38;

@CustomDialog
export struct TableEditorDialog {
  controller?: CustomDialogController;
  /** 编辑中的表格（宿主 @State，同一引用；增删行列用 epoch 强刷网格） */
  @Link tbl: MdTable;
  /** 保存（宿主负责写回原文并重载） */
  onSave: () => void = () => {
  };
  @StorageProp('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  /** 调色板：**必须 @Prop**，否则主题切换后不更新（普通成员只在创建时赋值一次） */
  @Prop palette: ReaderPalette = LIGHT_PALETTE;
  /** 网格重建纪元：增删行列 / 换对齐后 ++，ForEach key 带上它强制重建 */
  @State epoch: number = 0;
  /** 当前选中列（点表头选中；-1 = 未选中）。对齐 / 删列操作作用于它 */
  @State selCol: number = -1;
  /** 当前软键盘高度（px，0 = 未弹起）：键盘弹起时压缩网格限高，保证最后一行滚得到 */
  @State kbPx: number = 0;
  private kbWin: window.Window | null = null;
  private kbCallback: (h: number) => void = (h: number): void => {
    this.kbPx = h;
  };

  aboutToAppear(): void {
    // **键盘高度监听**：键盘弹起会遮住弹窗下半部（网格底部的行滚不上去），
    // 这里实时把网格限高压到"可视高度 − 弹窗其余部分"以内（见 gridMaxNow）。
    try {
      const c = this.getUIContext().getHostContext();
      if (c !== undefined && c !== null) {
        window.getLastWindow(c as common.UIAbilityContext).then((win: window.Window) => {
          this.kbWin = win;
          win.on('keyboardHeightChange', this.kbCallback);
        });
      }
    } catch (err) {
      // 拿不到窗口就维持静态限高（降级）
    }
  }

  aboutToDisappear(): void {
    if (this.kbWin !== null) {
      try {
        this.kbWin.off('keyboardHeightChange', this.kbCallback);
      } catch (err) {
        // 忽略
      }
      this.kbWin = null;
    }
  }

  /**
   * 网格区限高（vp）：静态 = 屏高 50%；键盘弹起后改取
   * 「（屏高 − 键盘高）− 弹窗其余部分（标题/说明/工具行/按钮/内边距）」，
   * 下限 140 保证仍可滚动。
   */
  private gridMaxNow(): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const screenVp: number = this.getUIContext().px2vp(d.height);
      const base: number = screenVp * 0.5;
      if (this.kbPx <= 0) {
        return Math.max(160, Math.round(base));
      }
      const visibleVp: number = this.getUIContext().px2vp(d.height - this.kbPx);
      const avail: number = visibleVp - 250;
      return Math.max(140, Math.round(Math.min(base, avail)));
    } catch (err) {
      return 240;
    }
  }

  /** 实际取色：显式读两键落局部常量（paletteFor 纯函数不登记依赖）。 */
  private pal(): ReaderPalette {
    const mode: number = this.themeMode;
    const dark: boolean = this.systemDark;
    return paletteFor(mode, dark);
  }

  /** 卡片底：surface 顶满 alpha 才是"实底卡片"。 */
  private cardBg(): string {
    return withAlpha(this.pal().surface, 'FF');
  }

  private bump(): void {
    this.epoch = this.epoch + 1;
  }

  /** 复制整张表：**同步**写剪贴板（与正文复制同一口径——异步 setData 的 promise 在
   *  部分设备上与真实写入不同步，会出现"提示已复制、粘出来没内容"）。 */
  private copyTable(text: string, hint: string): void {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.getUIContext().getPromptAction().showToast({ message: hint });
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      const msg: string = (e.message !== undefined && e.message !== null) ? e.message : L10n.t('未知错误');
      this.getUIContext().getPromptAction().showToast({ message: L10n.t('复制失败：') + msg });
    }
  }

  /**
   * 按格式取整张表的文本。**必须在点击那一刻才算**：单元格是直接改在 @Link 对象上的，
   * 不触发重建，构建期算好的字符串会停在旧内容。
   */
  private tableTextFor(kind: string): string {
    if (kind === 'md') {
      return TableTool.toLines(this.tbl).join(String.fromCharCode(10));
    }
    if (kind === 'tsv') {
      return TableTool.toDelimited(this.tbl, String.fromCharCode(9));
    }
    return TableTool.toDelimited(this.tbl, ',');
  }

  /** 复制胶囊（Markdown / CSV / TSV） */
  @Builder
  copyChip(label: string, kind: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.pal().textSecondary)
      .textAlign(TextAlign.Center)
      .padding({ left: 10, right: 10, top: 7, bottom: 7 })
      .borderRadius(10)
      .border({ width: 1, color: this.pal().divider })
      .onClick(() => {
        this.copyTable(this.tableTextFor(kind), L10n.t('表格已复制，可直接粘贴'));
      })
  }

  build() {
    Column({ space: HwSpace.sm }) {
      // ── 标题 + 行列数 ──
      Row({ space: HwSpace.sm }) {
        Text(L10n.t('编辑表格'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().textPrimary)
          .layoutWeight(1)
        Text((this.tbl.rows.length + 1) + ' 行 × ' + this.tbl.header.length + ' 列')
          .fontSize(12)
          .fontColor(this.pal().textTertiary)
      }
      .width('100%')

      // 使用说明
      Text(L10n.t('「＋ 行 / ＋ 列」在末尾追加；行尾 × 删除该行。表头与对齐样式保持原文不动。'))
        .fontSize(12)
        .fontColor(this.pal().textTertiary)
        .width('100%')

      // ── 工具行：加行 / 加列（用户要求：去掉左/中/右与删列，精简到只管结构）──
      Scroll() {
        Row({ space: HwSpace.xs }) {
          this.toolChip('＋ 行', 'addRow', false)
          this.toolChip('＋ 列', 'addCol', false)
        }
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      // ── 网格：列号行 + 表头 + 数据行 ──
      // **双向滚动 = 垂直 Scroll（外）+ 水平 Scroll（内）嵌套**：单层 Scroll 只能
      // 一个方向（用户实测：行数超 10 行后下面的内容看不到也滑不动）。
      // 方向正交不抢手势：横滑给内层、竖滑给外层。限高防顶爆弹窗，按钮固定底部。
      // 滚动条一律关闭（用户反馈"右边的滑动条太碍事"，更新日志弹窗同批处理）。
      Scroll() {
        Scroll() {
          Column({ space: 4 }) {
            // 列号行：让用户确认这是第几列（与下方 TextInput 同宽对齐）
            Row({ space: 4 }) {
              Column().width(30).height(22)
              ForEach(this.tbl.header, (cell: string, ci: number) => {
                Text(L10n.t('第') + (ci + 1) + '列')
                  .width(CELL_W)
                  .height(22)
                  .fontSize(11)
                  .fontColor(this.pal().textTertiary)
                  .textAlign(TextAlign.Center)
              }, (cell: string, ci: number) => 'cn' + this.epoch + '_' + ci)
              Column().width(26).height(22)
            }
            .alignItems(VerticalAlign.Center)

            // 表头行：点格选中列（**用 onFocus 而不是 onClick**——TextInput 会吞掉
            // 点击事件，onClick 不触发 → 选中列永远 -1、对齐/删列按钮一直灰，用户实测），
            // 聚焦即选中，两者不冲突
            Row({ space: 4 }) {
              Text(L10n.t('头'))
                .width(30)
                .height(CELL_H)
                .fontSize(11)
                .fontColor(this.pal().textTertiary)
                .textAlign(TextAlign.Center)
              ForEach(this.tbl.header, (cell: string, ci: number) => {
                TextInput({ text: cell })
                  .width(CELL_W)
                  .height(CELL_H)
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.pal().textPrimary)
                  .backgroundColor(this.selCol === ci ? this.pal().accentSoft : this.pal().quoteBg)
                  .borderRadius(HwRadius.inline)
                  .onChange((v: string) => {
                    this.tbl.header[ci] = v;
                  })
                  .onFocus(() => {
                    this.selCol = ci;
                  })
              }, (cell: string, ci: number) => 'h' + this.epoch + '_' + ci)

              Column()
                .width(26)
                .height(CELL_H)
            }
            .alignItems(VerticalAlign.Center)

            // 数据行：左侧行号 + 行尾「×」删该行
            ForEach(this.tbl.rows, (row: string[], ri: number) => {
              Row({ space: 4 }) {
                Text('' + (ri + 1))
                  .width(30)
                  .height(CELL_H)
                  .fontSize(11)
                  .fontColor(this.pal().textTertiary)
                  .textAlign(TextAlign.Center)
                ForEach(row, (cell: string, ci: number) => {
                  TextInput({ text: cell })
                    .width(CELL_W)
                    .height(CELL_H)
                    .fontSize(13)
                    .fontColor(this.pal().textPrimary)
                    .backgroundColor(this.selCol === ci ? this.pal().accentSoft : this.pal().quoteBg)
                    .borderRadius(HwRadius.inline)
                    .onChange((v: string) => {
                      this.tbl.rows[ri][ci] = v;
                    })
                    // **任意格子聚焦即选中该列**（用户要求）：数据格也纳入，
                    // 左/中/右与删列跟着这一列走
                    .onFocus(() => {
                      this.selCol = ci;
                    })
                }, (cell: string, ci: number) => 'c' + this.epoch + '_' + ri + '_' + ci)

                Text('×')
                  .fontSize(15)
                  .fontColor(this.pal().textTertiary)
                  .width(26)
                  .height(CELL_H)
                  .textAlign(TextAlign.Center)
                  .borderRadius(HwRadius.inline)
                  .backgroundColor(this.pal().quoteBg)
                  .onClick(() => {
                    TableTool.removeRow(this.tbl, ri);
                    this.bump();
                  })
              }
              .alignItems(VerticalAlign.Center)
            }, (row: string[], ri: number) => 'r' + this.epoch + '_' + ri)
          }
          .alignItems(HorizontalAlign.Start)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .constraintSize({ maxHeight: this.gridMaxNow() })
      .align(Alignment.Top)
      .width('100%')

      // ── 复制整张表（用户要求：长按表格弹菜单在真机上不生效，复制入口搬进弹窗）──
      Row({ space: HwSpace.xs }) {
        this.copyChip(L10n.t('复制为 Markdown'), 'md')
        this.copyChip(L10n.t('复制为 CSV'), 'csv')
        this.copyChip(L10n.t('复制为 TSV'), 'tsv')
      }
      .width('100%')

      // ── 底部：取消 | 保存 ──
      Row({ space: HwSpace.sm }) {
        Text(L10n.t('取消'))
          .fontSize(14)
          .fontColor('#FFD32F2F')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .border({ width: 1, color: '#FFD32F2F' })
          .onClick(() => {
            this.controller?.close();
          })
        Text(L10n.t('保存表格'))
          .fontSize(14)
          .fontColor('#FFFFFFFF')
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .backgroundColor(this.pal().accent)
          .onClick(() => {
            this.onSave();
          })
      }
      .width('100%')
    }
    .padding(HwSpace.lg)
    .borderRadius(16)
    .backgroundColor(this.cardBg())
    .width('92%')
  }

  /** 工具行小 chip：只收**值参数**（label / 命令名），动作统一走 runToolCmd 分派
   *  （@Builder 不传回调的工程约定）。disabled = 置灰不可点。 */
  @Builder
  toolChip(label: string, cmd: string, disabled: boolean) {
    Text(label)
      .fontSize(12)
      .fontColor(disabled ? this.pal().textTertiary : this.pal().accent)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .borderRadius(HwRadius.inline)
      .border({ width: 1, color: disabled ? this.pal().divider : this.pal().accent })
      .opacity(disabled ? 0.6 : 1)
      .onClick(() => {
        if (!disabled) {
          this.runToolCmd(cmd);
        }
      })
  }

  /** 工具命令分派（增行 / 增列）。 */
  private runToolCmd(cmd: string): void {
    if (cmd === 'addRow') {
      TableTool.addRow(this.tbl, -1);
      this.bump();
      return;
    }
    if (cmd === 'addCol') {
      TableTool.addCol(this.tbl, -1);
      this.bump();
    }
  }
}
