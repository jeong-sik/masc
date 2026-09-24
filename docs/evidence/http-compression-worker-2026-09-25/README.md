# HTTP/1 response compression worker

## Observed source of scheduler work

The authenticated runtime probe and bounded main-domain profile are in
[PR #38870](https://github.com/jeong-sik/masc/pull/38870).
The five-second profile observed 28 samples directly under
`Http_server_eio.prepare_json -> Http_response_payload.compress_body -> Compression_gzip.compress`
and gzip allocation / GC work on the main domain.

- Runtime source: `0c7a2d4f6babd942179ed942a732d9320b305264`.
- Executable SHA256: `d66654148abe6905d3616378b889cb318b7d9cef4ef59fdf5971faed500c8dc6`.
- Profile SHA256: `0199ba47b13b9a6c4a6e4c2024ffd5c4165c6722346e4ef44e171cf22838f68e`.

This sampled stack establishes that synchronous compression happens on the
scheduler domain. It does not attribute all HTTP/MCP latency to compression.

## Change

H1 JSON, lazy JSON and cached HTML submit only immutable compression inputs
to the existing `Domain_pool` CPU
path. Request selection, lazy body closures, response objects and writes stay
on the caller. Already-running executor jobs do not resubmit to their own
pool. `Http_response_payload.prepare` remains a synchronous producer helper.

Responses with compression disabled, identity negotiation, or bodies below
`Compression_codec.min_size` avoid queueing. H1 matching validators return
304 before compression. The codec threshold is reused without another knob.

This follows the existing shared-pool policy and the
[Eio executor interface](https://github.com/ocaml-multicore/eio/blob/main/lib_eio/executor_pool.mli).

## H2 follow-up boundary

H2 compression is outside this change. `Server_bootstrap_http.serve_h2` and
the H2 branch of `serve_auto` create one fiber per connection. The installed
`h2-eio` adapter passes the route callback directly to
`H2.Server_connection.create`; `H2.Server_connection.read` calls it while
processing incoming frames. Awaiting a shared compression worker in that
callback stops the connection reader from processing later streams, PING,
WINDOW_UPDATE and RST_STREAM until the worker responds. Sequential wire
parity cannot establish multiplexing progress.

H2 worker compression requires a follow-up that gives each request its own
fiber with appropriate stream/connection cancellation ownership, then proves
sibling-stream and control-frame progress while the worker pool is occupied.
The shared H2 helper and its test retain their base implementation here.
The existing `h2_respond_json_value_on_cpu` already awaits an executor from
the route callback; its connection-progress risk also belongs in that follow-up.

## Verification scope

- `test_http_server_eio`: single occupied worker; caller fiber progress;
  cancellation before response writes and after a worker barrier; unqueued
  small, identity, disabled and matching-validator responses; lazy closure
  owner domain; complete H1 identity/gzip/zstd wire parity with a real pool.
- Existing `test_compression`: negotiation, gzip decoding and snapshot
  representations remain the pure-codec regression coverage.
- Local `ocamlformat --check` and `git diff --check` passed. No local OCaml
  build or behavioral test was run. Exact-source CI results are pending.

## Remaining measurements

Pool queueing can add delay, especially for bodies just above the codec
minimum; this change has no demonstrated end-to-end latency improvement yet.
H1 callbacks also run in the connection reader/writer fibers, so waiting for
compression delays that connection's next request. HTTPun dispatches those
requests in order; other connections have separate fibers. Same-connection
pipelining latency under worker saturation remains unmeasured.
It does not remove allocation or cross-domain GC pauses. Snapshot caches are
still preferable for repeated immutable responses. This slice does not
change authentication, deployment, TUI frame policy or the 0.1ms target status.
