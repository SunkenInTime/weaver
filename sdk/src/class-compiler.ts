export type CrossAlign = "start" | "center" | "end" | "baseline";
export type MainAlign = "start" | "center" | "end" | "between";

export interface ClassProps {
  padding?: number;
  gap?: number;
  radius?: number;
  background?: string;
  textColor?: string;
  fontScale?: number;
  fontWeight?: "light" | "normal" | "medium" | "semibold" | "bold";
  opacity?: number;
  crossAlign?: CrossAlign;
  mainAlign?: MainAlign;
  grow?: number;
  width?: number;
  height?: number;
  truncate?: boolean;
}

export class UtilityError extends Error {
  readonly utility: string;

  constructor(utility: string, message: string) {
    super(message);
    this.name = "UtilityError";
    this.utility = utility;
  }
}

const fontScales: Readonly<Record<string, number>> = {
  xs: 12 / 14,
  sm: 1,
  base: 16 / 14,
  lg: 18 / 14,
  xl: 20 / 14,
  "2xl": 24 / 14,
  "3xl": 30 / 14,
  "4xl": 36 / 14,
};

const radii: Readonly<Record<string, number>> = {
  rounded: 4,
  "rounded-md": 6,
  "rounded-lg": 8,
  "rounded-xl": 12,
  "rounded-2xl": 16,
  "rounded-3xl": 24,
  "rounded-full": 9999,
};

const exampleUtilities = [
  "p-4", "p-[13px]", "gap-2", "gap-[13px]", "rounded", "rounded-md",
  "rounded-lg", "rounded-xl", "rounded-2xl", "rounded-3xl", "rounded-full",
  "rounded-[13px]", "bg-[#11141c]/86", "text-[#ffffff]", "text-xs",
  "text-sm", "text-base", "text-lg", "text-xl", "text-2xl", "text-3xl",
  "text-4xl", "font-light", "font-normal", "font-medium", "font-semibold",
  "font-bold", "opacity-70", "items-start", "items-center", "items-end",
  "items-baseline", "justify-start", "justify-center", "justify-end",
  "justify-between", "grow", "w-12", "w-[48px]", "h-12", "h-[48px]",
  "truncate",
] as const;

export function compileClass(className: string): ClassProps {
  const output: ClassProps = {};
  for (const utility of className.trim().split(/\s+/).filter(Boolean)) {
    applyUtility(output, utility);
  }
  return output;
}

function applyUtility(output: ClassProps, utility: string): void {
  if (/^(?:px|py|pt|pr|pb|pl)-/.test(utility) || /^(?:border|shadow|bg-gradient|from-|via-|to-|hover:|focus:|active:|transition)/.test(utility)) {
    throw new UtilityError(utility, `Class utility "${utility}" arrives in M2+`);
  }

  let match: RegExpExecArray | null;
  if ((match = /^p-(\d+(?:\.\d+)?)$/.exec(utility))) {
    output.padding = Number(match[1]) * 4;
    return;
  }
  if ((match = /^p-\[(\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    output.padding = Number(match[1]);
    return;
  }
  if ((match = /^gap-(\d+(?:\.\d+)?)$/.exec(utility))) {
    output.gap = Number(match[1]) * 4;
    return;
  }
  if ((match = /^gap-\[(\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    output.gap = Number(match[1]);
    return;
  }
  if (utility in radii) {
    output.radius = radii[utility];
    return;
  }
  if ((match = /^rounded-\[(\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    output.radius = Number(match[1]);
    return;
  }
  if ((match = /^bg-\[(#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|#[0-9a-fA-F]{8})\](?:\/(\d{1,3}))?$/.exec(utility))) {
    output.background = normalizeColor(match[1], match[2]);
    return;
  }
  if ((match = /^text-\[(#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|#[0-9a-fA-F]{8})\]$/.exec(utility))) {
    output.textColor = normalizeColor(match[1]);
    return;
  }
  if ((match = /^text-(xs|sm|base|lg|xl|2xl|3xl|4xl)$/.exec(utility))) {
    output.fontScale = fontScales[match[1]];
    return;
  }
  if ((match = /^font-(light|normal|medium|semibold|bold)$/.exec(utility))) {
    output.fontWeight = match[1] as ClassProps["fontWeight"];
    return;
  }
  if ((match = /^opacity-(\d{1,3})$/.exec(utility))) {
    const percent = Number(match[1]);
    if (percent <= 100) {
      output.opacity = percent / 100;
      return;
    }
  }
  if ((match = /^items-(start|center|end|baseline)$/.exec(utility))) {
    output.crossAlign = match[1] as CrossAlign;
    return;
  }
  if ((match = /^justify-(start|center|end|between)$/.exec(utility))) {
    output.mainAlign = match[1] as MainAlign;
    return;
  }
  if (utility === "grow") {
    output.grow = 1;
    return;
  }
  if ((match = /^(w|h)-(\d+(?:\.\d+)?)$/.exec(utility))) {
    output[match[1] === "w" ? "width" : "height"] = Number(match[2]) * 4;
    return;
  }
  if ((match = /^(w|h)-\[(\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    output[match[1] === "w" ? "width" : "height"] = Number(match[2]);
    return;
  }
  if (utility === "truncate") {
    output.truncate = true;
    return;
  }
  throw unknownUtility(utility);
}

function normalizeColor(source: string, alphaPercent?: string): string {
  let hex = source.slice(1);
  if (hex.length === 3) hex = hex.split("").map((part) => part + part).join("");
  if (hex.length === 6) hex += "ff";
  if (alphaPercent !== undefined) {
    const percent = Number(alphaPercent);
    if (percent > 100) throw new UtilityError(source, `Color alpha must be between 0 and 100, received ${percent}`);
    hex = hex.slice(0, 6) + Math.round(percent * 255 / 100).toString(16).padStart(2, "0");
  }
  return `#${hex.toUpperCase()}`;
}

function unknownUtility(utility: string): UtilityError {
  const pad = /^pad-(\d+(?:\.\d+)?)$/.exec(utility);
  const suggestion = pad ? `p-[${pad[1]}px]` : nearest(utility, exampleUtilities);
  return new UtilityError(utility, `Unknown class utility "${utility}". Did you mean "${suggestion}"?`);
}

function nearest(value: string, candidates: readonly string[]): string {
  let best = candidates[0];
  let score = Number.POSITIVE_INFINITY;
  for (const candidate of candidates) {
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
