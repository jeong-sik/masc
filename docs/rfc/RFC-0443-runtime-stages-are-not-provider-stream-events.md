---
rfc: "0443"
title: "Runtime lifecycle is not a provider stream event — a turn before its first token must say where it is"
status: Draft
created: 2026-09-12
updated: 2026-09-12
author: claude
related: ["0441", "0345", "0012", "0341"]
---

# RFC-0443 — Runtime lifecycle is not a provider stream event (#35344)

- Status: Draft
- Author: claude
- Related: masc#35344 (symptom), masc#35342 (the discarded failure reason, merged separately), RFC-0441 (turn liveness yields to the waiting person), RFC-0345 (stream idle fail-safe), RFC-0012 (mid-turn progress probe), RFC-0341 (lifecycle projection SSOT — the typed-value-not-string-assembly principle this RFC extends)
- Boundary vs RFC-0441: RFC-0441 owns a turn that **is** working — it grinds tools while a person waits, and the waiting client misreads its own silent feed as death. This RFC owns the window **before** a turn produces anything at all, where there are no tools to show and the silence is genuine. Same reader, disjoint windows: RFC-0441 makes existing activity visible, this RFC makes the absence of activity legible.
- Boundary vs RFC-0012 / RFC-0345: those decide **when a stalled turn is declared dead** (watchdog thresholds, idle fail-safe floors). This RFC decides **what the operator reads while it is still alive**. Neither ends a turn; this one never does.

## 0. Summary

A keeper turn spent 184 seconds producing no observable event, then failed. For that entire window the chat progress row read:

```
IN PROGRESS · connecting to [claude_code.claude-sonnet-5] · 1m29s
```

It was not connecting. It was somewhere between "the process is starting" and "the request is with the provider", and it was on its way to failing. Those states are not distinguishable today, and the row's word for all of them is the one word that is wrong for most of them.

The row has two inputs (`calls = 0`, `endpoint_streaming = false`) and the second is a `bool` flipped only by the arrival of provider output. Every runtime state before the model's first token collapses into `false`.

This RFC proposes: **emit the runtime's own lifecycle as a typed stage on the channel that already carries `Runtime_attempt_started`, and replace `endpoint_streaming : bool` in the transcript with that stage type so a new stage cannot be silently absorbed into `false`.**

## 1. What already exists (do not re-implement)

Three things look like this problem and are not. A reviewer must know them before reading the proposal, and an implementer must not rebuild them.

- **The queue is already rendered.** `masc_tui_render.ml:10375` (`pending_behind`) distinguishes "behind this Keeper's turn still out" from "behind another queued line" and from an ordinary wait. In the measured incident the queue was empty — the operator's line took the turn immediately. An empty queue area means an empty queue, not a missing feature.
- **The server→client custom channel already carries lifecycle events.** `Server_keeper_chat_agui_projection.custom_event_name` is a closed sum type holding both provider-protocol events (`Stream_message_start`, `Content_block_start`) and runtime/keeper-level ones (`Connected`, `Runtime_attempt_started`, `Tool_approval_requested`). `Runtime_attempt_started` is already exactly the kind of value this RFC adds. **No new transport, no new channel.**
- **The callbacks already fire at the right moments.** `runtime_claude_code.ml` calls `on_spawned`, `on_session_ready`, `on_turn_starting`, `on_prompt_sent` at precisely the boundaries an operator wants named. Nothing needs to be newly detected.

What is missing is one hop: those callbacks reach `Session_store` and the transmitted-input audit record, and nothing else.

## 2. Measurement

From `<base-path>/.masc/logs/system_log_2026-09-12.jsonl`, keeper `msx-retro-mania`, KST:

| time | event |
|---|---|
| 17:05:01 | chat input takes the turn (`holder_lane=chat_operation`) |
| 17:05:02 | `mode=start prompt_bytes=246323 system_prompt_bytes=45689 tools=136 tool_surface_bytes=102854` |
| 17:05:02–17:08:06 | **184 s, zero events for this keeper** |
| 17:08:06 | `Claude Code turn failed (kind=turn_failed)` |
| 17:08:06 | failover to `glm-coding.glm-5.3-flash` (`resume checkpoint_turn_count=5661`) |
| 17:08:23 | first response (`thinking_chars=1730`, `latency_ms=14636`) |

The operator's screenshot at 17:06:30 shows `connecting … 1m29s`, inside that window.

Note the shape: the row named a runtime that never answered. A reader watching it had no way to learn that the named runtime was failing and a different one would answer.

## 3. Why this is structural, not a missing wire

The runtime's only channel to the view is `stream_event` (`runtime_claude_code.mli:156`):

```ocaml
type stream_event =
  | Turn_started of { turn_id : string; model : string }
  | Text_delta of string
  | Dynamic_tool_started of { ... }
  | Dynamic_tool_finished of { call_id : string }
  | Native_tool_started of Runtime_native_tools.observation
  | Native_tool_finished of Runtime_native_tools.observation
  | Turn_finished of { text : string }
```

This is a provider streaming protocol, and it maps to one: `keeper_claude_code_runtime.ml:169` turns `Turn_started` into `Agent_core.Types.MessageStart`. There is no constructor for "the process started" because a provider protocol has no such notion.

Consequently `Turn_started` — the first value the view can possibly receive — is emitted from the `"assistant"` branch (`runtime_claude_code.ml:1121`), guarded by `if not !stream_started`. It fires when the model has produced a token. Everything before it is, by construction, silent.

On the receiving side (`masc_tui_keeper_chat_transcript.ml`):

```ocaml
mutable endpoint_streaming : bool     (* :209, initialised false at :248 *)

(* :1139 *)
if calls = 0 then
  match t.current_runtime_id, t.endpoint_streaming with
  | Some rid, true  -> "streaming from [%s]"
  | Some rid, false -> "connecting to [%s]"
```

`endpoint_streaming` is set true by exactly four deltas (`:1461-1473`): `Stream_model_started`, `Text`, `Thinking`, `Tool_started`. A `bool` cannot hold a third state, so the type itself guarantees that every pre-output condition renders identically — and that any stage added later is absorbed into `false` without a compiler complaint.

This is the shape RFC-0341 rejected for keeper lifecycle: the backend should emit one typed value and the view should render it, rather than the view assembling a label from flags. The chat progress row is the same mistake one layer down.

**All three official-client runtimes share it.** `keeper_codex_runtime.ml:951` and `keeper_antigravity_runtime.ml:888` route `on_prompt_sent` to the same `report_transmitted_input`. The fix must be shared or it will be written three times and drift.

## 4. Proposal

### 4.1 One shared stage type

A new module, since all three official-client runtimes need it and none owns the others:

```ocaml
(* lib/runtime/runtime_turn_stage.mli *)

type t =
  | Spawning
      (** The runtime process is starting. Nothing has been transferred. *)
  | Session_ready
      (** The client answered initialisation and a session id exists. *)
  | Request_sent
      (** The full request has been written to the client. What happens
          next belongs to the provider, not to us. *)
  | Provider_streaming
      (** The first provider output arrived. *)

val to_string : t -> string
```

Four values, ordered, no `Unknown`. A runtime that cannot distinguish two of them reports the earlier one rather than inventing a fifth.

### 4.2 The runtime reports stages

Add one optional callback beside the existing ones:

```ocaml
?on_stage:(Runtime_turn_stage.t -> unit) ->
```

It is called at the four sites that already exist. `on_spawned`, `on_session_ready`, `on_turn_starting`, `on_prompt_sent` keep their present duties (session store, audit); this RFC does not move or merge them, because their consumers are durable state and this one is a projection.

`Provider_streaming` is emitted from the same guarded point that emits `Turn_started` (`:1121`), so the two cannot disagree.

### 4.3 The keeper forwards it as a custom event, not through agent-core

The stage must **not** enter `Agent_core.Types`. That type is a provider protocol; adding lifecycle to it is the boundary violation this RFC exists to avoid.

Instead, add to the existing closed sum:

```ocaml
(* server_keeper_chat_agui_projection.ml *)
| Runtime_stage        (* -> "KEEPER_RUNTIME_STAGE" *)
```

adjacent to `Runtime_attempt_started`, which travels the same path for the same reason.

### 4.4 The transcript holds a stage, not a flag

```ocaml
(* masc_tui_keeper_chat_live.mli *)
| Runtime_stage of { stage : Runtime_turn_stage.t }

(* masc_tui_keeper_chat_transcript.ml *)
- mutable endpoint_streaming : bool
+ mutable stage : Runtime_turn_stage.t
```

`Runtime_attempt_started` resets it to `Spawning` where it currently sets `endpoint_streaming <- false`. The four deltas that currently set the flag true instead advance the stage to `Provider_streaming` — advance, never regress, so an out-of-order delta cannot walk the row backwards.

The progress row then reads the stage:

| stage | row |
|---|---|
| `Spawning` | `starting [rid]` |
| `Session_ready` | `sending the request to [rid]` |
| `Request_sent` | `waiting for [rid]` |
| `Provider_streaming` | `streaming from [rid]` |

The 184-second window would have read `waiting for [claude_code.claude-sonnet-5] · 3m4s` — which is the true statement, and the one that tells an operator the request left the building and the provider owns the delay.

The `match` is exhaustive over a four-value sum, so adding a stage later fails to compile until the row is taught to render it. That is the point of the type change; without it the rest is decoration.

## 5. Non-goals

- **No inference from elapsed time.** A row must never guess a stage from a clock. A guess printed in the position of an observation is worse than the current single word, because it is believable.
- **No new failure detection, thresholds, timeouts, or transitions.** Stages are a projection. Nothing in this RFC ends, retries, or fails a turn; RFC-0012, RFC-0345 and RFC-0441 own those.
- **No stage persistence.** This is not durable truth and must not acquire a store. If the view reconnects mid-turn it re-derives from the stream like every other live value.
- **No queue work.** §1.
- **No `Unknown` stage and no `_ ->` catch-all** in any match over `Runtime_turn_stage.t`.

## 6. Verification

1. **Per-stage delivery** — a fixture CLI that pauses at each boundary; assert the row's text at each, driving the transcript through the real delta path rather than setting the field.
2. **Exhaustiveness** — no `_ ->` arm over the stage type anywhere; a grep-level CI assertion, since the compiler cannot forbid a catch-all someone chooses to write.
3. **Monotonicity** — feed deltas out of order; assert the stage never regresses.
4. **Three runtimes** — the same fixture shape against claude_code, codex and antigravity, so the shared type does not acquire a per-runtime dialect.
5. **Failure interleaving** — the measured case: reach `Request_sent`, fail, fail over to a second runtime; assert the row stops naming the dead runtime at `Runtime_attempt_started`.

## 7. Blast radius

Read-only addition at every layer except one: `endpoint_streaming` becomes `stage`. That field is private to the transcript module; the compiler finds every use. The four delta handlers that set it are the only writers.

Three runtimes must call `on_stage` or their rows stay at `Spawning` — a visible wrong state rather than a silent one, which is the preferred failure for a projection. A CI check that each official-client runtime passes `on_stage` closes it.

`KEEPER_RUNTIME_STAGE` is additive on the wire. Older clients ignore unknown custom events.

## 8. Open questions

1. **Does `Request_sent` want the request size?** `prompt_bytes=246323` is in the log and a 246KB request is worth knowing about while waiting. Against: it is one more thing the row must fit, and the size is constant for the window — it explains a slow transfer, not a slow wait. Proposed: leave it out of `t`, revisit if transfer time proves to be where the seconds go.
2. **Is `Spawning` reachable often enough to name?** If process start is reliably sub-second, three stages may carry the same information with less surface. Answerable only after §6.1 measures real distributions — do not prune before the data.
3. **Does the keeper board deserve the same stage?** It reads "running" for the whole window too. Out of scope here; the projection is defined once and a second consumer costs nothing.
