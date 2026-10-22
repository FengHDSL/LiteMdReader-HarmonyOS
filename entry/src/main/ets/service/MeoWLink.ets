import { common } from '@kit.AbilityKit';

/**
 * 澄笺 · MeoW 跳转（MeoWLink）
 * ==========================
 *
 * 「探索中心 → MeoW订阅」与「意见反馈 → MeoW 反馈」两处共用这一份实现。
 *
 * 关键事实（2026-10-22 抓 `meow.chuckfang.com` 的页面脚本得到）：
 * 订阅页里「立即订阅」按钮的 href 是脚本写进去的
 *   `https://www.chuckfang.com/MeoW/appLinking?channelId=<id>`
 * 也就是 MeoW 的 **App Linking 深链**。按官方口径 openLink 它就等于"点了那个按钮"，
 * 而且会带上 channelId（只按包名 startAbility 的话子应用不知道要订哪个频道）。
 *
 * 降级链：① App Linking 深链 → ② 按包名拉起 → ③ 打开落地页（人可手点）→ ④ 交给浏览器 → ⑤ onFail。
 */
const MEOW_BUNDLE: string = 'com.chuckfang.meow';
const MEOW_PAGE: string = 'https://meow.chuckfang.com/?channelId=951fa7696734428c9ee367f5c07e4273';
const MEOW_APPLINK: string =
  'https://www.chuckfang.com/MeoW/appLinking?channelId=951fa7696734428c9ee367f5c07e4273';

export class MeoWLink {
  /** 打开 MeoW（尽力而为，全失败时回调 onFail，由调用方决定提示文案） */
  static open(ctx: common.UIAbilityContext, onFail: () => void): void {
    // ① 官方 App Linking：装了 MeoW 由系统直接拉起并带 channelId
    try {
      ctx.openLink(MEOW_APPLINK, { appLinkingOnly: true }).catch(() => {
        MeoWLink.byBundle(ctx, onFail);
      });
      return;
    } catch (err) {
      // 低版本没有 OpenLinkOptions / 调用直接抛：继续往下降级
    }
    MeoWLink.byBundle(ctx, onFail);
  }

  /** ② 深链没走通：按包名显式拉起（部分机型对 App Linking 校验更严，这条兜住） */
  private static byBundle(ctx: common.UIAbilityContext, onFail: () => void): void {
    try {
      ctx.startAbility({ bundleName: MEOW_BUNDLE }).catch(() => {
        MeoWLink.byPage(ctx, onFail);
      });
    } catch (err) {
      MeoWLink.byPage(ctx, onFail);
    }
  }

  /** ③ 没装 MeoW：打开给人看的落地页（页面上可点「立即订阅」） */
  private static byPage(ctx: common.UIAbilityContext, onFail: () => void): void {
    try {
      ctx.openLink(MEOW_PAGE).catch(() => {
        MeoWLink.byBrowser(ctx, onFail);
      });
    } catch (err) {
      MeoWLink.byBrowser(ctx, onFail);
    }
  }

  /** ④ 最后兜底：隐式 viewData 交给系统浏览器 */
  private static byBrowser(ctx: common.UIAbilityContext, onFail: () => void): void {
    try {
      ctx.startAbility({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: MEOW_PAGE
      }).catch(() => {
        onFail();
      });
    } catch (err) {
      onFail();
    }
  }
}
