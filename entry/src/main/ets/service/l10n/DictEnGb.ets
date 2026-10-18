/**
 * 澄笺 · 英语（英国）override
 * ========================
 *
 * 只登记**拼写差异**的条目（colour / grey），其余沿用 EN_US（L10n 里 en-GB 先查本表、
 * 查不到再回 EN_US）。这样两种英语共用一份译稿，不会出现"改了美国版忘了英国版"。
 */
import { L10nEntry, toL10nMap } from './L10nEntries';

export const EN_GB_ENTRIES: L10nEntry[] = [
  { k: '深色模式 · 主题色 · 应用壁纸 · 卡片与流光 · 灰体文本',
    v: 'Dark mode · Accent colour · Wallpaper · Cards and glow · Grey text' },
  { k: '主题色', v: 'Accent colour' },
  { k: '主题色 · 应用壁纸 · 卡片与流光', v: 'Accent colour · Wallpaper · Cards and glow' },
  { k: '已恢复默认主题色', v: 'Default accent colour restored' },
  { k: '自定义主题色已生效', v: 'Custom accent colour applied' },
  { k: '页面底色轻微染上主题色，整体更统一',
    v: 'The page background picks up a hint of the accent colour, so everything reads as one piece.' },
  { k: '自定义色也染背景', v: 'Custom colours tint it too' },
  { k: '关闭时，只有澄笺 5 色会染页面背景',
    v: 'When off, only the five 澄笺 colours tint the page background.' },
  { k: '按压卡片时的流光改用主题色（关闭为白光）',
    v: 'Press glow follows the accent colour; off gives plain white light.' },
  { k: '卡片染上一成主题色，整体更协调（需先选主题色）',
    v: 'Mixes a tenth of the accent colour into cards for a more settled look (pick an accent colour first).' },
  { k: '灰体文本显示增强', v: 'Boost grey text' },
  { k: '把说明文字、时间、占位提示这类灰字统一改成选定颜色',
    v: 'Repaints captions, timestamps and placeholder hints in one chosen colour.' },
  { k: '灰', v: 'Grey' },
  { k: '%1灰体文本：%2', v: '%1 grey text: %2' },
  { k: '%1灰体色已生效', v: '%1 grey text colour applied' },
  { k: '主题色：%1', v: 'Accent colour: %1' },
  { k: '默认「自动」＝有背景亮度信息时按对比度选色、否则跟随主题原本的灰字；深浅两套各设各的，互不影响。',
    v: 'Auto (the default) chooses its colour by contrast when it knows how bright the background is, and otherwise follows the theme grey. Light and dark are set separately and never interfere.' }
];

export const EN_GB_MAP: Map<string, string> = toL10nMap(EN_GB_ENTRIES);
