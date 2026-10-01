/**
 * LiteMdReader · 外观设置
 * ========================
 *
 * 移植自参考工程（HarmonyOS 原生应用）的外观体系：**材质类型 / 材质等级 / 主题 / 主题色**。
 *
 * 关于「两套材质引擎」：
 * 参考工程走的是华为官方 HDS 组件族——`@kit.UIDesignKit` 的 `HdsNavigation` / `HdsTabs`
 * 通过 `systemMaterialEffect: { materialType, materialLevel }` 让系统亲自画材质。
 * 这条路画出来的是真·系统材质，但只能在支持 HDS 的设备上生效。
 *
 * 本工程同时保留自绘承载层（Toggle + `uiMaterial.ImmersiveStyle`），所以在设置里给了选择：
 *   · 自绘云母：兼容性最好，任何装了 API 26 的设备都能出效果
 *   · 官方 HDS：走系统材质，观感最好，但依赖 HDS 能力
 *
 * 材质「类型 / 等级」两项在两套引擎下都生效：
 *   · 自绘引擎把它们映射到 `ImmersiveStyle`（ULTRA_THIN / THIN / REGULAR / THICK）
 *   · HDS 引擎直接原样传给 `systemMaterialEffect`
 */

import { hdsMaterial } from '@kit.UIDesignKit';

/** 材质引擎 */
export enum MaterialEngine {
  /** 自绘云母承载层（默认，兼容性最好） */
  Custom = 0,
  /** 官方 HDS 系统材质 */
  Hds = 1
}

/** 材质类型索引 → 文案。与服务端/参考工程保持同一套口径。 */
export const MATERIAL_TYPE_LABELS: string[] = ['沉浸', '自适应', '无材质'];
/** 材质等级索引 → 文案 */
export const MATERIAL_LEVEL_LABELS: string[] = ['精致', '温和', '平滑'];
/** 材质引擎索引 → 文案 */
export const MATERIAL_ENGINE_LABELS: string[] = ['自绘云母', '官方 HDS'];

export function materialTypeLabel(index: number): string {
  return index >= 0 && index < MATERIAL_TYPE_LABELS.length ? MATERIAL_TYPE_LABELS[index] : '自适应';
}

export function materialLevelLabel(index: number): string {
  return index >= 0 && index < MATERIAL_LEVEL_LABELS.length ? MATERIAL_LEVEL_LABELS[index] : '温和';
}

export function materialEngineLabel(index: number): string {
  return index === MaterialEngine.Hds ? MATERIAL_ENGINE_LABELS[1] : MATERIAL_ENGINE_LABELS[0];
}

/** 材质类型索引 → HDS 枚举。 */
export function toHdsMaterialType(index: number): hdsMaterial.MaterialType {
  if (index === 0) {
    return hdsMaterial.MaterialType.IMMERSIVE;
  }
  if (index === 2) {
    return hdsMaterial.MaterialType.NONE;
  }
  return hdsMaterial.MaterialType.ADAPTIVE;
}

/** 材质等级索引 → HDS 枚举。 */
export function toHdsMaterialLevel(index: number): hdsMaterial.MaterialLevel {
  if (index === 0) {
    return hdsMaterial.MaterialLevel.EXQUISITE;
  }
  if (index === 2) {
    return hdsMaterial.MaterialLevel.SMOOTH;
  }
  return hdsMaterial.MaterialLevel.GENTLE;
}

/**
 * 材质等级索引 → 自绘引擎的沉浸档位。
 * 等级越高越「实」：精致 = THICK，温和 = REGULAR，平滑 = THIN。
 */
export function toImmersiveStyleLevel(index: number): number {
  if (index === 0) {
    return 3;
  }
  if (index === 2) {
    return 1;
  }
  return 2;
}

/**
 * 本机支持哪些 HDS 材质类型。
 * 官方没有「是否支持 HDS」的布尔接口，只能列举支持的类型：
 * 返回空数组即表示本机没有 HDS 材质能力。
 */
export function supportedMaterialTypesText(): string {
  try {
    const list: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
    if (list === undefined || list === null || list.length === 0) {
      return '本机没有 HDS 材质能力，请使用自绘云母';
    }
    let text: string = '本机 HDS 支持：';
    for (let k = 0; k < list.length; k++) {
      const t: hdsMaterial.MaterialType = list[k];
      if (t === hdsMaterial.MaterialType.IMMERSIVE) {
        text = text + '沉浸 ';
      } else if (t === hdsMaterial.MaterialType.ADAPTIVE) {
        text = text + '自适应 ';
      } else {
        text = text + '无材质 ';
      }
    }
    return text.trim();
  } catch (err) {
    return 'HDS 材质接口不可用，请使用自绘云母';
  }
}

export function isHdsMaterialUsable(): boolean {
  try {
    const list: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
    return list !== undefined && list !== null && list.length > 0;
  } catch (err) {
    return false;
  }
}

// 说明：**主题色不在这里**。
// 本工程已有的 `theme/ThemeStore.ets`（AppStorage 键 `themeColor`）就是主题色机制，
// 再实现一套只会互相打架，所以材质相关以外的东西一律复用既有实现。

