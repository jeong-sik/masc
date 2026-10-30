# Schedule participants shared by Queue and world observation

Review baseline: `f4e6ff0eb583a3354486a0a3cc334f144d8ec1c1` (#41051).

Filtering only by `scheduled_by` hid B-created wakes from their target A.
It also showed unrelated human/system reservations in A's scoped Queue.
`Schedule_payload_projection.keeper_participants` now derives the automated
creator and decoded wake target once. Both world observation and Queue use
its `visible_to_keeper` predicate. Human/system actor IDs are not Keeper IDs;
self-wakes have one participant. Invalid/missing targets retain the creator
for diagnosis, matching the existing world-observation policy.

A scoped Queue assigns a visible reservation to the selected participant.
The fleet groups each reservation once, under a known creator or otherwise a
known target. If neither participant is in the roster it remains global.
The row detail retains all participant identities; fleet totals do not double
count a cross-Keeper wake. Store-read errors remain visible in every scope.

## Evidence and limits

- Thirteen source/interface/test files typecheck with OCaml 5.5.1 and warnings
  8/32/69 as errors, using cached dependency interfaces. See exact hashes in
  `typecheck-results.json`.
- The full production schedule payload projection was compiled natively with
  cached real dependencies, including `Schedule_domain`. Exact source slices
  of world visibility and Queue schedule grouping were exercised across
  13 actor/target scenarios, all seven lifecycle statuses and four scopes.
  The candidate passed all 578 assertions. The baseline failed 159 assertions
  (including the added participant-detail contract). Totals differ because
  missing rows cannot undergo both subsequent row-field assertions.
- `check-schedule-participants.py CHECKOUT CACHE_CHECKOUT` reproduces that
  focused run without Dune or cache mutation. `manifest.json` identifies the
  production sources. The runner requires an existing OCaml 5.5.1 cache.
- The registered inventory regression additionally uses real schedule storage,
  public inventory reads, corrupt-ledger handling and aggregate counts. It is
  authored and typechecked, not executed. The native slice does not exercise
  storage, HTTP, PTY, a complete candidate binary or deployed runtime behavior.

Earlier evidence directories retain their historical source hashes. Their
actor-only reservation interpretation is superseded by this participant-aware
contract. Independent review of this response delta remains pending.
