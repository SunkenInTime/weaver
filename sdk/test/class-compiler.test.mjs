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
  assert.throws(() => compileClass("px-4"), /arrives in M2\+/);
});

