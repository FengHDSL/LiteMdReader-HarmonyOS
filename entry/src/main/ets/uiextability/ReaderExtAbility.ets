import { EmbeddedUIExtensionAbility, UIExtensionContentSession, Want } from '@kit.AbilityKit';

const TAG: string = 'ReaderExtAbility';

/**
 * **澄笺 · 协同阅读扩展**（用户指令：强行接入 UI 扩展组件）：
 * 以 **embeddedUI** 类型注册（三方可注册的 UI 扩展类型；`uiExtension` 不在
 * module.json5 schema 允许的枚举里，编译期即被拒——已实测确认）。
 * 加载 pages/ReaderExtPage——从 AppStorage 读取流转 / 接续链路写入的
 * 当前文档，纯文本逐行渲染。
 *
 * ⚠️ 预期管理：本组件提供的是**可被嵌入 / 拉起的标准入口**（宿主用
 * EmbeddedComponent 指定本 ability 即可嵌入）；协同窗口是否提供全屏
 * 放大按钮仍由系统决定。
 */
export default class ReaderExtAbility extends EmbeddedUIExtensionAbility {
  onCreate(): void {
    console.info(TAG, 'onCreate');
  }

  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    console.info(TAG, 'onSessionCreate');
    session.loadContent('pages/ReaderExtPage');
  }

  onSessionDestroy(session: UIExtensionContentSession): void {
    console.info(TAG, 'onSessionDestroy');
  }

  onForeground(): void {
    console.info(TAG, 'onForeground');
  }

  onBackground(): void {
    console.info(TAG, 'onBackground');
  }

  onDestroy(): void {
    console.info(TAG, 'onDestroy');
  }
}
