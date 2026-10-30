# Addon test compilation boundary · 2026-10-23

Actual main-minimal runs [39915051394](https://github.com/jeong-sik/masc/actions/runs/39915051394) on 3931736b and [39916370374](https://github.com/jeong-sik/masc/actions/runs/39916370374) on acaaee98 completed with failure. [Original diagnostic blocks](original-error-blocks.json) retain six locations in four interface/dependency boundaries. Production Runtime's missing summary argument was separately repaired by merged [PR45444](https://github.com/jeong-sik/masc/pull/45444). This follow-up addresses only the five remaining test locations on base bdd5151351e7de19a80e78722f9bc1f97ff46d1c.

- Submit-once already calls the separately published Fs_compat library; explicitly link masc.fs_compat in its existing test stanza. No import facade is added.
- Curator's retry-event assertion explicitly excludes both Replacement event constructors, preserving its original Commit_retry_observed assertion.
- Three actual Python MCP fixtures now implement the required await_exit callback by awaiting their exact Agent_core.Mcp client process and formatting its real Eio exit status. This matches the production worker contract: waiting reports exit and does not stop or certify cleanup. Existing stop/restart/cleanup assertions remain unchanged.

[Source manifest](source-manifest.json) identifies five files at source head 5378dd4abe30b669253f7b65818a369c58b4dccf. [Independent SOURCE PASS](independent-review.md) / [identity and limits](independent-review.json) covers the complete frozen patch and direct API/dependency consumers; it is not formal GitHub approval. [Independent parser checks](independent-checks.json) cover four ML files and diff-check only. The Dune stanza was inspected but no local Dune parsing, typecheck, build or OCaml test was run.

Focused execution targets are test_lane_addon_submit_once, test_workspace_curator_addon_commit, test_keeper_addon_deferred_runtime, test_keeper_librarian_addon_owner and test_keeper_librarian_durable_execution. Those actual behavioral results and the next main-minimal build remain unverified here. No new wording/layout/row-order or implementation-mirroring tests are added.

This repair supports A01/A04 and E02/E03 validation of the original54 Addon goal. It does not establish full-tree compilation success, installed runtime behavior or completion of that goal. Voice Stack45450 and Librarian Stack45453 are separate source changes and need their own current-head reviews after any whole-stack rebase.
