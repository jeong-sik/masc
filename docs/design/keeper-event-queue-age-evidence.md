# Keeper event queue age evidence

A Board candidate retains its original `recorded_at` as the stimulus `arrived_at`.
Judgment and delivery can happen much later. Other producers also timestamp their
source before the queue commits it. This timestamp is source evidence, not the
first durable admission time.

The fleet health projection names its diagnostic fields
`oldest_source_arrived_at_unix` and `oldest_source_age_seconds`, with the same
explicit `source` qualifier for runnable, recoverable, paused, disabled and fenced
subsets. The decorated fleet schema is v5, work liveness is v2. Previous ambiguous
field names are not emitted or accepted as aliases. Persisted queue snapshots,
transition WAL, source hashes and admission identities are unchanged.

Each queue projection has `queue_residence` evidence:

```json
{"status":"unknown","oldest_age_seconds":null,"reason":"first_admission_not_recorded"}
```

An unavailable or incomplete queue/owner-lifecycle observation uses
`queue_observation_incomplete`; it does not claim that the snapshot itself failed.
Neither zero, source age, snapshot mtime, admission revision nor the current clock
is substituted for a missing admission timestamp. Source age alone cannot mark
runnable work stalled or request operator action. Runnable backlog remains
`backlogged`, actionable owner conditions remain `blocked`, and storage failure
and outbox evidence retain their existing health classification. Reaction-ledger
fleet health reads the same pending queue, so its source-age-only stale alarm is
removed too; actual ledger pending rows, quarantine and read/discovery failures
remain actionable. Its fleet schema is v3. The unused `health.durable_queue_stale_sec`
setting and environment projection are removed with that alarm. This change does
not prove that pending work progresses; it removes an unsupported timing claim.

A future residence measurement needs admission time in the same durable commit as
the pending entry. It must survive restart, deduplication, checkpoint retention,
priority changes and deferral, while a consumed then reinserted source is a new
membership. Target-side transfers begin a new target membership and replay must
preserve the original target admission. Older entries must retain explicit unknown
time through any authorized storage evolution.

A separate observation file is insufficient: writing before the snapshot can
leave an orphan timestamp on failed admission, while writing after it can lose the
measurement in a crash. Current source incarnations also change on defer and
reprioritize. An atomic membership identity and timestamp transport needs its own
storage design; no sidecar or timestamp backfill is introduced here.

Validation added: durable summary preserves snapshot bytes and separates source
age from unknown residence; health does not infer stalls for old or new sources
and retains blocked/unavailable states; the dashboard parses null residence and
renders source age with unknown residence. Execution requires remote CI.

Deployment must remove any configured `health.durable_queue_stale_sec` (and its
former environment setting) through the normal operator-owned config path. No
runtime configuration is mutated by this source change. Deploy matching backend
and dashboard artifacts because projection names changed without aliases.

The queue-summary test compares raw snapshot bytes; the reaction-ledger test
compares parsed durable state. Neither test has been executed for this change.
OCaml and TypeScript syntax checks do not establish typecheck, runtime or UI proof.
