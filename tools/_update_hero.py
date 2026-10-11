# -*- coding: utf-8 -*-
"""官网 Hero 改造：双书架截图 + 应用市场按钮 + 系统要求；Gitee 更新为 pandasoos。"""
import io

p = 'website/index.html'
s = io.open(p, encoding='utf-8').read()

# ① Hero 右侧：平板横屏书架 + 手机书架 前后叠放
old_shot = '''    <div>
      <div class="shot"><img src="assets/tab-shelf.png" alt="澄笺 · 平板书架"></div>
      <div class="shot-cap">书架 · 平板横屏（三页分页：文房 · 书架 · 写作日志）</div>
    </div>'''
new_shot = '''    <div>
      <div class="shots">
        <img class="shot-tab" src="assets/tab-shelf.png" alt="澄笺 · 平板书架">
        <img class="shot-phone" src="assets/phone-shelf.png" alt="澄笺 · 手机书架">
      </div>
      <div class="shot-cap">书架 · 手机与大屏横屏（三页分页：文房 · 书架 · 写作日志）</div>
    </div>'''
assert old_shot in s, 'Hero 截图锚点未命中'
s = s.replace(old_shot, new_shot, 1)

# ② Hero CTA：华为应用市场（即将上架，可点暂无响应）+ Hap Store + GitHub + Gitee
old_cta = '''      <div class="cta">
        <a class="primary" href="https://www.sydxky.cn/detail.php?id=956" target="_blank" rel="noopener">Hap Store 下载</a>
        <a class="ghost" href="https://github.com/FengHDSL/LiteMdReader-HarmonyOS/releases" target="_blank" rel="noopener">GitHub Releases</a>
        <a class="ghost" href="https://gitee.com/FengHDSL/LiteMdReader-HarmonyOS" target="_blank" rel="noopener">Gitee 镜像</a>
      </div>
      <p style="font-size:12px;color:var(--ink-3);margin-top:12px">华为应用市场（纯血鸿蒙）即将上架，敬请期待。</p>'''
new_cta = '''      <div class="cta">
        <span class="primary agc" title="华为应用市场 · 即将上架，敬请期待">
          <img src="assets/appgallery.png" alt="AppGallery"><span>华为应用市场<br><small>即将上架</small></span>
        </span>
        <a class="primary" href="https://www.sydxky.cn/detail.php?id=956" target="_blank" rel="noopener">Hap Store 下载</a>
        <a class="ghost" href="https://github.com/FengHDSL/LiteMdReader-HarmonyOS/releases" target="_blank" rel="noopener">GitHub Releases</a>
        <a class="ghost" href="https://gitee.com/pandasoos/LiteMdReader-HarmonyOS" target="_blank" rel="noopener">Gitee 镜像</a>
      </div>
      <div class="sys">
        <img src="assets/hmos.png" alt="HarmonyOS">
        <span>适配系统：<strong>HarmonyOS 6.1+</strong>（纯血鸿蒙）· 手机 / 平板 / 2in1</span>
      </div>'''
assert old_cta in s, 'CTA 锚点未命中'
s = s.replace(old_cta, new_cta, 1)

# ③ 样式：双截图叠放 + 应用市场按钮 + 系统要求行
old_css = '''.hero .shot{border-radius:16px;overflow:hidden;border:1px solid rgba(255,255,255,.6);
  box-shadow:0 30px 80px rgba(34,48,60,.22);animation:rise .9s cubic-bezier(.22,.8,.32,1) both .15s}
.hero .shot img{width:100%}'''
new_css = '''.hero .shots{position:relative;animation:rise .9s cubic-bezier(.22,.8,.32,1) both .15s}
.hero .shots .shot-tab{width:100%;border-radius:14px;border:1px solid rgba(255,255,255,.55);
  box-shadow:0 30px 80px rgba(34,48,60,.24)}
.hero .shots .shot-phone{position:absolute;width:31%;left:-7%;bottom:-9%;
  border-radius:18px;border:2px solid rgba(255,255,255,.65);
  box-shadow:0 34px 80px rgba(20,30,44,.42)}
.hero .agc{display:inline-flex;align-items:center;gap:12px;cursor:pointer;
  background:linear-gradient(150deg,#E6483D,#D23227);color:#fff;
  padding:9px 22px 9px 12px;border-radius:14px}
.hero .agc img{width:38px;height:38px;border-radius:9px;box-shadow:0 2px 8px rgba(0,0,0,.25)}
.hero .agc span{font-size:14px;line-height:1.35;text-align:left}
.hero .agc small{font-size:11px;opacity:.85;font-weight:normal}
.hero .agc:hover{filter:brightness(1.06)}
.sys{display:flex;align-items:center;gap:10px;margin-top:16px;font-size:13px;color:var(--ink-2)}
.sys img{width:30px;height:30px;border-radius:7px}'''
assert old_css in s, 'Hero 样式锚点未命中'
s = s.replace(old_css, new_css, 1)

# ④ Gitee 全站更新为 pandasoos
s = s.replace('gitee.com/FengHDSL/LiteMdReader-HarmonyOS', 'gitee.com/pandasoos/LiteMdReader-HarmonyOS')

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('Hero 改造完成')

# ⑤ 应用介绍同步（口号行下补 Gitee 与系统要求口径）
p2 = '澄笺-应用介绍.md'
s2 = io.open(p2, encoding='utf-8').read()
s2 = s2.replace('https://gitee.com/FengHDSL/LiteMdReader-HarmonyOS',
                'https://gitee.com/pandasoos/LiteMdReader-HarmonyOS')
old2 = '| 下载渠道 | Hap Store（侧载）：https://www.sydxky.cn/detail.php?id=956 ；GitHub Releases；华为应用市场（纯血鸿蒙）即将上架 |'
new2 = '''| 下载渠道 | Hap Store（侧载）：https://www.sydxky.cn/detail.php?id=956 ；GitHub Releases；Gitee 镜像；华为应用市场（纯血鸿蒙）即将上架 |
| 适配系统 | HarmonyOS 6.1+（纯血鸿蒙）· 手机 / 平板 / 2in1 |'''
assert old2 in s2, '下载渠道行未命中'
s2 = s2.replace(old2, new2, 1)
io.open(p2, 'w', encoding='utf-8', newline='\n').write(s2)
print('应用介绍同步完成')
