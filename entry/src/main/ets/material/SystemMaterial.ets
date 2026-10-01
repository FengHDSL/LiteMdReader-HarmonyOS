/**
 * LiteMdReader · 沉浸光感材质层（API 26 systemMaterial）
 * ======================================================
 *
 * 方案移植自 HarmonyOS 原生项目 miha_hm 的 `utils/SystemMaterial.ets`，
 * 保留其全部踩坑结论。三条硬约束在此重申，改这个文件前务必先读：
 *
 * 1. 应用级前置条件
 *    `uiMaterial.getMaterialInfo().state` 读的是 entry 模块 module.json5 里的 metadata
 *    `ohos.arkui.UIMaterial.state`。取值 disable 时「主动设置的材质也一并失效」，
 *    且**代码绕不过**——必须改配置并重新构建安装。本工程已显式配置为 enable。
 *
 * 2. 生效范围
 *    按钮与选择类组件（Button / Select / Toggle / Slider / ChipGroup / SegmentButton）
 *    可在页面内**全部区域**生效；其余组件（Column / Row / Text 等）的 systemMaterial
 *    只在 Navigation / NavDestination 标题栏或 BarPosition.End 的底部 TabBar 中生效。
 *    内容区的卡片把 systemMaterial 直接挂在 Column/Row 上**不渲染、不报错、不警告**，
 *    所以卡片一律由 Toggle 承载层来画材质（见 ImmersiveCard.ets）。
 *
 * 3. 惰性求值
 *    绝不能写成模块级常量（例如 `export const STYLE = uiMaterial.ImmersiveStyle.THIN`）。
 *    那行会在模块加载期就解引用 API 26 才有的接口，在低版本设备上抛出的异常发生在
 *    任何 try/catch 之外，结果是**应用启动即闪退**。
 */

import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';
import { materialLevelLabel, isHdsMaterialUsable } from '../theme/Appearance';

/** 应用内沉浸光感总开关的 AppStorage 键。 */
export const IMMERSIVE_KEY: string = 'immersiveLightEnabled';

/** 运行时错误信息，空串表示未出错。仅用于诊断展示。 */
let materialError: string = '';
let deviceError: string = '';

function messageOf(err: BusinessError): string {
  if (err.message !== undefined && err.message !== null && err.message.length > 0) {
    return err.message;
  }
  return '未知异常';
}

/** 当前系统 API 版本是否 >= 26（沉浸光感的最低要求）。 */
export function isApi26OrAbove(): boolean {
  try {
    return deviceInfo.sdkApiVersion >= 26;
  } catch (err) {
    deviceError = messageOf(err as BusinessError);
    return false;
  }
}

/**
 * 设备是否支持 ImmersiveMaterial。
 *
 * 注意：`uiMaterial.isImmersiveMaterialSupported()` 只存在于较新的 API 26 SDK 修订版中，
 * 早期 26.0.0 Beta 版 SDK 尚未提供该函数，直接调用会导致编译失败。因此这里退化为
 * 「API 版本判定」，真正的可用性由材质构造是否成功来体现（见 getImmersiveMaterial）。
 */
export function isImmersiveSupported(): boolean {
  return isApi26OrAbove();
}

/**
 * 设备材质档位（影响滤镜与投影是否生效）。
 *
 * 同样刻意不使用 `uiMaterial.getGlobalMaterialLevel()`——该函数与上面那个属于
 * 同一批新增接口，早期 API 26 SDK 上没有，调用即编译失败。
 * 返回 -1 表示无法获取，诊断行里会显示「未知」。
 */
export function materialLevel(): number {
  return -1;
}

/**
 * 系统材质状态文案。**只用于诊断展示，不用于降级判断。**
 * 历史坑：把 `state === DISABLE` 当成「本应用不能渲染」直接返回 Material.empty，
 * 又拿同一状态作降级条件——等于应用自己把光感关掉，是自锁。
 */
export function systemMaterialStateText(): string {
  if (!isApi26OrAbove()) {
    return 'API<26';
  }
  try {
    const state: uiMaterial.MaterialState = uiMaterial.getMaterialInfo().state;
    if (state === uiMaterial.MaterialState.DISABLE) {
      return 'DISABLE(全局关闭)';
    }
    if (state === uiMaterial.MaterialState.ENABLE) {
      return 'ENABLE';
    }
    return 'DEFAULT';
  } catch (err) {
    materialError = messageOf(err as BusinessError);
    return '读取失败';
  }
}

/** 材质厚薄档位。惰性求值，见文件头第 3 条。 */
function materialStyle(): uiMaterial.ImmersiveStyle {
  return toImmersiveStyle(appearanceNumber('appearanceMaterialLevel', 1));
}

/** 材质等级：0 精致 / 1 温和 / 2 平滑。等级越高材质越「实」。 */
function toImmersiveStyle(level: number): uiMaterial.ImmersiveStyle {
  if (level === 0) {
    return uiMaterial.ImmersiveStyle.THICK as uiMaterial.ImmersiveStyle;
  }
  if (level === 2) {
    return uiMaterial.ImmersiveStyle.THIN as uiMaterial.ImmersiveStyle;
  }
  return uiMaterial.ImmersiveStyle.REGULAR as uiMaterial.ImmersiveStyle;
}

function appearanceNumber(key: string, fallback: number): number {
  const value: number | undefined = AppStorage.get<number>(key);
  return value !== undefined && value !== null ? value : fallback;
}

/** 材质类型：0 沉浸 / 1 自适应 / 2 无材质。默认沉浸——「自适应」画出来接近普通磨砂，用户会以为光感没生效。 */
export function appearanceMaterialType(): number {
  return appearanceNumber('appearanceMaterialType', 0);
}

/** 材质引擎：0 自绘云母 / 1 官方 HDS。 */
export function appearanceMaterialEngine(): number {
  return appearanceNumber('appearanceMaterialEngine', 0);
}

/**
 * 清空材质缓存。
 * 外观设置里改了材质类型 / 等级后**必须**调用，否则会继续用旧档位缓存下来的材质对象。
 */
export function invalidateMaterialCache(): void {
  materialCache.clear();
  interactiveCache.clear();
}

/**
 * 静态 / 去投影材质**按完整外观组合缓存**（键 = materialCacheKey() + 是否带投影）。
 * 教训：之前用「D/L 两个槽位变量 + 双字符键」混着判断，键改成两维后分支还按
 * 单字符比较，深浅状态全部落进同一个槽 —— 深浅模式直接反转。统一用 Map 按键存取，
 * 键与判断永远同源，不会再错位。
 */
const materialCache: Map<string, uiMaterial.Material | null> = new Map();
const interactiveCache: Map<string, uiMaterial.Material | null> = new Map();

/** 应用当前是否处于深色外观：手动深色模式优先，跟随系统时读系统深浅。 */
export function appAppearanceDark(): boolean {
  const mode: number | undefined = AppStorage.get<number>('readerThemeMode');
  if (mode === 2) {
    return true;
  }
  if (mode === 1) {
    return false;
  }
  return AppStorage.get<boolean>('systemDark') === true;
}

/**
 * 深色外观下给材质层压一层**半透明深色罩**（materialColor）。
 * 系统材质只跟系统深浅色；应用内手动切深色时必须主动上色，
 * 否则深色模式下材质仍是浅色（用户反馈）。
 * 颜色带透明度（不可全不透明，否则材质滤镜被完全遮住）。
 */
const DARK_MATERIAL_TINT: string = '#B3141416';

/**
 * 浅色外观下的**反向浅色罩**。
 * 材质的底子只认系统深浅色：应用内把深色模式关掉（或切羊皮纸 / 护眼绿）时，
 * 只要系统还停在深色，材质画出来就仍是深色——用户反馈的
 * 「深色模式关闭后，卡片还是深色」就是这个错位。这里对称地压一层浅色罩，
 * 把材质抬回浅色观感（透明度口径与深色罩一致，保住材质滤镜）。
 */
const LIGHT_MATERIAL_TINT: string = '#B3F3F6FB';

/** 系统当前是否深色（AppStorage 'systemDark' 由 EntryAbility.onConfigurationUpdate 同步）。 */
function systemAppearanceDark(): boolean {
  return AppStorage.get<boolean>('systemDark') === true;
}

function buildMaterial(interactive: boolean, withShadow: boolean, lightColor: string): uiMaterial.Material | null {
  const type: number = appearanceMaterialType();
  // 「无材质」是用户显式选择的结果，不是失败降级——直接返回 null，
  // 让所有卡片走毛玻璃路径，观感干净且省电。
  if (type === 2) {
    return null;
  }
  const dark: boolean = appAppearanceDark();
  // 应用浅色 + 系统深色的错位档：材质底子跟系统走，必须反向压浅色罩。
  const lightOverride: boolean = !dark && systemAppearanceDark();
  try {
    if (interactive && type === 0 && !dark && !lightOverride) {
      // lightEffect.color 默认是 Color.White。要换成主题色就必须带类型标注，
      // 直接写成三元表达式里的对象字面量会被 ArkTS 判为「无类型对象」而编译不过。
      const light: uiMaterial.LightEffectOptions = {};
      if (lightColor.length > 0) {
        light.color = lightColor;
      }
      const options: uiMaterial.ImmersiveOptions = {
        style: materialStyle(),
        interactive: true,
        lightEffect: light
      };
      return new uiMaterial.ImmersiveMaterial(options);
    }
    if (!withShadow || type === 1 || dark || lightOverride) {
      // applyShadow 默认 true，材质自带一层投影。成排小卡片挨得近时，
      // 投影会在卡间缝隙里叠成一条暗带，所以单独开一档不带阴影的。
      // 深色外观：压 materialColor 深色罩（浅色材质滤镜 + 深色罩 = 深色材质）。
      // 应用浅色 + 系统深色：压浅色罩，把深色底子抬回浅色。
      const flat: uiMaterial.ImmersiveOptions = {
        style: materialStyle(),
        applyShadow: false
      };
      if (dark) {
        flat.materialColor = DARK_MATERIAL_TINT;
      } else if (lightOverride) {
        flat.materialColor = LIGHT_MATERIAL_TINT;
      }
      return new uiMaterial.ImmersiveMaterial(flat);
    }
    // 静态材质只传 style，刻意**不传 materialColor**：
    // 材质的通透感来自它自身的滤镜，额外赋色会把卡片叠成灰色。
    const plain: uiMaterial.ImmersiveOptions = {
      style: materialStyle()
    };
    return new uiMaterial.ImmersiveMaterial(plain);
  } catch (err) {
    materialError = messageOf(err as BusinessError);
    return null;
  }
}

/**
 * 取沉浸光感材质（惰性构造 + 分档缓存）。
 *
 * 构造失败返回 null，调用方统一降级为毛玻璃——**绝不返回 `Material.empty`**，
 * 那等于「显式不画」，会把失败伪装成静默失效。
 *
 * @param interactive 是否启用按压形变 + 流光。注意实测：卡片承载层用
 *                    `interactive: true` + `lightEffect: {}` 会让材质**完全不渲染**，
 *                    所以卡片走静态材质；此档仅供按钮类按需开启。
 * @param withShadow  是否保留材质自带投影
 * @param lightColor  流光颜色，空串 = 系统默认白光
 */
export function getImmersiveMaterial(interactive: boolean = false,
                                     withShadow: boolean = true,
                                     lightColor: string = ''): uiMaterial.Material | null {
  if (!isApi26OrAbove()) {
    return null;
  }
  const cacheKey: string = materialCacheKey();
  if (interactive) {
    const key: string = cacheKey + (lightColor.length > 0 ? lightColor : '__systemWhite__');
    const hit: uiMaterial.Material | null | undefined = interactiveCache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const built: uiMaterial.Material | null = buildMaterial(true, withShadow, lightColor);
    interactiveCache.set(key, built);
    return built;
  }
  // 静态 / 去投影材质：完整外观组合 + 投影档一起进键，惰性构造后按键存取。
  const key: string = cacheKey + (withShadow ? '|S' : '|F');
  const hit: uiMaterial.Material | null | undefined = materialCache.get(key);
  if (hit !== undefined) {
    return hit;
  }
  const built: uiMaterial.Material | null = buildMaterial(false, withShadow, '');
  materialCache.set(key, built);
  return built;
}

/** 应用侧沉浸光感开关。默认开；显式关掉（值为 false）才降级。 */
export function immersiveEnabled(): boolean {
  const v: boolean | undefined = AppStorage.get<boolean>(IMMERSIVE_KEY);
  return v !== false;
}

/**
 * 材质缓存键：**应用深浅 + 系统深浅**两个维度都要进键。
 * 只看应用深浅的话，固定浅色主题下系统切深色时浅色罩的材质会命中旧缓存，
 * 卡片依旧深色——键变不了，材质就换不了。
 */
function materialCacheKey(): string {
  return (appAppearanceDark() ? 'D' : 'L') + (systemAppearanceDark() ? 'S' : 's');
}

/** 沉浸光感是否应当启用：API 支持 + 构造成功。（刻意不看 MaterialState，避免自锁） */
export function immersiveMaterialActive(): boolean {
  return getImmersiveMaterial() !== null;
}

/**
 * 把材质下发给承载组件。
 *
 * **必须由调用方把订阅变量（开关）作为入参传进来。** ArkUI 的局部更新按表达式
 * 记录依赖，函数内部直接读 AppStorage 是登记不上的——拨开关后已经画出来的卡片
 * 不会重新求值，材质会停在旧状态。
 *
 * @param instance     承载组件的属性实例
 * @param fallbackBlur 材质不可用时是否补一层毛玻璃
 * @param interactive  是否可交互材质
 * @param withShadow   是否保留材质投影
 * @param lightColor   流光颜色
 * @param enabled      应用内开关的**订阅值**
 * @param dark         应用当前是否深色外观（决定材质深色罩，见 buildMaterial）
 */
export function applyMaterialCarrier(instance: CommonAttribute,
                                     fallbackBlur: boolean = true,
                                     interactive: boolean = false,
                                     withShadow: boolean = true,
                                     lightColor: string = '',
                                     enabled: boolean = true,
                                     dark: boolean = false): void {
  const themed: string = interactive ? lightColor : '';
  const material: uiMaterial.Material | null = getImmersiveMaterial(interactive, withShadow, themed);
  if (enabled && material !== null) {
    instance.systemMaterial(material);
  } else if (fallbackBlur) {
    // 降级：磨砂玻璃。注意承载层的底色必须透明，否则模糊会被完全盖住。
    instance.backgroundBlurStyle(BlurStyle.Thin);
  }
}

/**
 * 承载层修饰器。
 *
 * 刻意做成「由 build 期方法 new 出来的实例」而不是模块级单例：
 * 只有读操作发生在渲染期，订阅的开关变化才登记得上依赖。
 * darkOn 参与：深浅切换时调用方重建修饰器 → apply 重跑 → 换用对应外观的材质。
 */
export class MaterialCarrierModifier implements AttributeModifier<ToggleAttribute> {
  private shadowOn: boolean = true;
  private enabledOn: boolean = true;
  private darkOn: boolean = false;

  constructor(shadowOn: boolean, enabledOn: boolean, darkOn: boolean = false) {
    this.shadowOn = shadowOn;
    this.enabledOn = enabledOn;
    this.darkOn = darkOn;
  }

  applyNormalAttribute(instance: ToggleAttribute): void {
    // fallbackBlur=false：承载层自己不补模糊，模糊由外壳负责，
    // 避免承载层与外壳叠两层模糊把卡片糊成灰块。
    applyMaterialCarrier(instance, false, false, this.shadowOn, '', this.enabledOn, this.darkOn);
  }
}

/** 按「是否保留投影 + 应用内开关 + 深浅外观」构造承载层修饰器。 */
export function carrierModifier(shadowOn: boolean, enabledOn: boolean, darkOn: boolean = false): AttributeModifier<ToggleAttribute> {
  return new MaterialCarrierModifier(shadowOn, enabledOn, darkOn);
}

/**
 * 一行诊断文案，把各段判定条件摊开，便于真机排查「为什么没光感」。
 * 形如：API=26 材质=已构造 状态=ENABLE 开关=开 承载=下发材质
 */
export function materialDiagnostics(enabledOn: boolean): string {
  const api: number = isApi26OrAbove() ? 26 : 24;
  const material: uiMaterial.Material | null = getImmersiveMaterial();
  const type: number = appearanceMaterialType();
  const typeText: string = type === 0 ? '沉浸' : (type === 1 ? '自适应' : '无材质');
  const materialText: string = material === null
    ? (type === 2 ? '已关闭' : '构造失败') : '已构造';
  const err: string = materialError.length > 0 ? materialError : deviceError;
  const tail: string = err.length > 0 ? ' 错误=' + err : '';
  return 'API=' + api
    + ' 引擎=' + (appearanceMaterialEngine() === 1 ? 'HDS' : '自绘')
    + ' 类型=' + typeText
    + ' 等级=' + materialLevelLabel(appearanceNumber('appearanceMaterialLevel', 1))
    + ' HDS=' + (isHdsMaterialUsable() ? '可用' : '不可用')
    + ' 材质=' + materialText
    + ' 状态=' + systemMaterialStateText()
    + ' 开关=' + (enabledOn ? '开' : '关')
    + tail;
}
