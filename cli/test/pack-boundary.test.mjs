import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";

const cli = fileURLToPath(new URL("../dist/index.js", import.meta.url));
const weaveBundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/weave.ts", import.meta.url))],
  bundle: true,
  format: "esm",
  platform: "node",
  write: false,
});
const weave = await import(`data:text/javascript;base64,${Buffer.from(weaveBundle.outputFiles[0].contents).toString("base64")}`);

function runCli(cwd, ...arguments_) {
  return spawnSync(process.execPath, [cli, ...arguments_], { cwd, encoding: "utf8" });
}

function initFixture(prefix) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  const initialized = runCli(root, "init", "widget");
  assert.equal(initialized.status, 0, initialized.stderr);
  return { root, widget: join(root, "widget"), artifact: join(root, "widget.weave") };
}

function sourceWithImport(name, specifier) {
  return `import { widget } from "@weaver/sdk";
import { message } from ${JSON.stringify(specifier)};

export default widget({ name: ${JSON.stringify(name)}, size: [100, 100] }, () => <text>{message}</text>);
`;
}

test("check and pack keep module dependencies inside the portable source root", () => {
  const { root, widget, artifact } = initFixture("weaver-pack-boundary-");
  try {
    const nestedSource = "export const message = \"inside archive\";\n";
    mkdirSync(join(widget, "lib"));
    writeFileSync(join(widget, "lib", "message.ts"), nestedSource, "utf8");
    writeFileSync(join(widget, "widget.tsx"), sourceWithImport("Module Boundary", "./lib/message"), "utf8");

    const nestedCheck = runCli(root, "check", widget);
    assert.equal(nestedCheck.status, 0, nestedCheck.stderr);
    const nestedPack = runCli(root, "pack", widget);
    assert.equal(nestedPack.status, 0, nestedPack.stderr);
    assert.equal(existsSync(artifact), true);

    const acceptedBytes = readFileSync(artifact);
    assert.equal(acceptedBytes.includes(Buffer.from("source/lib/message.ts", "utf8")), true);
    const opened = weave.openWeave(acceptedBytes);
    assert.equal(opened.files.get("lib/message.ts")?.toString("utf8"), nestedSource);

    writeFileSync(join(root, "outside.ts"), "export const message = \"outside archive\";\n", "utf8");
    writeFileSync(join(widget, "widget.tsx"), sourceWithImport("Module Boundary", "../outside"), "utf8");

    const escapedCheck = runCli(root, "check", widget);
    const escapedPack = runCli(root, "pack", widget);
    assert.deepEqual(
      { check: escapedCheck.status, pack: escapedPack.status },
      { check: 1, pack: 1 },
      "check and pack must both reject an out-of-root import",
    );
    assert.match(`${escapedCheck.stderr}\n${escapedPack.stderr}`, /outside|source (?:directory|root)|project root|escape/i);
    assert.deepEqual(readFileSync(artifact), acceptedBytes, "a rejected pack overwrote the last valid artifact");

    rmSync(artifact);
    const cleanRejectedPack = runCli(root, "pack", widget);
    assert.equal(cleanRejectedPack.status, 1, "pack unexpectedly accepted an out-of-root import");
    assert.equal(existsSync(artifact), false, "a rejected pack emitted a new artifact");

    const absoluteModule = join(widget, "lib", "message").replaceAll("\\", "/");
    writeFileSync(join(widget, "widget.tsx"), sourceWithImport("Module Boundary", absoluteModule), "utf8");
    const absoluteRejectedPack = runCli(root, "pack", widget);
    assert.equal(absoluteRejectedPack.status, 1, "pack unexpectedly accepted a sender-local absolute import");
    assert.match(absoluteRejectedPack.stderr, /absolute import.*not portable/i);
    assert.equal(existsSync(artifact), false, "an absolute-import rejection emitted an artifact");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check rejects control characters in config.name before packing", () => {
  const { root, widget, artifact } = initFixture("weaver-name-boundary-");
  try {
    for (const name of ["line one\nline two", "escape\u001bsequence"]) {
      writeFileSync(join(widget, "widget.tsx"), `import { widget } from "@weaver/sdk";
export default widget({ name: ${JSON.stringify(name)}, size: [100, 100] }, () => <text>name</text>);
`, "utf8");
      const checked = runCli(root, "check", widget);
      const packed = runCli(root, "pack", widget);
      assert.deepEqual(
        { check: checked.status, pack: packed.status },
        { check: 1, pack: 1 },
        `check and pack must reject ${JSON.stringify(name)}`,
      );
      assert.match(`${checked.stderr}\n${packed.stderr}`, /config\.name.*(?:control|printable|single.line)/i);
      assert.equal(existsSync(artifact), false);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
