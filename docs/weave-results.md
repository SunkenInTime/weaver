# Portable `.weave` pack/install results

The source-sharing boundary is now real. `weaver pack <dir>` emits a
deterministic ZIP with no compiled output or machine-specific authoring
configuration. `weaver install <dir|file.weave>` validates the same artifact
path either way, prints its declared providers/origins/capabilities, builds an
owned source copy under Weaver's data root, and registers only that copy.

## Format v1

Each archive contains `weave.json` and regular files below `source/`.
`weave.json` carries `formatVersion`, SHA-256 source and artifact identities,
display name, nullable author provenance, root/parent lineage, and the declared
provider/origin/capability surface. The source identity hashes sorted path and
byte-content records. The artifact identity hashes the full envelope, including
the source identity, so provenance or lineage cannot change while retaining the
same artifact identity. The same input produces the same artifact bytes;
timestamps are fixed, entries are ordered, and v1 uses stored ZIP entries rather
than runtime-dependent compressor output.

`tsconfig.json`, `dist/`, legacy root `bundle.js`/`widget.json`, nested
`node_modules`, `.git`, and existing `.weave` output are not distribution
source. Install generates its local authoring config and builds `dist/` from
the received TSX.

## Validation wall

Before extraction, the reader rejects:

- absolute, drive-qualified, backslash, empty-segment, `.` and `..` paths;
- links, special files, duplicate paths, file/directory prefix conflicts, and
  Windows case collisions;
- encryption, data descriptors, unsupported compression, multi-disk/Zip64
  shapes, archive prefixes/gaps/comments/extras, trailing compressed bytes, and
  malformed/overlapping local and central records;
- more than 1,024 entries, a file over 16 MiB, `weave.json` over 64 KiB, more
  than 64 MiB total unpacked, or a `.weave` over 64 MiB;
- invalid UTF-8/JSON, unknown envelope fields, missing source, source-identity
  mismatch, unsafe display metadata, bad sizes, decompression failure, and CRC
  mismatch.

The extracted source is checked and bundled again. Its name and declared
surface must exactly match the envelope; metadata cannot under-report what the
TSX asks for.

## Verification

- root `npm test`: 20/20 pass, including deterministic bytes, canonical ZIP
  framing, aggregate limits, source-only contents, traversal/symlink/collision
  rejection, registry serialization, source-root import containment, and safe
  display metadata;
- root `npm run typecheck` and `npm run build`: pass;
- isolated `%LOCALAPPDATA%` production-path smoke: packed Clock installed from
  `.weave`, ran from an immutable owned `widgets/` path, switched to a second
  owned version through an acknowledged registry reload, collected the old
  version, and uninstalled with both registry and owned source removed;
- directory input traveled through the same in-memory artifact validation and
  registered an owned copy rather than the original example workspace;
- the isolated host and all widget processes were stopped and its temporary
  data root removed after verification.
