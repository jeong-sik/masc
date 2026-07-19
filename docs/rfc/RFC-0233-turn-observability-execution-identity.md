---
rfc: "0233"
title: "Typed turn observability: TurnRecord prompt-block provenance + canonical tool execution identity"
status: Draft
created: 2026-06-12
updated: 2026-07-19
author: vincent
supersedes: []
superseded_by: null
related: ["0225", "0230", "0231", "0252"]
implementation_prs: ["20968", "20975", "20985", "20995", "21000", "25184"]
---

# RFC-0233: TurnRecord + canonical execution identity

Status: Draft · One MASC tool execution has one typed identity across the
MASC tool-call store and canonical Keeper trajectory · OAS invocation
metadata remains exact OAS evidence, never a surrogate MASC identity · A
turn's assembled prompt is recorded as typed blocks so consecutive turns are
diffable.
Drafted by: Claude (Fable 5), from the 2026-06-12 keeper pipeline
diagnosis session (issues #20907–#20910).

> Anchors marked **(verified)** were read against `origin/main`
> (`589f8b560`) or live runtime stores on 2026-06-12.
> The hard-cut contract in §1.1–§6 was re-verified against PR #25184 on
> 2026-07-19; the older anchor records only the original diagnosis.

---

## §1 Problem

### §1.1 Two ownership domains, no cross-domain synthetic join

The current contract deliberately distinguishes MASC execution identity from
OAS invocation evidence:

| Store | Canonical fields | Authority |
|---|---|---|
| `.masc/keepers/<keeper>/trajectories/v1/<trace>.jsonl` | `execution_id`, `keeper_turn_id`, `oas_turn`, exact `schedule`, `tool_use_id` | MASC Keeper observation of one OAS invocation |
| `.masc/tool_calls/<YYYY-MM>/<DD>.jsonl` | full input/output, `execution_id`, `runtime_contract.keeper_turn_id`, `trace_id`, `session_id` | MASC dispatch/effect audit |
| OAS event projection | `turn`, exact `schedule`, `tool_use_id`, OAS correlation/run fields | OAS lifecycle evidence projected by MASC |

The concrete producer/codec anchors are
`lib/trajectory/trajectory.ml:139`, `lib/trajectory/trajectory.ml:307`,
`lib/trajectory/trajectory.ml:698`, `lib/keeper/keeper_hooks_oas.ml:541`, and
`lib/types/turn_record.ml:86` (verified 2026-07-19).

```text
MASC: execution_id  ->  tool_calls <-> canonical Keeper trajectory
OAS:  Invocation    ->  turn + schedule + tool_use_id (exact evidence)
```

`execution_id` is the typed foreign key shared by the two MASC stores. The OAS
event bridge does not stamp that key: OAS stays MASC-agnostic, and MASC does not
maintain a global join table keyed by provider `tool_use_id`.

`tool_use_id` is exact provider/OAS correlation evidence. It is required on
the wire but may be blank or repeated, so it is never an identity or join key.
Matching on tool name, arguments, timestamps, array position, or
`tool_use_id` would be read-side repair and is forbidden.

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

### §2.1 Canonical MASC execution identity and exact OAS schedule

Mint `execution_id` exactly once, at the masc dispatch boundary where a
keeper tool call enters execution (the same site that today stamps
`runtime_contract` / writes `tool_calls`). Type, not string-passing
convention:

```ocaml
module Execution_id : sig
  type t
  val generate : unit -> t        (* exec-<milliseconds>-<sequence> *)
  val to_string : t -> string
  val of_string : string -> t
end
```

Propagation:

- `tool_calls` store: typed `execution_id` minted at the MASC dispatch
  boundary.
- canonical Keeper trajectory: the same `execution_id`, plus the exact
  `Agent_sdk.Tool.Invocation.t` coordinates supplied by OAS.
- OAS event projection: exact invocation fields only. It does not consume or
  copy a MASC `execution_id`.
- dashboard: the canonical trajectory row may be enriched from tool-call log
  data only by exact `execution_id`. An unmatched source remains an explicit
  provenance gap; it is not silently dropped or synthesized.

The canonical tool row is a closed wire record:

```json
{
  "schema": "masc.keeper_trajectory.v1",
  "type": "tool_call",
  "ts": 123.0,
  "ts_iso": "2026-07-19T00:00:00Z",
  "keeper_turn_id": 412,
  "oas_turn": 0,
  "schedule": {
    "planned_index": 0,
    "batch_index": 0,
    "batch_size": 2,
    "execution_mode": "concurrent"
  },
  "tool_use_id": "",
  "tool_name": "Execute",
  "args": {},
  "outcome": { "status": "succeeded", "output": "..." },
  "duration_ms": 17,
  "execution_id": "exec-..."
}
```

Validation is field-local and exact:

- `keeper_turn_id > 0`, `oas_turn >= 0`;
- `planned_index >= 0`, `batch_index >= 0`, `batch_size > 0`;
- `execution_mode` uses the OAS closed codec;
- `tool_use_id` is a required string; blank and repeated values are valid;
- no cross-row inference adds constraints that OAS does not define.

There is no allocator beside OAS scheduling metadata. `planned_index`,
`batch_index`, `batch_size`, and `execution_mode` are observations, not MASC
policy or retry gates.

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
  { keeper : string
  ; trace_id : string
  ; absolute_turn : int
  ; turn_ref : Turn_ref.t option
  ; blocks : prompt_block list            (* assembly order *)
  ; runtime_profile : string
  ; model : string option
  ; finish_reason : string option
  ; context_window : int option
  ; price_input_per_million : float option
  ; price_output_per_million : float option
  ; request_latency_ms : int option
  ; ttfrc_ms : float option
  ; sampling : { temperature : float option
               ; top_p : float option
               ; max_tokens : int option
               ; thinking_budget : int option
               ; enable_thinking : bool option }
  ; usage : { input_tokens : int option; output_tokens : int option }
  ; ts : float
  }
```

TurnRecord does not copy per-tool execution identifiers. Its exact turn-range
coordinate is `(trace_id, absolute_turn)` / `turn_ref`; canonical tool rows
carry `keeper_turn_id` and remain queryable from the trajectory store. Keeping
an execution-id array in both records would make TurnRecord a second source of
tool membership and allow the two stores to diverge.

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
  and renders block-diff between turns. Tool detail comes from canonical
  trajectory rows for the exact Keeper turn, not a copied TurnRecord list.
- OTel: per-turn span gets turn-level block/profile attributes. Tool execution
  identity remains on the individual dispatch/tool span.
- `keeper_context_status` gains nothing new to compute — but its
  blob-preview display problem disappears for operators because the
  turn inspector becomes the primary surface for ratio/usage. The blob
  resolve endpoint fix in the dashboard remains a separate small PR
  under #20910.

## §3 Non-goals

- No new telemetry pipeline or transport — TurnRecord is one JSONL
  store next to the existing receipt store; views read it.
- No OAS API change. OAS continues to know nothing about MASC.
- No MASC identity injection into OAS events and no join by
  `tool_use_id`/name/arguments/timestamp.
- No decode, migration, or backfill from the retired
  `.masc/trajectories/...` archive. It remains raw, untouched data and is not a
  live input.
- No prompt-text duplication into TurnRecord (digests only).

## §4 Hard cut

1. Delete the independent call-order allocator and every direct trajectory
   append fallback. Only OAS `Invocation.turn + Invocation.schedule` provides
   occurrence coordinates.
2. Write and decode only `masc.keeper_trajectory.v1` under
   `.masc/keepers/<keeper>/trajectories/v1/<trace>.jsonl`; reject missing,
   duplicate, unexpected, and invalid fields explicitly.
3. Delete TurnRecord tool-membership duplication. A retired
   `execution_ids` field is an unexpected field, not a compatibility input.
4. Runtime MCP dispatch without an OAS Invocation does not fabricate a
   canonical Keeper trajectory row. Its tool-call audit and SSE observations
   remain in their own stores.
5. Render hierarchy as Keeper turn → OAS turn → schedule batch, with
   `planned_index` as presentation ordering metadata. No display label invents
   a second occurrence coordinate.

## §5 Verification harness

- Unit: minting uniqueness/sortability; `Prompt_block_id` round-trip;
  TurnRecord codec.
- Behavioral: drive one fake OAS invocation through dispatch → assert the
  same typed `execution_id` appears in tool_calls + canonical trajectory, and
  the exact invocation schedule is preserved.
- Boundary: bridge OAS events with blank/repeated `tool_use_id` → assert exact
  projection and absence of a fabricated MASC `execution_id`.
- Codec: missing/duplicate/unexpected fields, invalid schedule values, and an
  unknown execution mode are explicit row-local failures.
- Dashboard: canonical trajectory + matching tool-call fixture → one enriched
  row; an unmatched source → one explicit provenance gap.
- Runtime MCP: dispatch without an OAS Invocation → zero canonical Keeper
  trajectory rows.
- Block-diff: two synthetic TurnRecords → diff yields the exact
  added/removed block set (the "what entered/left context" question as
  a test).

## §6 Evidence trail

Diagnosis session 2026-06-12 (issues #20907 #20908 #20909 #20910)
established that multiple stores lacked a safe shared identity and that the
dashboard was treating source-local ordering metadata as identity. The
2026-07-19 hard cut narrows the shared identity to the two MASC-owned execution
stores, preserves OAS invocation fields exactly, and rejects heuristic joins.
Receipt digest fields remain in `keeper_agent_run_receipt.ml`; the context
assembly chain remains in `keeper_run_tools_hooks.ml`.

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
> surfaces. Its exact `turn_ref` propagation is implemented; the current
> contract is a hard cut with no timestamp or legacy-row recovery. Drafted 2026-06-19
> from the keeper-v2 "Keeper Agent v2" design hand-off (claude.ai/design
> project `v2`, file `keeper-v2/Keeper Agent v2.html`). Linkage precedent:
> RFC-0252 (fusion panel/judge → board post → chat block).

### §7.1 Historical root cause — turn identity stopped before chat and board

Before §7 was implemented, §2 gave one keeper turn a real composite identity, `(trace_id,
absolute_turn)`, recorded on `Turn_record.t` (`lib/types/turn_record.mli:32-41`
**(verified 2026-06-19)**) and materialized every turn at
`lib/keeper/keeper_agent_run.ml:250-251` (`trace_id =
Keeper_id.Trace_id.to_string meta.runtime.trace_id`; `absolute_turn =
usage.total_turns + 1`) **(verified)**. That identity stopped at the
TurnRecord observability store. It was not threaded onto the two surfaces
operators navigate between — the keeper **chat** and the **board**:

| Layer | current turn identity | state |
|---|---|---|
| MASC turn record (§2.2) | required typed `turn_ref`, validated against `(trace_id, absolute_turn)` | exact |
| MASC chat persist | Keeper-turn replies carry the same `turn_ref`; out-of-turn rows remain explicitly unlinked | exact when linked |
| MASC board post | typed `origin.turn_ref` when the post originates from a Keeper turn | exact when linked |
| dashboard API | TurnRecord and transcript surfaces carry the persisted `turn_ref` unchanged | exact |
| FE chat / turn inspector | opaque `turn_ref` equality only; no parsing, reconstruction, or timestamp window | exact |
| FE board → chat | `origin.turn_ref` opens the precise retained TurnRecord; absence exposes no inferred link | exact when linked |

Historical root: the turn id was dropped at the chat-persist producer→consumer seam
(`keeper_turn.ml:927-965`). Everything above it had a real id; everything
below had nothing to join on, so the board↔chat-turn link the keeper-v2
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
- chat turn → board post(s): fusion today; then typed board workflow events
  and keeper-authored posts as they gain `origin`.

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
- No backfill or compatibility decoder. A TurnRecord without `turn_ref` is
  invalid and counted as such. Chat rows/posts without a typed origin remain
  explicitly unlinked; the frontend does not infer one from time or text.
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
3. 30-min timestamp-window join (removed from `keeper-turn-inspector.ts`) — a
   heuristic standing in for a missing key; mis-attributes under dense/sparse
   turns or clock skew. → exact opaque `turn_ref` equality only; rows without
   the key are invalid/unlinked and are never revived.
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

## §8 Amendment (2026-06-21) — runtime model metadata: context window + pricing

### §8.1 Problem — the dashboard fabricated the context window and the price

The turn inspector rendered a token-economy panel whose denominator and
price rates were hardcoded constants, not facts from the record:

- `keeper-turn-inspector.ts:628` computed `ctxPct = (tokIn / 200_000) * 100`
  — a hardcoded 200K denominator for every runtime.
- `keeper-turn-inspector.ts:629` computed `cost = (tokIn*3 + tokOut*15)/1e6`
  — hardcoded Claude Sonnet $3/$15 per million for every runtime.

The token counts themselves were already real (`usage.input_tokens` /
`output_tokens`), so the only fabricated values were the window and the
price. For a non-Claude runtime (e.g. `glm-coding.glm-5-turbo`) the panel
therefore showed a wrong ctx-fill% against an irrelevant 200K ceiling and a
cost against Claude rates. The data to fix this already lived in the
process: `Runtime.t.binding` retains `price_input`/`price_output`/`num_ctx`
(`lib/runtime/runtime.ml:19`, `lib/runtime/runtime_schema.mli:116-119`) in
the boot-populated `runtimes_ref` singleton, and the keeper's resolved
effective budget (`max_context`) is already in scope at the write site. The
record simply never stored them, forcing the view to fabricate — a
view-side-repair violation of §2.3.

### §8.2 Design — three option fields, populated from retained runtime facts

```ocaml
; context_window : int option
    (* keeper-resolved effective context budget — the ctx% denominator *)
; price_input_per_million : float option
    (* USD per 1M input tokens from the runtime binding *)
; price_output_per_million : float option
    (* USD per 1M output tokens from the runtime binding *)
```

- `context_window` is the `max_context` parameter at
  `lib/keeper/keeper_agent_run.ml:693` — the keeper compaction budget the
  turn actually operates against. Stored as `Some max_context`.
- The two prices come from `Runtime.pricing_of_runtime_id`
  (`lib/runtime/runtime.ml:386`): a sibling of the existing
  `max_context_of_runtime_id` / `thinking_support_of_runtime_id`
  projections, projecting `rt.binding.price_input` / `price_output` off the
  retained singleton via `get_runtime_by_id`. No new holder, no threading,
  no re-parse.
- All three are `option`: `None` when the runtime is unknown or the operator
  left the rates unset in runtime.toml. The view renders "미상" (unknown),
  never a fabricated value — the same absence contract `model` and
  `finish_reason` already follow (§2.3).
- Cost is **not** stored: the view derives it from `price_*_per_million ×
  real token counts`, per the views-derive principle (§2.3).

### §8.3 Boundary invariant (unchanged from §3)

No OAS change. MASC reads the runtime binding it already materialized at
boot (`Runtime.t.binding`); OAS's `Provider_runtime_binding` catalog — which
deliberately omits price ("OAS owns identity/capability, not pricing") — is
untouched. Price is MASC's operator-config concern, sourced from
runtime.toml.

### §8.4 Non-goals

- No backfill: legacy rows decode all three as `None`; the view renders
  "미상" for them.
- `context_window` is the **keeper compaction budget**, not the provider's
  per-request `num_ctx` cap. `num_ctx` is an Ollama-only transport detail
  (`oas/lib/llm_provider/backend_ollama.ml`: honored by Ollama only); the
  keeper resolver does not consult it, and conflating the two would mis-state
  the window for any Ollama binding where the operator set `num-ctx` below
  the model ceiling. For the current fleet (glm/deepseek/claude, none
  Ollama-bound) `max_context` is the effective window. A future wave that
  needs the provider-enforced cap should add a separate
  `provider_context_window` field rather than overload this one.
- No OAS `request_latency_ms` (phase duration) — that is a separate
  amendment (Wave 2b); this amendment is context window + pricing only.

### §8.5 Migration

Single PR, dependency-ordered. Each builds fully (`dune build --root .`) so
the shared-record field addition catches every literal construction site
(the compiler forces `writer.ml` + `test_turn_record.ml`).

1. **Type + codec** — `lib/types/turn_record.{mli,ml}`: three option fields
   on `t`; `to_json` via `opt_field`, `of_json` via `opt_member` (mirrors
   `model`/`finish_reason`/`temperature`).
2. **Runtime projection** — `lib/runtime/runtime.{ml,mli}`:
   `pricing_of_runtime_id : string -> float option * float option`, sibling
   to `max_context_of_runtime_id`.
3. **Writer + emit** — `lib/keeper/keeper_turn_record_writer.{ml,mli}`:
   three labeled args + record fields; `lib/keeper/keeper_agent_run.ml:693`
   binds `price_*` from `Runtime.pricing_of_runtime_id runtime_id_string`
   and passes `~context_window:(Some max_context)`.
4. **Dashboard API** — `lib/server/server_dashboard_http_keeper_api.ml:551`
   needs **no edit**: it serializes via `Turn_record.to_json`, so the new
   fields auto-flow.
5. **Frontend** — `dashboard/src/api/dashboard.ts`: `TurnRecordEntry` type +
   `decodeTurnRecordEntry` (hand-rolled decoder, no schema auto-pickup);
   `keeper-turn-inspector.ts`: `TurnDetail.ctxPct`/`cost` widen to
   `number | null`, compute from real `context_window`/prices, render "미상"
   when absent (replaces the Wave-1 "200K 가정" / "Claude 가격" labels).

### §8.6 Workaround guards (rejected per CLAUDE.md §워크어라운드)

1. Keeping the hardcoded 200K / Claude $3·$15 in the dashboard as "the fix"
   — the exact fabrication this amendment removes. → real runtime facts.
2. Storing a precomputed `cost_usd` number — collapses two facts (prices ×
   tokens) into one derived value at write time, losing the rates and
   blocking per-field absence rendering. → store price rates + token counts;
   derive cost in the view (§2.3).
3. Re-parsing runtime.toml per turn (the `fusion_config_loader` pattern) —
   diverges from the boot-validated config and parses a ~900-line file on
   the turn-record hot path. → read the retained `Runtime` singleton.
4. Threading price up from `runtime_adapter.binding_to_provider_config` —
   duplicates the SSOT already retained in the `Runtime` singleton (where
   price is read once as a boolean signal then discarded). →
   `pricing_of_runtime_id` projection.
5. Sourcing `context_window` from `binding.num_ctx` — conflates the keeper
   compaction budget with an Ollama-only transport KV-cache cap and would
   mis-state the window (see §8.4). → `max_context`.

### §8.7 Verification harness

- Unit (`test/test_turn_record.ml`): round-trip of all three new fields
  (`Some`); the absent case (`None`) omits the JSON keys and decodes `None`
  (no fabricated 200K / $3·$15 on the wire).
- Frontend (`dashboard/src/components/keeper-turn-inspector.test.ts`): a
  grounded fixture (real `context_window` + prices) renders a `$` cost and a
  `%` fill, not "미상" — guards the `number | null` widening.
- Behavioral: a `glm-coding.glm-5-turbo` turn (empty binding — no price set)
  records `context_window = Some <model max-context>` and `price_* = None`,
  so the inspector shows the real ctx% and "미상" cost; a turn on a priced
  runtime shows a real derived cost.
- FE: turn inspector opens the correct turn by id (not by window) given
  `turn_ref`; a board post navigates to its anchored chat turn and back.
  tsc + vitest, including a board↔chat navigation test.

## §9 Amendment (2026-06-22) — response-generation phase duration: `request_latency_ms`

### §9.1 Problem — the `gen` phase waterfall bar showed "측정 없음"

The turn inspector's phase waterfall assembles four phases per turn —
context assembly (`ctx`), thinking (`reason`), tool calls (`tool`), and
response generation (`gen`). Only the `tool` phase carried a measured
`duration_ms` (from `/api/v1/keepers/:name/tool-calls`). The other three
were hardcoded `durationMs: null, durationSource: 'not_recorded'`, and the
`gen` phase's own `meta` string declared *"provider/OAS duration is not
recorded in turn-records"*. So every keeper turn's response-generation bar
read "측정 없음" even though the provider call wall-clock was already
measured — it just never reached the record.

The measurement already exists in-process: the OAS `api_response.telemetry`
field carries `inference_telemetry.request_latency_ms`, and the transport
layer (`complete_common.patch_telemetry` non-streaming, `complete_stream`
streaming) synthesizes it for every provider, so it is populated whenever a
response was produced. `keeper_agent_result.ml:63` already retains that
telemetry as `inference_telemetry` (= `result.response.telemetry`,
`keeper_agent_run_finalize_response.ml:221`), exactly the source the keeper
hooks already consume (`keeper_hooks_oas.ml:417` reads
`t.request_latency_ms` off `response.telemetry`). The record simply never
stored it, forcing the `gen` phase to render "측정 없음" — a view-side-repair
violation of §2.3.

### §9.2 Design — one option field, populated from OAS transport telemetry

```ocaml
; request_latency_ms : int option
    (* wall-clock duration of the provider call in milliseconds *)
```

- Sourced at the write site (`lib/keeper/keeper_agent_run.ml`, next to the
  `usage` binding) via `Option.bind result.inference_telemetry (fun t ->
  t.request_latency_ms)`. `request_latency_ms` is itself `int option` in OAS
  (`oas/lib/llm_provider/types.mli:197`), and `inference_telemetry` is an
  outer `option`; `Option.bind` flattens the two layers rather than nesting
  option-of-option. On the error path (or before a response existed) the
  value is `None`.
- The view maps it onto the `gen` phase: `durationMs = request_latency_ms`,
  `durationSource = 'provider_telemetry'` (a new variant on the
  `TurnPhase.durationSource` union, distinct from `'tool_call_log'` so the
  tooltip names the real source). Absent → the existing `'not_recorded'` /
  "측정 없음" render is preserved. No fabrication.
- `ctx` and `reason` phases stay `'not_recorded'`: OAS `inference_telemetry`
  has no isolated measurement for context assembly or thinking, so mapping
  `request_latency_ms` onto them would mislabel the whole-call wall-clock.
  This is an honest limit, not a gap to paper over.

### §9.3 Boundary invariant (unchanged from §3)

No OAS change. MASC reads `inference_telemetry` it already receives in the
keeper turn result — the same consumption pattern as
`keeper_hooks_oas.ml:287/326/417`, `lib/runtime/dashboard_oas_bridge.ml`,
and `keeper_unified_turn_success.ml:253`. The telemetry record is an OAS
generic asset (`types.mli:325` docstring: *"Parsed from the raw API
response; never computed by downstream"*); `rg "MASC|masc|keeper"` in
`oas/lib/api.ml` / `types.ml` returns 0 hits, so `patch_telemetry` is OAS's
own transport pipeline, not MASC-requested code. Per
`docs/OAS-MASC-BOUNDARY.md:16,50,52`, MASC consuming a public OAS response
field is permitted; only adding MASC-specific code to OAS would not be.

### §9.4 Non-goals

- No phase-level split (`prefill_ms` / `ttfrc_ms` / `timings.{prompt_ms,
  predicted_ms}`). Those are provider-native: `timings` is reported by
  Ollama and llama-server only; `prefill_ms`/`ttfrc_ms` are wall-clock
  derived on the streaming path and `None` non-streaming. Emitting them now
  would show mostly-empty columns across the (predominantly cloud) keeper
  fleet rather than measured signal — a Wave-2c candidate once a keeper's
  runtime is known to populate them. `request_latency_ms` is the only field
  every provider reports.
- No derivation of `ctx`/`reason` durations by differencing
  `request_latency_ms` against tool durations — that would fabricate a
  measurement OAS does not provide (see §9.6).
- No backfill: legacy rows decode `request_latency_ms` as `None`; the `gen`
  phase renders "측정 없음" exactly as before.

### §9.5 Migration

Additive. `request_latency_ms` is a trailing optional field serialized only
when `Some`; the decoder reads it via `opt_member` (absent → `None`). The
writer gains one labeled argument (`~request_latency_ms`); the single call
site passes it. The dashboard `TurnRecordEntry` gains one optional field
and one `asNumber` decode line. The `gen` phase mapping and the new
`'provider_telemetry'` variant on `TurnPhase.durationSource` are the only
frontend logic changes (the `phaseDurationLabel` / `finalizePhaseOffsets`
consumers already key off `durationMs != null`, so they pick the measured
path automatically; only `phaseDurationTitle`'s switch gained an explicit
case).

### §9.6 Workaround guards (rejected per CLAUDE.md §워크어라운드)

1. Deriving a `ctx` or `reason` duration as
   `request_latency_ms − Σ tool durations` — constructs a measurement OAS
   never made; silent on multi-SDK-turn keeper turns where multiple provider
   calls occur. → leave those phases `'not_recorded'`.
2. Defaulting `request_latency_ms` to 0 (the `keeper_hooks_oas.ml:417`
   `Option.value ~default:0` pattern is for a tok/s log line, not a stored
   record) — would render a 0ms bar indistinguishable from a real fast call.
   → store `None`, render "측정 없음".
3. Collapsing all phase timing into a single `total_turn_ms` — loses the
   per-phase source attribution the waterfall exists to show. → one field,
   one phase.

### §9.7 Verification harness

- Unit (`test/test_turn_record.ml`): round-trip of `request_latency_ms`
  (`Some 1234`); the absent case (`None`) omits the JSON key and decodes
  `None` (no fabricated duration on the wire).
- Frontend: a grounded fixture (real `request_latency_ms`) renders a
  `formatMsCompact` label on the `gen` phase with the `'provider_telemetry'`
  tooltip, not "측정 없음"; an absent value still renders "측정 없음".
- Behavioral: a turn whose provider call was measured shows a real `gen`
  bar; an errored turn (no response) keeps `gen` as "측정 없음". tsc +
  vitest.

## §10 Amendment (2026-06-22) — time-to-first-token: `ttfrc_ms`

### §10.1 Problem

§9 wired the `gen` phase to `request_latency_ms` (end-to-end provider call
wall-clock), but the inspector still cannot distinguish *time-to-first-token*
— how long the user waited before the first response chunk appeared — from
the full generation duration. This is the half of latency users perceive
("why is it thinking before it starts typing?").

### §10.2 Design

Add `ttfrc_ms : float option` to `Turn_record.t`, sourced from OAS
`inference_telemetry.ttfrc_ms` (Time-To-First-Response-Chunk, wall-clock).
Unlike `request_latency_ms`, this isolates the wait for the first SSE chunk.
The inspector renders it alongside the `gen` phase's end-to-end duration
(`"1.2s · 첫 568ms"`), never as a fabricated split.

### §10.3 Provider fill matrix (grounding)

`ttfrc_ms` is the one phase-level signal populated across the keeper fleet:
the OAS streaming transport (`complete_stream.ml:573-574`) sets it as a
provider-agnostic wall-clock measurement as soon as the first SSE chunk
arrives. The keeper default fleet (deepseek-v4-flash / deepseek-v4-pro /
glm-4-7-coding / minimax-m3, all `openai-compatible-http` + `streaming`)
reports `Some` for every turn. Non-streaming turns and the error path leave
it `None`.

`prefill_ms` and `timings.{prompt_ms, predicted_ms}` remain deferred
(§9.4): only Ollama/llama-server report them natively, so emitting them
would show mostly-empty columns across the predominantly-cloud fleet.

### §10.4 Why a single field (B), not a phase split (A)

A full prefill/decode split (option A) was rejected by the grounding
workflow: cloud keepers do not populate `prefill_ms`/`timings`, so the
decode sub-phase would be `None` for the majority of turns. `ttfrc_ms` is
the only phase-level field the streaming transport fills for every
provider, so it alone carries fleet-wide signal. Option B (single field)
captures that signal at ~10 LOC without the empty-column cost.

### §10.5 Honesty guard (§9.6 reaffirmed)

The decode (post-first-chunk) duration is intentionally NOT derived as
`request_latency_ms - ttfrc_ms`. That difference would be indistinguishable
from a measurement yet is an arithmetic artifact; decode stays
`not_recorded` until a provider reports it natively. `ttfrc_ms` is shown as
a separate annotation, never subtracted into a phase bar.

### §10.6 Inspector wiring

`TurnPhase.ttfrcMs` (number | null, separate from `durationMs`). The `gen`
phase populates it from `record.ttfrc_ms`; `phaseDurationLabel` appends
`· 첫 {formatMsCompact(ttfrc)}` when both `request_latency_ms` and
`ttfrc_ms` are present; the `meta` tooltip notes both sources. Absent
`ttfrc_ms` leaves the `gen` label at its end-to-end form.

### §10.7 Verification harness

- Unit (`test/test_turn_record.ml`): round-trip of `ttfrc_ms`
  (`Some 567.8`); the absent case (`None`) omits the JSON key and decodes
  `None`.
- Frontend: a grounded fixture (`ttfrc_ms: 567.8`) renders `"첫 568ms"`
  alongside the `gen` phase duration; an absent value leaves the label
  unchanged. tsc + vitest.
