# Token rotation authority: local source evidence

Seven changed OCaml files parse with OCaml 5.5.1. Parsing does not typecheck or execute them. Scoped ignore lint includes both tests; whitespace and changelog fragment checks are recorded separately. `provenance.json` pins exact source bytes and commands on composed local parent `fedf36b9bc8246211fc337070843271e83229498`.

Sixteen new feature cases and the existing shared-token suite are committed for native CI, and were not executed locally. No local Dune, typecheck, native test, runtime, network or CI was exercised. The read-only credential-directory failure fixture requires an unprivileged process. Root owns publication, current main composition and native validation. The rotation changelog `40182.md` is a numeric placeholder with matching citation.

`determinism-check.txt` records the committed rotation diff gate against the local parent. Its captured commit is pinned in provenance; the follow-up evidence commit changes only this evidence folder.

Published as stacked PR #40182 over actual prune parent b5f401cbf540c1461408bd1d5885fabc5b0b2d85. Native and required CI remain pending; the placeholder release fragment was not published.

The private retirement record label was subsequently renamed to `retiring_agent_name` after the root reviewed compiler failure in native run `36666974017` / job `109733612368`. `private-retirement-label-followup.json` captures the current two repaired source files, source checks and attribution to that primary job review. Earlier provenance remains historical to its captured bytes; local parsing does not establish that the compiler error is resolved. Public prune entry names are unchanged.
