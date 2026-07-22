import assert from "node:assert/strict";
import test from "node:test";
import { compileClass } from "../src/class-compiler.ts";

test("class compiler maps the frozen M1 utility surface", () => {
  assert.deepEqual(
    compileClass("p-4 gap-[3px] rounded-2xl bg-[#123]/50 text-[#abcdef] grow w-12 truncate"),
    {
      padding: 16,
      gap: 3,
      radius: 16,
      background: "#11223380",
      textColor: "#ABCDEFFF",
      grow: 1,
      width: 48,
      truncate: true,
    },
  );
});

test("unknown utilities carry an actionable fix-it", () => {
  assert.throws(() => compileClass("pad-13"), /Unknown class utility "pad-13"\. Did you mean "p-\[13px\]"\?/);
});

test("arbitrary uniform padding returns its compiled value", () => {
  assert.deepEqual(compileClass("p-[13px]"), { padding: 13 });
});

test("styling 01 accepts directional spacing sizing fractions and aspect ratios", () => {
  assert.deepEqual(
    compileClass("p-2 px-4 pt-[3px] m-2 -mx-1 mb-[5px] w-1/2 h-full min-w-12 max-w-[160px] min-h-4 max-h-20 aspect-[4/3]"),
    {
      padding: 8,
      paddingLeft: 16,
      paddingRight: 16,
      paddingTop: 3,
      marginTop: 8,
      marginRight: -4,
      marginBottom: 5,
      marginLeft: -4,
      widthPercent: 50,
      heightPercent: 100,
      minWidth: 48,
      maxWidth: 160,
      minHeight: 16,
      maxHeight: 80,
      aspectRatio: 4 / 3,
    },
  );
  assert.deepEqual(compileClass("px-4 p-2"), { padding: 8 });
  assert.deepEqual(compileClass("w-full w-12 w-auto h-1/4 size-[20px]"), { width: 20, height: 20 });
  assert.deepEqual(compileClass("aspect-video aspect-auto aspect-square"), { aspectRatio: 1 });
  assert.deepEqual(compileClass("w-0 h-[0px] max-w-0 max-h-[0px]"), {
    width: 0, height: 0, maxWidth: 0, maxHeight: 0,
  });
});

test("styling 01 utility families each have an accept case", () => {
  const cases = [
    ["px-1", { paddingLeft: 4, paddingRight: 4 }],
    ["py-[3px]", { paddingTop: 3, paddingBottom: 3 }],
    ["pt-1", { paddingTop: 4 }], ["pr-1", { paddingRight: 4 }],
    ["pb-1", { paddingBottom: 4 }], ["pl-1", { paddingLeft: 4 }],
    ["m-1", { marginTop: 4, marginRight: 4, marginBottom: 4, marginLeft: 4 }],
    ["mx-1", { marginLeft: 4, marginRight: 4 }],
    ["my-1", { marginTop: 4, marginBottom: 4 }],
    ["mt-1", { marginTop: 4 }], ["mr-1", { marginRight: 4 }],
    ["mb-1", { marginBottom: 4 }], ["ml-1", { marginLeft: 4 }],
    ["-m-[2px]", { marginTop: -2, marginRight: -2, marginBottom: -2, marginLeft: -2 }],
    ["w-full", { widthPercent: 100 }], ["h-3/4", { heightPercent: 75 }],
    ["w-4 w-auto", {}], ["h-full h-auto", {}],
    ["size-3", { width: 12, height: 12 }],
    ["size-[7px]", { width: 7, height: 7 }],
    ["size-full", { widthPercent: 100, heightPercent: 100 }],
    ["min-w-2", { minWidth: 8 }], ["min-h-[9px]", { minHeight: 9 }],
    ["max-w-10", { maxWidth: 40 }], ["max-h-[11px]", { maxHeight: 11 }],
    ["aspect-square", { aspectRatio: 1 }], ["aspect-video", { aspectRatio: 16 / 9 }],
    ["aspect-[3/2]", { aspectRatio: 1.5 }], ["aspect-[1.25]", { aspectRatio: 1.25 }],
    ["aspect-square aspect-auto", {}],
  ];
  for (const [utility, expected] of cases) assert.deepEqual(compileClass(utility), expected, utility);
});

test("styling 01 rejects malformed new utilities with fix-its", () => {
  assert.throws(() => compileClass("w-3/0"), /Unknown class utility "w-3\/0"\. Did you mean/);
  assert.throws(() => compileClass("w-0/1"), /Unknown class utility "w-0\/1"\. Did you mean/);
  assert.throws(() => compileClass("w-3/2"), /Unknown class utility "w-3\/2"\. Did you mean/);
  assert.throws(() => compileClass("aspect-[4/0]"), /Unknown class utility "aspect-\[4\/0\]"\. Did you mean/);
  assert.throws(() => compileClass("-pt-4"), /Unknown class utility "-pt-4"\. Did you mean/);
  assert.throws(() => compileClass("px-[-1px]"), /Unknown class utility "px-\[-1px\]"\. Did you mean/);
  assert.throws(() => compileClass("mx-[2rem]"), /Unknown class utility "mx-\[2rem\]"\. Did you mean/);
  assert.throws(() => compileClass("size-auto"), /Unknown class utility "size-auto"\. Did you mean/);
  assert.throws(() => compileClass("min-w-full"), /Unknown class utility "min-w-full"\. Did you mean/);
  assert.throws(() => compileClass("aspect-[0]"), /requires an aspect ratio greater than zero/);
  assert.throws(() => compileClass(`p-[${"9".repeat(400)}px]`), /non-finite or absurd numeric value/);
  assert.throws(() => compileClass("w-[1000001px]"), /non-finite or absurd numeric value/);
  assert.throws(() => compileClass("aspect-[1000001]"), /non-finite or absurd numeric value/);
});

test("styling 02 accepts complete flex utilities and rejects near misses", () => {
  const cases = [
    ["justify-around", { mainAlign: "around" }],
    ["justify-evenly", { mainAlign: "evenly" }],
    ["grow-3", { grow: 3 }],
    ["grow-[2.5]", { grow: 2.5 }],
    ["shrink", { shrink: 1 }],
    ["shrink-0", { shrink: 0 }],
    ["self-auto", { alignSelf: "auto" }],
    ["self-start", { alignSelf: "start" }],
    ["self-center", { alignSelf: "center" }],
    ["self-end", { alignSelf: "end" }],
    ["self-stretch", { alignSelf: "stretch" }],
    ["flex-wrap", { flexWrap: true }],
    ["flex-wrap flex-nowrap", { flexWrap: false }],
  ];
  for (const [utility, expected] of cases) assert.deepEqual(compileClass(utility), expected, utility);
  assert.throws(() => compileClass("justify-space-around"), /Unknown class utility/);
  assert.throws(() => compileClass("shrink-2"), /Unknown class utility/);
  assert.throws(() => compileClass("self-baseline"), /Unknown class utility/);
  assert.throws(() => compileClass("flex-wrap-reverse"), /Unknown class utility/);
});

