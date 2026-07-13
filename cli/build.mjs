import { build } from "esbuild";

await build({
  entryPoints: ["cli/src/index.ts"],
  outfile: "cli/dist/index.js",
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node20",
  packages: "external",
  banner: { js: "#!/usr/bin/env node" },
});

