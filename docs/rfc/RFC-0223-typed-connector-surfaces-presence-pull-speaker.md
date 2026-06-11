---
rfc: "0223"
title: "Typed connector surfaces: presence in world prompt, pull-based lane context, speaker identity persistence"
status: Draft
created: 2026-06-10
updated: 2026-06-10
author: vincent
supersedes: []
superseded_by: null
related: ["0203", "0218"]
implementation_prs: []
---

# RFC-0223: Typed connector surfaces — presence, pull-based lane context, speaker identity

Status: Draft · Push/pull boundary for keeper context · No new stores
Drafted by: Claude Fable 5 (design session with owner, 2026-06-10).

> All anchors marked **(verified)** were read against `origin/main` (`78823b414`) on 2026-06-10 while writing this RFC.

---

## §1 Problem — the keeper gains ears and mouths but cannot perceive or address them

A keeper's conversation timeline is one continuous sequence, but messages now
arrive through multiple connectors: dashboard chat, the in-process Discord
gateway (RFC-0203), Slack adapters, and any consumer of the generic gate
endpoint `POST /api/v1/gate/message`. One agent, several ears and mouths.
Four defects prevent the keeper from handling this coherently:

### 1.1 No presence: the keeper does not know which surfaces are attached

`Keeper_world_observation.observe()` assembles pending board events, task
counts, idle seconds, context ratio (`keeper_world_observation.ml:422-471`
**(verified)**) — but nothing about connectors. A keeper bound to a Discord
channel has no standing awareness that the binding exists, whether the
gateway is alive, or that it could be spoken through.

### 1.2 No pull: lane history exists on disk but is unreachable from a turn

Every connector's traffic is already persisted into one JSONL per keeper
(`<base-path>/.masc/keeper_chat/<name>.jsonl`) with a `source` label
(`keeper_chat_store.mli:35-43` **(verified)**). The only reader is the
dashboard hydration endpoint `GET /api/v1/keepers/:name/chat/history`
(`server_dashboard_http_keeper_api.ml:28-39` **(verified)**). The keeper
itself has no tool to read "what was said on the dashboard lane" while it is
talking on Discord, or vice versa.

### 1.3 No addressed output: replies are reactive only

Keeper output is persisted to session-local history
(`keeper_context_core_history.ml:198-234` **(verified)**) and connector
replies happen only as the synchronous response to an inbound dispatch
(`server_discord_in_process_gateway.ml:58-96` **(verified)**, adapter loops in
`server_bootstrap_loops.ml:934-999` **(verified)**). There is no way for a
keeper to initiate a message to a specific bound surface ("post the build
result to the Discord channel").

### 1.4 Speaker identity reaches the turn but dies before persistence

The dashboard is the authenticated owner; a Discord channel contains
arbitrary external people the keeper "meets". Identity currently flows:

- The gate prepends a text block — channel / workspace_id / user_id /
  user_name — to the user message via `Gate_keeper_backend.contextualize_message`
  (`gate_keeper_backend.ml:73-90` **(verified)**), so the *current turn* sees
  who spoke.
- But persistence drops it: `append_turn ~user_content:payload.message` stores
  the pre-contextualize original, and `chat_message` has no speaker fields
  (`server_routes_http_keeper_stream.ml:607` **(verified)**,
  `keeper_chat_store.mli:35-43` **(verified)**). Replaying the lane later
  cannot recover who said what.
- Worse, for Discord the "name" is not a name: the in-process gateway copies
  the snowflake into the name slot — `channel_user_name = author_id`
  (`server_discord_in_process_gateway.ml:70` **(verified)**) — because the
  gateway parser extracts only `author.id` and discards `author.username` /
  `author.global_name` (`discord_gateway_state.ml:272-274` **(verified)**).
- Meanwhile the dispatch layer already keys per-actor sessions via
  `agent_name_for_channel_actor ~channel ~channel_workspace_id ~channel_user_id`
  (`gate_keeper_backend.ml:95-98` **(verified)**) — identity exists at
  dispatch, is rendered as prompt text once, and is then lost. The two layers
  disagree about whether identity is durable.

### 1.5 Related dead path (context, not scope)

`collect_message_scope` is a stub returning `([], [], [])` after the tool
observation gate removal (`keeper_world_observation_message_scope.ml:47-53`
**(verified)**, commit `c4df7c44d`). This RFC does **not** revive it; it is
listed so a future reader does not confuse the per-lane pull design with the
old push-scoped message feed.

## §2 Design principles

1. **Push/pull boundary.** Only small, deterministic facts live in the world
   prompt (presence: which surfaces, alive or not). Conversation content is
   pulled on demand by tool call. This is the inverse of the raw-history
   reinjection pattern (`keeper_run_prompt.ml:182-184` **(verified)** injects
   full checkpoint messages every turn); presence adds tens of tokens, not
   thousands.
2. **No new stores.** Lane views and the participant roster are derived from
   the existing keeper_chat JSONL. The bindings file
   (`.gate/runtime/discord/bindings.json`) and connector registry
   (`channel_gate_connector.mli:17-68` **(verified)**) remain the SSOT for
   presence. Adding a third conversation store would extend the existing
   keeper_chat ↔ checkpoint.messages split-brain, not solve it.
3. **Typed surfaces, parse at the boundary.** `source` stays a plain label on
   disk (`"dashboard" | "discord" | <gate-channel>`) for compatibility; code
   that consumes it parses into a closed sum immediately. No new string
   classifier branches (CLAUDE.md workaround signature #2).
4. **read/act split.** The read tool is side-effect-free and always allowed;
   the post tool is an action and goes through tool policy.
5. **OAS untouched.** Surfaces are a MASC concept. OAS continues to receive a
   host-assembled message list; nothing here crosses the boundary.
6. **No standing machinery (owner constraint).** Presence is recomputed from
   bindings + registry on every observation — no cached presence state. The
   roster is a fold over existing JSONL lines — no roster store. The only
   persistent addition in this RFC is optional data fields on lines that are
   already written. No budgets, no cursors, no caps, no cooldowns: the
   deleted tool-retry budget (#20624) and the removed tool_heavy compaction
   trigger (#20694) are the cautionary precedents for what accumulating
   small state machines produces.

## §3 Typed model

New module (proposed `lib/gate/surface.ml`, consumed by keeper + server):

```ocaml
type t =
  | Dashboard
  | Discord of { workspace_id : string; channel_id : string }
  | Slack of { workspace_id : string; channel_id : string }
  | Gate of { channel : string }
      (* any other connector speaking the generic gate protocol;
         [channel] is the connector's registered label, verbatim *)

val label : t -> string
(* round-trips to today's on-disk [source] strings *)

val of_source :
  source:string -> workspace_id:string option -> channel_id:string option -> t
(* unknown labels map to [Gate { channel = source }] — this is the honest
   reading (every non-builtin source IS a gate channel label), not a
   permissive default *)
```

```ocaml
type authority =
  | Owner      (* authenticated dashboard operator *)
  | External   (* arrived through a connector; arbitrary third party *)

type speaker = {
  id : string;            (* dashboard session id / Discord snowflake / ... *)
  name : string option;   (* human-readable; None when the connector gave none *)
  authority : authority;
}
```

`authority` is derived structurally, never from content: requests through the
authenticated dashboard route are `Owner`; anything with connector context is
`External`. The keeper prompt attribution must carry this distinction so that
instructions from channel strangers are not weighted as operator
instructions (prompt-injection surface; today both arrive as undifferentiated
user messages).

## §4 Changes, by phase (each independently shippable)

### P1 — Speaker persistence + real Discord names

| Change | Site |
|---|---|
| `chat_message` gains `speaker_id : string option`, `speaker_name : string option`, `speaker_authority : authority option` | `keeper_chat_store.ml/.mli` |
| `append_turn` takes `?speaker` and writes the fields on the user line | `keeper_chat_store.ml` |
| Stream route passes `payload.channel_user_id/_name` (connector) or the authenticated operator identity (dashboard) into `append_turn` | `server_routes_http_keeper_stream.ml:599-661` |
| Gateway parser extracts `author.username` and `author.global_name` alongside `author.id` | `discord_gateway_state.ml:272-294` |
| In-process gateway passes the real name; the snowflake stays in `channel_user_id` only | `server_discord_in_process_gateway.ml:58-96` |
| REST history schema + dashboard pass-through of the new optional fields | `dashboard/src/api/schemas/keeper-chat-history.ts`, render minimal |

Disk compatibility: fields are optional and omitted when absent, same policy
as existing optional fields (`keeper_chat_store.ml:277-305` **(verified)**).
Old lines parse unchanged.

### P2 — Presence in the world prompt

- `world_observation` gains `connected_surfaces : surface_presence list` where
  `surface_presence = { surface : Surface.t; alive : bool }`.
- Sources: reverse lookup of the Discord bindings for this keeper
  (`Channel_gate_discord_state` bindings, `channel_gate_discord_state.ml:61-76`
  **(verified)**) plus connector registry status
  (`channel_gate_connector.mli` registry). Dashboard is always present.
- World prompt renderer adds one short section, e.g.:
  `Connected surfaces: discord #<channel> (alive), dashboard (alive)`.
- Deterministic; no content, no counts in this phase.

### P3 — Pull tool: `keeper_surface_read`

```
keeper_surface_read { surface: <label or structured>, limit?: int }
```

- Backed by `Keeper_chat_store.load` filtered to the requested surface,
  returning messages **with speaker id/name/authority** (P1 data).
- Response includes a derived participant roster for that lane: group lines by
  `speaker_id` → `{ id, name, first_seen, last_seen, message_count }`. No
  separate roster store; it is a fold over the lane's lines.
- Read-only; registered in the always-allowed read class.
- A `mode: digest` parameter is reserved but NOT implemented in this RFC
  (summarization is non-deterministic and needs its own evaluation harness;
  see §5).

### P4 — Act tool: `keeper_surface_post`

```
keeper_surface_post { surface: <label or structured>, content: string }
```

- Discord: `Channel_gate_discord_state.send_message`
  (`channel_gate_discord_state.mli:48-97` **(verified)**).
- Dashboard: `Keeper_chat_store.append_turn` (assistant-only form) +
  `Keeper_chat_broadcast.chat_appended` so a keeper-initiated message appears
  in the dashboard via the existing `keeper_chat_appended` SSE path
  (`keeper_chat_broadcast.ml:6-31` **(verified)**).
- Policy-gated (action class). Posting to a surface the keeper is not bound to
  is an error, not a no-op.

Tool registration for P3/P4 must satisfy the three-system consistency
requirement (policy candidate / `effective_core_tools` `public_names()` /
`raw_all_tool_schemas` inventory) — the same surface that produced the
WebSearch allow-list prune regression fixed in PR #20060.

## §5 Non-goals / deferred

| Deferred | Why | Re-entry condition |
|---|---|---|
| Digest mode for `keeper_surface_read` | summarization is non-deterministic; needs a fact-retention evaluation harness before it can feed a prompt | separate RFC with harness |
| Ambient channel recording | today, messages failing the trigger policy never reach dispatch (`server_discord_in_process_gateway.ml:103-105` **(verified)** — policy enforced at gateway-state layer) and are not persisted anywhere. Recording all bound-channel traffic decouples record-from-trigger and is a privacy/noise decision in its own right | separate RFC |
| Unread counts / lane cursors | requires per-lane cursor state; presence v1 is stateless | when digest or ambient lands |
| Person-note memory ("who is this person") | the roster (P3) is the deterministic layer: derived from the log, it naturally ages out with log retention — log-bounded LRU behavior for free. A durable "what I know about this person" layer is keeper memory work, non-deterministic, out of scope | separate design |

## §6 Validation

- Unit: `Surface.of_source`/`label` round-trip over all known labels +
  unknown-label → `Gate` case; speaker fields JSONL round-trip (write old-style
  line, read; write new line, read); roster derivation fold (ordering,
  first/last seen, counts).
- Integration: gate inbound with connector context → persisted user line
  carries speaker id + real name; bound keeper's world prompt contains the
  presence section; unbound keeper's does not.
- Tool registration: three-system consistency test for the two new tools
  (mirrors the #20060 regression tests).
- Manual: real Discord message from a named user → `keeper_surface_read`
  from the dashboard lane shows the user's name, not a snowflake.

## §7 Workaround self-check (CLAUDE.md signatures)

- No telemetry-as-fix: every change alters behavior (persistence, prompt
  content, tools), none merely counts.
- No string classifier added: the one string surface (`source` label) gains a
  boundary parser into a closed sum; consumers match on the sum.
- No N-of-M: phases are vertical slices, each complete for its concern.
- No cap/cooldown/dedup/repair.
