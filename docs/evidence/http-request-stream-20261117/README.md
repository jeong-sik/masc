# Streaming JSON field encoding

The Core exposes `Http_request_stream.encode` for final streaming fields on an
existing JSON tree. Its byte/error contract is the existing text encoder followed
by `Http_client.inject_stream_param` or `inject_stream_and_options`.

Ordinary trees are encoded once. Raw `Intlit` fragments and nonfinite floats keep
the existing text validation path before any overwritten field is removed. This
preserves malformed-fragment refusal, normalization and writer exceptions. No
input or authority is cached.

## Focused evidence

Measured source: lower `922090554eae4c3bdeb37a1eac162a3b551299a2`.
[Native verification](native-verification.json) records complete fresh Core MLI/ML
compilation and all four maintained wire-boundary tests passing against compatible
prebuilt dependencies. Fatal warnings 4, 8, 32 and 69 remain enabled. The test has
an empty MLI so unused private helpers are checked.

Only fresh experiment output and the test's declared `llm_provider`, `yojson` and
`alcotest` libraries are public to test compilation; transitive directories use
OCaml `-H`. Hiding only public Yojson reproduces `Unbound module Yojson` (exit 2);
restoring that declaration compiles, links and runs all four tests. Complete Core
compilation and the final link use a broader compatible prebuilt dependency graph;
this is not a Dune workspace-build result.

Coverage includes field order, duplicate keys, object/scalar refusal, finite and
nonfinite numbers, malformed UTF-8 bytes, raw literals and invalid values inside
fields that will be overwritten. The oracle preserves returned errors and the
constructor/detail of writer exceptions. The actual maintained test remains in
`packages/agent_core/test/test_http_request_stream.ml`.

[Independent review summary](source-review.json) records the direct `yojson`
dependency repair and the final source/visibility assessments. It is not a formal
GitHub approval. The upper layer retains a focused replay of these tests and the
complete real consumer comparison.

No local Dune, full regression, HTTP/provider call, installed-server improvement
or peak live-heap measurement is claimed. These retained JSON files are selected
derivatives; original run captures and their digest meanings are preserved.
