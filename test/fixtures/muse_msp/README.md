# MSP golden transcripts

Except where noted at the end, these files are copied without changes from
[meta-models/muse-code-sdk](https://github.com/meta-models/muse-code-sdk)
at commit `a7c10c5dd3f66be412077d29f9d11111af70317b` (2026-09-21, host 1.3.0).
Each `<scenario>.ndjson` is that repository's
`schema/msp/transcripts/<scenario>/transcript.ndjson`.

Each line is `{"dir":"client"|"server","raw":"<one wire frame>"}`.
`test/test_runtime_muse_msp.ml` reads the server frames with
`Runtime_muse_msp` and compares the frames MASC writes against the client
frames.

Copyright (c) Meta Platforms, Inc. and affiliates. Used under the MIT License.
The full notice is in `LICENSE` in this directory.

`approval-resolved-by-policy.ndjson` is not from that repository. MASC
captured it from a real `muse serve` 1.4.0 host (build `04f5eb2e`) on
2026-09-26: a `denyUnmatched` session's `approval/request` for
`mcp__masc__ping`, the host closing it with `approval/resolved` (`denied`
by `policy`), MASC's acknowledgement and `approval/decide`, and the host's
`-32051` `approvalAlreadyResolved` answer. Only these five frames are kept;
the session start, which carries the MCP bridge's bearer header, is left out.
