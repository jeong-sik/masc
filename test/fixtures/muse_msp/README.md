# MSP golden transcripts

These files are copied without changes from
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
