import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

if (process.platform !== "darwin") {
  process.stdout.write("macOS host smoke skipped outside macOS\n");
  process.exit(0);
}

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const cli = join(repoRoot, "cli", "bin", "weaver.js");
const tempRoot = realpathSync(tmpdir());
const scratch = mkdtempSync(join(tempRoot, "weaver-macos-host-smoke-"));
const environment = { ...process.env, HOME: join(scratch, "home"), WEAVER_AUTOMATION: "1" };
const dataRoot = join(environment.HOME, "Library", "Application Support", "Weaver");
const statusFile = join(dataRoot, "status.json");
const clockSource = join(scratch, "clock", "widget.tsx");
const runtimeRootPrefix = `weaver-${process.getuid()}-`;
const runtimeSearchRoots = [...new Set([tempRoot, realpathSync("/tmp")])];
const runtimeEntriesBefore = new Set(runtimeSearchRoots.flatMap((root) => readdirSync(root)
  .filter((name) => name.startsWith(runtimeRootPrefix))
  .map((name) => join(root, name))));
const trackedPids = new Set();
let devProcess;
let devStdout = "";
let devStderr = "";

function run(arguments_, expectedStatus = 0) {
  const result = spawnSync(process.execPath, [cli, ...arguments_], {
    cwd: scratch,
    env: environment,
    encoding: "utf8",
  });
  assert.equal(result.status, expectedStatus, `weaver ${arguments_.join(" ")} exited ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  return result;
}

function runAsync(arguments_) {
  const child = spawn(process.execPath, [cli, ...arguments_], { cwd: scratch, env: environment, stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (bytes) => { stdout += bytes; });
  child.stderr.on("data", (bytes) => { stderr += bytes; });
  return new Promise((resolvePromise, rejectPromise) => {
    child.once("error", rejectPromise);
    child.once("exit", (code, signal) => resolvePromise({ code, signal, stdout, stderr }));
  });
}

function status() {
  if (!existsSync(statusFile)) return null;
  try { return JSON.parse(readFileSync(statusFile, "utf8")); }
  catch { return null; }
}

function alive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; }
  catch { return false; }
}

async function waitFor(description, predicate, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 50));
  }
  throw new Error(`Timed out waiting for ${description}\nstatus:\n${JSON.stringify(status(), null, 2)}\ndev stdout:\n${devStdout}\ndev stderr:\n${devStderr}`);
}

function editClock(from, to) {
  const source = readFileSync(clockSource, "utf8");
  assert.match(source, new RegExp(from.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  writeFileSync(clockSource, source.replace(from, to), "utf8");
}

async function waitForExit(child, timeoutMs = 10_000) {
  if (child.exitCode !== null || child.signalCode !== null) return { code: child.exitCode, signal: child.signalCode };
  return Promise.race([
    new Promise((resolvePromise) => child.once("exit", (code, signal) => resolvePromise({ code, signal }))),
    new Promise((_, rejectPromise) => setTimeout(() => rejectPromise(new Error("Timed out waiting for child exit")), timeoutMs)),
  ]);
}

try {
  run(["init", "clock"]);
  devProcess = spawn(process.execPath, [cli, "dev", "clock"], { cwd: scratch, env: environment, stdio: ["ignore", "pipe", "pipe"] });
  devProcess.stdout.on("data", (bytes) => { devStdout += bytes; });
  devProcess.stderr.on("data", (bytes) => { devStderr += bytes; });
  await waitFor("dev Widget with honest renderer and cost status", () => {
    const document = status();
    const widget = document?.widgets?.[0];
    return widget?.state === "running" && widget.backend === "gpu" && widget.privateMb > 0 && widget.threads > 0 && widget;
  });
  const first = status();
  const firstHostPid = first.hostPid;
  const firstWidgetPid = first.widgets[0].pid;
  trackedPids.add(firstHostPid);
  trackedPids.add(firstWidgetPid);

  editClock("opacity-60", "opacity-61");
  await waitFor("state-preserving in-process hot swap", () => devStdout.includes("dev hot swap applied (preserved root hook state)"));
  assert.equal(status().widgets[0].pid, firstWidgetPid, "bundle-only edit restarted the Widget process");

  editClock("size: [240, 110]", "size: [241, 110]");
  await waitFor("window-contract restart", () => {
    const widget = status()?.widgets?.[0];
    return devStdout.includes("weaver dev restarted widget: window config changed") && widget?.state === "running" && widget.pid !== firstWidgetPid && widget;
  });
  trackedPids.add(status().widgets[0].pid);
  devProcess.kill("SIGINT");
  const devExit = await waitForExit(devProcess);
  assert.equal(devExit.code, 0, `weaver dev did not exit cleanly: ${JSON.stringify(devExit)}\n${devStderr}`);
  devProcess = undefined;
  await waitFor("dev registration removal acknowledgement", () => status()?.widgets?.length === 0);

  run(["init", "alpha"]);
  run(["init", "beta"]);
  const installs = await Promise.all([runAsync(["install", "alpha"]), runAsync(["install", "beta"])]);
  for (const result of installs) assert.equal(result.code, 0, `concurrent install failed\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  await waitFor("both concurrent installs in status", () => status()?.widgets?.length === 2);
  assert.deepEqual(status().widgets.map((widget) => widget.name).sort(), ["Alpha", "Beta"]);
  const uninstalls = await Promise.all([runAsync(["uninstall", "Alpha"]), runAsync(["uninstall", "Beta"])]);
  for (const result of uninstalls) assert.equal(result.code, 0, `concurrent uninstall failed\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  await waitFor("both concurrent uninstalls in status", () => status()?.widgets?.length === 0);
  assert.equal(status().providers.systemSampleCount, 0, "host sampled system providers without a subscriber");

  run(["init", "system-two"]);
  const systemSource = readFileSync(join(repoRoot, "examples", "system", "widget.tsx"), "utf8");
  writeFileSync(join(scratch, "system-two", "widget.tsx"), systemSource.replaceAll("System Monitor", "System Monitor 2"), "utf8");
  run(["install", join(repoRoot, "examples", "system")]);
  run(["install", "system-two"]);
  await waitFor("system-provider fan-out", () => {
    const providers = status()?.providers;
    const logs = ["System Monitor.log", "System Monitor 2.log"]
      .map((name) => join(environment.HOME, "Library", "Logs", "Weaver", name));
    return providers?.systemSubscribers === 2 && providers.systemSampleCount >= 2 && providers.systemFrames >= 4 &&
      logs.every((path) => existsSync(path) && readFileSync(path, "utf8").includes("widget provider frames applied count=2"));
  });
  const activeRuntimeRoot = runtimeSearchRoots.flatMap((root) => readdirSync(root)
    .filter((name) => name.startsWith(runtimeRootPrefix))
    .map((name) => join(root, name)))
    .filter((path) => !runtimeEntriesBefore.has(path))
    .find((path) => existsSync(join(path, "control.sock")));
  assert.ok(activeRuntimeRoot, "macOS host did not create its short per-user runtime root");
  const providerSockets = readdirSync(activeRuntimeRoot, { withFileTypes: true }).filter((entry) => entry.isSocket() && entry.name.startsWith("widget-"));
  assert.equal(providerSockets.length, 2, "provider fan-out did not create one Unix socket per Widget");
  assert.ok(providerSockets.every((entry) => join(activeRuntimeRoot, entry.name).length <= 104), "provider Unix socket exceeded macOS sun_path capacity");
  const providerSamplesBeforeStop = status().providers.systemSampleCount;
  const systemUninstalls = await Promise.all([runAsync(["uninstall", "System Monitor"]), runAsync(["uninstall", "System Monitor 2"])]);
  for (const result of systemUninstalls) assert.equal(result.code, 0, `concurrent System uninstall failed\n${result.stderr}`);
  await waitFor("system provider shutdown", () => status()?.providers?.systemSubscribers === 0 && status()?.widgets?.length === 0);
  assert.ok(providerSockets.every((entry) => !existsSync(join(activeRuntimeRoot, entry.name))), "uninstall left a per-Widget provider endpoint behind");
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 2200));
  assert.equal(status().providers.systemSampleCount, providerSamplesBeforeStop, "host continued sampling after the final system subscriber stopped");

  run(["install", "clock"]);
  await waitFor("installed Clock", () => status()?.widgets?.[0]?.state === "running" && status().widgets[0]);
  const beforeHostCrash = status();
  const crashedHostPid = beforeHostCrash.hostPid;
  const orphanCandidatePid = beforeHostCrash.widgets[0].pid;
  trackedPids.add(crashedHostPid);
  trackedPids.add(orphanCandidatePid);
  process.kill(crashedHostPid, "SIGKILL");
  await waitFor("host crash", () => !alive(crashedHostPid));
  assert.equal(alive(orphanCandidatePid), true, "fixture did not establish the adverse orphan order");
  run(["up"]);
  await waitFor("replacement host and Widget recovery", () => {
    const document = status();
    const widget = document?.widgets?.[0];
    return document?.hostPid !== crashedHostPid && widget?.state === "running" && widget.pid !== orphanCandidatePid && widget;
  });
  assert.equal(alive(orphanCandidatePid), false, "replacement host left the old Widget orphaned");

  const afterHostRecovery = status().widgets[0].pid;
  trackedPids.add(status().hostPid);
  trackedPids.add(afterHostRecovery);
  process.kill(afterHostRecovery, "SIGKILL");
  const firstRecoveryPid = await waitFor("first Widget crash recovery", () => {
    const widget = status()?.widgets?.[0];
    return widget?.state === "running" && widget.pid !== afterHostRecovery && widget.pid;
  });
  trackedPids.add(firstRecoveryPid);
  process.kill(firstRecoveryPid, "SIGKILL");
  await waitFor("observable Widget backoff", () => status()?.widgets?.[0]?.state === "backoff");
  const secondRecoveryPid = await waitFor("Widget recovery after backoff", () => {
    const widget = status()?.widgets?.[0];
    return widget?.state === "running" && widget.pid !== firstRecoveryPid && widget.pid;
  }, 15_000);
  trackedPids.add(secondRecoveryPid);

  run(["uninstall", "Clock"]);
  assert.deepEqual(status().widgets, [], "uninstall acknowledgement left a Widget slot");
  run(["down"]);
  await waitFor("daemon shutdown", () => !alive(status()?.hostPid));
  for (const pid of trackedPids) assert.equal(alive(pid), false, `Weaver process ${pid} remained after shutdown`);
  const runtimeEntriesAfter = runtimeSearchRoots.flatMap((root) => readdirSync(root)
    .filter((name) => name.startsWith(runtimeRootPrefix))
    .map((name) => join(root, name)))
    .filter((path) => !runtimeEntriesBefore.has(path));
  assert.deepEqual(runtimeEntriesAfter, [], `runtime endpoint or lock remained: ${runtimeEntriesAfter.join(", ")}`);
} finally {
  if (devProcess && devProcess.exitCode === null && devProcess.signalCode === null) {
    devProcess.kill("SIGINT");
    await waitForExit(devProcess).catch(() => devProcess.kill("SIGKILL"));
  }
  spawnSync(process.execPath, [cli, "down"], { cwd: scratch, env: environment, stdio: "ignore" });
  for (const pid of trackedPids) {
    try { process.kill(pid, "SIGKILL"); }
    catch { /* Already stopped. */ }
  }
  rmSync(scratch, { recursive: true, force: true });
}

process.stdout.write("macOS daemon, dev hot-swap, mutation, crash, and cleanup smoke passed\n");
