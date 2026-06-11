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

Status: Draft · Models keeper attention as a typed engagement state machine
(salience), not a string/recency scan · Retires the per-message cursor
scaffolding (RFC-0223 §1.5)
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

Salience is **not** a per-observation string scan plus a numeric recency
compare (that would be the substring-classifier + magic-number signatures
CLAUDE.md rejects). It is a typed engagement state machine (§3), advanced by
typed events; the state replaces the cursor.

## §3 Design — a typed engagement state machine

The exemplar is `keeper_failure_policy`
(`lib/keeper_failure_policy/keeper_failure_policy.mli:9-57` **(verified)**):
closed-sum state types (`stream_idle_state`, `timeout_phase`,
`liveness_evidence`, `failure`), `_of_label` / `_to_label` only at the
serialization boundary, predicates and a total decision over the sum. Salience
follows that shape.

### 3.1 Parse to a typed signal at the boundary, once

Detection is a one-time boundary parse, not a per-observation re-scan.
`pending_board_event` already does exactly this for board posts —
`explicit_mention : bool`, `matched_targets : string list`,
`post_kind : Board.post_kind` (`keeper_world_observation.ml:13-25`
**(verified)**). Lane lines get the same typed treatment:

```ocaml
type lane_signal =
  | Direct_mention of { speaker : string; at : float }
  | Scope_message  of { speaker : string; at : float }
  | Self_authored
  | Ambient
```

The `@<keeper>` text match runs once here (reusing the existing
`Keeper_identity` self-token logic), producing a typed value — the same way
board derives `matched_targets`. There is no substring gate downstream of this
parse.

### 3.2 Engagement is a per-conversation FSM, keyed like board (by post/thread)

```ocaml
type engagement =
  | Idle
  | Addressed   of { since : float; by : string }
  | Acknowledged of { at : float }
  | Disengaged  of { resolved_at : float }

type engagement_event =
  | Lane of lane_signal
  | Keeper_responded
  | Conversation_idle of { for_seconds : float }

val advance : engagement -> engagement_event -> engagement
(* total: every (state x event) pair is explicit, no `_ ->` catch-all
   (software-development.md AI anti-pattern #4). Each arm comments its path,
   e.g. Idle x Lane (Direct_mention _) -> Addressed;
        Addressed _ x Keeper_responded -> Acknowledged;
        Acknowledged _ x Lane (Direct_mention _) -> Addressed (re-addressed). *)
```

The keeper holds a typed map `conversation_key -> engagement` (mirroring
board's per-post tracking), persisted in `keeper_meta`. "Have I already handled
this mention" is the predicate `is Acknowledged`, never a `ts` comparison — the
state **is** the memory, so there is no cursor.

### 3.3 Salience is derived and total

```ocaml
type salience = Wake of { reason : string } | Quiet
val reactive_salience : engagement -> salience
(* Addressed _ -> Wake; Idle | Acknowledged _ | Disengaged _ -> Quiet *)
```

`observe()` builds `pending_mentions` / `pending_scope_messages` from the
entries whose engagement is `Addressed`. The consumer graph (§1) is unchanged —
only the producer becomes a typed FSM read instead of a stub.

### 3.4 Removed (the cursor scaffolding)

The `(string * int)` tuple element, `apply_message_cursor_updates`
(`keeper_world_observation_message_scope.ml:55-59` **(verified)**),
`world_observation.message_cursor_updates`
(`keeper_world_observation.ml:33,459` **(verified)**), and
`Keeper_heartbeat_loop_persist_cursor.persist_message_cursor_updates`
(`keeper_heartbeat_loop_persist_cursor.ml:33` **(verified)**) are superseded by
the engagement map — an explicit typed lifecycle, not a numeric per-source
pointer. Removing the field forces every construction site to update at compile
time.

## §4 Phases

### P1 — Typed lane signal at the boundary
- Add `lane_signal` and the one-time parse (reusing `Keeper_identity`); replace
  the raw `(string * string)` detection with typed signals.
- No FSM yet; no behavior change beyond producing typed values.
- Tests: a lane line addressing `<keeper>` parses to `Direct_mention`; a
  self-authored line to `Self_authored`; unrelated to `Ambient`.

### P2 — Engagement FSM + remove cursor scaffolding
- Add `engagement`, `engagement_event`, total `advance`, `reactive_salience`.
- Persist the `conversation_key -> engagement` map in `keeper_meta`; wire
  `observe()` to surface `Addressed` entries as `pending_mentions` /
  `pending_scope_messages`. Delete the cursor scaffolding (§3.4).
- Tests: `advance` is exhaustive; mention → `Addressed` → `Wake`; after
  `Keeper_responded` → `Acknowledged` → `Quiet` (re-fire suppressed without a
  cursor); only the addressed keeper wakes (targeted, not herd).

### P3 — Wake/silence assertions (TLA+ bug-model)
Three invariants, two directions:
- Noise side: `OnlyAddressedKeeperReacts` (no herd) and
  `AcknowledgedNeverReReacts` (no re-fire). Bug actions `MentionLostToHerd`
  (every keeper reacts) and `AckedReReacts` must each violate one.
- Silence side: `AddressedNeverSilentlyDropped` — an `Addressed` engagement
  leaves that state only via `Keeper_responded` (→ `Acknowledged`) or a fresh
  addressing signal (→ `Addressed`); never to `Disengaged`, a pruned slot, or a
  `Quiet` terminal without a `Keeper_responded`. Bug action `AddressedTimedOut`
  (`Addressed → Disengaged` on idle) must violate it; the clean model must
  satisfy it.

This is the formal guard against the side effect of keepers going quiet where
they should react (software-development.md §TLA+ bug-model).

## §5 Verification

| Claim | How |
|-------|-----|
| Producer no longer starves consumers | Test: `pending_mentions` non-empty when an `Addressed` engagement exists |
| Detection is typed, not a downstream substring gate | Code review: string match confined to the §3.1 boundary parse → `lane_signal` |
| `advance` is total | OCaml exhaustive match, no catch-all (CI ratchet guards `_ ->`) |
| Re-fire suppressed without a cursor | Test: `Acknowledged` + same mention → `Quiet`; no `ts` compare in the path |
| Targeted, not herd | Test/TLA+: only the addressed keeper's engagement is `Addressed` |
| Cursor scaffolding gone | `git grep message_cursor_updates` → empty after P2 |

## §6 Workaround self-check (CLAUDE.md signatures)

- Telemetry-as-fix: no — implements a behavior (a typed FSM), not a counter.
- String/substring classifier: the `@<keeper>` match is a one-time boundary
  parse producing a typed `lane_signal` (like board's `matched_targets`), not a
  downstream substring gate. No new prefix classifier; no magic-number recency
  compare (the FSM state replaces it).
- N-of-M: no — one signal type, one FSM, one locus.
- Cap/cooldown/dedup/repair: **net removal** of the cursor scaffolding; no cap,
  no cooldown, no dedup pointer introduced.

## §7 Open questions

1. **Engagement key granularity.** Proposed: a per-conversation map keyed by
   board-post / lane-thread id (mirrors `pending_board_event`'s per-post
   tracking, and matches the human model of being pulled into several threads).
   Alternatives: a single per-keeper `engagement`, or per-speaker. Confirm the
   per-conversation map.
2. **Persistence locus and size.** The `conversation_key -> engagement` map
   lives in `keeper_meta` (typed, serialized with the rest of meta). This is
   state, not a cursor (§2.6 distinguishes a typed lifecycle from a numeric
   pointer), but its growth needs a bound — proposal: prune `Disengaged`/
   `Acknowledged` entries older than the lane tail window. Confirm the prune
   rule (this is the one place a bound is introduced; it is a GC of dead state,
   not a cap on behavior).
3. **Unify board into the same FSM?** `pending_board_event` is a parallel
   typed-event path with its own cursor policy
   (`collect_board_events_with_cursor_policy`,
   `keeper_world_observation.ml:221` **(verified)**). A larger follow-up could
   fold board posts into the same engagement FSM so posts and lane lines share
   one attention model (and board sheds its cursor too). Out of scope here;
   flagged so the two paths converge rather than drift.

## §8 Silence / starvation analysis

The danger of adding a salience gate is the inverse of the herd: a keeper that
should react goes quiet. This section enumerates the failure modes and the
design rule that closes each.

### 8.1 Baseline guarantee — this RFC cannot wake less than today

Today a keeper wakes via registry-wide `wakeup_all` (content-free) and the live
reactive discriminator is `pending_board_events`; `pending_mentions` /
`pending_scope_messages` are stubbed empty and contribute nothing. The
post-action guard ORs the three independently (`keeper_turn_helpers.ml:155-156`
**(verified)**). This RFC fills the mention/scope producer **additively** — it
does not touch `wakeup_all` or the board path. So a buggy FSM degrades to
today's behavior (silent on mentions), never below it. There is no path by
which this RFC removes a wake that exists today.

### 8.2 Transition traps and their rules

| # | Trap | Direction | Rule that closes it |
|---|------|-----------|---------------------|
| 1 | `Keeper_responded` acknowledges a mention in a different conversation | silence | `Keeper_responded` carries a `conversation_key`; it advances only that key's engagement. A keyless/coarse ack is forbidden. |
| 2 | idle or the §7.2 prune removes an `Addressed` entry | silence | `Addressed` is non-terminal. `Conversation_idle` and prune act only on `Acknowledged` / `Disengaged`. `Addressed → Disengaged` is not a legal transition. |
| 3 | a follow-up with no `@mention` after `Acknowledged` stays quiet | silence | `Scope_message` (not only `Direct_mention`) re-addresses `Acknowledged → Addressed`. Residual risk: a bare follow-up outside scope — flagged, not silently assumed solved. |
| 4 | mention parse miss (nickname/format) → `Ambient` | silence (= today) | board path stays live; degrades to today, not a regression. Parser test fixtures (§4 P1) bound this. |
| 5 | `conversation_key` mismatch so ack never lands | noise (keeps waking) | opposite direction — surfaces as re-fire, caught by `AcknowledgedNeverReReacts`, not a silence bug. |

### 8.3 Where silence risk actually concentrates (and why it is deferred)

The research goal of cutting the herd means eventually gating `wakeup_all` on
relevance — i.e. *replacing* a content-free wake with the FSM. That change can
silence a keeper if the FSM is wrong, and it is **not in this RFC**. It must be
its own RFC, gated on the §8.2 rules holding and the §4 P3 silence invariant
(`AddressedNeverSilentlyDropped`) passing TLA+. Keeping additive salience
(RFC-0230) separate from wake replacement is the boundary that prevents the
silence side effect from shipping unproven.
