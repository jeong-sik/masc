---
rfc: "0240"
title: "Tool-pair invariant enforced at write-time (eliminate repair-on-read)"
status: Draft
created: 2026-06-15
updated: 2026-06-15
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0044", "0233"]
implementation_prs: []
---

# RFC-0240: Tool-pair invariant enforced at write-time

Status: Draft · The ToolUse/ToolResult pairing invariant is checked and
repaired when a checkpoint is *read* or a prompt is *assembled*. This RFC
moves the check to the *write/append* boundary, rejects malformed
pairings there, and removes the read-time repair so a malformed pairing
can no longer be silently persisted and re-repaired every load.
Drafted by: Claude (Opus 4.8), from a repair-on-read audit on
2026-06-15.

> Anchors marked **(verified)** were read against the worktree tree
> `132658e3f` (branch `rfc/0240-tool-pair-write-enforcement`,
> `origin/main` base `8fb955bbb`) on 2026-06-15. No code is changed by
> this RFC.

---

## §1 Problem

### §1.1 The invariant

A keeper conversation is a list of `Agent_sdk.Types.message`. Tool calls
must pair: every `ToolUse { id; ... }` block emitted by the assistant
must be answered by a `ToolResult { tool_use_id; ... }` block, and every
`ToolResult` must reference a `ToolUse` that precedes it. Two failure
shapes break the invariant:

- **dangling tool-use** — a `ToolUse` whose `id` is never matched by a
  later `ToolResult`.
- **orphan tool-result** — a `ToolResult` whose `tool_use_id` does not
  match any preceding `ToolUse`.

Providers reject a malformed pairing at dispatch, so the system must keep
the invariant intact across persistence, compaction, and prompt
assembly.

### §1.2 Today the invariant is repaired on read, not enforced on write

The repair body lives in `Keeper_context_core_accessors`. It walks the
message list and *drops* the offending blocks:

- `filter_group_message_content`
  (`lib/keeper/keeper_context_core_accessors.ml:318-348` **(verified)**)
  — under `drop_dangling_uses`, a `ToolUse` not present in
  `matched_tool_result_ids` is recorded and dropped
  (`record_dropped_tool_use`, returns `None`); under
  `drop_orphan_results`, a `ToolResult` whose `tool_use_id` is not in the
  allowed/seen set is recorded and dropped.
- `filter_orphan_result_message_content`
  (`lib/keeper/keeper_context_core_accessors.ml:350-367` **(verified)**)
  — drops orphan `ToolResult` blocks in a result-only message.
- `repair_broken_tool_call_pairs_with_stats`
  (`lib/keeper/keeper_context_core_accessors.ml:493-498` **(verified)**)
  drives both with mode `{ drop_dangling_uses = true; drop_orphan_results
  = true }`.

This repair is invoked at **read / assembly** time:

| Site | What it does | file:line |
|---|---|---|
| `deserialize_context` | repairs every checkpoint deserialized from disk | `lib/keeper/keeper_context_core_accessors.ml:520` **(verified)** |
| `context_of_oas_checkpoint` | repairs messages on the checkpoint load path | `lib/keeper/keeper_context_core.ml:585` **(verified)** |
| `load_context_from_checkpoint` → `sanitize_oas_checkpoint` | repairs on load **and writes the repaired copy back** | `lib/keeper/keeper_context_core.ml:695,709` **(verified)** |
| `keeper_run_prompt` | repairs the in-memory history immediately before building the prompt for the LLM call | `lib/keeper/keeper_run_prompt.ml:183` **(verified)** |
| `keeper_run_tools_hooks` reducer | `repair_broken_tool_call_pairs_observed` runs as a `Context_reducer.Custom` step during prompt assembly | `lib/keeper/keeper_run_tools_hooks.ml:502-548` **(verified)** |

A second cluster runs the same repair *after* a transform, then writes
the result — repair-then-write, which still masks the producer:

| Site | file:line |
|---|---|
| compaction post-fold repair | `lib/keeper/keeper_compact_policy.ml:320` **(verified)** |
| post-turn compaction | `lib/keeper/keeper_post_turn.ml:633` **(verified)** |
| post-turn compaction recovery | `lib/keeper/keeper_post_turn.ml:910` **(verified)** |
| handoff rollover | `lib/keeper/keeper_rollover.ml:301` **(verified)** |

### §1.3 Why this is the repair/sanitize workaround class

CLAUDE.md §워크어라운드 거부 기준 names "Repair / Sanitize" as a
symptom-suppression pattern whose root is "Protocol boundary enforce
(validate at write, reject on read)". This code is the canonical
instance:

1. **The producer is never fixed.** A malformed pairing is dropped on
   read, so whatever *appended* a dangling `ToolUse` or an orphan
   `ToolResult` keeps doing so. The drop is silent to the producer.
2. **The malformed state can be persisted.** `append`
   (`lib/keeper/keeper_context_core_accessors.ml:176` **(verified)**) is
   a plain `messages_of_context ctx @ [ msg ]` with no pairing check, and
   `save_oas` (`lib/keeper/keeper_checkpoint_store.ml:362` **(verified)**,
   returns `(unit, string) result`) does not validate pairing. So a
   checkpoint with a broken pair lands on disk and is re-repaired on
   every subsequent load — `load_context_from_checkpoint` even rewrites
   the repaired copy back (§1.2), turning each load into a lossy rewrite.
3. **Telemetry stands in for a fix.** `ToolPairRepair`
   (`masc_keeper_tool_pair_repair_total`) and
   `CompactionPairRepairDrops` (`masc_keeper_compaction_pair_repair_drops_total`)
   (`lib/keeper_metrics/keeper_metrics.ml:266,272` **(verified)**) count
   drops. A counter is an alarm, not a fix — the data is still dropped.
4. **The drop is data loss with no causal record.** The dropped block is
   summarized into bounded diagnostic samples
   (`Keeper_context_core_pair_repair_stats`, sample cap 8, 256-byte
   prefix, `lib/keeper/keeper_context_core_pair_repair_stats.ml:24-25`
   **(verified)**) — enough to alert, not enough to reconstruct.

The pattern is a `match` arm choosing "drop and continue" over `Error`,
matching the CLAUDE.md §AI 코드 생성 안티패턴 #2 "Unknown → Permissive
Default". RFC-0042 closed the same class for keeper terminal codes by
replacing string classification with a closed sum; RFC-0044 closed it
for persistence read-drop by typing the drop. RFC-0233 §1.1 explicitly
refused view-side dedup as read-side repair. This RFC closes it for tool
pairing.

### §1.4 Introduction

`repair_broken_tool_call_pairs` was introduced in `85692cadb`
(#7366 "fix(keeper): repair broken tool call pairs", 2026-04-15
**(verified via `git log -S`)**), wired into `deserialize_context` and
`context_of_oas_checkpoint` from the first commit — i.e. read-time repair
was the original design, not a later regression. The module decomposition
that produced the current file layout is `c4df7c44d`
(#20156, 2026-06-05 **(verified)**); span-aware drop is `fed12810e`
(#21045); diagnostic preservation is `831e364e2` (#21039). None changed
the read-vs-write boundary.

## §2 Design

### §2.1 Parse, don't validate: a typed paired-message-list

Introduce a type whose values can only hold a well-paired message list.
Construction is the only place the invariant is checked; once held, no
consumer needs to re-check or repair.

```ocaml
module Paired_messages : sig
  type t
  (* A message list whose ToolUse/ToolResult blocks pair up:
     every ToolUse id is answered by a later ToolResult, and every
     ToolResult references a preceding ToolUse. *)

  type violation =
    | Dangling_tool_use of { tool_use_id : string; tool_name : string }
    | Orphan_tool_result of { tool_use_id : string }
    | Duplicate_tool_result of { tool_use_id : string }

  val of_messages :
    Agent_sdk.Types.message list -> (t, violation list) result
  (* Parse: Ok t when the list is well-paired, Error violations
     otherwise. Total, pure, no I/O. *)

  val to_messages : t -> Agent_sdk.Types.message list

  val append :
    t -> Agent_sdk.Types.message -> (t, violation list) result
  (* Append one message and re-parse the pairing window it touches. *)
end
```

The violation cases are the existing drop reasons (`record_dropped_tool_use`,
`record_dropped_tool_result`, and the duplicate guard in
`filter_group_message_content`,
`lib/keeper/keeper_context_core_accessors.ml:337` **(verified)**) turned
into a closed sum. The classifier the repair already runs (walk groups,
match `tool_use_id` against allowed/seen ids) becomes the *parser*; the
only behavioral change is the verdict: `Error` instead of "drop and
continue".

### §2.2 Enforce at the write boundary

Two write boundaries, both currently unchecked:

1. **In-memory append.** `Keeper_context_core.append`
   (`lib/keeper/keeper_context_core_accessors.ml:176` **(verified)**)
   gains a checked sibling that returns `(working_context, violation
   list) result`. Callers that append assistant turns and tool results
   (the `append`/`append_many` users) consume the `Result`. A malformed
   append is the producer bug surfacing at the exact site that created
   it, not three loads later.

2. **Checkpoint persistence.** `save_oas`
   (`lib/keeper/keeper_checkpoint_store.ml:362` **(verified)**) already
   returns `(unit, string) result`; before writing, it parses
   `ckpt.messages` through `Paired_messages.of_messages` and returns
   `Error` (mapped to the existing `Store_error`/string channel) on
   violation. Save callers already pattern-match the result
   (`keeper_run_context.ml:191`, `keeper_post_turn.ml:649,927`,
   `keeper_rollover.ml:317`, `keeper_turn_up_create.ml:477`
   **(verified)**), so the reject path has a place to go.

Once both boundaries reject malformed pairings, the read path can hold a
`Paired_messages.t` invariant by construction. `deserialize_context`
(`:520`) and `context_of_oas_checkpoint` (`:585`) parse instead of
repair: a stored checkpoint that fails to parse is a *parse error*
(routed to the existing `CheckpointFailures` counter at
`lib/keeper/keeper_context_core.ml:660-686` **(verified)**), not a silent
drop. The repair functions and their read-time call sites are deleted.

### §2.3 Caller handling of rejection

The append boundary is reached after a turn produces blocks. The keeper
already has a turn-failure path (it records receipts, can retry, can
abort the turn). A `Dangling_tool_use`/`Orphan_tool_result` violation at
append maps to a turn-level failure with the violation as the typed
reason — the same severity as a provider-rejected malformed request,
which is what the dropped data would have caused downstream anyway. The
violation list is logged with the existing keeper warn channel and
emitted on the existing `ToolPairRepair` counter relabeled to a
*rejection* counter (drops become rejections; the metric name keeps its
`_total` series so dashboards do not lose history, with a `kind`
label of `rejected_*`).

The save boundary maps a violation to `Error`, which save callers
already handle (they log and continue without persisting that
checkpoint, preserving the last good checkpoint). This is strictly safer
than today, where a malformed checkpoint is persisted in repaired
(lossy) form.

## §3 Non-goals

- This RFC does not change how tool calls are *executed* or how
  `ToolResult` blocks are *built* — only where the pairing invariant is
  checked.
- This RFC does not address explicit MASC LLM compaction or UTF-8 transport
  validity. Those are separate boundaries; only the pairing-repair coupling
  is removed. `trim_messages_preserving_pairs`
  (`lib/keeper/keeper_context_tool_message_pairs.mli` **(verified)**)
  already *preserves* pairs rather than repairing, and stays.
- This RFC does not migrate to a new on-disk checkpoint format; existing
  checkpoints are handled by §4.

## §4 Migration

The risk is existing on-disk checkpoints that already carry a broken
pairing (written under the current repair-then-save paths). After this
change they would fail to parse on load.

1. **One-time forward repair.** A migration step parses each stored
   checkpoint; on violation it applies the *old* repair once, rewrites
   the checkpoint, and emits a one-shot migration counter
   (`kind=migration_repair`). This is the only place the old drop logic
   survives, behind an explicit migration flag, removed after the fleet
   has rolled over (`removal target: one release after merge`).
2. **Grace window.** For one release, a load-time parse failure on a
   pre-migration checkpoint falls back to the migration repair (logged at
   WARN) rather than discarding the checkpoint, so a keeper mid-flight is
   not stranded. After the grace window the fallback is deleted and a
   parse failure is a hard `CheckpointFailures` error.
3. **No new format.** Migration rewrites in the same format; only the
   message list is re-paired.

### §4.1 Trade-offs

- **Cost: rejection at append can surface a producer bug that today is
  invisible.** This is the intended effect — but if a producer emits
  malformed pairs frequently, turns will fail until that producer is
  fixed. Mitigation: the grace window (§4.2) plus a dashboard on the
  rejection counter lets operators see the producer rate before the hard
  cutover. The producer fix is in scope as follow-up work, not deferred
  indefinitely — the rejection telemetry names the exact append site.
- **Cost: the migration carries the old drop logic for one release.**
  This is a bounded, flagged exception to the no-repair rule, justified
  by not stranding live checkpoints, with an explicit removal target.
- **Cost: re-parse on append is O(window) per message.** The classifier
  already runs over the full list on every read; checking the touched
  pairing window on append is strictly less work than the per-read full
  walk it replaces.
- **Benefit: data loss stops.** Today a dropped block is gone and the
  producer is unobserved. After this change the block is never silently
  dropped; it is either well-formed (kept) or the producer fails loudly.

## §5 Verification harness

### §5.1 Property tests (parser side)

`test/test_pbt_context_overflow.ml` already exercises
`repair_broken_tool_call_pairs_with_stats` across generated message lists
(`:417-765` **(verified)**). These convert to parser properties:

- **P1 well-paired round-trip.** For any well-paired generated list,
  `of_messages l` is `Ok t` and `to_messages t = l` (identity — no
  silent transform).
- **P2 violation completeness.** For any list with k injected dangling
  uses and m injected orphan results, `of_messages` returns
  `Error vs` with exactly k `Dangling_tool_use` and m `Orphan_tool_result`
  violations (no over- or under-reporting).
- **P3 append monotonicity.** `append t msg` is `Ok` iff appending `msg`
  to `to_messages t` is well-paired; the two construction paths agree.

### §5.2 No-read-repair grep gate (boundary side)

A drift-guard test asserts the read-time repair sites are gone:
`repair_broken_tool_call_pairs` has zero references under `lib/keeper/`
except inside the flagged migration module. This is a structural
assertion (the symbol is deleted), not a substring classifier on data —
it guards the *absence* of the workaround, which is the property this RFC
establishes. It fails the build if a future PR reintroduces read-time
repair.

### §5.3 TLA+ bug model (clean + buggy pair)

Per CLAUDE.md §TLA+ Bug Model and the `specs/bug-models/` convention
(clean `.cfg` "no error", `-buggy.cfg` "invariant violated"), add
`specs/bug-models/ToolPairWriteEnforce.tla`:

| Element | Role |
|---|---|
| `bank` | sequence of blocks: `[kind \|-> "use"\|"result", id \|-> Nat, matched \|-> BOOLEAN]` |
| `Append(block)` (clean) | appends only if the result keeps `PairInvariant` (write-time enforce); otherwise the transition is disabled (reject) |
| `AppendUnchecked(block)` (bug) | appends any block; models today's `append` with no pairing check |
| `PairInvariant` | no dangling `use` and no orphan `result` in `bank` |
| `Next` (clean) | `Append` only |
| `NextBuggy` | `Next \/ AppendUnchecked` |

- `ToolPairWriteEnforce.cfg`: `SPECIFICATION Spec`, `INVARIANT
  PairInvariant` → TLC reports no error (write-time enforce holds the
  invariant).
- `ToolPairWriteEnforce-buggy.cfg`: `SPECIFICATION SpecBuggy`,
  `INVARIANT PairInvariant` → TLC reports the invariant violated (an
  `AppendUnchecked` of a dangling use reaches a bad state). This is the
  exact state today's read-repair must compensate for.

Both `.cfg` must hold: clean passes, buggy fails. A clean that does not
fail under `NextBuggy` would mean the invariant is too weak.

## §6 Evidence trail

- Repair body and modes: `lib/keeper/keeper_context_core_accessors.ml:299-502`
  **(verified)**.
- Read-time call sites: table in §1.2 **(verified)**.
- Repair-then-write call sites: table in §1.2 **(verified)**.
- Uncovered write boundaries: `append`
  `lib/keeper/keeper_context_core_accessors.ml:176`; `save_oas`
  `lib/keeper/keeper_checkpoint_store.ml:362` **(verified)**.
- Drop counters: `lib/keeper_metrics/keeper_metrics.ml:266,272`
  **(verified)**.
- Diagnostic bounding (data-loss-with-only-samples): 
  `lib/keeper/keeper_context_core_pair_repair_stats.ml:24-25` **(verified)**.
- Save callers that already handle `result`:
  `keeper_run_context.ml:191`, `keeper_post_turn.ml:649,927`,
  `keeper_rollover.ml:317`, `keeper_turn_up_create.ml:477` **(verified)**.
- Existing property tests to convert: `test/test_pbt_context_overflow.ml:417-765`
  **(verified)**.
- Introduction commit: `85692cadb` (#7366, 2026-04-15)
  **(verified via `git log -S`)**.
- Precedent RFCs: RFC-0042 (closed-sum terminal codes), RFC-0044 (typed
  persistence read-drop), RFC-0233 §1.1 (refused view-side dedup as
  read-side repair).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
