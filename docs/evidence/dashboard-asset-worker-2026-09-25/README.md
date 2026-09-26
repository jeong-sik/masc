# Dashboard static asset compression worker

## Change and dependency

The HTTP/1 dashboard static responder and HTTP/2 dashboard asset route now use
the existing `Http_response_payload.compress_body_on_cpu` adapter. Negotiation,
compression thresholds, MIME types, cache policy and final response writes stay
with their current owners. Only immutable payload bytes and codec selection
cross the CPU worker boundary.

This change now starts from main `08cbfc631b610f130bb9f1d9010e309ff211eeef`,
which includes #38886 and #38878. HTTP/2 handlers run off the connection reader
with per-stream cancellation. Calling a suspending compression adapter directly
from the reader would stall sibling streams and flow control.

## Behavioral verification

`test_dashboard_asset_worker` adds four socketpair scenarios: HTTP/1 and HTTP/2,
each negotiating gzip and zstd. A single CPU worker is held by a promise. The
actual static asset responder must suspend while identity, noncompressible and
sub-threshold asset responses complete. HTTP/2 must also acknowledge PING on
the same connection. Releasing the worker must produce the exact original
Unicode bytes after decompression, with the existing encoding, content length,
content type, Vary and immutable cache headers.

The fixture temporarily clears the optional Eio filesystem registration so its
small synthetic files are read synchronously. This makes the route admission
handshake conclusive: no file-read suspension can masquerade as a queued codec.
It restores that registration and the asset-root environment after each case.
This does not measure production file I/O scheduling or installed asset loading.

The original focused CI run 36042596174 failed to compile because this new
fixture did not declare its direct `gluten` dependency. That declaration is now
present. The same run also found a polymorphic method type error in the parent
H2 fixture; current main already fixes it. The H2 fixture uses `shutdown` before
joining the connection, following main's repair for a read keeping the FD open.

Static syntax/format and `git diff --check` passed. Behavioral execution awaits
CI on the updated source; no local OCaml build is run under the constitution
execution protocol. The previous compile failure is not a behavioral result.

## Limits

- Worker queueing can increase the compressed request's own latency. This change
  protects scheduling of other requests; no end-to-end speedup is claimed.
- The existing filesystem read, asset verification and compression policy are
  unchanged. No new compressed cache or configuration knob is added.
- This is source and fixture coverage. No production deployment, browser result
  or 0.1ms target achievement is established.
