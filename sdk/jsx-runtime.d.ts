import type { WidgetChild } from "./index.js";

export const Fragment: unique symbol;
export function jsx(type: unknown, props: Record<string, unknown>, key?: string | number): JSX.Element;
export function jsxs(type: unknown, props: Record<string, unknown>, key?: string | number): JSX.Element;
export function jsxDEV(type: unknown, props: Record<string, unknown>, key?: string | number): JSX.Element;
export function h(type: unknown, props: Record<string, unknown> | null, ...children: WidgetChild[]): JSX.Element;

