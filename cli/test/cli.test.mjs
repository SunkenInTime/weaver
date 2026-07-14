import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";

const originBundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/origin.ts", import.meta.url))],
  bundle: true,
  format: "esm",
  platform: "node",
  write: false,
});
const origin = await import(`data:text/javascript;base64,${Buffer.from(originBundle.outputFiles[0].contents).toString("base64")}`);

test("CLI failures are emitted as one actionable block", () => {
  const result = spawnSync(process.execPath, ["cli/dist/index.js", "unknown", "widget"], { encoding: "utf8" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /^weaver failed \(1 error\)\n- Usage:/);
});

test("origin matching is HTTPS-only and exact-host", () => {
  assert.equal(origin.originHost("https://api.example.com/v1"), "api.example.com");
  assert.equal(origin.originHost("http://api.example.com/v1"), null);
  assert.equal(origin.originDeclared(["api.example.com"], "API.EXAMPLE.COM"), true);
  assert.equal(origin.originDeclared(["example.com"], "api.example.com"), false);
  assert.equal(origin.originNotDeclaredMessage("api.example.com"), 'OriginNotDeclared: add "api.example.com" to origins in your widget config');
});

