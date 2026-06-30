---
rfc: "0301"
title: "Connector deferred reply: busy-path messages must drain through the chat queue, not a poll-only async store"
status: Draft
created: 2026-06-30
updated: 2026-06-30
author: vincent
supersedes: []
superseded_by: null
related: ["0203", "0217", "0223", "0225", "0226", "0232"]
implementation_prs: []
---

# RFC-0301: Connector deferred reply via the chat queue

## 1. Problem

A keeper in autonomous / `Busy` state receives a connector (Discord) message,
emits a "busy, I'll answer later" ACK, finishes its in-flight work — and never
answers the queued connector message. The deferred reply is generated but never
delivered back to the channel.

### 1.1 Observed mechanism (verified, file:line)

The non-busy and busy gate paths diverge in `gate_keeper_backend.ml`:

- **Inbound recording (both paths):** `dispatch_core` records the connector user
  line at the gate boundary — `Keeper_chat_store.append_user_message`
  (`lib/gate_keeper_backend.ml:299`), per RFC-0226 ("the gate inbound boundary is
  the sole recorder of connector user lines").
- **Busy branch:** when `Keeper_turn_admission.in_flight = Some info`
  (`lib/gate_keeper_backend.ml:359`), it returns `` `Async_ack `` and calls
  `Keeper_tool_surface.dispatch ~name:"masc_keeper_msg" ~args`
  (`lib/gate_keeper_backend.ml:367-370`). It builds a busy ACK reply
  (`busy_ack_reply_text`, `:133`) with `message_request = Some request` and the
  original Discord fiber sends the ACK and **returns**.
- `masc_keeper_msg` resolves to `Keeper_msg_async.submit`
  (`lib/keeper/keeper_tool_surface_ops.ml:103`), which forks a background daemon
  fiber. That fiber runs `Turn.handle_keeper_msg`
  (`lib/keeper/keeper_turn.ml:1320`) → `Keeper_turn_admission.run_serialized`,
  which **waits fiber-cooperatively** for the in-flight turn to release, then runs
  a genuine keeper turn (`keeper_turn_admission.mli:56`). So the deferred turn
  **does** execute — the drain is not the break.
- **The break is outbound routing.** The busy turn's success callback,
  `append_direct_chat_pair_if_reply` (`lib/keeper/keeper_tool_surface_ops.ml:583`),
  writes the assistant reply only to `Keeper_chat_store` + `Keeper_chat_broadcast`
  (dashboard SSE; `keeper_chat_broadcast.mli` — "the dashboard uses it to re-merge
  the server transcript live"). It has **no connector outbound**.
  `keeper_msg_async.ml` contains zero references to discord / send_message /
  adapter_loop / chat_queue.

### 1.2 The only Discord-outbound path is never fed

The single code path that forks a Discord delivery adapter
(`Keeper_chat_discord.adapter_loop`, `lib/server/server_bootstrap_loops.ml:1050`)
is `Keeper_chat_consumer`'s `handle_turn`, which drains a **different** store:
`Keeper_chat_queue`. But `Keeper_chat_queue.enqueue`
(`lib/keeper/keeper_chat_queue.ml:275`) has **zero production callers** —
repo-wide it is invoked only by tests (`test/test_keeper_chat_coalescing.ml`,
`test/test_keeper_effective_meta_overlay.ml`). The drain + outbound half of the
pipeline is wired (`Keeper_chat_consumer.start`,
`server_bootstrap_loops.ml:989`); the producer half is not.

Result: busy connector messages flow into `Keeper_msg_async` (poll-only, no
outbound), while the outbound-capable `Keeper_chat_queue` is never populated. Two
disjoint async subsystems.

### 1.3 This completes RFC-0225 §3.1, which was only half-implemented

RFC-0225 §3.1 specifies: "The `fork_daemon`-per-request pattern in
`keeper_msg_async.ml` is replaced by a per-keeper serial consumer fiber draining
the queued chat requests through the same admission point." Rollout Phase 1:
"Admission primitive + chat lane serial consumer (3.1)."

What shipped: the admission primitive (`run_serialized` / `in_flight`),
`Keeper_chat_consumer`, `Keeper_chat_queue` (typed source + outbound adapter).
What did **not** ship: routing the busy connector path off `Keeper_msg_async`
(fork-per-request, poll-only) onto `Keeper_chat_queue`. This RFC finishes that
migration for the connector lane.

### 1.4 History (not a regression)

The user-described behaviour — busy ACK now, automatic answer later — was never
built in any version. The Python sidecar's only deferred mechanism was an
**operator-triggered** emoji-reaction re-submission (`_drain_pending`), dropped on
the in-process gateway migration (the `Reaction_add` "drain pending messages …
dropped" comment, `lib/server/server_discord_in_process_gateway.ml:544`). This is
a missing feature, not a regression.

## 2. Non-goals

- **External-attention wake gate (separate axis).** `Keeper_external_attention`
  records connector urgency (`Mention | Direct_message | Ambient`) but is consumed
  only by `operator_digest.ml:287` (digest/dashboard); the reactive-wake gate keys
  on `Keeper_approval_queue.has_pending_for_keeper`, a different queue. Making the
  connector backlog drive a wake belongs to the RFC-0020 data-channel frame and is
  out of scope here. The user's scenario is a message that already entered the chat
  lane (it was dispatched and got a busy ACK), so this RFC closes it without the
  wake-gate change.
- Not a turn-admission redesign; RFC-0225's `run_serialized` stays as-is.
- Not removing `Keeper_msg_async` wholesale. Keeper→keeper messaging and operator
  `masc_keeper_msg` retain their poll/`masc_keeper_msg_result` semantics. Only the
  **gate connector** busy branch is rerouted.

## 3. Design

### 3.1 Route the busy connector branch into `Keeper_chat_queue`

In `gate_keeper_backend.dispatch_core`, replace the busy-branch
`Keeper_msg_async.submit` call with `Keeper_chat_queue.enqueue` carrying a typed
`message_source`. The already-wired `Keeper_chat_consumer` then drains it once the
slot frees (coalescing same-source batches via `dequeue_batch` / `merge_batch`)
and `handle_turn` forks `Keeper_chat_discord.adapter_loop ~channel_id` to deliver
the reply to the channel. The non-busy branch keeps streaming the immediate reply
unchanged.

### 3.2 Typed source mapping — no string match (key boundary decision)

`gate_keeper_backend` is connector-neutral by design (RFC-0226): `dispatch_core`
sees only a string `lane = channel` (`"discord"`, …), `channel_workspace_id`
(= Discord channel_id snowflake), and `channel_user_id`. But
`Keeper_chat_queue.message_source` is a typed sum
(`Dashboard | Discord {channel_id; user_id} | Slack {channel; user_id}`).

Mapping `lane` → `message_source` by `match lane with "discord" -> …` is a
string classifier — forbidden (CLAUDE.md "노 스트링 매치"; AI anti-pattern #2/#4).

#### Layering constraint (discovered during implementation)

The first instinct — thread a typed `Surface_ref.t` or `message_source` through
the `Channel_gate.dispatch_fn` type — does **not** type-check: `channel_gate` lives
in the `masc_gate` library, which `masc` (where `Surface_ref` / `message_source` /
`gate_keeper_backend` live) **depends on**. Putting a `masc`-level type on a
`masc_gate` function signature is a dependency cycle (`masc_gate → masc`).

**Resolution — `connector_kind` injected at dispatch construction (not per
message):** the connector type (Discord vs Slack vs sidecar) is a property of the
*connector*, not of each message; the per-message varying data (channel_id,
user_id) already arrives as `channel_workspace_id` / `channel_user_id`. So:

- Define a leaf variant in `masc` (next to the routing site):
  `type connector_kind = Discord | Slack | Generic`.
- Add `?connector_kind` to `Gate_keeper_backend.dispatch` /
  `dispatch_with_text_snapshot` (functions in `masc`, **not** the `masc_gate`
  `dispatch_fn` type). The Discord gateway bakes `~connector_kind:Discord` in at
  partial-application time, when it constructs its `dispatch`; the remaining
  signature still matches `streaming_dispatch_fn`, so `masc_gate` is untouched and
  no cycle is introduced. Default `Generic` preserves today's behaviour for every
  caller that does not opt in (HTTP gate-route sidecars, tests).
- `dispatch_core`'s busy branch maps `connector_kind` + channel_id + user_id →
  `message_source` via an **exhaustive** match (a new `connector_kind` variant
  fails to compile until handled). No string match; the typed discrimination
  happens where the type is known (the connector), threaded as a typed value.

The pure decision is `route_busy_connector` (§4.0), exhaustive over
`connector_kind`.

### 3.3 message_source coverage gap (honest constraint)

`message_source` is a closed 3-variant sum. HTTP gate-route sidecars
(imessage-bot, cli-connector) also POST to `/api/v1/gate/message` and converge on
`dispatch_core` (RFC-0226 §3.3 amendment) with a generic `channel` label that is
neither `discord` nor `slack` nor `dashboard`. Two admissible resolutions, to be
decided in review:

- **(a) Scope deferred-queue delivery to connectors with an in-process outbound
  adapter** (Discord, Slack). Sidecars that POST-and-await keep their current
  synchronous/poll semantics; the typed map returns `None` for them and the busy
  branch falls back to today's `Keeper_msg_async` path. Smallest blast radius.
- **(b) Widen `message_source`** with a generic `Gate {label; channel_id;
  user_id}` variant and a matching outbound delivery adapter. Larger, but unifies
  every gate connector under the serial consumer (full RFC-0225 §3.1 intent).

This RFC recommends **(a)** first (surgical, closes the reported Discord bug),
with **(b)** as a follow-up once a generic gate outbound adapter exists.

### 3.4 Recording ownership — source-keyed user-line write

`Keeper_chat_consumer.handle_turn` invokes `process_single_turn`
(`lib/server/server_routes_http_keeper_stream.ml:669`), which records the user
line itself (`persist_user_message_only`, `:736`; `append_turn`, `:755`). That is
correct for **dashboard** stream messages (no gate inbound recorder) but would
**double-record** a connector user line, since the gate inbound already recorded
it (`gate_keeper_backend.ml:299`, RFC-0226's sole-recorder invariant).

**Resolution (typed, exhaustive):** the consumer-driven turn records the user line
only when there is no upstream recorder, keyed on the typed `message_source`:

```ocaml
match queued_message.source with
| Dashboard            -> record user line   (* no gate inbound recorder *)
| Discord _ | Slack _  -> assistant-only     (* gate inbound owns the user line *)
```

This preserves RFC-0226's ownership split (gate inbound = connector user line;
reply path = assistant) under the unified consumer, with no dedup and no
string-keyed branch. A new source variant forces a compile-time decision.

## 4. Verification

### 4.0 The fix must introduce a testable routing seam (harness-first)

Today the busy branch hard-calls `Keeper_tool_surface.dispatch ~name:"masc_keeper_msg"`
inline (`lib/gate_keeper_backend.ml:367-370`), and `test/test_gate_keeper_backend.ml`
exercises only `Gate_keeper_backend`'s pure helpers — there is **no harness that
drives `dispatch_core`'s busy branch end-to-end**, and no injection point for the
routing decision. A deterministic "red now, green after" reproduction therefore
cannot be written against the current code without standing up a full runtime
(proc_mgr / net / a live keeper turn).

The fix extracts the busy-connector routing decision into a pure, injectable
function whose effect is observable — e.g.

```ocaml
type connector_kind = Discord | Slack | Generic

(* pure, exhaustive over connector_kind: decide where a busy connector
   message goes, building the typed message_source from per-message ids *)
val route_busy_connector
  :  connector_kind
  -> channel_id:string
  -> user_id:string
  -> [ `Enqueue_chat_queue of Keeper_chat_queue.message_source
     | `Async_poll (* §3.3 fallback: Generic has no in-process outbound adapter *) ]
```

The enqueue side effect (`Keeper_chat_queue.length` / `dequeue`) is the
deterministic seam the test asserts against. This is the harness-first part of the
fix, not an afterthought: the routing decision becomes a total function over the
typed source, and the test pins it.

### 4.1 Tests

- **Routing decision (pure, deterministic):** `route_busy_connector
  ~source:(Some (Discord {channel_id; user_id}))` → `` `Enqueue_chat_queue (Discord …) ``;
  a source with no chat-queue projection (§3.3) → `` `Async_poll ``. Exhaustive over
  `message_source`.
- **Reproduction test (failing-first), `test/test_keeper_busy_connector_deferred.ml`:**
  hold the turn slot busy (the proven `Keeper_turn_admission.For_testing.reset` +
  forked `run_serialized` blocking on a `release` promise pattern from
  `test_keeper_turn_admission.ml`), dispatch a Discord-source gate message, and
  assert `Keeper_chat_queue.length ~keeper_name ≥ 1` with `source = Discord
  {channel_id; _}`. Pre-fix the busy branch routes into `Keeper_msg_async`, so
  `length = 0` — **red**. Post-fix — **green**.
- **Ownership regression guard:** assert the gate inbound records the user line
  exactly once and the consumer-driven turn records it zero additional times for a
  `Discord` source (no double-record).
- **Drain/coalesce:** reuse the existing `test_keeper_chat_coalescing.ml` harness
  to assert same-source coalescing of multiple busy-arrival connector messages into
  one follow-up turn.
- **TLA+ bug model (CLAUDE.md pattern), optional:** `BugAction` = busy connector
  message routed to a store with no outbound; `Invariant` = every accepted
  connector message eventually has an outbound delivery attempt. Clean spec passes;
  buggy spec violates.

## 5. Rollout

1. Typed `connector_source` threaded through gate dispatch + busy-branch enqueue
   into `Keeper_chat_queue` (§3.1–3.3 option (a)).
2. Source-keyed user-line ownership in the consumer turn (§3.4).
3. Failing reproduction test flips to green; coalescing + ownership guards added.
4. Follow-up (separate RFC/PR): generic gate outbound adapter (§3.3 option (b))
   and the external-attention wake gate (§2, RFC-0020 frame).

## 6. Workaround self-check (CLAUDE.md gate)

- Telemetry-as-fix: no — this routes the message to a store that delivers, it does
  not merely count the drop.
- String/substring classifier: no — §3.2 explicitly replaces a would-be string
  match with a typed `Surface_ref → message_source` exhaustive mapping.
- N-of-M: no — the migration is the producer half of RFC-0225 §3.1, completed for
  the connector lane in one place; §3.3 names the remaining coverage decision
  rather than silently patching one site.
- Cap/cooldown/dedup/repair: none introduced.
