import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const cli = join(repoRoot, "cli", "bin", "weaver.js");
const fixtures = [
  "clock",
  "pomodoro",
  "system",
  "now-playing",
  "visualizer",
  "dpi-diagnostic",
  "m4b-parity",
  "m4b-synthetic",
];

for (const fixture of fixtures) {
  const source = join(repoRoot, "examples", fixture);
  const dist = join(source, "dist");
  const distExisted = existsSync(dist);
  for (const command of ["check", "bundle"]) {
    const result = spawnSync(process.execPath, [cli, command, source], { cwd: repoRoot, encoding: "utf8" });
    assert.equal(result.status, 0, `${command} failed for ${fixture}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  }
  assert.equal(existsSync(join(dist, "bundle.js")), true, `${fixture} bundle is missing`);
  assert.equal(existsSync(join(dist, "widget.json")), true, `${fixture} manifest is missing`);
  if (!distExisted) rmSync(dist, { recursive: true, force: true });
}

process.stdout.write(`Checked and bundled ${fixtures.length} portable example surfaces.\n`);
