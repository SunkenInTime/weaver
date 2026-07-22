export const ICON_FONT_FILE = "WeaverLucide.ttf";
export const ICON_FONT_FAMILY = "WeaverLucide";

export const iconCodepoints = {
  "activity": 0xe038,
  "alarm-clock": 0xe03a,
  "album": 0xe03b,
  "archive": 0xe041,
  "arrow-down": 0xe042,
  "arrow-left": 0xe048,
  "arrow-right": 0xe049,
  "arrow-up": 0xe04a,
  "badge-alert": 0xe475,
  "battery": 0xe053,
  "bell": 0xe059,
  "bluetooth": 0xe05c,
  "bookmark": 0xe060,
  "calendar": 0xe063,
  "camera": 0xe064,
  "cast": 0xe066,
  "check": 0xe06c,
  "check-circle": 0xe07c,
  "chevron-down": 0xe06d,
  "chevron-left": 0xe06e,
  "chevron-right": 0xe06f,
  "chevron-up": 0xe070,
  "circle": 0xe076,
  "clock": 0xe087,
  "cloud": 0xe088,
  "download": 0xe0b2,
  "external-link": 0xe0b9,
  "eye": 0xe0ba,
  "file": 0xe0c0,
  "folder": 0xe0d7,
  "gauge": 0xe1bf,
  "headphones": 0xe0f1,
  "heart": 0xe0f2,
  "home": 0xe0f5,
  "image": 0xe0f6,
  "info": 0xe0f9,
  "layers": 0xe529,
  "link": 0xe102,
  "list": 0xe106,
  "lock": 0xe10b,
  "mail": 0xe10f,
  "map-pin": 0xe111,
  "maximize": 0xe112,
  "menu": 0xe115,
  "message-circle": 0xe116,
  "mic": 0xe118,
  "minimize": 0xe11a,
  "monitor": 0xe11d,
  "moon": 0xe11e,
  "more-horizontal": 0xe0b6,
  "more-vertical": 0xe0b7,
  "music": 0xe122,
  "pause": 0xe12e,
  "play": 0xe13c,
  "plus": 0xe13d,
  "power": 0xe140,
  "radio": 0xe142,
  "refresh-cw": 0xe145,
  "repeat": 0xe146,
  "search": 0xe151,
  "settings": 0xe154,
  "share": 0xe155,
  "shuffle": 0xe15e,
  "skip-back": 0xe15f,
  "skip-forward": 0xe160,
  "smartphone": 0xe163,
  "speaker": 0xe166,
  "square": 0xe167,
  "star": 0xe176,
  "sun": 0xe178,
  "trash-2": 0xe18e,
  "triangle": 0xe192,
  "upload": 0xe19e,
  "user": 0xe19f,
  "volume-1": 0xe1aa,
  "volume-2": 0xe1ab,
  "volume-x": 0xe1ac,
  "wifi": 0xe1ae,
  "x": 0xe1b2,
} as const;

export type IconName = keyof typeof iconCodepoints;
export const iconNames = Object.freeze(Object.keys(iconCodepoints) as IconName[]);

export function isIconName(value: string): value is IconName {
  return Object.prototype.hasOwnProperty.call(iconCodepoints, value);
}

export function iconGlyph(name: string): string {
  if (!isIconName(name)) throw new Error(unknownIconMessage(name));
  return String.fromCodePoint(iconCodepoints[name]);
}

export function unknownIconMessage(name: string): string {
  return `Unknown icon "${name}". Did you mean "${nearestIconName(name)}"?`;
}

export function nearestIconName(value: string): IconName {
  let best = iconNames[0];
  let score = Number.POSITIVE_INFINITY;
  for (const candidate of iconNames) {
    const candidateScore = editDistance(value, candidate);
    if (candidateScore < score) {
      best = candidate;
      score = candidateScore;
    }
  }
  return best;
}

function editDistance(left: string, right: string): number {
  const row = Array.from({ length: right.length + 1 }, (_, index) => index);
  for (let i = 1; i <= left.length; i += 1) {
    let diagonal = row[0];
    row[0] = i;
    for (let j = 1; j <= right.length; j += 1) {
      const previous = row[j];
      row[j] = Math.min(row[j] + 1, row[j - 1] + 1, diagonal + (left[i - 1] === right[j - 1] ? 0 : 1));
      diagonal = previous;
    }
  }
  return row[right.length];
}
