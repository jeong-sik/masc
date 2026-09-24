# H2 request fibers and compression

## Problem and boundary

The H1 compression review (#38878, issue #38876) found that H2's request
callback is invoked directly by `H2.Server_connection.read`. A route waiting
for a CPU worker consequently holds that connection's reader: later streams,
PING, WINDOW_UPDATE and RST_STREAM cannot advance. The existing
`h2_respond_json_value_on_cpu` already has this wait. General compression
cannot move to the pool safely until the reader can continue independently.

The installed h2 0.13 source calls the handler in `server_connection.ml` and
passes the connection to `gluten-eio` through `h2-eio`. Eio's
[executor interface](https://github.com/ocaml-multicore/eio/blob/main/lib_eio/executor_pool.mli)
queues work when its workers are occupied. This is a source-level diagnosis;
new behavioral evidence is pending CI.

## Implementation

- `serve_h2_connection` runs socket I/O alongside a separate request switch.
  I/O completion cancels that switch and all request children, including
  ordinary fibers spawned by streaming responses. Both h2-only and automatic
  protocol listeners use this boundary.
- Header callbacks are dispatched on that switch and yield before any route
  work starts. Exceptions are reported to the affected h2 request; Eio
  cancellation propagates.
- Generic and OAuth body completions, including oversized-body replies,
  dispatch outside the connection reader. The gateway rebinds the parsed
  request authority around deferred callbacks.
- The factory retains its original server switch for MCP work and shared
  dashboard producers. A separate required `request_sw` owns callbacks and
  subscription streams, so disconnect does not redefine durable task lifetime.
- Shared H2 response compression uses the parent PR's immutable CPU adapter.
  Disabled/identity/sub-codec-minimum responses do not queue.

## Behavioral coverage prepared for CI

`test_h2_request_fibers` uses actual socketpairs and H2_eio peers with a held
one-domain CPU pool:

1. The old direct-reader path cannot acknowledge PING until the worker is
   released (bounded baseline observation, not a performance pass threshold).
2. GET JSON encoding and POST string compression preserve PING and sibling
   response progress while the slow response remains queued. The sibling body
   spans two initial windows, requiring WINDOW_UPDATE to complete.
3. POST HEADERS are sent first. A reader-registration handshake precedes DATA,
   forcing completion on the connection reader rather than a buffered-body
   callback inside the request fiber.
4. RST_STREAM suppresses a delayed response and permits another stream/PING.
5. Closing the socket cancels a queued response and an ordinary child fiber
   before the held CPU worker is released.
6. A handler exception becomes a stream 500 while siblings remain usable.

`test_h2_oauth_request_fibers` uses the actual OAuth gateway and synthetic
workspace. It splits HEADERS/DATA, covers EOF and oversize without EOF,
requires PING/sibling progress before releasing the worker, then compares the
complete OAuth error body and headers. Existing body-admission and dashboard
route tests are retained with the explicit request scope.

## Review and verification status

Adversarial review found an OAuth-specific body reader that bypassed the
first implementation, and a POST fixture that could accidentally test a
prebuffered body. Both were corrected and independently rechecked. The parent
also preserved server/request lifetime separation after inspecting MCP's
switch propagation. Formatting and whitespace checks pass. No local OCaml
build or behavioral test was run under the repository execution protocol.
Exact-source CI is pending.

## Limits

A stream reset closes h2's response state and prevents a later response. The
public h2 interface does not notify application request fibers of that reset;
this change does not claim immediate cancellation of the CPU computation on
RST_STREAM. Connection termination does cancel request work. No new timeout,
wire parser, dependency patch, production restart or deployment is introduced.
No 0.1ms claim is made. Shared-pool queueing, JSON work on the main domain,
and full live-runtime latency still require measurement and further work.
