# Channel-Independent Turn Surface Plan

Status: design proposal
Created: 2026-06-11
Scope: MASC keeper turn lifecycle, channel adapters, dashboard Keeper Operations surface
HTML companion: `docs/design/channel-independent-turn-surface-plan.html`
Related: RFC-0150, RFC-0203, RFC-0225, RFC-0230

## Decision

MASC should expose a channel-independent keeper turn presence read model.
Discord, Slack, dashboard chat, board wakeups, and future connectors may start
or observe a turn, but none of them should own the surface state that tells an
operator whether a keeper is busy, asleep, idle, offline, or waiting for human
attention.

For `sangsu`, this means:

- if an autonomous turn is currently running, every operator surface shows
  `Busy` even when Discord is not the active channel;
- if no turn is in flight and the keeper is only waiting for the next
  deterministic cycle, surfaces show `Zzz`;
- if a direct message can run immediately, surfaces show `Idle`;
- if the keeper needs operator action, surfaces show `Attention`;
- if runtime/keepalive is not available, surfaces show `Offline`.

This is not an OAS feature. OAS owns provider/model execution, transport, hooks,
tool-use mechanics, and agent turn internals. MASC owns keeper runtime,
admission, state projection, and operator surfaces.

## Problem

The recent Discord work made a new channel visible, but the desired behavior is
not Discord-specific. The operator question is:

> If `sangsu` is already doing an autonomous turn, what should every surface say?

Today the code has several adjacent signals, but no single surface contract:

- `Keeper_heartbeat_loop_presence.keeper_agent_status` maps paused/current task
  metadata to `Inactive`, `Busy`, or `Active`.
- `Keeper_status_runtime.keeper_surface_status` derives a coarse UI status from
  health plus agent runtime status.
- RFC-0150 defines a typed `attention_signal` for human-action needs.
- RFC-0225 defines the missing per-keeper single-flight admission point, which
  is the correct source for in-flight turn ownership.
- RFC-0203 deliberately keeps Discord as a connector, not as a keeper-facing
  tool or polling loop.

The gap is the read model that binds these together without making Discord,
dashboard chat, or any other channel special.

## Streaming And Typing Reference

Hermes Agent is the closest external reference for this slice, but only at the
surface projection level. Its gateway separates:

- a platform adapter that receives a message and authorizes the user;
- an agent runner that owns the turn;
- a stream consumer that buffers deltas and progressively edits one platform
  message;
- a Discord typing loop that refreshes the typing indicator every 8 seconds
  while work is in progress.

MASC should borrow that projection pattern, not the agent boundary. In MASC:

- `typing` is a connector-local projection of the response-wait phase;
- `streaming out` is a connector-local edit-loop transport for response deltas;
- `turn_presence` is still derived from keeper runtime/admission state;
- OAS remains provider/model/transport and agent-turn mechanics, with no
  MASC-specific surface state.

[근거] Discord official channel API says the typing indicator is
`POST /channels/{channel.id}/typing`, expires after 10 seconds, and returns 204
on success; checked 2026-06-11 Asia/Seoul; confidence High:
<https://docs.discord.com/developers/resources/channel#trigger-typing-indicator>.

[근거] Discord official message API exposes edit-message semantics for
previously sent messages, including editable `content`; checked 2026-06-11
Asia/Seoul; confidence High:
<https://docs.discord.com/developers/resources/message#edit-message>.

[근거] Hermes Agent README and architecture docs describe one gateway process,
multi-platform messaging, a shared agent loop, and platform-agnostic core;
checked 2026-06-11 Asia/Seoul; confidence High:
<https://github.com/NousResearch/hermes-agent>,
<https://hermes-agent.nousresearch.com/docs/developer-guide/architecture>.

[근거] Hermes `GatewayStreamConsumer` buffers synchronous agent deltas, rate
limits them, and progressively edits a target-platform message; its Discord
adapter keeps a typing loop alive at 8-second intervals; checked 2026-06-11
Asia/Seoul; confidence Medium:
<https://raw.githubusercontent.com/NousResearch/hermes-agent/refs/heads/main/gateway/stream_consumer.py>,
<https://raw.githubusercontent.com/NousResearch/hermes-agent/refs/heads/main/gateway/platforms/discord.py>.

## Model

Introduce a typed MASC-owned read model:

```ocaml
type turn_lane =
  | Autonomous
  | Chat
  | Board
  | Mcp
  | Operator

type availability =
  | Busy of in_flight_turn
  | Zzz of sleep_context
  | Idle of idle_context
  | Attention of Keeper_attention_signal.t
  | Offline of offline_context

and in_flight_turn =
  { lane : turn_lane
  ; started_at : string
  ; keeper_turn_id : int option
  ; trace_id : string option
  ; task_id : string option
  ; source : channel_source option
  }

and channel_source =
  { kind : [ `Dashboard | `Discord | `Slack | `Board | `Mcp | `Scheduler ]
  ; conversation_key : string option
  }
```

The invariant is simple: `availability` is derived from keeper runtime state,
not from the channel that last produced an event.

## State Derivation

Evaluation order:

| Priority | Input | Availability | Reason |
|---|---|---|---|
| 1 | keeper runtime missing, keepalive stopped, health offline | `Offline` | no live execution surface |
| 2 | RFC-0150 attention signal present | `Attention` | operator action is blocking progress |
| 3 | RFC-0225 admission slot has an owner | `Busy` | a turn is in flight |
| 4 | keepalive healthy, no turn, deterministic cooldown or no salience | `Zzz` | autonomous lane is asleep/waiting |
| 5 | keepalive healthy and direct turn can start now | `Idle` | direct work can be admitted |

`Busy` wins over channel origin. A Discord message arriving while an autonomous
turn is in flight should not make the surface look Discord-active; it should
show `Busy` with the current lane set to `Autonomous` and the incoming message
queued or marked waiting according to the admission policy.

`Attention` is not a synonym for `Busy`. `Attention` means the next useful
operator action is human-side inspection or intervention. `Busy` means MASC is
already executing a turn.

`Zzz` is not offline. It means the keeper is alive, has no in-flight turn, and
is waiting for the next scheduled/reactive trigger.

## Wire Shape

Add `turn_presence` to keeper composite/status responses:

```json
{
  "keeper": "sangsu",
  "turn_presence": {
    "availability": "busy",
    "label": "Busy",
    "reason": "turn_in_flight",
    "source_independent": true,
    "in_flight": {
      "lane": "autonomous",
      "started_at": "2026-06-11T21:10:33+09:00",
      "keeper_turn_id": 370,
      "trace_id": "trace-1780648779957-00000",
      "task_id": null,
      "source": { "kind": "scheduler", "conversation_key": null }
    },
    "sleep": null,
    "attention": null,
    "updated_at": "2026-06-11T21:10:34+09:00"
  }
}
```

For a sleeping keeper:

```json
{
  "turn_presence": {
    "availability": "zzz",
    "label": "Zzz",
    "reason": "autonomous_cooldown",
    "source_independent": true,
    "in_flight": null,
    "sleep": {
      "next_autonomous_after": "2026-06-11T21:22:00+09:00",
      "direct_message_admissible": true
    },
    "attention": null,
    "updated_at": "2026-06-11T21:15:00+09:00"
  }
}
```

## API And Surface Placement

Primary read path:

- `GET /api/v1/keepers/:name/composite`
  - add `turn_presence`;
  - used by selected Keeper Operations detail.

Fleet summary path:

- `GET /api/v1/dashboard/shell` or the current Keeper Operations list model
  - include compact `turn_presence` fields for each keeper:
    `availability`, `label`, `reason`, `lane`, `started_at`.

Live update path:

- existing dashboard SSE should emit `keeper_presence_changed` when the
  availability kind changes or an in-flight owner starts/releases.

No connector gets a dedicated presence endpoint. Discord status remains
connector health; keeper turn presence remains keeper runtime health.

## Implementation Plan

### P0: Type and fixture

- Add `Keeper_turn_presence.{ml,mli}` with the closed sums above.
- Add JSON encoder and fixture tests for `busy`, `zzz`, `idle`, `attention`,
  and `offline`.
- Keep it read-only; no dashboard behavior change.

Verification:

- focused Dune target for the new test binary;
- `ocamlformat --check` on touched OCaml files.

### P1: Producer from admission and runtime state

- Use RFC-0225 admission owner as the authoritative `Busy` source.
- On admission, publish lane/start metadata into the registry read model.
- On token release, clear the owner via `Switch.on_release`.
- Derive `Zzz` from keepalive healthy + no in-flight owner + cooldown/no
  salience.
- Derive `Offline` from existing health/keepalive conditions.
- Derive `Attention` from RFC-0150 signal when present and no turn is already
  in flight.

Verification:

- long autonomous fake turn yields `Busy(Autonomous)`;
- direct chat while autonomous is running does not overwrite lane;
- release moves away from `Busy`;
- offline keeper never reports `Zzz`.

### P2: Dashboard Keeper Operations projection

- Render compact badges in the keeper list:
  - `Busy` with lane and elapsed time;
  - `Zzz` with next deterministic cycle when known;
  - `Idle`;
  - `Attention`;
  - `Offline`.
- Selected keeper detail shows the same read model near the message/control
  surface, not buried in diagnostics.
- Avoid channel-specific badge text. The source may be shown as metadata, but
  it must not drive the primary availability label.

Verification:

- component tests for badge mapping;
- Playwright screenshot for Keeper Operations list and selected keeper detail;
- dashboard typecheck/lint.

### P3: Connector-neutral behavior tests

- Disable Discord token and prove autonomous `Busy` still appears.
- Simulate dashboard chat and prove it queues/waits while autonomous `Busy`
  remains visible.
- Simulate a connector-origin message and prove the surface still reports the
  current in-flight lane rather than the connector name.

### P4: Streaming-out transport

- Extend the gate response path from single final `send_message` to a stream
  projection contract.
- Start with a Discord implementation:
  - create an initial reply/placeholder message when the first visible delta
    arrives;
  - coalesce deltas by time and size;
  - edit the same message with accumulated text;
  - finalize with a final edit that removes any cursor/progress marker;
  - fall back to one final message when edits fail or rate limits require it.
- Keep this transport below `turn_presence`. Progressive edits do not decide
  whether the keeper is `Busy`, `Zzz`, or `Idle`.

Verification:

- fake streamed keeper response yields multiple edit operations and one final
  visible response;
- rate-limit/error path falls back to a final send without dropping text;
- direct non-streaming response keeps the existing send path;
- no OAS public schema changes are required unless the OAS stream callback
  contract itself changes.

Verification:

- integration test around composite JSON;
- no references to Discord in the availability derivation module except
  through generic `channel_source`.

## Boundary Rules

- OAS does not learn about `Busy`, `Zzz`, dashboard labels, or Discord.
- Channel adapters produce typed inbound events and optional source metadata;
  they do not decide keeper availability.
- The dashboard reads MASC read models; it does not infer availability by
  combining raw Discord status with keeper health.
- `attention_signal` stays human-action oriented. It is an input to
  `turn_presence`, not a replacement for it.
- RFC-0225 admission is the long-term source of truth for `Busy`.

## Open Questions

1. Should `Attention` outrank `Busy` when a turn is in flight and also emits a
   human-action signal? The proposal says no: an active turn remains `Busy`,
   and the attention signal is nested metadata.
2. Should `Zzz` require a known next autonomous timestamp? The proposal says no:
   lack of a timestamp should still render as `Zzz` when keepalive is healthy
   and no turn is in flight.
3. Should queued direct messages have their own `Waiting` label? Defer until
   RFC-0225 queue behavior lands; the first surface can show `Busy` plus
   `queued_direct_messages`.

## Done Criteria

- `sangsu` autonomous long turn shows `Busy` in Keeper Operations with Discord
  disabled.
- After the turn releases and no reactive salience exists, the same surface
  shows `Zzz` or `Idle` according to direct-message admissibility.
- Discord connector health can be down while keeper presence remains truthful.
- No OAS public schema or provider/model code changes are required.
