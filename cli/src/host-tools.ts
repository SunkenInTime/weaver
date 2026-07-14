import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

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
export interface StatusDocument { hostPid: number; widgets: WidgetStatus[] }

export function registryPath(localAppData = process.env.LOCALAPPDATA): string {
  if (!localAppData) throw new Error("LOCALAPPDATA is not available");
  return join(localAppData, "weaver", "registry.json");
}

export function statusPath(localAppData = process.env.LOCALAPPDATA): string {
  if (!localAppData) throw new Error("LOCALAPPDATA is not available");
  return join(localAppData, "weaver", "status.json");
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
  const temporary = `${path}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(document, null, 2)}\n`, "utf8");
  renameSync(temporary, path);
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
