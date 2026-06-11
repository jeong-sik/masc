---
rfc: "0230"
title: "Keeper mention/scope reactivity: cursor-free salience to complement pull-based recall"
status: Draft
created: 2026-06-11
updated: 2026-06-11
author: vincent
supersedes: []
superseded_by: null
related: ["0223", "0228"]
implementation_prs: []
---

# RFC-0230: Keeper mention/scope reactivity — cursor-free salience

Status: Draft · Implements the starved `collect_message_scope` as a turn-trigger
salience signal · Retires the per-message cursor scaffolding (RFC-0223 §1.5)
Drafted by: Claude Opus 4.8 (research-to-RFC pass with owner, 2026-06-11).

> Anchors marked **(verified)** were read against `origin/main` (`95150953b`)
> on 2026-06-11 while writing this RFC.

---

## §1 Problem — the salience producer is stubbed; the consumer graph is live

`collect_message_scope` returns `[], [], []`
(`lib/keeper/keeper_world_observation_message_scope.ml:47-53` **(verified)**):

```ocaml
let collect_message_scope ~(config : Workspace.config) ~(meta : keeper_meta)
  : (string * string) list * (string * string) list * (string * int) list
  = let _ = config in let _ = meta in [], [], []
```

It is a stub, but its outputs (`world_observation.pending_mentions`,
`pending_scope_messages`) feed a fully-wired consumer graph:

- `keeper_unified_prompt.ml:738-750` **(verified)** formats mentions and scope
  messages into the keeper prompt (`format_mentions` / `format_scope_messages`).
- `keeper_unified_metrics_result.ml:68` **(verified)**:
  `is_mention_reactive = observation.pending_mentions <> []`.
- `keeper_unified_metrics_support.ml:18-20,426-449` **(verified)** classifies the
  reactive trigger (`direct_mention`, `scope_message`, `message_sweep`).
- `keeper_turn_helpers.ml:155-156` **(verified)**: the post-action guard pins a
  reactive turn when `pending_mentions` / `pending_board_events` /
  `pending_scope_messages` is non-empty.

Because the producer is always `[]`, every one of these branches is dead at
runtime. The prompt has a mention slot that is always empty; the reactive
classifier never sees a mention; the post-action guard fires only on board
events. This is an **unimplemented needed function**, not dead code.

### 1.1 Why this is the herd's root

Today a keeper wakes content-free (registry-wide `wakeup_all`) and the only
live reactive discriminator is `pending_board_events` — so woken keepers all
look at the same global backlog and react together. The research
(`2026-06-10-masc-autonomy-determinism-harness` R3) traced the thundering-herd
to exactly this: there is no *targeted* wake. Mention/scope salience is the
missing per-keeper discriminator that would let the addressed keeper react and
the others stay quiet.

### 1.2 Salience is a turn-trigger; pull cannot supply it

RFC-0228 (paged lane pull) and RFC-0223 §2.1 (pull-on-demand) give a keeper
*in-turn* read access — it pulls what it needs once it is already taking a turn.
Salience is the opposite edge: deciding *whether* to take a turn because the
keeper was addressed. A pull surface cannot answer "should this keeper wake
now" — by construction the keeper is not in a turn yet. So this signal is not
redundant with 0228; it is the attention half whose recall half 0228 builds.

| Concern | Surface | Edge |
|---|---|---|
| Recall (read older context) | `keeper_surface_read` + 0228 paging | in-turn pull |
| Salience (notice being addressed) | `collect_message_scope` (this RFC) | turn-trigger |

## §2 The cursor question — what RFC-0223 actually rejected

RFC-0223 §1.5 declined to "revive" `collect_message_scope` and warned against
confusing the pull design with the "old push-scoped message feed." §2.6 states
the owner constraint: no budgets, no cursors, no caps, no cooldowns.

The third tuple element of `collect_message_scope` — `(string * int) list` — is
a **per-source cursor**, persisted by its partner
`apply_message_cursor_updates` (identity stub,
`keeper_world_observation_message_scope.ml:55-59` **(verified)**) through
`Keeper_heartbeat_loop_persist_cursor.persist_message_cursor_updates`
(`keeper_heartbeat_loop_persist_cursor.ml:33` **(verified)**) and surfaced as
the `world_observation.message_cursor_updates` field
(`keeper_world_observation.ml:33,459` **(verified)**). *That cursor mechanism*
is what §1.5/§2.6 reject — not the relevance computation.

So this RFC separates the two:

1. **Implement** the relevance computation (mentions of `meta.name`, scope
   messages) — the capability the consumer graph waits on.
2. **Retire** the per-message cursor scaffolding (the `(string * int)` tuple
   element, `apply_message_cursor_updates`, `message_cursor_updates` field,
   `persist_message_cursor_updates`) — the mechanism §1.5/§2.6 reject.

Salience is recomputed each observation from existing keeper state, the same
way presence already is: `connected_surfaces` is rebuilt every `observe()` via
`Gate_surface.connected_surfaces_for_keeper ~keeper_name:meta.name`
(`keeper_world_observation.ml:471-472` **(verified)**) with no cursor. Mention
and scope salience follow that template.

## §3 Design

### 3.1 New signature (cursor-free)

```ocaml
val collect_message_scope :
  config:Workspace.config -> meta:keeper_meta ->
  (string * string) list * (string * string) list
  (* mentions, scope_messages — the (string * int) cursor element is removed *)
```

- **Mentions**: scan the keeper's lane window (tail-bounded read, reusing the
  RFC-0226 P2 `tail_read_bytes` bound — no full-file scan) for messages whose
  text addresses `meta.name` (the existing `Keeper_identity` self-token logic
  already present in the module is the matcher). Return `(speaker, text)` pairs.
- **Scope messages**: the same window filtered to the keeper's subscribed scope,
  excluding keeper-authored lines (`is_keeper_authored_message`, already in the
  module).
- **Recency**: "new to this keeper" is derived from the keeper's own continuity
  marker (`continuity_summary`, already read in `observe()` and already used by
  `collect_board_events ~meta ~continuity_summary`), not from a separate cursor
  store. See §7 open question on board/message symmetry.

### 3.2 Removed (the cursor scaffolding)

- `apply_message_cursor_updates` and its `.mli`.
- `world_observation.message_cursor_updates` field and the `observe()` binding.
- `Keeper_heartbeat_loop_persist_cursor.persist_message_cursor_updates` (its
  only callers are the heartbeat loop persisting empty cursor updates).

Removing a field forces every construction site to be updated at compile time;
OCaml's exhaustiveness is the safety net.

## §4 Phases

### P1 — Mention salience (cursor-free)
- Implement the mention half; drop the cursor tuple element + scaffolding.
- Wire nothing new downstream — the consumers already read `pending_mentions`.
- Tests: a lane with `@<keeper>` produces a non-empty `pending_mentions` for
  that keeper and empty for others (targeted, not herd); no mention → empty.

### P2 — Scope salience
- Implement the scope-message half (subscribed scope, non-self-authored).
- Tests: scope message in-scope → `pending_scope_messages` non-empty; out of
  scope / self-authored → empty.

### P3 — Targeted-wake assertion
- Property test (TLA+ optional, software-development.md §TLA+): given a mention
  for keeper A only, A's post-action guard pins a reactive turn and B's does
  not. A `MentionLostToHerd` bug-action (every keeper reacts) must violate a
  `OnlyAddressedKeeperReacts` invariant; the clean model must satisfy it.

## §5 Verification

| Claim | How |
|-------|-----|
| Producer no longer starves consumers | Test: `pending_mentions` non-empty on a planted mention |
| Targeted, not herd | Test: only the addressed keeper's observation carries the mention |
| No new store | Code review: salience derived from lane window + existing continuity marker |
| Cursor scaffolding gone | `git grep message_cursor_updates` → empty after P1 |
| Read cost bounded | Code review: tail-bounded read, no full-file scan (RFC-0226 P2 bound) |

## §6 Workaround self-check (CLAUDE.md signatures)

- Telemetry-as-fix: no — this implements a behavior (salience), not a counter.
- String classifier: the mention matcher is the existing typed `Keeper_identity`
  self-token logic, not a new substring gate. No new prefix classifier.
- N-of-M: no — single function, single locus.
- Cap/cooldown/dedup/repair: **net removal** of the cursor scaffolding; no cap,
  no cooldown introduced. The tail-bound reuses the existing RFC-0226 bound.

## §7 Open questions

1. **Board/message cursor symmetry.** `collect_board_events` today uses a cursor
   policy (`collect_board_events_with_cursor_policy`,
   `keeper_world_observation.ml:221` **(verified)**), so making message scope
   cursor-free creates two different "what's new for me" bases in the same
   `observe()`. Options: (a) ship message salience cursor-free now and migrate
   board events to the same continuity basis in a follow-up (aligns §2.6); (b)
   mirror the board cursor policy for messages now (symmetry, but perpetuates a
   cursor §2.6 wants gone). This RFC proposes (a); confirm.
2. **Continuity marker sufficiency.** Is `continuity_summary` a precise enough
   recency anchor to avoid re-surfacing an already-handled mention every
   observation, without a per-message cursor? If not, the minimal addition is a
   single keeper-owned last-observed lane `ts` in `keeper_meta` (not a
   per-source cursor table) — to be decided in P1, not assumed here.
