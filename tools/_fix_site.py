# -*- coding: utf-8 -*-
"""官网修复（按钮可点 + 去更新日志 + 画廊更新）与截图归类。"""
import io
import os
import shutil
import glob

# ① 官网：Hap Store 按钮可点 + 移除更新日志 + 画廊换新图
p = 'website/index.html'
s = io.open(p, encoding='utf-8').read()

old = """.hero::before{content:'';position:absolute;width:760px;height:760px;border-radius:50%;
  right:-200px;top:-260px;background:radial-gradient(circle,rgba(74,111,165,.16),transparent 65%)}
.hero::after{content:'';position:absolute;width:520px;height:520px;border-radius:50%;
  left:-160px;bottom:-220px;background:radial-gradient(circle,rgba(181,162,126,.14),transparent 65%)}"""
new = """.hero::before{content:'';position:absolute;width:760px;height:760px;border-radius:50%;
  right:-200px;top:-260px;background:radial-gradient(circle,rgba(74,111,165,.16),transparent 65%);
  pointer-events:none}
.hero::after{content:'';position:absolute;width:520px;height:520px;border-radius:50%;
  left:-160px;bottom:-220px;background:radial-gradient(circle,rgba(181,162,126,.14),transparent 65%);
  pointer-events:none}"""
assert old in s, 'hero 伪元素未命中'
s = s.replace(old, new, 1)

start = s.index('<section id="log" class="alt">')
end = s.index('</section>', start) + len('</section>')
s = s[:start] + s[end:]
s = s.replace('      <a href="#log">更新日志</a>\n', '')

for src, dst in [('store/phone/02.png', 'website/assets/phone-reading.png'),
                 ('store/phone/05.png', 'website/assets/phone-search.png'),
                 ('store/tablet/02.png', 'website/assets/tab-reading.png'),
                 ('store/pc/06.png', 'website/assets/pc-ai.png')]:
    shutil.copyfile(src, dst)

anchor = '<figure class="reveal d3"><img src="assets/pc-reading.png" alt="PC · 阅读" data-cap="PC · 沉浸阅读"><figcaption>PC · 沉浸阅读</figcaption></figure>'
add = anchor + '\n      <figure class="reveal"><img src="assets/pc-ai.png" alt="PC · AI 助手" data-cap="AI 助手 · 大屏更从容"><figcaption>AI 助手 · 大屏更从容</figcaption></figure>'
assert anchor in s, 'pc-reading 图未命中'
s = s.replace(anchor, add, 1)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('官网修复完成')

# ② 截图归类
base = '应用截图'
for src_dir, dst_dir in [('store/phone', base + '/手机端'),
                         ('store/tablet', base + '/平板端'),
                         ('store/pc', base + '/PC端')]:
    os.makedirs(dst_dir, exist_ok=True)
    for f in sorted(glob.glob(src_dir + '/*.png')):
        shutil.copyfile(f, os.path.join(dst_dir, os.path.basename(f)))
print('归类完成')
for d in ['手机端', '平板端', 'PC端']:
    n = len(glob.glob(base + '/' + d + '/*.png'))
    print(' ', d, n, '张')
