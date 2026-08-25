---
title: In-process Telegram connector (long polling)
rfc: "0384"
status: Proposed
created: 2026-08-16
author: vincent
related: ["0203", "0317"]
---

# RFC-0384 — In-process Telegram connector (long polling)

An OCaml `getUpdates` loop replaces `sidecars/telegram-bot/` (Python
python-telegram-bot). The third and simplest instance of the move
[[RFC-0203]] made for Discord and [[RFC-0317]] made for Slack.

> **Status.** Proposed. Two PRs, not four — see §PR split.

## Why

The out-of-process shape is not a neutral packaging choice. It generates a
specific, recurring class of defect, and this repo paid for it four times on
2026-08-16 alone:

| PR | Defect |
|---|---|
| #28848 | A stopped sidecar could not be restarted. Liveness read a heartbeat file that the bot's shutdown path rewrote with `connected=true` |
| #28855 | The liveness decision took the clock inside itself |
| #28869 | The bot wrote `status.json` to a path no reader looked at |
| #28882 | The two OCaml readers of that file accepted no env var in common |

Every one of those is a consequence of liveness being a *file* rather than a
value the process owns. Discord and Slack have none of them: their
`connected ()` reads an `Atomic` published by the run loop
(`channel_gate_discord_state.ml:469`, `channel_gate_slack_state.ml:336`), and
a value in memory cannot be stale, cannot be at the wrong path, and cannot
outlive the process that wrote it.

Telegram is the cheapest remaining connector to move, and it is cheaper than
Slack was.

## Shape

```
api.telegram.org  ←  getUpdates(offset, timeout=N)   [Eio fiber, Masc_http_client]
        ↓ decode update
  Channel_gate.handle_inbound ~dispatch
        ↓
  keeper turn

keeper → Channel_gate_telegram_state.send → Masc_http_client.post_sync sendMessage
```

There is no third box. That is the whole point of this RFC.

### Reuse, not re-implementation

`Masc_http_client` (`post_sync`, `get_sync`, `get_response_sync`) already
carries Slack's and Discord's REST traffic. Telegram's Bot API is ordinary
HTTPS JSON against `api.telegram.org`. **Zero new opam deps**, same as
RFC-0317.

`Channel_gate.handle_inbound` (`channel_gate.mli:83`) is the existing inbound
boundary; Slack reaches it at
`server_slack_in_process_gateway.ml:315`. Telegram uses the same call.

### Unlike Slack: there is no gateway FSM

This is the material difference from RFC-0317, and it is what makes this the
smallest of the three migrations.

| Layer | Discord | Slack | Telegram |
|---|---|---|---|
| Transport | `discord_wss_connection` (WSS + TLS) | reused | **none** — plain HTTPS |
| Gateway FSM | `discord_gateway_state.ml` (1,285 lines) | `slack_gateway_state.ml` (376) | **none** |
| I/O driver | `discord_gateway_client.ml` (431) | `slack_socket_client.ml` (293) | poll loop |
| Handshake | HELLO → IDENTIFY | HELLO envelope | **none** |
| Liveness | client heartbeat + ACK | TCP/TLS layer | **the poll itself** |
| Resume | RESUME with session_id + sequence | fresh `apps.connections.open` | **`offset`, an integer** |
| Per-message ack | none | required per envelope | **implicit**: advancing `offset` |

Long polling has no connection state machine because it has no connection to
keep. Every `getUpdates` is a fresh request; the only carried state is one
integer. The 1,285-line box and the 376-line box are both empty here.

### What is genuinely new

Three things, and they are where the bugs will be:

1. **The offset ledger.** `getUpdates(offset=N)` acknowledges everything below
   `N`. Advance it before the turn is durably accepted and an update is lost;
   advance it after and a crash redelivers. python-telegram-bot hid this
   choice. We have to make it, and it must be the same choice
   `Channel_gate.handle_inbound` already encodes for the other two.
2. **429 / `retry_after`.** Telegram answers flood with a `retry_after`
   seconds field. Honour it or the bot is throttled into silence.
3. **Structured-block rendering.** `formatters.py` is 255 lines projecting
   keeper chat blocks into Telegram HTML. That has to be ported, not
   redesigned.

## Validation

- **Unit**: offset advances exactly once per accepted update and never past an
  unaccepted one; `retry_after` honoured; update decode
  (`message` / `edited_message` / unknown → ignored); HTML renderer matches
  `formatters.py` output for each block kind.
- **Integration**: server boot with `TELEGRAM_BOT_TOKEN` → send a message →
  keeper turn → reply arrives.
- **Regression**: `/api/v1/sidecar/status?name=telegram` 404 after PR-2;
  Discord and Slack unaffected (separate module trees).
- **Security**: token redaction snapshot; no token in logs or argv.

All of it runs on Linux CI. This is not true of iMessage — see §Out of scope.

## PR split

Two, not four.

1. **PR-1**: `telegram_rest_client` (`getUpdates` / `sendMessage` /
   `editMessageText`), the poll fiber, the offset ledger, the HTML renderer,
   unit tests. Not wired into bootstrap; the sidecar still runs.
2. **PR-2**: `channel_gate_telegram_state` rewritten from the sidecar functor
   instance to the in-process shape, bootstrap wiring, env, observability,
   dashboard `IN_PROCESS_CONNECTOR_IDS` + `IN_PROCESS_CONFIG_GUIDES`, and
   deletion of `sidecars/telegram-bot/`.

RFC-0317 split the same work four ways and PR-4 — the deletion — landed six
weeks after the gateway, while the state module already described the
sidecar as gone. A migration whose last step is optional does not finish; the
deletion belongs in the PR that makes it correct.

## Costs

Stated plainly, because the Why section only lists gains.

- **Crash blast radius.** A sidecar that dies takes Telegram with it. An
  exception escaping an Eio switch takes the server. Discord and Slack already
  accepted this for network I/O; Telegram adds no new kind of risk, but it
  does add another fiber that can raise.
- **A proven library is lost.** python-telegram-bot handles offset, dedup and
  flood control. Hand-writing them is where this will break. Mitigation is
  only that Discord and Slack hand-wrote harder protocols and hold.
- **Dashboard config surface.** Small and measured: the in-process guide
  entries for Discord and Slack are four lines each
  (`dashboard/src/components/connector-config-form.ts:82`).

## Out of scope

- **iMessage.** It reads `~/Library/Messages/chat.db` and sends through
  `osascript`, so in-processing it moves macOS Full Disk Access and Automation
  grants onto the masc binary. Whether a TCC grant survives a rebuild of an
  unsigned dune-built executable is unverified, and if it does not, the failure
  mode is precisely the one #28869 just fixed — configured, silent, reading
  nothing. Separately, CI cannot see it: of the `runs-on` declarations in
  `ci.yml`, fifteen are `ubuntu-latest` and one is `macos-14`
  (`ci.yml:1601`), and that one is gated on
  `github.ref == 'refs/heads/main' && github.ref_protected == true`
  (`ci.yml:1611-1612`), so it never runs on a PR. Needs its own RFC, and a
  measurement of whether the TCC grant survives a rebuild, before anything
  else.
- Telegram inline keyboards, callback queries, slash commands. This round is
  `message` and `edited_message`.
- Webhook mode. Long polling only; no public endpoint, no secret token.
- Ambient recording and idle-keeper wake on non-triggering messages —
  deferred in RFC-0317 too.

## Alternatives rejected

- **Keep the sidecar, fix the file protocol.** Four PRs on 2026-08-16 did
  exactly that. The class does not close while liveness lives in a file.
- **Move all remaining sidecars at once.** [[RFC-0203]] already rejected this:
  *"All-sidecars-at-once rejected: per-sidecar RFCs"* (RFC-0203:120). Telegram
  and iMessage have nothing in common beyond both being out of process.
