# Canonical Board candidate wire boundary

PR #42130. Base: dce14bcf4b91a06351a922117eb2e0f3c747e12f.

Private keeper_board_attention_candidate_wire owns 18 canonical public data types, signal/candidate identity, current strict JSON codecs, context canonicalization, finite/state validation, judgment request projection and latest-row indexing (1543 lines). The root retains path resolution, durable storage/compaction, caches and locks, state mutations, quarantine/requeue, worker wake and delivery (1062 lines, previously 2450).

Public MLI is byte-identical. Manifest type re-exports with destructive signature substitution connect the same nominal types. Partition_generation uses destructive module substitution to preserve its existing public identity, and Candidate_map is owned once in the wire module. Extracted types/function bodies are exact parent blocks apart from final newline normalization. No forwarding functions, compatibility reader or field/default was introduced.

Initial focused build failed because the include duplicated Board_signal/Partition_generation module declarations. Root Board_signal alias was removed and Partition_generation was substituted destructively. Corrected `opam exec -- dune build test/test_keeper_board_attention_candidate.exe` completed exit 0. Execution `_build/default/test/test_keeper_board_attention_candidate.exe --color=never`: 26 PASS, 40DG6VBB, exit 0. Cases cover current signal/context projection, identity/deduplication, strict provenance/numeric decoding, exact delivery, append/compaction/replaced-store behavior and same-domain ledger locking. Fixtures use temporary workspace files and in-process wake/queue boundaries. No provider request or live Keeper was contacted. Separate quarantine/operator-recovery suites were not run.

Five source hashes, one executable hash and actual output are retained. Full CI, installation, deployment, formal GitHub approval and merge remain unverified. Remaining storage/state/compaction/wake/quarantine semantics require audit. Falling below 2000 lines does not complete the original candidate or the 171-file campaign.
