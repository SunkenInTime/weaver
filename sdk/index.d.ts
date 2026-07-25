export type WidgetChild = JSX.Element | string | number | null | undefined | false;

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
  subscribe?: ("time" | "cpu" | "memory" | "audio" | "media")[];
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

export interface WFetchInit {
  method?: "GET" | "POST";
  headers?: Record<string, string>;
  body?: string;
}

export interface WFetchResponse {
  status: number;
  ok: boolean;
  text(): Promise<string>;
  json(): Promise<unknown>;
}

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

export function widget(config: WidgetConfig, component: () => JSX.Element): WidgetModule;
export function useState<T>(initial: T | (() => T)): [T, (next: T | ((prev: T) => T)) => void];
export function useRef<T>(initial: T): { current: T };
export function useEffect(fn: () => void | (() => void), deps?: unknown[]): void;
export function useInterval(fn: () => void, ms: number): void;
export function useProvider(name: "time"): TimeData;
export function useProvider(name: "cpu"): CpuData;
export function useProvider(name: "memory"): MemoryData;
export function useProvider(name: "audio"): AudioData;
export function useProvider(name: "media"): MediaData;
export function useStorage<T>(key: string, initial: T): [T, (next: T | ((prev: T) => T)) => void];
export function wfetch(url: string, init?: WFetchInit): Promise<WFetchResponse>;

export function h(type: unknown, props: Record<string, unknown> | null, ...children: WidgetChild[]): JSX.Element;
export const Fragment: unique symbol;

declare global {
  namespace JSX {
    interface Element {
      readonly __weaverElement: true;
    }

    interface ElementChildrenAttribute {
      children: {};
    }

    interface IntrinsicAttributes {
      key?: string | number;
    }

    interface BoxProps {
      class?: string;
      children?: WidgetChild | WidgetChild[];
    }

    interface TextProps {
      class?: string;
      children?: string | number | (string | number)[];
    }

    type IconProps =
      | { class?: string; name: string; d?: never; viewBox?: never; stroke?: never }
      | { class?: string; d: string; viewBox?: string; stroke?: number; name?: never };

    interface IntrinsicElements {
      column: BoxProps;
      row: BoxProps;
      panel: BoxProps;
      text: TextProps;
      icon: IconProps;
      image: BoxProps & { src: string };
      button: BoxProps & { onPress: () => void };
      slider: BoxProps & { value: number; max: number; onChange: (value: number) => void };
      canvas: BoxProps & { fps?: number; onFrame: (ctx: CanvasCtx, frame: CanvasFrame) => void };
    }
  }
}

declare global {
  function wfetch(url: string, init?: WFetchInit): Promise<WFetchResponse>;
}

