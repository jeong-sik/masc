# Token prune transaction: local source evidence

`parse-only.log` records successful OCaml 5.5.1 syntax parsing of the Auth interfaces, private store, new feature operation, CLI and feature test. Parsing does not typecheck or run those files. `diff-check.log` records whitespace verification. `ignore-lint.log` records the targeted ignore justification check, including the feature test. `provenance.json` pins the exact inspected source bytes and commands.

Twelve feature scenarios are committed for native CI, including real credential-writer admission ordering, preview, validated UUID cleanup, forged UUID and traversal refusal, read-before-write failure, preservation, actual dangling raw-token removal and partial deletion. They were not executed locally. No local Dune build, native test, deployed CLI, network or CI was exercised.

The composed local parent is `219ff24a8ab705af76620af8039b614c3d5f81b1`: expiry stack `9d2e0d1448b27bd8952a5fcc51b8ba6e1015c607` plus the root's parent refusal assertion repair `886762f483` (exactly two `error`→`code` assertions). Those parent test changes are outside the prune delta. Original prune commits `072783ceed` and `2d587d4cbd` are composed on this parent; Auth's existing `let _stat` presence lookup is retained.

The current expiry inventory rule is used directly, preserving malformed input and the entire live expiry second. main's test/dune import, expiry include and prune include are all retained. This is a partial local source composition, not a complete current main tree or a published commit. Root owns publication and native CI.

`changelog.d/40174.md` is a positive numeric placeholder with matching `#40174` citation; root must replace it with the prune PR number before publication. The expiry parent's `999999.md` placeholder is unchanged. Older Play/expiry source evidence remains historical to its own captured source; this folder pins the prune composition bytes only.

Published as stacked PR #40174 over expiry parent 63cc46e9380102e8a39e46b14bd7b9358fcfad74. Native and required checks must cite its final public head; local placeholders were not published.

The private retirement record label was subsequently renamed to `retiring_agent_name` after the root reviewed compiler failure in native run `36666974017` / job `109733612368`. `private-retirement-label-followup.json` captures the current two repaired source files, source checks and attribution to that primary job review. Earlier provenance remains historical to its captured bytes; local parsing does not establish that the compiler error is resolved. Public prune entry names are unchanged.

## Complete current main composition (prune)

This feature was extracted from its own local parent `219ff24a8a` to source `6eb66f6d3a`, then applied to complete current main `c112b2030652a5a25360f5d5322f8dc6da99c598` with immediate feature parent `4e10b82bc574276465f3d65bf5cb19ded168c58b`. Parent fixes were retained through three-way application, and the native registration was added without importing the old partial-main test/dune overlay. `current-main-composition.json` records the exact parent delta manifest, current source hashes and source checks. Retired Keeper API/implementation and every current-main test registration are preserved. Earlier provenance remains historical to its captured source.

This layer's syntax parsing, changed-line ignore gate, whitespace and determinism checks pass. Whole-file production and test-inclusive ignore scans are retained with their actual exit codes and outputs, including any inherited source or fixture debt; those results are not normalized into passes. No local typecheck, Dune, native test, runtime, network or CI was performed; root owns publication and finishing-boundary native validation.
