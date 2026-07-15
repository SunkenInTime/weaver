import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

if (process.platform !== "darwin") {
  process.stdout.write("macOS host control smoke skipped outside macOS\n");
  process.exit(0);
}

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const cli = join(repoRoot, "cli", "bin", "weaver.js");
const scratch = mkdtempSync(join(realpathSync(tmpdir()), "weaver-macos-control-smoke-"));
const environment = { ...process.env, HOME: join(scratch, "home"), WEAVER_AUTOMATION: "1" };
const dataRoot = join(environment.HOME, "Library", "Application Support", "Weaver");
const statusFile = join(dataRoot, "status.json");
const runtimeRootPrefix = `weaver-${process.getuid()}-`;
const runtimeSearchRoots = [...new Set([realpathSync(tmpdir()), realpathSync("/tmp")])];
const runtimeEntriesBefore = new Set(runtimeSearchRoots.flatMap((root) => readdirSync(root)
  .filter((name) => name.startsWith(runtimeRootPrefix))
  .map((name) => join(root, name))));
const trackedPids = new Set();

function run(arguments_, expectedStatus = 0) {
  const result = spawnSync(process.execPath, [cli, ...arguments_], { cwd: scratch, env: environment, encoding: "utf8" });
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
  throw new Error(`Timed out waiting for ${description}\nstatus:\n${JSON.stringify(status(), null, 2)}`);
}

try {
  const starts = await Promise.all([runAsync(["up"]), runAsync(["up"]), runAsync(["up"])]);
  for (const result of starts) assert.equal(result.code, 0, `concurrent up failed\n${result.stderr}`);
  const first = await waitFor("one reload-ready singleton", () => {
    const document = status();
    return document?.hostPid > 0 && alive(document.hostPid) && document;
  });
  trackedPids.add(first.hostPid);
  assert.deepEqual(first.widgets, []);
  assert.equal(first.providers.audioCaptureActive, false);
  assert.match(run(["up"]).stdout, /already running/);
  const reported = JSON.parse(run(["status", "--json"]).stdout);
  assert.equal(reported.hostPid, first.hostPid);
  assert.deepEqual(reported.widgets, []);

  process.kill(first.hostPid, "SIGKILL");
  await waitFor("deliberately crashed host", () => !alive(first.hostPid));
  run(["up"]);
  const replacement = await waitFor("replacement singleton", () => {
    const document = status();
    return document?.hostPid > 0 && document.hostPid !== first.hostPid && alive(document.hostPid) && document;
  });
  trackedPids.add(replacement.hostPid);
  assert.deepEqual(replacement.widgets, []);

  run(["down"]);
  await waitFor("acknowledged daemon shutdown", () => !alive(replacement.hostPid));
  for (const pid of trackedPids) assert.equal(alive(pid), false, `Weaver host ${pid} remained after shutdown`);
  const runtimeEntriesAfter = runtimeSearchRoots.flatMap((root) => readdirSync(root)
    .filter((name) => name.startsWith(runtimeRootPrefix))
    .map((name) => join(root, name)))
    .filter((entry) => !runtimeEntriesBefore.has(entry));
  assert.deepEqual(runtimeEntriesAfter, [], `runtime endpoint or lock remained: ${runtimeEntriesAfter.join(", ")}`);
} finally {
  spawnSync(process.execPath, [cli, "down"], { cwd: scratch, env: environment, stdio: "ignore" });
  for (const pid of trackedPids) {
    try { process.kill(pid, "SIGKILL"); }
    catch { /* Already stopped. */ }
  }
  rmSync(scratch, { recursive: true, force: true });
}

process.stdout.write("macOS host control, singleton, crash replacement, and cleanup smoke passed\n");
