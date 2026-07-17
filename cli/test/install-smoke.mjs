import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const cli = join(repoRoot, "cli", "bin", "weaver.js");
const tempRoot = realpathSync(tmpdir());
const scratch = mkdtempSync(join(tempRoot, "weaver-install-smoke-"));
const environment = { ...process.env, WEAVER_AUTOMATION: "1" };
const expectedArchiveSha256 = "d4a517dac1e6355bdf6d75e5e828470ec657a82dbfdfcec8efd2903eb88d4bf4";

if (process.platform === "win32") {
  environment.LOCALAPPDATA = join(scratch, "local");
} else if (process.platform === "darwin") {
  environment.HOME = join(scratch, "home");
} else {
  throw new Error(`Portable install smoke does not support ${process.platform}`);
}

const dataRoot = process.platform === "win32"
  ? join(environment.LOCALAPPDATA, "weaver")
  : join(environment.HOME, "Library", "Application Support", "Weaver");
const logsRoot = process.platform === "win32"
  ? join(dataRoot, "logs")
  : join(environment.HOME, "Library", "Logs", "Weaver");
const widgetsRoot = join(dataRoot, "widgets");
const registryPath = join(dataRoot, "registry.json");
let logFollower;

function run(arguments_, extraEnvironment = {}, expectedStatus = 0) {
  const result = spawnSync(process.execPath, [cli, ...arguments_], {
    cwd: scratch,
    env: { ...environment, ...extraEnvironment },
    encoding: "utf8",
  });
  assert.equal(result.status, expectedStatus, `weaver ${arguments_.join(" ")} exited ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  return result;
}

function registry() {
  return JSON.parse(readFileSync(registryPath, "utf8"));
}

function assertOwned(path) {
  const relation = relative(resolve(widgetsRoot), resolve(path));
  assert.equal(isAbsolute(relation) || relation === "" || relation === ".." || relation.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`), false, `install escaped its owned root: ${path}`);
  assert.equal(existsSync(join(path, "weave.json")), true, `owned install is missing weave.json: ${path}`);
  assert.equal(existsSync(join(path, "dist", "bundle.js")), true, `owned install is missing its runtime bundle: ${path}`);
}

function ownedEntries() {
  return existsSync(widgetsRoot) ? readdirSync(widgetsRoot).sort() : [];
}

function waitForOutput(child, token, timeoutMs = 5_000) {
  return new Promise((resolvePromise, rejectPromise) => {
    let output = "";
    const timeout = setTimeout(() => rejectPromise(new Error(`Timed out waiting for log follower token ${token}\noutput:\n${output}`)), timeoutMs);
    child.stdout.on("data", (bytes) => {
      output += bytes;
      if (!output.includes(token)) return;
      clearTimeout(timeout);
      resolvePromise(output);
    });
    child.once("exit", (code, signal) => {
      if (output.includes(token)) return;
      clearTimeout(timeout);
      rejectPromise(new Error(`Log follower exited before ${token}: ${JSON.stringify({ code, signal })}\noutput:\n${output}`));
    });
  });
}

try {
  run(["init", "clock"]);
  run(["check", "clock"]);
  run(["bundle", "clock"]);
  run(["pack", "clock"]);
  const artifact = join(scratch, "clock.weave");
  const archiveHash = createHash("sha256").update(readFileSync(artifact)).digest("hex");
  assert.equal(archiveHash, expectedArchiveSha256, "identical starter source must pack to identical .weave bytes on Windows and macOS");

  const inspected = run(["inspect", "clock.weave"]);
  assert.match(inspected.stdout, /^Name: Clock$/m);
  assert.match(inspected.stdout, /^Format: \.weave v1$/m);
  assert.match(inspected.stdout, /^Readable source: 1 files, \d+ bytes$/m);

  run(["install", "clock.weave"]);
  assert.equal(registry().widgets.length, 1);
  const first = resolve(registry().widgets[0].sourcePath);
  assertOwned(first);

  const beforeFailedReplacement = ownedEntries();
  const refused = run(["install", "clock.weave"], { WEAVER_AUTOMATION_FAIL_INSTALL_AFTER_PUBLISH: "1" }, 1);
  assert.match(refused.stderr, /Automation refused the install after publishing its owned source/);
  assert.equal(resolve(registry().widgets[0].sourcePath), first, "failed replacement changed the authoritative registration");
  assert.deepEqual(ownedEntries(), beforeFailedReplacement, "failed replacement left a stage or published directory behind");

  const abandonedStage = join(widgetsRoot, ".install-0-abandoned");
  mkdirSync(abandonedStage);
  const old = new Date(Date.now() - 10 * 60_000);
  utimesSync(abandonedStage, old, old);
  run(["install", "clock.weave"]);
  assert.equal(existsSync(abandonedStage), false, "a later registry mutation did not collect an abandoned install stage");
  const second = resolve(registry().widgets[0].sourcePath);
  assert.notEqual(second, first, "replacement did not publish a new immutable owned version");
  assert.equal(existsSync(first), false, "replacement did not collect the old owned version");
  assertOwned(second);

  mkdirSync(logsRoot, { recursive: true });
  const logToken = `portable-log-${randomUUID()}`;
  writeFileSync(join(logsRoot, "Clock.log"), `${logToken}\n`, "utf8");
  assert.match(run(["logs", "Clock"]).stdout, new RegExp(logToken));
  logFollower = spawn(process.execPath, [cli, "logs", "Clock", "--follow"], {
    cwd: scratch,
    env: environment,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const followerExitPromise = new Promise((resolvePromise) => logFollower.once("exit", (code, signal) => resolvePromise({ code, signal })));
  await waitForOutput(logFollower, logToken);
  const followToken = `follow-${randomUUID()}`;
  const followOutputPromise = waitForOutput(logFollower, followToken);
  appendFileSync(join(logsRoot, "Clock.log"), `${followToken}\n`, "utf8");
  await followOutputPromise;
  logFollower.kill("SIGINT");
  const followerExit = await followerExitPromise;
  if (process.platform === "win32") {
    // Node emulates child signals with TerminateProcess on Windows, so a
    // programmatic SIGINT is reported as the terminating signal rather than a
    // process exit code. Reaching the exit event proves the follower stopped;
    // the preceding assertions prove it followed appended data.
    assert.deepEqual(followerExit, { code: null, signal: "SIGINT" }, `logs --follow did not stop after SIGINT: ${JSON.stringify(followerExit)}`);
  } else {
    assert.equal(followerExit.code, 0, `logs --follow did not stop cleanly: ${JSON.stringify(followerExit)}`);
  }
  logFollower = undefined;

  run(["uninstall", "Clock"]);
  assert.equal(existsSync(second), false, "uninstall did not remove archive-owned source");

  run(["install", "clock"]);
  const directoryOwned = resolve(registry().widgets[0].sourcePath);
  assert.notEqual(directoryOwned, resolve(scratch, "clock"), "directory install registered the developer workspace by reference");
  assertOwned(directoryOwned);
  run(["uninstall", "Clock"]);
  assert.equal(existsSync(directoryOwned), false, "uninstall did not remove directory-owned source");
  assert.equal(registry().widgets.length, 0, "registry is not empty after uninstall");
  assert.deepEqual(ownedEntries(), [], "owned widget root retains abandoned install content");

  if (process.platform === "darwin") {
    const status = JSON.parse(run(["status", "--json"]).stdout);
    assert.equal(typeof status.hostPid, "number");
    assert.deepEqual(status.widgets, [], "uninstall acknowledgement left a Widget in host status");
    assert.match(run(["up"]).stdout, /already running/);
  }
} finally {
  if (logFollower && logFollower.exitCode === null && logFollower.signalCode === null) logFollower.kill("SIGKILL");
  if (process.platform === "win32" || process.platform === "darwin") spawnSync(process.execPath, [cli, "down"], { cwd: scratch, env: environment, stdio: "ignore" });
  const resolvedScratch = resolve(scratch);
  const relation = relative(tempRoot, resolvedScratch);
  if (isAbsolute(relation) || relation === "" || relation === ".." || relation.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`)) {
    throw new Error(`Refusing cleanup outside the temporary root: ${resolvedScratch}`);
  }
  rmSync(resolvedScratch, { recursive: true, force: true });
}

process.stdout.write(`Portable ${process.platform} install and artifact smoke passed\n`);
