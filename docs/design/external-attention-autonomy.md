# External Attention Autonomy Design

Date: 2026-06-11
Status: Draft implementation design
Scope: MASC keeper autonomy, connector-neutral attention, operator surface
Out of scope: OAS provider/model/transport internals

## 1. Goal

Make an external message affect a keeper's autonomous turn behavior through one
transport-neutral contract.

Discord is only one adapter. If the same event arrives from Slack, GitHub,
webhook, dashboard inbox, or another gate connector, the keeper scheduler and
operator surface must behave the same:

```text
transport adapter
  -> external_attention event
  -> per-keeper durable pending attention
  -> keeper availability surface
  -> world observation / reactive turn decision
  -> keeper turn
  -> claim / resolution
```

The feature must not move Discord-specific policy into OAS. OAS remains the
provider/model/turn execution substrate. MASC owns transport semantics,
autonomy, keeper scheduling, and operator-facing state.

## 2. Current Evidence

[근거] `git -C ~/me/workspace/yousleepwhen/masc rev-parse --short HEAD` ->
`d5359788f`, checked `2026-06-11T20:31:38+0900`, trust High.

[근거] `curl -fsS 'http://127.0.0.1:8935/health?full=1' | jq ...`, checked
`2026-06-11T20:31:38+0900`, trust High:

- runtime process repo root: `/Users/dancer/me/workspace/yousleepwhen/masc`
- effective base path: `/Users/dancer/me`
- effective MASC root: `/Users/dancer/me/.masc`
- build commit: `d5359788f`
- fleet safety: degraded because paused/blocked keeper capacity is below target

[근거] `curl -fsS 'http://127.0.0.1:8935/api/v1/keepers/sangsu/composite' | jq ...`,
checked `2026-06-11T20:31:38+0900`, trust High:

- `keeper=sangsu`
- `phase=running`
- `runtime_attention.state=ok`
- `runtime_attention.needs_attention=false`
- `runtime_attention.live_turn_started_at=null`

Current code anchors:

| Area | Current behavior | Source |
|---|---|---|
| Discord triggered path | `Message_create` maps a bound channel to a keeper and calls `Channel_gate.handle_inbound`; successful output is sent back to Discord. | `lib/server/server_discord_in_process_gateway.ml:58-96` |
| Discord ambient path | Messages that fail trigger policy are recorded as chat user lines, but no turn is dispatched. | `lib/server/server_discord_in_process_gateway.ml:118-147` |
| Gate dispatch | `Gate_keeper_backend.dispatch` records a connector user line, contextualizes external channel metadata, then calls `Keeper_tool_surface.dispatch_stream` with `masc_keeper_msg`. | `lib/gate_keeper_backend.ml:73-90`, `lib/gate_keeper_backend.ml:126-171` |
| Chat persistence | Connector/dashboard chat rows persist under `<base_dir>/.masc/keeper_chat/<keeper>.jsonl`, with `source` and `speaker_authority`. | `lib/keeper/keeper_chat_store.mli:1-14`, `lib/keeper/keeper_chat_store.ml:19-23` |
| Message salience | Current `collect_message_scope` loads keeper chat history and reports user lines mentioning the keeper after the keeper's last assistant line. Scope messages are still reserved for a later phase. | `lib/keeper/keeper_world_observation_message_scope.ml:104-143` |
| World observation | `observe` includes pending mentions, pending board events, pending scope messages, task counts, and connected surfaces. | `lib/keeper/keeper_world_observation.ml:421-470` |
| Reactive turn decision | `keeper_cycle_decision` runs a Reactive turn for pending mentions, board events, or scope messages before falling back to scheduled autonomous cadence. | `lib/keeper/keeper_world_observation.ml:624-662` |
| Prompt context | The unified prompt renders connected surfaces, pending mentions, pending scope messages, and board events. | `lib/keeper/keeper_unified_prompt.ml:620-655`, `lib/keeper/keeper_unified_prompt.ml:737-776` |
| Single-flight | Chat waits/queues, autonomous skips when the same keeper already has an in-flight turn. | `lib/keeper/keeper_turn_admission.mli:1-19`, `lib/keeper/keeper_turn_admission.mli:39-61` |
| Chat queue coalescing | While a turn is in flight, queued chat messages stay queued and coalesce into one later turn. | `lib/keeper/keeper_chat_consumer.ml:9-40` |
| Runtime attention surface | Composite attention currently reports blocked/stale/idle runtime attention, but not transport-neutral pending external attention. | `lib/server/server_dashboard_http_composite_claims.ml:422-526` |

Important drift note: `docs/rfc/RFC-0230-keeper-mention-scope-reactivity.md`
is adjacent, but its early statement that `collect_message_scope` is a stub is
stale for `d5359788f`. The current producer already implements mention
watermarking from `Keeper_chat_store`. This design builds on the current code,
not the stale RFC claim.

## 3. Problem

The system has two different concepts that currently look similar in the UI:

1. A transport message can already reach a keeper as a chat/direct turn.
2. A keeper's autonomous turn selection only reacts to the signals that are
   represented in world observation.

When Sangsu is in Discord, the connector can be alive and bound, but autonomous
turns only care if the message has been promoted into a keeper salience signal.
The current mention-watermark path helps, but it is coupled to chat history and
does not expose a first-class pending external attention object.

Missing pieces:

- no durable, source-neutral `external_attention` lifecycle;
- no shared adapter contract for Discord/Slack/GitHub/webhook/dashboard inbox;
- no typed `surface_ref` / `conversation_ref` that lets Discord channels,
  Discord threads, Slack threads, and dashboard sessions keep distinct lanes;
- no explicit boundary saying platform adapters own "what becomes pending",
  while the shared store owns only lifecycle;
- no operator surface that says "Sangsu is Busy, 3 external items are pending";
- no explicit `Ready | Busy | Zzz | Offline | Blocked` availability projection
  derived from keeper scheduler state plus pending attention;
- no acceptance test proving source substitution preserves behavior.

## 4. Design Principles

1. Transport-neutral after the adapter boundary.
   Discord, Slack, GitHub, webhook, dashboard inbox, and future gate connectors
   all emit the same MASC event shape.

2. Durable before dispatch.
   An inbound attention item is recorded before any model turn is attempted. A
   failed turn, busy slot, restart, or silent provider failure cannot drop it.

3. Single-flight is respected.
   If the keeper is already running a turn, the new attention item becomes
   pending and the surface says `Busy`; it must not start a second same-keeper
   turn.

4. Prompt salience is explicit.
   World observation includes a bounded list of pending external attention. The
   prompt gets a dedicated section, not a hidden side effect of chat history.

5. OAS remains generic.
   OAS does not learn about Discord, Slack, Sangsu, gate bindings, keeper
   availability, or pending attention. OAS sees ordinary turn context.

6. Surface state is scheduler state.
   `Busy`, `Zzz`, `Ready`, `Offline`, and `Blocked` describe whether a keeper can
   process an item now; they are not transport status labels.

7. Pending semantics are adapter-policy-owned.
   Discord, Slack, GitHub, dashboard, and webhooks each decide which inbound
   event becomes `Mention`, `Direct_message`, `Ambient`, or `System`. The shared
   store never contains Discord-specific "is this pending?" logic; it receives
   already-classified attention and manages only durable lifecycle.

## 5. Data Contract

Add a MASC-owned module:

```ocaml
module Keeper_external_attention : sig
  type surface_ref =
    | Dashboard of { session_id : string option }
    | Discord of
        { guild_id : string option
        ; channel_id : string
          (** Discord channel id. For thread messages this is the thread
              channel id; plain channel messages use the parent channel id. *)
        ; parent_channel_id : string option
        ; thread_id : string option
        }
    | Slack of
        { team_id : string option
        ; channel_id : string
        ; thread_ts : string option
        }
    | Github of { repo : string; notification_id : string option }
    | Webhook of { source : string; event_id : string }
    | Gate of { label : string; address : (string * string) list }

  type conversation_ref =
    { conversation_id : string
    ; surface : surface_ref
    }

  type external_message_ref =
    { surface : surface_ref
    ; message_id : string
    ; reply_to_message_id : string option
    }

  type urgency =
    | Mention
    | Direct_message
    | Ambient
    | System

  type actor =
    { actor_id : string option
    ; display_name : string option
    ; authority : Keeper_chat_store.speaker_authority
    }

  type item =
    { event_id : string
    ; dedupe_key : string
    ; keeper_name : string
    ; conversation : conversation_ref
    ; external_message : external_message_ref option
    ; source_label : string
    ; actor : actor
    ; urgency : urgency
    ; content_preview : string
    ; content_ref : string option
    ; received_at : float
    ; metadata : (string * string) list
    }

  type event =
    | Recorded of item
    | Claimed_for_turn of
        { event_id : string
        ; claim_id : string
        ; turn_id : int option
        ; claimed_at : float
        }
    | Resolved of { event_id : string; resolved_at : float; reason : string }
    | Ignored of { event_id : string; ignored_at : float; reason : string }

  type record_result =
    [ `Recorded
    | `Duplicate of item
    | `Error of string
    ]

  val record :
    base_path:string ->
    item ->
    record_result

  val pending_for_keeper :
    base_path:string ->
    keeper_name:string ->
    ?now:float ->
    ?claim_stale_after:float ->
    limit:int ->
    unit ->
    item list

  val claim_for_turn :
    base_path:string ->
    keeper_name:string ->
    event_ids:string list ->
    claim_id:string ->
    turn_id:int option ->
    ?now:float ->
    unit ->
    (unit, string) result

  val mark_resolved :
    base_path:string ->
    keeper_name:string ->
    event_ids:string list ->
    reason:string ->
    ?now:float ->
    unit ->
    (unit, string) result

  val mark_ignored :
    base_path:string ->
    keeper_name:string ->
    event_ids:string list ->
    reason:string ->
    ?now:float ->
    unit ->
    (unit, string) result
end
```

Suggested persistence:

```text
<base_path>/.masc/external_attention/<keeper>.jsonl
```

Each line is one append-only `event`. The current `Pending` set is a projection:
latest event per `event_id`, excluding terminal `Resolved` / `Ignored` events
and recovering stale claims by policy. `event_id = sha256(dedupe_key)`;
`dedupe_key` is transport-derived and identifies one inbound external event:

```text
discord:<channel_id>:<message_id>
slack:<team_id>:<channel_id>:<event_ts>
github:<repo>:<notification_id>
dashboard:<session_id>:<message_id>
webhook:<source>:<event_id>
```

`dedupe_key` is not the conversation lane key. Lane identity lives in
`conversation_ref.conversation_id`:

```text
discord:<guild-or-unknown>:<channel_id>
slack:<team-or-unknown>:<channel_id>:<thread_ts-or-channel>
dashboard:<keeper>:<session-or-default>
github:<repo>:<notification-or-thread>
```

The store is event-sourced so retries are idempotent and lifecycle changes are
auditable. No in-memory mutable registry is part of correctness. A later
compaction can write `<keeper>.snapshot.json`, but P1 should start with
append-only JSONL.

Content policy:

- Persist `content_preview` after keeper secret redaction.
- Persist full conversation content in `Keeper_chat_store` when the source is a
  chat lane; `content_ref` can later point to a chat row once chat rows have a
  stable row id.
- Never trust actor authority from message text. Authority comes from route:
  dashboard owner route -> `Owner`; connector routes -> `External`.

## 6. Adapter Contract

Every adapter owns its pending policy, then calls one helper before dispatching
or queueing:

```ocaml
type wake_policy =
  | Wake
  | Do_not_wake

type adapter_attention_policy =
  { classify : inbound_event -> Keeper_external_attention.urgency option
  ; conversation_ref :
      inbound_event -> Keeper_external_attention.conversation_ref
  ; external_message_ref :
      inbound_event -> Keeper_external_attention.external_message_ref option
  ; dedupe_key : inbound_event -> string
  ; wake_policy : Keeper_external_attention.urgency -> wake_policy
  }

val record_external_attention :
  base_path:string ->
  keeper_name:string ->
  conversation:Keeper_external_attention.conversation_ref ->
  ?external_message:Keeper_external_attention.external_message_ref ->
  actor:Keeper_external_attention.actor ->
  urgency:Keeper_external_attention.urgency ->
  content_preview:string ->
  dedupe_key:string ->
  metadata:(string * string) list ->
  Keeper_external_attention.item
```

Mapping rules:

| Adapter | Conversation lane | Urgency | Wake default |
|---|---|---|---|
| Discord mention/DM | `discord:<guild>:<channel_id>`; thread messages use the thread channel id | `Mention` or `Direct_message` | wake |
| Discord ambient bound lane | same Discord lane | `Ambient` | do not wake |
| Slack app mention/IM | team + channel + thread ts when present | `Mention` or `Direct_message` | wake |
| Dashboard inbox/chat | keeper + session/default | `Direct_message` | direct queue/turn |
| GitHub mention/review request | repo + notification/thread | `Mention` or `System` | policy/batch |
| Generic gate/webhook | adapter supplied | adapter supplied | adapter supplied |

The adapter may still write the existing `Keeper_chat_store` user line. The new
attention store is not a replacement for chat history; it is the turn-trigger
and operator-visible lifecycle.

Boundary rule:

```text
Pending semantics are adapter-policy-owned.
Lifecycle semantics are MASC-store-owned.
```

## 7. Scheduler Semantics

Add `pending_external_attention` to `Keeper_world_observation.world_observation`:

```ocaml
type external_attention_summary =
  { event_id : string
  ; source_label : string
  ; urgency : string
  ; actor_label : string
  ; received_at : float
  ; preview : string
  }

type world_observation =
  { ...
  ; pending_external_attention : external_attention_summary list
  }
```

Then wire it into existing decision points:

- `durable_signal_present`: true when pending trigger attention is non-empty.
- `actionable_signal_present`: true when pending trigger attention is non-empty.
- `proactive_work_signal_present`: true for `Mention` and `Direct_message`;
  optional for `Ambient`.
- `turn_reason`: add `External_attention_pending`.
- `keeper_cycle_decision`: any pending trigger attention makes the channel
  `Reactive`, like current pending mentions/board/scope messages.
- `Keeper_unified_prompt`: add `### External Attention` after `Connected
  Surfaces` and before `Namespace State`.

Prompt section example:

```text
### External Attention (2 pending)
- [discord mention] Alex in #ops at 20:29: "@sangsu can you check ..."
- [github mention] review request in yousleepwhen/masc#20871: "Need owner..."
```

When building the turn, append `Claimed_for_turn` for selected event ids with a
fresh `claim_id`. When the turn successfully persists an assistant reply, append
`Resolved`. If the keeper deliberately stays silent, append `Ignored` with the
silence reason. If a process dies after claim and before terminal resolution,
stale-claim recovery projects the item back to pending instead of dropping it.

## 8. Availability Surface

Add a keeper availability projection independent from transport:

```ocaml
module Keeper_availability : sig
  type state =
    | Ready
    | Busy
    | Zzz
    | Offline
    | Blocked
    | Degraded

  type t =
    { state : state
    ; reason : string option
    ; current_turn : Yojson.Safe.t option
    ; pending_attention_count : int
    ; top_pending_attention : Yojson.Safe.t option
    ; next_action : string
    }
end
```

Derivation:

| State | Condition | Display meaning |
|---|---|---|
| `Busy` | `Keeper_turn_admission.in_flight` is `Some _` or composite `live_turn` is present | Keeper is already doing a turn. New attention remains pending. |
| `Ready` | no in-flight turn, lifecycle can execute, pending attention count > 0 | A turn can be promoted now. |
| `Zzz` | no in-flight turn, lifecycle can execute, pending count = 0, keeper is in sleep/cooldown/poll wait | Nothing urgent is pending; wakeup can change this. |
| `Offline` | registry/fiber not running or phase cannot execute because keeper is offline | Wakeup alone may not work; recover/start first. |
| `Blocked` | runtime blocker, approval gate, paused state, provider exhaustion, or continue gate prevents execution | Human/actionable intervention required. |
| `Degraded` | stale/uncertain/runtime attention says not fully healthy but not hard-blocked | Probe or inspect before relying on automation. |

Composite JSON extension:

```json
{
  "availability": {
    "state": "busy",
    "reason": "turn_in_flight",
    "current_turn": {
      "lane": "autonomous",
      "started_at": 1781180100.0,
      "last_progress_at": 1781180163.0
    },
    "pending_attention_count": 3,
    "top_pending_attention": {
      "source_label": "discord",
      "urgency": "mention",
      "actor_label": "Alex",
      "preview": "@sangsu ..."
    },
    "next_action": "will_process_after_current_turn"
  }
}
```

Dashboard copy:

- `Busy`: "Sangsu is busy with an autonomous turn. 3 external items pending."
- `Ready`: "Sangsu can process 1 pending external item now."
- `Zzz`: "Sangsu is sleeping; no pending external attention."
- `Offline`: "Sangsu is offline; recover before wakeup."
- `Blocked`: "Sangsu is blocked; inspect runtime/approval state."

## 9. Flow Examples

### 9.1 Busy Keeper, Discord Mention

```text
Sangsu autonomous turn is in flight.
Discord mention arrives.
Adapter records external_attention Pending.
Availability becomes Busy + pending_attention_count=1.
No second same-keeper turn starts.
Current turn finishes.
Next heartbeat/chat consumer observes pending attention.
Reactive turn starts with External Attention section.
Item is Claimed_for_turn, then Resolved after reply.
```

### 9.2 Zzz Keeper, Slack Mention

```text
Sangsu has no in-flight turn and no pending attention -> Zzz.
Slack app_mention arrives.
Adapter records the same lifecycle shape with a Slack surface_ref.
Availability becomes Ready.
Wakeup flag is set for high urgency.
Reactive turn starts.
Prompt and lifecycle behavior match Discord case.
```

### 9.3 Ambient Channel Message

```text
Bound Discord channel receives ordinary ambient chat.
Adapter records chat history as today.
If urgency=Ambient, attention item may be retained for context but does not
force immediate turn unless policy says the keeper observes ambient traffic.
Availability may show pending ambient count separately, but `Ready` is reserved
for items allowed to trigger a turn.
```

## 10. Implementation Slices

### P1. Store and Type Contract

Files:

- add `lib/keeper/keeper_external_attention.ml`
- add `lib/keeper/keeper_external_attention.mli`
- add tests in `test/test_keeper_external_attention.ml`
- add Dune entries

Behavior:

- source-neutral event type;
- typed `surface_ref`, `conversation_ref`, and `external_message_ref`;
- JSON encode/decode;
- append-only durable record under `<base>/.masc/external_attention`;
- idempotent `record` by `event_id`;
- pending read with bounded limit and stale-claim projection.

Validation:

```bash
cd ~/me/workspace/yousleepwhen/masc
scripts/dune-local.sh build test/test_keeper_external_attention.exe
./_build/default/test/test_keeper_external_attention.exe
```

### P2. Gate Adapter Recording

Files:

- `lib/gate_keeper_backend.ml`
- `lib/server/server_discord_in_process_gateway.ml`
- later: Slack/dashboard/GitHub adapters as they enter the same gate shape

Behavior:

- record attention before keeper dispatch;
- keep current chat-store write;
- use the existing gate idempotency key as the dedupe key;
- do not put Discord-specific code outside the adapter/boundary layer.

Validation:

- duplicate Discord `message_id` records one attention item;
- Discord and Slack fixtures produce identical pending item semantics except
  adapter-owned `surface_ref/source_label`;
- trigger-policy ambient messages are recorded as `Ambient` and do not force a
  turn by default.

### P3. Observation and Prompt

Files:

- `lib/keeper/keeper_world_observation.ml`
- `lib/keeper/keeper_world_observation.mli`
- `lib/keeper/keeper_unified_prompt.ml`
- related metric/result helpers for reactive reason labeling

Behavior:

- `pending_external_attention` joins existing pending mentions/board/scope;
- `External_attention_pending` becomes a typed reactive run reason;
- prompt renders the bounded list;
- selected items are claimed with `Claimed_for_turn`.

Validation:

- pending attention makes `keeper_cycle_decision.should_run=true`;
- source substitution does not change decision;
- prompt contains `### External Attention` with source labels and previews.

### P4. Availability Surface

Files:

- add `lib/keeper/keeper_availability.ml`
- add `lib/keeper/keeper_availability.mli`
- `lib/server/server_dashboard_http_composite_claims.ml`
- `lib/server/server_dashboard_http_composite_enrich.ml`
- `dashboard/src/types/core.ts`
- `dashboard/src/keeper-store-normalize.ts`
- relevant dashboard component for keeper cards/detail

Behavior:

- expose `availability` JSON in keeper composite;
- derive `Busy` from turn admission/live turn;
- derive `Ready` from executable keeper + pending trigger attention;
- derive `Zzz` from executable keeper + no pending trigger attention;
- keep `Blocked/Offline/Degraded` tied to lifecycle/runtime state.

Validation:

- busy turn + new attention -> `availability.state=busy`;
- no turn + pending trigger attention -> `ready`;
- no turn + no pending attention -> `zzz`;
- blocked runtime with pending attention -> `blocked`, not `ready`.

### P5. Wakeup Wiring and Resolution

Files:

- `lib/keeper/keeper_keepalive.ml`
- `lib/keeper/keeper_heartbeat_loop.ml`
- `lib/keeper/keeper_unified_turn*.ml`
- possibly `Keeper_chat_consumer` if queued chat should drain pending attention
  explicitly

Behavior:

- high-urgency pending attention sets `fiber_wakeup`;
- busy keepers do not start a concurrent turn;
- successful reply resolves claimed attention items;
- stay-silent or decline marks included items as `Ignored` with reason.

Validation:

- regression for "no dropped addressed attention";
- regression for "no second same-keeper turn while busy";
- restart test: pending attention survives server restart.

## 11. Test Matrix

| Test | Setup | Expected |
|---|---|---|
| Source substitution | one Discord mention and one Slack mention with same keeper/content | both become pending trigger attention with identical scheduler behavior |
| Busy queue | autonomous turn holds slot, external mention arrives | no second turn; `Busy`; pending count increments |
| Zzz wake | no in-flight turn, keeper healthy, mention arrives | `Ready`; high urgency sets wakeup |
| Blocked preserves pending | keeper paused/runtime blocked, mention arrives | pending count increments; `Blocked`; no turn until unblocked |
| Resolution clears | pending item claimed in successful turn | lifecycle projects to `Resolved`; no repeat reactive turn |
| Stay silent explicit | pending item claimed and model chooses no reply | lifecycle projects to `Ignored` with reason; no infinite reactivity |
| Stale claim recovers | claim is recorded, process dies before terminal event | item projects back to pending after claim timeout |
| Restart durability | record pending item, restart server, observe | item is still pending |
| Ambient policy | ambient bound-lane message arrives | stored as `Ambient`; does not force turn unless policy enables ambient trigger |

## 12. TLA / Invariants

Model the attention lifecycle separately from transport:

```text
Pending -> ClaimedForTurn -> Resolved
Pending -> ClaimedForTurn -> Ignored
ClaimedForTurn -> Pending  (stale claim recovery)
Pending -> Ignored
```

Invariants:

- `NoDroppedAddressedAttention`: a `Mention` or `Direct_message` cannot disappear
  without `Resolved` or `Ignored`.
- `AtMostOneTurnPerKeeper`: pending attention never bypasses turn single-flight.
- `SourceNeutralAttention`: changing adapter/surface without changing urgency,
  target keeper, or content does not change scheduler decision.
- `BusySurfacesPending`: if a keeper is in-flight and pending trigger attention
  exists, availability is `Busy`, not `Zzz`.
- `BlockedDoesNotResolve`: blocked/paused/offline state cannot mark attention
  resolved.

Bug actions to include:

- `DropPendingOnBusy`
- `DiscordBypassesAttention`
- `SecondTurnStartsWhileBusy`
- `BlockedMarksResolved`
- `AmbientForcesTurnWithoutPolicy`
- `ClaimedDiesAndDropsAttention`

## 13. Dashboard Placement

Keeper list/card:

- compact badge: `Ready`, `Busy`, `Zzz`, `Blocked`, `Offline`, `Degraded`
- pending count next to the badge
- source icon/label for top pending item

Keeper detail:

- new "Attention" tab or panel near runtime/turn controls;
- pending list with source, actor, age, urgency, preview;
- current turn row when Busy;
- explicit next action text.

Do not bury this under connector settings. The operator asks "why is Sangsu not
looking at Discord?" while staring at Sangsu, so the answer belongs on the
keeper surface.

## 14. Open Decisions

1. Should `Ambient` ever wake a keeper automatically?
   - Conservative default: no. It is visible context, not trigger attention.

2. Should pending external attention reuse `Keeper_chat_store` as the only
   storage?
   - No for P1. Chat history is recall; attention is scheduler state. Keep a
   separate small lifecycle store, optionally cross-reference chat later.

3. Should direct gate dispatch still synchronously wait for a reply?
   - For operator/dashboard direct chat, yes. For connector events while Busy,
   prefer record + pending surface over blocking the adapter fiber behind a
   long autonomous turn.

4. Should `pending_mentions` stay?
   - Yes initially. P3 can bridge `pending_external_attention` into the same
   reactive consumer graph. Later, mention-watermark can become a producer of
   `external_attention` instead of a separate prompt section.

5. Should external reaction/receipt events be part of P1?
   - No. Discord emoji/read receipts are intentionally excluded from this slice.
   First ship durable pending attention, availability, and reactive resolution.

## 15. Definition of Done

- The same test fixture can swap Discord `surface_ref` for Slack `surface_ref`
  and keep the same scheduler/availability result.
- Discord channel and Discord thread messages get distinct conversation ids
  without special scheduler behavior.
- If Sangsu is already in an autonomous turn, a new external mention makes the
  keeper surface show `Busy` with pending count and top pending item.
- If Sangsu is sleeping and a mention arrives, availability becomes `Ready` and
  the keeper wakes through the existing wakeup path.
- Pending attention survives restart and is not cleared by failed dispatch.
- OAS has no Discord/Slack/GitHub-specific code changes.
- Dashboard exposes the state near the keeper, not only in connector settings.
