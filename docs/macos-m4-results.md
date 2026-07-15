# macOS M4 — HTTPS network parity

Recorded 2026-07-15 on a MacBook Air with Apple M2 (8 cores, 8 GB), macOS
26.5.1 (25F80), arm64, Zig 0.16.0, and Node 23.11.0.

## Claim

`wfetch` now uses an ephemeral public `NSURLSession` transport on macOS while
preserving the existing request/result and QuickJS worker contract. Runtime
policy remains in portable Zig: HTTPS-only parsing, case-insensitive exact-host
declarations, GET/POST, validated string headers, four bounded worker slots,
and main-loop-only promise completion. The Objective-C seam owns only the
system HTTPS exchange.

The implementation is published as stacked draft
[Weaver PR #7](https://github.com/SunkenInTime/weaver/pull/7), based on the
display/anchoring layer.

The macOS transport uses the system trust store, has no cookie store or URL
cache, returns the original 3xx instead of following redirects, enforces a
15-second whole-exchange deadline, streams into a 5 MiB response cap, and
participates in active-request cancellation during engine shutdown. The total
URL + headers + body request is also capped at 5 MiB before a worker starts.

## Transport shape

- `NSURLSessionConfiguration.ephemeralSessionConfiguration` provides the
  public system TLS/trust path without shared cookies or persisted cache.
- A serial session delegate receives response bytes incrementally. Declared
  `Content-Length` values over the cap are rejected before buffering; unknown
  lengths are cancelled at the first chunk crossing the same cap.
- The redirection delegate passes `nil` for every redirect request. Widgets
  receive the original HTTP 3xx, matching WinHTTP's stricter no-follow policy,
  so a system client can never cross the manifest host check invisibly.
- The Zig bridge copies request data before spawning one of its existing four
  workers. Only `drainFetches` touches QuickJS and runs promise continuations.
- Every live fetch slot has an atomic cancellation byte. Teardown marks all
  slots first, then joins; the macOS exchange notices within its 25 ms wait
  quantum and cancels its `NSURLSessionDataTask`.
- Production compilation contains no test trust override. The loopback test
  entry point exists only with `WEAVER_NETWORK_TESTING=1`; ordinary builds
  always perform default system trust handling.

## Deterministic loopback HTTPS matrix

The runtime test creates a one-day RSA certificate with `localhost` SANs,
starts `runtime/test/https_server.py` on `127.0.0.1` at an OS-selected port,
and uses the real NSURLSession transport. A test-only exact-leaf trust hook
admits that generated certificate for success cases. The certificate-failure
case calls the production trust entry point against the same self-signed
server and is rejected.

| Case | Expected | Result |
|---|---|---|
| HTTPS GET + request header | `200`, `GET|alpha|ok` | PASS |
| HTTPS POST + headers/body | `201`, `POST|beta|payload` | PASS |
| Cross-origin redirect attempt | original `302`, no follow | PASS |
| Body larger than 5 MiB | `response_too_large` | PASS |
| Whole-exchange test deadline | `timed_out` | PASS |
| Self-signed certificate through production trust | `request_failed` | PASS |
| Active request cancellation | `cancelled` in under one second | PASS |
| Malformed/missing-host/userinfo/bad-port URLs | rejected before transport | PASS |
| Total request over 5 MiB | rejected before worker allocation | PASS |

The fixture avoids external DNS and network availability. It also overrides
`HTTPServer`'s unnecessary reverse-DNS bind lookup so runner DNS cannot affect
readiness.

## Production end-to-end proof

A temporary bundled `NetworkProbe` declared only `example.com`, called
`wfetch("https://example.com")`, rendered the response result, and wrote:

```text
widget console: NETWORK_OK status=200 bytes=559
```

The live system-trust request completed through the production ReleaseFast
binary. `CGWindowListCopyWindowInfo` simultaneously reported the rendered
300 x 80 Widget on-screen at `(24, 63)`. Normal
`NSRunningApplication.terminate()` produced `stop`, then `window_closed`, and
the process exited 0. This public-network probe is corroborating production
evidence; the loopback matrix above is the deterministic regression gate. Its
temporary bundle and log were removed afterward.

## Cost ledger

The idle network capability creates no NSURLSession, operation queue, request
worker, bridge polling timer, or response buffer. Those objects exist only
while one of the four request slots is active.

With no request active, the same 1 Hz Clock produced five one-second `top`
samples of `0.0, 1.0, 1.2, 0.9, 1.5` percent of one core: mean `0.92%`. It held
six threads. `/usr/bin/footprint --noCategories -p <pid>` reported 90 MB
physical and 90 MB peak. These short samples are consistent with the M2/M3
range but are not an Instruments attribution claim.

An exact ReleaseFast rebuild of PR04 commit `5a88b84` was 5,486,624 bytes. The
PR05 binary was 5,510,544 bytes: a 23,920-byte increase. Active requests add
one existing bounded Zig worker each plus system-client work and up to the
declared request/response buffers; no fixed network process is introduced.

## Regression gates

The following completed locally:

```text
cd runtime
zig build test --summary all                 # 12/12, includes loopback TLS
zig build test-platform-services
zig build -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast

cd ..
npm test                                     # 20/20
npm run typecheck
```

The macOS CI matrix now builds the ReleaseFast runtime and runs the complete
runtime suite on both Apple silicon and Intel in addition to the Native SDK
profiles. Windows keeps its WinHTTP linkage and behavior; the x64 cross-build
passes locally, while the existing Windows CI runs its ReleaseFast runtime
tests natively.
