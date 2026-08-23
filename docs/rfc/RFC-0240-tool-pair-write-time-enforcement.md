---
rfc: "0240"
title: "Tool-pair invariant enforced at write-time (eliminate repair-on-read)"
status: Draft
created: 2026-06-15
updated: 2026-07-28
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0044", "0110", "0233"]
implementation_prs: []
---

# RFC-0240: Tool-pair invariant enforced at write-time

> **2026-08-23 갱신.** 아래 본문이 근거로 삼은 `Transcript_corruption_reset_required`
> 래치는 제거됐다. 불완전한 tool transcript 는 이제 다른 실패와 같은 typed route 를
> 타고 `turn_failures` blocker 로 드러나며, 부팅 시 `Keeper_transcript_tail_recovery`
> (§2.4) 가 프로세스 사망이 남긴 열린 cycle 을 닫는다. 과거 사실은 evidence 이지
> scheduling gate 가 아니다. write-time 강제라는 이 RFC 의 본론은 여전히 미구현이다.

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

> **Amendment 2026-07-28** (§1.5, §1.6, §2.1a, §2.2 correction, §2.4,
> §5.4, §6.1). The original draft treats every unmatched `ToolUse` as one
> violation shape. It is two: a `ToolUse` unmatched *in tail position* is
> an in-flight tool call that checkpoint persistence stores on purpose,
> and a `ToolUse` unmatched *mid-history* is the producer bug this RFC
> targets. Enforcing §2.2 as originally written would reject the
> in-flight checkpoint at save and discard the running turn on every
> crash. The amendment splits the two, keeps the save boundary permissive
> for the tail, and adds the missing recovery move that closes it.
> Amendment anchors marked **(verified 07-28)** were read against
> `origin/main` `97e5ffeca8` — the commit the live fleet is running.
> Motivated by a live incident on 2026-07-27 (§1.5).

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

### §1.5 The case this RFC does not cover: crash consistency

*Added 2026-07-28.*

The original draft reasons about a *producer* emitting a malformed pair.
There is a second way the invariant breaks that no producer discipline
can prevent: **the process dies between committing a `ToolUse` and
committing its `ToolResult`.** The write that would have closed the pair
never runs, so "reject at write" has nothing to reject.

**The producer is exact and reachable today.** agent_core persists a durable
checkpoint at stage `After_assistant_collected`
(`agent_core/lib/pipeline/pipeline.ml:213-220` **(verified 07-28)**), whose
state is `messages = snoc agent.state.messages assistant_message` — the
assistant message carrying the `ToolUse` blocks appended, no `ToolResult`
in existence yet. masc's sink saves **every** snapshot with no stage
filter: `checkpoint_sink` in `lib/keeper/keeper_agent_run.ml`
**(verified 07-28)** passes `snapshot.stage` only to an optional observer
(`on_checkpoint_stage`) and then calls
`Keeper_checkpoint_store.save_oas_classified` unconditionally. So the
canonical checkpoint is *designed* to be durably open across the tool
cycle. Any death in that window leaves the open tail on disk.

This is not hypothetical. On 2026-07-27 the live fleet restarted three
times (`11:10:35Z`, `14:42:06Z`, `15:25:41Z`; server log
`<base-path>/.masc/logs/system_log_2026-07-27.jsonl` **(verified 07-28)**). **Two
different death modes both produced it**, which is why neither a
shutdown hook nor producer discipline is sufficient:

- **Ungraceful kill, `14:41:26Z`–`14:42:06Z`.** The last record before
  the gap is at `14:41:26Z` and the next at `14:42:06Z`; counting
  `"ts"`-anchored records per second over that window gives **zero**
  (an unanchored substring count gives false positives — timestamps
  recur inside message bodies). Sequence number `37496` was allocated
  and never flushed: `rg -c '"seq":37496,'` exits 1 while `37495` and
  `37497` each return 1 **(verified 07-28)**. The restart came up on a
  binary built at `14:40:14Z` (`bundle build-stamp … older than server
  binary 2026-07-27T14:40:14Z`, logged `14:42:06Z`) — i.e. a rebuild
  killed the running server mid-turn. No shutdown hook ran, and none
  could have.
- **Graceful `SIGINT`, `15:25:28Z`.** The log records
  `signal attribution: no takeover breadcrumb — sender is external
  (user/pkill/system)`, all four shutdown phases, and then per keeper
  `<name>: fiber unresolved during shutdown (graceful, not a crash)`.
  The orderly path still cancels fibers mid-tool-cycle, so `sangsu`
  latched on the next start anyway.

Four keepers never came back. Each died with the identical error:

```
[masc_oas_error] {"kind":"incomplete_tool_transcript",
                  "reason":"unresolved_tool_results",
                  "detail":"Keeper_compaction_unit.Unresolved_tool_results {
                              tool_use_ids = [\"call_u3gtrgo6\"; \"call_y1wnpvff\"]}"}
```

| keeper | open `tool_use_id`s | latched at | durable `latched_reason` |
|---|---|---|---|
| `executor` | `call_4oejwkij`, `call_fgwa0fvt` | `14:42:12Z` | `transcript_corruption_reset_required` |
| `kinobot-frontend` | `call_eyvvaza5` | `14:47:46Z` | `transcript_corruption_reset_required` |
| `sangsu` | `call_u3gtrgo6`, `call_y1wnpvff` | `15:26:11Z` | `transcript_corruption_reset_required` |
| `rondo` | `call_8mdhr4wm` | `14:42:11Z`, overwritten `14:54:33Z` | `operator_paused` (`keeper_down`) |

The latch fires on the **first post-restart cycle**, not at the moment of
death: the tail was written before the kill, and the rejection happens
when the next turn re-reads it. `executor` latches within seconds of the
`14:42:06Z` start; `kinobot-frontend` on its first cycle 5m54s later;
`sangsu` on its first post-`15:25:41Z` turn terminal. A restart is a
fleet-wide trigger, so one interrupt takes down several lanes at once —
this is one incident, not four.

`rondo` shows a second defect on top. It failed at `14:42:11Z` with the
same signature, then an MCP `masc_keeper_down` at `14:54:28Z` replaced
its latch: `lib/keeper/keeper_shutdown_finalize.ml:309-318` builds
`paused_meta` with `Operator_paused { keeper_down }` **without reading
the existing `meta.latched_reason`**. A terminal, reset-required latch is
silently downgraded to an ordinary operator pause, which disarms both
transcript guards. The same hole exists on the directive path
(`lib/keeper/keeper_keepalive.ml:125-138`, where the transcript guard at
`:284` is `if (not paused) && …` — resume-only). That latches are not
monotonic is a distinct bug and should be filed separately; it is noted
here because it is why `rondo`'s durable reason no longer names the real
cause. `rondo`'s pre-`14:54` latch kind is **inferred**, not logged — no
log line records a latch *kind*, and `rondo.json` was overwritten.

The state is terminal, not transient. `Keeper_lifecycle_admission`
classifies `Transcript_corruption_reset_required` as a pause that generic
resume cannot clear (`lib/keeper/keeper_lifecycle_admission.mli:1-12`
**(verified 07-28)**), and
`lib/keeper/keeper_paused_work_resume_transaction.ml:168-174`
**(verified 07-28)** returns `Error Durable_owner_transcript_reset_required`
for it. Meanwhile the dashboard boot preflight rejects with
`"keeper is operator-paused; commit Resume_owner through the directive
endpoint"`
(`lib/server/server_dashboard_http_keeper_api_lifecycle_post.ml:267`
**(verified 07-28)**) — advice that path cannot honour. The runtime's own
broadcast names the right *class* of remedy and disagrees with the 409:
`disposition=operator_reset_required reason=transcript_corruption`.

But the named remedy does not exist as an action either. `masc_keeper_reset`
zeroes usage counters (`lib/keeper/keeper_meta_contract.ml:671-672` is
`map_usage (fun _ -> zero_usage) m`) and never touches `latched_reason`;
`masc_keeper_clear` rewrites the checkpoint but leaves meta alone;
`masc_keeper_up` copies the latch forward
(`lib/keeper/keeper_turn_up_update.ml:118-119`). Only two sites in the
tree write `latched_reason = None` — the fresh-create path
(`keeper_turn_up_create.ml:213`) and `mark_resumed`
(`keeper_meta_contract.ml:432`), and `mark_resumed` is a deliberate no-op
for this latch (`:423-427`). `rg -ni "transcript.corrupt" docs/` returns
zero runbook coverage. So the state is not merely operator-gated; for
these three keepers it is a dead end reachable by an ordinary restart.

**Requirement added by this section:** an interrupted tool call must be
recoverable without operator action. A restart may cost the in-flight
turn; it must not cost the lane. A latch whose only exit is
delete-and-recreate is not an acceptable resting place for a routine
process death.

### §1.6 What happened to the repair between draft and now

*Added 2026-07-28.*

The read-time repair this RFC proposed to delete **was deleted — without
the write-time enforcement that was supposed to replace it.**

| date | change | effect |
|---|---|---|
| 2026-04-15 | `85692cadb4` (#7366) | repair-on-read introduced |
| 2026-06-12 | RFC-0110 marked `Implemented` (PR #15924) | shipped visible-content *drop* + `masc.tool_pair_repair` telemetry, not write-boundary atomicity |
| 2026-06-15 | this RFC drafted | write-time enforcement designed; `implementation_prs: []` |
| 2026-07-18 | `f5f45f97c3` (#25046) | repair symbols removed; compaction bound to the exact structural source |
| 2026-07-23 | `4a1880624b` (#25335) | `validate_provider_transcript` added — hard reject at provider admission |
| 2026-07-27 | — | four keepers latched (§1.5) |

`repair_broken_tool_call_pairs`, `repair_dangling_tool_use_messages`, and
the `tool_pair_repair` metric now have zero references under `lib/`
(searched as `repair_broken`, `repair.*pair`, and `tool_pair_repair`
**(verified 07-28)**). RFC-0110's own §1 describes what it shipped:
"깨진 structural block 을 visible content 에서 drop 하고, bounded id/name
sample 을 … telemetry stats 로 남긴다" — drop plus counters, which is the
telemetry-as-fix signature `software-development.md` rejects. Its
`status: Implemented` is therefore misleading and should be corrected to
`Partially implemented (superseded by 0240)`; left as-is, a reader
concludes the write boundary is already closed.

The removal (#25046) and the hard reject (#25335) are individually
defensible. Together, and without §2, they leave the system with neither
repair nor enforcement: a checkpoint that is structurally open at
restart has no path back. #25335's own commit message states the
consequence plainly:

> A quarantined poisoned checkpoint is preserved unmodified by design, so
> every re-lease reloads the same incomplete transcript and the provider
> admission rejects it again

The response was a retry counter with an escalation ceiling of 3
(`transcript_quarantine_consecutive_retries`). Because the checkpoint is
preserved unmodified, the retry is deterministic and can never succeed;
the counter only chooses how many times to fail before parking the lane.
That is the cap/cooldown symptom-suppression shape, and it is a symptom
of the missing closing move in §2.4 — not a fix for it.

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

### §2.1a The tail is already typed — do not re-conflate it

*Added 2026-07-28. Amends §2.1.*

`Keeper_compaction_unit` already provides the parser this RFC asks for,
and it already separates the open tail from the closed history
(`lib/keeper/keeper_compaction_unit.mli:62-65` **(verified 07-28)**):

```ocaml
type partition =
  { closed_prefix : closed_unit list          (* every ToolUse has its ToolResult *)
  ; protected_suffix : Agent_sdk.Types.message list }   (* the open cycle *)
```

The two validators built on it differ in exactly one clause
(`lib/keeper/keeper_compaction_unit.ml:262, 291-299` **(verified 07-28)**):

```ocaml
let validate messages = Result.map (fun _partition -> ()) (partition messages)
(* accepts a non-empty protected_suffix — persistence path *)

let validate_provider_transcript messages =
  match partition messages with
  | Error error -> Error (Invalid_transcript_structure error)
  | Ok { protected_suffix = []; _ } -> Ok ()
  | Ok { protected_suffix; _ } ->
    Error (Unresolved_tool_results
             { tool_use_ids = unresolved_tool_use_ids protected_suffix })
(* rejects it — provider dispatch path *)
```

The asymmetry is deliberate and documented: provider dispatch "rejects
the open ToolUse suffix that **checkpoint persistence deliberately
preserves for crash recovery**"
(`lib/keeper/keeper_compaction_unit.mli:89-91` **(verified 07-28)**).

Two consequences for §2.1:

1. **`Paired_messages` must not flatten this.** A `violation` list with a
   single `Dangling_tool_use` case cannot express "legal in-flight tail"
   versus "producer bug mid-history". Either reuse `partition` as the
   parser, or give the type a tail slot:

   ```ocaml
   type t = private
     { closed    : closed_cycle list
     ; open_tail : open_cycle option }   (* at most one, tail position only *)

   type violation =
     | Dangling_tool_use_mid_history of { tool_use_id : string; tool_name : string }
     | Orphan_tool_result of { tool_use_id : string }
     | Duplicate_tool_result of { tool_use_id : string }
   ```

   A `ToolUse` unmatched at the tail is `open_tail`, not a violation. A
   `ToolUse` left unmatched with any closed cycle following it is
   `Dangling_tool_use_mid_history` — that is the producer bug, and
   rejecting it at write is this RFC's original and correct point.

2. **The ids needed to close the tail are already computed.**
   `unresolved_tool_use_ids` (`:264` **(verified 07-28)**) returns exactly
   the open ids. It has one call site — `:298`, populating the error
   payload. The system computes the precise list of what it would need to
   close, then ships that list inside a fatal error instead of closing
   it. §2.4 spends it.

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

   > **Correction 2026-07-28.** As written, this rejects *any* checkpoint
   > whose messages do not fully pair — including the in-flight one whose
   > tail is open because the tool call has not returned yet. Save callers
   > "log and continue without persisting that checkpoint", so the effect
   > would be: **the running turn is never saved, and every crash loses
   > it.** That contradicts the stated persistence contract
   > (`keeper_compaction_unit.mli:89-91` **(verified 07-28)**) and is
   > strictly worse than today.
   >
   > The save boundary rejects only `Dangling_tool_use_mid_history`,
   > `Orphan_tool_result`, and `Duplicate_tool_result` (§2.1a). A
   > non-empty `open_tail` is **accepted and persisted** — it is the
   > record of what was in flight, and §2.4 is what closes it.
   >
   > The anchor has also drifted: there is no `save_oas` at
   > `keeper_checkpoint_store.ml:362` at `97e5ffeca8` (that line is inside
   > a symlink-validation comment). The save entry points are
   > `save_oas_history:133`, `save_oas_classified_typed:927`, and
   > `save_oas_classified:978` **(verified 07-28)**. Re-anchor before
   > implementing; see §6.1.

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

### §2.4 The missing move: close the open tail at recovery

*Added 2026-07-28.*

Write-time enforcement (§2.2) cannot cover §1.5: no boundary check
prevents a write that never happened. The open tail must be **closed**,
and the only place that can be done for both graceful and hard death is
**recovery**, not shutdown — a shutdown hook does not run under `kill -9`
or OOM.

**Where.** Server boot already has the phase.
`Keeper_persistence_prepare` runs `Restoring_shutdown` (`set_phase` at
`lib/server/server_bootstrap_loops.ml:490`) then `Recovering_requests`
(`:558`) **(verified 07-28)**. Closing belongs in `Recovering_requests`,
before any keeper loop starts.

**What.** For each restored checkpoint, parse with `partition`. If
`protected_suffix` is non-empty, append one `ToolResult` per id from
`unresolved_tool_use_ids` (`keeper_compaction_unit.ml:264`) and persist.
After that the checkpoint satisfies `validate_provider_transcript` and
the lane resumes with no operator action.

**With what content — the load-bearing detail.** The synthesized result
must not claim the tool failed. The process died after the call was
issued; the tool may already have taken effect (a write, a push, an API
call) with only the *result record* lost. The honest content is the
uncertainty:

```
is_error: true
content:  "interrupted: the server restarted before this tool result was
           recorded. The call may or may not have taken effect. Verify
           current state before retrying."
```

This is what separates this from the repair/sanitize class
`software-development.md` rejects. Repair guesses at a corrupt artifact
of unknown provenance. Here the provenance is exact and known at
recovery time — this id was issued, no result was recorded — and the
appended block states precisely that, including what is *not* known. It
completes a record rather than inventing one. The agent then re-observes
state, which is what a human operator does after an interrupted command.

**Why the content states uncertainty rather than consulting a record.**
masc has no per-tool-call settlement authority to consult **(verified
07-28)**. Execution receipts are turn-level and carry no `tool_use_id`
(`<base-path>/.masc/keepers/<name>/execution-receipts/`, schema
`keeper.execution_receipt.v1`). The decision log does carry
`tool_use_id` with a `disposition`, but `tool_exec` is emitted *after*
execution with `duration_ms`/`result_bytes`
(`lib/keeper/keeper_tools_oas_handler_exec.ml:114-190`), so it is lost
with the unflushed buffer at exactly the crash being recovered — all six
unresolved ids from the 2026-07-27 incident are absent from their
keepers' `decisions.jsonl` while completed ids from the same turns are
present. Absence therefore cannot be read as "did not run".

agent_core does have the authority: `Pipeline_execution_resume`
(`agent_core/lib/pipeline/pipeline_execution_resume.ml`) classifies a crashed
tool turn against the execution journal and replays settled results
rather than re-executing. masc does not use it — `rg` for
`Execution_journal|Pipeline_execution_resume|durable_execution` over
masc `lib/` and `bin/` returns **zero hits**, and receipts record
`oas_dispatch_mode: single_provider_agent_run` with
`oas_internal_runtime_disabled: true`. Adopting agent_core durable execution
for keeper turns is the principled successor to §2.4 and would replace
"may or may not have taken effect" with a journal-backed answer. It is a
separate project; until then, stating the uncertainty is the accurate
report, not a shortcut.

**Effect classification (design question, not yet settled).** Whether
every interrupted call may be auto-closed, or whether effectful tools
should additionally raise an operator notice, depends on the tool
catalog's effect typing. Read-only calls are unambiguously safe to close.
For effectful calls the content above is still honest, but a reviewer may
want the lane to surface a notice rather than proceed silently. Resolve
against `Tool_result`'s effect disposition before implementation; do not
gate the whole change on it — a lane that resumes with an honest
"verify first" note strictly dominates a lane that is dead.

**Rejected alternative: filter the stage at the sink.** The obvious
cheaper move is to stop persisting `After_assistant_collected` — add a
stage filter to `checkpoint_sink` so the open tail never reaches disk.
Rejected: that is the same information loss as §2.2's naive form. The
`After_assistant_collected` checkpoint is what tells recovery *which*
tool calls were in flight; dropping it means a crash loses the whole
assistant turn and the record of what it had already dispatched — which
matters precisely when a tool may have taken effect. Persist the open
tail; close it at recovery.

**What this replaces.** With §2.4 in place,
`transcript_quarantine_consecutive_retries` and its escalation ceiling of
3 (#25335) lose their reason to exist: the retry stops being
deterministic-and-doomed because recovery mutates the checkpoint into a
dispatchable one. Removing that counter is part of this RFC's
implementation, not a follow-up — leaving it would keep a cap whose root
cause is gone.

**What it does not replace.** `Transcript_corruption_reset_required`
stays for genuinely unparseable history (`Invalid_transcript_structure`,
i.e. `partition` returning `Error`). §2.4 only closes the case where
`partition` returns `Ok` with a non-empty `protected_suffix`. That
narrowing is the point: today both collapse into one terminal latch.

## §3 Non-goals

- This RFC does not change how tool calls are *executed* or how
  `ToolResult` blocks are *built* — only where the pairing invariant is
  checked.
- This RFC does not address message-content size capping, UTF-8
  sanitation, or token trimming (`sanitize_checkpoint_messages`,
  `trim_messages_preserving_pairs`). Those are separate transforms; only
  the pairing-repair coupling is removed. `trim_messages_preserving_pairs`
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

### §5.4 Incident regression: restart must not strand a lane

*Added 2026-07-28. The 2026-07-27 incident (§1.5) has no covering test —
that is why it reached production.*

- **R1 open tail survives save.** A checkpoint whose messages end in an
  unmatched `ToolUse` is accepted by the save boundary and round-trips
  byte-identically. Guards the §2.2 correction: an implementation that
  rejects the in-flight checkpoint fails here.
- **R2 recovery closes the tail.** Given a persisted checkpoint with k
  unresolved `tool_use_id`s, `Recovering_requests` produces a checkpoint
  with exactly k appended `ToolResult` blocks, one per id, each
  `is_error: true`, and `validate_provider_transcript` then returns `Ok`.
- **R3 no latch on the interrupted path.** Driving a keeper through
  interrupt → restart → recovery leaves `paused = false` and
  `latched_reason = None` in durable meta. Fails against today's code,
  where `commit_transcript_corruption`
  (`lib/keeper/keeper_heartbeat_loop.ml:780` **(verified 07-28)**) writes
  the latch.
- **R4 mid-history dangling still rejects.** A `ToolUse` left unmatched
  with a closed cycle after it is rejected at the write boundary. Guards
  against §2.1a's tail allowance being over-applied into a blanket
  "unmatched is fine".
- **R5 unparseable still latches.** `partition` returning `Error`
  (`Invalid_transcript_structure`) still produces
  `Transcript_corruption_reset_required`. Guards the §2.4 narrowing —
  the terminal latch must not be deleted, only stop catching the
  in-flight case.

R1–R3 fail on `97e5ffeca8` and must pass after implementation; R4–R5
must pass both before and after.

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

### §6.1 Amendment evidence (2026-07-28, `origin/main` `97e5ffeca8`)

The 06-15 anchors were re-checked at `97e5ffeca8`. Two have drifted and
must be re-derived before implementation:

| §6 anchor | state at `97e5ffeca8` |
|---|---|
| `append` at `keeper_context_core_accessors.ml:176` | file is 172 lines; `append` is at `:104` |
| `save_oas` at `keeper_checkpoint_store.ml:362` | no such function there; entries are `:133`, `:927`, `:978` |
| repair body at `keeper_context_core_accessors.ml:299-502` | **removed** by `f5f45f97c3` (#25046) |
| drop counters `keeper_metrics.ml:266,272` | `tool_pair_repair` has zero references under `lib/` |

New anchors introduced by this amendment, all **(verified 07-28)**:

- Tail-aware parser: `lib/keeper/keeper_compaction_unit.mli:62-65`
  (`partition` type), `:72-81` (`~quarantine`), `:89-91` (the
  persistence-preserves-open-tail contract).
- Validator asymmetry: `lib/keeper/keeper_compaction_unit.ml:262`
  (`validate`), `:264` (`unresolved_tool_use_ids`), `:291-299`
  (`validate_provider_transcript`).
- Sole quarantine-tolerant caller: `lib/keeper/keeper_compact_policy.ml:206`.
- Rejection → error: `lib/keeper/keeper_agent_run.ml:136`, `:143-153`.
- Latch write: `lib/keeper/keeper_heartbeat_loop.ml:774-800`
  (`commit_transcript_corruption`); read: `lib/keeper/keeper_keepalive.ml:141,284`.
- Resume refusal: `lib/keeper/keeper_paused_work_resume_transaction.ml:168-174`.
- Latch SSOT: `lib/keeper_runtime/keeper_latched_reason.mli`.
- Contradictory operator advice:
  `lib/server/server_dashboard_http_keeper_api_lifecycle_post.ml:267,288`.
- Recovery phases: `lib/server/server_bootstrap_loops.ml:490,558`.
- Removal of repair: `f5f45f97c3` (#25046, 2026-07-18). Hard reject:
  `4a1880624b` (#25335, 2026-07-23).
- Producer: `agent_core/lib/pipeline/pipeline.ml:213-220`
  (`persist_turn_checkpoint_for_state … After_assistant_collected` over
  `snoc messages assistant_message`); unfiltered sink `checkpoint_sink`
  in `lib/keeper/keeper_agent_run.ml` (passes `snapshot.stage` to an
  observer only, then saves unconditionally).
- Latch non-monotonicity: `lib/keeper/keeper_shutdown_finalize.ml:309-318`,
  `lib/keeper/keeper_keepalive.ml:125-138` and the resume-only guard at
  `:284`.
- Absent recovery action: `lib/keeper/keeper_meta_contract.ml:671-672`
  (`masc_keeper_reset` zeroes usage only), `:423-427` and `:432`
  (`mark_resumed` no-op for this latch / sole non-create `None` write),
  `lib/keeper/keeper_turn_up_update.ml:118-119` (latch copied forward).
- Live incident: `<base-path>/.masc/logs/system_log_2026-07-27.jsonl`,
  `<base-path>/.masc/keepers/{executor,kinobot-frontend,sangsu,rondo}.json`.
  Ungraceful-kill signature: last `"ts"`-anchored record `14:41:26Z`,
  next `14:42:06Z`, zero in between; `"seq":37496` absent while `37495`
  and `37497` are present.

**Method note.** Substring counts over the log overcount badly —
timestamps recur inside message bodies, so an unanchored
`rg -c '14:41:[2-5][0-9]Z'` reports hundreds of records in a window that
is in fact empty. Anchor on `"ts":"…"` before concluding anything about
log gaps. A first pass of this amendment drew the wrong conclusion from
the unanchored count.

**Hypothesis rejected during investigation.** A transport-error cluster
(`Failure("connection closed by peer")`, 200 events) was proposed as the
precursor and does not survive: those fall in a `12:12`–`12:30Z` window,
hours before the latches, and `kinobot-frontend` recorded none yet is
latched. Causation from transport errors to this incident is
**UNVERIFIED** and is not relied on anywhere above.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
