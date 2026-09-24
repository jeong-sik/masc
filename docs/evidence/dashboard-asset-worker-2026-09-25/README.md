# Dashboard static asset compression worker

## Change and dependency

The HTTP/1 dashboard static responder and HTTP/2 dashboard asset route now use
the existing `Http_response_payload.compress_body_on_cpu` adapter. Negotiation,
compression thresholds, MIME types, cache policy and final response writes stay
with their current owners. Only immutable payload bytes and codec selection
cross the CPU worker boundary.

This stacks on #38886 (`78ca7483a24cfe88453ab71a169162bec3a16233`), which moves
HTTP/2 handlers off the connection reader. Calling a suspending compression
adapter directly from that reader would stall sibling streams and flow control.
The adapter itself comes from #38878.

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

Static syntax/format and `git diff --check` passed. Behavioral execution awaits
CI; no local OCaml build is run under the constitution execution protocol.

## Limits

- Worker queueing can increase the compressed request's own latency. This change
  protects scheduling of other requests; no end-to-end speedup is claimed.
- The existing filesystem read, asset verification and compression policy are
  unchanged. No new compressed cache or configuration knob is added.
- This is source and fixture coverage. No production deployment, browser result
  or 0.1ms target achievement is established.
