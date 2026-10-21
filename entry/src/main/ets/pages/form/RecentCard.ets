import { L10n } from '../../service/L10n';
/**
 * 澄笺 · 2×2 桌面卡片（最近阅读 + 新建文档）
 * ==========================================
 *
 * 上半部分展示**最近阅读的一篇文档**（名称 + 进度，点击进阅读页），
 * 下方一枚**蓝色「新建文档」胶囊按钮**（点击进编辑器新建）。
 *
 * 数据由 EntryFormAbility 用 formBindingData 推送（FormSync.buildData 统一组装），
 * 这里通过 LocalStorageProp 读取（ArkTS 卡片的标准数据通道）；
 * 布尔标志用字符串 '1'/'0' 传递（formBindingData 对布尔支持不稳）。
 *
 * 跳转用 postCardAction router：EntryAbility 解析 params.target 写 AppStorage 信号，
 * 书架页（Index.onPageShow）消费信号完成实际路由（openDoc / 新建进编辑器）。
 */

let storage = new LocalStorage();

@Entry(storage)
@Component
struct RecentCard {
  /** 最近阅读的文档名（无记录时是占位文案，配合 hasRecent 区分） */
  @LocalStorageProp('recentName') recentName: string = '暂无阅读记录';
  /** 进度文案（「已读 45%」/「刚开始读」/「去书架挑一篇吧」） */
  @LocalStorageProp('recentPercent') recentPercent: string = '';
  /** 是否有阅读记录（'1'/'0'） */
  @LocalStorageProp('hasRecent') hasRecent: string = '0';
  /** 点击卡片要打开的文档名（原始名，传回应用做查找键） */
  @LocalStorageProp('docName') docName: string = '';
  /**
   * **界面字体**（外观设置 → 界面字体）。卡片跑在 FormExtension 独立进程，
   * 读不到主应用的 AppStorage，只能由 FormSync 随 bindingData 推过来；
   * 值已经是解析好的 fontFamily 串（空 = 系统默认），卡片直接给 .fontFamily()。
   */
  @LocalStorageProp('cardFont') cardFont: string = '';

  build() {
    Column() {
      // 标题行
      Row() {
        Text(L10n.t('澄笺'))
          .fontFamily(this.cardFont)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FF1F2933')
        Blank()
        Text(L10n.t('最近阅读'))
          .fontFamily(this.cardFont)
          .fontSize(10)
          .fontColor('#FF8A93A0')
        // 刷新按钮：数据偶尔没刷出来时点一下，message 动作 → EntryFormAbility.onFormEvent
        // → 立即重推一份数据自愈
        Row() {
          Image($r('app.media.arrow_2_circlepath'))
            .width(11)
            .height(11)
            .fillColor('#FF8A93A0')
        }
        .width(20)
        .height(20)
        .borderRadius(10)
        .backgroundColor('#FFEDF0F3')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .margin({ left: 5 })
        .onClick(() => {
          postCardAction(this, {
            'action': 'message',
            'params': { 'target': 'refresh' }
          });
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 最近阅读文档区（点击进阅读页）
      Column({ space: 3 }) {
        Text(this.hasRecent === '1' ? this.recentName : L10n.t('还没有阅读记录'))
          .fontFamily(this.cardFont)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.hasRecent === '1' ? '#FF1F2933' : '#FFA6ADB5')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(20)
          .width('100%')
        Text(this.hasRecent === '1'
          ? (this.recentPercent.length > 0 ? this.recentPercent : L10n.t('刚开始读'))
          : L10n.t('去书架挑一篇吧'))
          .fontFamily(this.cardFont)
          .fontSize(10)
          .fontColor('#FF8A93A0')
          .maxLines(1)
          .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        if (this.hasRecent !== '1' || this.docName.length === 0) {
          // 没有记录：进书架挑一篇
          postCardAction(this, {
            'action': 'router',
            'abilityName': 'EntryAbility',
            'params': { 'target': 'shelf' }
          });
          return;
        }
        postCardAction(this, {
          'action': 'router',
          'abilityName': 'EntryAbility',
          'params': { 'target': 'doc', 'name': this.docName }
        });
      })

      // 新建文档按钮（蓝色胶囊，用户指定）
      Row({ space: 4 }) {
        Text('+')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFFFF')
        Text(L10n.t('新建文档'))
          .fontFamily(this.cardFont)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFFFF')
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .height(34)
      .borderRadius(17)
      .backgroundColor('#FF1565C0')
      .onClick(() => {
        postCardAction(this, {
          'action': 'router',
          'abilityName': 'EntryAbility',
          'params': { 'target': 'newdoc' }
        });
      })
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
}
