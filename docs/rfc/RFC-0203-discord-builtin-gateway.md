---
title: In-process Discord connector
rfc: "0203"
status: Draft
created: 2026-05-28
updated: 2026-05-28
author: vincent
related: ["0088"]
---

# RFC-0203 — In-process Discord connector

OCaml Gateway client replaces `sidecars/discord-bot/`. One tool out, push in.

## Why

- `sidecars/discord-bot/` (Python) has been silently dead since 2026-05-10 — gate reports `stale, connected:false`, can't self-recover.
- The connector state module (`Channel_gate_discord_state`) already lives in-process. Only "speak Discord" is external.
- OCaml build already has `httpun-ws`, `tls-eio`, `piaf`, `ca-certs`, `eio`. Zero new deps.

## Shape

```
Discord ↔ discord_gateway_client (OCaml WSS, Eio fiber)
              ↓ push
        Channel_gate_discord_state (existing)
              ↓
        keeper room (existing)

keeper → discord_send_message tool → Channel_gate_discord_state.send_message → REST POST
```

- **In = push.** Gateway WSS. No polling. Heartbeat op 1 every ~30s, dispatch op 0 events arrive when Discord sends them.
- **Out = one tool.** `discord_send_message(channel_id, content)`. Snowflake `channel_id` covers guild text + DM + thread uniformly.
- **No `discord_react`, no `discord_send_dm`, no `discord_watch`.** Anything reactions/DMs/threads can do is already covered by send_message + push inbound.
- **Inbound filter.** One env var `DISCORD_TRIGGER_POLICY` decides which pushed messages reach the keeper room. Three values only — typed variant, no string classifier:
  - `mention_only` (default) — only messages that @-mention the bot user
  - `user_only:<discord_user_id>` — only messages from one specific Discord user, in any connected channel/DM/thread
  - `all` — every message in connected channels (high traffic; explicit opt-in)

## Modules

New: `lib/gate/discord_gateway_client.{ml,mli}` (WSS + opcodes 0/1/6/7/9/10/11), `lib/gate/discord_rest_client.{ml,mli}` (single `send_message`), `lib/tool/tool_discord_dispatch.ml` (one typed input, match dispatch).

Extended: `lib/gate/channel_gate_discord_state.{ml,mli}` gains `send_message`. Existing `bind/unbind/status_json` unchanged.

Intents: `GUILDS | GUILD_MESSAGES | MESSAGE_CONTENT | GUILD_MESSAGE_REACTIONS | DIRECT_MESSAGES | DIRECT_MESSAGE_REACTIONS`. Threads ride `GUILD_MESSAGES`.

Token: reuse `sidecars/discord-bot/.env` `DISCORD_BOT_TOKEN` during dual-run; relocate at Phase 3.

## Phases

1. **Build.** WSS client + REST client + send_message tool, behind `MASC_DISCORD_BUILTIN=false` flag. PR ships, no user-visible change. Dead-code build verifies typing/linking.
2. **Dual-run.** Flag on, Python sidecar still running. 7 days. Inbound/outbound counters in gate audit must match across both paths.
3. **Delete.** Remove `sidecars/discord-bot/`, drop `discord` from sidecar status path resolver, update README. Reversible by `git revert`.

## Non-goals (anti-pattern guard)

If a follow-up PR adds any of these, it violates this RFC. Reject and escalate.

- `discord_react`, `discord_send_dm`, `discord_send_thread`, `discord_send_guild`, `discord_edit_message`, `discord_watch` — channel_id unifies, push delivers. Re-splitting brings back the fragmentation we're killing.
- Trigger policies beyond the three listed in §Shape (e.g. keyword match, regex, role-based, AI-classifier). That door opens straight onto the RFC-0088 §2 string-classifier anti-pattern. If you need finer routing, do it in the keeper, not in the connector.
- Polling. The reason this RFC exists is the sidecar's heartbeat polling failure mode. Adding any "check if there's a new message" loop on the OCaml side defeats the rewrite.
- Counter-as-fix on Gateway disconnects. Supervisor backs off (exponential, max 10 restarts / 60s window, then error log). No silent `gateway_disconnect_count` while spinning.
- String classifier on Discord error responses. Discord returns typed JSON with numeric `code`; decode into a variant.
- Catch-all `_ -> Ok ()` on opcode dispatch. Unknown opcode = typed error + close-and-resume.
- Heartbeat outside the WSS Eio switch. Must be a fiber on the same switch so teardown cancels it automatically.

## Risks

- **Gateway protocol drift.** discord.py absorbs this for free; we won't. Mitigation: pin v10, decode only `READY` / `MESSAGE_CREATE` / `MESSAGE_REACTION_ADD`, add a daily CI canary that identifies-and-exits.
- **WSS reconnect storms get IPs banned.** Mitigation: mandatory exponential backoff in supervisor + honor `Invalid_session.resumable=false` with 1–5s jitter (Discord docs).
- **`zlib-stream` compression not implemented.** Ship with `compress=false`. Personal-traffic volume makes this a non-issue. If it ever matters, separate small RFC.

## Decisions (user-confirmed 2026-05-28)

- Tool surface: **one tool, `discord_send_message`.** No `masc_` prefix. No `discord_react`.
- DM + threads + guild text all routed through the same tool via `channel_id`.
- Inbound trigger: default `mention_only`. `user_only:<id>` for "내 말에만 반응", `all` as explicit opt-in for high-traffic mode.
- Hermes Agents reference = [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent). Confirmed prior art with the same "single gateway process for all messaging platforms (Discord/Telegram/Slack/Signal/Matrix/...)" architecture. Hermes Discord default = mention-only (`DISCORD_REQUIRE_MENTION=true`), matching our `mention_only` default. Hermes' `DISCORD_ALLOWED_USERS` ≈ our `user_only:<id>`. Differences kept deliberate: Hermes supports role-based + channel allowlists; we do not (see §Non-goals — string/role classifier anti-pattern, single-operator setup).
- Python supervisor alternative rejected: defeats "내장" intent and leaves venv as deploy dep.
- All-sidecars-at-once rejected: per-sidecar RFCs; this one is Discord only.

## Open question

- RFC number 0203 may collide with an unmerged 0202 in another worktree. If 0202 merges first, renumber to next free at merge time.
