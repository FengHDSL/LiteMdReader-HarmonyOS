// 一次性补丁：把 Settings.ets 的外观设置卡替换为 xjau WallpaperPage 的控制清单
const fs = require('fs');
const p = 'entry/src/main/ets/pages/Settings.ets';
const lines = fs.readFileSync(p, 'utf8').split('\n');
// 行号（1-based）279..479 是旧外观卡（含头注释到数据卡前）
const head = lines.slice(0, 278).join('\n');
const tail = lines.slice(479).join('\n');
const card = `            // ── 外观设置（照搬 xjau WallpaperPage 的控制清单与语义） ──
            Text('外观设置')
              .fontSize(HwType.label + 1)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.palette().textSecondary)
              .width('100%')

            ImmersiveCard({ cardRadius: HwRadius.card, cardPadding: HwSpace.lg, palette: this.palette() }) {
              Column({ space: HwSpace.md }) {
                Text('顶栏主题色')
                  .fontSize(HwType.label + 1)
                  .fontColor(this.palette().textPrimary)
                Row({ space: HwSpace.sm }) {
                  ForEach(THEME_PRESETS, (item: NamedColor) => {
                    Column()
                      .width(44)
                      .height(44)
                      .borderRadius(10)
                      .backgroundColor(item.value)
                      .justifyContent(FlexAlign.Center)
                      .border({
                        width: 2,
                        color: this.themeColor === item.value ? this.palette().accent : this.palette().divider
                      })
                      .onClick(() => {
                        this.themeColor = item.value;
                        this.toast('顶栏主题色：' + item.name);
                      })
                  }, (item: NamedColor) => 'tp' + item.name)
                }
                .width('100%')

                Row({ space: HwSpace.xs }) {
                  TextInput({ text: this.customHex, placeholder: '自定义 #RRGGBB' })
                    .layoutWeight(1)
                    .fontSize(HwType.label)
                    .fontColor(this.palette().textPrimary)
                    .placeholderColor(this.palette().textTertiary)
                    .backgroundColor(this.palette().quoteBg)
                    .borderRadius(HwRadius.inner)
                    .maxLines(1)
                    .onChange((value: string) => {
                      this.customHex = value;
                    })
                  Text('应用')
                    .fontSize(HwType.label + 1)
                    .fontColor(this.palette().accent)
                    .padding({ left: HwSpace.md, right: HwSpace.md, top: 8, bottom: 8 })
                    .borderRadius(HwRadius.pill)
                    .backgroundColor(this.palette().accentSoft)
                    .onClick(() => {
                      const norm: string = normalizeHex8(this.customHex);
                      if (norm.length === 0) {
                        this.toast('格式：#RRGGBB，例如 #B07A2E');
                        return;
                      }
                      this.themeColor = norm.substring(3);
                      this.toast('自定义主题色已生效');
                    })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)

                Divider().strokeWidth(1).color(this.palette().divider)

                Row() {
                  Column({ space: 2 }) {
                    Text('沉浸光感')
                      .fontSize(HwType.label + 1)
                      .fontColor(this.palette().textPrimary)
                    Text('API 26 系统材质；关闭后卡片按下方样式降级')
                      .fontSize(HwType.caption)
                      .fontColor(this.palette().textTertiary)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Toggle({ type: ToggleType.Switch, isOn: this.immersiveOn })
                    .onChange((isOn: boolean) => {
                      this.immersiveOn = isOn;
                    })
                }
                .width('100%')

                Text(materialDiagnostics(this.immersiveOn))
                  .fontSize(HwType.caption)
                  .fontColor(this.palette().textTertiary)
                  .width('100%')

                Row() {
                  Column({ space: 2 }) {
                    Text('卡片降级样式')
                      .fontSize(HwType.label + 1)
                      .fontColor(this.palette().textPrimary)
                    Text('关闭沉浸光感后，卡片使用云母磨砂还是实色纯底')
                      .fontSize(HwType.caption)
                      .fontColor(this.palette().textTertiary)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Row({ space: HwSpace.xs }) {
                    Text('云母')
                      .fontSize(HwType.label)
                      .fontColor(this.cardFallback === 'mica' ? this.palette().accent : this.palette().textSecondary)
                      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                      .borderRadius(HwRadius.pill)
                      .backgroundColor(this.cardFallback === 'mica' ? this.palette().accentSoft : this.palette().quoteBg)
                      .onClick(() => {
                        this.cardFallback = 'mica';
                      })
                    Text('实色')
                      .fontSize(HwType.label)
                      .fontColor(this.cardFallback === 'solid' ? this.palette().accent : this.palette().textSecondary)
                      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                      .borderRadius(HwRadius.pill)
                      .backgroundColor(this.cardFallback === 'solid' ? this.palette().accentSoft : this.palette().quoteBg)
                      .onClick(() => {
                        this.cardFallback = 'solid';
                      })
                  }
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)

                Column({ space: HwSpace.xs }) {
                  Row() {
                    Text('玻璃通透程度')
                      .fontSize(HwType.label + 1)
                      .fontColor(this.palette().textPrimary)
                    Blank()
                    Text('' + Math.round(this.glassStrength))
                      .fontSize(HwType.label)
                      .fontColor(this.palette().accent)
                  }
                  .width('100%')
                  Slider({ value: this.glassStrength, min: 0, max: 100, step: 5, style: SliderStyle.OutSet })
                    .width('100%')
                    .selectedColor(this.palette().accent)
                    .blockColor(this.palette().accent)
                    .onChange((v: number, mode: SliderChangeMode) => {
                      this.glassStrength = Math.round(v);
                    })
                  Text('越高越透明清透，越低越白越模糊；顶栏 / 底栏 / 工具条同步变化')
                    .fontSize(HwType.caption)
                    .fontColor(this.palette().textTertiary)
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)

                Divider().strokeWidth(1).color(this.palette().divider)

                Row() {
                  Column({ space: 2 }) {
                    Text('卡片沾色')
                      .fontSize(HwType.label + 1)
                      .fontColor(this.palette().textPrimary)
                    Text('开启后所有卡片底色混入 10% 主题色')
                      .fontSize(HwType.caption)
                      .fontColor(this.palette().textTertiary)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Toggle({ type: ToggleType.Switch, isOn: this.cardTint })
                    .onChange((isOn: boolean) => {
                      this.cardTint = isOn;
                    })
                }
                .width('100%')

                Row() {
                  Column({ space: 2 }) {
                    Text('主题色流光')
                      .fontSize(HwType.label + 1)
                      .fontColor(this.palette().textPrimary)
                    Text('按压卡片的流光与光晕改用主题色；关闭后为白光')
                      .fontSize(HwType.caption)
                      .fontColor(this.palette().textTertiary)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Toggle({ type: ToggleType.Switch, isOn: this.pressGlow })
                    .onChange((isOn: boolean) => {
                      this.pressGlow = isOn;
                    })
                }
                .width('100%')

                Row() {
                  Column({ space: 2 }) {
                    Text('卡片流光触感')
                      .fontSize(HwType.label + 1)
                      .fontColor(this.palette().textPrimary)
                    Text('开启后按压卡片出现跟手流光')
                      .fontSize(HwType.caption)
                      .fontColor(this.palette().textTertiary)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Toggle({ type: ToggleType.Switch, isOn: this.cardGlowTouch })
                    .onChange((isOn: boolean) => {
                      this.cardGlowTouch = isOn;
                    })
                }
                .width('100%')

                Row() {
                  Column({ space: 2 }) {
                    Text('高权限自定义主题色')
                      .fontSize(HwType.label + 1)
                      .fontColor(this.palette().textPrimary)
                    Text('默认只有内置主题色会染页面背景；开启后自定义颜色也会')
                      .fontSize(HwType.caption)
                      .fontColor(this.palette().textTertiary)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Toggle({ type: ToggleType.Switch, isOn: this.customAccentFull })
                    .onChange((isOn: boolean) => {
                      this.customAccentFull = isOn;
                    })
                }
                .width('100%')

                Row() {
                  Column({ space: 2 }) {
                    Text('背景跟随主题色')
                      .fontSize(HwType.label + 1)
                      .fontColor(this.palette().textPrimary)
                    Text('关闭后页面底色保持中性，不混入主题色')
                      .fontSize(HwType.caption)
                      .fontColor(this.palette().textTertiary)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Toggle({ type: ToggleType.Switch, isOn: this.pageBgTint })
                    .onChange((isOn: boolean) => {
                      this.pageBgTint = isOn;
                    })
                }
                .width('100%')

                Row() {
                  Column({ space: 2 }) {
                    Text('粒子消散')
                      .fontSize(HwType.label + 1)
                      .fontColor(this.palette().textPrimary)
                    Text('切换文档 / 标签时，一团主题色粒子向外飞散消散')
                      .fontSize(HwType.caption)
                      .fontColor(this.palette().textTertiary)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Toggle({ type: ToggleType.Switch, isOn: this.particleDissolve })
                    .onChange((isOn: boolean) => {
                      this.particleDissolve = isOn;
                    })
                }
                .width('100%')

                Text('阅读背景（预设色板）在「阅读偏好 → 阅读背景」里更换。')
                  .fontSize(HwType.caption)
                  .fontColor(this.palette().textTertiary)
                  .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
`;
fs.writeFileSync(p, head + '\n' + card + '\n' + tail);
console.log('card replaced');
