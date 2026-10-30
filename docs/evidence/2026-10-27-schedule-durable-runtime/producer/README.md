# C2 producer and frozen source inputs

Source input is `a3950a189b9cc5a7ce82cb725699455d79923f42` (Draft proof candidate #46274). Producer run `40396800146` executed workflow `main` at `9377c7f3025d68e3856d2afd3762468dabc77813`; these are different identities. The original receipt binds the requested source and native server hash `1622a35d1082da4fe24d9effb05aec11918d9444288441049c8d6d30cedb415c`.

The native receipt/build logs, artifact metadata, original local identity verification and runtime build identity are copied byte for byte. `source/` retains the six selected source heads and assembly slice identities. Its assembly identity describes product head `d526b490…`, before the final five documentation files; it is not the final whole-diff digest. Selection/approval-pending text is capture-time metadata, not a fresh approval query.

The first verifier failed on a mistaken `tui_sha256` key; that postrun reconstructed failure record remains separate from the corrected original verification. The source uses `sha256` for the TUI. Neither the verifier failure nor dispatch-only receipt is substituted for completion evidence.

ZIP and executables are omitted. Their original SHA/bytes and locations are in [submanifest.json](submanifest.json). Do not expect omitted paths in captured records to resolve here. Exact copies are mapped in [current-locations.json](current-locations.json); original paths/digests remain unchanged. Each derivative, if any, is separately marked in the submanifest.

The artifact's two executed suites concern addon lifecycle. This native build is not focused scheduler CI, model correctness, installed-runtime validation, visible UI validation or release/full-feature PASS. No new build, CI request, binary execution or installation occurred during retention.
