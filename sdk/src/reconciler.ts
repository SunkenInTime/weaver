import { compileClass, type ClassProps } from "./class-compiler.js";

export type WidgetChild = VNode | string | number | null | undefined | false;
export type Component = () => VNode;
export type NodeType = "column" | "row" | "panel" | "text";

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
  subscribe?: "time"[];
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
  children: Instance[];
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

export function useProvider(name: "time"): TimeData {
  if (name !== "time") throw new Error(`Provider "${String(name)}" arrives in M2`);
  if (!activeConfig?.subscribe?.includes("time")) {
    throw new Error('useProvider("time") requires subscribe: ["time"] in the widget config');
  }
  const [value, setValue] = useState<TimeData>(() => currentTime());
  useEffect(() => timeProvider.subscribe(setValue), []);
  return value;
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
    : { kind: "host", type, key: vnode.key, id: native.createNode(type), props: {}, children: [] };
  if (!reusable && previous) unmount(previous);
  const nextProps = compileClass(typeof vnode.props.class === "string" ? vnode.props.class : "");
  applyProps(instance.id, instance.props, nextProps);
  instance.props = nextProps;
  if (type === "text") {
    const text = vnode.children.map((child) => {
      if (typeof child !== "string" && typeof child !== "number") throw new Error("<text> children must be strings or numbers");
      return String(child);
    }).join("");
    native.setText(instance.id, text);
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
  native.removeNode(instance.id);
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
  if (config.capabilities && config.capabilities.length > 0) throw new Error("Widget capabilities arrive in M2; capabilities must be empty in M1");
}

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
