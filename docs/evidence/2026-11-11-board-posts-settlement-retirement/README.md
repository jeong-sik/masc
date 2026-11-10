# Posts source-only settlement retirement

Native Stack #51180: #51178 then #51179, destination `main`. Refs #26378.

- Base: `cea83a6b7ad417974b1a7a267f463bdbab798312`
- Lower: `7f61a56a5e38534bd5462e02ec29dd3cd7e77edd`
- Case source: `c2832168977de6686d756fd451aeb4609d79e7b7`

This four-file evidence refresh follows the case source. The manifest covers
14 source/test/spec/changelog paths. Lower has 13 changed paths; upper has six,
including these four evidence files and the shared authority test file.

## Product boundary

The public Posts settlement family had no repository production caller. Its
source-only verdict could authorize an old cached model after an unknown write.
The old `test_settle_preserves_memory_tables` case expected a later flush to
replace the published new body with the older cached body. This is a source
counterexample, not evidence of an observed installation incident.

Remove that API, its dedicated outcome/direction helpers and reexports. Cached
display remains available; unknown source reads and mutation admission remain
refused with their evidence. Keep the shared reserved carrier/backtrace,
before/intended bytes, canonical guards and fresh-store deletion recovery.
Comments recovery is separate. External callers have not been inventoried.

## Each layer keeps its callers coherent

Lower removes the API and ports all four repository test callers together.
Seven API-only cases are removed and five existing cases retain reserved mutex,
explicit poison, unknown ownership, sub-board recovery and leaf refusal checks.
Upper enhances one existing unknown-write case: a real public vote creates dirty
parent work before the unknown edit; source retry/flush refusal preserves its
published new body and dirty work, and fresh loading sees the actual new body.
No new case or suite is registered. All six updated functional cases are unexecuted.

The final 11 ML/MLI blobs equal the prior combined head `271cf2099a4c1be27243db5b5c25d2fc57438218`.
The lower authority fixture is the one additional distinct parser input: its
unknown-write case is still the original supported case before upper enhancement.
The moved-base changes are unrelated docs/changelog and a Keeper test helper.

## Why the partition changed

During delivery, `changes` and `type-check` became required server contexts.
The original lower removed the API while leaving four callers in upper. Existing
workflow **PR type-check (dune build @check)** run **42886898641**, pull-request
head `266ba0733853c8cd1bcaf49a802a8f3efa1c1bb4`, concluded **failure** with four
`Unbound value Board.settle_posts_source` errors. It actually checked out
`refs/remotes/pull/51178/merge` at `fb66e352f95e738b9974440d67b4cf412f244829`.

The same workflow run **42886898879**, pull-request head
`271cf2099a4c1be27243db5b5c25d2fc57438218`, reports **success** in run/check metadata.
Its raw job log was not read. This prior combined-head result does not certify
the repartition or moved base. Merge UUID `2174bbb5-6be1-4ca6-aaca-1ceae6e25cfa`
ended **failed** on the required lower check; it was not a merge and is not replayed.
The caller ports now belong to lower. No rule or workflow is weakened.

## Evidence limits

Two independent local readers rereviewed the repartition and moved-base delta,
reusing exact-source prior inspections. Final source has 11 parse-only receipts
with OCaml 5.5.1 (target 5.5.2): nine exact-source receipts reused and two new
invocations to record complete command vectors. Lower's one different authority
fixture also has a parse-only receipt. Both layers have zero retired-symbol hits
and clean full-diff whitespace checks. No local Dune execution occurred.

Parsing does not establish types, warnings, linking or behavior. The current tuple
has no observed CI result in this capture. Existing failure logs were read once
for the actual merge refusal; no workflow was dispatched and CI was not watched.
Backend cases, browser/live HTTP, installed behavior and deployment remain unverified.
Local source review is not formal GitHub approval or integration. Historical
captures at prior heads remain separate from this refreshed record.
