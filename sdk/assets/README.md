# Weaver Lucide subset

`WeaverLucide.ttf` is a deterministic subset of `lucide-static@1.25.0`
(ISC, npm tarball SHA-1 `d44930d6e5815faace63d9fd9c46c0cadabaaae8`). The upstream
font is 843,668 bytes and exceeds Weaver's 512 KiB registered-face limit; the
vendored 26,768-byte face contains the 79 exact names frozen in
`sdk/src/icons.ts` and has SHA-256
`2fd2c0b19112b2e2aa3ecc669ae00850af7c12d27c8bb08e8847f68557220e40`.

Subset rule: common widget controls, media transport, navigation, status,
device, file, and communication glyphs required by the styling breadth and
showcase work. Names and upstream codepoints are explicit and alphabetized;
no aliases or range-based inclusion are used.

Generated with FontTools 4.59.0 from `package/font/lucide.ttf` using the
codepoints in `sdk/src/icons.ts`, with glyph names, symbol cmap, all name IDs,
legacy names, and timestamp recalculation disabled. Regeneration must preserve
the exact name/codepoint map, pass CLI SFNT validation, and stay below 512 KiB.

See `LUCIDE-LICENSE.txt` for the required Lucide/Feather notices.
