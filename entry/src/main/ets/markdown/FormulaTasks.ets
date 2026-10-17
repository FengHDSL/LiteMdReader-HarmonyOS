/**
 * 澄笺 · 行内公式图任务工具箱
 * ==============================
 *
 * 行内公式图（MathJax → PNG，见 InlineFormulaPool）在**每个渲染 Markdown 的
 * 页面**都要能出图：阅读页 / AI 对话气泡 / 编辑器预览……各页面的收集与
 * "就绪位"逻辑完全一致，统一收口到这里，避免三套实现漂移。
 *
 * 两块职责：
 *   · `collect(blocks, dark, size)`  —— 遍历块收集行内公式任务（含字号，去重交给池子）；
 *   · `readySuffix(ctx, block, …)`   —— 含公式块的 key 后缀（`_m<就绪数>`）：
 *     图就绪后"就绪数"变化 → 只有该块重建 → 正文把线性化文本换成公式图。
 *     （此前段落 key 恒稳、图渲染出来正文也不换——用户实测"公式全都不支持"。）
 */

import { common } from '@kit.AbilityKit';
import { MdBlock, MdInline, MdInlineKind } from './MdTypes';
import { ChartCache } from '../service/ChartCache';
import { EngineRegistry } from '../service/EngineRegistry';

/** 一个待生成的行内公式图任务（InlineFormulaPool 消费） */
export interface FormulaTask {
  /** 缓存键（ChartCache.inlineKey 生成，含字号与深浅） */
  key: string;
  /** 公式源码（LaTeX） */
  latex: string;
  /** 正文字号（vp）：图按该字号排版，与正文大小一致 */
  size: number;
}

/** 行内文本切段：math = 该段按 LaTeX 公式渲染（ImageSpan），否则纯文本 */
export interface InlinePiece {
  text: string;
  math: boolean;
}

export class FormulaTasks {
  /**
   * 收集 blocks 中的行内公式任务。
   * 重复公式（同 text 同字号同深浅）会产生相同 key——由池子的"已缓存跳过"
   * 天然去重，这里不额外处理。
   */
  static collect(blocks: MdBlock[], dark: boolean, size: number): FormulaTask[] {
    // MathJax 已关闭（设置 → 引擎管理）→ 不再收集行内公式图任务：
    // 正文回落线性化文本。判定收口在这一个点，阅读页 / AI 气泡 / 编辑器
    // 预览三处调用方无需各自实现；重新开启后由各页面的 @Watch 重新收集。
    if (EngineRegistry.isOff('mathjax', EngineRegistry.current())) {
      return [];
    }
    const out: FormulaTask[] = [];
    for (let k: number = 0; k < blocks.length; k++) {
      const b: MdBlock = blocks[k];
      for (let q: number = 0; q < b.inlines.length; q++) {
        const il: MdInline = b.inlines[q];
        if (il.kind === MdInlineKind.MathInline && il.text.trim().length > 0) {
          out.push({
            key: ChartCache.inlineKey(il.text, dark, size),
            latex: il.text,
            size: size
          } as FormulaTask);
        }
      }
    }
    return out;
  }

  /**
   * 含行内公式的块的 key 后缀（`_m<就绪数>`；无公式返回空串）。
   *
   * 成本：ChartCache.path 有会话内 memo，命中后是 Map 查询（无磁盘 IO）；
   * key 只在 ForEach diff / 状态变化时计算，不在每帧调用。
   */
  static readySuffix(ctx: common.UIAbilityContext | null, block: MdBlock,
                     dark: boolean, size: number): string {
    if (ctx === null) {
      return '';
    }
    let total: number = 0;
    let ready: number = 0;
    for (let k: number = 0; k < block.inlines.length; k++) {
      const il: MdInline = block.inlines[k];
      if (il.kind !== MdInlineKind.MathInline || il.text.trim().length === 0) {
        continue;
      }
      total++;
      const key: string = ChartCache.inlineKey(il.text, dark, size);
      if (ChartCache.isReady(ctx, key)) {
        ready++;
      }
    }
    return total > 0 ? '_m' + ready : '';
  }

  /**
   * 任意文本 → 行内切段（背诵卡 / 学习卡等**非 Markdown 块**场景用）。
   *
   * 切分规则：
   *   · 含成对 `$…$` → 按对切出公式段（成对才切，单个 $ 按普通文本处理）；
   *   · 没有成对 $ 时整段"像 LaTeX"（含 \command、^、_ 等特征）→ 整段按公式
   *     处理——**公式学习卡**（公式菜单 → 学习卡）的 front 就是裸 LaTeX 源码；
   *   · 其余整段纯文本。
   */
  static splitInline(src: string): InlinePiece[] {
    const out: InlinePiece[] = [];
    if (src.length === 0) {
      return out;
    }
    // ① 成对 $ 切分
    let rest: string = src;
    let dollar: number = rest.indexOf('$');
    if (dollar >= 0 && rest.indexOf('$', dollar + 1) >= 0) {
      while (rest.length > 0) {
        const open: number = rest.indexOf('$');
        if (open < 0) {
          out.push({ text: rest, math: false } as InlinePiece);
          break;
        }
        const close: number = rest.indexOf('$', open + 1);
        if (close < 0) {
          out.push({ text: rest, math: false } as InlinePiece);
          break;
        }
        if (open > 0) {
          out.push({ text: rest.substring(0, open), math: false } as InlinePiece);
        }
        const latex: string = rest.substring(open + 1, close).trim();
        if (latex.length > 0) {
          out.push({ text: latex, math: true } as InlinePiece);
        }
        rest = rest.substring(close + 1);
      }
      return out;
    }
    // ② 无成对 $：整段像 LaTeX → 整段公式（公式学习卡的裸源码）
    if (FormulaTasks.looksLikeLatex(src)) {
      out.push({ text: src.trim(), math: true } as InlinePiece);
      return out;
    }
    out.push({ text: src, math: false } as InlinePiece);
    return out;
  }

  /** 是否"像 LaTeX 源码"（\命令 / 上下标特征）；纯中文句子不会误判。 */
  private static looksLikeLatex(src: string): boolean {
    if (/\\[a-zA-Z]+/.test(src)) {
      return true;
    }
    return /[\^_]\{?/.test(src);
  }

  /**
   * 收集**任意文本**里的行内公式任务（背诵卡 / 学习卡渲染用）。
   * 与 collect 的差异：输入是一段字符串而不是解析后的块。
   */
  static collectText(src: string, dark: boolean, size: number): FormulaTask[] {
    // MathJax 关闭（设置 → 引擎管理）→ 不出图（与 collect 同一口径）
    if (EngineRegistry.isOff('mathjax', EngineRegistry.current())) {
      return [];
    }
    const out: FormulaTask[] = [];
    const pieces: InlinePiece[] = FormulaTasks.splitInline(src);
    for (let k: number = 0; k < pieces.length; k++) {
      const p: InlinePiece = pieces[k];
      if (p.math && p.text.trim().length > 0) {
        out.push({
          key: ChartCache.inlineKey(p.text, dark, size),
          latex: p.text,
          size: size
        } as FormulaTask);
      }
    }
    return out;
  }
}
