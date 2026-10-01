/**
 * 澄笺 · 手写批注（Huawei PenKit · HandwriteComponent）
 * =====================================================
 *
 * 华为官方手写能力：压感笔迹、荧光笔、橡皮、套索、激光笔，以及缩放画布。
 * 本文件把它包成一层**覆盖在正文上方**的全屏手写层：根背景透明，
 * 正文内容保持在下面渲染，笔迹直接写在原内容之上。
 *
 * **闪退根因（必须记住）**：HandwriteController 的 load/save 只能在
 * 手写套件初始化完成后调用——官方参数表里有 `onInit` 回调，就是干这个的。
 * 在 aboutToAppear 里直接 load 会原生崩溃（闪退）。现在 load 挪进 onInit。
 *
 * 笔迹文件按文档独立存放：`<filesDir>/handwrite/<文档名>.handwrite`；
 * save 是异步的，退出前必须等保存完成。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { HandwriteComponent, HandwriteController, PenType } from '@kit.Penkit';
import {
  HwRadius,
  HwSpace,
  HwType,
  ReaderPalette,
  ReaderThemeMode,
  paletteOf
} from '../theme/DesignTokens';
import { ImmersiveBar, ImmersiveCard, ImmersiveIconButton } from '../material/ImmersiveCard';
import GlobalUIAbilityContext from '../util/ContextConfig';
import { DocStore } from '../service/DocStore';

/** 手写能力是否可用。判定一次即可，运行期不会变化。 */
let stylusSupported: boolean | null = null;

export function isStylusSupported(): boolean {
  if (stylusSupported === null) {
    try {
      stylusSupported = canIUse('SystemCapability.Stylus.Handwrite');
    } catch (err) {
      stylusSupported = false;
    }
  }
  return stylusSupported;
}

@Component
export struct HandWriteView {
  /** 文档名，用于定位笔迹文件 */
  docKey: string = '';
  @StorageLink('readerThemeMode') themeMode: number = ReaderThemeMode.System;
  @StorageProp('systemDark') systemDark: boolean = false;
  @StorageProp('safeTopPx') safeTopPx: number = 0;
  @StorageProp('safeBottomPx') safeBottomPx: number = 0;
  @State saving: boolean = false;
  @State note: string = '在原内容上直接书写，笔迹会按文档保存';
  /** 画布是否完成初始化（onInit 之后才能 load/save） */
  @State canvasReady: boolean = false;
  onClose: () => void = () => {
  };

  /**
   * 手写控制器。
   *
   * ⚠️ **绝对不能写成 `= new HandwriteController()` 的字段初始化**：
   * `HandwriteController` 的构造函数会立刻初始化原生画笔引擎
   * （initPaintView → createSystemHspModuleResourceManager），
   * 而字段初始化发生在组件构造期，那时上下文还没就绪 → 抛
   * `TypeError: Cannot read property createSystemHspModuleResourceManager of undefined`
   * 直接闪退（真机崩溃日志已确认）。
   *
   * 所以：字段只置空，**在 aboutToAppear 里带 try/catch 创建**，
   * 失败就退化成一个提示卡片——宁可没有手写，也绝不崩。
   */
  private controller: HandwriteController | null = null;
  /** 引擎是否创建成功（失败时 build 走占位分支） */
  @State engineReady: boolean = false;
  private pendingPath: string = '';
  private pendingHasFile: boolean = false;

  private isDark(): boolean {
    if (this.themeMode === ReaderThemeMode.Dark) {
      return true;
    }
    if (this.themeMode === ReaderThemeMode.Light) {
      return false;
    }
    return this.systemDark;
  }

  private palette(): ReaderPalette {
    return paletteOf(this.isDark());
  }

  private ctx(): common.UIAbilityContext | null {
    const fromAbility = GlobalUIAbilityContext.getContext();
    if (fromAbility !== null) {
      return fromAbility;
    }
    const host = this.getUIContext().getHostContext();
    if (host === undefined || host === null) {
      return null;
    }
    return host as common.UIAbilityContext;
  }

  /** 笔迹文件路径。目录不存在时先建。 */
  private notePath(): string {
    const ctx = this.ctx();
    if (ctx === null) {
      return '';
    }
    const dir: string = ctx.filesDir + '/handwrite';
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (err) {
      // 目录已存在或创建失败，后续读写会报错
    }
    return dir + '/' + DocStore.sanitizeName(this.docKey) + '.handwrite';
  }

  aboutToAppear(): void {
    // **不要在这里碰 controller 的 load**——组件还没初始化，load 会闪退。
    // 这里只做两件事：① 安全地创建引擎（带 try/catch）② 准备路径与提示。
    if (isStylusSupported()) {
      try {
        this.controller = new HandwriteController();
        this.engineReady = true;
      } catch (err) {
        this.engineReady = false;
        this.note = '手写引擎初始化失败，本机暂不可用';
        return;
      }
    }
    const path: string = this.notePath();
    if (path.length === 0) {
      this.note = '拿不到应用上下文，手写不可用';
      return;
    }
    this.pendingPath = path;
    try {
      this.pendingHasFile = fs.accessSync(path);
    } catch (err) {
      this.pendingHasFile = false;
    }
  }

  /** HandwriteComponent 的 onInit 回调：套件就绪后才能 load。 */
  private canvasInit(): void {
    this.canvasReady = true;
    const ctrl: HandwriteController | null = this.controller;
    if (this.pendingPath.length === 0 || ctrl === null) {
      return;
    }
    try {
      ctrl.onLoad((err: BusinessError, data: string) => {
        if (err !== undefined && err !== null && err.code !== 0) {
          this.note = '笔迹加载失败：' + err.message;
        }
      });
      if (this.pendingHasFile) {
        ctrl.load(this.pendingPath);
        this.note = '已载入这篇文档的笔迹，直接在原内容上继续写';
      }
    } catch (err) {
      this.note = '笔迹加载失败：' + DocStore.describeError(err as BusinessError);
    }
  }

  /** 保存笔迹。返回是否成功。 */
  private saveThen(close: boolean): void {
    const path: string = this.notePath();
    const ctrl: HandwriteController | null = this.controller;
    if (path.length === 0 || !this.canvasReady || ctrl === null) {
      if (close) {
        this.onClose();
      }
      return;
    }
    this.saving = true;
    ctrl.save(path).then(() => {
      this.saving = false;
      this.note = '笔迹已保存';
      if (close) {
        this.onClose();
      }
    }).catch((err: BusinessError) => {
      this.saving = false;
      this.note = '保存失败：' + err.message;
    });
  }

  @Builder
  topBar() {
    ImmersiveBar({ palette: this.palette(), barPaddingH: HwSpace.xs, barPaddingV: HwSpace.xs }) {
      ImmersiveIconButton({
        buttonSize: 36,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          // 退出前先存，避免「写了半天退出就没了」
          this.saveThen(true);
        }
      }) {
        SymbolGlyph($r('sys.symbol.arrow_left'))
          .fontSize(17)
          .fontColor([this.palette().textPrimary])
      }

      Column({ space: 1 }) {
        Text('手写批注')
          .fontSize(HwType.label)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.palette().textPrimary)
        Text(this.docKey.length > 0 ? this.docKey : '未命名文档')
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      .padding({ left: HwSpace.sm, right: HwSpace.sm })

      ImmersiveIconButton({
        buttonSize: 36,
        buttonMaterialShadow: false,
        palette: this.palette(),
        buttonOnTap: () => {
          this.saveThen(false);
        }
      }) {
        SymbolGlyph(this.saving ? $r('sys.symbol.arrow_down_circle') : $r('sys.symbol.checkmark_circle'))
          .fontSize(18)
          .fontColor([this.palette().accent])
      }
    }
  }

  @Builder
  unsupportedCard() {
    Column() {
      ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
        Column({ space: HwSpace.sm }) {
          SymbolGlyph($r('sys.symbol.highlighter_line'))
            .fontSize(30)
            .fontColor([this.palette().textTertiary])
          Text(isStylusSupported() ? '手写引擎未能启动' : '当前设备不支持手写')
            .fontSize(HwType.label + 2)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette().textPrimary)
          Text('手写批注依赖华为手写能力（SystemCapability.Stylus.Handwrite）。引擎启动失败时应用会自动降级到这里，不会闪退。\n\n可以改用正文长按选中文本的方式做荧光笔与文字批注。')
            .fontSize(HwType.caption)
            .fontColor(this.palette().textTertiary)
            .lineHeight(HwType.caption * 1.7)
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .padding(HwSpace.lg)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (isStylusSupported() && this.engineReady && this.controller !== null) {
        // 画布铺满：透明根背景让正文透出来，笔迹直接写在原内容上
        Column() {
          HandwriteComponent({
            handwriteController: this.controller,
            defaultPenType: PenType.PEN,
            widthRatio: 1,
            heightRatio: 1,
            maxCanvasHeight: 8000,
            scaleDisabled: false,
            onInit: () => {
              this.canvasInit();
            }
          })
        }
        .width('100%')
        .height('100%')
      } else {
        Column() {
          this.unsupportedCard()
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }

      Column() {
        Row() {
          this.topBar()
        }
        .width('100%')
        // 画布是全屏的，工具栏浮在上面，所以要自己让开状态栏与手势条
        .padding({
          left: HwSpace.lg,
          right: HwSpace.lg,
          top: this.getUIContext().px2vp(this.safeTopPx) + HwSpace.xs
        })

        Column()
          .layoutWeight(1)

        Text(this.note)
          .fontSize(HwType.caption)
          .fontColor(this.palette().textTertiary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({
            left: HwSpace.lg,
            right: HwSpace.lg,
            bottom: this.getUIContext().px2vp(this.safeBottomPx) + HwSpace.lg
          })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // 根背景透明：正文保持在下层渲染，手写层悬浮在原内容之上
    .backgroundColor('#00000000')
  }
}
