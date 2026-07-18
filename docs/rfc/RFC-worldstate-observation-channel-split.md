---
rfc: "worldstate-observation-channel-split"
title: "Split keeper world-state into an observation channel (system) and an utterance channel (user)"
status: Draft
created: 2026-07-19
updated: 2026-07-19
author: vincent
supersedes: []
superseded_by: []
related: ["0230", "0233", "0257"]
implementation_prs: []
---

# RFC-worldstate-observation-channel-split

## 0. Summary

Every keeper turn assembles a `## Current World State` block and delivers it as
a **conversation user message** (`keeper_unified_prompt.ml:811`). That message
is sent to the provider each turn. Because it is a user message, each turn's
snapshot lands in `checkpoint.messages` and accumulates for the life of the
session.

A live checkpoint (`trace-1783826424111`, 396 world-state user messages)
measured the composition:

| Section | Occurs | Total bytes | Share |
|---|---|---|---|
| `### Claimable Work` | 396/396 | 149,292 | 48% |
| `### Namespace State` | 396/396 | 60,174 | 19% |
| `### Autonomous Trigger` | 396/396 | 59,578 | 19% |
| `### Board Activity` | 37 | 24,667 | 8% |
| `### Pending Messages` | 15 (mostly (1)–(2)) | ~5,900 | 2% |

The three always-present sections — Claimable Work, Namespace State, Autonomous
Trigger — are **86%** of the world-state bytes and are pure *current-state
observations*: a snapshot of the workspace at turn time, not anything anyone
said. Persisting them as conversation history is duplication: turn N's
namespace snapshot has no value once turn N+1 recomputes it.

The genuinely conversational sections — Pending Messages (owner/keeper
utterances) and Board Activity (posts) — are correctly user-side, and their
accumulation is already bounded: `message_scope_ack_id` advances to the latest
consumed message on every turn success
(`keeper_unified_turn_success.ml:49-54`), so the pending window is (1)–(2)
messages in steady state, not a re-copied backlog.

This RFC splits the world-state assembly into two channels by layer:
observation layers go to turn-scoped system context (re-sent each turn, never
persisted); utterance layers stay in the user message (persisted, ack-bounded).

## 1. Problem (evidence)

### 1.1 The accumulation is observation-as-history, not utterance backlog

An earlier hypothesis (#25193 original) blamed a re-copied "Pending Messages
(50)" window. Re-measurement refuted it: `(50)`/`(51)` occur exactly once each;
the ack watermark works. The real driver is the always-present observation
sections being written to `checkpoint.messages` every turn
(`keeper_run_prompt.ml:115` appends the user message to `ctx_work`; the OAS run
persists the resulting conversation).

### 1.2 Turn execution does not depend on world-state being a user message

Turn admission branches exclusively on the typed `world_observation` record and
event-queue triggers (`keeper_world_observation.ml:1164`,
`keeper_heartbeat_loop_scheduling.ml:30`); it never reads the
`## Current World State` string. Delivering the observation content by a
different channel does not change whether or when a turn fires. The dashboard
preview re-derives world-state from the observation, not from history
(`dashboard_http_keeper_snapshot.ml:137`).

### 1.3 The world-state channel is already excluded from durable surfaces

`history_user_source = "world_state_prompt"` is classified `Drop_line`
(`keeper_context_core_history.ml:57`), so the world-state message is never
written to `history.jsonl`, and it is filtered out of memory recall and the
dashboard conversation view. The only place it accumulates is the **live**
`checkpoint.messages` sent to the provider. So the persisted-history contract
already treats world-state as ephemeral; only the in-context copy contradicts
that.

### 1.4 Why the previous fix (PR #25232) could not work

Stamping the user message with masc-side metadata and filtering prior stamped
copies is a permanent no-op: OAS owns the conversation and rebuilds the user
message from the raw `~goal` string with `metadata = []`
(`oas agent.ml:165-172`), so no masc stamp survives the round-trip. Masc
message metadata does not cross the OAS conversation boundary. The fix must
change **which channel** the content is delivered on, not tag the message.

## 2. Design

### 2.1 Classify each layer as observation or utterance

`keeper_context_layers.ml` already enumerates the layers as an exhaustive
`layer_id` variant. Add a total classifier:

```ocaml
type channel = Observation | Utterance

(* Exhaustive: a new layer must declare its channel at compile time. *)
let channel_of = function
  | Active_goals | Current_task | Connected_surfaces
  | Namespace_state | Autonomous_trigger | Scheduled_automation
  | Claimable_work -> Observation
  | Pending_mentions | Scope_messages | Board_activity -> Utterance
```

Rationale per layer:
- **Observation** (current-state snapshot, no author): active goals, claimed
  task, connected surfaces, namespace counts, the autonomous trigger reason,
  scheduled-automation readiness, claimable work. None of these is something a
  participant said; each is fully recomputed next turn.
- **Utterance** (a participant addressed the keeper): pending mentions, scope
  messages, board posts. These are conversational and their accumulation is
  already ack-bounded.

### 2.2 Assemble two strings instead of one

`build_prompt` already returns `(system_prompt, user_message)`. Extend the
world-state assembly so:
- Observation layers render into an **observation block** appended to the
  turn-scoped `extra_system_context` (the `dynamic_context` channel that flows
  to OAS `AdjustParams.extra_system_context`,
  `keeper_run_tools_hooks.ml:369`). This is re-sent every turn and never
  persisted to `checkpoint.messages`.
- Utterance layers render into the **user message** exactly as today, so the
  keeper still receives owner/board input as a user turn and the ack watermark
  keeps bounding it.

When there are no utterance layers this turn, the user message degrades to a
minimal turn marker (see §2.4) rather than an empty goal.

### 2.3 What `extra_system_context` actually is (verified in OAS)

`extra_system_context` is NOT a system-role message. OAS renders it as a
`User`-role message prefixed with `[system context] ` and **appends** it to the
turn's provider-bound message list — never to the persisted conversation
(`oas agent_turn.ml:30-49 prepare_messages`). The persisted `agent.state.messages`
and the provider-bound `prep.effective_messages` are distinct:
`effective_messages = state.messages @ [extra_system_context msg]`, and only
`effective_messages` reaches the provider (`pipeline_stage_route.ml:62`), while
`state.messages` is what checkpoints persist. So the observation block is
re-sent every turn but never accumulates.

The masc side already round-trips this channel through the OAS `world_state_prompt`
Drop_line contract for `history.jsonl`; this RFC extends the same
"ephemeral, not history" treatment to the live `checkpoint.messages` growth by
choosing the non-persisting channel.

### 2.4 Prefix-cache interaction

OAS deliberately *appends* `extra_system_context` at the tail specifically to
keep the conversation prefix byte-identical across turns for local-LLM KV-cache
reuse (`agent_turn.ml:34-40` comment). Today's design already relies on this for
`dynamic_context`. Moving the large observation block here keeps that stable
prefix intact while shrinking persisted history. Per-turn wire cost is unchanged
(the observation block was already sent every turn as the user message); what
changes is that it stops being written to `checkpoint.messages`.

### 2.5 Turn marker (open question — see §5)

OAS `run`/`run_blocks` require a non-empty goal and always append it to the
conversation (`agent.ml:165`). On a turn whose world-state has no utterance
layer, the goal today is the full observation block; after this change it must
be a short, stable sentinel (e.g. a one-line "proceed with current world
state" marker) so the persisted user message is bounded and near-constant
across such turns. The sentinel must be stable enough that prefix caching is
not defeated and small enough that its accumulation is negligible, OR the
existing `world_state_prompt` `Drop_line` treatment must be verified to also
keep the sentinel out of the live context growth (it does not today — Drop_line
only affects `history.jsonl`, not `checkpoint.messages`).

## 3. Alternatives rejected

- **masc-side metadata stamp + supersede filter** (PR #25232): no-op, §1.4.
- **Compaction tuning**: compaction removes duplication after the fact; it does
  not stop the observation sections from re-accumulating, and it is currently
  429-blocked anyway. Preventing accumulation is upstream of compaction.
- **Truncating the observation block**: loses signal; the block is legitimately
  needed each turn — it just should not be *history*.

## 4. Phases

1. **PR-1**: `channel_of` classifier + `assemble_by_channel` in
   `keeper_context_layers`, with unit tests pinning each layer's channel and
   the exhaustiveness guard. No behavior change yet (both channels still
   concatenated into the user message).
2. **PR-2**: route the observation block to `extra_system_context` in
   `build_prompt` / `keeper_run_tools_hooks`; user message carries utterance
   layers + turn marker. Live checkpoint re-measurement as the acceptance test.
3. **PR-3 (if needed)**: turn-marker persistence bound (§2.4) once PR-2's live
   data shows whether the marker accumulates.

## 5. Open questions

- Turn marker shape and whether it needs its own persistence bound (§2.4).
- Does moving the autonomous-trigger reason to system context change model
  behavior (it currently reads as a user instruction "you were triggered
  because…")? The block already declares itself "context, not instructions",
  so system placement is arguably more honest, but this needs an A/B on a live
  keeper before PR-2 lands.
- Board Activity is classified Utterance here, but a board *summary* (counts)
  is observation while the *posts* are utterance — a future split of that one
  layer may be warranted.
