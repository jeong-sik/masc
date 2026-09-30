# Token rotation authority: local source evidence

Seven changed OCaml files parse with OCaml 5.5.1. Parsing does not typecheck or execute them. Scoped ignore lint includes both tests; whitespace and changelog fragment checks are recorded separately. `provenance.json` pins exact source bytes and commands on composed local parent `fedf36b9bc8246211fc337070843271e83229498`.

Sixteen new feature cases and the existing shared-token suite are committed for native CI, and were not executed locally. No local Dune, typecheck, native test, runtime, network or CI was exercised. The read-only credential-directory failure fixture requires an unprivileged process. Root owns publication, current main composition and native validation. The rotation changelog `999997.md` is a numeric placeholder with matching citation.

`determinism-check.txt` records the committed rotation diff gate against the local parent. Its captured commit is pinned in provenance; the follow-up evidence commit changes only this evidence folder.
