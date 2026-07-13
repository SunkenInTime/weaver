interface WeaverNativeBridge {
  createNode(type: "column" | "row" | "text" | "panel"): number;
  setProp(id: number, key: string, value: string | number | boolean): void;
  setText(id: number, text: string): void;
  appendChild(parentId: number, childId: number): void;
  insertBefore(parentId: number, childId: number, beforeId: number): void;
  removeNode(id: number): void;
  setRoot(id: number): void;
  beginBatch(): void;
  endBatch(): void;
  setInterval(ms: number): number;
  clearInterval(id: number): void;
  onTimer(id: number, callback: () => void): void;
  log(message: string): void;
}

declare const native: WeaverNativeBridge;

