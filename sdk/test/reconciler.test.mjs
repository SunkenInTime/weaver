import assert from "node:assert/strict";
import test from "node:test";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

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
  let pressEvent;
  let doublePressEvent;
  let rightPressEvent;
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
    return sdk.h("column", { class: "p-2 pt-0 mx-1 w-1/2 min-w-4 max-w-0 max-h-[60px] aspect-square justify-evenly grow-2 shrink-0 self-end flex-wrap shadow-inner shadow-red-500/40" },
      sdk.h("panel", { class: "w-0" }),
      sdk.h("text", { class: "text-[13px] text-center leading-tight tracking-[-0.5px] line-clamp-2 tabular-nums font-bold font-mono text-shadow-md" }, time.ss),
      sdk.h("text", null, cpu.percent.toFixed(1)),
      sdk.h("text", null, audio.bands[0].toFixed(2)),
      sdk.h("text", null, media.title),
      sdk.h("icon", {
        iconPath: "M 5 5 L 19 12 L 5 19 Z",
        iconViewBox: "0 0 24 24",
        iconStroke: 2,
        class: "text-red-500 w-6",
      }),
      sdk.h("stack", { class: "w-full h-[32px] overflow-hidden rounded-xl" },
        sdk.h("panel", { class: "size-full bg-slate-800" }),
        sdk.h("text", null, "overlay")),
      sdk.h("image", { src: "./cover.png", fit: "cover", tile: true, class: "w-6 h-4 rounded-tl-lg rounded-br-2xl" }),
      sdk.h("button", {
        class: "bg-zinc-900 hover:bg-zinc-800 hover:text-white hover:opacity-90 hover:border-zinc-600 pressed:bg-black pressed:text-red-500 pressed:opacity-70 pressed:border-white",
        onPress: (event) => { presses += 1; pressEvent = event; },
        onDoublePress: (event) => { doublePressEvent = event; },
        onRightPress: (event) => { rightPressEvent = event; },
      }, sdk.h("text", null, minutes)),
      sdk.h("slider", { value: minutes, max: 60, onChange: (value) => { sliderValue = value; } }),
      sdk.h("canvas", {
        class: "w-[8px] h-[4px]",
        fps: 0,
        onFrame(ctx) { ctx.fillRect(0, 0, 8, 4, "#000"); },
      }),
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
  const rootColumnId = operations.find((operation) => operation[0] === "createNode" && operation[1] === "column")[2];
  for (const [key, value] of [
    ["padding", 8], ["paddingTop", 0], ["marginLeft", 4], ["marginRight", 4],
    ["widthPercent", 50], ["minWidth", 16], ["maxWidth", 0], ["maxHeight", 60], ["aspectRatio", 1],
    ["mainAlign", "evenly"], ["grow", 2], ["shrink", 0], ["alignSelf", "end"], ["flexWrap", true],
    ["shadow", "0 2 4 0 #FB2C3666"], ["shadowInset", true],
  ]) {
    assert.ok(operations.some((operation) => operation[0] === "setProp" && operation[1] === rootColumnId && operation[2] === key && operation[3] === value), `${key} wire prop`);
  }
  assert.ok(operations.some((operation) => operation[0] === "setProp" && operation[2] === "width" && operation[3] === 0), "explicit w-0 wire prop");
  const styledTextId = operations.find((operation) => operation[0] === "createNode" && operation[1] === "text")[2];
  for (const [key, value] of [
    ["fontScale", 13 / 14], ["fontWeight", "bold"], ["fontFamily", "mono"], ["textAlign", "center"],
    ["lineHeight", 1.25], ["letterSpacing", -0.5], ["lineClamp", 2], ["tabularNums", true],
    ["textShadow", "0 2 4 #00000026"],
  ]) {
    assert.ok(operations.some((operation) => operation[0] === "setProp" && operation[1] === styledTextId && operation[2] === key && operation[3] === value), `${key} text wire prop`);
  }
  const iconId = operations.find((operation) => operation[0] === "createNode" && operation[1] === "icon")[2];
  for (const [key, value] of [
    ["iconPath", "M 5 5 L 19 12 L 5 19 Z"],
    ["iconViewBox", "0 0 24 24"],
    ["iconStroke", 2],
    ["textColor", "#FB2C36FF"],
    ["width", 24],
    ["height", 24],
  ]) {
    assert.ok(operations.some((operation) => operation[0] === "setProp" && operation[1] === iconId && operation[2] === key && operation[3] === value), `${key} icon wire prop`);
  }
  const stackId = operations.find((operation) => operation[0] === "createNode" && operation[1] === "stack")[2];
  for (const [key, value] of [["widthPercent", 100], ["height", 32], ["radius", 12], ["overflowHidden", true]]) {
    assert.ok(operations.some((operation) => operation[0] === "setProp" && operation[1] === stackId && operation[2] === key && operation[3] === value), `${key} stack wire prop`);
  }
  assert.equal(operations.filter((operation) => operation[0] === "appendChild" && operation[1] === stackId).length, 2);
  const imageId = operations.find((operation) => operation[0] === "createNode" && operation[1] === "image")[2];
  for (const [key, value] of [["source", "./cover.png"], ["imageFit", "cover"], ["imageTile", true], ["radiusTopLeft", 8], ["radiusBottomRight", 16]]) {
    assert.ok(operations.some((operation) => operation[0] === "setProp" && operation[1] === imageId && operation[2] === key && operation[3] === value), `${key} image wire prop`);
  }
  const buttonId = operations.find((operation) => operation[0] === "createNode" && operation[1] === "button")[2];
  const sliderId = operations.find((operation) => operation[0] === "createNode" && operation[1] === "slider")[2];
  for (const [key, value] of [
    ["hoverBackground", "#27272AFF"], ["hoverTextColor", "#FFFFFFFF"], ["hoverOpacity", 0.9], ["hoverBorderColor", "#52525CFF"],
    ["pressedBackground", "#000000FF"], ["pressedTextColor", "#FB2C36FF"], ["pressedOpacity", 0.7], ["pressedBorderColor", "#FFFFFFFF"],
  ]) {
    assert.ok(operations.some((operation) => operation[0] === "setProp" && operation[1] === buttonId && operation[2] === key && operation[3] === value), `${key} interaction wire prop`);
  }
  eventCallback(buttonId, "press", { x: 25, y: 10, w: 100, h: 40 });
  eventCallback(buttonId, "doublepress", { x: 80, y: 30, w: 100, h: 40 });
  eventCallback(buttonId, "rightpress", { x: 50, y: 20, w: 100, h: 40 });
  eventCallback(sliderId, "change", 42);
  assert.equal(presses, 1);
  assert.deepEqual(pressEvent, { x: 25, y: 10, u: 0.25, v: 0.25 });
  assert.deepEqual(doublePressEvent, { x: 80, y: 30, u: 0.8, v: 0.75 });
  assert.deepEqual(rightPressEvent, { x: 50, y: 20, u: 0.5, v: 0.5 });
  assert.equal(sliderValue, 42);
  assert.ok(operations.some((operation) => operation[0] === "setHandler" && operation[1] === buttonId && operation[2] === "press" && operation[3] === true));
  assert.ok(operations.some((operation) => operation[0] === "setHandler" && operation[1] === buttonId && operation[2] === "doublepress" && operation[3] === true));
  assert.ok(operations.some((operation) => operation[0] === "setHandler" && operation[1] === buttonId && operation[2] === "rightpress" && operation[3] === true));
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
  const pausedCanvasNode = operations.filter((operation) => operation[0] === "createNode" && operation[1] === "canvas")[0][2];
  assert.ok(operations.some((operation) => operation[0] === "setCanvasCommands" && operation[1] === pausedCanvasNode));
  assert.ok(!operations.some((operation) => operation[0] === "onCanvasFrame" && operation[1] === pausedCanvasNode));
  const submit = operations.findLast((operation) => operation[0] === "setCanvasCommands" && operation[1] === canvasNode);
  assert.deepEqual(submit[2].slice(0, 2), [0, 0]);
  assert.equal(submit[2][2], 1);
  assert.ok(operations.some((operation) => operation[0] === "onCanvasFrame" && operation[1] === canvasNode));
  assert.throws(() => retainedCanvasContext.clear(), /only be called inside onFrame/);
});

test("styling 08 runtime accepts only bundle-lowered path icons and rejects children before native mutation", () => {
  const operationCount = operations.length;
  assert.throws(() => sdk.h("icon", { name: "play" }), /must be lowered to path data/);
  assert.throws(() => sdk.h("icon", { iconPath: "M 0 0", iconViewBox: "0 0 24 24", iconStroke: 0 }, "child"), /does not accept children/);
  assert.equal(operations.length, operationCount);
});

test("styling 10 image props reject invalid fit and tile before native mutation", () => {
  const operationCount = operations.length;
  assert.throws(() => sdk.h("image", { src: "./cover.png", fit: "scale-down" }), /fit must be "cover", "contain", or "stretch"/);
  assert.throws(() => sdk.h("image", { src: "./cover.png", tile: "yes" }), /tile must be boolean/);
  assert.equal(operations.length, operationCount);
});

test("styling 11 button handlers reject invalid callbacks before native mutation", () => {
  const operationCount = operations.length;
  assert.throws(() => sdk.h("button", { onPress: () => {}, onDoublePress: true }), /onDoublePress must be a function/);
  assert.throws(() => sdk.h("button", { onPress: () => {}, onRightPress: "menu" }), /onRightPress must be a function/);
  assert.equal(operations.length, operationCount);
});

function isolatedNative() {
  let id = 0;
  return {
    createNode() { return ++id; }, setProp() {}, setText() {}, appendChild() {}, insertBefore() {}, removeNode() {}, setRoot() {},
    beginBatch() {}, endBatch() {}, setHandler() {}, onEvent() {}, hostAvailable() { return false; }, onProvider() {},
    setInterval() { return 1; }, clearInterval() {}, onTimer() {}, setCanvasCommands() {}, onCanvasFrame() {}, clearCanvasFrame() {},
    fetch: async () => ({ status: 200, body: "{}" }), storageRead() { return null; }, storageWrite() {}, log() {},
  };
}

async function runHotSwapFixture({ seed, initial = "0", addedHook = false }) {
  const source = `
    import { h, useEffect, useRef, useState, widget } from "./src/index.ts";
    widget({ name: "Hot swap fixture", size: [100, 50] }, () => {
      ${addedHook ? "useState(\"new slot\");" : ""}
      const [count] = useState(${initial});
      const marker = useRef("kept");
      useEffect(() => {}, []);
      globalThis.fixtureRendered = { count, marker: marker.current };
      return h("text", null, String(count));
    });
    globalThis.fixtureAccepted = globalThis.__weaverHotSwapAccepted();
    globalThis.fixtureSnapshot = globalThis.__weaverCaptureHotSwap();
  `;
  const output = await build({
    stdin: { contents: source, resolveDir: fileURLToPath(new URL("..", import.meta.url)), sourcefile: "hot-swap-fixture.ts" },
    bundle: true, format: "iife", platform: "neutral", write: false,
  });
  const context = { native: isolatedNative(), __weaverHotSwapSeed: seed };
  vm.runInNewContext(output.outputFiles[0].text, context);
  return context;
}

test("hot swap captures and seeds root hook slots only when every slot type matches", async () => {
  const original = await runHotSwapFixture({});
  const snapshot = JSON.parse(original.fixtureSnapshot);
  assert.deepEqual(snapshot.map(({ kind, valueType }) => [kind, valueType]), [
    ["state", "number"], ["ref", "string"], ["effect", undefined],
  ]);

  snapshot[0].value = 42;
  snapshot[1].value = "preserved ref";
  const compatible = await runHotSwapFixture({ seed: JSON.stringify(snapshot) });
  assert.equal(compatible.fixtureAccepted, true);
  assert.deepEqual(JSON.parse(JSON.stringify(compatible.fixtureRendered)), { count: 42, marker: "preserved ref" });

  const changedType = await runHotSwapFixture({ seed: JSON.stringify(snapshot), initial: "\"fresh\"" });
  assert.equal(changedType.fixtureAccepted, false);
  const changedOrder = await runHotSwapFixture({ seed: JSON.stringify(snapshot), addedHook: true });
  assert.equal(changedOrder.fixtureAccepted, false);
});
