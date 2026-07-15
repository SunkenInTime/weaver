import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { dirname, join, posix, resolve, win32 } from "node:path";

export interface Registration { name: string; sourcePath: string; enabled: boolean; dev?: boolean }
export interface RegistryDocument { widgets: Registration[] }
export interface WidgetStatus {
  name: string;
  pid: number;
  privateMb: number;
  cpuPercent: number;
  threads?: number;
  backend: "gpu" | "software" | "-";
  uptimeSeconds: number;
  state: "disabled" | "starting" | "running" | "backoff" | "stopped" | "source missing";
  reason: string;
}
export interface ProviderStatus {
  systemSubscribers: number;
  systemSampleCount: number;
  systemFrames: number;
  audioCaptureActive: boolean;
  audioSilent: boolean;
  audioPipeFrames: number;
  audioAvailability: "idle" | "authorization-required" | "starting" | "live" | "permission-denied" | "permission-revoked" | "device-unavailable" | "capture-failed";
  audioSubscribers: number;
  audioCaptureStarts: number;
  audioProviderFrames: number;
  audioLastError: number;
  mediaPipeFrames: number;
}
export interface StatusDocument { hostPid: number; providers: ProviderStatus; widgets: WidgetStatus[] }
export interface RegistryLockOptions { timeoutMs?: number; retryMs?: number; staleMs?: number }
export interface WeaverPathEnvironment {
  platform?: NodeJS.Platform;
  localAppData?: string;
  home?: string;
}

export function weaverDataPath(environment: WeaverPathEnvironment = {}): string {
  const platform = environment.platform ?? process.platform;
  if (platform === "win32") {
    const localAppData = environment.localAppData ?? process.env.LOCALAPPDATA;
    if (!localAppData) throw new Error("LOCALAPPDATA is not available");
    return win32.join(localAppData, "weaver");
  }
  if (platform === "darwin") {
    const home = environment.home ?? process.env.HOME;
    if (!home) throw new Error("HOME is not available");
    return posix.join(home, "Library", "Application Support", "Weaver");
  }
  throw new Error(`Weaver data paths are not supported on ${platform}`);
}

export function weaverLogsPath(environment: WeaverPathEnvironment = {}): string {
  const platform = environment.platform ?? process.platform;
  if (platform === "win32") return win32.join(weaverDataPath(environment), "logs");
  if (platform === "darwin") {
    const home = environment.home ?? process.env.HOME;
    if (!home) throw new Error("HOME is not available");
    return posix.join(home, "Library", "Logs", "Weaver");
  }
  throw new Error(`Weaver log paths are not supported on ${platform}`);
}

export function widgetsPath(environment: WeaverPathEnvironment = {}): string {
  const implementation = (environment.platform ?? process.platform) === "win32" ? win32 : posix;
  return implementation.join(weaverDataPath(environment), "widgets");
}

export function registryPath(environment: WeaverPathEnvironment = {}): string {
  const implementation = (environment.platform ?? process.platform) === "win32" ? win32 : posix;
  return implementation.join(weaverDataPath(environment), "registry.json");
}

export function statusPath(environment: WeaverPathEnvironment = {}): string {
  const implementation = (environment.platform ?? process.platform) === "win32" ? win32 : posix;
  return implementation.join(weaverDataPath(environment), "status.json");
}

export function readRegistry(path = registryPath()): RegistryDocument {
  if (!existsSync(path)) return { widgets: [] };
  const parsed = JSON.parse(readFileSync(path, "utf8")) as RegistryDocument;
  if (!parsed || !Array.isArray(parsed.widgets)) throw new Error(`Invalid Weaver registry at ${path}`);
  return { widgets: parsed.widgets.map((widget) => ({
    name: String(widget.name), sourcePath: resolve(String(widget.sourcePath)), enabled: Boolean(widget.enabled), dev: Boolean(widget.dev),
  })) };
}

export function writeRegistry(document: RegistryDocument, path = registryPath()): void {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, `${JSON.stringify(document, null, 2)}\n`, "utf8");
    renameSync(temporary, path);
  } finally {
    if (existsSync(temporary)) rmSync(temporary, { force: true });
  }
}

export async function withRegistryLock<T>(operation: () => T | Promise<T>, path = registryPath(), options: RegistryLockOptions = {}): Promise<T> {
  // A transaction may spend up to five seconds starting the host and ten
  // seconds waiting for its reload acknowledgement. Contenders must wait
  // longer than the longest valid critical section before declaring failure.
  const timeoutMs = options.timeoutMs ?? 30_000;
  const retryMs = options.retryMs ?? 25;
  const staleMs = options.staleMs ?? 5 * 60_000;
  const lockDirectory = `${path}.lock`;
  const ownerPath = join(lockDirectory, "owner.json");
  const token = randomUUID();
  const deadline = Date.now() + timeoutMs;
  mkdirSync(dirname(path), { recursive: true });
  while (true) {
    try {
      mkdirSync(lockDirectory);
      try {
        writeFileSync(ownerPath, `${JSON.stringify({ pid: process.pid, token })}\n`, "utf8");
      } catch (error) {
        rmSync(lockDirectory, { recursive: true, force: true });
        throw error;
      }
      break;
    } catch (error) {
      if (!isAlreadyExists(error)) throw error;
      if (reclaimAbandonedLock(lockDirectory, ownerPath, staleMs)) continue;
      if (Date.now() >= deadline) throw new Error(`Timed out waiting for Weaver registry lock at ${lockDirectory}`);
      await delay(retryMs);
    }
  }

  const heartbeat = setInterval(() => {
    if (!lockOwnedBy(ownerPath, token)) return;
    const now = new Date();
    try { utimesSync(lockDirectory, now, now); }
    catch { /* A later owner reclaimed the lease; release must not remove it. */ }
  }, Math.max(1_000, Math.floor(staleMs / 3)));
  heartbeat.unref();
  try {
    return await operation();
  } finally {
    clearInterval(heartbeat);
    if (lockOwnedBy(ownerPath, token)) rmSync(lockDirectory, { recursive: true, force: true });
  }
}

export function pathsEqual(left: string, right: string, platform: NodeJS.Platform = process.platform): boolean {
  return comparablePath(left, platform) === comparablePath(right, platform);
}

export function pathInside(root: string, candidate: string, platform: NodeJS.Platform = process.platform): boolean {
  const implementation = platform === "win32" ? win32 : posix;
  const relative = implementation.relative(comparablePath(root, platform), comparablePath(candidate, platform));
  return relative !== "" && relative !== ".." && !relative.startsWith(`..${implementation.sep}`) && !implementation.isAbsolute(relative);
}

export function readStatus(path = statusPath()): StatusDocument {
  return JSON.parse(readFileSync(path, "utf8")) as StatusDocument;
}

export function formatStatus(document: StatusDocument): string {
  const headings = ["NAME", "PID", "BACKEND", "PRIVATE", "CPU", "THREADS", "UPTIME", "STATE"];
  const rows = document.widgets.map((widget) => [
    widget.name,
    widget.pid === 0 ? "-" : String(widget.pid),
    widget.backend ?? "-",
    `${widget.privateMb.toFixed(1)} MB`,
    `${widget.cpuPercent.toFixed(1)}%`,
    String(widget.threads ?? 0),
    formatUptime(widget.uptimeSeconds),
    widget.reason ? `${widget.state}: ${widget.reason}` : widget.state,
  ]);
  const widths = headings.map((heading, column) => Math.max(heading.length, ...rows.map((row) => row[column].length)));
  return [headings, ...rows].map((row) => row.map((cell, column) => column === row.length - 1 ? cell : cell.padEnd(widths[column])).join("  ")).join("\n");
}

function formatUptime(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const remainder = total % 60;
  return hours > 0 ? `${hours}h${String(minutes).padStart(2, "0")}m` : minutes > 0 ? `${minutes}m${String(remainder).padStart(2, "0")}s` : `${remainder}s`;
}

function comparablePath(path: string, platform: NodeJS.Platform): string {
  const implementation = platform === "win32" ? win32 : posix;
  const normalized = implementation.resolve(path);
  return platform === "win32" ? normalized.toLowerCase() : normalized;
}

function reclaimAbandonedLock(lockDirectory: string, ownerPath: string, staleMs: number): boolean {
  let ageMs: number;
  try { ageMs = Date.now() - statSync(lockDirectory).mtimeMs; }
  catch { return true; }
  let pid: number | null = null;
  try {
    const owner = JSON.parse(readFileSync(ownerPath, "utf8")) as { pid?: unknown };
    if (typeof owner.pid === "number" && Number.isInteger(owner.pid) && owner.pid > 0) pid = owner.pid;
  } catch { /* A creator may still be publishing a fresh owner file. */ }
  if (pid !== null && processIsRunning(pid) && ageMs <= staleMs) return false;
  if (pid === null && ageMs <= staleMs) return false;
  try {
    rmSync(lockDirectory, { recursive: true, force: true });
    return true;
  } catch {
    return false;
  }
}

function processIsRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return !isNoSuchProcess(error);
  }
}

function lockOwnedBy(ownerPath: string, token: string): boolean {
  try {
    const owner = JSON.parse(readFileSync(ownerPath, "utf8")) as { token?: unknown };
    return owner.token === token;
  } catch {
    return false;
  }
}

function isAlreadyExists(error: unknown): boolean {
  return error instanceof Error && "code" in error && error.code === "EEXIST";
}

function isNoSuchProcess(error: unknown): boolean {
  return error instanceof Error && "code" in error && error.code === "ESRCH";
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds));
}
