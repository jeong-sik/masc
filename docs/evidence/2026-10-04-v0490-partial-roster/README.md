# Partial-roster Item account withdrawal

Scope note: this PR retains historical reproduction evidence; it adds no current implementation change. The published v0.49.0 notes already cover partial-roster Item retention under #40313 and #41069. The artifact and measurements below retain their original candidate identities.

Release blocker: [40313 review4173955107](https://github.com/jeong-sik/masc/pull/40313#discussion_r4173955107). The release permits a local Keeper omitted from a capped roster to read its authoritative Item account, but subsequent successful roster application withdrew that account. The automatic refresh launcher also cleared it, so fixing the roster match alone would not fix the visible defect.

## Reproduction

Downloaded artifact11279606181 from RC37137607438. Native macOS arm64 TUI embedded commit: `fd7e6c37e006af09b1dba65fb2b3b55249104c7f`; binary SHA-256: `f3531778d03b6b2bfd68ae86ba47507cb653bcffd62cd543b2720c4e918b882d`.

A synthetic HTTP/PTy scenario loaded12.500 Candle and owned glasses, then held one automatic Item reply while successful partial-roster reads continued. After6 roster reads and1 held Item request, the native pane displayed Loading Item account and omitted balance, prices and ownership. The assertion failed with process exit1. Raw failure and terminal text (trailing blank cells trimmed) are preserved here; raw PTY bytes remain in the local diagnostic directory named in the failure log.

## Repair and consumers

`launch_keeper_items` takes an optional preservation flag, default false. Only `refresh_changed_keeper_items` supplies it during roster cadence. The same workspace/roster authorization checks run before the prior account is restored; only the same Keeper with partial-roster Unobserved liveness qualifies. Explicit reads and failed/unobserved/invalid/absent authority keep withdrawing. Successful partial roster application no longer clears that account or its pending request.

The new scenario checks retained balance/prices/ownership, one pending request, the specific held reply's updated balance, and withdrawal on HTTP503. Subsequent responses are held independently so they cannot overwrite the unique reply before it is observed.

## Verification boundary

OCaml parsing, Python parsing and diff whitespace checks passed. Independent source review covered authority checks and found one fixture race, corrected with a second response gate. The old candidate reproduces the defect; it does not execute the modified OCaml. Post-fix typechecking, the successful full PTY scenario, Linux behavior and final candidate FullRC remain required. No local Dune build or additional RC dispatch was performed.
