import assert from "node:assert/strict";
import test from "node:test";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";

const operations = [];
const callbacks = new Map();
let nextNode = 1;
let nextTimer = 1;
globalThis.native = {
  createNode(type) { const id = nextNode++; operations.push(["createNode", type, id]); return id; },
  setProp(...args) { operations.push(["setProp", ...args]); },
  setText(...args) { operations.push(["setText", ...args]); },
  appendChild(...args) { operations.push(["appendChild", ...args]); },
  insertBefore(...args) { operations.push(["insertBefore", ...args]); },
  removeNode(...args) { operations.push(["removeNode", ...args]); },
  setRoot(...args) { operations.push(["setRoot", ...args]); },
  beginBatch() { operations.push(["beginBatch"]); },
  endBatch() { operations.push(["endBatch"]); },
  setInterval(ms) { const id = nextTimer++; operations.push(["setInterval", ms, id]); return id; },
  clearInterval(id) { operations.push(["clearInterval", id]); callbacks.delete(id); },
  onTimer(id, callback) { operations.push(["onTimer", id]); callbacks.set(id, callback); },
  log(message) { operations.push(["log", message]); },
};

const bundled = await build({
  entryPoints: [fileURLToPath(new URL("../src/index.ts", import.meta.url))],
  bundle: true,
  format: "esm",
  platform: "neutral",
  write: false,
});
const sdk = await import(`data:text/javascript;base64,${Buffer.from(bundled.outputFiles[0].contents).toString("base64")}`);

test("widget renders one native generation and providers use native timers", async () => {
  let reverse;
  sdk.widget({ name: "Test", size: [100, 50], subscribe: ["time"] }, () => {
    const time = sdk.useProvider("time");
    sdk.useInterval(() => {}, 2500);
    const [reversed, setReversed] = sdk.useState(false);
    reverse = () => setReversed(true);
    const keyed = [sdk.h("panel", { key: "a" }), sdk.h("panel", { key: "b" })];
    return sdk.h("column", { class: "p-2" }, sdk.h("text", null, time.ss), ...(reversed ? keyed.reverse() : keyed));
  });
  assert.equal(operations.filter(([name]) => name === "beginBatch").length, 1);
  assert.equal(operations.filter(([name]) => name === "endBatch").length, 1);
  assert.deepEqual(operations.filter(([name]) => name === "setInterval").map((operation) => operation[1]), [1000, 2500]);
  assert.equal(callbacks.size, 2);
  const createCount = operations.filter(([name]) => name === "createNode").length;
  reverse();
  await Promise.resolve();
  assert.equal(operations.filter(([name]) => name === "createNode").length, createCount);
  assert.ok(operations.some(([name]) => name === "insertBefore"));
  callbacks.get(1)();
  await Promise.resolve();
  assert.equal(operations.filter(([name]) => name === "beginBatch").length, 3);
});
