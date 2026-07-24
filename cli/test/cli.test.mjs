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
test("icon lowering leaves icon-free widget sources byte-exact", () => {
  const transformSource = readFileSync(fileURLToPath(new URL("../src/icon-transform.ts", import.meta.url)), "utf8");
  assert.match(transformSource, /if \(!sourceContainsIcon\(sourceFile\)\) return source;/);
});

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

test("styling 07 discovers, validates, bundles, and names TrueType faces", () => {
  const root = mkdtempSync(join(tmpdir(), "weaver-font-bundle-"));
  try {
    const widget = join(root, "widget");
    mkdirSync(widget, { recursive: true });
    writeFileSync(join(widget, "tsconfig.json"), JSON.stringify({
      compilerOptions: {
        target: "ES2020", module: "ESNext", moduleResolution: "Bundler", strict: true, noEmit: true,
        jsx: "react-jsx", jsxImportSource: "@weaver/sdk", baseUrl: ".",
        paths: { "@weaver/sdk": [join(process.cwd(), "sdk/index.d.ts")], "@weaver/sdk/jsx-runtime": [join(process.cwd(), "sdk/jsx-runtime.d.ts")] },
      },
      include: ["widget.tsx"],
    }));
    writeFileSync(join(widget, "widget.tsx"), `import { widget } from "@weaver/sdk";
export default widget({ name: "Font Test", size: [160, 80] }, () => <text class="font-[Geist] font-bold">Bundled</text>);
`);
    writeFileSync(join(widget, "Geist-Regular.ttf"), readFileSync(join(process.cwd(), "runtime/native-sdk/src/primitives/canvas/fonts/Geist-Regular.ttf")));
    const check = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(check.status, 0, check.stderr);
    const bundle = spawnSync(process.execPath, ["cli/dist/index.js", "bundle", widget], { encoding: "utf8" });
    assert.equal(bundle.status, 0, bundle.stderr);
    const manifest = JSON.parse(readFileSync(join(widget, "dist", "widget.json"), "utf8"));
    assert.deepEqual(manifest.fonts, [{
      id: 64, name: "Geist-Regular.ttf", stem: "Geist-Regular", family: "Geist", weight: "regular", file: "Geist-Regular.ttf",
    }]);
    assert.deepEqual(readFileSync(join(widget, "dist", "Geist-Regular.ttf")), readFileSync(join(widget, "Geist-Regular.ttf")));

    writeFileSync(join(widget, "widget.tsx"), `import { widget } from "@weaver/sdk";
export default widget({ name: "Font Test", size: [160, 80] }, () => <text class="font-[Missing]">Missing</text>);
`);
    const missing = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(missing.status, 1);
    assert.match(missing.stderr, /Unknown bundled font "Missing".*Geist-Regular.*Geist/s);

    writeFileSync(join(widget, "Broken.ttf"), "not a font");
    const broken = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(broken.status, 1);
    assert.match(broken.stderr, /Broken\.ttf: not a parseable TrueType face/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("styling 08 resolves full Lucide and custom SVG paths without reserving fonts", () => {
  const root = mkdtempSync(join(tmpdir(), "weaver-icon-bundle-"));
  try {
    const widget = join(root, "widget");
    mkdirSync(widget, { recursive: true });
    writeFileSync(join(widget, "tsconfig.json"), JSON.stringify({
      compilerOptions: {
        target: "ES2020", module: "ESNext", moduleResolution: "Bundler", strict: true, noEmit: true,
        jsx: "react-jsx", jsxImportSource: "@weaver/sdk", baseUrl: ".",
        paths: { "@weaver/sdk": [join(process.cwd(), "sdk/index.d.ts")], "@weaver/sdk/jsx-runtime": [join(process.cwd(), "sdk/jsx-runtime.d.ts")] },
      },
      include: ["widget.tsx"],
    }));
    const validSource = `import { widget } from "@weaver/sdk";
export default widget({ name: "Icon Test", size: [160, 80] }, () => <row><icon name="badge-question-mark" class="text-red-500 w-6" /><icon d="m1 1 h10 v10 q2 2 4 0 a3 3 0 0 1 3 3 z" viewBox="0 0 20 20" stroke={1.5} /><text class="font-[Geist]">Label</text></row>);
`;
    writeFileSync(join(widget, "widget.tsx"), validSource);
    writeFileSync(join(widget, "Geist-Regular.ttf"), readFileSync(join(process.cwd(), "runtime/native-sdk/src/primitives/canvas/fonts/Geist-Regular.ttf")));
    const check = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(check.status, 0, check.stderr);
    const bundle = spawnSync(process.execPath, ["cli/dist/index.js", "bundle", widget], { encoding: "utf8" });
    assert.equal(bundle.status, 0, bundle.stderr);
    const manifest = JSON.parse(readFileSync(join(widget, "dist", "widget.json"), "utf8"));
    assert.deepEqual(manifest.fonts, [
      { id: 64, name: "Geist-Regular.ttf", stem: "Geist-Regular", family: "Geist", weight: "regular", file: "Geist-Regular.ttf" },
    ]);
    assert.deepEqual(readFileSync(join(widget, "dist", "Lucide-LICENSE.txt")), readFileSync(join(process.cwd(), "sdk/assets/LUCIDE-LICENSE.txt")));
    assert.equal(existsSync(join(widget, "dist", "WeaverLucide.ttf")), false);
    const bundleSource = readFileSync(join(widget, "dist", "bundle.js"), "utf8");
    assert.match(bundleSource, /iconPath/);
    assert.match(bundleSource, /M 3\.85 8\.62/);
    assert.doesNotMatch(bundleSource, /[mhaqv]1 1/);
    assert.doesNotMatch(bundleSource, /zodiac-aquarius/);

    writeFileSync(join(widget, "widget.tsx"), validSource.replace('name="badge-question-mark"', 'name="badge-question-mrak"'));
    const unknown = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(unknown.status, 1);
    assert.match(unknown.stderr, /Unknown Lucide icon "badge-question-mrak"\. Did you mean "badge-question-mark"\?/);

    writeFileSync(join(widget, "widget.tsx"), validSource);
    writeFileSync(join(widget, "Geist-Bold.ttf"), readFileSync(join(process.cwd(), "runtime/native-sdk/src/primitives/canvas/fonts/Geist-Regular.ttf")));
    const twoFonts = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(twoFonts.status, 0, twoFonts.stderr);
    writeFileSync(join(widget, "Third.ttf"), readFileSync(join(process.cwd(), "runtime/native-sdk/src/primitives/canvas/fonts/Geist-Regular.ttf")));
    const overBudget = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(overBudget.status, 1);
    assert.match(overBudget.stderr, /Registered fonts exceed the widget-profile limit of 2 faces/);

    rmSync(join(widget, "Third.ttf"));
    writeFileSync(join(widget, "widget.tsx"), validSource.replace('<icon name="badge-question-mark"', '<icon name="badge-question-mark" d="M0 0"'));
    const mutuallyExclusive = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(mutuallyExclusive.status, 1);
    assert.match(mutuallyExclusive.stderr, /requires exactly one of name or d/);

    writeFileSync(join(widget, "widget.tsx"), validSource.replace('<icon name="badge-question-mark" class="text-red-500 w-6" />', "<icon />"));
    const neither = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(neither.status, 1);
    assert.match(neither.stderr, /requires exactly one of name or d/);

    const oversizedPath = `M0 0 ${"l1 0 ".repeat(2000)}`;
    writeFileSync(join(widget, "widget.tsx"), `import { widget } from "@weaver/sdk";
export default widget({ name: "Icon Test", size: [160, 80] }, () => <icon d="${oversizedPath}" />);
`);
    const oversized = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(oversized.status, 1);
    assert.match(oversized.stderr, /Normalized icon path exceeds the 8192-byte per-node limit/);
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
