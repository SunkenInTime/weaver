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
timestamps are fixed and entries are ordered.

`tsconfig.json`, `dist/`, legacy root `bundle.js`/`widget.json`, nested
`node_modules`, `.git`, and existing `.weave` output are not distribution
source. Install generates its local authoring config and builds `dist/` from
the received TSX.

## Validation wall

Before extraction, the reader rejects:

- absolute, drive-qualified, backslash, empty-segment, `.` and `..` paths;
- links, special files, duplicate paths, and Windows case collisions;
- encryption, data descriptors, unsupported compression, multi-disk/Zip64
  shapes, malformed/overlapping local and central records;
- more than 1,024 entries, a file over 16 MiB, more than 64 MiB unpacked or a
  `.weave` over 64 MiB;
- invalid UTF-8/JSON, unknown envelope fields, missing source, source-identity
  mismatch, bad sizes, decompression failure, and CRC mismatch.

The extracted source is checked and bundled again. Its name and declared
surface must exactly match the envelope; metadata cannot under-report what the
TSX asks for.

## Verification

- root `npm test`: 12/12 pass, including deterministic bytes, source-only
  contents, traversal rejection, symlink rejection, and payload corruption;
- root `npm run typecheck` and `npm run build`: pass;
- isolated `%LOCALAPPDATA%` production-path smoke: packed Clock installed from
  `.weave`, ran from the owned `widgets/` path, installed over itself
  atomically, exposed its source/metadata/runtime bundle, and uninstalled with
  both registry and owned source removed;
- directory input traveled through the same in-memory artifact validation and
  registered an owned copy rather than the original example workspace;
- the isolated host and all widget processes were stopped and its temporary
  data root removed after verification.
