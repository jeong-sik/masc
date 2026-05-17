---
rfc: "0094"
title: "Compact cooldown semantics split — typed write anchor vs check anchor"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0088"]
implementation_prs: []
---

# RFC-0094: Compact cooldown semantics split

## 1. Summary

[keeper_runtime.last_continuity_update_ts] currently carries two
semantically distinct meanings on the same field:

1. **Cooldown anchor** — "when did this keeper last *attempt* a
   compact gate evaluation?" Used by
   [Keeper_compact_policy.compaction_decide] to throttle compact triggers.
2. **Successful state write anchor** — "when did this keeper last
   persist a continuity [STATE] snapshot?" Used by
   [Keeper_world_observation.read_continuity_summary] and
   [Keeper_heartbeat_snapshot] to render the fallback summary's
   "last updated at X" label when no snapshot file exists.

PR #15682 (V01 fix) advanced this field on every post-turn invocation,
including turns that produced no [STATE] snapshot, to close a cooldown-bypass
silent-failure. That fix is correct *for the cooldown reader* but
**misleads the display readers**: the operator now sees a stale
[continuity_summary] field paired with a fresh [last_continuity_update_ts],
producing the visual signal "state is current" while it is not.

This RFC proposes splitting the field into two typed anchors. The fix
follows the discriminated-union refactor pattern documented in RFC-0088
(write-side success model attribution): one shared timestamp encoding
two semantic concepts is the conflation; the type system must mark the
two concepts distinct so future readers cannot accidentally re-merge them.

## 2. Motivation

### 2.1 Concrete symptom path (post-PR #15682)

Pre-fix code (origin/main before #15682) at [keeper_post_turn.ml:434]:

```ocaml
let apply_continuity_summary ~snapshot ~now_ts meta =
  match snapshot with
  | None -> meta            (* DO NOT advance ts — silent gate bypass *)
  | Some s -> { meta with runtime = { last_continuity_update_ts = now_ts; ... } }
```

The [None] branch is the V01 bug: cooldown anchor never advances when
no snapshot was produced, so a runaway loop of context-overflow turns
can re-trigger compact every cycle. PR #15682's fix:

```ocaml
| None ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_state_snapshot_skipped_no_state
      ~labels:[("keeper", meta.name)] ();
    { meta with runtime = { meta.runtime with
        last_continuity_update_ts = now_ts; } }
```

This **correctly closes the cooldown gate** but breaks the display
readers. [continuity_fallback_summary_text] at [keeper_summary.ml] reads
the timestamp as "this is when the persisted summary was last updated"
— it renders `Last continuity update: 2026-05-17T11:24:30Z` even
when [meta.continuity_summary] has not changed in days.

### 2.2 Why this is RFC-shaped, not a code-fix

Three pressures converge:

1. **Code level (CLAUDE.md "Workaround Rejection Bar")** — V01's
   counter [keeper_state_snapshot_skipped_no_state_total] is a *telemetry
   without typed root-fix*. RFC-0088 has already named this anti-pattern.
   The counter belongs as an observability sidecar to a typed split,
   not as the answer.
2. **Spec level (RFC-0088 lineage)** — RFC-0088 prescribes
   "discriminated union over conflated string/numeric encoding" for
   success-model attribution. The compact gate field has the same shape
   of conflation (different semantic axes share a numeric encoding)
   and benefits from the same refactor pattern.
3. **Behavioral level** — the cooldown advance change is observable
   externally (dashboard panels, slack notification text drawn from
   [continuity_fallback_summary_text]). Changing it back without a
   compensating field is also wrong: it would re-open the V01 silent
   failure that #15682 closed.

The only path that holds *all three* invariants is splitting the field.

## 3. Current state

### 3.1 Field readers and writers (lib/keeper/)

Writers ([keeper_runtime.last_continuity_update_ts = ...]):

| Site | Trigger | Semantic intent (pre-#15682) |
|---|---|---|
| [keeper_turn_up_create.ml:565] | Keeper init | Bootstrap to now_ts |
| [keeper_post_turn.ml:434] | Snapshot present | Successful state write |
| [keeper_post_turn.ml:470] | Snapshot present (parallel branch) | Successful state write |
| [keeper_post_turn.ml:719-729] | Restore from parse | Restore prior write |
| [keeper_post_turn.ml] None branch (post-#15682) | Snapshot absent | Cooldown advance (new conflation) |

Readers:

| Site | Use | Semantic expectation |
|---|---|---|
| [keeper_compact_policy.ml:64] | `max(this, last_proactive_ts)` → cooldown gate | Cooldown anchor |
| [keeper_world_observation.ml:541] | `continuity_fallback_summary_text` | Successful state write |
| [keeper_heartbeat_snapshot.ml:201] | `continuity_fallback_summary_text` | Successful state write |
| [keeper_meta_json.ml:108,228] | Persist/parse | Cross-cycle restore (both meanings) |

The parse-side observability counter
[parse_last_continuity_update_ts_missing_total] (defined at
[keeper_meta_json_parse.ml:416]) was added precisely because the field
was nondeterministically present — itself a downstream symptom of the
conflation.

### 3.2 The compact gate's actual operand

[keeper_compact_policy.ml:64]:

```ocaml
let last_reflection_ts =
  max last_continuity_update_ts last_proactive_ts
in
```

The compact gate only ever reads this field as `max(...)` with
[last_proactive_ts]. It never reads it standalone. The semantic name
*last_reflection_ts* is correct for the gate's purpose, but
[last_continuity_update_ts] is the wrong field to feed it under the
new advance-on-no-snapshot rule.

## 4. Proposed split

Introduce one new field. Keep the existing one. Reassign semantics by
name and behavior.

### 4.1 Field definitions (post-split)

```ocaml
type runtime = {
  ...
  (* Last time this keeper completed a post-turn evaluation of the
     compact gate, regardless of whether a STATE snapshot was produced.
     This is the cooldown anchor consumed by Keeper_compact_policy. *)
  last_compact_check_ts : float;

  (* Last time this keeper successfully persisted a continuity STATE
     snapshot. Consumed by Keeper_world_observation /
     Keeper_heartbeat_snapshot for the "last updated at X" label. Never
     advances on a no-snapshot turn. *)
  last_continuity_update_ts : float;
  ...
}
```

### 4.2 Writer routing

- All five writer sites that previously wrote
  [last_continuity_update_ts] now write **either** [last_compact_check_ts]
  **or** [last_continuity_update_ts] (or both) based on the gate they
  represent. Concretely:
  - [keeper_post_turn.ml] Some snapshot → both
  - [keeper_post_turn.ml] None branch → only [last_compact_check_ts]
    (reverts the PR #15682 advance of the *display* anchor)
  - [keeper_turn_up_create.ml] init → both, since "no prior state"
    is a degenerate case that must not block first-turn compact
  - [keeper_post_turn.ml:719-729] restore-from-parse → both, preserving
    cross-cycle continuity

### 4.3 Reader routing

- [keeper_compact_policy.ml:64]:
  `max(last_compact_check_ts, last_proactive_ts)` — cooldown anchor.
- [keeper_world_observation.ml:541] /
  [keeper_heartbeat_snapshot.ml:201]:
  unchanged signature, but the value passed in is the unconflated
  [last_continuity_update_ts] which now means "real last write" again.
- [keeper_meta_json.ml]: serialize/parse both fields, with a backfill
  rule: if [last_compact_check_ts] is missing from a persisted blob,
  read [last_continuity_update_ts] as the fallback (so existing on-disk
  meta files keep working).

### 4.4 Telemetry deprecation

- [keeper_state_snapshot_skipped_no_state_total] (added by #15682)
  remains as a useful observability signal for "how often does the
  post-turn loop run without producing a snapshot." It is no longer
  load-bearing for the fix.
- New counter [keeper_compact_check_advanced_total{outcome=}] with
  outcome ∈ {`with_snapshot`, `without_snapshot`} replaces it for
  cardinality parity with the actual gate behavior. Old counter stays
  for one minor version, then is removed in a closeout commit.

## 5. Migration plan

| Phase | Scope | PR shape |
|---|---|---|
| 1 | Add [last_compact_check_ts] field + parse/serialize + backfill rule. No reader/writer changes. | Pure type-level addition, ~150 LOC. Tests verify round-trip + backfill. |
| 2 | Route [keeper_compact_policy] to read [last_compact_check_ts]. Revert [keeper_post_turn] None branch advance from [last_continuity_update_ts] to [last_compact_check_ts]. | Behavior change. Tests: V01 regression test (cooldown still advances on no-snapshot) + new test that display fallback text is unchanged on no-snapshot. |
| 3 | Update display reader docstring and remove [keeper_state_snapshot_skipped_no_state_total]. RFC closeout commit. | Cleanup. |

Phase 1 and Phase 2 can each be a Draft PR. Phase 3 only after Phase 2
has been on main for one minor version cycle (per RFC-0088's deprecation
cadence pattern).

## 6. Test plan

### 6.1 Unit (Phase 1)

- [test_keeper_meta_json] roundtrip with both fields set.
- [test_keeper_meta_json] backfill: missing [last_compact_check_ts] in
  persisted blob → reader sees [last_continuity_update_ts] value.

### 6.2 Lifecycle (Phase 2)

- Reuse [test_apply_post_turn_lifecycle_no_state_advances_cooldown_ts]
  (added by #15682) but assert it advances [last_compact_check_ts],
  not [last_continuity_update_ts].
- New test: post-turn with no snapshot leaves
  [last_continuity_update_ts] *unchanged* (display fallback still shows
  the prior real-write timestamp).
- New test: post-turn with snapshot advances *both* fields.

### 6.3 Reader-level

- Mock fallback summary path: feed a meta where
  [last_compact_check_ts] is fresh and [last_continuity_update_ts]
  is one hour old. Assert rendered text contains the one-hour-old ts.

## 7. Risks and trade-offs

| Risk | Mitigation |
|---|---|
| Adding a field to [keeper_meta] forces a meta-json schema bump and risks parse failures on old persisted blobs | Backfill rule + existing [Safe_ops.json_float ~default:0.0] pattern handles missing field gracefully. Round-trip test covers both directions. |
| Two-field representation invites future writers to update only one and silently regress | Add a typed helper [advance_post_turn_anchors : runtime -> snapshot:bool -> float -> runtime] that is the only call site; ban direct field writes via dune lint or comment + grep test. |
| Dashboard panels that read [last_continuity_update_ts] as cooldown anchor will visibly shift | Audit dashboard queries in [features/masc-cockpit-solidjs-poc] and any Prometheus rule that derives cooldown state from the field name. Update those to consume the new field. |
| TLA+ spec [KeeperOASAdvanced.tla] models the field abstractly; if the spec asserts properties that rely on cooldown advance being observable, the spec must be updated | Add a Phase 2 task to re-run TLC against the spec with the renamed cooldown variable. |

## 8. Alternatives considered

### 8.1 Status quo (live with PR #15682's conflation)

Rejected. Concrete failure mode: operator on-call escalates "state
snapshot looks current per dashboard" when the underlying continuity
write has been stuck for hours. We have a recent precedent — masc-mcp
2026-05-08~09 PR sweep flagged 14 read-drop counter PRs as the same
telemetry-as-fix anti-pattern (memory: [[reference_masc_mcp_lib_types_agent_sdk_collision]]).

### 8.2 Single field with derived "actual write" timestamp from messages

Compute "last successful state write" on-demand by scanning the
checkpoint message stream for [STATE] markers. Rejected: O(messages)
scan on every dashboard tick, and the marker scan is itself a
string-classifier anti-pattern (CLAUDE.md S2 "string/substring
classifier boost"). RFC-0089 prescribes typed-variant detection paths
for exactly this case.

### 8.3 Rename instead of split

Rename [last_continuity_update_ts] to [last_compact_check_ts] without
introducing a second field; let display readers compute the
"successful write" anchor from the [continuity_summary] string change.
Rejected: silently changes the meaning of a persisted field name,
breaks any external consumer of the meta-json dump, and the
"compute from string change" suggestion has the same string-classifier
problem as 8.2.

### 8.4 Drop the cooldown gate entirely

Let every turn re-evaluate compact eligibility without throttling.
Rejected: thrash under sustained context-overflow. The cooldown gate
exists for backpressure (CLAUDE.md "Eio drain loop must yield" Reason),
and removing it shifts the failure mode from "stale display" to "compact
storm under failure."

## 9. Open questions

1. **TLA+ binding** — does [KeeperOASAdvanced.tla] reference the
   compact gate's cooldown variable by name? Phase 2 audit step.
2. **Cross-cycle migration cadence** — running services with old-shape
   meta-json blobs need at least one read-with-backfill cycle before
   Phase 3 removes the backfill. Coordinate with deployment cadence.
3. **Dashboard cutover** — do we batch the dashboard-panel rename with
   Phase 2 or as a follow-up after Phase 2 stabilizes? Inclined toward
   follow-up to keep the Phase 2 PR small.

## 10. Implementation summary (filled at Implemented status)

_Reserved for closeout commit after Phase 3._

## 11. References

- PR #15682 — V01 fix that introduced the conflation; this RFC's
  immediate trigger.
- RFC-0088 — Counter-as-fix anti-pattern. This RFC follows the same
  discriminated-union refactor pattern.
- RFC-0089 — String classifier to typed variant. Cited in §8.2 rejection.
- CLAUDE.md "Workaround Rejection Bar" — Section "Symptom 억제 패턴",
  pattern *Counter / Cooldown / Fallback Resolution*.
- [keeper_post_turn.ml] — Primary code site for Phase 2.
- [keeper_compact_policy.ml:64] — Primary reader to re-route.
- [keeper_world_observation.ml:541], [keeper_heartbeat_snapshot.ml:201]
  — Display readers that gain back unconflated semantics.
