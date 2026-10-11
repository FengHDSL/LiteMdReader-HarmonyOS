# -*- coding: utf-8 -*-
"""
澄笺 · 商店截图合成器（定稿）
============================
**截图按内容 MD5 匹配**（免疫文件重命名 / 换序），原比例完整展示（不裁切、不拉伸），
外套符合商店规格的深色壳：白色大字标题（金色短线）+ 截图悬浮（圆角、深投影、微光边）。

镜头映射（md5 前 8 位 → 文案）：
  手机 1440×2560：书架 / 精读 / AI 对话 / 复习确认 / 注释搜索 / 编辑 / 文房 / 复习计划 / 写作日志
  平板 2400×1600：书架 / AI 对话 / 三栏精读 / 文房 / 编辑
  PC   2560×1440：主视觉 / AI 对话 / 沉浸阅读 / 文房 / 编辑
"""
import os
import glob
import hashlib
from PIL import Image, ImageDraw, ImageFilter, ImageFont

FOLDER = r'C:/Users/panda/OneDrive/Desktop/新建文件夹 (3)'
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'store')
ASSETS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'website', 'assets')
FILES = sorted(glob.glob(os.path.join(FOLDER, '*')))

FONT_BOLD = r'C:/Windows/Fonts/msyhbd.ttc'
FONT_REG = r'C:/Windows/Fonts/msyh.ttc'
FONT_KAI = r'C:/Windows/Fonts/simkai.ttf'

C_TITLE = (244, 248, 252)
C_SUB = (156, 176, 196)
C_GOLD = (212, 186, 134)


def font(size, bold=True, kai=False):
    if kai:
        try:
            return ImageFont.truetype(FONT_KAI, size)
        except Exception:
            return ImageFont.truetype(FONT_BOLD, size)
    return ImageFont.truetype(FONT_BOLD if bold else FONT_REG, size)


def name8(path):
    return os.path.splitext(os.path.basename(path))[0][:8]


def find_by_name(h8):
    for p in FILES:
        if name8(p) == h8:
            return p
    return None


def prep(path):
    im = Image.open(path)
    if im.mode == 'RGBA':
        bbox = im.getchannel('A').getbbox()
        if bbox:
            im = im.crop(bbox)
    return im.convert('RGB')


def dark_bg(W, H):
    c1, c2, c3 = (13, 18, 27), (26, 40, 58), (34, 54, 78)
    bg = Image.new('RGB', (W, H))
    px = bg.load()
    for y in range(H):
        ty = y / max(1, H - 1)
        for x in range(W):
            tx = x / max(1, W - 1)
            t = tx * 0.35 + ty * 0.65
            if t < 0.5:
                k = t / 0.5
                r = c1[0] + (c2[0] - c1[0]) * k
                g = c1[1] + (c2[1] - c1[1]) * k
                b = c1[2] + (c2[2] - c1[2]) * k
            else:
                k = (t - 0.5) / 0.5
                r = c2[0] + (c3[0] - c2[0]) * k
                g = c2[1] + (c3[1] - c2[1]) * k
                b = c2[2] + (c3[2] - c2[2]) * k
            px[x, y] = (int(r), int(g), int(b))
    glow = Image.new('RGB', (W, H), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([W * 0.55, -H * 0.18, W * 1.35, H * 0.5], fill=(30, 52, 84))
    gd.ellipse([-W * 0.18, H * 0.62, W * 0.38, H * 1.25], fill=(40, 56, 44))
    glow = glow.filter(ImageFilter.GaussianBlur(int(min(W, H) * 0.09)))
    bg = Image.blend(bg, glow, 0.55)
    vig = Image.new('L', (W, H), 0)
    vd = ImageDraw.Draw(vig)
    vd.ellipse([-W * 0.25, -H * 0.25, W * 1.25, H * 1.25], fill=255)
    vig = vig.filter(ImageFilter.GaussianBlur(int(min(W, H) * 0.22)))
    dark = Image.new('RGB', (W, H), (7, 11, 17))
    return Image.composite(bg, dark, vig)


def gold_rule(d, x, y, w, h):
    d.rounded_rectangle([x, y, x + w, y + h], radius=3, fill=C_GOLD)


def paste_floating(cv, shot, cx, cy, disp_w, radius, k):
    w, h = shot.size
    disp_h = int(h * disp_w / w)
    im = shot.resize((disp_w, disp_h), Image.LANCZOS).convert('RGBA')
    pad = int(70 * k)
    shadow = Image.new('RGBA', (disp_w + pad * 2, disp_h + pad * 2), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([pad, pad + int(18 * k), pad + disp_w - 1, pad + disp_h + int(16 * k)],
                         radius=radius, fill=(0, 0, 0, 230))
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(38 * k)))
    mask = Image.new('L', (disp_w, disp_h), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle([0, 0, disp_w - 1, disp_h - 1], radius=radius, fill=255)
    rounded = Image.new('RGBA', (disp_w, disp_h), (0, 0, 0, 0))
    rounded.paste(im, (0, 0), mask)
    bd = ImageDraw.Draw(rounded)
    bd.rounded_rectangle([0, 0, disp_w - 1, disp_h - 1], radius=radius,
                         outline=(210, 226, 240, 60), width=max(1, int(2 * k)))
    cv.alpha_composite(shadow, (int(cx - disp_w / 2 - pad), int(cy - disp_h / 2 - pad)))
    cv.alpha_composite(rounded, (int(cx - disp_w / 2), int(cy - disp_h / 2)))


def draw_header(d, x, y, title, sub, t_size, s_size):
    gold_rule(d, x, y, int(t_size * 1.1), int(t_size * 0.09))
    d.text((x, y + int(t_size * 0.5)), title, font=font(t_size, True), fill=C_TITLE)
    d.text((x, y + int(t_size * 0.5) + t_size + int(t_size * 0.4)), sub,
           font=font(s_size, False), fill=C_SUB)


def compose_phone(im, title, sub, out_path):
    W, H = 1440, 2560
    cv = dark_bg(W, H).convert('RGBA')
    d = ImageDraw.Draw(cv)
    ring = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    rd.ellipse([W * 0.62, H * 0.04, W * 1.22, H * 0.42], outline=(212, 186, 134, 46), width=3)
    cv.alpha_composite(ring)
    draw_header(d, 150, 300, title, sub, 96, 40)
    paste_floating(cv, im, W // 2 + 90, 1560, 980, 52, 1.0)
    d.text((150, H - 210), '澄心执笔，笺上生光', font=font(46, True, kai=True), fill=C_GOLD)
    d.text((150, H - 128), '澄笺 · LiteMdReader · 开源', font=font(26, False), fill=(120, 140, 160))
    cv.convert('RGB').save(out_path, 'PNG')
    print(out_path)


def compose_wide(im, title, sub, out_path, W, H):
    cv = dark_bg(W, H).convert('RGBA')
    d = ImageDraw.Draw(cv)
    k = W / 2560.0
    ring = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    rd.ellipse([-W * 0.12, -H * 0.3, W * 0.42, H * 0.9], outline=(212, 186, 134, 42), width=3)
    cv.alpha_composite(ring)
    tx = int(W * 0.062)
    ty = H * 0.28
    draw_header(d, tx, int(ty), title, sub, int(84 * k), int(30 * k))
    d.text((tx, H - int(190 * k)), '澄心执笔，笺上生光',
           font=font(int(38 * k), True, kai=True), fill=C_GOLD)
    d.text((tx, H - int(110 * k)), '澄笺 · LiteMdReader · 开源',
           font=font(int(22 * k), False), fill=(120, 140, 160))
    w, h = im.size
    disp_w = int(W * 0.5)
    paste_floating(cv, im, int(W * 0.68), int(H * 0.52), disp_w, int(30 * k), k)
    cv.convert('RGB').save(out_path, 'PNG')
    print(out_path)


# ── 镜头映射（md8 → 文案；按内容匹配，免疫文件重命名/换序）──
PHONE_SHOTS = [
    ('8fc23051', '书架，像整理真的书架', '封面配色 · 文件夹归组 · 三页分页'),
    ('b8dde7c8', '荧光笔、学习卡，随读随记', '注释侧栏搜索直达 · 批注不漂移'),
    ('a65aa898', 'AI 助手，接口由你定夺', '讲解 · 原文 · 批注同屏，生成文档直达书架'),
    ('b09dff3f', '划过的词，变成学习卡', 'SM-2 记忆曲线，安排你的复习'),
    ('99394fbd', '批注再多，一搜即达', '分类筛选固定顶部 · 命中直达原文'),
    ('4e435b48', '实时预览，写起来不打断', '分屏对照 · 快捷工具条 · 版本历史'),
    ('04ee9dd9', '学习与统计，一页收纳', '签到日历 · 阅读轨迹 · 复习目标'),
    ('b15af572', '每日目标，记忆曲线', '连续签到 · 复习统计 · 文档筛选'),
    ('90af50c5', '写下每一笔，都有轨迹', '写作日志热力图 · 最近动态'),
]
TABLET_SHOTS = [
    ('b5dec4b1', '大屏书架，更从容', '横屏封面墙 · 文件夹归组 · 树形视图'),
    ('c84dea88', 'AI 助手，大屏更从容', '生成文档直达书架 · 词元统计'),
    ('70c611be', '横屏精读，注释两侧常驻', '荧光笔与学习卡同屏可见'),
    ('84713298', '学习数据，一屏尽览', '统计 · 速记 · 复习排期'),
]
WIDE_CLIP = {
    '8f066855': ('实时预览写作', '分屏对照，所见即所得'),
}

os.makedirs(os.path.join(OUT, 'phone'), exist_ok=True)
os.makedirs(os.path.join(OUT, 'tablet'), exist_ok=True)
os.makedirs(os.path.join(OUT, 'pc'), exist_ok=True)

for idx, (h8, title, sub) in enumerate(PHONE_SHOTS, 1):
    p = find_by_name(h8)
    if p is None:
        print('[跳过] 手机镜头源图缺失:', h8, title)
        continue
    compose_phone(prep(p), title, sub, os.path.join(OUT, 'phone', f'{idx:02d}.png'))

for idx, (h8, title, sub) in enumerate(TABLET_SHOTS, 1):
    p = find_by_name(h8)
    if p is None:
        print('[跳过] 平板镜头源图缺失:', h8, title)
        continue
    compose_wide(prep(p), title, sub, os.path.join(OUT, 'tablet', f'{idx:02d}.png'), 2400, 1600)

PC_SHOTS = [
    ('b5dec4b1', '澄笺 · 澄心执笔，笺上生光', '本地优先的 Markdown 书房：阅读 · 写作 · 复习'),
    ('c84dea88', 'AI 助手，大屏更从容', '生成文档直达书架 · 词元统计'),
    ('70c611be', '沉浸阅读', '图表公式离线渲染，荧光笔与学习卡随读随记'),
    ('84713298', '学习与统计', '签到 · 热力图 · 复习排期'),
]

for idx, (h8, title, sub) in enumerate(PC_SHOTS, 1):
    p = find_by_name(h8)
    if p is None:
        print('[跳过] PC 镜头源图缺失:', h8, title)
        continue
    compose_wide(prep(p), title, sub, os.path.join(OUT, 'pc', f'{idx:02d}.png'), 1920, 1080)

# ── 桌面卡片镂空（背景透明，只留卡片本体）──


def cutout_widget(im):
    rgb = im.convert('RGB')
    px = rgb.load()
    w, h = im.size
    cx, cy = w // 2, h // 2

    def light(p):
        return p[0] > 205 and p[1] > 205 and p[2] > 205

    def run_light(x, y, dx, dy, need=14):
        for s in range(need):
            xx, yy = x + dx * s, y + dy * s
            if not (0 <= xx < w and 0 <= yy < h) or not light(px[xx, yy]):
                return False
        return True

    left = 0
    while left < cx:
        if run_light(left, cy, 1, 0):
            break
        left += 1
    right = w - 1
    while right > cx:
        if run_light(right, cy, -1, 0):
            break
        right -= 1
    top = 0
    while top < cy:
        if run_light(cx, top, 0, 1):
            break
        top += 1
    bot = h - 1
    while bot > cy:
        if run_light(cx, bot, 0, -1):
            break
        bot -= 1
    margin = 6
    box = (max(0, left - margin), max(0, top - margin),
           min(w, right + margin), min(h, bot + margin))
    card = im.crop(box).convert('RGBA')
    radius = max(12, card.width // 14)
    mask = Image.new('L', card.size, 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle([0, 0, card.width - 1, card.height - 1], radius=radius, fill=255)
    card.putalpha(mask)
    return card


WIDGET_NAME8 = 'ec6897d3'
widget_src = None
for p in FILES:
    if name8(p) == WIDGET_NAME8:
        widget_src = p
        break
if widget_src is not None:
    widget = cutout_widget(Image.open(widget_src))
    os.makedirs(ASSETS, exist_ok=True)
    widget.save(os.path.join(ASSETS, 'widget.png'), 'PNG')
    print('widget 镂空完成', widget.size)
else:
    print('桌面卡片源图不在文件夹（沿用现有 website/assets/widget.png）')
print('全部完成')
