# Token rotation authority: local source evidence

Seven changed OCaml files parse with OCaml 5.5.1. Parsing does not typecheck or execute them. Scoped ignore lint includes both tests; whitespace and changelog fragment checks are recorded separately. `provenance.json` pins exact source bytes and commands on composed local parent `fedf36b9bc8246211fc337070843271e83229498`.

Sixteen new feature cases and the existing shared-token suite are committed for native CI, and were not executed locally. No local Dune, typecheck, native test, runtime, network or CI was exercised. The read-only credential-directory failure fixture requires an unprivileged process. Root owns publication, current main composition and native validation. The rotation changelog `40182.md` is a numeric placeholder with matching citation.

`determinism-check.txt` records the committed rotation diff gate against the local parent. Its captured commit is pinned in provenance; the follow-up evidence commit changes only this evidence folder.

Published as stacked PR #40182 over actual prune parent b5f401cbf540c1461408bd1d5885fabc5b0b2d85. Native and required CI remain pending; the placeholder release fragment was not published.

The private retirement record label was subsequently renamed to `retiring_agent_name` after the root reviewed compiler failure in native run `36666974017` / job `109733612368`. `private-retirement-label-followup.json` captures the current two repaired source files, source checks and attribution to that primary job review. Earlier provenance remains historical to its captured bytes; local parsing does not establish that the compiler error is resolved. Public prune entry names are unchanged.

## Complete current main composition (rotation)

This feature was extracted from its own local parent `fedf36b9bc` to source `2849c75934`, then applied to complete current main `c112b2030652a5a25360f5d5322f8dc6da99c598` with immediate feature parent `fcaaecff6d051f964e16b65b796ce67140441df7`. Parent fixes were retained through three-way application, and the native registration was added without importing the old partial-main test/dune overlay. `current-main-composition.json` records the exact parent delta manifest, current source hashes and source checks. Retired Keeper API/implementation and every current-main test registration are preserved. Earlier provenance remains historical to its captured source.

This layer's syntax parsing, changed-line ignore gate, whitespace and determinism checks pass. Whole-file production and test-inclusive ignore scans are retained with their actual exit codes and outputs, including any inherited source or fixture debt; those results are not normalized into passes. No local typecheck, Dune, native test, runtime, network or CI was performed; root owns publication and finishing-boundary native validation.
