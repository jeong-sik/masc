---
rfc: "discord-server-binding-and-passive-reading"
title: "Discord server bindings, per-binding trigger stance, and passive reading"
status: Draft
created: 2026-11-28
updated: 2026-11-28
author: jeong-sik
related: []
---

# RFC discord-server-binding-and-passive-reading

- Code coordinates audited against `origin/main` (`6c2f2b384f19c`).
- Governance: `docs/constitution.xml` (`closed_sum_over_string`,
  `strict_parse_no_default`, `legacy_residue`, `gates`, `work_unit`).
- Scope: binding model and ingress routing. Outbound files are a separate
  stack (Discord file upload, `keeper_surface_post` `attachment_ids`).

## 0. Summary

An operator who wants a Keeper in one Discord server must bind every channel
of that server one by one, and bind again for each channel created later.
Every bound channel then follows one global trigger policy, and every
unmentioned message in it wakes the Keeper.

This RFC adds a server binding (a guild id bound to a Keeper), resolved after
channel and thread bindings, and gives each binding its own stance: which
messages start a turn, and what happens to the messages that do not. The new
stance `passive` records an unmentioned message as conversation the Keeper
reads later, without putting it in the Keeper's queue.

Operator decisions (2026-11-28): the default trigger is a mention; whether
unmentioned messages are kept is an option; kept messages are read passively.
Real-time voice channels are out of scope.

## 1. Current state

| Fact | Where |
|---|---|
| A binding row is `{ channel_id; keeper_name }`, one store shared by Discord, Slack, Telegram and iMessage. | `lib/gate/channel_gate_binding_store.mli:4` |
| Resolution: the exact channel binding, else the thread's parent channel binding. No server step. | `lib/gate/channel_gate_discord_state.ml:426` (`resolve_keeper_for_channel_result`) |
| An unbound channel's message is dropped (`Dropped_unbound`), including every message in a server whose channels are not bound. | `lib/server/server_discord_in_process_gateway.ml` (`accept_message_create`, `handle_ambient`) |
| The trigger policy is one value for every channel: runtime param `discord.trigger_policy` > `[discord].trigger_policy` > `mention_or_thread`. | `lib/server/server_discord_in_process_gateway.mli` (`resolved_trigger_policy`), `docs/CONNECTOR-CONFIG-SCHEMA.md` |
| A bound-channel message that fails the policy is recorded (chat line + external-attention row) and enqueued as a `Connector_attention` stimulus, which wakes the Keeper to judge it. | `server_discord_in_process_gateway.ml` (`handle_ambient`), `lib/server/server_connector_attention_delivery.mli` |
| The bot already learns its servers: READY carries `guild_ids`. | `Channel_gate_discord_state.current_guild_ids` |
| Production (`--base-path ~/me`, 2026-11-28): gateway READY, `.masc/connectors/discord/bindings.json` absent, so zero bindings exist. | measured with `test -e` and the server log |

## 2. Design

### 2.1 Binding target

```ocaml
type binding_target =
  | Channel of string   (* channel, thread or DM channel snowflake *)
  | Server of string    (* Discord guild snowflake *)
```

A binding row becomes `{ target; keeper_name; stance }`. Telegram and iMessage
only ever write `Channel`. Slack keeps `Channel` until a Slack workspace
binding is designed; nothing here requires it.

Resolution for a message with `channel_id`, optional thread parent and
optional `guild_id`, first match wins:

1. `Channel channel_id`
2. `Channel parent_channel_id` (thread)
3. `Server guild_id` (absent for a DM, so a DM resolves only by channel)

A channel binding inside a bound server therefore overrides the server's
Keeper and stance for that channel. The resolution records which step
matched (`via_parent` today becomes a closed `matched_by = Exact | Parent |
Server`).

### 2.2 Per-binding stance

```ocaml
type unmentioned =
  | Ignore    (* not recorded; as if unbound *)
  | Passive   (* recorded as conversation; no queue entry, no wake *)
  | Wake      (* recorded and enqueued: today's behaviour *)

type stance =
  { trigger : Discord_gateway_client.trigger_policy option
      (* None: the global discord.trigger_policy decides *)
  ; unmentioned : unmentioned
  }
```

`trigger` decides which messages start a turn, exactly as the global policy
does today (`message_passes_policy`). `unmentioned` decides what happens to a
message that does not start one. "Unmentioned" names the operator's mental
model; precisely it means "did not pass this binding's trigger".

Defaults for a new binding: `trigger = None` (the global policy, currently
`mention_only` in the production `runtime.toml`) and `unmentioned = Passive`.

`Passive` writes the same chat line and external-attention row as `Wake` and
skips only `Server_connector_attention_delivery.deliver`. The attention row
keeps the event as evidence; the absent queue entry means no Keeper owes a
judgement. When the Keeper is next in that conversation (a mention, or its own
cycle), the recorded lines are part of what it reads.

`handle_ambient` today states that no flag may suppress the stimulus. That
sentence is rewritten, not worked around: the stance is the operator's
written decision, stored on the binding and audited, and it is applied when
the event is accepted. It is not a rollout flag, a content filter or a time
window, and it never consumes an entry that was enqueued.

### 2.3 Store and wire (hard cut)

`bindings.json` rows become:

```json
{ "target": { "kind": "server", "id": "123" },
  "keeper_name": "k1",
  "trigger": "mention_only",
  "unmentioned": "passive" }
```

`trigger` is absent when it inherits. The decoder is strict: an unknown
`kind` or `unmentioned` value, or the old `channel_id` row shape, is a decode
error. No reader or converter for the old shape is written (`legacy_residue`):
production has zero bindings (§1), and other installations re-bind.

### 2.4 Surfaces

- HTTP: `/api/v1/gate/connector/bind?name=discord` takes `target_kind`
  (`channel` | `server`), `target_id`, `keeper_name`, optional `trigger` and
  `unmentioned`. `unbind` takes `target_kind` and `target_id`.
- Dashboard Quick Bind and the TUI Connectors bind form: a target-kind choice;
  the server picker lists `current_guild_ids` with names from the directory
  refresh.
- Connector status JSON lists each binding with its target and stance.
- `keeper_surface_post`: a Keeper bound to a server may post to a channel when
  that channel resolves to it through §2.1. The channel's guild comes from the
  directory refresh (`get_guild_channels`), or from `get_channel` when the
  directory does not know it yet.
- Presence (`Discord_presence_bridge`): a Keeper with any Discord binding,
  channel or server, counts as bound.

## 3. Risks

- A server binding with `trigger = all` starts a turn for every message in
  every channel the bot can read. That is the stance's meaning, not a defect;
  the dashboard shows the stance next to the binding.
- `Passive` and `Wake` on a server binding record every message the bot can
  read into the Keeper's chat store, including from people who never
  addressed the bot. `Ignore` is the stance for a server where that is not
  wanted.
- A channel binding inside a bound server silently wins. The status JSON
  shows both rows, and the resolution's `matched_by` is recorded on each
  accepted message (`discord.binding_matched_by` metadata).

## 4. Alternatives

- **Discord-only server store** (`server_bindings.json` next to
  `bindings.json`): leaves the shared row alone, but two stores answer one
  question and the resolver reads both. Rejected for the split authority.
- **Global stance only** (add `[discord].unmentioned`): smaller, but a server
  binding with `Passive` and a support channel with `Wake` could not coexist.
  Rejected; the global `trigger_policy` stays as the inherited default.
- **Bind every channel automatically on GUILD_CREATE/CHANNEL_CREATE**:
  writes many rows the operator never chose and still misses channels created
  while the gateway is down. Rejected.

## 5. Stack

Each layer stays within the constitution's work unit.

1. Store: `binding_target`, `stance`, strict codec, resolver with
   `matched_by`; shared-store callers (Slack, Telegram, iMessage) write
   `Channel`. Tests: decode refuses the old shape; resolution order
   Exact > Parent > Server; DM never matches a server.
2. Ingress: per-binding trigger and `unmentioned` in
   `accept_message_create` / `handle_ambient`. Tests: `Passive` writes the chat
   line and attention row and no queue entry; `Ignore` writes nothing.
3. Surfaces: HTTP bind/unbind, status JSON, dashboard Quick Bind, TUI form.
4. `keeper_surface_post` and presence for server bindings; connector docs.

## 6. Verification

- Unit: the tests in §5.
- Live, after deployment: bind the test server with defaults, then post (a) an
  unmentioned message in an unbound channel of that server, (b) a mention.
  Expected: (a) a chat row and attention row, no `Connector_attention` queue
  entry, no turn; (b) a turn and a reply. Evidence: the connector status JSON,
  the Keeper chat store rows, and the Discord observability counters
  (`record_inbound_dispatch`, `record_ambient`), attached to the PR.
