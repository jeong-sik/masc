# RFC: Keeper orphan stimulus persistence — close the ack/persist synchronization gap

## §0 Summary

A keeper whose event-queue persist file holds an orphan stimulus (most commonly a
`bootstrap` stimulus whose goal has since left `active_goal_ids`) enters a
self-sustaining no-op loop that ends in an `Idle_turn` crash every 30 minutes:

- the orphan stimulus survives in the persisted event queue, so every heartbeat
  snapshot restores it (`event_queue_snapshot: restored N stimuluses pending`);
- RFC-0020's `QueueNeverStarvedBySkip` invariant (correct, kept) then forces a
  turn each heartbeat to drain it;
- but the stimulus carries no actionable work (snapshot goal cleared as
  `not in active_goal_ids`), so the turn is a 5-token no-op that does not advance
  `last_turn_ts` (no `had_live_turn`);
- after `stale_run_threshold_sec` (RFC-0250, default 1800s) the supervisor stamps
  `Stale_turn_timeout (Idle_turn …)` and restarts the keeper, which restores the
  same orphan stimulus and repeats.

The crash-restart policy (RFC-0250) and the no-starve policy (RFC-0020) are both
correct and are deliberately left untouched. The gap is narrower: a stimulus that
has been consumed and acknowledged still re-appears on the next persist load, so
the queue can never drain for an idle keeper. This RFC closes that synchronization
gap. It adds no type, no string classifier, no cap, no dedup, no cooldown — it
makes "acknowledged stimulus" and "absent from the next persisted snapshot" mean
the same thing.

This is a **wiring RFC**, in the style of RFC-0250: it reuses the closed mechanisms
already on disk (`ack_inflight`, the persist snapshot path) and completes the
synchronization between them. It does not introduce a new classifier for "stale
stimulus".

## §1 Motivation (verified against live runtime, 2026-06-27)

The loop was observed end-to-end in `<base-path>/.masc/logs/main_eio-main-20260626-2307.log`
on a fleet where 9 of 14 keepers were `paused` and would not stay up after a manual
`/boot` ("Play → immediately stops"). Five load-bearing facts:

1. **The persisted event queue holds many orphan stimuli.** On `verifier` fiber
   start: `event_queue_snapshot: restored 14 stimuluses pending for keeper=verifier`
   (2026-06-27 10:01:42). This is a restore from the base-path event-queue persist
   file, not from in-memory state — `keeper_event_queue_persistence.ml` emits the
   `restored %s` line at load time (`:106`).

2. **A consumed-and-acknowledged stimulus re-appears on the next snapshot
   (verified directly against the persist files).** The pending snapshot
   `<base-path>/.masc/keepers/<name>/event-queue.json` holds the bootstrap stimulus in
   quantity — albini 70, verifier 48, nick0cave 46, idealist 38, issue_king 10,
   rondo 8 occurrences — while the sibling `event-queue-inflight.json` is 63 bytes
   (empty) for the same keepers. The ack path (`ack_inflight`,
   `keeper_registry_event_queue.ml:96-98`) is therefore running and clearing the
   inflight file, yet the pending snapshot is not drained. The same cycle is
   visible in the log: `turn entry: consumed stimulus stimulus_id=bootstrap`
   followed by `event_queue_snapshot: restored 1 stimulus pending for
   keeper=verifier`, with the turn completing (`completing -> done ContractOk`),
   `consumed_stimuli_turn_completed := true` (`keeper_heartbeat_loop.ml:410`),
   routing to `ack_consumed` (`:421`). Despite that ack, the stimulus is back in
   the next restored snapshot.

3. **The no-starve invariant then re-runs the turn every heartbeat.** The consume
   recurs every ~33s (matching the snapshot interval
   `keeper_heartbeat_loop_in_turn_pulse.ml:14`, `min 30.0 keepalive_interval_sec`):
   `consumed stimulus stimulus_id=bootstrap` at 10:01:42, 10:02:18, 10:02:51,
   10:03:22, 10:03:56, … This is RFC-0020 Rule 2 (a non-empty queue forces `Emit`)
   behaving exactly as specified.

4. **The repeated turn is a no-op that does not advance `last_turn_ts`
   (verified against code and the monotone stall sequence).** `had_live_turn` is
   defined as `current_turn_observation` being `Some _`
   (`keeper_registry.ml:135-138`), and `last_turn_ts` is advanced only when
   `had_live_turn` (`:162-167`). The repeated cycle is `turn=9909 tokens=5 …
   stop=completed`, `state metadata missing, synthesized from 0 tools` (i.e. no
   live observation, `current_turn_observation = None`), then `snapshot goal
   AwaitingVerification … not in active_goal_ids, clearing`
   (`keeper_post_turn.ml:480-488`). The consequence is observable: the stall
   sequence advances monotonically `idle_turn(1826s) → 1886 → 1946 → 2006 → 2096
   → 2276` and resets only after a crash-restart (`1816`, `1804`) — i.e.
   `last_turn_ts` does not move between restarts, confirming `had_live_turn =
   false`.

5. **RFC-0250 then crashes the keeper, which restores the orphan and repeats.**
   After ~1800s of no `last_turn_ts` advance: `phase transition name=verifier
   old=running new=crashed event=fiber_terminated(stale_turn_timeout(idle_turn(1830s)))`
   → `restart_budget_exhausted` → `dead` → dead-tombstone cleanup writes
   `paused = true`. The next boot restores the same orphan stimulus from persist
   and the loop restarts. The same shape was observed for albini, nick0cave,
   mad-improver, idealist, sangsu, rondo, ramarama, issue_king — 9 keepers total.

Net: the persist layer can retain a stimulus that the runtime has already
acknowledged. For an idle keeper that stimulus is permanent, so RFC-0020 and
RFC-0250 (both correct) compose into a 30-minute crash cycle. The bug is the
desynchronization between the ack path and the persist-snapshot path, not in
either policy.

## §2 Design

### 2.1 Make acknowledgement authoritative over the persisted snapshot

The contract this RFC fixes: **once the genuine consumed-ack path
(`ack_consumed`) succeeds for a stimulus, that stimulus must not appear in the
next persisted snapshot loaded for that keeper.** `ack_inflight` remains an
inflight-only helper because `requeue_front` uses it after putting an unconsumed
lease back into pending; it must not drain pending in that path. The bug was that
the consumed-ack caller used the inflight-only helper and never made the pending
snapshot agree with the acknowledged fact.

The fix is a synchronization rule on the persist path, not a new data structure.
Concretely (exact field paths and the precise CAS sequence confirmed at
implementation time against `keeper_event_queue_persistence.ml`, in the style of
RFC-0250 §2.1):

- `dequeue` already records inflight (`keeper_registry_event_queue.ml`) and
  persists the live queue snapshot. The snapshot written here must not contain
  the dequeued stimulus in its pending set.
- `ack_consumed` removes the exact consumed stimuli from both pending and
  inflight snapshots under one persistence lock. Public `load` takes the same
  lock before reading both files, so it cannot observe the old split state where
  inflight was already cleared while pending still contained the consumed
  stimulus.
- Durable consumed-ack failure is not a log-and-continue path. Persistence
  returns `Error`, and the registry ack wrapper raises rather than treating the
  stimulus as acknowledged.

The diverging path is now identified directly (§1 claim 2): the ack path clears
`event-queue-inflight.json` (verified empty), but the pending snapshot
`event-queue.json` retains the bootstrap stimulus and is not drained on ack.
Compounding this, the supervisor launch enqueues a `bootstrap` stimulus on each
fiber start (`keeper_supervisor_launch.ml:84-90`), so each crash-restart in the
loop adds one more copy to a pending snapshot that never shrinks — which is why
the files hold 8–70 copies per keeper rather than one. The fix therefore has two
sides, both wiring rather than new mechanism:

- **Consumed ack must drain the pending snapshot, not only the inflight file.**
  After successful `ack_consumed`, the corresponding stimulus must be absent
  from the next `event-queue.json` load. There is no orphan heuristic: the drain
  removes only the exact stimuli that the turn already dequeued and passed to
  the genuine ack path. A delayed-but-valid stimulus that was not consumed is not
  matched and remains pending.
- **Launch enqueue must be idempotent against the persisted pending set.**
  `enqueue_if_missing` (`keeper_registry_event_queue.ml:17-19`) already guards
  the in-memory queue; the same guard must hold against the persisted snapshot
  so a restart does not double-add a `bootstrap` that the previous generation
  already persisted.

Neither side adds a type, a classifier, a cap, or a sweeper.

### 2.2 Why not the alternatives

- **Not "make bootstrap non-persistent".** `bootstrap` is a one-shot launch
  stimulus, but RFC-0020's event queue is an at-least-once replay boundary by
  design (`keeper_event_queue_persistence.mli:33`). Special-casing one stimulus
  reintroduces exactly the string-shaped carve-out the closed-sum discipline
  (RFC-0042) forbids, and the gap reproduces for any future orphan stimulus, not
  only `bootstrap`.
- **Not a stale-stimulus GC / cap / dedup.** Adding a sweeper is a new mechanism
  that admits the abstraction is missing. The right fix is that "acknowledged"
  and "gone from persist" are the same fact, defined once. RFC-0250 §2.3
  explicitly rejects "no cap / cooldown / dedup" for the same reason; this RFC
  inherits that stance.
- **Not changing RFC-0020 or RFC-0250.** Both policies are correct in isolation.
  No-starve must keep forcing a turn when the queue is non-empty; idle-crash must
  keep killing a keeper producing no turns. Weakening either would re-open the
  field bugs they closed (`#fleet-stall`, the operator-latency starvation race).

### 2.3 What this RFC does NOT add

- No new stimulus kind, no new failure-reason variant — `Idle_turn` and the
  event-queue stimulus type stay as-is.
- No string classifier on stimulus ids.
- No cap, cooldown, dedup, or periodic sweeper.
- No change to the no-starve (RFC-0020) or stale-run (RFC-0250) policies.

## §3 Verification

- **Contract test (the core regression).** A fixture that enqueues a stimulus,
  dequeues it, runs `ack_consumed`, and then `load`s the persist snapshot must
  observe the stimulus absent from the pending set. A buggy variant that skips the
  synchronized pending+inflight update must fail this test. (Mirror RFC-0020's
  clean/buggy `.cfg` pair pattern if a TLA+ model of the persist path is
  warranted.)
- **Loop-break integration test.** A keeper fixture with an orphan `bootstrap`
  stimulus in persist and `active_goal_ids = []`: after the fix, the heartbeat
  consumes it once, acks it, and the next snapshot is empty — the keeper reaches
  the normal idle wait (no forced no-op turn) instead of looping. This proves the
  bootstrap-orphan loop is closed. It does **not** prove no no-op turn can ever
  occur: a separate `scheduled_autonomous` heartbeat tick is an independent turn
  source and is out of scope for this RFC. If scheduled no-op turns prove to also
  stall keepers, that is a follow-up, not a gap in this fix. Pin the
  bootstrap-orphan case with a test; it is the behavioral proof that the
  "Play → stops" symptom caused by accumulated bootstrap stimuli is gone.
- **Invariant preservation.** `KeeperEventQueue.tla` `Conservation`
  (`enqueued ≥ dequeued`) and `QueueNeverStarvedBySkip` still hold: the fix only
  removes acknowledged stimuli, which by definition have already been dequeued, so
  the monotone counter relation is preserved.
- `dune build --root .` + `@check`: exit 0 (touches the hot path; default target
  must build).
- ocamlformat `@fmt`: clean.
- Relevant `dune runtest` suites: keeper event-queue persistence, heartbeat loop,
  registry event-queue.

## §4 Non-goals

- Repairing the already-accumulated orphan stimuli in existing `.masc` traces.
  That is an operational one-shot (a migration / cleanup script), not a design
  change; it is tracked separately so this RFC stays a pure synchronization fix.
  Implementations may ship a one-time idempotent compaction alongside, but it is
  not required by this RFC.
- Changing bootstrap's one-shot launch semantics.
- Reintroducing any per-turn wall-clock watchdog (RFC-0250 §4 already forbids
  this).

## §5 Relationship to existing RFCs

- **RFC-0020** — event-layer / policy-layer separation, source of the
  `QueueNeverStarvedBySkip` invariant this RFC must preserve. This RFC operates
  entirely inside RFC-0020's persist module; it changes no layer boundary.
- **RFC-0250** — stale-run window, the `Idle_turn` producer. This RFC removes the
  input that feeds RFC-0250's crash for idle keepers; it does not alter RFC-0250's
  threshold, variant, or cohort routing.
- **RFC-0042** — closed-sum discipline. This RFC is shaped to satisfy it: no
  string match on stimulus ids, no carve-out for `bootstrap`.
