# Canonical Board candidate wire boundary

PR #42130. Current base: 57266cf4178665779d5ffa4f7b6b06035a73eea4.
Original base: dce14bcf4b91a06351a922117eb2e0f3c747e12f.

Private keeper_board_attention_candidate_wire owns 18 canonical public data types, signal/candidate identity, current strict JSON codecs, context canonicalization, finite/state validation, judgment request projection and latest-row indexing (1533 lines). The root retains path resolution, durable storage/compaction, caches and locks, state mutations, quarantine/requeue, worker wake and delivery (1062 lines, previously 2450).

Public MLI is byte-identical. Manifest type re-exports with destructive signature substitution connect the same nominal types. Partition_generation uses destructive module substitution to preserve its existing public identity, and Candidate_map is owned once in the wire module. Extracted types/function bodies are exact parent blocks apart from final newline normalization and the corrected rejected-row comment. No forwarding functions, compatibility reader or field/default was introduced.

Initial focused build failed because the include duplicated Board_signal/Partition_generation module declarations. Root Board_signal alias was removed and Partition_generation was substituted destructively. Corrected `opam exec -- dune build test/test_keeper_board_attention_candidate.exe` completed exit 0. Execution `_build/default/test/test_keeper_board_attention_candidate.exe --color=never`: 26 PASS, 40DG6VBB, exit 0. Cases cover current signal/context projection, identity/deduplication, strict provenance/numeric decoding, exact delivery, append/compaction/replaced-store behavior and same-domain ledger locking. Fixtures use temporary workspace files and in-process wake/queue boundaries. No provider request or live Keeper was contacted. Separate quarantine/operator-recovery suites were not run.

The actual output is retained. Full CI, installation, deployment, formal GitHub approval and merge remain unverified. Remaining storage/state/compaction/wake/quarantine semantics require audit. Falling below 2000 lines does not complete the original candidate or the 171-file campaign.

Parent refresh: PR #42126 moved to 57266cf4178665779d5ffa4f7b6b06035a73eea4 after upstream refresh merges. Integration head 81fc88d9d7c803e126233888eb1bb1773c5b1f06 incorporates that parent. The complete binary diff from the old parent to a86ed7f421 and from the refreshed parent to the integration head is byte-identical (SHA256 baa88ad09fdf190bed5a43799eb086787521e22b8e12644b5f4a2632e5d77b97). The 26-case execution above belongs to the original dependency combination; the focused build for the refreshed combination completed exit 0. This comparison does not certify the upstream changes or reuse approval for them. Current-base independent review remains pending.

Refreshed execution: the same candidate command completed exit 0 with 26 PASS, D06TXZZ1. refreshed-tests.output records this dependency combination separately. This repeats the same 26 cases, not 52 distinct cases. Current-base source review remains separate.

Source review corrected an inaccurate moved comment: unreadable rows are preserved by the storage owner, and compaction requires zero rejected rows. This comment-only correction changes neither codec nor storage policy; the refreshed execution above still applies to the same function bodies. The source manifest reflects the corrected comment.
