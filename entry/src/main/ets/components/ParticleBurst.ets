/**
 * 澄笺 · 粒子消散（外观设置）
 * ============================
 * 切换文档 / 切换标签时，一团主题色粒子从屏幕中心向外飞散消散。
 * 纯装饰层不吃触摸；外观设置「粒子消散」关闭时不产生粒子。
 */

interface ParticleSpec {
  dx: number;
  dy: number;
  s: number;
  delay: number;
  color: string;
}

@Component
export struct ParticleBurst {
  /** 触发序号：每次自增爆一次 */
  @Prop @Watch('onGo') trigger: number = 0;
  @State parts: ParticleSpec[] = [];
  @State go: boolean = false;

  private onGo(): void {
    if (this.trigger <= 0) {
      return;
    }
    if (AppStorage.get<boolean>('particleDissolve') !== true) {
      return;
    }
    const colors: string[] = ['#FFB07A2E', '#FF2F63E8', '#FF8A5AF0', '#FF1F9E9E', '#FFD9435F'];
    const list: ParticleSpec[] = [];
    for (let k = 0; k < 26; k++) {
      const ang: number = Math.random() * Math.PI * 2;
      const dist: number = 90 + Math.random() * 220;
      list.push({
        dx: Math.cos(ang) * dist,
        dy: Math.sin(ang) * dist - 70,
        s: 3 + Math.random() * 5,
        delay: Math.random() * 140,
        color: colors[Math.floor(Math.random() * colors.length)]
      });
    }
    this.parts = list;
    this.go = false;
    setTimeout(() => {
      this.go = true;
    }, 16);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      ForEach(this.parts, (p: ParticleSpec, i: number) => {
        Circle({ width: p.s, height: p.s })
          .fill(p.color)
          .translate({ x: this.go ? p.dx : 0, y: this.go ? p.dy : 0 })
          .opacity(this.go ? 0 : 0.85)
          .animation({ duration: 720, curve: Curve.EaseOut, delay: p.delay })
      }, (p: ParticleSpec, i: number) => 'p' + this.trigger + '_' + i)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }
}
