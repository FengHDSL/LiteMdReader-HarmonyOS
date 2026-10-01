/**
 * LiteMdReader · Emoji 短代码
 * ============================
 *
 * 移植自参考项目 MD Reader 的 Emoji 支持：把 `:smile:` 这样的短代码渲染成对应字符。
 *
 * 取舍：**不引入完整 Emoji 词表**（Unicode 全量表有数千条，且 ArkTS 侧维护成本高）。
 * 这里只收最常用的一百来个；命中才替换，未命中的 `:xxx:` 原样保留——
 * 这一点很重要，否则正文里的时间 `10:30` 或 URL 里的冒号会被误伤。
 */

/** 短代码 → 字符。键不含两端的冒号。 */
const EMOJI_MAP: Map<string, string> = new Map<string, string>([
  ['smile', '😄'], ['grin', '😁'], ['joy', '😂'], ['rofl', '🤣'],
  ['wink', '😉'], ['blush', '😊'], ['heart_eyes', '😍'], ['kissing_heart', '😘'],
  ['sunglasses', '😎'], ['thinking', '🤔'], ['neutral_face', '😐'], ['expressionless', '😑'],
  ['unamused', '😒'], ['sweat', '😅'], ['sweat_smile', '😅'], ['sob', '😭'],
  ['cry', '😢'], ['angry', '😠'], ['rage', '😡'], ['scream', '😱'],
  ['fearful', '😨'], ['cold_sweat', '😰'], ['sleeping', '😴'], ['sleepy', '😪'],
  ['dizzy_face', '😵'], ['nerd', '🤓'], ['smirk', '😏'], ['relieved', '😌'],
  ['pensive', '😔'], ['disappointed', '😞'], ['worried', '😟'], ['confused', '😕'],
  ['flushed', '😳'], ['hushed', '😯'], ['open_mouth', '😮'], ['astonished', '😲'],
  ['yum', '😋'], ['stuck_out_tongue', '😛'], ['zipper_mouth', '🤐'], ['mask', '😷'],
  ['wave', '👋'], ['thumbsup', '👍'], ['+1', '👍'], ['thumbsdown', '👎'],
  ['-1', '👎'], ['ok_hand', '👌'], ['clap', '👏'], ['pray', '🙏'],
  ['muscle', '💪'], ['point_up', '☝️'], ['point_right', '👉'], ['point_left', '👈'],
  ['v', '✌️'], ['fist', '✊'], ['handshake', '🤝'], ['writing_hand', '✍️'],
  ['heart', '❤️'], ['broken_heart', '💔'], ['two_hearts', '💕'], ['sparkling_heart', '💖'],
  ['star', '⭐'], ['star2', '🌟'], ['sparkles', '✨'], ['boom', '💥'],
  ['fire', '🔥'], ['zap', '⚡'], ['sunny', '☀️'], ['cloud', '☁️'],
  ['umbrella', '☔'], ['snowflake', '❄️'], ['rainbow', '🌈'], ['moon', '🌙'],
  ['rocket', '🚀'], ['airplane', '✈️'], ['car', '🚗'], ['bike', '🚲'],
  ['bulb', '💡'], ['wrench', '🔧'], ['gear', '⚙️'], ['hammer', '🔨'],
  ['lock', '🔒'], ['unlock', '🔓'], ['key', '🔑'], ['mag', '🔍'],
  ['book', '📖'], ['books', '📚'], ['memo', '📝'], ['pencil', '✏️'],
  ['pushpin', '📌'], ['paperclip', '📎'], ['file_folder', '📁'], ['clipboard', '📋'],
  ['calendar', '📅'], ['clock', '🕐'], ['hourglass', '⏳'], ['alarm_clock', '⏰'],
  ['chart', '📊'], ['chart_with_upwards_trend', '📈'], ['bar_chart', '📊'], ['package', '📦'],
  ['computer', '💻'], ['desktop_computer', '🖥️'], ['keyboard', '⌨️'], ['phone', '📱'],
  ['battery', '🔋'], ['floppy_disk', '💾'], ['cd', '💿'], ['satellite', '📡'],
  ['warning', '⚠️'], ['no_entry', '⛔'], ['white_check_mark', '✅'], ['heavy_check_mark', '✔️'],
  ['x', '❌'], ['question', '❓'], ['exclamation', '❗'], ['grey_exclamation', '❕'],
  ['info', 'ℹ️'], ['recycle', '♻️'], ['label', '🏷️'], ['bookmark', '🔖'],
  ['link', '🔗'], ['globe_with_meridians', '🌐'], ['earth_asia', '🌏'], ['map', '🗺️'],
  ['gift', '🎁'], ['trophy', '🏆'], ['medal', '🏅'], ['dart', '🎯'],
  ['bug', '🐛'], ['beetle', '🪲'], ['cat', '🐱'], ['dog', '🐶'],
  ['coffee', '☕'], ['beer', '🍺'], ['pizza', '🍕'], ['apple', '🍎'],
  ['tada', '🎉'], ['confetti_ball', '🎊'], ['balloon', '🎈'], ['cake', '🎂'],
  ['musical_note', '🎵'], ['headphones', '🎧'], ['camera', '📷'], ['movie_camera', '🎥']
]);

/** 查表。未命中返回空串（调用方据此保留原文）。 */
export function lookupEmoji(code: string): string {
  const hit: string | undefined = EMOJI_MAP.get(code);
  return hit !== undefined ? hit : '';
}

/** 短代码允许的字符集：小写字母、数字、下划线、加号、减号。 */
export function isEmojiCodeChar(ch: string): boolean {
  const code: number = ch.charCodeAt(0);
  const isLower: boolean = code >= 97 && code <= 122;
  const isUpper: boolean = code >= 65 && code <= 90;
  const isDigit: boolean = code >= 48 && code <= 57;
  return isLower || isUpper || isDigit || ch === '_' || ch === '+' || ch === '-';
}
