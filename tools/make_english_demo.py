# -*- coding: utf-8 -*-
"""
澄笺 · 英语学习演示备份包生成器
================================
产出 filesDir 同构的 zip（shelf.json + docs/ + annotations/），
用「数据管理 → 导入备份」选择本文件即可完整还原。

结构对齐（全部按应用真实存储格式生成）：
  · shelf.json            ShelfIndex{docs: DocMeta[]}（folders/order 缺省由 normalizeOrder 兜底）
  · docs/<文件名>.md      正文（UTF-8）
  · annotations/<名>.json {items:[MdAnnotation]}，块 id = 'b'+解析序号

注意：
  · 学习卡 = 批注 style='card' + color=3（实色黄底）+ note=中文释义
  · 带批注的两篇文档只用「标题 + 段落」两种块（序号可手数，杜绝 id 错位）
  · 演示文档第三篇用 Front Matter / 表格 / 任务 / 图表 / 脚注，展示语法覆盖面
"""
import json
import os
import zipfile

NOW_MS = 1781000000000 // 1  # 固定时间戳，保证可复现

# ─────────────────────────── 文档 1：英语核心词汇（学习卡） ───────────────────────────
# 结构：# 标题(b0) → 段(b1) → ## 小标题(b2) → 词段落(b3..) → ## 小标题 → 词段落…
# 每个词段落以「单词」开头 → 批注区间恒为 start=0, end=len(word)，与后续内容无关

VOCAB_WORDS = [
    # (单词, 释义行, 中文意思[学习卡备注])
    ("abandon", "abandon — v. 放弃；中止；n. 尽情、放纵", "v. 放弃；抛弃。常见搭配 abandon the plan / give up hope"),
    ("ambivalent", "ambivalent — adj. 矛盾的；有好歹两种情绪的", "adj. （对人或事）有矛盾心理的。ambivalent feelings 又爱又恨"),
    ("diligent", "diligent — adj. 勤勉的；用功的", "adj. 勤奋的。近义词 hard-working，反义词 lazy"),
    ("emphasize", "emphasize — v. 强调；着重", "v. 强调。名词形式 emphasis，搭配 lay emphasis on"),
    ("feasible", "feasible — adj. 可行的；行得通的", "adj. 可行的。a feasible plan 切实可行的计划"),
    ("gratitude", "gratitude — n. 感激；感恩", "n. 感恩。express gratitude to sb 向某人致谢"),
    ("hesitate", "hesitate — v. 犹豫；踌躇", "v. 犹豫。hesitate to do sth 做某事有所顾虑"),
    ("inevitable", "inevitable — adj. 不可避免的；必然的", "adj. 必然的。the inevitable result 必然结果"),
]

lines1 = []
lines1.append("# 英语核心词汇 · 高频词卡")
lines1.append("")
lines1.append("本页收录日常阅读里的高频词，每段一个词。点按黄色高亮的单词即可看到中文释义（学习卡），也可以在「书架 → 文房 → 复习卡片」里背记，忘了的词会按记忆曲线重复出现。")
lines1.append("")
words_meta1 = []  # (blockId, word)
seq = 0
seq += 1  # b0 = 标题
seq += 1  # b1 = 说明段
lines1.append("## Week 1 · 基础动作与态度")
seq += 1  # b2 = 小标题
for i, (w, line, note) in enumerate(VOCAB_WORDS):
    if i == 2:
        lines1.append("")
        lines1.append("## Week 2 · 描述与评价")
        seq += 1  # 小标题
    lines1.append("")
    lines1.append(line)
    words_meta1.append(("b" + str(seq), w, note))
    seq += 1  # 词段落
doc1 = "\n".join(lines1) + "\n"
DOC1_NAME = "英语核心词汇笔记"
DOC1_FILE = DOC1_NAME + ".md"

# 批注 1：每个词一张学习卡
anno1_items = []
for idx, (bid, w, note) in enumerate(words_meta1):
    anno1_items.append({
        "id": "demo-card-" + str(idx + 1),
        "blockId": bid,
        "start": 0,
        "end": len(w),
        "text": w,
        "color": 3,
        "note": note,
        "style": "card",
        "created": NOW_MS + idx,
    })

# ─────────────────────────── 文档 2：经济学人精读（荧光笔 / 文字批注 / 波浪线 / 学习卡） ───────────────────────────
# 结构：# 标题(b0) → 导读段(b1) → ## 原文选段(b2) → 三个段落(b3,b4,b5) → ## 精读讲解(b6) → 讲解段(b7,b8)
# 批注只落在 b3 / b4 / b5（纯文本段落，偏移即字面位置）

L1 = "In an economy of abundance, the scarce resource is no longer information but human attention."
L2 = "Platforms compete for every spare moment, packaging content into ever smaller, more addictive pieces."
L3 = "The result is a marketplace where users pay with time instead of money."

lines2 = []
lines2.append("# The Economics of Attention")
lines2.append("")
lines2.append("导读：本文演示「精读」工作流——黄色荧光笔标地道表达，红色批注写长难句讲解，波浪线标记值得留意的用法，学习卡收录核心词。")
lines2.append("")
lines2.append("## 原文选段")
lines2.append("")
lines2.append(L1)
lines2.append("")
lines2.append(L2)
lines2.append("")
lines2.append(L3)
lines2.append("")
lines2.append("## 精读讲解")
lines2.append("")
lines2.append("第一段的骨架是 A is no longer X but Y：用 no longer…but 把「信息过剩」与「注意力稀缺」对举，写作中可以直接套用（资源类话题万能句式）。")
lines2.append("")
lines2.append("第二段的 packaging content into… 是「介词 + 动名词」结构，ever smaller 表示「越来越小」，比 more and more 更书面。")
doc2 = "\n".join(lines2) + "\n"
DOC2_NAME = "经济学人精读示范"
DOC2_FILE = DOC2_NAME + ".md"


def offset_of(sentence, phrase):
    """短语在句子中的字面偏移（演示文档全为纯文本，偏移即下标）。"""
    p = sentence.find(phrase)
    assert p >= 0, phrase
    return p, p + len(phrase)


anno2_items = [
    {
        "id": "demo-hl-1",
        "blockId": "b3",
        "start": offset_of(L1, "the scarce resource")[0],
        "end": offset_of(L1, "the scarce resource")[1],
        "text": "the scarce resource",
        "color": 1,
        "note": "地道表达：scarce resource 稀缺资源，与 abundance（丰饶）形成反差。",
        "style": "",
        "created": NOW_MS + 10,
    },
    {
        "id": "demo-note-1",
        "blockId": "b3",
        "start": offset_of(L1, "no longer information but human attention")[0],
        "end": offset_of(L1, "no longer information but human attention")[1],
        "text": "no longer information but human attention",
        "color": -1,
        "note": "长难句：no longer…but… 对举结构，前否后肯；注意 but 在这里是介词（+名词短语）。",
        "style": "",
        "created": NOW_MS + 11,
    },
    {
        "id": "demo-wavy-1",
        "blockId": "b4",
        "start": offset_of(L2, "addictive")[0],
        "end": offset_of(L2, "addictive")[1],
        "text": "addictive",
        "color": 0,
        "note": "让人上瘾的；本文用波浪线提醒：addictive design 是争议表达。",
        "style": "wavy",
        "created": NOW_MS + 12,
    },
    {
        "id": "demo-card-10",
        "blockId": "b5",
        "start": offset_of(L3, "marketplace")[0],
        "end": offset_of(L3, "marketplace")[1],
        "text": "marketplace",
        "color": 3,
        "note": "n. 市场；交易场所。pay with time instead of money 用时间付费——注意力经济的关键隐喻。",
        "style": "card",
        "created": NOW_MS + 13,
    },
]

# ─────────────────────────── 文档 3：功能演示（Front Matter / 表格 / 任务 / 图表 / 脚注 / 双链） ───────────────────────────
DOC3_NAME = "功能演示：语法与图表"
DOC3_FILE = DOC3_NAME + ".md"
doc3 = """---
title: 澄笺功能演示
cover: '#3F6FB5'
---
# 澄笺功能一览

本篇集中演示正文的全部语法组件。延伸阅读：[[英语核心词汇笔记]] 与 [[经济学人精读示范]]。

## 任务清单

- [ ] 背完本页单词
- [ ] 精读《The Economics of Attention》并整理生词
- [x] 学会用「学习卡」记录生词

## 数据统计

| 指标 | 本周 | 上周 |
| --- | --- | --- |
| 新增词卡 | 12 | 8 |
| 复习时长 | 25 分钟 | 16 分钟 |
| 精读篇数 | 1 | 0 |

## 图表（mermaid）

```mermaid
mindmap
  root((澄笺))
    阅读
      批注与学习卡
      朗读与滚屏
    写作
      实时预览
      版本历史
    复习
      SM-2 记忆曲线
      签到日历
```

## 脚注示例

这是一个带脚注的句子[^1]，脚注内容会集中出现在「注释与批注」侧栏里。

[^1]: 脚注（footnote）：用 [^标签] 引用、用 [^标签]: 内容 定义，编号自动排版。
"""

# ─────────────────────────── 组装 shelf.json ───────────────────────────


def utf8_len(s):
    return len(s.encode("utf-8"))


def meta_of(name, file_name, content, cover, last_open):
    return {
        "name": name,
        "fileName": file_name,
        "builtin": False,
        "size": utf8_len(content),
        "mtime": NOW_MS,
        "charCount": len(content),
        "wordCount": len([w for w in content.replace("\n", " ").split(" ") if w]),
        "headingCount": sum(1 for ln in content.splitlines() if ln.startswith("#")),
        "progressIndex": 0,
        "progressRatio": 0,
        "lastOpen": last_open,
        "coverColor": cover,
    }


docs_meta = [
    meta_of(DOC1_NAME, DOC1_FILE, doc1, "#FF3F6FB5", NOW_MS + 3),
    meta_of(DOC2_NAME, DOC2_FILE, doc2, "#FF2E7D52", NOW_MS + 2),
    meta_of(DOC3_NAME, DOC3_FILE, doc3, "#FFB5651F", NOW_MS + 1),
]

shelf = {
    "docs": docs_meta,
    "folders": [],
    "order": ["D|" + DOC1_NAME, "D|" + DOC2_NAME, "D|" + DOC3_NAME],
    "hiddenBuiltins": [],
    "seededFolder": "",
}

# ─────────────────────────── 打包 ───────────────────────────

OUT = "澄笺示例数据-英语学习.zip"

annotations = {
    DOC1_NAME: {"items": anno1_items},
    DOC2_NAME: {"items": anno2_items},
}


def sanitize(name):
    out = ""
    for ch in name.strip():
        if ch in '/\\:*?"<>|' or ord(ch) < 32:
            out += "_"
        else:
            out += ch
    return out


with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("shelf.json", json.dumps(shelf, ensure_ascii=False, indent=1))
    z.writestr("docs/" + DOC1_FILE, doc1)
    z.writestr("docs/" + DOC2_FILE, doc2)
    z.writestr("docs/" + DOC3_FILE, doc3)
    for name, data in annotations.items():
        z.writestr("annotations/" + sanitize(name) + ".json",
                   json.dumps(data, ensure_ascii=False, indent=1))

print("written:", OUT, os.path.getsize(OUT), "bytes")
print("doc1 blocks:", seq, "| cards:", len(anno1_items), "| anno2:", len(anno2_items))
