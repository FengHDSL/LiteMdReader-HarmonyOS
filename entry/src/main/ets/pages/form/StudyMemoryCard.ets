import { L10n } from '../../service/L10n';

let storage = new LocalStorage();

@Entry(storage)
@Component
struct StudyMemoryCard {
  @LocalStorageProp('studyHas') studyHas: string = '0';
  @LocalStorageProp('studyRemain') studyRemain: string = '0';
  @LocalStorageProp('studyFront') studyFront: string = '';

  @LocalStorageProp('studyBack') studyBack: string = '';
  /** 界面字体（外观设置）：由 FormSync 随 bindingData 推来（卡片进程读不到 AppStorage） */
  @LocalStorageProp('cardFont') cardFont: string = '';
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row({ space: 6 }) {
          Image($r('app.media.foreground'))
            .width(16)
            .height(16)
          Text(L10n.t('学习卡 · 记忆'))
            .fontFamily(this.cardFont)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FF1F2933')
          Blank()
          Text(L10n.t('剩 ') + this.studyRemain)
            .fontFamily(this.cardFont)
            .fontSize(10)
            .fontColor('#FF8A93A0')
        }
        .width('100%')
        Blank()
        if (this.studyHas === '1') {
          Text(this.studyFront)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FF1F2933')
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Divider()
            .strokeWidth(1)
            .color('#FFE5E9EE')
            .margin({ top: 6, bottom: 6 })
          Text(this.studyBack)
            .fontSize(12)
            .fontColor('#FF5B6470')
            .maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        } else {
          Text(L10n.t('今天没有待背的学习卡'))
            .fontFamily(this.cardFont)
            .fontSize(12)
            .fontColor('#FF8A93A0')
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        Blank()
        Row() {
          Blank()
          Text(L10n.t('下一个'))
            .fontFamily(this.cardFont)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFFFF')
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .borderRadius(16)
            .backgroundColor('#FF1565C0')
            .onClick(() => {
              postCardAction(this, { 'action': 'message', params: { 'next': '1' } });
            })
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .padding(14)

    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFFFF')
  }
}
