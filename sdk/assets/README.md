# Weaver Lucide paths

The CLI depends on the complete `lucide-static@1.26.0` icon-node catalog
(ISC; npm tarball SHA-1
`cdaec64ebb9ba10d9ce0fc065184b9dde3eb992d`). During bundle compilation,
each literal `<icon name>` is resolved to its SVG geometry and normalized to
absolute M/L/C/Z commands. Only icons referenced by the widget are emitted.

`LUCIDE-LICENSE.txt` carries the required Lucide/Feather notices and is copied
beside bundles that contain Lucide geometry. No icon font, glyph subset,
codepoint map, or registered font face is retained.
