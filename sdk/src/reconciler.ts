import { compileClass, type ClassProps } from "./class-compiler.js";

export type WidgetChild = VNode | string | number | null | undefined | false;
export type Component = () => VNode;
export type NodeType = "column" | "row" | "panel" | "text" | "button" | "slider" | "image" | "canvas";
export type ProviderName = "time" | "cpu" | "memory" | "audio" | "media";

export interface WidgetConfig {
  name: string;
  size: [width: number, height: number];
  anchor?: {
    monitor?: "primary";
    corner: "top-left" | "top-right" | "bottom-left" | "bottom-right";
    offset?: [x: number, y: number];
  };
  layer?: "desktop" | "normal" | "topmost";
  clickThrough?: boolean;
  subscribe?: ProviderName[];
  origins?: string[];
  capabilities?: never[];
}

export interface WidgetModule {
  readonly config: WidgetConfig;
}

export interface TimeData {
  hh: string;
  mm: string;
  ss: string;
  weekday: string;
  month: string;
  day: number;
  year: number;
  epochMs: number;
}

export interface CpuData { percent: number; perCore: number[] }
export interface MemoryData { usedMb: number; totalMb: number; percent: number }
export interface AudioData { rms: number; bands: number[] }
export interface MediaData { title: string; artist: string; album: string; playing: boolean; positionMs: number; durationMs: number }
export interface WFetchInit { method?: "GET" | "POST"; headers?: Record<string, string>; body?: string }
export interface WFetchResponse { status: number; ok: boolean; text(): Promise<string>; json(): Promise<unknown> }
export interface CanvasFrame { t: number; dt: number }
export interface CanvasCtx {
  readonly width: number;
  readonly height: number;
  clear(color?: string): void;
  fillRect(x: number, y: number, width: number, height: number, color: string): void;
  fillRoundRect(x: number, y: number, width: number, height: number, radius: number, color: string): void;
  fillCircle(cx: number, cy: number, radius: number, color: string): void;
  line(x1: number, y1: number, x2: number, y2: number, width: number, color: string): void;
  polyline(points: number[], width: number, color: string): void;
}

interface VNode {
  readonly __weaverElement: true;
  readonly type: NodeType | Component | typeof Fragment;
  readonly props: Record<string, unknown>;
  readonly children: WidgetChild[];
  readonly key?: string | number;
}

interface HostInstance {
  kind: "host";
  type: NodeType;
  key?: string | number;
  id: number;
  props: ClassProps;
  elementProps: HostElementProps;
  children: Instance[];
}

interface HostElementProps {
  onPress?: () => void;
  onChange?: (value: number) => void;
  value?: number;
  max?: number;
  src?: string;
  onFrame?: (ctx: CanvasCtx, frame: CanvasFrame) => void;
  fps?: number;
}

interface ComponentInstance {
  kind: "component";
  type: Component;
  key?: string | number;
  hooks: Hook[];
  hookIndex: number;
  child: Instance | null;
}

interface FragmentInstance {
  kind: "fragment";
  key?: string | number;
  children: Instance[];
}

type Instance = HostInstance | ComponentInstance | FragmentInstance;
type Hook = StateHook<unknown> | RefHook<unknown> | EffectHook;
interface StateHook<T> { kind: "state"; value: T }
interface RefHook<T> { kind: "ref"; value: { current: T } }
interface EffectHook { kind: "effect"; deps?: unknown[]; cleanup?: () => void; effect?: () => void | (() => void) }

export const Fragment = Symbol("weaver.fragment");

let rootComponent: Component | null = null;
let rootInstance: Instance | null = null;
let activeConfig: WidgetConfig | null = null;
let renderingComponent: ComponentInstance | null = null;
let renderQueued = false;
let committedRootId = 0;
const pendingEffects: EffectHook[] = [];
const handlers = new Map<number, HostElementProps>();
interface CanvasBinding {
  onFrame: (ctx: CanvasCtx, frame: CanvasFrame) => void;
  fps?: number;
  timerId: number;
  surfaceClock: boolean;
  width: number;
  height: number;
  lastT?: number;
  nextT?: number;
  nativeTimestampStarted?: boolean;
}
const canvases = new Map<number, CanvasBinding>();
const colorCache = new Map<string, number>();

export function h(type: VNode["type"], props: Record<string, unknown> | null, ...children: WidgetChild[]): VNode {
  const source = props ?? {};
  const propChildren = source.children as WidgetChild | WidgetChild[] | undefined;
  return {
    __weaverElement: true,
    type,
    props: source,
    key: source.key as string | number | undefined,
    children: flatten(children.length > 0 ? children : propChildren === undefined ? [] : [propChildren]),
  };
}

export function jsx(type: VNode["type"], props: Record<string, unknown>, key?: string | number): VNode {
  return h(type, key === undefined ? props : { ...props, key });
}

export const jsxs = jsx;
export const jsxDEV = jsx;

export function widget(config: WidgetConfig, component: Component): WidgetModule {
  validateRuntimeConfig(config, component);
  if (rootComponent !== null) throw new Error("A widget bundle may call widget() exactly once");
  activeConfig = config;
  rootComponent = component;
  renderRoot();
  return Object.freeze({ config });
}

export function useState<T>(initial: T | (() => T)): [T, (next: T | ((previous: T) => T)) => void] {
  const component = currentComponent("useState");
  const index = component.hookIndex++;
  let hook = component.hooks[index] as StateHook<T> | undefined;
  if (!hook) {
    hook = { kind: "state", value: typeof initial === "function" ? (initial as () => T)() : initial };
    component.hooks[index] = hook as StateHook<unknown>;
  } else if (hook.kind !== "state") {
    throw hookOrderError("useState", index);
  }
  return [hook.value, (next) => {
    const value = typeof next === "function" ? (next as (previous: T) => T)(hook.value) : next;
    if (Object.is(value, hook.value)) return;
    hook.value = value;
    scheduleRender();
  }];
}

export function useRef<T>(initial: T): { current: T } {
  const component = currentComponent("useRef");
  const index = component.hookIndex++;
  let hook = component.hooks[index] as RefHook<T> | undefined;
  if (!hook) {
    hook = { kind: "ref", value: { current: initial } };
    component.hooks[index] = hook as RefHook<unknown>;
  } else if (hook.kind !== "ref") {
    throw hookOrderError("useRef", index);
  }
  return hook.value;
}

export function useEffect(effect: () => void | (() => void), deps?: unknown[]): void {
  const component = currentComponent("useEffect");
  const index = component.hookIndex++;
  let hook = component.hooks[index] as EffectHook | undefined;
  if (!hook) {
    hook = { kind: "effect" };
    component.hooks[index] = hook;
  } else if (hook.kind !== "effect") {
    throw hookOrderError("useEffect", index);
  }
  if (depsEqual(hook.deps, deps)) return;
  hook.deps = deps?.slice();
  hook.effect = effect;
  pendingEffects.push(hook);
}

export function useInterval(callback: () => void, milliseconds: number): void {
  const latest = useRef(callback);
  latest.current = callback;
  useEffect(() => {
    if (!Number.isFinite(milliseconds) || milliseconds <= 0) throw new Error("useInterval requires a positive millisecond interval");
    const id = native.setInterval(milliseconds);
    native.onTimer(id, () => latest.current());
    return () => native.clearInterval(id);
  }, [milliseconds]);
}

export function useProvider(name: "time"): TimeData;
export function useProvider(name: "cpu"): CpuData;
export function useProvider(name: "memory"): MemoryData;
export function useProvider(name: "audio"): AudioData;
export function useProvider(name: "media"): MediaData;
export function useProvider(name: ProviderName): TimeData | CpuData | MemoryData | AudioData | MediaData {
  if (!activeConfig?.subscribe?.includes(name)) {
    throw new Error(`useProvider("${name}") requires subscribe: ["${name}"] in the widget config`);
  }
  if (name === "time") {
    const [value, setValue] = useState<TimeData>(() => currentTime());
    useEffect(() => timeProvider.subscribe(setValue), []);
    return value;
  }
  if (!native.hostAvailable()) throw new Error(`Provider "${name}" requires weaverd; run "weaver up"`);
  if (name === "cpu") {
    const [value, setValue] = useState<CpuData>(() => ({ percent: 0, perCore: [] }));
    useEffect(() => hostProviders.subscribeCpu(setValue), []);
    return value;
  }
  if (name === "memory") {
    const [value, setValue] = useState<MemoryData>(() => ({ usedMb: 0, totalMb: 0, percent: 0 }));
    useEffect(() => hostProviders.subscribeMemory(setValue), []);
    return value;
  }
  if (name === "audio") {
    const [value, setValue] = useState<AudioData>(() => ({ rms: 0, bands: Array.from({ length: 32 }, () => 0) }));
    useEffect(() => hostProviders.subscribeAudio(setValue), []);
    return value;
  }
  const [value, setValue] = useState<MediaData>(() => ({ title: "", artist: "", album: "", playing: false, positionMs: 0, durationMs: 0 }));
  useEffect(() => hostProviders.subscribeMedia(setValue), []);
  return value;
}

let storageValues: Record<string, unknown> | null = null;
let storageDirty = false;
let storageTimerId = 0;

export function useStorage<T>(key: string, initial: T): [T, (next: T | ((previous: T) => T)) => void] {
  if (typeof key !== "string" || key.length === 0) throw new Error("useStorage requires a non-empty string key");
  const values = readStorage();
  const [value, setValue] = useState<T>(() => Object.prototype.hasOwnProperty.call(values, key) ? values[key] as T : initial);
  return [value, (next) => {
    setValue((previous) => {
      const resolved = typeof next === "function" ? (next as (prior: T) => T)(previous) : next;
      const candidate = { ...readStorage(), [key]: resolved };
      const encoded = serializeStorage(candidate);
      storageValues = candidate;
      storageDirty = true;
      scheduleStorageWrite(encoded);
      return resolved;
    });
  }];
}

export function wfetch(url: string, init: WFetchInit = {}): Promise<WFetchResponse> {
  const method = init.method ?? "GET";
  const headers = init.headers ?? {};
  if (method !== "GET" && method !== "POST") return Promise.reject(new Error("wfetch method must be GET or POST"));
  for (const [name, value] of Object.entries(headers)) {
    if (!name || /[:\r\n]/.test(name) || typeof value !== "string" || /[\r\n]/.test(value)) {
      return Promise.reject(new Error("wfetch headers must be string values without CR/LF"));
    }
  }
  return native.fetch(url, method, JSON.stringify(headers), init.body ?? "").then((response) => ({
    status: response.status,
    ok: response.status >= 200 && response.status < 300,
    text: async () => response.body,
    json: async () => JSON.parse(response.body) as unknown,
  }));
}

function renderRoot(): void {
  if (!rootComponent) return;
  pendingEffects.length = 0;
  native.beginBatch();
  try {
    rootInstance = reconcile(null, rootInstance, h(rootComponent, null));
    const rootId = firstNativeId(rootInstance);
    if (rootId !== committedRootId) {
      native.setRoot(rootId);
      committedRootId = rootId;
    }
  } finally {
    native.endBatch();
  }
  for (const hook of pendingEffects.splice(0)) {
    hook.cleanup?.();
    const cleanup = hook.effect?.();
    hook.cleanup = typeof cleanup === "function" ? cleanup : undefined;
  }
}

function reconcile(parentId: number | null, previous: Instance | null, vnode: VNode): Instance {
  if (typeof vnode.type === "function") return reconcileComponent(parentId, previous, vnode, vnode.type);
  if (vnode.type === Fragment) return reconcileFragment(parentId, previous, vnode);
  return reconcileHost(parentId, previous, vnode, vnode.type);
}

function reconcileComponent(parentId: number | null, previous: Instance | null, vnode: VNode, componentType: Component): ComponentInstance {
  const instance: ComponentInstance = previous?.kind === "component" && previous.type === componentType && previous.key === vnode.key
    ? previous
    : { kind: "component", type: componentType, key: vnode.key, hooks: [], hookIndex: 0, child: null };
  if (instance !== previous && previous) unmount(previous);
  instance.hookIndex = 0;
  const prior = renderingComponent;
  renderingComponent = instance;
  let rendered: VNode;
  try {
    rendered = componentType();
  } finally {
    renderingComponent = prior;
  }
  if (!isVNode(rendered)) throw new Error("A Weaver component must return one JSX element");
  instance.child = reconcile(parentId, instance.child, rendered);
  if (instance.hookIndex !== instance.hooks.length) {
    throw new Error(`Hook order changed in ${componentType.name || "component"}`);
  }
  return instance;
}

function reconcileFragment(parentId: number | null, previous: Instance | null, vnode: VNode): FragmentInstance {
  const instance: FragmentInstance = previous?.kind === "fragment" && previous.key === vnode.key
    ? previous
    : { kind: "fragment", key: vnode.key, children: [] };
  if (instance !== previous && previous) unmount(previous);
  instance.children = reconcileChildren(parentId, instance.children, vnode.children);
  return instance;
}

function reconcileHost(parentId: number | null, previous: Instance | null, vnode: VNode, type: NodeType): HostInstance {
  const reusable = previous?.kind === "host" && previous.type === type && previous.key === vnode.key;
  const instance: HostInstance = reusable
    ? previous
    : { kind: "host", type, key: vnode.key, id: native.createNode(type), props: {}, elementProps: {}, children: [] };
  if (!reusable && previous) unmount(previous);
  const nextProps = compileClass(typeof vnode.props.class === "string" ? vnode.props.class : "");
  applyProps(instance.id, instance.props, nextProps);
  instance.props = nextProps;
  applyElementProps(instance, vnode.props);
  if (type === "text") {
    const text = vnode.children.map((child) => {
      if (typeof child !== "string" && typeof child !== "number") throw new Error("<text> children must be strings or numbers");
      return String(child);
    }).join("");
    native.setText(instance.id, text);
  } else if (type === "canvas") {
    if (vnode.children.some(isRenderable)) throw new Error("<canvas> does not accept children");
  } else {
    instance.children = reconcileChildren(instance.id, instance.children, vnode.children);
  }
  if (!reusable && parentId !== null) native.appendChild(parentId, instance.id);
  return instance;
}

function reconcileChildren(parentId: number | null, previous: Instance[], children: WidgetChild[]): Instance[] {
  const vnodes = children.filter(isRenderable).map(toVNode);
  const keyed = new Map<string | number, Instance>();
  const unkeyed: Instance[] = [];
  for (const child of previous) {
    const key = instanceKey(child);
    if (key === undefined) unkeyed.push(child);
    else keyed.set(key, child);
  }
  let unkeyedIndex = 0;
  const used = new Set<Instance>();
  const next = vnodes.map((vnode) => {
    const candidate = vnode.key === undefined ? unkeyed[unkeyedIndex++] ?? null : keyed.get(vnode.key) ?? null;
    if (candidate) used.add(candidate);
    return reconcile(parentId, candidate, vnode);
  });
  for (const child of previous) if (!used.has(child)) unmount(child);
  if (parentId !== null) reorder(parentId, previous.flatMap(nativeIds).filter((id) => next.flatMap(nativeIds).includes(id)), next.flatMap(nativeIds));
  return next;
}

function reorder(parentId: number, currentSource: number[], target: number[]): void {
  const current = currentSource.slice();
  for (const id of target) if (!current.includes(id)) current.push(id);
  for (let index = 0; index < target.length; index += 1) {
    if (current[index] === target[index]) continue;
    const from = current.indexOf(target[index]);
    if (from >= 0) current.splice(from, 1);
    const before = current[index] ?? 0;
    native.insertBefore(parentId, target[index], before);
    current.splice(index, 0, target[index]);
  }
}

function applyProps(id: number, previous: ClassProps, next: ClassProps): void {
  const defaults: Required<ClassProps> = {
    padding: 0, gap: 0, radius: 0, background: "", textColor: "",
    fontScale: 1, fontWeight: "normal", opacity: 1, crossAlign: "start",
    mainAlign: "start", grow: 0, width: 0, height: 0, truncate: false,
  };
  for (const key of Object.keys(defaults) as (keyof ClassProps)[]) {
    const before = previous[key] ?? defaults[key];
    const after = next[key] ?? defaults[key];
    if (!Object.is(before, after)) native.setProp(id, key, after);
  }
}

function applyElementProps(instance: HostInstance, props: Record<string, unknown>): void {
  const previous = instance.elementProps;
  const next: HostElementProps = {};
  if (instance.type === "button") {
    if (typeof props.onPress !== "function") throw new Error("<button> requires onPress={() => ...}");
    next.onPress = props.onPress as () => void;
  } else if (instance.type === "slider") {
    if (typeof props.onChange !== "function") throw new Error("<slider> requires onChange={(value) => ...}");
    if (typeof props.value !== "number" || !Number.isFinite(props.value)) throw new Error("<slider> value must be a finite number");
    if (typeof props.max !== "number" || !Number.isFinite(props.max) || props.max <= 0) throw new Error("<slider> max must be positive");
    next.onChange = props.onChange as (value: number) => void;
    next.value = Math.max(0, Math.min(props.value, props.max));
    next.max = props.max;
  } else if (instance.type === "image") {
    if (typeof props.src !== "string" || props.src.length === 0) throw new Error("<image> requires a local src string");
    if (/^[a-z][a-z0-9+.-]*:/i.test(props.src) || props.src.startsWith("//")) {
      throw new Error("RemoteImageUnsupported: <image> remote sources arrive in M3; use a local widget path");
    }
    next.src = props.src;
  } else if (instance.type === "canvas") {
    if (typeof props.onFrame !== "function") throw new Error("<canvas> requires onFrame={(ctx, frame) => ...}");
    if (props.fps !== undefined && (typeof props.fps !== "number" || !Number.isFinite(props.fps) || props.fps <= 0)) {
      throw new Error("<canvas> fps must be a positive number when provided");
    }
    next.onFrame = props.onFrame as (ctx: CanvasCtx, frame: CanvasFrame) => void;
    next.fps = props.fps === undefined ? undefined : Math.min(60, props.fps as number);
  }
  if (Boolean(previous.onPress) !== Boolean(next.onPress)) native.setHandler(instance.id, "press", Boolean(next.onPress));
  if (Boolean(previous.onChange) !== Boolean(next.onChange)) native.setHandler(instance.id, "change", Boolean(next.onChange));
  if (!Object.is(previous.value, next.value) && next.value !== undefined) native.setProp(instance.id, "value", next.value);
  if (!Object.is(previous.max, next.max) && next.max !== undefined) native.setProp(instance.id, "max", next.max);
  if (!Object.is(previous.src, next.src) && next.src !== undefined) native.setProp(instance.id, "source", next.src);
  instance.elementProps = next;
  if (instance.type === "canvas" && next.onFrame) {
    updateCanvasBinding(instance.id, next.onFrame, next.fps, instance.props.width ?? 0, instance.props.height ?? 0);
  }
  if (next.onPress || next.onChange) handlers.set(instance.id, next);
  else handlers.delete(instance.id);
}

function unmount(instance: Instance): void {
  if (instance.kind === "component") {
    for (const hook of instance.hooks) if (hook.kind === "effect") hook.cleanup?.();
    if (instance.child) unmount(instance.child);
    return;
  }
  if (instance.kind === "fragment") {
    for (const child of instance.children) unmount(child);
    return;
  }
  handlers.delete(instance.id);
  disposeCanvas(instance.id);
  native.removeNode(instance.id);
}

function updateCanvasBinding(id: number, onFrame: (ctx: CanvasCtx, frame: CanvasFrame) => void, fps: number | undefined, width: number, height: number): void {
  let binding = canvases.get(id);
  const intervalChanged = binding?.fps !== fps;
  if (!binding) {
    binding = { onFrame, fps, timerId: 0, surfaceClock: false, width, height };
    canvases.set(id, binding);
  } else {
    binding.onFrame = onFrame;
    binding.width = width;
    binding.height = height;
  }
  if (intervalChanged && binding.timerId !== 0) {
    native.clearInterval(binding.timerId);
    binding.timerId = 0;
    binding.lastT = undefined;
    binding.nextT = undefined;
    binding.nativeTimestampStarted = false;
  }
  if (intervalChanged && binding.surfaceClock) {
    native.clearCanvasFrame(id);
    binding.surfaceClock = false;
    binding.lastT = undefined;
    binding.nextT = undefined;
    binding.nativeTimestampStarted = false;
  }
  binding.fps = fps;
  if (fps === undefined) {
    drawCanvasFrame(id, Date.now() / 1000);
    return;
  }
  if (fps >= 60) {
    if (!binding.surfaceClock) {
      native.onCanvasFrame(id, (timestampSeconds) => drawCanvasFrame(id, timestampSeconds));
      binding.surfaceClock = true;
      drawCanvasFrame(id, Date.now() / 1000);
    }
    return;
  }
  if (binding.timerId === 0) {
    // The native timer requests a surface frame; the surface scheduler then
    // presents on its 60 Hz grid. A short wake lead keeps sub-60 callbacks on
    // their requested glass cadence; max-rate canvases use the completion
    // clock above and need no independent timer.
    binding.timerId = native.setInterval(Math.max(1, Math.floor(1000 / fps - 1000 / 110)));
    native.onTimer(binding.timerId, (timestampSeconds) => drawTimedCanvasFrame(id, timestampSeconds ?? Date.now() / 1000));
    drawCanvasFrame(id, Date.now() / 1000);
  }
}

function drawTimedCanvasFrame(id: number, timestampSeconds: number): void {
  const binding = canvases.get(id);
  if (!binding || binding.fps === undefined) return;
  const period = 1 / binding.fps;
  if (binding.nextT === undefined) binding.nextT = timestampSeconds;
  if (timestampSeconds + 0.000_001 < binding.nextT) return;
  do binding.nextT += period;
  while (binding.nextT <= timestampSeconds);
  drawCanvasFrame(id, timestampSeconds);
}

function disposeCanvas(id: number): void {
  const binding = canvases.get(id);
  if (!binding) return;
  if (binding.timerId !== 0) native.clearInterval(binding.timerId);
  if (binding.surfaceClock) native.clearCanvasFrame(id);
  canvases.delete(id);
}

function drawCanvasFrame(id: number, nativeTimestamp?: number): void {
  const binding = canvases.get(id);
  if (!binding) return;
  if (nativeTimestamp !== undefined && !binding.nativeTimestampStarted) {
    binding.lastT = undefined;
    binding.nativeTimestampStarted = true;
  }
  const t = typeof nativeTimestamp === "number" && Number.isFinite(nativeTimestamp) && nativeTimestamp > 0
    ? nativeTimestamp
    : Date.now() / 1000;
  const dt = binding.lastT === undefined ? 0 : Math.max(0, t - binding.lastT);
  binding.lastT = t;
  const batch: number[] = [];
  let active = true;
  const ensureActive = (): void => { if (!active) throw new Error("CanvasCtx methods may only be called inside onFrame"); };
  const number = (value: number, label: string): number => {
    if (!Number.isFinite(value)) throw new Error(`CanvasCtx ${label} must be finite`);
    return value;
  };
  const ctx: CanvasCtx = Object.freeze({
    width: binding.width,
    height: binding.height,
    clear(color = "#00000000"): void {
      ensureActive();
      batch.push(0, packedColor(color));
    },
    fillRect(x: number, y: number, rectWidth: number, rectHeight: number, color: string): void {
      ensureActive();
      batch.push(1, number(x, "x"), number(y, "y"), number(rectWidth, "width"), number(rectHeight, "height"), packedColor(color));
    },
    fillRoundRect(x: number, y: number, rectWidth: number, rectHeight: number, radius: number, color: string): void {
      ensureActive();
      batch.push(2, number(x, "x"), number(y, "y"), number(rectWidth, "width"), number(rectHeight, "height"), number(radius, "radius"), packedColor(color));
    },
    fillCircle(cx: number, cy: number, radius: number, color: string): void {
      ensureActive();
      batch.push(3, number(cx, "cx"), number(cy, "cy"), number(radius, "radius"), packedColor(color));
    },
    line(x1: number, y1: number, x2: number, y2: number, lineWidth: number, color: string): void {
      ensureActive();
      batch.push(4, number(x1, "x1"), number(y1, "y1"), number(x2, "x2"), number(y2, "y2"), number(lineWidth, "width"), packedColor(color));
    },
    polyline(points: number[], lineWidth: number, color: string): void {
      ensureActive();
      if (!Array.isArray(points) || points.length < 4 || points.length % 2 !== 0) throw new Error("CanvasCtx polyline points must be a flat [x,y,...] array with at least two points");
      batch.push(5, number(lineWidth, "width"), packedColor(color), points.length / 2);
      for (const point of points) batch.push(number(point, "point"));
    },
  });
  try {
    binding.onFrame(ctx, { t, dt });
  } finally {
    active = false;
  }
  native.setCanvasCommands(id, Float64Array.from(batch));
}

function packedColor(source: string): number {
  const cached = colorCache.get(source);
  if (cached !== undefined) return cached;
  if (typeof source !== "string") throw new Error("Canvas colors must be #rgb, #rrggbb, or #rrggbbaa");
  let hex: string;
  if (/^#[0-9a-f]{3}$/i.test(source)) {
    hex = `${source[1]}${source[1]}${source[2]}${source[2]}${source[3]}${source[3]}ff`;
  } else if (/^#[0-9a-f]{6}$/i.test(source)) {
    hex = `${source.slice(1)}ff`;
  } else if (/^#[0-9a-f]{8}$/i.test(source)) {
    hex = source.slice(1);
  } else {
    throw new Error(`Invalid canvas color "${source}": use #rgb, #rrggbb, or #rrggbbaa`);
  }
  const packed = Number.parseInt(hex, 16) >>> 0;
  colorCache.set(source, packed);
  return packed;
}

function nativeIds(instance: Instance): number[] {
  if (instance.kind === "host") return [instance.id];
  if (instance.kind === "component") return instance.child ? nativeIds(instance.child) : [];
  return instance.children.flatMap(nativeIds);
}

function firstNativeId(instance: Instance): number {
  const ids = nativeIds(instance);
  if (ids.length !== 1) throw new Error("A widget root must resolve to exactly one native element");
  return ids[0];
}

function instanceKey(instance: Instance): string | number | undefined { return instance.key; }
function isRenderable(value: WidgetChild): value is VNode | string | number { return value !== null && value !== undefined && value !== false; }
function isVNode(value: unknown): value is VNode { return typeof value === "object" && value !== null && (value as { __weaverElement?: boolean }).__weaverElement === true; }
function toVNode(value: VNode | string | number): VNode { return isVNode(value) ? value : h("text", null, value); }

function flatten(values: readonly unknown[]): WidgetChild[] {
  const output: WidgetChild[] = [];
  for (const value of values) {
    if (Array.isArray(value)) output.push(...flatten(value));
    else output.push(value as WidgetChild);
  }
  return output;
}

function scheduleRender(): void {
  if (renderQueued) return;
  renderQueued = true;
  void Promise.resolve().then(() => {
    renderQueued = false;
    renderRoot();
  });
}

function currentComponent(hook: string): ComponentInstance {
  if (!renderingComponent) throw new Error(`${hook} must be called while rendering a component`);
  return renderingComponent;
}

function hookOrderError(hook: string, index: number): Error { return new Error(`${hook} changed hook order at slot ${index}`); }
function depsEqual(left?: unknown[], right?: unknown[]): boolean {
  if (!left || !right || left.length !== right.length) return false;
  return left.every((value, index) => Object.is(value, right[index]));
}

function validateRuntimeConfig(config: WidgetConfig, component: Component): void {
  if (!config || typeof config !== "object") throw new Error("widget config must be an object");
  if (!config.name?.trim()) throw new Error("widget config.name must be a non-empty string");
  if (!Array.isArray(config.size) || config.size.length !== 2 || config.size.some((value) => !Number.isFinite(value) || value <= 0)) {
    throw new Error("widget config.size must contain two positive numbers");
  }
  if (typeof component !== "function") throw new Error("widget component must be a function");
  if (config.capabilities && config.capabilities.length > 0) throw new Error("Widget capabilities are not exposed in M2a; capabilities must be empty");
}

function readStorage(): Record<string, unknown> {
  if (storageValues) return storageValues;
  const raw = native.storageRead();
  if (raw === null) return storageValues = {};
  const parsed = JSON.parse(raw) as unknown;
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error("Stored widget state is not a JSON object");
  return storageValues = parsed as Record<string, unknown>;
}

function serializeStorage(values: Record<string, unknown>): string {
  const encoded = JSON.stringify(values);
  if (utf8ByteLength(encoded) > 64 * 1024) throw new Error("StorageQuotaExceeded: widget storage exceeds 64 KB");
  return encoded;
}

function scheduleStorageWrite(_encoded: string): void {
  if (storageTimerId !== 0) native.clearInterval(storageTimerId);
  storageTimerId = native.setInterval(200);
  native.onTimer(storageTimerId, () => {
    native.clearInterval(storageTimerId);
    storageTimerId = 0;
    flushStorage();
  });
}

function flushStorage(): void {
  if (!storageDirty || !storageValues) return;
  native.storageWrite(serializeStorage(storageValues));
  storageDirty = false;
}

function utf8ByteLength(value: string): number {
  let bytes = 0;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code < 0x80) bytes += 1;
    else if (code < 0x800) bytes += 2;
    else if (code >= 0xd800 && code <= 0xdbff && index + 1 < value.length && value.charCodeAt(index + 1) >= 0xdc00 && value.charCodeAt(index + 1) <= 0xdfff) {
      bytes += 4;
      index += 1;
    } else bytes += 3;
  }
  return bytes;
}

native.onEvent((id, kind, payload) => {
  const handler = handlers.get(id);
  if (kind === "press") handler?.onPress?.();
  else if (kind === "change" && typeof payload === "number") handler?.onChange?.(payload);
});
Object.defineProperty(globalThis, "wfetch", { value: wfetch, configurable: false, writable: false });
Object.defineProperty(globalThis, "__weaverFlushStorage", { value: flushStorage, configurable: false, writable: false });

const weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;
const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"] as const;
function pad2(value: number): string { return String(value).padStart(2, "0"); }
function currentTime(): TimeData {
  const now = new Date();
  return {
    hh: pad2(now.getHours()), mm: pad2(now.getMinutes()), ss: pad2(now.getSeconds()),
    weekday: weekdays[now.getDay()], month: months[now.getMonth()], day: now.getDate(),
    year: now.getFullYear(), epochMs: now.getTime(),
  };
}

const timeProvider = (() => {
  const listeners = new Set<(value: TimeData) => void>();
  let timerId = 0;
  const tick = (): void => {
    const value = currentTime();
    for (const listener of listeners) listener(value);
  };
  return {
    subscribe(listener: (value: TimeData) => void): () => void {
      listeners.add(listener);
      if (timerId === 0) {
        timerId = native.setInterval(1000);
        native.onTimer(timerId, tick);
      }
      return () => {
        listeners.delete(listener);
        if (listeners.size === 0 && timerId !== 0) {
          native.clearInterval(timerId);
          timerId = 0;
        }
      };
    },
  };
})();

const hostProviders = (() => {
  const cpuListeners = new Set<(value: CpuData) => void>();
  const memoryListeners = new Set<(value: MemoryData) => void>();
  const audioListeners = new Set<(value: AudioData) => void>();
  const mediaListeners = new Set<(value: MediaData) => void>();
  let installed = false;
  const install = (): void => {
    if (installed) return;
    installed = true;
    native.onProvider((line) => {
      const frame = JSON.parse(line) as { provider?: unknown; value?: unknown };
      if (frame.provider === "cpu") {
        const value = frame.value as CpuData;
        for (const listener of cpuListeners) listener(value);
      } else if (frame.provider === "memory") {
        const value = frame.value as MemoryData;
        for (const listener of memoryListeners) listener(value);
      } else if (frame.provider === "audio") {
        const value = frame.value as AudioData;
        for (const listener of audioListeners) listener(value);
      } else if (frame.provider === "media") {
        const value = frame.value as MediaData;
        for (const listener of mediaListeners) listener(value);
      }
    });
  };
  return {
    subscribeCpu(listener: (value: CpuData) => void): () => void {
      install();
      cpuListeners.add(listener);
      return () => cpuListeners.delete(listener);
    },
    subscribeMemory(listener: (value: MemoryData) => void): () => void {
      install();
      memoryListeners.add(listener);
      return () => memoryListeners.delete(listener);
    },
    subscribeAudio(listener: (value: AudioData) => void): () => void {
      install();
      audioListeners.add(listener);
      return () => audioListeners.delete(listener);
    },
    subscribeMedia(listener: (value: MediaData) => void): () => void {
      install();
      mediaListeners.add(listener);
      return () => mediaListeners.delete(listener);
    },
  };
})();
