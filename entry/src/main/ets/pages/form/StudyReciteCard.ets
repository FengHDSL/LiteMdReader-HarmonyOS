import { L10n } from '../../service/L10n';

let storage = new LocalStorage();

@Entry(storage)
@Component
struct StudyReciteCard {
  @LocalStorageProp('studyHas') studyHas: string = '0';
  @LocalStorageProp('studyRemain') studyRemain: string = '0';
  @LocalStorageProp('studyFront') studyFront: string = '';
  @LocalStorageProp('studyBack') studyBack: string = '';
  /** **「具体」切换**：true = 显示该卡的批注内容（back），false = 显示题面 */
  @State showBack: boolean = false;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row({ space: 6 }) {
          Image($r('app.media.foreground'))
            .width(22)
            .height(22)
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
          if (this.showBack) {
            // **「具体」态**：显示这张卡的批注内容（用户要求）
            Text(this.studyBack)
              .fontSize(14)
              .fontColor('#FF5B6470')
              .textAlign(TextAlign.Center)
              .maxLines(8)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.FastOutSlowIn }))
          } else {
            Text(this.studyFront)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FF1F2933')
              .textAlign(TextAlign.Center)
              .maxLines(6)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.FastOutSlowIn }))
          }
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
      Text(this.showBack ? L10n.t('返回') : L10n.t('具体'))
        .fontSize(11)
        .fontColor('#FF1565C0')
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .borderRadius(13)
        .border({ width: 1, color: '#FF1565C0' })
        // ⚠️ position 没有 right 键——之前写 right 被忽略，按钮跑到左边（用户截图实锤）。
        // 改用 x='100%'（贴右缘）+ markAnchor 反向偏移按钮自身宽度
        .position({ x: '100%', y: '46%' })
        // markAnchor 在部分形态上表现不一致（用户实测按钮仍在左）——
        // 改用 translate 显式左移按钮宽 + 边距（62 + 14 = 76）
        .translate({ x: -76, y: 0 })
        .onClick(() => {
          // **「具体」→ 展示这张卡的批注内容**（卡片内切换，不再跳应用）
          this.showBack = !this.showBack;
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFFFF')
  }
}
