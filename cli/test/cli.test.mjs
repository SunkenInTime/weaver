import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const originBundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/origin.ts", import.meta.url))],
  bundle: true,
  format: "esm",
  platform: "node",
  write: false,
});
const origin = await import(`data:text/javascript;base64,${Buffer.from(originBundle.outputFiles[0].contents).toString("base64")}`);
const hostToolsBundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/host-tools.ts", import.meta.url))],
  bundle: true,
  format: "esm",
  platform: "node",
  write: false,
});
const hostTools = await import(`data:text/javascript;base64,${Buffer.from(hostToolsBundle.outputFiles[0].contents).toString("base64")}`);

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

test("status table is aligned and includes crash reasons", () => {
  const table = hostTools.formatStatus({ hostPid: 1, widgets: [
    { name: "Clock", pid: 42, privateMb: 9.55, cpuPercent: 0.2, uptimeSeconds: 65, state: "running", reason: "" },
    { name: "Broken", pid: 0, privateMb: 0, cpuPercent: 0, uptimeSeconds: 0, state: "stopped", reason: "crashed 3 times" },
  ] });
  assert.match(table, /^NAME\s+PID\s+PRIVATE\s+CPU\s+UPTIME\s+STATE/m);
  assert.match(table, /Broken\s+-\s+0\.0 MB\s+0\.0%\s+0s\s+stopped: crashed 3 times/);
});

test("bundle manifest is the subscription origin of truth", () => {
  const root = mkdtempSync(join(tmpdir(), "weaver-subscriptions-"));
  const widget = join(root, "system-card");
  const cli = fileURLToPath(new URL("../dist/index.js", import.meta.url));
  try {
    assert.equal(spawnSync(process.execPath, [cli, "init", "system-card"], { cwd: root, encoding: "utf8" }).status, 0);
    const sourcePath = join(widget, "widget.tsx");
    const source = `import { useProvider, widget } from "@weaver/sdk";
export default widget({ name: "System Card", size: [200, 100], subscribe: ["cpu", "memory"] }, () => {
  const cpu = useProvider("cpu");
  return <text>{cpu.percent}</text>;
});
`;
    writeFileSync(sourcePath, source, "utf8");
    const result = spawnSync(process.execPath, ["cli/dist/index.js", "bundle", widget], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(readFileSync(join(widget, "dist", "widget.json"), "utf8")).subscribe, ["cpu", "memory"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

