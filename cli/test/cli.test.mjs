import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import test from "node:test";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:net";

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
const devReloadBundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/dev-reload.ts", import.meta.url))],
  bundle: true,
  format: "esm",
  platform: "node",
  write: false,
});
const devReload = await import(`data:text/javascript;base64,${Buffer.from(devReloadBundle.outputFiles[0].contents).toString("base64")}`);

test("dev hot reload signals one loopback event instead of polling", { timeout: 5000 }, async () => {
  const root = mkdtempSync(join(tmpdir(), "weaver-dev-reload-"));
  const dist = join(root, "dist");
  mkdirSync(dist);
  let notifications = 0;
  const server = createServer((socket) => {
    notifications += 1;
    socket.end();
  });
  await new Promise((resolvePromise, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolvePromise);
  });
  try {
    const address = server.address();
    assert.notEqual(typeof address, "string");
    assert.ok(address);
    writeFileSync(join(dist, ".weaver-dev-port"), `${address.port}\n`);
    const notification = once(server, "connection");
    await devReload.signalDevReload(root, 1);
    await notification;
    assert.equal(notifications, 1);
  } finally {
    await new Promise((resolvePromise) => server.close(resolvePromise));
    rmSync(root, { recursive: true, force: true });
  }
});

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
    { name: "Clock", pid: 42, backend: "software", privateMb: 9.55, cpuPercent: 0.2, uptimeSeconds: 65, state: "running", reason: "" },
    { name: "Broken", pid: 0, backend: "-", privateMb: 0, cpuPercent: 0, uptimeSeconds: 0, state: "stopped", reason: "crashed 3 times" },
  ] });
  assert.match(table, /^NAME\s+PID\s+BACKEND\s+PRIVATE\s+CPU\s+THREADS\s+UPTIME\s+STATE/m);
  assert.match(table, /Broken\s+-\s+-\s+0\.0 MB\s+0\.0%\s+0\s+0s\s+stopped: crashed 3 times/);
});

test("path helpers follow Windows case rules without weakening POSIX containment", () => {
  const root = "C:\\Users\\Dara\\AppData\\Local\\weaver\\widgets";
  assert.equal(hostTools.pathsEqual(`${root}\\Clock`, "c:/users/dara/appdata/local/weaver/widgets/clock", "win32"), true);
  assert.equal(hostTools.pathInside(root, "c:/users/dara/appdata/local/weaver/widgets/Clock", "win32"), true);
  assert.equal(hostTools.pathInside(root, "C:\\Users\\Dara\\AppData\\Local\\weaver\\widgets-old\\Clock", "win32"), false);
  assert.equal(hostTools.pathsEqual("/var/lib/Weaver", "/var/lib/weaver", "linux"), false);
  assert.equal(hostTools.pathInside("/var/lib/weaver", "/var/lib/weaver/../outside", "linux"), false);
});

test("CLI paths match the runtime contract on Windows and macOS", () => {
  const windows = { platform: "win32", localAppData: "C:\\Users\\Dara\\AppData\\Local" };
  assert.equal(hostTools.weaverDataPath(windows), "C:\\Users\\Dara\\AppData\\Local\\weaver");
  assert.equal(hostTools.weaverLogsPath(windows), "C:\\Users\\Dara\\AppData\\Local\\weaver\\logs");
  assert.equal(hostTools.registryPath(windows), "C:\\Users\\Dara\\AppData\\Local\\weaver\\registry.json");
  const macos = { platform: "darwin", home: "/Users/dara" };
  assert.equal(hostTools.weaverDataPath(macos), "/Users/dara/Library/Application Support/Weaver");
  assert.equal(hostTools.weaverLogsPath(macos), "/Users/dara/Library/Logs/Weaver");
  assert.equal(hostTools.registryPath(macos), "/Users/dara/Library/Application Support/Weaver/registry.json");
});

test("registry mutations are serialized across processes and leave no shared temp file", async () => {
  const root = mkdtempSync(join(tmpdir(), "weaver-registry-lock-"));
  const registry = join(root, "registry.json");
  const modulePath = join(root, "host-tools.mjs");
  const workerPath = join(root, "worker.mjs");
  try {
    writeFileSync(modulePath, hostToolsBundle.outputFiles[0].contents);
    writeFileSync(workerPath, `import { readRegistry, withRegistryLock, writeRegistry } from "./host-tools.mjs";
const [registry, name, hold] = process.argv.slice(2);
await withRegistryLock(async () => {
  const document = readRegistry(registry);
  await new Promise((resolve) => setTimeout(resolve, Number(hold)));
  writeRegistry({ widgets: [...document.widgets, { name, sourcePath: "/" + name, enabled: true }] }, registry);
}, registry, { timeoutMs: 5000, retryMs: 5, staleMs: 30000 });
`);
    const first = spawn(process.execPath, [workerPath, registry, "first", "150"], { stdio: ["ignore", "pipe", "pipe"] });
    await waitForPath(`${registry}.lock`);
    const second = spawn(process.execPath, [workerPath, registry, "second", "0"], { stdio: ["ignore", "pipe", "pipe"] });
    const [firstResult, secondResult] = await Promise.all([childResult(first), childResult(second)]);
    assert.equal(firstResult.code, 0, firstResult.stderr);
    assert.equal(secondResult.code, 0, secondResult.stderr);
    assert.deepEqual(hostTools.readRegistry(registry).widgets.map((widget) => widget.name), ["first", "second"]);
    assert.deepEqual(readdirSync(root).filter((name) => name.endsWith(".tmp") || name.endsWith(".lock")), []);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("an abandoned registry lock is reclaimed and completely removed", async () => {
  const root = mkdtempSync(join(tmpdir(), "weaver-abandoned-lock-"));
  const registry = join(root, "registry.json");
  const lock = `${registry}.lock`;
  try {
    mkdirSync(lock, { recursive: true });
    writeFileSync(join(lock, "owner.json"), '{"pid":0,"token":"abandoned"}\n', "utf8");
    const old = new Date(Date.now() - 60_000);
    utimesSync(lock, old, old);
    let ran = false;
    await hostTools.withRegistryLock(() => { ran = true; }, registry, { timeoutMs: 1000, retryMs: 5, staleMs: 10 });
    assert.equal(ran, true);
    assert.equal(existsSync(lock), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("bundle manifest is the subscription origin of truth", () => {
  const root = mkdtempSync(join(tmpdir(), "weaver-subscriptions-"));
  const widget = join(root, "system-card");
  const cli = fileURLToPath(new URL("../dist/index.js", import.meta.url));
  try {
    assert.equal(spawnSync(process.execPath, [cli, "init", "system-card"], { cwd: root, encoding: "utf8" }).status, 0);
    const sourcePath = join(widget, "widget.tsx");
    const source = `import { useProvider, widget } from "@weaver/sdk";
export default widget({ name: "System Card", size: [200, 100], subscribe: ["cpu", "memory", "audio", "media"] }, () => {
  const cpu = useProvider("cpu");
  const audio = useProvider("audio");
  return <text>{cpu.percent + audio.rms}</text>;
});
`;
    writeFileSync(sourcePath, source, "utf8");
    mkdirSync(join(widget, "data"));
    writeFileSync(join(widget, "data", "widget.json"), "nested manifest asset", "utf8");
    mkdirSync(join(widget, "assets", "dist"), { recursive: true });
    writeFileSync(join(widget, "assets", "dist", "pixel.bin"), "nested dist asset", "utf8");
    const result = spawnSync(process.execPath, ["cli/dist/index.js", "bundle", widget], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    const manifest = JSON.parse(readFileSync(join(widget, "dist", "widget.json"), "utf8"));
    assert.deepEqual(manifest.subscribe, ["cpu", "memory", "audio", "media"]);
    assert.equal(manifest.renderBackend, "software");
    assert.equal(readFileSync(join(widget, "dist", "data", "widget.json"), "utf8"), "nested manifest asset");
    assert.equal(readFileSync(join(widget, "dist", "assets", "dist", "pixel.bin"), "utf8"), "nested dist asset");
    assert.equal(existsSync(join(widget, "dist", "widget.tsx")), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

async function waitForPath(path) {
  const deadline = Date.now() + 5000;
  while (!existsSync(path)) {
    if (Date.now() >= deadline) throw new Error(`Timed out waiting for ${path}`);
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

function childResult(child) {
  return new Promise((resolve) => {
    let stderr = "";
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("exit", (code) => resolve({ code, stderr }));
  });
}
