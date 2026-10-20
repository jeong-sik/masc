# MSP golden transcripts

These files are copied without changes from
[meta-models/muse-code-sdk](https://github.com/meta-models/muse-code-sdk)
at commit `22a8a56103c106009f7452c4ef5631e58cb8485c` (2026-10-19, host 1.4.11).
Each `<scenario>.ndjson` is that repository's
`schema/msp/transcripts/<scenario>/transcript.ndjson`, and
`stable-manifest.json` is its `schema/msp/stable/manifest.json`.

Each line is `{"dir":"client"|"server","raw":"<one wire frame>"}`.
`test/test_runtime_muse_msp.ml` reads the server frames with
`Runtime_muse_msp` and compares the frames MASC writes against the client
frames.

The transcripts are hand-authored, so the `schema.fingerprint` their
`initialize` frames carry is a placeholder no host reports. A host reports
the fingerprint of its stable schema bundle, which `stable-manifest.json`
records. `Runtime_muse_msp.corpus_schema_fingerprint` must equal that
manifest's `fingerprint`, and the test checks it.

Copyright (c) Meta Platforms, Inc. and affiliates. Used under the MIT License.
The full notice is in `LICENSE` in this directory.
