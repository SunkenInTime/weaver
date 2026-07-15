# Installation owns a source copy

A `.weave` is a deterministic ZIP containing readable source plus its audit and lineage envelope. `weaver install` validates it, copies the source into Weaver-owned storage, builds that copy locally, and registers only the owned path; only `weaver dev` runs a developer workspace by reference. This costs an extra copy and requires atomic replacement, but prevents later workspace edits, moves, generated output, or sender-controlled paths from silently changing an Installed Widget, and gives Remix a stable source boundary.
