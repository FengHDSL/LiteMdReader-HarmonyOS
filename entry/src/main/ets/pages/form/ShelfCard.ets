/**
 * 澄笺 · 2×4 桌面书架卡片
 * ======================
 *
 * 展示最近阅读的 3 篇文档，**封面卡片式**（与书架同一套封面配色：
 * coverColorsOf 按文档名哈希取色，内置教程用主题章首配色）。
 *
 * 数据由 EntryFormAbility 用 formBindingData 推送，
 * 这里通过 LocalStorageProp 读取（ArkTS 卡片的标准数据通道）。
 * 布尔标志用字符串 '1'/'0' 传递（formBindingData 对布尔支持不稳）。
 *
 * 尺寸 2×4（横 4 竖 2）：三张迷你封面横排 + 名称。
 */
import { DocCover, coverColorsOf } from '../../components/DocCover';
import { HwRadius } from '../../theme/DesignTokens';

let storage = new LocalStorage();

@Entry(storage)
@Component
struct ShelfCard {
  @LocalStorageProp('recent1') recent1: string = '';
  @LocalStorageProp('recent2') recent2: string = '';
  @LocalStorageProp('recent3') recent3: string = '';
  @LocalStorageProp('percent1') percent1: string = '';
  @LocalStorageProp('percent2') percent2: string = '';
  @LocalStorageProp('percent3') percent3: string = '';
  @LocalStorageProp('has1') has1: string = '0';
  @LocalStorageProp('has2') has2: string = '0';
  @LocalStorageProp('has3') has3: string = '0';
  @LocalStorageProp('builtin1') builtin1: string = '0';
  @LocalStorageProp('builtin2') builtin2: string = '0';
  @LocalStorageProp('builtin3') builtin3: string = '0';

  build() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text('澄笺 · 最近阅读')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FF1F2933')
        Blank()
        Text('书架')
          .fontSize(10)
          .fontColor('#FF8A93A0')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        // 槽位 1：有记录显示封面，没有给引导
        if (this.has1 === '1') {
          this.coverSlot(this.recent1, this.percent1, this.builtin1 === '1')
        } else {
          this.emptySlot('还没有阅读记录')
        }
        if (this.has2 === '1') {
          this.coverSlot(this.recent2, this.percent2, this.builtin2 === '1')
        } else {
          this.emptySlot('去书架挑一篇')
        }
        if (this.has3 === '1') {
          this.coverSlot(this.recent3, this.percent3, this.builtin3 === '1')
        } else {
          this.emptySlot('读完即可展示')
        }
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .borderRadius(16)
    .linearGradient({
      angle: 180,
      colors: [['#FFFFFFFF', 0.0], ['#FFF2F4F7', 1.0]]
    })
  }

  /** 一个封面槽位：迷你书籍封面 + 名称 + 进度 */
  @Builder
  coverSlot(name: string, percent: string, builtin: boolean) {
    Column({ space: 4 }) {
      DocCover({
        title: name,
        builtin: builtin,
        coverTop: coverColorsOf(name, builtin).top,
        coverBottom: coverColorsOf(name, builtin).bottom,
        coverInk: coverColorsOf(name, builtin).ink,
        edgeColor: '#FFD8DDE3',
        coverBadge: '澄笺'
      })
      .width('100%')
      .layoutWeight(1)
      .borderRadius({ topLeft: 5, bottomLeft: 5, topRight: 13, bottomRight: 13 })
      .clip(true)

      Text(name)
        .fontSize(11)
        .fontColor('#FF1F2933')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Text(percent.length > 0 ? percent : '刚开始读')
        .fontSize(9)
        .fontColor('#FF8A93A0')
        .maxLines(1)
        .width('100%')
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 空槽：虚线感的引导位 */
  @Builder
  emptySlot(hint: string) {
    Column({ space: 4 }) {
      Column() {
        Text('+')
          .fontSize(20)
          .fontColor('#FFB8BFC7')
      }
      .width('100%')
      .layoutWeight(1)
      .borderRadius({ topLeft: 5, bottomLeft: 5, topRight: 13, bottomRight: 13 })
      .border({ width: 1, color: '#FFD8DDE3' })
      .justifyContent(FlexAlign.Center)

      Text(hint)
        .fontSize(10)
        .fontColor('#FFA6ADB5')
        .maxLines(1)
        .width('100%')
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
