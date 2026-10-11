# -*- coding: utf-8 -*-
"""
澄笺 · 更新日志敏感词检查
==========================
扫描 `entry/src/main/ets/service/Changelog.ets` 与 `CHANGELOG.md`，
命中即打印上下文并以非零码退出（可挂进发版前检查）。

词库来源：用户提供的审核侧敏感名单截图（VPN / clash / EhViewer 等）
+ 同类扩展（代理 / 翻墙工具、成人应用、敏感平台）
+ 常规类（政治 / 违规 / 广告法极限词 / 医疗金融承诺）。
"""
import io
import os
import re
import sys

WORDS = [
    # 审核名单截图可见
    'VPN', 'Eros-N', 'EhViewer', 'NextE', 'clash',
    # 同类：代理 / 翻墙工具
    'v2ray', 'V2Ray', 'shadowsocks', 'Shadowsocks', 'SSR', 'trojan', 'Trojan',
    'wireguard', 'WireGuard', 'sing-box', 'Surge', 'Quantumult', 'Shadowrocket',
    '小火箭', 'Potatso', 'Loon', 'Stash', 'surfshark', 'NordVPN',
    '代理服务器', '翻墙', '科学上网', '梯子', ' circumvent',
    # 同类：成人 / 敏感应用
    'Eros', 'ehviewer', 'picacomic', 'PicAcg', 'bika', '18禁', 'R18', 'NSFW',
    'porn', 'onlyfans', 'JAV',
    # 同类：敏感平台
    'Telegram', 'Discord', '洋葱路由',
    # 常规：政治 / 领土
    '台湾', '香港', '澳门', '西藏', '新疆', '法轮',
    # 常规：违规
    '破解', '盗版', '越狱', 'ROOT', '刷机', '赌博', '博彩', '彩票', '色情',
    '性感', '暴力', '血腥', '武器', '毒品', '烟草', '代孕',
    # 常规：广告法极限词
    '最好', '最强', '最优', '最大', '最低', '最全', '最快', '第一', '唯一',
    '顶级', '国家级', '百分百',
    # 常规：医疗 / 金融承诺
    '治疗', '治愈', '包治', '根治', '稳赚', '保本', '翻倍', '收益率',
    # 常规：其它易敏感
    '黑客', '监听', '窃取', '翻录', '盗取',
]

TARGETS = [
    'entry/src/main/ets/service/Changelog.ets',
    'CHANGELOG.md',
]


def scan(text):
    """词边界匹配 + 大小写不敏感；返回 [(词, 上下文)]。"""
    low = text.lower()
    hits = []
    for w in WORDS:
        pat = r'(?<![a-z0-9])' + re.escape(w.lower()) + r'(?![a-z0-9])'
        for m in re.finditer(pat, low):
            i = m.start()
            ctx = text[max(0, i - 30):i + 42].replace('\n', ' ')
            hits.append((w, ctx))
    return hits


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    total = 0
    for rel in TARGETS:
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            print('[跳过] 不存在:', rel)
            continue
        text = io.open(path, encoding='utf-8', errors='ignore').read()
        for w, ctx in scan(text):
            total += 1
            print(f'[敏感词 {w}] ({rel}) …{ctx}…')
    if total == 0:
        print('检查通过：两份更新日志均未命中敏感词 ✓')
        return 0
    print(f'共命中 {total} 处，请人工确认并修改')
    return 1


if __name__ == '__main__':
    sys.exit(main())
