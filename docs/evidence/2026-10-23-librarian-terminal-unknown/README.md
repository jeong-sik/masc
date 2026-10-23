# Librarian terminal unknown source frontier · 2026-10-23

After a real host terminal `Outcome_unknown`, the immutable original remains pending and continues to own its unread source. An ordinary later wake must not recapture overlapping source under a new UUID and call the provider again. Per-ID submit-once alone did not enforce this source-level boundary.

The existing strict original/host proof/preparation/Gate lineage validator now returns `Unfinished | Settled`. It uses the final it already decoded and verified: actual terminal unknown is unfinished; definite refusals retain their former behavior. Execution uses this validated frontier, and the original owner returns the verified unknown as `Pending (Worker_unknown, original)`. No new store, wire schema or worker registry is introduced.

- [Frozen source and check scope](source-manifest.json): seven files based on main `f985fde683092953b33cfcab0884ef9f27d17ad9`.
- [Author's consumer/validation handoff](author-handoff.md) records the direct interfaces and authored tests. Its local artifact inventory is provenance rather than a public execution receipt.
- [Parser-only checks](parser-checks.json): seven parser checks and diff-check passed. OCaml typing, executable linking, tests and runtime remain unverified.

The existing actual Python worker/Runtime/host HTTP/Memory-lane scenario now first asserts that the original host terminal is really `Retained_terminal Outcome_unknown`. It then checks first settlement plus second and third public production wakes, actual worker restart/Off-On and local recovery while Off. Assertions cover the unique original ID, full request/preparation/progress, provider POST count, checkpoint/official/external cursor and ACK, Memory/WAL/publication state, and absence of a new absorption judgment. Both Atoms and Mixed history are selected. These tests are authored, not executed evidence.

Existing definite Invalid_request fresh-selection, RPC Sent_unknown pending, Answered/Commit_unknown publication-only recovery and known basis-supersession cases are retained. Focused targets are `test_keeper_librarian_durable_execution` and `test_lane_addon_submit_once`.

The original targeted finding was relayed in [the existing PR45357 comment](https://github.com/jeong-sik/masc/pull/45357#issuecomment-6359364111). The former 16-layer stack has merged; this is a new follow-up. No merged branch was changed. This fixes one E03/D03/D04/D06 boundary, not the original 54-item goal or all Librarian continuity/absorption/live-installation requirements.

[Independent seven-file SOURCE PASS](independent-review.md) / [identity and limits](independent-review.json) found no P0–P2 issues in the frozen patch. This certifies the reviewed source scope only, not typing, the authored actual-worker regression, a future rebase, or formal GitHub approval.
