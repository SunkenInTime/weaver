import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";

const weaveBundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/weave.ts", import.meta.url))],
  bundle: true,
  format: "esm",
  platform: "node",
  write: false,
});
const weave = await import(`data:text/javascript;base64,${Buffer.from(weaveBundle.outputFiles[0].contents).toString("base64")}`);

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "weaver-archive-"));
  writeFileSync(join(root, "widget.tsx"), "export default widget({ name: \"Archive Test\", size: [100, 100] }, () => <text>hello</text>);\n");
  writeFileSync(join(root, "tsconfig.json"), "{\"compilerOptions\":{\"paths\":{\"@weaver/sdk\":[\"C:/private/sdk\"]}}}\n");
  writeFileSync(join(root, "safe.txt"), "safe asset\n");
  writeFileSync(join(root, "bundle.js"), "compiled output");
  writeFileSync(join(root, "widget.json"), "{\"legacy\":true}\n");
  mkdirSync(join(root, "dist"));
  writeFileSync(join(root, "dist", "bundle.js"), "generated");
  mkdirSync(join(root, "art"));
  writeFileSync(join(root, "art", "pixel.bin"), Buffer.from([0, 1, 2, 3]));
  return root;
}

test(".weave packing is deterministic and contains source rather than build output", () => {
  const root = fixture();
  try {
    const declared = { providers: ["time"], origins: ["api.example.com"], capabilities: [] };
    const first = weave.packWeave(root, "Archive Test", declared);
    const second = weave.packWeave(root, "Archive Test", declared);
    const metadataVariant = weave.packWeave(root, "Archive Test", { ...declared, origins: ["other.example.com"] });
    assert.deepEqual(first.bytes, second.bytes);
    assert.match(first.manifest.artifactId, /^sha256:[0-9a-f]{64}$/);
    assert.match(first.manifest.sourceId, /^sha256:[0-9a-f]{64}$/);
    assert.notEqual(first.manifest.artifactId, first.manifest.sourceId);
    assert.equal(metadataVariant.manifest.sourceId, first.manifest.sourceId);
    assert.notEqual(metadataVariant.manifest.artifactId, first.manifest.artifactId);
    assert.equal(first.manifest.lineage.root, first.manifest.sourceId);
    assert.equal(first.manifest.lineage.parent, null);
    const opened = weave.openWeave(first.bytes);
    assert.deepEqual(opened.manifest.declared, declared);
    assert.deepEqual([...opened.files.keys()], ["art/pixel.bin", "safe.txt", "widget.tsx"]);
    assert.equal(opened.files.has("tsconfig.json"), false);
    assert.equal(opened.files.has("bundle.js"), false);
    assert.equal(opened.files.has("widget.json"), false);
    assert.equal(opened.files.has("dist/bundle.js"), false);

    const extracted = join(root, "extracted");
    weave.extractWeave(opened, extracted);
    assert.equal(readFileSync(join(extracted, "safe.txt"), "utf8"), "safe asset\n");
    assert.equal(JSON.parse(readFileSync(join(extracted, "weave.json"), "utf8")).artifactId, first.manifest.artifactId);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test(".weave reader rejects traversal paths before extraction", () => {
  const root = fixture();
  try {
    const packed = weave.packWeave(root, "Archive Test", { providers: [], origins: [], capabilities: [] });
    const malicious = Buffer.from(packed.bytes);
    const from = Buffer.from("source/safe.txt");
    const to = Buffer.from("source/../x.txt");
    assert.equal(from.length, to.length);
    let replacements = 0;
    for (let offset = malicious.indexOf(from); offset !== -1; offset = malicious.indexOf(from, offset + to.length)) {
      to.copy(malicious, offset);
      replacements += 1;
    }
    assert.equal(replacements, 2);
    assert.throws(() => weave.openWeave(malicious), /Unsafe archive path/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test(".weave reader rejects Unix symlink entries", () => {
  const root = fixture();
  try {
    const packed = weave.packWeave(root, "Archive Test", { providers: [], origins: [], capabilities: [] });
    const malicious = Buffer.from(packed.bytes);
    const name = Buffer.from("source/safe.txt");
    const centralName = malicious.lastIndexOf(name);
    assert.notEqual(centralName, -1);
    const centralHeader = centralName - 46;
    assert.equal(malicious.readUInt32LE(centralHeader), 0x02014b50);
    malicious.writeUInt32LE((0o120777 << 16) >>> 0, centralHeader + 38);
    assert.throws(() => weave.openWeave(malicious), /link or special file/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test(".weave reader rejects corrupted payloads", () => {
  const root = fixture();
  try {
    const packed = weave.packWeave(root, "Archive Test", { providers: [], origins: [], capabilities: [] });
    const corrupted = Buffer.from(packed.bytes);
    const name = Buffer.from("source/safe.txt");
    const localName = corrupted.indexOf(name);
    assert.notEqual(localName, -1);
    const dataOffset = localName + name.length;
    corrupted[dataOffset] ^= 0xff;
    assert.throws(() => weave.openWeave(corrupted), /could not be decompressed|checksum is invalid/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
