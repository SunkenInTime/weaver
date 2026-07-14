interface WeaverNativeFetchResponse { status: number; body: string }

interface WeaverNativeBridge {
  createNode(type: "column" | "row" | "text" | "panel" | "button" | "slider" | "image"): number;
  setProp(id: number, key: string, value: string | number | boolean): void;
  setText(id: number, text: string): void;
  appendChild(parentId: number, childId: number): void;
  insertBefore(parentId: number, childId: number, beforeId: number): void;
  removeNode(id: number): void;
  setRoot(id: number): void;
  beginBatch(): void;
  endBatch(): void;
  setHandler(id: number, kind: "press" | "change", enabled: boolean): void;
  onEvent(callback: (id: number, kind: "press" | "change", payload: number | null) => void): void;
  hostAvailable(): boolean;
  onProvider(callback: (jsonLine: string) => void): void;
  setInterval(ms: number): number;
  clearInterval(id: number): void;
  onTimer(id: number, callback: () => void): void;
  fetch(url: string, method: "GET" | "POST", headersJson: string, body: string): Promise<WeaverNativeFetchResponse>;
  storageRead(): string | null;
  storageWrite(json: string): void;
  log(message: string): void;
}

declare const native: WeaverNativeBridge;

