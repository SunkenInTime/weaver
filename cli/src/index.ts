import { spawn, spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { closeSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, readSync, readdirSync, realpathSync, renameSync, rmSync, statSync, watch, writeFileSync } from "node:fs";
import type { Dirent } from "node:fs";
import { basename, dirname, extname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import ts from "typescript";
import { compileClass, UtilityError } from "../../sdk/src/class-compiler.js";
import { originDeclared, originHost, originNotDeclaredMessage, validOriginHost } from "./origin.js";
import { formatStatus, pathInside, pathsEqual, readRegistry, readStatus, statusPath, weaverLogsPath, widgetsPath, withRegistryLock, writeRegistry, type RegistryDocument } from "./host-tools.js";
import { extractWeave, isWeaveSourceEntryIncluded, MAX_WEAVE_ARCHIVE_BYTES, openWeave, packWeave, type DeclaredSurface, type OpenedWeave, type WeaveManifest } from "./weave.js";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const sdkRoot = join(repoRoot, "sdk", "src");
const executableSuffix = process.platform === "win32" ? ".exe" : "";
const runtimeExecutable = join(repoRoot, "runtime", "zig-out", "bin", `weaver-widget${executableSuffix}`);
const hostExecutable = process.platform === "darwin"
  ? join(repoRoot, "host", "zig-out", "Weaverd.app", "Contents", "MacOS", "weaverd")
  : join(repoRoot, "host", "zig-out", "bin", `weaverd${executableSuffix}`);

class WeaverFailure extends Error {
  constructor(readonly details: string[]) {
    super(details.join("\n"));
    this.name = "WeaverFailure";
  }
}

interface SourceProject {
  directory: string;
  sourcePath: string;
  source: string;
  sourceFile: ts.SourceFile;
  config: WidgetConfigData;
}

interface WidgetConfigData {
  name: string;
  size: [number, number];
  anchor?: {
    monitor?: "primary";
    corner: "top-left" | "top-right" | "bottom-left" | "bottom-right";
    offset?: [number, number];
  };
  layer?: "desktop" | "normal" | "topmost";
  clickThrough?: boolean;
  subscribe?: ("time" | "cpu" | "memory" | "audio" | "media")[];
  origins?: string[];
  capabilities?: never[];
}

interface RuntimeManifest {
  name: string;
  size: [number, number];
  anchor: NonNullable<WidgetConfigData["anchor"]>;
  layer: "desktop" | "normal" | "topmost";
  clickThrough: boolean;
  transparent: true;
  origins: string[];
  subscribe: ("time" | "cpu" | "memory" | "audio" | "media")[];
  renderBackend: "gpu" | "software";
}

interface BundleResult { project: SourceProject; manifest: RuntimeManifest }

async function main(argv: string[]): Promise<void> {
  const [command, argument, ...rest] = argv;
  const directoryCommands = ["init", "check", "bundle", "dev", "pack"];
  const noArgumentCommands = ["up", "down"];
  if (command === "logs") {
    if (!argument || rest.length > 1 || (rest.length === 1 && rest[0] !== "--follow")) throw new WeaverFailure(["Usage: weaver logs <name> [--follow]"]);
    return showLogs(argument, rest[0] === "--follow");
  }
  if (command === "inspect") {
    if (!argument || rest.length > 0) throw new WeaverFailure(["Usage: weaver inspect <file.weave>"]);
    return inspectWidget(resolve(argument));
  }
  if (command === "audio") {
    if (argument !== "authorize" || rest.length > 0) throw new WeaverFailure(["Usage: weaver audio authorize"]);
    return authorizeAudio();
  }
  if (!command || rest.length > 0 || (directoryCommands.includes(command) && !argument) || (noArgumentCommands.includes(command) && argument) || (command === "install" && !argument) || (command === "uninstall" && !argument) || (command === "status" && argument !== undefined && argument !== "--json") || ![...directoryCommands, ...noArgumentCommands, "install", "uninstall", "status"].includes(command)) {
    throw new WeaverFailure(["Usage: weaver <init|check|bundle|dev|pack> <name-or-directory> | inspect <file.weave> | install <directory-or-file.weave> | uninstall <name> | up | down | status [--json] | logs <name> [--follow] | audio authorize"]);
  }
  if (command === "up") return upHost(true);
  if (command === "down") return downHost();
  if (command === "status") return showStatus(argument === "--json");
  if (command === "uninstall") return uninstallWidget(argument!);
  if (command === "init") return initWidget(argument!);
  const target = resolve(argument!);
  if (command === "install") return installWidget(target);
  const directory = target;
  if (command === "check") {
    checkWidget(directory);
    process.stdout.write(`weaver check passed: ${directory}\n`);
    return;
  }
  if (command === "bundle") {
    await bundleWidget(directory);
    process.stdout.write(`weaver bundle wrote ${join(directory, "dist")}\n`);
    return;
  }
  if (command === "pack") return packWidget(directory);
  await devWidget(directory);
}

function initWidget(name: string): void {
  if (!/^[a-zA-Z][a-zA-Z0-9_-]*$/.test(name)) {
    throw new WeaverFailure([`Invalid widget name "${name}". Use letters, numbers, hyphens, or underscores and start with a letter.`]);
  }
  const directory = resolve(name);
  if (existsSync(directory)) throw new WeaverFailure([`Cannot initialize ${directory}: the path already exists.`]);
  mkdirSync(directory, { recursive: true });
  const displayName = name.replace(/[-_]+/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
  writeFileSync(join(directory, "widget.tsx"), starterSource(displayName), "utf8");
  writeAuthoringTsconfig(directory);
  process.stdout.write(`Initialized ${directory}\nNext: weaver check ${name}\n`);
}

function writeAuthoringTsconfig(directory: string): void {
  writeFileSync(join(directory, "tsconfig.json"), `${JSON.stringify({
    compilerOptions: {
      target: "ES2020",
      module: "ESNext",
      moduleResolution: "Bundler",
      strict: true,
      noEmit: true,
      skipLibCheck: true,
      jsx: "react-jsx",
      jsxImportSource: "@weaver/sdk",
      types: [],
      // Widgets scaffold anywhere on disk, not just inside the Weaver
      // monorepo, so the SDK types must be reachable by absolute path.
      baseUrl: ".",
      paths: {
        "@weaver/sdk": [join(repoRoot, "sdk", "index.d.ts").replace(/\\/g, "/")],
        "@weaver/sdk/jsx-runtime": [join(repoRoot, "sdk", "jsx-runtime.d.ts").replace(/\\/g, "/")],
      },
    },
    include: ["widget.tsx"],
  }, null, 2)}\n`, "utf8");
}

function starterSource(name: string): string {
  return `import { useProvider, widget } from "@weaver/sdk";

export default widget({
  name: ${JSON.stringify(name)},
  size: [240, 110],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  return (
    <column class="p-4 gap-1 bg-[#11141c]/86 rounded-2xl">
      <row class="items-baseline gap-2">
        <text class="text-3xl font-light">{time.hh}:{time.mm}</text>
        <text class="text-sm opacity-70">{time.ss}</text>
      </row>
      <text class="text-xs opacity-60">{time.weekday}, {time.month} {time.day}</text>
    </column>
  );
});
`;
}

function checkWidget(directory: string): SourceProject {
  const project = loadProject(directory);
  const errors = validateSource(project);
  const tsc = runTypeScript(directory);
  if (tsc) errors.push(...tsc.split(/\r?\n/).filter(Boolean).map((line) => `TypeScript: ${line}`));
  if (errors.length > 0) throw new WeaverFailure(errors);
  return project;
}

async function bundleWidget(directory: string): Promise<BundleResult> {
  const project = checkWidget(directory);
  const outputDirectory = join(directory, "dist");
  mkdirSync(outputDirectory, { recursive: true });
  copyWidgetAssets(directory, outputDirectory);
  const bundle = await compileWidgetBundle(project, join(outputDirectory, "bundle.js"));
  writeAtomic(join(outputDirectory, "bundle.js"), bundle);
  const manifest: RuntimeManifest = {
    name: project.config.name,
    size: project.config.size,
    anchor: project.config.anchor ?? { monitor: "primary", corner: "top-right", offset: [24, 24] },
    layer: project.config.layer ?? "desktop",
    clickThrough: project.config.clickThrough ?? false,
    transparent: true,
    origins: project.config.origins ?? [],
    subscribe: project.config.subscribe ?? [],
    renderBackend: sourceUsesCanvas(project.sourceFile) ? "gpu" : "software",
  };
  writeAtomic(join(outputDirectory, "widget.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  return { project, manifest };
}

async function compileWidgetBundle(project: SourceProject, outfile: string): Promise<Uint8Array> {
  const built = await build({
    entryPoints: [project.sourcePath],
    outfile,
    bundle: true,
    format: "iife",
    platform: "neutral",
    target: "es2020",
    jsx: "automatic",
    jsxImportSource: "@weaver/sdk",
    legalComments: "none",
    minify: true,
    plugins: [weaverResolutionPlugin(project.directory)],
    logLevel: "silent",
    write: false,
  });
  return built.outputFiles[0].contents;
}

async function packWidget(directory: string): Promise<void> {
  const project = checkWidget(directory);
  await compileWidgetBundle(project, join(directory, "bundle.js"));
  const packed = packWeave(directory, project.config.name, declaredSurface(project.config));
  const output = resolve(dirname(directory), `${basename(directory)}.weave`);
  writeAtomic(output, packed.bytes);
  process.stdout.write(`Packed ${project.config.name}\nArtifact: ${packed.manifest.artifactId}\nSource: ${packed.manifest.sourceId}\nWrote ${output}\n`);
}

function inspectWidget(input: string): void {
  if (!existsSync(input)) throw new WeaverFailure([`Archive does not exist: ${input}`]);
  const inputStat = statSync(input);
  if (!inputStat.isFile() || extname(input).toLowerCase() !== ".weave") {
    throw new WeaverFailure([`Inspect expects a regular .weave file: ${input}`]);
  }
  if (inputStat.size > MAX_WEAVE_ARCHIVE_BYTES) {
    throw new WeaverFailure([`Archive exceeds the ${MAX_WEAVE_ARCHIVE_BYTES / (1024 * 1024)} MiB .weave limit: ${input}`]);
  }
  let opened: OpenedWeave;
  try { opened = openWeave(readFileSync(input)); }
  catch (error) { throw new WeaverFailure([`Cannot open ${input}: ${errorMessage(error)}`]); }
  const sourceBytes = [...opened.files.values()].reduce((total, bytes) => total + bytes.length, 0);
  printArtifactAudit(opened.manifest, opened.files.size, sourceBytes);
}

function declaredSurface(config: WidgetConfigData): DeclaredSurface {
  return {
    providers: [...(config.subscribe ?? [])],
    origins: [...(config.origins ?? [])],
    capabilities: [...(config.capabilities ?? [])],
  };
}

function writeAtomic(path: string, data: string | Uint8Array): void {
  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, data);
    renameSync(temporary, path);
  } finally {
    if (existsSync(temporary)) rmSync(temporary, { force: true });
  }
}

function sourceUsesCanvas(sourceFile: ts.SourceFile): boolean {
  let found = false;
  const visit = (node: ts.Node): void => {
    if (ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) {
      if (node.tagName.getText(sourceFile) === "canvas") found = true;
    }
    if (!found) ts.forEachChild(node, visit);
  };
  visit(sourceFile);
  return found;
}

/// `dist` is the runtime artifact, so local image paths must mean the same
/// thing after install as they did beside widget.tsx. Copy every ordinary
/// widget-owned file recursively while excluding authoring/build outputs;
/// dynamic local `src` expressions then remain valid without a magic asset
/// directory or source-tree dependency.
function copyWidgetAssets(sourceDirectory: string, outputDirectory: string, root = true): void {
  for (const entry of readdirSync(sourceDirectory, { withFileTypes: true })) {
    if (!isWeaveSourceEntryIncluded(entry.name, root) || (root && entry.name === "widget.tsx")) continue;
    const source = join(sourceDirectory, entry.name);
    const destination = join(outputDirectory, entry.name);
    if (entry.isDirectory()) {
      mkdirSync(destination, { recursive: true });
      copyWidgetAssets(source, destination, false);
    } else if (entry.isFile()) {
      copyFileSync(source, destination);
    } else {
      throw new WeaverFailure([`Local widget asset ${source} must be a regular file or directory; links are not bundled.`]);
    }
  }
}

function weaverResolutionPlugin(sourceRoot: string): import("esbuild").Plugin {
  // esbuild resolves importer directories through the filesystem. On macOS,
  // tmpdir() commonly returns /var/... while the resolver reports the same
  // directory through its canonical /private/var/... path. Compare against
  // the canonical root so a real child is not mistaken for an escape.
  const canonicalSourceRoot = realpathSync(sourceRoot);
  return {
    name: "weaver-import-wall",
    setup(pluginBuild) {
      pluginBuild.onResolve({ filter: /^@weaver\/sdk$/ }, () => ({ path: join(sdkRoot, "index.ts") }));
      pluginBuild.onResolve({ filter: /^@weaver\/sdk\/jsx-runtime$/ }, () => ({ path: join(sdkRoot, "jsx-runtime.ts") }));
      pluginBuild.onResolve({ filter: /.*/ }, (args) => {
        if (args.kind === "entry-point") return null;
        if (args.importer && (pathsEqual(args.importer, sdkRoot) || pathInside(sdkRoot, args.importer))) return null;
        if (isAbsolute(args.path)) {
          return { errors: [{ text: `Absolute import "${args.path}" is not portable; use a relative path inside the widget source root` }] };
        }
        if (!args.path.startsWith(".")) {
          return { errors: [{ text: `External import "${args.path}" is not allowed in a widget. Only @weaver/sdk imports are bundled.` }] };
        }
        const candidate = resolve(args.resolveDir, args.path);
        if (!pathsEqual(candidate, canonicalSourceRoot) && !pathInside(canonicalSourceRoot, candidate)) {
          return { errors: [{ text: `Import "${args.path}" escapes the widget source root ${sourceRoot}` }] };
        }
        return null;
      });
    },
  };
}

async function devWidget(directory: string): Promise<void> {
  assertHostLifecycleAvailable("dev");
  assertRuntimeBuilt();
  await upHost(false);
  const initial = await bundleWidget(directory);
  const project = initial.project;
  let activeManifest = initial.manifest;
  let existing: RegistryDocument["widgets"][number] | undefined;
  const startupWarnings: string[] = [];
  await withRegistryLock(() => {
    const before = readRegistry();
    existing = before.widgets.find((widget) => widget.name === project.config.name);
    if (existing && !pathsEqual(existing.sourcePath, directory)) {
      throw new WeaverFailure([`Widget name "${project.config.name}" is already registered from ${existing.sourcePath}`]);
    }
    const nextRegistry = { widgets: [...before.widgets.filter((widget) => widget.name !== project.config.name), {
      name: project.config.name, sourcePath: directory, enabled: true, dev: true,
    }] };
    writeRegistry(nextRegistry);
    try { signalHost("--signal-reload"); }
    catch (error) {
      writeRegistry(before);
      try { signalHost("--signal-reload"); }
      catch { /* Preserve the reload failure after restoring the authoritative registry. */ }
      throw error;
    }
    startupWarnings.push(...sweepUnregisteredInstallDirectories(nextRegistry));
  });
  const temporaryRegistration = !existing;
  const logFollower = followLogFile(project.config.name, true);
  printCleanupWarnings(startupWarnings);
  let rebuilding = false;
  let pending = false;
  let debounce: NodeJS.Timeout | undefined;
  const rebuild = async (): Promise<void> => {
    if (rebuilding) {
      pending = true;
      return;
    }
    rebuilding = true;
    try {
      const next = await bundleWidget(directory);
      const configChanged = JSON.stringify(next.manifest) !== JSON.stringify(activeManifest);
      activeManifest = next.manifest;
      if (configChanged) {
        signalHost("--signal-reload");
        process.stdout.write("weaver dev restarted widget: window config changed\n");
      } else {
        process.stdout.write("weaver dev bundle ready for in-place hot swap\n");
      }
    } catch (error) {
      printFailure(error);
    } finally {
      rebuilding = false;
      if (pending) {
        pending = false;
        void rebuild();
      }
    }
  };
  const watcher = watch(join(directory, "widget.tsx"), () => {
    clearTimeout(debounce);
    debounce = setTimeout(() => void rebuild(), 100);
  });
  process.stdout.write(`weaver dev watching ${join(directory, "widget.tsx")}\n`);
  await new Promise<void>((resolvePromise) => {
    let stopping = false;
    const stop = (): void => {
      if (stopping) return;
      stopping = true;
      watcher.close();
      logFollower.stop();
      clearTimeout(debounce);
      void (async () => {
        try {
          const shutdownWarnings: string[] = [];
          await withRegistryLock(() => {
            const current = readRegistry();
            const registration = current.widgets.find((widget) => widget.name === project.config.name);
            if (registration?.dev && pathsEqual(registration.sourcePath, directory)) {
              const widgets = current.widgets.filter((widget) => widget.name !== project.config.name);
              if (!temporaryRegistration && existing) widgets.push(existing);
              const nextRegistry = { widgets };
              writeRegistry(nextRegistry);
              try { signalHost("--signal-reload"); }
              catch (error) {
                writeRegistry(current);
                try { signalHost("--signal-reload"); }
                catch { /* Preserve the reload failure after restoring the authoritative registry. */ }
                throw error;
              }
              shutdownWarnings.push(...sweepUnregisteredInstallDirectories(nextRegistry));
            } else {
              shutdownWarnings.push(...sweepUnregisteredInstallDirectories(current));
            }
          });
          printCleanupWarnings(shutdownWarnings);
        } catch (error) {
          printFailure(error);
        } finally {
          resolvePromise();
        }
      })();
    };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
  });
}

function logPath(name: string): string {
  const safe = name.replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").replace(/[. ]+$/g, "_") || "widget";
  return join(weaverLogsPath(), `${safe}.log`);
}

function showLogs(name: string, follow: boolean): Promise<void> | void {
  const path = logPath(name);
  const oldPath = `${path}.old`;
  const text = [oldPath, path].filter(existsSync).map((file) => readFileSync(file, "utf8")).join("");
  const lines = text.split(/\r?\n/).filter((line) => line.length > 0).slice(-200);
  if (lines.length > 0) process.stdout.write(`${lines.join("\n")}\n`);
  if (!follow) return;
  const follower = followLogFile(name, true);
  return new Promise<void>((resolvePromise) => {
    const stop = (): void => { follower.stop(); resolvePromise(); };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
  });
}

function followLogFile(name: string, startAtEnd: boolean): { stop(): void } {
  const path = logPath(name);
  let offset = startAtEnd && existsSync(path) ? statSync(path).size : 0;
  const poll = (): void => {
    if (!existsSync(path)) return;
    const size = statSync(path).size;
    if (size < offset) offset = 0;
    if (size === offset) return;
    const length = size - offset;
    const bytes = Buffer.alloc(length);
    const descriptor = openSync(path, "r");
    try { readSync(descriptor, bytes, 0, length, offset); }
    finally { closeSync(descriptor); }
    offset = size;
    process.stdout.write(bytes);
  };
  const timer = setInterval(poll, 100);
  return { stop(): void { clearInterval(timer); poll(); } };
}

async function installWidget(input: string): Promise<void> {
  assertRuntimeBuilt();
  if (!existsSync(input)) throw new WeaverFailure([`Install source does not exist: ${input}`]);
  let opened: OpenedWeave;
  try {
    const inputStat = statSync(input);
    if (inputStat.isDirectory()) {
      const sourceProject = checkWidget(input);
      opened = openWeave(packWeave(input, sourceProject.config.name, declaredSurface(sourceProject.config)).bytes);
    } else {
      if (!inputStat.isFile()) throw new WeaverFailure([`Install source must be a regular directory or file: ${input}`]);
      if (extname(input).toLowerCase() !== ".weave") throw new WeaverFailure([`Install expects a widget directory or .weave file: ${input}`]);
      if (inputStat.size > MAX_WEAVE_ARCHIVE_BYTES) throw new WeaverFailure([`Archive exceeds the ${MAX_WEAVE_ARCHIVE_BYTES / (1024 * 1024)} MiB .weave limit: ${input}`]);
      opened = openWeave(readFileSync(input));
    }
  } catch (error) {
    if (error instanceof WeaverFailure) throw error;
    throw new WeaverFailure([`Cannot open ${input}: ${error instanceof Error ? error.message : String(error)}`]);
  }

  const root = widgetsPath();
  mkdirSync(root, { recursive: true });
  const destination = join(root, installDirectoryName(opened.manifest));
  const stage = mkdtempSync(join(root, `.install-${process.pid}-`));
  let stageExists = true;
  let finalExists = false;
  const cleanupWarnings: string[] = [];
  try {
    extractWeave(opened, stage);
    writeAuthoringTsconfig(stage);
    const project = checkWidget(stage);
    assertManifestMatchesSource(opened.manifest, project.config);
    await bundleWidget(stage);
    await withRegistryLock(async () => {
      const originalRegistry = readRegistry();
      if (hostLifecycleAvailable() && hostRunning()) assertHostReloadReady();
      const conflicting = originalRegistry.widgets.find((widget) => widget.name === project.config.name && !ownedInstallPath(widget.sourcePath));
      if (conflicting) {
        throw new WeaverFailure([`Widget name "${project.config.name}" is already registered from ${conflicting.sourcePath}`, `Run "weaver uninstall ${project.config.name}" before replacing a source-linked installation.`]);
      }
      if (hostLifecycleAvailable()) await upHost(false);
      renameSync(stage, destination);
      stageExists = false;
      finalExists = true;
      const nextRegistry = { widgets: [...originalRegistry.widgets.filter((widget) => widget.name !== project.config.name), {
        name: project.config.name, sourcePath: destination, enabled: true,
      }] };
      printInstallAudit(opened.manifest);
      if (process.env.WEAVER_AUTOMATION === "1" && process.env.WEAVER_AUTOMATION_FAIL_INSTALL_AFTER_PUBLISH === "1") {
        throw new WeaverFailure(["Automation refused the install after publishing its owned source."]);
      }
      writeRegistry(nextRegistry);
      if (hostLifecycleAvailable()) {
        try {
          signalHost("--signal-reload");
        } catch (error) {
          writeRegistry(originalRegistry);
          if (hostRunning()) {
            try { signalHost("--signal-reload"); }
            catch { /* Preserve the original failure; the registry is authoritative on the next reload. */ }
          }
          throw error;
        }
      }
      cleanupWarnings.push(...sweepUnregisteredInstallDirectories(nextRegistry));
    });
    finalExists = false;
    process.stdout.write(`Installed ${project.config.name}\nSource: ${destination}\n`);
  } finally {
    if (stageExists && existsSync(stage)) rmSync(stage, { recursive: true, force: true });
    if (finalExists) await removeUnregisteredInstall(destination);
    printCleanupWarnings(cleanupWarnings);
  }
}

function assertManifestMatchesSource(manifest: WeaveManifest, config: WidgetConfigData): void {
  if (manifest.name !== config.name) throw new WeaverFailure([`weave.json names "${manifest.name}" but source declares "${config.name}"`]);
  const actual = declaredSurface(config);
  for (const field of ["providers", "origins", "capabilities"] as const) {
    if (JSON.stringify(manifest.declared[field]) !== JSON.stringify(actual[field])) {
      throw new WeaverFailure([`weave.json declared.${field} does not match widget.tsx`]);
    }
  }
}

function printInstallAudit(manifest: WeaveManifest): void {
  const author = manifest.provenance.author === null ? "Author: local/unsigned" : `Claimed author (unverified): ${manifest.provenance.author}`;
  const providers = manifest.declared.providers.length > 0 ? manifest.declared.providers.join(", ") : "none";
  const origins = manifest.declared.origins.length > 0 ? manifest.declared.origins.join(", ") : "none";
  const capabilities = manifest.declared.capabilities.length > 0 ? manifest.declared.capabilities.join(", ") : "none";
  process.stdout.write(`Reviewing ${manifest.name}\n${author}\nArtifact: ${manifest.artifactId}\nSource: readable · ${manifest.sourceId}\nProviders: ${providers}\nNetwork origins: ${origins}\nSystem capabilities: ${capabilities}\n`);
}

function printArtifactAudit(manifest: WeaveManifest, sourceFiles: number, sourceBytes: number): void {
  const author = manifest.provenance.author === null ? "local/unsigned" : `${manifest.provenance.author} (claimed, unverified)`;
  const list = (values: string[]): string => values.length > 0 ? values.join(", ") : "none";
  process.stdout.write(`Name: ${manifest.name}\nFormat: .weave v${manifest.formatVersion}\nArtifact: ${manifest.artifactId}\nSource: ${manifest.sourceId}\nAuthor: ${author}\nLineage root: ${manifest.lineage.root}\nLineage parent: ${manifest.lineage.parent ?? "none"}\nProviders: ${list(manifest.declared.providers)}\nNetwork origins: ${list(manifest.declared.origins)}\nSystem capabilities: ${list(manifest.declared.capabilities)}\nReadable source: ${sourceFiles} files, ${sourceBytes} bytes\n`);
}

function installDirectoryName(manifest: WeaveManifest): string {
  const slug = manifest.name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 48) || "widget";
  const nameHash = createHash("sha256").update(manifest.name, "utf8").digest("hex").slice(0, 12);
  const artifactHash = manifest.artifactId.slice("sha256:".length, "sha256:".length + 12);
  return `${slug}-${nameHash}-${artifactHash}-${randomUUID()}`;
}

function ownedInstallPath(path: string): boolean {
  const root = resolve(widgetsPath());
  const candidate = resolve(path);
  return pathInside(root, candidate) && existsSync(join(candidate, "weave.json"));
}

async function uninstallWidget(name: string): Promise<void> {
  const warnings: string[] = [];
  let installed = false;
  await withRegistryLock(() => {
    const document = readRegistry();
    const registration = document.widgets.find((widget) => widget.name === name);
    if (!registration) {
      const running = hostLifecycleAvailable() && hostRunning();
      if (running) {
        assertHostReloadReady();
        signalHost("--signal-reload");
      }
      warnings.push(...sweepUnregisteredInstallDirectories(document));
      return;
    }
    installed = true;
    const nextRegistry = { widgets: document.widgets.filter((widget) => widget.name !== name) };
    const running = hostLifecycleAvailable() && hostRunning();
    if (running) assertHostReloadReady();
    writeRegistry(nextRegistry);
    if (running) {
      try { signalHost("--signal-reload"); }
      catch (error) {
        writeRegistry(document);
        try { signalHost("--signal-reload"); }
        catch { /* Preserve the reload failure after restoring the authoritative registry. */ }
        throw error;
      }
    }
    warnings.push(...sweepUnregisteredInstallDirectories(nextRegistry));
  });
  printCleanupWarnings(warnings);
  if (!installed) throw new WeaverFailure([`Widget "${name}" is not installed.`]);
  process.stdout.write(`Uninstalled ${name}\n`);
}

function sweepUnregisteredInstallDirectories(document: RegistryDocument): string[] {
  const root = widgetsPath();
  if (!existsSync(root)) return [];
  const warnings: string[] = [];
  const registered = document.widgets.map((widget) => widget.sourcePath);
  let entries: Dirent[];
  try { entries = readdirSync(root, { withFileTypes: true }); }
  catch (error) { return [`Could not inspect owned widget sources at ${root}: ${errorMessage(error)}. A later registry mutation will retry cleanup.`]; }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const candidate = join(root, entry.name);
    if (entry.name.startsWith(".install-")) {
      if (!abandonedInstallStage(candidate, entry.name)) continue;
      try { rmSync(candidate, { recursive: true, force: true }); }
      catch (error) { warnings.push(`Could not remove abandoned install stage at ${candidate}: ${errorMessage(error)}. A later registry mutation will retry cleanup.`); }
      continue;
    }
    if (registered.some((path) => pathsEqual(path, candidate)) || !existsSync(join(candidate, "weave.json"))) continue;
    try { rmSync(candidate, { recursive: true, force: true }); }
    catch (error) { warnings.push(`Could not remove unregistered owned source at ${candidate}: ${errorMessage(error)}. A later registry mutation will retry cleanup.`); }
  }
  return warnings;
}

function abandonedInstallStage(path: string, name: string): boolean {
  const staleMs = 5 * 60_000;
  let ageMs: number;
  try { ageMs = Date.now() - statSync(path).mtimeMs; }
  catch { return false; }
  if (ageMs <= staleMs) return false;
  const pid = /^\.install-(\d+)-/.exec(name)?.[1];
  if (!pid) return true;
  const ownerPid = Number(pid);
  if (!Number.isSafeInteger(ownerPid) || ownerPid <= 0) return true;
  try {
    process.kill(ownerPid, 0);
    return false;
  } catch (error) {
    return error instanceof Error && "code" in error && error.code !== "EPERM";
  }
}

async function removeUnregisteredInstall(candidate: string): Promise<void> {
  const warnings: string[] = [];
  try {
    await withRegistryLock(() => {
      const document = readRegistry();
      if (!document.widgets.some((widget) => pathsEqual(widget.sourcePath, candidate)) && existsSync(candidate)) {
        const running = hostLifecycleAvailable() && hostRunning();
        if (running) {
          assertHostReloadReady();
          signalHost("--signal-reload");
        }
        try { rmSync(candidate, { recursive: true, force: true }); }
        catch (error) { warnings.push(`Could not remove unregistered owned source at ${candidate}: ${errorMessage(error)}. A later registry mutation will retry cleanup.`); }
      }
    });
  } catch (error) {
    warnings.push(`Could not verify cleanup for ${candidate}: ${errorMessage(error)}. A later registry mutation will retry cleanup.`);
  }
  printCleanupWarnings(warnings);
}

function printCleanupWarnings(warnings: string[]): void {
  for (const warning of warnings) process.stderr.write(`weaver warning: ${warning}\n`);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function upHost(announce: boolean): Promise<void> {
  assertHostLifecycleAvailable("up");
  assertHostBuilt();
  if (hostRunning()) {
    assertHostReloadReady();
    if (announce) process.stdout.write("weaverd is already running\n");
    return;
  }
  const child = spawn(hostExecutable, [], { cwd: repoRoot, detached: true, stdio: "ignore", windowsHide: true, env: hostEnvironment() });
  child.unref();
  const deadline = Date.now() + 5000;
  while ((!hostRunning() || !hostReloadReady()) && Date.now() < deadline) await delay(50);
  if (!hostRunning() || !hostReloadReady()) throw new WeaverFailure(["weaverd did not become reload-ready"]);
  if (announce) process.stdout.write("weaverd started\n");
}

async function downHost(): Promise<void> {
  assertHostLifecycleAvailable("down");
  assertHostBuilt();
  if (!hostRunning()) {
    process.stdout.write("weaverd is not running\n");
    return;
  }
  signalHost("--signal-down");
  const deadline = Date.now() + 5000;
  while (hostRunning() && Date.now() < deadline) await delay(50);
  if (hostRunning()) throw new WeaverFailure(["weaverd did not stop cleanly"]);
  process.stdout.write("weaverd stopped\n");
}

function showStatus(json: boolean): void {
  assertHostLifecycleAvailable("status");
  if (!hostRunning()) throw new WeaverFailure(['weaverd is not running; run "weaver up"']);
  try {
    const document = readStatus();
    process.stdout.write(`${json ? JSON.stringify(document, null, 2) : formatStatus(document)}\n`);
  } catch {
    throw new WeaverFailure([`weaverd has not published status yet at ${statusPath()}`]);
  }
}

function hostRunning(): boolean {
  if (!hostLifecycleAvailable()) return false;
  if (!existsSync(hostExecutable)) return false;
  return spawnSync(hostExecutable, ["--probe"], { stdio: "ignore", windowsHide: true, env: hostEnvironment() }).status === 0;
}

function hostReloadReady(): boolean {
  if (!hostLifecycleAvailable()) return false;
  if (!existsSync(hostExecutable)) return false;
  return spawnSync(hostExecutable, ["--probe-reload-ready"], { stdio: "ignore", windowsHide: true, env: hostEnvironment() }).status === 0;
}

function assertHostReloadReady(): void {
  if (!hostReloadReady()) {
    throw new WeaverFailure(["The running weaverd predates acknowledged registry reloads.", 'Run "weaver down", then retry; Weaver will start the current host automatically.']);
  }
}

function signalHost(signal: "--signal-down" | "--signal-reload"): void {
  const result = spawnSync(hostExecutable, [signal], { stdio: "ignore", windowsHide: true, env: hostEnvironment() });
  if (result.status !== 0) throw new WeaverFailure([`weaverd rejected ${signal}`]);
}

function authorizeAudio(): void {
  if (process.platform !== "darwin") throw new WeaverFailure(["weaver audio authorize is available only on macOS."]);
  assertHostBuilt();
  const result = spawnSync(hostExecutable, ["--authorize-audio"], {
    cwd: repoRoot,
    env: hostEnvironment(),
    stdio: "inherit",
  });
  if (result.status !== 0) throw new WeaverFailure(["Weaver could not authorize macOS system audio.", "Check System Settings > Privacy & Security > Screen & System Audio Recording, then retry."]);
  if (hostRunning()) signalHost("--signal-reload");
}

function hostEnvironment(): NodeJS.ProcessEnv {
  return { ...process.env, WEAVER_REPO_ROOT: repoRoot };
}

function assertHostBuilt(): void {
  if (!existsSync(hostExecutable)) throw new WeaverFailure([`Host not found at ${hostExecutable}`, "Build host/ with zig build -Doptimize=ReleaseFast."]);
}

function hostLifecycleAvailable(): boolean {
  return process.platform === "win32" || process.platform === "darwin";
}

function assertHostLifecycleAvailable(command: string): void {
  if (hostLifecycleAvailable()) return;
  const platform = process.platform === "darwin" ? "macOS" : process.platform;
  throw new WeaverFailure([`weaver ${command} is unavailable on ${platform} until the native host lands in PR 10.`, "Artifact commands and logs remain available without the host."]);
}

function assertRuntimeBuilt(): void {
  if (!existsSync(runtimeExecutable)) throw new WeaverFailure([`Runtime not found at ${runtimeExecutable}`, "Build runtime/ with the ReleaseFast command in docs/m2a-results.md."]);
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds));
}

function loadProject(directory: string): SourceProject {
  const sourcePath = join(directory, "widget.tsx");
  const configPath = join(directory, "tsconfig.json");
  if (!existsSync(sourcePath) || !existsSync(configPath)) {
    throw new WeaverFailure([`Expected ${sourcePath} and ${configPath}. Run "weaver init <name>" to scaffold a widget.`]);
  }
  const source = readFileSync(sourcePath, "utf8");
  const sourceFile = ts.createSourceFile(sourcePath, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const extractionErrors: string[] = [];
  const config = extractConfig(sourceFile, extractionErrors);
  if (extractionErrors.length > 0 || !config) throw new WeaverFailure(extractionErrors);
  return { directory, sourcePath, source, sourceFile, config };
}

function extractConfig(sourceFile: ts.SourceFile, errors: string[]): WidgetConfigData | null {
  const exportNode = sourceFile.statements.find(ts.isExportAssignment);
  if (!exportNode || !ts.isCallExpression(exportNode.expression) || !ts.isIdentifier(exportNode.expression.expression) || exportNode.expression.expression.text !== "widget") {
    errors.push(locationMessage(sourceFile, exportNode ?? sourceFile, "Default export must be widget({ ... }, component)"));
    return null;
  }
  const [configNode, componentNode] = exportNode.expression.arguments;
  if (!configNode || !ts.isObjectLiteralExpression(configNode) || !componentNode) {
    errors.push(locationMessage(sourceFile, exportNode, "widget config must be a statically extractable literal object; computed values are not allowed"));
    return null;
  }
  try {
    const value = literalValue(configNode) as unknown;
    return validateConfigShape(value, sourceFile, configNode, errors);
  } catch (error) {
    errors.push(locationMessage(sourceFile, configNode, error instanceof Error ? error.message : "Config is not a literal object"));
    return null;
  }
}

function literalValue(node: ts.Expression): unknown {
  if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) return node.text;
  if (ts.isNumericLiteral(node)) return Number(node.text);
  if (node.kind === ts.SyntaxKind.TrueKeyword) return true;
  if (node.kind === ts.SyntaxKind.FalseKeyword) return false;
  if (node.kind === ts.SyntaxKind.NullKeyword) return null;
  if (ts.isPrefixUnaryExpression(node) && node.operator === ts.SyntaxKind.MinusToken && ts.isNumericLiteral(node.operand)) return -Number(node.operand.text);
  if (ts.isArrayLiteralExpression(node)) return node.elements.map((element) => literalValue(element as ts.Expression));
  if (ts.isObjectLiteralExpression(node)) {
    const output: Record<string, unknown> = {};
    for (const property of node.properties) {
      if (!ts.isPropertyAssignment(property) || property.name === undefined || ts.isComputedPropertyName(property.name)) {
        throw new Error("widget config must contain only literal property assignments; spreads, shorthand, and computed keys are not allowed");
      }
      const name = ts.isIdentifier(property.name) || ts.isStringLiteral(property.name) || ts.isNumericLiteral(property.name) ? property.name.text : null;
      if (name === null) throw new Error("widget config property names must be literal");
      output[name] = literalValue(property.initializer);
    }
    return output;
  }
  throw new Error("widget config must be a statically extractable literal object; computed values are not allowed");
}

function validateConfigShape(value: unknown, sourceFile: ts.SourceFile, node: ts.Node, errors: string[]): WidgetConfigData | null {
  if (!isRecord(value)) {
    errors.push(locationMessage(sourceFile, node, "widget config must be an object literal"));
    return null;
  }
  const allowed = new Set(["name", "size", "anchor", "layer", "clickThrough", "subscribe", "origins", "capabilities"]);
  for (const key of Object.keys(value)) if (!allowed.has(key)) errors.push(locationMessage(sourceFile, node, `Unknown widget config field "${key}"`));
  if (typeof value.name !== "string" || value.name.trim() === "") errors.push(locationMessage(sourceFile, node, "config.name must be a non-empty string"));
  else if (Buffer.byteLength(value.name, "utf8") > 256 || /[\p{C}\p{Zl}\p{Zp}]/u.test(value.name)) errors.push(locationMessage(sourceFile, node, "config.name must be at most 256 UTF-8 bytes and contain only printable single-line characters without controls"));
  if (!isNumberPair(value.size) || value.size.some((part) => part <= 0)) errors.push(locationMessage(sourceFile, node, "config.size must be [width, height] with positive numbers"));
  const corners = ["top-left", "top-right", "bottom-left", "bottom-right"];
  if (value.anchor !== undefined) {
    if (!isRecord(value.anchor) || !corners.includes(String(value.anchor.corner)) || (value.anchor.monitor !== undefined && value.anchor.monitor !== "primary") || (value.anchor.offset !== undefined && !isNumberPair(value.anchor.offset))) {
      errors.push(locationMessage(sourceFile, node, "config.anchor must use monitor \"primary\", a supported corner, and an optional numeric [x, y] offset"));
    }
  }
  if (value.layer !== undefined && !["desktop", "normal", "topmost"].includes(String(value.layer))) errors.push(locationMessage(sourceFile, node, "config.layer must be desktop, normal, or topmost"));
  if (value.clickThrough !== undefined && typeof value.clickThrough !== "boolean") errors.push(locationMessage(sourceFile, node, "config.clickThrough must be boolean"));
  if (value.subscribe !== undefined && (!Array.isArray(value.subscribe) || value.subscribe.some((item) => !["time", "cpu", "memory", "audio", "media"].includes(String(item))))) errors.push(locationMessage(sourceFile, node, 'config.subscribe supports only "time", "cpu", "memory", "audio", and "media"'));
  if (value.capabilities !== undefined && (!Array.isArray(value.capabilities) || value.capabilities.length > 0)) errors.push(locationMessage(sourceFile, node, "Widget capabilities are not exposed in M2a; capabilities must be empty"));
  if (value.origins !== undefined) {
    if (!Array.isArray(value.origins) || value.origins.some((origin) => !validOriginHost(origin))) errors.push(locationMessage(sourceFile, node, 'config.origins entries must be exact hosts such as "api.example.com"'));
  }
  if (errors.length > 0) return null;
  return value as unknown as WidgetConfigData;
}

function validateSource(project: SourceProject): string[] {
  const errors: string[] = [];
  const usedProviders = new Set<"time" | "cpu" | "memory" | "audio" | "media">();
  const visit = (node: ts.Node): void => {
    if (ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) {
      const tag = node.tagName.getText(project.sourceFile);
      const classAttribute = node.attributes.properties.find((attribute): attribute is ts.JsxAttribute => ts.isJsxAttribute(attribute) && attribute.name.getText(project.sourceFile) === "class");
      if (classAttribute) {
        const classText = jsxStringValue(classAttribute.initializer);
        if (classText === null) errors.push(locationMessage(project.sourceFile, classAttribute, "class must be a literal string so weaver check can validate every utility"));
        else {
          try { compileClass(classText); }
          catch (error) { errors.push(locationMessage(project.sourceFile, classAttribute, error instanceof UtilityError ? error.message : String(error))); }
        }
      }
      if (tag === "image") {
        const sourceAttribute = node.attributes.properties.find((attribute): attribute is ts.JsxAttribute => ts.isJsxAttribute(attribute) && attribute.name.getText(project.sourceFile) === "src");
        const source = sourceAttribute ? jsxStringValue(sourceAttribute.initializer) : null;
        if (source !== null && (/^[a-z][a-z0-9+.-]*:/i.test(source) || source.startsWith("//"))) {
          errors.push(locationMessage(project.sourceFile, sourceAttribute ?? node, "RemoteImageUnsupported: <image> remote sources arrive in M3; use a local widget path"));
        }
      }
    }
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "useProvider") {
      const argument = node.arguments[0];
      if (argument && ts.isStringLiteral(argument) && ["time", "cpu", "memory", "audio", "media"].includes(argument.text)) usedProviders.add(argument.text as "time" | "cpu" | "memory" | "audio" | "media");
    }
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "wfetch") {
      const argument = node.arguments[0];
      if (argument && (ts.isStringLiteral(argument) || ts.isNoSubstitutionTemplateLiteral(argument))) {
        const host = originHost(argument.text);
        if (host === null) errors.push(locationMessage(project.sourceFile, argument, "wfetch requires an https:// URL"));
        else if (!originDeclared(project.config.origins ?? [], host)) errors.push(locationMessage(project.sourceFile, argument, originNotDeclaredMessage(host)));
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(project.sourceFile);
  for (const provider of usedProviders) {
    if (!project.config.subscribe?.includes(provider)) errors.push(`useProvider("${provider}") requires subscribe: ["${provider}"] in the widget config`);
  }
  return errors;
}

function runTypeScript(directory: string): string | null {
  const executable = join(repoRoot, "node_modules", "typescript", "bin", "tsc");
  const result = spawnSync(process.execPath, [executable, "--noEmit", "--pretty", "false", "--rootDir", directory, "-p", join(directory, "tsconfig.json")], { cwd: directory, encoding: "utf8", windowsHide: true });
  if (result.status === 0) return null;
  return `${result.stdout ?? ""}${result.stderr ?? ""}`.trim() || "TypeScript checker failed without output";
}

function jsxStringValue(initializer: ts.JsxAttributeValue | undefined): string | null {
  if (!initializer) return null;
  if (ts.isStringLiteral(initializer)) return initializer.text;
  if (ts.isJsxExpression(initializer) && initializer.expression && (ts.isStringLiteral(initializer.expression) || ts.isNoSubstitutionTemplateLiteral(initializer.expression))) return initializer.expression.text;
  return null;
}

function locationMessage(sourceFile: ts.SourceFile, node: ts.Node, message: string): string {
  const point = sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile));
  return `${sourceFile.fileName}:${point.line + 1}:${point.character + 1}: ${message}`;
}

function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
function isNumberPair(value: unknown): value is [number, number] { return Array.isArray(value) && value.length === 2 && value.every((part) => typeof part === "number" && Number.isFinite(part)); }

function printFailure(error: unknown): void {
  const details = error instanceof WeaverFailure ? error.details : [error instanceof Error ? error.message : String(error)];
  process.stderr.write(`weaver failed (${details.length} error${details.length === 1 ? "" : "s"})\n${details.map((detail) => `- ${detail}`).join("\n")}\n`);
}

main(process.argv.slice(2)).catch((error: unknown) => {
  printFailure(error);
  process.exitCode = 1;
});
