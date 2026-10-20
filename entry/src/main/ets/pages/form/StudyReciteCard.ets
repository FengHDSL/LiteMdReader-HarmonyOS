import { L10n } from '../../service/L10n';

let storage = new LocalStorage();

@Entry(storage)
@Component
struct StudyReciteCard {
  @LocalStorageProp('studyHas') studyHas: string = '0';
  @LocalStorageProp('studyRemain') studyRemain: string = '0';
  @LocalStorageProp('studyFront') studyFront: string = '';

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row({ space: 6 }) {
          Image($r('app.media.foreground'))
            .width(16)
            .height(16)
          Text(L10n.t('学习卡 · 背诵'))
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FF1F2933')
          Blank()
          Text(L10n.t('剩 ') + this.studyRemain)
            .fontSize(10)
            .fontColor('#FF8A93A0')
        }
        .width('100%')
        Blank()
        if (this.studyHas === '1') {
          Text(this.studyFront)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FF1F2933')
            .textAlign(TextAlign.Center)
            .maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        } else {
          Text(L10n.t('今天没有待背的学习卡'))
            .fontSize(12)
            .fontColor('#FF8A93A0')
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        Blank()
        Row() {
          Blank()
          Text(L10n.t('下一个'))
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
      // **「具体」右边中间**（用户要求）：router 进应用看该卡的批注详情
      Text(L10n.t('具体'))
        .fontSize(11)
        .fontColor('#FF1565C0')
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .borderRadius(13)
        .border({ width: 1, color: '#FF1565C0' })
        .position({ right: 12, y: '46%' })
        .onClick(() => {
          postCardAction(this, {
            'action': 'router',
            'abilityName': 'EntryAbility',
            'params': { 'target': 'study' }
          });
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFFFF')
  }
}
