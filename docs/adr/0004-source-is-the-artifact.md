# A distributed widget IS its source — no sealed/compiled distribution

A shared widget is its TSX + manifest + assets; install means Weaver builds
and runs it locally. There is no compiled-blob distribution and no
author-choice sealing. This is the load-bearing decision for three systems at
once: remixing (ADR 0003) requires agent-readable source; the capability
audit (ADR 0002) requires that what you read is what runs; and the culture
target is "view source" for the desktop — every installed widget is a
potential fork. Manifest carries provenance/remixed-from lineage fields from
day one so a future gallery can treat remixing as a first-class social verb.

## Consequences

- The build toolchain ships with the runtime (install = local sub-second
  build of a small TSX module).
- Authors cannot ship obfuscated widgets; commercial "sealed skin" models are
  deliberately unsupported.
