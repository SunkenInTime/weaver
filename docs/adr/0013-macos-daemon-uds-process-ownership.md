# macOS daemon uses one control socket, one provider socket per Widget, and validated child ownership

The macOS host projects the portable supervisor through one permission-restricted
Unix-domain control socket for `probe`, `reload`, and `down`. Reload and down
are request/acknowledgement operations, not filesystem hints: a reload is
acknowledged only after registry reconciliation, synchronous stop/launch work,
and status publication have completed. Each provider-subscribed Widget receives
its own cryptographically unguessable Unix socket through the private
`WEAVER_HOST_ENDPOINT` child environment. The public SDK and `.weave` format
remain unaware of sockets, AppKit, processes, and macOS paths.

All endpoints live below a mode-0700, per-user ephemeral root. The host prefers
`TMPDIR`, but falls back to the short public `/tmp` root when the longest
per-Widget endpoint would exceed macOS `sun_path`; the data-root hash keeps
isolated HOME roots distinct. Startup removes stale socket state only after
acquiring the singleton lock. Normal removal closes the child and provider
stream before deleting its endpoint, and normal daemon shutdown removes the
entire runtime root and singleton file.

macOS has no direct public equivalent of the Windows kill-on-close Job object.
Each launched runtime therefore gets a marker containing the exact runtime
executable path. A replacement host treats a marker as ownership evidence only
when `proc_pidpath` still reports that exact executable for that PID; it then
kills the old process group before deleting stale IPC and reconciling the
registry. This closes the host-crash/orphan order without risking an unrelated
process after PID reuse. The rejected alternatives are leaving orphan Widgets,
killing unvalidated status PIDs, a polling parent-death timer in every quiet
Widget, and a shared renderer/window service already rejected by ADR 0012.

The host remains the sole owner of supervision, provider endpoints, process
metrics, and child lifecycle. One Widget remains one crash-isolated runtime
process, and its renderer remains in-process on macOS. PR 11 may add actual CPU
and memory samples to these endpoints; it does not change this ownership or
transport decision.
