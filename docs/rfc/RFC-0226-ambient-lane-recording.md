---
rfc: "0226"
title: "Ambient lane recording: record-vs-trigger decouple for connector surfaces"
status: Draft
created: 2026-06-11
updated: 2026-06-11
author: vincent
supersedes: []
superseded_by: null
related: ["0203", "0223"]
implementation_prs: ["20771"]
---

# RFC-0226: Ambient lane recording — record ≠ trigger

Status: Draft · Re-entry of RFC-0223 §5 "Ambient channel recording" · No new stores, no cursors
Drafted by: Claude Fable 5 (design session with owner, 2026-06-11).

> All anchors marked **(verified)** were read against `origin/main`
> (`593775203`, post RFC-0223 P1–P3 merge) on 2026-06-11.

## §1 Problem

A keeper's lane history has holes because **persistence is coupled to
turn-triggering and to replying**, in both trigger-policy modes:

1. **`Mention_only` (primary deployment)** — a bound-channel message
   without a mention is dropped inside the gateway state machine:
   `Message_create` failing `message_passes_policy` goes to `no_op`
   (`lib/gate/discord_gateway_state.ml:523-528`, predicate `:360-366`
   **(verified)**). Nothing downstream sees it; it is never persisted
   anywhere. From the channel participant's side the keeper has "ears
   that only switch on when its name is called" — and from the
   keeper's side, `keeper_surface_read` (RFC-0223 P3) returns a lane
   with gaps between mentioned messages.

2. **`All` / `User_only` (must also be served — owner directive
   2026-06-11)** — every message triggers a turn, but the inbound user
   line is only persisted by `append_direct_chat_pair_if_reply`
   (`lib/keeper/keeper_tool_surface_ops.ml:537-539` **(verified)**),
   which is gated on `direct_reply=true && tool_result_success`. A
   silent turn, a non-reply action, or a failed turn drops the inbound
   message from history. Even maximal triggering does not give
   complete recording. This hole covers **every gate consumer**, not
   just Discord: sidecar connectors enter through
   `POST /api/v1/gate/message` (imessage-bot, cli-connector —
   `sidecars/shared/gate_shared/gate_client_base.py`) and converge on
   the same reply-path persistence.

The root cause is ownership: today the *reply path* owns inbound
persistence, so anything that doesn't end in a reply records nothing.

## §2 Principles

1. **Record ≠ trigger.** Recording happens at gateway delivery time
   for every bound-channel message, regardless of trigger policy.
   Trigger policy decides exactly one thing: whether a turn starts.
   The two decisions share an input, never an outcome.
2. **Ownership split, not dedup.** The inbound delivery boundary
   becomes the sole recorder of connector user lines: the gate
   dispatch entry (`Gate_keeper_backend.dispatch` — post
   validation/dedup, pre turn) records everything that starts a turn,
   and the Discord gateway's ambient arm records what the policy
   filtered out. A message takes exactly one of the two routes, so
   the split is exhaustive and disjoint by construction. The reply
   path stops writing the user+assistant pair and appends the
   assistant line only (`append_assistant_message`, shipped in
   RFC-0223 P4). No idempotency cache, no dedup pass (CLAUDE.md
   workaround bar; owner constraint RFC-0223 §2 principle 6).
3. **Bind = consent.** Only bound channels record. Binding is an
   explicit operator action with an audit trail
   (`channel_gate_discord_state.ml` bind/unbind + `binding_audit`),
   so the privacy boundary is the existing one, made load-bearing.
   Unbind stops recording immediately (binding is re-read per event:
   `keeper_for_channel`, `server_discord_in_process_gateway.ml:62`
   **(verified)**).
4. **Push surface unchanged.** Ambient lines are visible only through
   `keeper_surface_read` (pull) and the dashboard transcript. The
   world prompt still carries presence only (RFC-0223 §2 principle 1
   — the R4 counter-pattern stays intact).
5. **No standing state.** Recording is a fire-and-forget append. No
   unread counts, no per-lane cursors, no rate caps. (Deliberately
   re-stated: a busy channel must not grow a backpressure machine
   here; the read path gets bounded instead — §4 P2.)
6. **The bot's own gateway echoes are not recorded.** `is_self`
   suppression (`discord_gateway_state.ml:355-358` **(verified)**)
   applies to recording too: the keeper's outbound is already
   persisted at send time by `keeper_surface_post` (RFC-0223 P4);
   recording the gateway echo would double-record by another route.

## §3 Design

### 3.1 Typed event split (state machine)

`Discord_gateway_state.step` currently emits `Emit_event ev` for
policy-passing messages and silently drops the rest. The effect type
gains one variant:

```ocaml
type effect =
  | ...
  | Emit_event of dispatched_event       (* triggers a turn, as today *)
  | Emit_ambient of dispatched_event     (* record-only delivery      *)
```

- `Message_create` passing policy → `Emit_event` (unchanged).
- `Message_create` failing policy but passing `is_self` →
  `Emit_ambient` (new; today `no_op`).
- `Reaction_add` failing policy stays dropped — a reaction is a
  trigger signal, not conversation content.
- Closed variant: the compiler enumerates every effect consumer
  (`discord_gateway_client.ml` `run_effect`) — no silent fall-through.

### 3.2 Gateway handler (in-process)

`Server_discord_in_process_gateway.on_event` gains the `Emit_ambient`
arm: resolve the binding (`keeper_for_channel`); if bound, append a
**single user line** with source `"discord"` and the External speaker
(id + display name, RFC-0223 P1 fields), then
`Keeper_chat_broadcast.chat_appended` so the dashboard transcript
updates live. **No dispatch, no turn.** Unbound channels drop, as
today (`server_discord_in_process_gateway.ml:63-66` **(verified)**).

New store function (symmetric to P4's `append_assistant_message`):

```ocaml
val append_user_message :
  base_dir:string -> keeper_name:string -> content:string ->
  ?source:string -> ?speaker:speaker -> unit -> unit
```

### 3.3 Gate dispatch recording + reply-path ownership migration

> Amended during implementation (P1 PR): the original draft assumed
> sidecar connectors enter via the keeper stream route. They do not —
> imessage-bot and cli-connector POST to `/api/v1/gate/message` and
> converge on the same reply-path persistence as Discord. The
> recording site therefore moves up to the convergence point.

`Gate_keeper_backend.dispatch` — the single point every gate inbound
passes through (in-process Discord gateway and the HTTP gate route
alike), after `Channel_gate.handle_inbound` validation/dedup and
before the keeper turn — appends the user line at entry via
`append_user_message`. The line carries the **raw** `content` with
the External speaker fields; the `[External channel context]` wrapper
(`contextualize_message`) remains turn input only, not conversation
history.

`append_direct_chat_pair_if_reply` then changes meaning: for
connector traffic (non-empty `channel`) it appends the assistant
reply only. The agent-initiated path (`channel = ""`, source
`"agent"`) keeps the pair — there is no upstream recorder for it.
This removes the silent-turn hole (§1.2) for **all** gate consumers —
Discord and gate-route sidecars — without any dedup, and without a
per-connector (string-keyed) recorder split.

The keeper stream route (dashboard chat) is NOT migrated: its
`append_turn` already records every request unconditionally
(`server_routes_http_keeper_stream.ml:623/:668`).

### 3.4 Read-cost bound (P2 of this RFC)

`Keeper_chat_store.load` returns a bounded window (last 100
user/assistant, 400 lines absolute) but reads and parses the **whole
file** to build it (`keeper_chat_store.ml:289-319` **(verified)**:
`Fs_compat.load_file` then full-line scan). Ambient recording changes
the write-volume class of busy channels, so the read path must stop
scaling with file size — the same pathology family as the
2026-06-09 telemetry JSONL incident (50–82MB files starving the Eio
domain). Fix: tail-bounded read — read the last N bytes (sized to
comfortably cover `max_total_lines` worst-case lines), drop the first
partial line, parse the remainder through the existing window logic.
Same signature, same semantics for files under the bound; root fix
for the cost curve, not a cap on writes.

## §4 Phases

| Phase | Scope | Ships alone? |
|---|---|---|
| P1 | `Emit_ambient` variant + gateway arm + `append_user_message` + gate dispatch recording + reply-path ownership migration | yes — recording becomes complete for every gate consumer (Discord + gate-route sidecars) in all trigger modes |
| P2 | tail-bounded `load` | yes — independent read-cost fix, valuable even without P1 |

P1 and P2 are independent; either may land first.

## §5 Non-goals

| Out | Why |
|---|---|
| Sidecar-connector ambient (slack/telegram/imessage) | their inbound already records unconditionally via the stream route; true ambient (messages the sidecar never forwards) needs sidecar-side changes — separate work if ever needed |
| Digest / summarization of ambient backlog | non-deterministic; needs a fact-retention harness (RFC-0223 §5, unchanged) |
| Unread counts / lane cursors | standing state; presence stays stateless |
| Operator-context discretion (what the keeper reveals to External speakers) | behavioral/prompt concern, not storage: the timeline is one by design ("one person, many hands, one memory" — owner, 2026-06-11). Attribution (`External`) already reaches the prompt; tuning what the keeper says with it is prompt/policy work |
| Retention/rotation of keeper_chat files | P2 makes read cost independent of file size; deletion policy is an ops decision tracked separately |

## §6 Validation

- State machine: policy-fail `Message_create` yields `Emit_ambient`
  (not `no_op`); policy-pass yields `Emit_event`; self-authored yields
  neither — pure `step` tests alongside the existing dispatch decode
  suite (`test/test_discord_gateway_state.ml`).
- Store: `append_user_message` round-trip (speaker + source on a lone
  user line; `load` returns it; `keeper_surface_read` lane includes
  it).
- Ownership: gate reply path appends assistant-only when connector
  context is present; agent path (`source = "agent"`) still appends
  the pair.
- P2: synthetic large file (> tail bound) — `load` output identical
  to full-scan output for the window, with bounded bytes read.
- Manual: bound channel, `mention_only`, two humans converse without
  mentioning the bot → `keeper_surface_read` shows their lines with
  names; mention the bot → turn triggers and the reply appears in the
  same lane with no duplicated user line.

## §7 Workaround self-check (CLAUDE.md signatures)

- Telemetry-as-fix: no — the fix changes recording ownership, not
  visibility.
- String classifier: no — one closed-variant addition, compiler-led.
- N-of-M: no — the reply-path migration covers the only gate-path
  writer; stream-route writers are intentionally out (different
  semantics, §3.3), not deferred.
- Cap/cooldown/dedup/repair: none introduced; §3.4 bounds the read
  side instead of capping writes; dedup avoided by ownership split.
