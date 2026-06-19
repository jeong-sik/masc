---
rfc: "0233"
title: "Typed turn observability: TurnRecord prompt-block provenance + canonical tool execution identity"
status: Draft
created: 2026-06-12
updated: 2026-06-19
author: vincent
supersedes: []
superseded_by: null
related: ["0225", "0230", "0231", "0252"]
implementation_prs: ["20968", "20975", "20985", "20995", "21000"]
---

# RFC-0233: TurnRecord + canonical execution identity

Status: Draft · One tool execution must have one identity across every
store and every view · A turn's assembled prompt must be recorded as
typed blocks so consecutive turns are diffable.
Drafted by: Claude (Fable 5), from the 2026-06-12 keeper pipeline
diagnosis session (issues #20907–#20910).

> Anchors marked **(verified)** were read against `origin/main`
> (`589f8b560`) or live runtime stores on 2026-06-12.

---

## §1 Problem

### §1.1 One execution, three stores, three id vocabularies

A single `keeper_memory_search` call by keeper `sangsu` produced, in the
same second:

| Store | Record shape | Identity carried |
|---|---|---|
| `trajectories/<keeper>/<trace>.jsonl` | `{"turn":0,"round":4,"tool_name":...,"args":...}` **(verified)** | turn-relative `turn`/`round` |
| `tool_calls/<YYYY-MM>/<DD>.jsonl` | full input/output + `runtime_contract.keeper_turn_id:718`, `trace_id`, `session_id` **(verified)** | absolute keeper turn + session |
| `logs/system_log_<date>.jsonl` | `oas:tool_called` / `oas:tool_completed` pair, `correlation_id`, `run_id`, `turn:null` **(verified)** | OAS correlation ids |

No field is shared across all three. The dashboard session-trace
interleaves at least two of these sources and renders the same physical
execution as two activity rows — `T${event.turn}R${event.round}`
(`dashboard/src/components/session-trace/session-trace-entry.ts:776`
**(verified)**) next to an absolute-turn row carrying the session id.
Operators read this as double execution (issue #20910).

Any view-side dedup (matching on tool name + args + timestamp) would be
read-side repair — the workaround class this repo rejects
(CLAUDE.md §워크어라운드, RFC-0042 precedent). The root is that no
identity is minted at the execution boundary.

### §1.2 The assembled prompt is not recorded anywhere

`keeper_run_tools_hooks.ml` assembles `extra_system_context` as an
append chain — dynamic context, temporal summary, claimed-task nudge,
retry nudge, memory-os recall **(verified)** — and
`build_keeper_system_prompt` renders persona fields per turn. None of
this is persisted per turn. Execution receipts carry only
`extra_system_context_digest` and sizes
(`lib/keeper/keeper_agent_run_receipt.ml:121-123` **(verified)**) — a
digest can prove *change* but cannot show *what changed*.

Consequences observed in the diagnosis session:

- Operators cannot answer "which instruction blocks entered or left this
  turn's context" (issue trail: persona tone drift, post-idle amnesia —
  the mechanism was only reconstructable by reading source).
- Sampling options (model profile, temperature, thinking budget) are
  scattered: `runtime_profile` lives in `runtime_contract` per tool
  call, not per turn; temperature is not recorded at all.
- `keeper_context_status` computes ratio/tokens correctly but its
  output is blob-wrapped above the inline threshold and the dashboard
  shows a ~200-byte preview **(verified)** — there is no turn-level
  surface to read these values from instead.

## §2 Design

### §2.1 Canonical execution identity

Mint `execution_id` exactly once, at the masc dispatch boundary where a
keeper tool call enters execution (the same site that today stamps
`runtime_contract` / writes `tool_calls`). Type, not string-passing
convention:

```ocaml
module Execution_id : sig
  type t
  val mint : unit -> t            (* uuid-v7; sortable *)
  val to_string : t -> string
  val of_string : string -> t option
end
```

Propagation:

- `tool_calls` store: new `execution_id` field.
- trajectory writer: same field; `turn`/`round` stay as display
  attributes.
- OAS event bridge: masc already owns the consumer that turns OAS
  stream events into `oas:tool_called`/`oas:tool_completed` log rows;
  that consumer joins on the in-flight execution (it is masc-side, so
  no OAS API change — OAS stays masc-agnostic per the boundary rule).
- dashboard: one row per `execution_id`; turn-relative and absolute
  labels become attributes of that row, not separate rows.

### §2.2 TurnRecord — typed prompt-block provenance

One record per keeper turn, written at the same point that already
writes the execution receipt:

```ocaml
type prompt_block =
  { block : Prompt_block_id.t   (* closed variant — see below *)
  ; bytes : int
  ; digest : string             (* sha256 of block text *)
  }

type turn_record =
  { execution_ids : Execution_id.t list   (* tool calls in this turn *)
  ; keeper : string
  ; trace_id : string
  ; absolute_turn : int
  ; blocks : prompt_block list            (* assembly order *)
  ; runtime_profile : string
  ; sampling : { temperature : float option
               ; thinking_budget : int option
               ; enable_thinking : bool option }
  ; usage : { input_tokens : int option; output_tokens : int option }
  ; ts : float
  }
```

`Prompt_block_id.t` is a closed sum mirroring today's real assembly
chain in `keeper_run_tools_hooks.ml` and `keeper_prompt.ml`
**(verified)**: `Persona | Continuity | Dynamic_context |
Temporal_summary | Claimed_task_nudge | Retry_nudge | Memory_os_recall
| Connected_surface | Other of string` — adding a new injection site
without extending the variant is a compile-time error at the record
site, which is exactly the leverage that keeps the record honest.

Diffing two consecutive TurnRecords by `(block, digest)` answers the
operator question directly: which blocks appeared, disappeared, or
changed size between turns. Block *text* is not duplicated into the
record; digests join against the existing prompt/receipt stores.

### §2.3 Views derive; no view-side repair

- Dashboard turn inspector reads TurnRecord (blocks, sampling, usage)
  and renders block-diff between turns.
- OTel: per-turn span gets `masc.turn.blocks`, `masc.turn.profile`,
  `masc.execution_id` attributes from the same record.
- `keeper_context_status` gains nothing new to compute — but its
  blob-preview display problem disappears for operators because the
  turn inspector becomes the primary surface for ratio/usage. The blob
  resolve endpoint fix in the dashboard remains a separate small PR
  under #20910.

## §3 Non-goals

- No new telemetry pipeline or transport — TurnRecord is one JSONL
  store next to the existing receipt store; views read it.
- No OAS API change. The execution-id join happens in masc's own event
  consumer. OAS continues to know nothing about MASC.
- No backfill of historical stores; old rows render as today.
- No prompt-text duplication into TurnRecord (digests only).

## §4 Migration

1. PR-1: `Execution_id` + stamp at dispatch + `tool_calls` and
   trajectory fields (additive, old readers unaffected).
2. PR-2: OAS event consumer join + dashboard single-row render keyed by
   `execution_id` (closes the #20910 double-row symptom at the root).
3. PR-3: `Prompt_block_id` + TurnRecord writer at receipt site.
4. PR-4: dashboard turn inspector (block diff) + OTel span attributes.

Each PR lands with its harness (below); none is operable as a silent
cap/dedup — if the id is missing, writers fail loudly in dev builds.

## §5 Verification harness

- Unit: minting uniqueness/sortability; `Prompt_block_id` round-trip;
  TurnRecord codec.
- Behavioral: drive one fake tool execution through dispatch → assert
  exactly one `execution_id` appears in tool_calls + trajectory + the
  oas-event rows for that call (no orphan, no dup).
- Dashboard: session-trace fixture with all three sources for one
  execution → exactly one rendered row.
- Block-diff: two synthetic TurnRecords → diff yields the exact
  added/removed block set (the "what entered/left context" question as
  a test).

## §6 Evidence trail

Diagnosis session 2026-06-12 (issues #20907 #20908 #20909 #20910):
duplicate rows and id vocabularies verified against live stores under
the runtime base path (`tool_calls/2026-06/12.jsonl`,
`trajectories/sangsu/trace-1780648779957-00000.jsonl`,
`logs/system_log_2026-06-12.jsonl`); dashboard render site
`session-trace-entry.ts:776`; receipt digest fields
`keeper_agent_run_receipt.ml:121-123`; context assembly chain
`keeper_run_tools_hooks.ml` (dynamic/temporal/nudge/retry/recall).

Ledger note: this RFC advances `.next-number` 0231→0234 in one commit —
0231 and 0232 were de-facto allocated by the Memory OS series
(implementation merged via #20876/#20881/#20883/#20897) and the typed
lane event model (doc PR #20877, implementation merged via #20896)
without ledger advancement; skipping past both heals the drift without
renumbering shipped references.

---

## §7 Amendment (2026-06-19) — `Turn_ref`: chat ↔ board turn-identity reference

> Base RFC (§1–§6) is implemented and merged (2026-06-12): PR-1 #20968,
> PR-2a #20975, PR-2b #20985, PR-3 #20995, PR-4 #21000. The front-matter
> `status: Draft` predates those merges and should be reconciled by the
> author. This amendment extends that identity work to the chat and board
> surfaces; it is **Proposed** (not yet implemented). Drafted 2026-06-19
> from the keeper-v2 "Keeper Agent v2" design hand-off (claude.ai/design
> project `v2`, file `keeper-v2/Keeper Agent v2.html`). Linkage precedent:
> RFC-0252 (fusion panel/judge → board post → chat block).

### §7.1 Problem — the turn identity is minted but never reaches chat or board

§2 gave one keeper turn a real composite identity, `(trace_id,
absolute_turn)`, recorded on `Turn_record.t` (`lib/types/turn_record.mli:32-41`
**(verified 2026-06-19)**) and materialized every turn at
`lib/keeper/keeper_agent_run.ml:250-251` (`trace_id =
Keeper_id.Trace_id.to_string meta.runtime.trace_id`; `absolute_turn =
usage.total_turns + 1`) **(verified)**. That identity stops at the
TurnRecord observability store. It is never threaded onto the two surfaces
operators navigate between — the keeper **chat** and the **board**:

| Layer | turn identity today | state |
|---|---|---|
| MASC turn record (§2.2) | `(trace_id, absolute_turn)` | present, isolated |
| MASC chat persist | none — `chat_message` carries a per-message `msg-…` id + typed `surface : Surface_ref.t`, no turn id. The reply payload omits the turn id: `lib/keeper/keeper_turn.ml:927-965` **(verified)** emits `reply/outcome/model/turns/usage` only. | **broken (root)** |
| MASC board post | none — `board_types` post has no originating-turn field; fusion alone smuggles `run_id` through untyped `meta_json`. | broken |
| dashboard API | `/chat/history` carries no turn id; `TurnRecordEntry` is a disjoint feed with no shared wire key. | broken |
| FE chat / turn inspector | matches a turn to a message by a 30-min timestamp window (`dashboard/src/components/keeper-turn-inspector.ts` **(verified 2026-06-19)**); the keeper-v2 prototype fabricates `traceId = 'trc_' + keeper.id + message.id.slice(-4)`. | broken |
| FE board → chat | `author` (keeper) level only (`navigateToAuthor`); no turn anchor. chat → board exists for fusion only (post-level, one-way). | broken / partial |

Root: the turn id is dropped at the chat-persist producer→consumer seam
(`keeper_turn.ml:927-965`). Everything above it has a real id; everything
below has nothing to join on, so the board↔chat-turn link the keeper-v2
design assumes is visual-only (`docs/design/keeper-v2-v12-gap-current.md`,
final gap item).

### §7.2 Design — one canonical `Turn_ref`, minted MASC-side, carried to chat and board

**Turn_ref.** A new module in `lib/types/ids.ml`, beside §2.1 `Execution_id`:

```ocaml
module Turn_ref : sig
  type t
  val make : trace_id:string -> absolute_turn:int -> t
  val to_string : t -> string          (* "<trace_id>#<absolute_turn>" *)
  val of_string : string -> t option   (* total; None on malformed, no repair *)
  val trace_id : t -> string
  val absolute_turn : t -> int
end
```

- Serialization `"<trace_id>#<absolute_turn>"` is **derived deterministically**
  from the pair §2.2 already records, so it joins against `Turn_record.t`
  with no new mapping table and is reproducible across reloads. Not a fresh
  UUID.
- Named `turn_ref`, not `turn_id`: `turn_id` is already the `int` FSM turn
  counter (`keeper_turn_fsm`); reusing the token invites a collision. The
  legacy `Ids.Turn_id` (`<thread>-turn-N`, `ids.ml:132`) is effectively
  unused for keeper turns and is **not** repurposed.

**Flow** (mint once at the turn boundary, thread down — never re-derive
downstream):

1. Mint at `keeper_agent_run.ml:251`, where `trace_id` + `absolute_turn`
   already exist.
2. Stamp `turn_ref` on `Turn_record.t`.
3. Emit `trace_id` + `turn_ref` in the reply payload (`keeper_turn.ml:945`,
   `gate_protocol.ml`) — this closes the root seam.
4. `extract_visible_reply` returns `turn_ref`; chat-store `append_*` accepts
   `?turn_ref` and persists it on **every** row of the turn (user / tool /
   assistant); `to_json_array` and the `keeper_chat_appended` SSE emit it.
5. board post gains a typed `origin`; keeper-originated posts carry the turn
   that produced them.
6. dashboard API + FE carry `turn_ref` read-only for navigation.

**Board `origin`.** Replace the fusion `meta_json` smuggle with a typed
field on the board post record:

```ocaml
type post_origin =
  { turn_ref : Ids.Turn_ref.t
  ; source : Surface_ref.t option   (* the channel the turn entered through *)
  ; fusion_run_id : string option   (* set for fusion posts; distinct from turn_ref *)
  }
(* board post record: + origin : post_origin option *)
```

threaded through the `create_post` dispatch boundary
(`mcp_tool_runtime_board.ml:203-228`) beside `agent_name`, serialized in
`post_to_yojson`, with a real `find_post_by_turn_ref` / `find_post_by_run_id`
index — never a `meta_json` substring scan.

**Fusion migration.** Today `Keeper_chat_blocks.fusion_block = {
board_post_id; run_id }` (`lib/keeper/keeper_chat_blocks.mli` **(verified)**)
and `fusion_sink` creates the board post first to obtain `post.id`, then
attaches the chat block (the reusable bidirectional handshake, RFC-0252 §8).
Extend the block to also carry the originating `turn_ref`, set
`post.origin.{turn_ref; fusion_run_id = run_id}`, and keep RFC-0252 §8 as the
visibility layer. `run_id` stays a distinct run-correlation id; it is **not**
collapsed into `turn_ref`.

**Bidirectional navigation contract.**

- board post → exact chat turn: `origin.turn_ref` anchors the chat surface to
  that turn (scroll/highlight), superseding the keeper-level `navigateToAuthor`.
- chat turn → board post(s): fusion today; then state-block lifecycle and
  keeper-authored posts as they gain `origin`.

### §7.3 Boundary invariant (unchanged from §3)

OAS owns the run/turn lifecycle and stays MASC-agnostic. OAS exposes no
first-class per-turn id — only `(worker_run_id : string, turn : int)` on the
event bus / `last_raw_trace_run` (**verified 2026-06-19**: `run()` does not
return the run id). MASC joins that pair MASC-side and mints `Turn_ref`. No
MASC concept (`turn_ref`, channel) crosses into OAS. The channel axis is
`Surface_ref.t` (`lib/keeper/surface_ref.ml`: `Dashboard | Discord | Slack |
Github | Webhook | Agent | Gate`). The keeper-v2 prototype's `imessage`
source has no first-class variant today — it rides `Gate { label =
"imessage" }`, or gains an `IMessage` variant as a closed-sum extension
(total decode preserved) if it becomes a primary channel. **Decision
deferred** to whoever wires the iMessage gate.

### §7.4 Non-goals

- No OAS API change (per §3).
- No backfill: legacy chat rows / posts decode `turn_ref = None`; the FE
  30-min window survives only as an explicit, commented, removal-targeted
  fallback for `None` rows.
- `turn_ref` does not replace `Execution_id` (tool-call identity) or fusion
  `run_id` (run correlation); it is the turn-level join key between them.

### §7.5 Migration (Proposed)

Dependency-ordered. Each builds fully (`dune build --root .`) so a
shared-record field addition catches every literal construction site (per the
foundational-record-field rule).

1. **Amendment PR-A** (RFC-gated, largest blast radius): `Ids.Turn_ref` +
   mint at `keeper_agent_run.ml:251` + `Turn_record.t` field + reply-payload
   `trace_id`/`turn_ref` + `extract_visible_reply` + chat-store `?turn_ref`
   on all append sites + `to_json_array` + SSE.
2. **Amendment PR-B** (RFC-gated, needs A): board `origin` typed field +
   dispatch-boundary / `create_post` threading + fusion populate +
   `find_post_by_turn_ref` / `find_post_by_run_id` index.
3. **Amendment PR-C** (additive, low risk): dashboard API `turn_ref?` on
   `KeeperChatHistoryMessage` + SSE; `origin?` on `BoardPost` + normalize.
   Passes the chat-block 3-gate (backend union → zod → `normalizeBlocks`).
4. **Amendment PR-D** (FE-only): carry `turnRef` onto
   `KeeperConversationEntry`, remove the prototype `buildTurn()` `trc_`
   fabrication, turn inspector matches by exact `(trace_id, absolute_turn)`,
   add board→turn / chat→board nav actions.

### §7.6 Workaround guards (rejected per CLAUDE.md §워크어라운드)

1. Client-side derived turn id (the prototype's `buildTurn` `trc_…`) —
   render-time fabrication; collides and is non-deterministic across reloads.
   → backend-minted `Turn_ref` only.
2. `run_id` / `meta_json` substring or prefix match (`starts_with "fus-"`) —
   the RFC-0042 string-classifier anti-pattern. → typed `origin` + real index.
3. 30-min timestamp-window join (already in `keeper-turn-inspector.ts`) — a
   heuristic standing in for a missing key; mis-attributes under dense/sparse
   turns or clock skew. → exact `(trace_id, absolute_turn)` join; keep the
   window only as a commented, removal-targeted fallback for legacy
   `turn_ref = None` rows.
4. Telemetry-as-fix ("count chat rows missing turn_ref") — a counter is a
   backfill metric, not a fix. → propagate the id so new rows never miss it.
5. Collapsing `run_id` into `turn_ref` — distinct typed concepts (run
   correlation vs turn identity). → keep both in `origin`.
6. N-of-M migration (patch the dashboard append site, leave
   discord/slack/voice/gate/fusion on `_ -> None`) → thread `turn_ref`
   through all append sites in PR-A, or make it a required argument so the
   compiler forces every site.

### §7.7 Verification harness

- Unit: `Turn_ref` `to_string`/`of_string` round-trip; `of_string` returns
  `None` on malformed input (no repair).
- Behavioral: drive one keeper turn → assert the same `turn_ref` appears on
  the TurnRecord, on every chat row of that turn, and (for a fusion turn) on
  the board post's `origin`.
- API: `/chat/history` and `BoardPost` JSON carry `turn_ref` / `origin` for
  new rows and `null`/absent for legacy rows.
- FE: turn inspector opens the correct turn by id (not by window) given
  `turn_ref`; a board post navigates to its anchored chat turn and back.
  tsc + vitest, including a board↔chat navigation test.
