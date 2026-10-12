/**
 * **协同阅读扩展页**（UIExtensionAbility 的界面）：极简只读阅读器——
 * 从 AppStorage 读取流转 / 接续链路写入的当前文档（continueDocName /
 * continueDocContent），纯文本逐行渲染，支持字号缩放与滚动。
 * 独立 UI 实例，不复用主页面组件（Extension 进程隔离）。
 */
import { DocStore } from '../service/DocStore';
import { L10n } from '../service/L10n';

@Entry
@Component
struct ReaderExtPage {
  @StorageLink('continueDocName') docName: string = '澄笺 · 协同阅读';
  @StorageLink('continueDocContent') docContent: string = '';
  @State fontSize: number = 18;
  /** 语言切换计数：变更时整页重建（key 拼接），文案随词典刷新 */
  @StorageProp('languageTick') languageTick: number = 0;
  private scroller: Scroller = new Scroller();

  /** 正文行：按换行切分（扩展页只做纯文本阅读，不引 Markdown 管线）。 */
  private lines(): string[] {
    if (this.docContent.length === 0) {
      return [];
    }
    return this.docContent.split('\n');
  }

  build() {
    Column() {
      // 顶栏：文档名 + 字号控制
      Row({ space: 8 }) {
        Text(this.docName)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#E6222226')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('A-')
          .fontSize(13)
          .fontColor('#666666')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(8)
          .backgroundColor('#14000000')
    .key('rext_l' + this.languageTick)
          .onClick(() => {
            this.fontSize = Math.max(12, this.fontSize - 2);
          })
        Text('A+')
          .fontSize(13)
          .fontColor('#666666')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(8)
          .backgroundColor('#14000000')
          .onClick(() => {
            this.fontSize = Math.min(28, this.fontSize + 2);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      Divider().color('#14000000').strokeWidth(1)

      // 正文：纸面底色 + 逐行纯文本
      Scroll(this.scroller) {
        Column({ space: 6 }) {
          if (this.lines().length === 0) {
            Text(L10n.t('暂无接续内容。请先在手机端打开一篇文档，再通过多设备流转迁移到本端。'))
              .fontSize(14)
              .fontColor('#99666666')
              .padding(16)
          } else {
            ForEach(this.lines(), (line: string, index: number) => {
              Text(line.length === 0 ? ' ' : line)
                .fontSize(this.fontSize)
                .fontColor('#D9222226')
                .width('100%')
            }, (line: string, index: number) => 'ext_' + index)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 18, right: 18, top: 12, bottom: 40 })
      }
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#FAF7F1')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FAF7F1')
  }
}
