# HTTP response compression worker

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

H1 JSON, lazy JSON and cached HTML, plus the shared H2 response helper,
submit only immutable compression inputs to the existing `Domain_pool` CPU
path. Request selection, lazy body closures, response objects and writes stay
on the caller. Already-running executor jobs do not resubmit to their own
pool. `Http_response_payload.prepare` remains a synchronous producer helper.

Responses with compression disabled, identity negotiation, or bodies below
`Compression_codec.min_size` avoid queueing. H1 matching validators return
304 before compression. The codec threshold is reused without another knob.

This follows the existing shared-pool policy and the
[Eio executor interface](https://github.com/ocaml-multicore/eio/blob/main/lib_eio/executor_pool.mli).

## Verification scope

- `test_http_server_eio`: single occupied worker; caller fiber progress;
  cancellation before response writes and after a worker barrier; unqueued
  small, identity, disabled and matching-validator responses; lazy closure
  owner domain; complete H1 identity/gzip/zstd wire parity with a real pool.
- `test_h2_json_worker`: complete H2 payload and header parity with and without
  an installed one-domain pool, including nested value serialization.
- Existing `test_compression`: negotiation, gzip decoding and snapshot
  representations remain the pure-codec regression coverage.
- Local `ocamlformat --check` and `git diff --check` passed. No local OCaml
  build or behavioral test was run. Exact-source CI results are pending.

## Remaining measurements

Pool queueing can add delay, especially for bodies just above the codec
minimum; this change has no demonstrated end-to-end latency improvement yet.
It does not remove allocation or cross-domain GC pauses. Snapshot caches are
still preferable for repeated immutable responses. This slice does not
change authentication, deployment, TUI frame policy or the 0.1ms target status.
