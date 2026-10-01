/**
 * 澄笺 · 桌面卡片能力（FormExtensionAbility）
 * =========================================
 *
 * 2×4 书架卡片：展示**最近阅读的 3 篇文档**。
 *
 * 数据流：卡片添加 / 定时刷新时，这里用 FormSync.buildData 组装最近阅读数据
 * 推给卡片页（pages/form/ShelfCard.ets 通过 LocalStorageProp 读取）。
 * **即时更新走应用进程侧的 FormSync.pushRecents**（Reader 进度落盘 /
 * 应用退后台时主动 formProvider.updateForm），这里只是定时兜底。
 *
 * 卡片添加时把 formId（want 参数 FormParam.IDENTITY_KEY）登记进
 * `<filesDir>/form_ids.json`，移除时去登记——应用进程侧推送靠这份存档。
 *
 * 注意：FormExtensionContext 没有 filesDir，而 DocStore 只用 filesDir，
 * 所以这里把 **ApplicationContext**（有 filesDir）传给 DocStore。
 */
import { FormExtensionAbility, formBindingData, formProvider, formInfo } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { FormSync } from '../service/FormSync';

const TAG: string = 'ShelfForm';

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    this.rememberFromWant(want);
    return FormSync.buildData(this.appCtx());
  }

  onUpdateForm(formId: string): void {
    try {
      // 顺带登记：修复前就添加到桌面的卡片，第一次定时刷新即入库自愈
      FormSync.rememberFormId(this.appCtx(), formId);
      formProvider.updateForm(formId, FormSync.buildData(this.appCtx()));
    } catch (err) {
      hilog.warn(0x0000, TAG, 'updateForm failed: %{public}s', (err as Error).message);
    }
  }

  onRemoveForm(formId: string): void {
    FormSync.forgetFormId(this.appCtx(), formId);
  }

  /** 从 want 里取卡片 ID 登记（FormParam.IDENTITY_KEY，值是字符串）。 */
  private rememberFromWant(want: Want): void {
    try {
      const params: Record<string, Object> | undefined = want.parameters;
      if (params === undefined) {
        return;
      }
      const raw: Object | undefined = params[formInfo.FormParam.IDENTITY_KEY];
      if (raw === undefined || raw === null) {
        return;
      }
      const id: string = raw as string;
      FormSync.rememberFormId(this.appCtx(), id);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'rememberFromWant failed: %{public}s', (err as Error).message);
    }
  }

  /**
   * FormExtensionContext 与 UIAbilityContext 不是一族，直接 cast 会被编译器拒绝；
   * DocStore 只用 filesDir（ApplicationContext 上有），双重转换是标准绕法。
   */
  private appCtx(): common.UIAbilityContext {
    return this.context.getApplicationContext() as object as common.UIAbilityContext;
  }
}
