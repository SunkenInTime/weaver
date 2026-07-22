import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const cli = fileURLToPath(new URL("../dist/index.js", import.meta.url));

function runCli(cwd, ...arguments_) {
  return spawnSync(process.execPath, [cli, ...arguments_], { cwd, encoding: "utf8" });
}

function fixture(source) {
  const root = mkdtempSync(join(tmpdir(), "weaver-lowered-budget-"));
  const initialized = runCli(root, "init", "widget");
  assert.equal(initialized.status, 0, initialized.stderr);
  const widget = join(root, "widget");
  writeFileSync(join(widget, "widget.tsx"), source, "utf8");
  return { root, widget };
}

function source(tree) {
  return `import { widget } from "@weaver/sdk";
export default widget({ name: "Lowered Budget", size: [320, 200] }, () => (${tree}));
`;
}

test("check rejects node counts after painted row and column lowering", () => {
  const groups = Array.from({ length: 5 }, (_, group) =>
    `<column key="g${group}">${Array.from({ length: 24 }, (_, child) => `<row key="r${group}-${child}" class="bg-[#111]" />`).join("")}</column>`,
  ).join("");
  const { root, widget } = fixture(source(`<column>${groups}</column>`));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetNodeLimit: this tree lowers to 246 Native nodes \(limit 128\)/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check rejects depth after painted layout lowering", () => {
  let tree = "<text>leaf</text>";
  for (let index = 0; index < 16; index += 1) tree = `<row class="border">${tree}</row>`;
  const { root, widget } = fixture(source(tree));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetDepthLimit: this tree lowers to depth 33 \(Native limit 32\)/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
