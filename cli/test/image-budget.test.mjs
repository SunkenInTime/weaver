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

function pngHeader(width, height) {
  const bytes = Buffer.alloc(24);
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(bytes);
  bytes.writeUInt32BE(width, 16);
  bytes.writeUInt32BE(height, 20);
  return bytes;
}

function fixture(width, height) {
  const root = mkdtempSync(join(tmpdir(), "weaver-image-budget-"));
  const initialized = runCli(root, "init", "widget");
  assert.equal(initialized.status, 0, initialized.stderr);
  const widget = join(root, "widget");
  writeFileSync(join(widget, "cover.png"), pngHeader(width, height));
  writeFileSync(
    join(widget, "widget.tsx"),
    `import { widget } from "@weaver/sdk";
export default widget({ name: "Image Budget", size: [320, 200] }, () => (
  <image src="./cover.png" class="w-[256px] h-[256px]" />
));
`,
    "utf8",
  );
  return { root, widget };
}

test("check reports exact decoded RGBA image budget math", () => {
  const { root, widget } = fixture(257, 256);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /ImageTooLarge/);
    assert.match(checked.stderr, /257 \* 256 \* 4 = 263168 bytes/);
    assert.match(checked.stderr, /max_image_rgba_bytes=262144 by 1024 bytes/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check accepts an image exactly at the decoded RGBA budget", () => {
  const { root, widget } = fixture(256, 256);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 0, checked.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
