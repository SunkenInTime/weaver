import assert from "node:assert/strict";
import test from "node:test";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";

const operations = [];
const callbacks = new Map();
let nextNode = 1;
let nextTimer = 1;
let eventCallback;
let providerCallback;
const canvasFrameCallbacks = new Map();
let hostAvailable = true;
let storageDocument = null;
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
  setHandler(...args) { operations.push(["setHandler", ...args]); },
  onEvent(callback) { eventCallback = callback; },
  hostAvailable() { return hostAvailable; },
  onProvider(callback) { providerCallback = callback; },
  setInterval(ms) { const id = nextTimer++; operations.push(["setInterval", ms, id]); return id; },
  clearInterval(id) { operations.push(["clearInterval", id]); callbacks.delete(id); },
  onTimer(id, callback) { operations.push(["onTimer", id]); callbacks.set(id, callback); },
  setCanvasCommands(id, commands) { operations.push(["setCanvasCommands", id, [...commands]]); },
  onCanvasFrame(id, callback) { operations.push(["onCanvasFrame", id]); canvasFrameCallbacks.set(id, callback); },
  clearCanvasFrame(id) { operations.push(["clearCanvasFrame", id]); canvasFrameCallbacks.delete(id); },
  fetch: async () => ({ status: 200, body: '{"ok":true}' }),
  storageRead() { operations.push(["storageRead"]); return storageDocument; },
  storageWrite(json) { operations.push(["storageWrite", json]); storageDocument = json; },
  log(message) { operations.push(["log", message]); },
};

const bundled = await build({
  entryPoints: [fileURLToPath(new URL("../src/index.ts", import.meta.url))],
  bundle: true,
  format: "esm",
  platform: "neutral",
  write: false,
});

const sdkUrl = `data:text/javascript;base64,${Buffer.from(bundled.outputFiles[0].contents).toString("base64")}`;
const sdk = await import(sdkUrl);

test("widget renders one native generation and providers use native timers", async () => {
  let reverse;
  let saveMinutes;
  let presses = 0;
  let sliderValue = 0;
  let retainedCanvasContext;
  sdk.widget({ name: "Test", size: [100, 50], subscribe: ["time", "cpu", "audio", "media"] }, () => {
    const time = sdk.useProvider("time");
    const cpu = sdk.useProvider("cpu");
    const audio = sdk.useProvider("audio");
    const media = sdk.useProvider("media");
    sdk.useInterval(() => {}, 2500);
    const [reversed, setReversed] = sdk.useState(false);
    const [minutes, setMinutes] = sdk.useStorage("minutes", 25);
    reverse = () => setReversed(true);
    saveMinutes = setMinutes;
    const keyed = [sdk.h("panel", { key: "a" }), sdk.h("panel", { key: "b" })];
    return sdk.h("column", { class: "p-2" },
      sdk.h("text", null, time.ss),
      sdk.h("text", null, cpu.percent.toFixed(1)),
      sdk.h("text", null, audio.bands[0].toFixed(2)),
      sdk.h("text", null, media.title),
      sdk.h("button", { onPress: () => { presses += 1; } }, sdk.h("text", null, minutes)),
      sdk.h("slider", { value: minutes, max: 60, onChange: (value) => { sliderValue = value; } }),
      sdk.h("canvas", {
        class: "w-[80px] h-[40px]",
        fps: 120,
        onFrame(ctx, frame) {
          retainedCanvasContext = ctx;
          assert.equal(ctx.width, 80);
          assert.equal(ctx.height, 40);
          assert.equal(typeof frame.dt, "number");
          ctx.clear();
          ctx.fillRect(1, 2, 3, 4, "#abc");
          ctx.fillCircle(8, 9, 2, "#11223344");
          ctx.polyline([0, 0, 4, 5], 2, "#ffffff");
        },
      }),
      ...(reversed ? keyed.reverse() : keyed));
  });
  assert.equal(operations.filter(([name]) => name === "beginBatch").length, 1);
  assert.equal(operations.filter(([name]) => name === "endBatch").length, 1);
  assert.deepEqual(operations.filter(([name]) => name === "setInterval").map((operation) => operation[1]), [1000, 2500]);
  assert.equal(callbacks.size, 2);
  const buttonId = operations.find((operation) => operation[0] === "createNode" && operation[1] === "button")[2];
  const sliderId = operations.find((operation) => operation[0] === "createNode" && operation[1] === "slider")[2];
  eventCallback(buttonId, "press", null);
  eventCallback(sliderId, "change", 42);
  assert.equal(presses, 1);
  assert.equal(sliderValue, 42);
  assert.ok(operations.some((operation) => operation[0] === "setHandler" && operation[1] === buttonId && operation[2] === "press" && operation[3] === true));
  const createCount = operations.filter(([name]) => name === "createNode").length;
  reverse();
  await Promise.resolve();
  assert.equal(operations.filter(([name]) => name === "createNode").length, createCount);
  assert.ok(operations.some(([name]) => name === "insertBefore"));
  callbacks.get(1)();
  await Promise.resolve();
  assert.equal(operations.filter(([name]) => name === "beginBatch").length, 3);
  saveMinutes(30);
  await Promise.resolve();
  const storageTimer = operations.filter(([name, ms]) => name === "setInterval" && ms === 200).at(-1)[2];
  callbacks.get(storageTimer)();
  assert.equal(JSON.parse(storageDocument).minutes, 30);
  assert.equal(typeof providerCallback, "function");
  providerCallback('{"provider":"cpu","value":{"percent":37.5,"perCore":[30,45]}}');
  providerCallback('{"provider":"audio","value":{"rms":0.25,"bands":[0.75]}}');
  providerCallback('{"provider":"media","value":{"title":"Test Song","artist":"Artist","album":"Album","playing":true,"positionMs":10,"durationMs":20}}');
  await Promise.resolve();
  assert.ok(operations.some((operation) => operation[0] === "setText" && operation[2] === "37.5"));
  assert.ok(operations.some((operation) => operation[0] === "setText" && operation[2] === "0.75"));
  assert.ok(operations.some((operation) => operation[0] === "setText" && operation[2] === "Test Song"));
  const canvasNode = operations.findLast((operation) => operation[0] === "createNode" && operation[1] === "canvas")[2];
  const submit = operations.findLast((operation) => operation[0] === "setCanvasCommands" && operation[1] === canvasNode);
  assert.deepEqual(submit[2].slice(0, 2), [0, 0]);
  assert.equal(submit[2][2], 1);
  assert.ok(operations.some((operation) => operation[0] === "onCanvasFrame" && operation[1] === canvasNode));
  assert.throws(() => retainedCanvasContext.clear(), /only be called inside onFrame/);
});
