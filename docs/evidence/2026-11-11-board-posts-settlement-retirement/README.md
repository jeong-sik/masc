# Posts source-only settlement retirement

Native Stack #51180: #51178 then #51179, destination `main`. Refs #26378.

- Base: `840321a4d1d95a655810f4441ece7e58572ec57e`
- Lower: `266ba0733853c8cd1bcaf49a802a8f3efa1c1bb4`
- Case source: `e6856d5357bd7ddaccc4b14b3f19276e266fba17`

This bundle is added after the case source. Its manifest covers the 14 changed
source, test, spec and changelog paths before these four evidence files.

## Product boundary

The public Posts settlement family had no repository production caller. Its
source-only verdict could authorize an old cached model after an unknown write.
The old `test_settle_preserves_memory_tables` case explicitly expected a later
flush to replace the published new body with the older cached body. This is a
source counterexample, not evidence of an observed installation incident.

Remove that unused API, its dedicated outcome/direction helpers and reexports.
No compatibility shim or replacement recovery engine is added. External callers
have not been inventoried. Cached display reads remain available; unknown source
reads and mutation admission remain refused with their original evidence.

Keep the shared reserved-exception carrier and original backtrace, before/intended
bytes, source refusal, canonical authority checks and fresh-store initialization.
Deletion recovery still follows the recorded IDs; ordinary flush does not replay
an uncertain source effect. Comments recovery APIs are separate and unchanged.

## Existing scenarios retained

Seven API-only cases are removed. Six existing functional cases are updated:

1. A real public vote leaves a dirty cached parent before an unknown edit. Same-store
   source read/retry/flush refusal preserves its published new body and pending dirty work.
2. Reserved unknown writes preserve usable persistence/state locks, while the old
   store remains refused and a fresh store can load and edit the actual source.
3. An explicit ordinary exception still poisons only the persistence mutex.
4. Unknown ownership transfer refuses same-store deletion; fresh loading observes
   the new owner and rejects the original actor without changing source bytes.
5. Sub-board `Sources_uncertain` keeps no-IO ordinary flush and fresh recovery.
6. Unknown Posts refuse post/comment votes and reactions before leaf writes.

No new suite or case registration is added. All six updated cases are unexecuted.
Local reviewers caught and rereviewed a cached-read error/opaque-ID mismatch and
an initially empty dirty-work fixture. Those were MLI/source findings, not observed
compiler failures. The final fixture uses the real public vote producer.

## Evidence limits

Two independent local readers reviewed the full source changes and final deltas.
Eleven changed ML/MLI inputs have parse-only receipts with OCaml 5.5.1 (target
5.5.2): seven exact-source receipts reused, four new invocations. Whitespace and
the retired-symbol scan passed. Dune was not run.

Parsing does not establish types, warnings, linking or behavior. No backend case,
CI/Actions, browser/live HTTP, installation or deployment result is supplied.
Formal GitHub review and integration are separate observations. Historical evidence
from previous #26378 units is preserved unchanged.
