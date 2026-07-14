import { spawn, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, watch, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import ts from "typescript";
import { compileClass, UtilityError } from "../../sdk/src/class-compiler.js";
import { originDeclared, originHost, originNotDeclaredMessage, validOriginHost } from "./origin.js";
import { formatStatus, readRegistry, readStatus, statusPath, writeRegistry } from "./host-tools.js";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const sdkRoot = join(repoRoot, "sdk", "src");
const runtimeExecutable = join(repoRoot, "runtime", "zig-out", "bin", "weaver-widget.exe");
const hostExecutable = join(repoRoot, "host", "zig-out", "bin", "weaverd.exe");

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

async function main(argv: string[]): Promise<void> {
  const [command, argument, ...rest] = argv;
  const directoryCommands = ["init", "check", "bundle", "dev", "install"];
  const noArgumentCommands = ["up", "down"];
  if (!command || rest.length > 0 || (directoryCommands.includes(command) && !argument) || (noArgumentCommands.includes(command) && argument) || (command === "uninstall" && !argument) || (command === "status" && argument !== undefined && argument !== "--json") || ![...directoryCommands, ...noArgumentCommands, "uninstall", "status"].includes(command)) {
    throw new WeaverFailure(["Usage: weaver <init|check|bundle|dev|install> <name-or-directory> | uninstall <name> | up | down | status [--json]"]);
  }
  if (command === "up") return upHost(true);
  if (command === "down") return downHost();
  if (command === "status") return showStatus(argument === "--json");
  if (command === "uninstall") return uninstallWidget(argument!);
  if (command === "init") return initWidget(argument!);
  const directory = resolve(argument!);
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
  if (command === "install") return installWidget(directory);
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
  process.stdout.write(`Initialized ${directory}\nNext: weaver check ${name}\n`);
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

async function bundleWidget(directory: string): Promise<void> {
  const project = checkWidget(directory);
  const outputDirectory = join(directory, "dist");
  mkdirSync(outputDirectory, { recursive: true });
  copyWidgetAssets(directory, outputDirectory);
  await build({
    entryPoints: [project.sourcePath],
    outfile: join(outputDirectory, "bundle.js"),
    bundle: true,
    format: "iife",
    platform: "neutral",
    target: "es2020",
    jsx: "automatic",
    jsxImportSource: "@weaver/sdk",
    legalComments: "none",
    minify: true,
    plugins: [weaverResolutionPlugin()],
    logLevel: "silent",
  });
  const manifest = {
    name: project.config.name,
    size: project.config.size,
    anchor: project.config.anchor ?? { monitor: "primary", corner: "top-right", offset: [24, 24] },
    layer: project.config.layer ?? "desktop",
    clickThrough: project.config.clickThrough ?? false,
    transparent: true,
    origins: project.config.origins ?? [],
    subscribe: project.config.subscribe ?? [],
  };
  writeFileSync(join(outputDirectory, "widget.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
}

/// `dist` is the runtime artifact, so local image paths must mean the same
/// thing after install as they did beside widget.tsx. Copy every ordinary
/// widget-owned file recursively while excluding authoring/build outputs;
/// dynamic local `src` expressions then remain valid without a magic asset
/// directory or source-tree dependency.
function copyWidgetAssets(sourceDirectory: string, outputDirectory: string): void {
  for (const entry of readdirSync(sourceDirectory, { withFileTypes: true })) {
    if (["dist", "widget.tsx", "tsconfig.json"].includes(entry.name)) continue;
    const source = join(sourceDirectory, entry.name);
    const destination = join(outputDirectory, entry.name);
    if (entry.isDirectory()) {
      mkdirSync(destination, { recursive: true });
      copyWidgetAssets(source, destination);
    } else if (entry.isFile()) {
      copyFileSync(source, destination);
    } else {
      throw new WeaverFailure([`Local widget asset ${source} must be a regular file or directory; links are not bundled.`]);
    }
  }
}

function weaverResolutionPlugin(): import("esbuild").Plugin {
  return {
    name: "weaver-import-wall",
    setup(pluginBuild) {
      pluginBuild.onResolve({ filter: /^@weaver\/sdk$/ }, () => ({ path: join(sdkRoot, "index.ts") }));
      pluginBuild.onResolve({ filter: /^@weaver\/sdk\/jsx-runtime$/ }, () => ({ path: join(sdkRoot, "jsx-runtime.ts") }));
      pluginBuild.onResolve({ filter: /^[^./]|^\.[^./]|^\.\.$/ }, (args) => args.kind === "entry-point" ? null : ({
        errors: [{ text: `External import "${args.path}" is not allowed in a widget. Only @weaver/sdk imports are bundled.` }],
      }));
    },
  };
}

async function devWidget(directory: string): Promise<void> {
  assertRuntimeBuilt();
  await upHost(false);
  await bundleWidget(directory);
  const project = loadProject(directory);
  const before = readRegistry();
  const existing = before.widgets.find((widget) => widget.name === project.config.name);
  if (existing && resolve(existing.sourcePath) !== directory) {
    throw new WeaverFailure([`Widget name "${project.config.name}" is already registered from ${existing.sourcePath}`]);
  }
  const temporaryRegistration = !existing;
  writeRegistry({ widgets: [...before.widgets.filter((widget) => widget.name !== project.config.name), {
    name: project.config.name, sourcePath: directory, enabled: true,
  }] });
  signalHost("--signal-reload");
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
      await bundleWidget(directory);
      signalHost("--signal-reload");
      process.stdout.write("weaver dev restarted widget\n");
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
    const stop = (): void => {
      watcher.close();
      clearTimeout(debounce);
      if (temporaryRegistration) {
        const current = readRegistry();
        writeRegistry({ widgets: current.widgets.filter((widget) => widget.name !== project.config.name) });
        signalHost("--signal-reload");
      }
      resolvePromise();
    };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
  });
}

async function installWidget(directory: string): Promise<void> {
  assertRuntimeBuilt();
  const project = checkWidget(directory);
  await bundleWidget(directory);
  const document = readRegistry();
  const conflicting = document.widgets.find((widget) => widget.name === project.config.name && resolve(widget.sourcePath) !== directory);
  if (conflicting) throw new WeaverFailure([`Widget name "${project.config.name}" is already registered from ${conflicting.sourcePath}`]);
  writeRegistry({ widgets: [...document.widgets.filter((widget) => widget.name !== project.config.name), {
    name: project.config.name, sourcePath: directory, enabled: true,
  }] });
  await upHost(false);
  signalHost("--signal-reload");
  process.stdout.write(`Installed ${project.config.name} from ${directory}\n`);
}

function uninstallWidget(name: string): void {
  const document = readRegistry();
  if (!document.widgets.some((widget) => widget.name === name)) throw new WeaverFailure([`Widget "${name}" is not installed.`]);
  writeRegistry({ widgets: document.widgets.filter((widget) => widget.name !== name) });
  if (hostRunning()) signalHost("--signal-reload");
  process.stdout.write(`Uninstalled ${name}\n`);
}

async function upHost(announce: boolean): Promise<void> {
  assertHostBuilt();
  if (hostRunning()) {
    if (announce) process.stdout.write("weaverd is already running\n");
    return;
  }
  const child = spawn(hostExecutable, [], { cwd: repoRoot, detached: true, stdio: "ignore", windowsHide: true });
  child.unref();
  const deadline = Date.now() + 5000;
  while (!hostRunning() && Date.now() < deadline) await delay(50);
  if (!hostRunning()) throw new WeaverFailure(["weaverd did not start"]);
  if (announce) process.stdout.write("weaverd started\n");
}

async function downHost(): Promise<void> {
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
  if (!hostRunning()) throw new WeaverFailure(['weaverd is not running; run "weaver up"']);
  try {
    const document = readStatus();
    process.stdout.write(`${json ? JSON.stringify(document, null, 2) : formatStatus(document)}\n`);
  } catch {
    throw new WeaverFailure([`weaverd has not published status yet at ${statusPath()}`]);
  }
}

function hostRunning(): boolean {
  if (!existsSync(hostExecutable)) return false;
  return spawnSync(hostExecutable, ["--probe"], { stdio: "ignore", windowsHide: true }).status === 0;
}

function signalHost(signal: "--signal-down" | "--signal-reload"): void {
  const result = spawnSync(hostExecutable, [signal], { stdio: "ignore", windowsHide: true });
  if (result.status !== 0) throw new WeaverFailure([`weaverd rejected ${signal}`]);
}

function assertHostBuilt(): void {
  if (!existsSync(hostExecutable)) throw new WeaverFailure([`Host not found at ${hostExecutable}`, "Build host/ with zig build -Doptimize=ReleaseFast."]);
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
  const result = spawnSync(process.execPath, [executable, "--noEmit", "--pretty", "false", "-p", join(directory, "tsconfig.json")], { cwd: directory, encoding: "utf8", windowsHide: true });
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
