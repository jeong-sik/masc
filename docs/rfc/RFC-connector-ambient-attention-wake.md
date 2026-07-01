---
rfc: "connector-ambient-attention-wake"
title: "Connector ambient attention wake: drive an idle keeper turn from external-attention backlog"
status: Draft
created: 2026-06-30
updated: 2026-07-01
author: vincent
supersedes: []
superseded_by: null
related: ["0020", "0203", "0223", "0226", "connector-deferred-reply-via-chat-queue"]
implementation_prs: [22818, 22825]
---

# RFC: Connector ambient attention wake

## 1. Problem

`RFC-connector-deferred-reply-via-chat-queue` closed the **dispatched** half: a
connector message that passes the trigger policy (e.g. an @mention) runs a keeper
turn (or, when busy, is queued and answered after the slot frees). This RFC closes
the **ambient** half, the §2 non-goal that RFC deferred to "a separate RFC, the
RFC-0020 frame".

An **ambient** connector message — one the trigger policy filters out (default
`Mention_or_thread`, `lib/server/server_discord_in_process_gateway.ml:30`) — takes the
`handle_ambient` path (`lib/server/server_discord_in_process_gateway.ml:572`): it appends a
chat line and records `Keeper_external_attention` (urgency `Ambient` /
`Direct_message`), then stops. It never enqueues a stimulus and never flips a
wakeup. So an **idle keeper never notices it.**

The backlog is a dead-end to the wake decision:

- `Keeper_external_attention.pending_for_keeper` is consumed by exactly one
  caller, `lib/operator/operator_digest.ml:287` (the operator digest). It never reaches
  `lib/keeper/keeper_world_observation.ml` or `keeper_cycle_decision`.
- `lib/keeper/keeper_world_observation.ml` already drives reactive wakes from
  `pending_mentions → Mention_pending`, `pending_board_events → Board_event_pending`,
  `pending_scope_messages → Scope_message_pending`, and Event-Layer stimuli
  (`lib/keeper/keeper_world_observation.ml:1067-1078`) — but **none of these read
  external_attention.** `lib/keeper/keeper_supervisor.ml` has zero references to it.

This is exactly the RFC-0020 §1 failure: an external stimulus has a durable store
but **no data channel into the policy layer**, so the only recovery is the next
periodic tick — which for an idle keeper at its slow cadence is "never, in
practice".

User-visible symptom (the original report): "Discord에서 들어오는 메시지는 중간에
쌓이긴 하지만 … busy면 …" — and when idle/ambient, the keeper does not pick them up
at all.

## 2. Non-goals

- Not changing the trigger policy. Ambient stays ambient; this RFC adds a
  *throttled, resolvable* wake for it, not promotion to a mention.
- Not the dispatched path (already shipped).
- Not a general "respond to all chatter" mode — §3.5 spurious-wake gating is a
  hard requirement, not an afterthought.
- Not a dedicated outbound lane or fleet-wide rate cap for ambient-wake replies.
  §3.5 enqueues onto the same `Keeper_chat_queue` the dispatched (mention) path
  already uses; this RFC does not add lane separation or a mention-starvation
  backpressure mechanism for the shared queue. §3.6's debounce bounds how often
  an *individual* keeper wakes on ambient traffic, but does not bound how the
  resulting replies interleave with mention-driven replies once both are
  enqueued. If ambient-wake volume turns out to meaningfully delay mention
  replies in practice, that is a follow-up RFC (lane separation and/or a
  priority field on `Keeper_chat_queue` entries), not something this RFC's
  design covers.

## 3. Design

The wake must satisfy the **actionability invariant**
(`lib/keeper/keeper_world_observation.ml:919-930`, `RFC-keeper-proactive-wake-actionability-invariant`):
a signal may drive a proactive turn only if the keeper holds a tool affordance
that can *clear* it. A pending connector message qualifies — the keeper can reply
on the connector surface, and the reply resolves it — **provided** an outbound
reply path and a resolution step exist. Therefore the wake, the content, the
outbound, and the resolution are **one coupled unit**: shipping the wake without
the rest would re-create the `failed_task` anti-pattern (a wake that produces no
clearing action → infinite spin), which the invariant explicitly forbids.

### 3.1 Trigger: edge stimulus carrying the event_id (not the content)

The wake decision is **edge-triggered**, not level-polled. On `handle_ambient`,
after `record_external_attention`:

1. Enqueue a lightweight Event-Layer stimulus
   `Connector_attention { keeper_name; event_id; urgency; surface }` into
   `Keeper_event_queue` (`lib/keeper_runtime/keeper_event_queue.ml`). The stimulus
   carries the **event_id pointer**, never the content — the content stays in the
   single durable store (`external_attention`), so there is no payload
   duplication / split-brain (the objection to a content-bearing queue variant).
2. Flip the wakeup hint (`Keeper_registry.wakeup` / `wakeup_keeper`,
   `lib/keeper/keeper_keepalive.mli:29`) so propagation is sub-second, not next-tick
   (RFC-0020 §1 latency).

The heartbeat stimulus intake maps the new payload to a new event_queue trigger,
and `turn_reason_of_event_queue_trigger`
(`lib/keeper_contract/keeper_world_observation_turn_types.ml:83`) maps that to a **new closed-sum
turn_reason** `Connector_attention_pending`. Because
`event_queue_reactive_triggers` already fold into `reactive_triggers`
(`lib/keeper/keeper_world_observation.ml:1067-1078`), `keeper_cycle_decision` needs **zero
structural change** — the stimulus yields `Run { channel = Reactive }` via the
existing `match reactive_triggers | first :: rest -> Run` arm (1100-1109), the
same path Bootstrap / No_progress_recovery stimuli already take.

Why edge, not level (`observe` polling `pending_for_keeper`): a level read is
non-empty until the item is terminally resolved, so any missed resolution →
`Run = true` every heartbeat forever (token burn). The edge stimulus is dequeued
exactly once and re-armed only by a *new* ambient message — **resolution-safe by
construction for the wake.** (`external_attention` resolution, §3.4, remains for
the digest/backlog read, not for gating the wake.)

### 3.2 Actionability affordance (type-safe admission)

Gate the trigger through `Keeper_agent_tool_surface.affordance_can_mutate`
exactly like `claimable ↔ Task_claim` / `failed ↔ Task_audit`
(`lib/keeper/keeper_world_observation.ml:932-944`). Introduce a "can reply on a connector
surface" affordance so `Connector_attention_pending` is admitted **only** when the
keeper actually holds the outbound tool. A keeper bound to no connector, or with
the reply tool removed, must not wake on it (it cannot clear it). This makes the
invariant a compile-time `match`, not a comment.

### 3.3 Content: the woken turn must see the message

A wake with no rendered content is the "contentless wake" failure — the keeper
runs a turn knowing only "something pending" and cannot reply. The turn prompt
must render the pending attention: read `pending_for_keeper` (capped, §3.6) and
render each item's `content_preview` + `surface` (which channel) into a prompt
layer, analogous to how board events surface `board_post_get`. The keeper learns
*what* to respond to and *where*.

### 3.4 Resolution lifecycle (landed pieces and contract)

At RFC creation, `mark_resolved` was wired only into the Discord gateway's
synchronous reply path (`lib/server/server_discord_in_process_gateway.ml:310`).
The first implementation slices have since landed:

- #22818 added the dormant `Connector_attention` stimulus, `Connector_attention_pending`
  turn reason, intake mapping, and turn-start `claim_for_turn`
  (`lib/keeper/keeper_heartbeat_stimulus_intake.ml:79`,
  `lib/keeper/keeper_heartbeat_stimulus_intake.ml:146-183`).
- #22825 added the gated `handle_ambient` producer, wakeup hint, prompt content
  delivery, heartbeat-loop `mark_ignored` terminalization for completed ambient
  turns, and debounce gating
  (`lib/server/server_discord_in_process_gateway.ml:617-643`,
  `lib/keeper/keeper_heartbeat_loop.ml:140-170`).

The lifecycle contract for every implementation slice remains:

- **Turn start**: `claim_for_turn` the surfaced event_ids, so concurrent cycles
  and the digest stop re-projecting them as pending for `claim_stale_after`
  (`default_claim_stale_after_s`, currently 900s).
- **Turn end**: `mark_resolved` (the keeper replied) or `mark_ignored` (the keeper
  woke, read, and decided no reply — `mark_ignored` is the existing primitive for
  exactly this, `lib/keeper/keeper_external_attention.mli:162`).
- A **claimed-but-never-resolved** item re-surfaces after the stale-claim window
  and can re-wake forever, so turn execution MUST terminalize via a finally-style
  guard (`Fun.protect`, `Eio.Switch.on_release`, or the supervisor turn-end hook).
  Prose intent is not sufficient; cancellation/exception paths must reach
  `Resolved`/`Ignored` or explicitly requeue/release.

This is shared with the dispatched path's resolution model and must not race the
gateway fiber writing to the same per-keeper JSONL (`project_pending` is already
order-robust: `Terminal` is sticky, §3 of the lifecycle).

### 3.5 Outbound: the reply reaches the channel

The woken turn composes a reply; it must reach the connector surface. Reuse the
just-merged delivery substrate: the reply enqueues onto `Keeper_chat_queue` with
the `surface`'s `Discord { channel_id; user_id }` (or routes through the
connector reply tool), so `Keeper_chat_consumer` → `Keeper_chat_discord.adapter_loop`
delivers it — the symmetric outbound to the dispatched fix, no new transport.

### 3.6 Spurious-wake gating (hard requirement)

Ambient messages are precisely the ones the trigger policy filtered out. Waking a
full LLM turn on every line in a chatty bound channel is the opposite of intent
and burns tokens. Gate by urgency + debounce, reusing the board precedent
(`board_reactive_debounce_sec = 60`, `board_reactive_wakeup_max`,
`lib/keeper/keeper_keepalive_signal.ml:299`):

- `Mention` / `Direct_message` urgency: wake promptly (these are addressed to the
  keeper).
- `Ambient` urgency: debounced + capped — batch ambient lines and wake at most
  once per window, or require N accumulated before waking. Tunable; conservative
  default biases toward *not* waking.

### 3.7 Per-cycle cost bound

`pending_for_keeper` does a full JSONL scan (`load_events`, from offset 0). The
content read (§3.3) runs on the turn path (rare), not every observe — keep it off
the per-heartbeat cheap-gate path. The edge trigger (§3.1) means `observe` does
**not** poll the store every cycle; only a woken turn reads it.

## 4. Route adjudication

| Criterion | Route A: content-bearing event_queue variant | Route B: poll `pending_for_keeper` level | **Chosen: edge event_id + durable store** |
|---|---|---|---|
| Wake re-arm | edge (safe) | level (re-wake-forever hazard) | edge (safe) |
| Durable payload | duplicated in stimulus (split-brain) | single store | single store (stimulus = event_id pointer) |
| `keeper_cycle_decision` change | none | adds a reactive arm | none |
| Resolution needed for *wake* | no | yes (mandatory) | no (wake is edge); resolution only for digest/backlog |

The chosen hybrid takes the edge-safety of A and the single-store discipline of B.
Resolution (§3.4) is still built — not to gate the wake, but to keep the backlog
and operator digest honest and to support the content read.

## 5. Risks

- **Infinite re-wake** — mitigated by edge trigger (§3.1) + terminal resolution
  (§3.4). The turn MUST reach `Resolved`/`Ignored`.
- **Spurious wake** — §3.6 gating is mandatory, not optional.
- **Contentless / non-actionable wake** — §3.2 affordance + §3.3 content + §3.5
  outbound are coupled to the wake; do not ship the wake alone.
- **Double-processing with the dispatched fix** — a message that is both queued
  (dispatched) and recorded (ambient) must not drive two turns. Resolution keys on
  `dedupe_key` / `event_id`; the chat-queue path already sets
  `connector_user_line_recorded_upstream = true` (`lib/server/server_bootstrap_loops.ml:1088`)
  to avoid re-recording.
- **Approval_pending shadowing** — the `Approval_pending` hard gate returns
  `blocked` before `reactive_triggers` are matched (`lib/keeper/keeper_world_observation.ml:1096-1099`).
  This is not merely held for later: `Keeper_heartbeat_stimulus_intake.consume_turn_entry_stimuli`
  unconditionally calls `Keeper_registry_event_queue.dequeue` before `keeper_cycle_decision`
  ever runs (`lib/keeper/keeper_heartbeat_stimulus_intake.ml:224-232`), and nothing
  re-enqueues on a `blocked` verdict (`requeue_missing_front`, the one function that
  could, has zero callers). A `Connector_attention` stimulus dequeued into a cycle
  that then blocks on `Approval_pending` is **lost**, not re-delivered — the wake
  only recovers if a genuinely new ambient message arrives later. This is the same
  gap the Problem section names ("the only recovery is the next periodic tick... for
  an idle keeper... 'never, in practice'"); this RFC does not close it for the
  Approval_pending case. Needs either a real re-enqueue-on-block path or an explicit
  decision that this loss is acceptable for a HITL-gated keeper specifically.
- **RFC-0020 path drift** — RFC-0020 §4 cites `lib/keeper/keeper_event_queue.*`
  but the module is at `lib/keeper_runtime/keeper_event_queue.*`. Use the real path.

## 6. Phasing

The actionability invariant couples wake+content+outbound+resolution into one
minimum shippable unit. Phasing is therefore by *internal* slice, each behind the
prior, landing together before the feature is enabled. Current main has already
landed P1/P2 turn-start plumbing in #22818 and P3/P4 gated producer/throttle work
in #22825; future work should not recreate those modules and should focus on
remaining policy/readiness gaps.

| Phase | Scope | Independently mergeable? |
|---|---|---|
| P1 | `Connector_attention` stimulus + `Connector_attention_pending` turn_reason + intake mapping + affordance gate (§3.1–3.2). | landed in #22818; no producer on its own |
| P2 | Resolution lifecycle: `claim_for_turn` at turn-start and terminal `mark_resolved`/`mark_ignored` at turn-end (§3.4). | turn-start landed in #22818; turn-end ignore path landed in #22825 |
| P3 | `handle_ambient` enqueues the stimulus + flips wakeup; prompt content layer; outbound via `Keeper_chat_queue` (§3.1, §3.3, §3.5). | landed behind feature flag in #22825 |
| P4 | Spurious-wake gating (urgency throttle + debounce, §3.6), then enable. | gating landed in #22825; enabling remains an operator rollout decision |

A reproduction/integration test per phase (deterministic, the busy-slot +
`Keeper_chat_queue.length` harness from `test_keeper_busy_connector_deferred` and
the consumer-drain harness extend naturally): assert (P1) a `Connector_attention`
stimulus yields `Run { Connector_attention_pending }`; (P2) a resolved item stops
re-surfacing; (P3) an ambient message wakes an idle keeper and the reply enqueues
to the right channel; (P4) chatty ambient lines wake at most once per window.

## 7. Workaround self-check (CLAUDE.md gate)

- Telemetry-as-fix: no — drives a real turn + delivery, not a counter.
- String/substring classifier: no — `Connector_attention_pending` is a closed-sum
  turn_reason; urgency is the existing typed `urgency` variant.
- N-of-M: no — the resolution lifecycle is added once for the heartbeat path, not
  per-call-site.
- Cap/cooldown/dedup/repair: §3.6 uses a debounce **cap** — but as the *root*
  backpressure for ambient chatter (mirroring the accepted board precedent), with
  the alternative (wake on every line) being the actual anti-pattern. Documented,
  not a symptom-suppressor.
