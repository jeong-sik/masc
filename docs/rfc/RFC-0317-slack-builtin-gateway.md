---
title: In-process Slack connector (Socket Mode)
rfc: "0317"
status: In progress (PR-1/PR-2 landed; PR-3 implemented; PR-4 sidecar removal pending)
created: 2026-07-07
updated: 2026-07-08
author: vincent
related: ["0203", "0287"]
---

# RFC-0317 — In-process Slack connector (Socket Mode)

OCaml Socket Mode client replaces `sidecars/slack-bot/` (Python slack-bolt).
One tool out, push in. The mirror of [[RFC-0203]] for Slack.

> **Status.** This RFC lands in four PRs. PR-1 (landed) shipped the inbound
> client: `Slack_gateway_state` (pure FSM) + `Slack_socket_client` (I/O driver)
> + a `Log.Slack` logger + unit tests. PR-2 (landed) wired REST outbound
> (`slack_rest_client`) + the in-process `Channel_gate_slack_state` rewrite +
> connector registration + `Keeper_chat_queue.Slack` deferred delivery. PR-3
> (this batch) wires `Server_slack_in_process_gateway` + bootstrap + env
> (`SLACK_APP_TOKEN`, `MASC_SLACK_TRIGGER_POLICY`) + `slack_observability`,
> and adds the `connector_kind:Slack` arm together with that gateway (per the
> "add it together with the gateway, not before" note in `gate_keeper_backend`).
> PR-4 (pending) deletes the sidecar. Ambient recording + idle-keeper wake on
> non-triggering messages and reaction-as-trigger are follow-up scope, not PR-3.

## Why

- `sidecars/slack-bot/` is a Python slack-bolt process with its own
  lifecycle, its own HTTP push path (`/api/v1/gate/message` with
  `connector_kind = Generic`), and its own failure modes. The server
  already in-processes Discord (`lib/gate/discord_*`); Slack is the last
  connector that lives in a separate process. Removing it collapses two
  failure surfaces into one.
- `lib/gate_keeper_backend.mli` documents the gap directly: *"Slack is
  intentionally absent — there is no wired Slack inbound gateway."*
- The OCaml build already has everything Socket Mode needs: `ws-direct-eio`
  + `tls-eio` (the Discord transport, reused verbatim), `masc_http_client`
  (for `apps.connections.open` and `chat.postMessage`), `yojson`, `eio`.
  **Zero new opam deps.**

## Shape

```
Slack WSS ↔ slack_socket_client (OCaml, Eio fiber, reuses discord_wss_connection)
                ↓ parse envelope, ack, emit
          Slack_gateway_state (pure FSM: hello/connected/reconnect)
                ↓ Emit_event (message/app_mention)
          Channel_gate.handle_inbound_streaming (existing)
                ↓
          keeper workspace (existing)

keeper → Channel_gate_slack_state.send_message → Masc_http_client.post_sync chat.postMessage
```

### Reuse, not re-implementation

The transport layer (`Discord_wss_connection` — ws-direct + TLS over
`Eio.Flow.two_way`) is **protocol-neutral**. A Slack Socket Mode WSS URL
(`wss://wss-primary.slack.com/?batch_size=...&app_id=...`) is the same
`wss://host/path?query` shape as a Discord gateway URL. So we open the
Slack connection with the Slack-issued URL through the *same* module — no
`slack_wss_connection` shim. This is deliberate duplication-avoidance:
the two gateways share a transport and differ only in FSM + I/O driver.

What is genuinely Slack-specific and therefore new:

| Layer | Discord (original) | Slack (new) | Difference |
|---|---|---|---|
| Transport | `discord_wss_connection` | **reused** | URL only |
| FSM | `discord_gateway_state` (op 1/2/10/11, heartbeat, resume, identify) | `slack_gateway_state` | **simpler**: no heartbeat opcode (endpoint auto-replies to RFC 6455 Ping), no resume (reconnect is always a fresh `apps.connections.open`), no identify (the WSS URL carries the credential) |
| I/O driver | `discord_gateway_client` (run + heartbeat fiber) | `slack_socket_client` | run + on_event, **adds per-envelope ack**, **adds apps.connections.open URL fetch** |
| REST | `discord_rest_client` | `slack_rest_client` / `keeper_chat_slack` (PR-2) | chat.postMessage/chat.update; `keeper_chat_slack.ml` already in-process (dead code) |
| Connector state | `channel_gate_discord_state` | `channel_gate_slack_state` **rewrite** (PR-2) | sidecar functor → in-process FSM read |

## Protocol differences (Slack Socket Mode vs Discord Gateway)

| Concern | Discord | Slack |
|---|---|---|
| Connection URL | constant (`wss://gateway.discord.gg/?v=10&encoding=json`) | **dynamic**: fetched per-connect via `apps.connections.open` |
| Handshake | HELLO (op 10) → IDENTIFY (op 2) | HELLO envelope only (no identify; URL carries the token) |
| Liveness | client-sent heartbeat (op 1) + ACK (op 11), with timeout-driven reconnect | **no client heartbeat**: ws-direct auto-replies to Ping; liveness is the TCP/TLS layer |
| Resume | RESUME (op 6) with session_id + sequence | **none**: reconnect is always fresh `apps.connections.open` → new WSS → new hello |
| Per-message ack | none (fire-and-forget over the socket) | **required**: each envelope must be answered with `{"envelope_id": "..."}` or Slack retransmits and eventually drops the connection |
| Tokens | one (`BOT ...`, gateway + REST) | **two**: `xoxb-...` (bot, REST outbound) + `xapp-...` (app, Socket Mode / `apps.connections.open`) |

## Envelopes and events

A Slack Socket Mode frame is `{type, envelope_id?, payload?}`:

- `type: "hello"` — once on connect. Transitions FSM `Awaiting_hello → Connected`.
- `type: "events_api"` — `payload.event` is the real event. Decoded by
  `event.type`: `message` / `app_mention` / `reaction_added` (others →
  `Ignored_event`, a known-unknown, never a silent swallow).
- `type: "disconnect"` — `payload.reason`; reconnect required.
- `type: "reconnect"` — Slack asks for a fresh connection.
- `type: "slash_commands" | "interactive"` — acknowledged, not surfaced
  this round (out of scope).

Every envelope except `hello` carries `envelope_id` and **must be acked**.
The FSM emits `Send_ack { envelope_id }` alongside any `Emit_event` so the
I/O layer cannot forget — this is the type-level guarantee that replaces
Discord's fire-and-forget.

## Trigger policy

Same closed sum as Discord (`Mention_only` / `Mention_or_thread` /
`User_only of string` / `All`), decoded from `MASC_SLACK_TRIGGER_POLICY`
(PR-3). The FSM's `passes_policy` decides which `message`/`app_mention`
events earn an `Emit_event`; `reaction_added` is ambient (not a
turn-starter). `App_mention` always emits (it is, by definition, a mention).

## Tokens and redaction

- `SLACK_APP_TOKEN` (`xapp-...`) — used **only** for
  `apps.connections.open` (the URL fetch). It leaves the process only in
  that one `Authorization: Bearer` header. Resolved via `Env_config_slack`;
  the gateway passes it to `slack_socket_client`.
- `SLACK_BOT_TOKEN` (`xoxb-...`) — REST outbound (`chat.postMessage` /
  `chat.update`) and `auth.test` (bot identity). Resolved via
  `Env_config_slack` at send time — one boundary shared with the keeper
  surface-post tool and the chat-queue consumer — not by the inbound client.

Tokens are **unprefixed** (not `MASC_SLACK_*`): this matches the Slack SDK
convention, the Python sidecar, the dashboard setup guide, and the Discord
token precedent (`DISCORD_BOT_TOKEN`), so a single `SLACK_BOT_TOKEN` covers
both the sidecar (until PR-4) and this in-process gateway. Only the
non-credential policy override keeps the namespace: `MASC_SLACK_TRIGGER_POLICY`
(mirroring `MASC_DISCORD_TRIGGER_POLICY`).

Both are redaction prefixes: `observability_redact` already covers `xoxb-`
and friends; `xapp-` and `ghs_/gho_/ghu_` style prefixes are added where
Slack-specific. Neither token is logged, nor appears in argv.

Every outbound Slack HTTP call (`apps.connections.open`, `chat.postMessage`,
`chat.update`, `auth.test`) is bounded by `Slack_rest_client`'s
`default_http_timeout_sec` (10s) once the gateway threads its `~clock`, so a
stalled Slack API cannot pin the gateway boot fiber or a reply fiber
indefinitely.

## Reconnect and backoff

Exponential backoff starting at 1s, doubling, capped at 30s — same shape as
Discord. ±25% jitter is applied in the I/O layer (not the FSM) so the FSM's
`delay_ms` stays deterministic for unit tests. Reconnect is always a fresh
`apps.connections.open` (no resume). The FSM routes any `Wss_closed` in
`Awaiting_hello` or `Connected` to `Reconnect_pending`; a connect-time
failure (DNS/TLS/handshake) is fed as `Wss_closed` — there is no separate
`Connect_failed` input, because both retry the same way.

## Validation

- **Unit (PR-1)**: `Slack_gateway_state.step` — every legal transition
  (Disconnected→Awaiting_hello on Connect_requested; Awaiting_hello→Connected
  on hello; Connected→Reconnect_pending on disconnect/reconnect/wss_closed;
  Reconnect_pending→Awaiting_hello on Backoff_elapsed), `Send_ack` emitted
  on every ackable envelope, `passes_policy` for each policy, `parse_envelope`
  (hello/events_api/disconnect/reconnect/unknown→Error), `decode_event`
  (message/app_mention/reaction_added/unknown→Ignored_event).
- **Integration (PR-3)**: with both tokens set, server boot → Socket Mode
  connect → Slack mention → keeper turn → `chat.postMessage` reply.
- **Regression (PR-4)**: `/api/v1/sidecar/status?name=slack` 404; Discord
  gateway unaffected (separate module tree).
- **Security**: token redaction snapshot test; no token in logs/argv.

## PR split

1. **PR-1 (landed)**: RFC + `slack_gateway_state` (pure FSM) +
   `slack_socket_client` (I/O driver) + `Log.Slack` + unit tests. Proves
   the core Socket Mode connection decodes and acks. Server does not wire
   it yet.
2. **PR-2 (landed)**: `slack_rest_client` + `keeper_chat_slack` +
   `channel_gate_slack_state` rewrite (in-process) + connector registration +
   `Keeper_chat_queue.Slack` deferred-delivery source. (`connector_kind` Slack
   moved to PR-3: `gate_keeper_backend` withholds the arm until the gateway that
   emits `dispatch ~connector_kind:Slack` exists, to avoid a dead branch.)
3. **PR-3 (this batch)**: `server_slack_in_process_gateway` + bootstrap + env
   (`SLACK_APP_TOKEN`, `MASC_SLACK_TRIGGER_POLICY`) + `slack_observability`
   + `slack_rest_client.auth_test` (bot identity) + the `connector_kind:Slack`
   arm (with `route_busy_connector` + the surface/conversation-id arms). Bridges
   triggered `Message_create`/`App_mention` to
   `Channel_gate.handle_inbound_streaming` with a threaded streaming reply.
   Ambient recording, idle-keeper wake, and reaction-as-trigger are deferred.
4. **PR-4 (pending)**: delete `sidecars/slack-bot/` + remove Slack branch from
   `server_routes_http_routes_sidecar` + drop `channel_gate_sidecar_state`
   Slack instance.

## Out of scope

- Slack interactive / slash_commands envelopes (buttons, slash commands) —
  this round is `message` / `app_mention` / `reaction_added`. Interactive
  is a follow-up.
- Slack Events API (HTTP redirect) mode — Socket Mode only; no
  `SIGNING_SECRET`.
- Discord / imessage / telegram sidecars — unchanged.
- keeper alert Slack (webhook/DM, `keeper_alerting.ml`) — separate feature,
  untouched.
- `plugin_slack` MCP (Claude Code capability) — unrelated to masc.
