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
  subscribe?: ("time")[];
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

export function widget(config: WidgetConfig, component: () => JSX.Element): WidgetModule;
export function useState<T>(initial: T | (() => T)): [T, (next: T | ((prev: T) => T)) => void];
export function useRef<T>(initial: T): { current: T };
export function useEffect(fn: () => void | (() => void), deps?: unknown[]): void;
export function useInterval(fn: () => void, ms: number): void;
export function useProvider(name: "time"): TimeData;

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

    interface IntrinsicElements {
      column: BoxProps;
      row: BoxProps;
      panel: BoxProps;
      text: TextProps;
      image: BoxProps & { src: string };
      button: BoxProps & { onPress: () => void };
      slider: BoxProps & { value: number; max: number; onChange: (value: number) => void };
      canvas: BoxProps & { onFrame: (draw: unknown, fps: number) => void };
    }
  }
}

