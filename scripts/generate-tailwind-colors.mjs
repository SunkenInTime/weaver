#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const [themePath, outputPath = "sdk/src/tailwind-colors.js"] = process.argv.slice(2);
if (!themePath) {
  console.error("usage: node scripts/generate-tailwind-colors.mjs <tailwindcss/theme.css> [output]");
  process.exit(2);
}

const theme = readFileSync(resolve(themePath), "utf8");
const colors = [];
const pattern = /^\s*--color-([a-z]+-\d+):\s*oklch\(([\d.]+)%\s+([\d.]+)\s+([\d.]+|none)\);$/gm;
for (const match of theme.matchAll(pattern)) {
  colors.push([match[1], oklchToHex(Number(match[2]) / 100, Number(match[3]), match[4] === "none" ? 0 : Number(match[4]))]);
}
if (colors.length !== 286) throw new Error(`expected 286 Tailwind palette entries, found ${colors.length}`);

const lines = [
  "// Generated from tailwindcss@4.3.3 theme.css by scripts/generate-tailwind-colors.mjs.",
  "// Source tarball shasum: c006861611c213c1877893ab5b23daa16be2bb55; OKLCH values",
  "// are converted to the runtime's sRGB8 wire format using the CSS Color 4 matrix and channel clipping.",
  "/** @type {Readonly<Record<string, string>>} */",
  "export const tailwindColors = Object.freeze({",
  ...colors.map(([name, hex]) => `  \"${name}\": \"${hex}\",`),
  "  white: \"#FFFFFFFF\",",
  "  black: \"#000000FF\",",
  "  transparent: \"#00000000\",",
  "});",
  "",
];
writeFileSync(resolve(outputPath), lines.join("\n"));

function oklchToHex(lightness, chroma, hueDegrees) {
  const hue = hueDegrees * Math.PI / 180;
  const a = chroma * Math.cos(hue);
  const b = chroma * Math.sin(hue);
  const lRoot = lightness + 0.3963377774 * a + 0.2158037573 * b;
  const mRoot = lightness - 0.1055613458 * a - 0.0638541728 * b;
  const sRoot = lightness - 0.0894841775 * a - 1.291485548 * b;
  const l = lRoot ** 3;
  const m = mRoot ** 3;
  const s = sRoot ** 3;
  return `#${[
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
  ].map(toSrgbByte).map((value) => value.toString(16).padStart(2, "0")).join("").toUpperCase()}FF`;
}

function toSrgbByte(linear) {
  const encoded = linear <= 0.0031308 ? 12.92 * linear : 1.055 * linear ** (1 / 2.4) - 0.055;
  return Math.round(Math.max(0, Math.min(1, encoded)) * 255);
}
