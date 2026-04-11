# OAS/MASC State Boundary: Agent State vs Domain State

Issue: #1736

> Status: historical audit + migration backlog
>
> Boundary contract SSOT lives in `/home/runner/work/masc-mcp/masc-mcp/docs/OAS-MASC-BOUNDARY.md`.
> Implementation status / open ledger lives in `/home/runner/work/masc-mcp/masc-mcp/docs/spec/13-oas-integration.md`.

## Related

- [Contract-Driven Agent Loop RFC](./contract-driven-agent-loop-rfc.md)
- [Labeling and Judging Protocol](./contract-driven-agent-loop-labeling-protocol.md)
- [Implementation Checklist](./contract-driven-agent-loop-implementation-checklist.md)
- [RFC Review Memo](./contract-driven-agent-loop-rfc-review.md)

## Principle

OAS manages **agent state** — the lifecycle of an individual agent or collaboration session.
MASC manages **domain state** — the coordination domain: rooms, tasks, governance, board posts, keeper profiles.

The boundary is the **tool call**: an agent (managed by OAS) invokes a domain tool (managed by MASC), which mutates domain state and returns a result. The agent incorporates that result into its own state. Neither side reaches into the other's storage.

```
                    tool call
  OAS Agent State ───────────> MASC Domain State
  (turns, messages,            (rooms, tasks, votes,
   memory, context,             governance, board,
   checkpoint, usage)           keeper profiles)
```

## 1. Agent State (belongs in OAS)

State that describes an agent's runtime, cognitive context, and operational lifecycle.

| Category | Data | Current Owner | Target Owner |
|----------|------|---------------|--------------|
| Turn count | `turn_count`, `total_turns` | **MASC** (`keeper_meta.runtime`, partial split) | OAS `Session.t` |
| Messages/history | `messages : message list` | **MASC** (`keeper_exec_context` / `working_context`) | OAS `Context.t` |
| Token usage | `total_input_tokens`, `total_output_tokens`, `total_tokens`, `total_cost_usd` | **MASC** (`keeper_meta.runtime`, partial split) | OAS `Session.t` or `Usage_tracker` |
| Context window | `token_count`, `max_tokens`, `importance_scores` | **MASC** (`keeper_exec_context` / `working_context`) | OAS `Context.t` |
| Checkpoint | `checkpoint_id`, `generation`, `serialized` | **MASC** (`keeper_exec_context`) | OAS `Checkpoint` |
| Memory (5-tier) | `long_term`, `episodic`, `procedural`, `working`, `scratchpad` | **Bridge** (`memory_oas_bridge`) | OAS `Memory.t` (already the target) |
| Context reduction | `PruneToolOutputs`, `MergeContiguous`, `DropLowImportance`, `SummarizeOld` | **MASC** (`context_compact_oas`) | OAS `Context_reducer` |
| Model selection | `last_model_used`, derived `active_model`, `cascade_name` | **MASC** (`keeper_meta`) | OAS `Cascade_config` |
| System prompt | `system_prompt`, `build_turn_prompt` | **MASC** (`keeper_prompt`, `keeper_agent_run`) | OAS `Agent.config` |
| Collaboration phase | `phase`, `participants`, `artifacts`, `contributions` | **OAS** (`Collaboration.t`) | OAS (correct) |
| Session lifecycle | `session_id`, `created_at`, `updated_at` | **OAS** (`Session.t`) | OAS (correct) |

## 2. Domain State (belongs in MASC)

State that describes the coordination domain — not how an agent thinks, but what it does within the MASC system.

| Category | Data | Current Owner | Target Owner |
|----------|------|---------------|--------------|
| Room membership | `joined_room_ids`, `room_scope` (`current` only), agents.json | MASC | MASC (single-room compatibility state) |
| Task claims | task files, `assignee`, `status` | MASC | MASC (correct) |
| Board posts | `board_posts`, `board_comments`, `board_votes` | MASC | MASC (correct) |
| Governance | petitions, cases, rulings, execution orders | MASC (`governance_v2`) | MASC (correct) |
| Room votes | vote proposals, vote casts | MASC (`room_vote`) | MASC (correct) |
| Agent economy | token economy, reputation | MASC (`agent_economy`, `agent_reputation`) | MASC (correct) |
| Broadcasts | room event log, SSE events | MASC | MASC (correct) |
| Institution rules | institution.json, norms | MASC (`institution_eio`) | MASC (correct) |

## 3. Current Boundary Violations

Classification used below:

- **Resolved**
- **Partial**
- **Open**

### V1 (Partial): `keeper_meta` still mixes domain profile and runtime ownership

`keeper_types.ml` no longer stores all runtime fields flat on `keeper_meta`; it already groups runtime-heavy state under `runtime : agent_runtime_state`.
That is real progress, but ownership is still mixed because keeper persistence still writes agent-runtime data as part of the MASC keeper record.

Nested sub-records expand the effective surface further:

- `usage_metrics`: 11 fields
- `compaction_state`: 11 fields
- `proactive_config`: 7 fields

So the flattened operational surface is roughly 83 fields. Approximately 29-30 of these are agent-runtime state:

**Agent state fields in keeper_meta (should be in OAS):**
- `total_turns`, `total_input_tokens`, `total_output_tokens`, `total_tokens`, `total_cost_usd` — cumulative usage stats
- `last_turn_ts`, `last_model_used`, `last_input_tokens`, `last_output_tokens`, `last_total_tokens`, `last_latency_ms` — per-turn metrics
- `compaction_count`, `last_compaction_ts`, `last_compaction_before_tokens`, `last_compaction_after_tokens` — context management stats
- `last_model_used`, `cascade_name`, derived `active_model` — model selection state
- `trace_id`, `trace_history` — session tracing
- `generation` — checkpoint generation counter
- `context_budget` — context window budget ratio

**Domain state fields in keeper_meta (correct placement):**
- `room_scope` (`current` only compatibility), `mention_targets`, `proactive_*` — operational coordination policy
- `joined_room_ids`, `last_seen_seq_by_room` — current-room compatibility state (single-room canonical model)
- `autonomy_level`, `active_goal_ids` — coordination state

**Impact**: Every keeper turn reads the full keeper record, updates agent-runtime fields, and writes it back. This couples domain persistence (MASC JSONL/PG) with agent-runtime state that OAS should own.

### V2 (Open): keeper `working_context` duplicates OAS Context.t

The current code keeps the wrapper in `keeper_exec_context.ml` / `keeper_types.ml`:
```ocaml
type working_context = {
  system_prompt : string;
  messages : Agent_sdk.Types.message list;
  token_count : int;
  max_tokens : int;
  importance_scores : (int * float) list;
  oas_context : Agent_sdk.Context.t;
}
```

This wraps `Agent_sdk.Context.t` with additional MASC-specific fields (`importance_scores`, `token_count`). The wrapper exists because MASC needs importance scoring for `DropLowImportance` compaction, but OAS `Context_reducer` already supports `Custom` closures. The `token_count` duplication is unnecessary since OAS Context tracks this.

**Impact**: Checkpoint save/restore serializes this MASC wrapper rather than the native OAS checkpoint. Two sources of truth for message state.

### V3 (Open): `context_compact_oas.ml` re-implements OAS scoring in MASC

`context_compact_oas.ml` contains `score_messages` (importance scoring) and `oas_strategy_of` (strategy mapping). While it delegates to `Agent_sdk.Context_reducer`, it maintains MASC-side scoring logic (`[MASC_GOAL]` prefix detection, `[MASC_MEMORY_SUMMARY v1]` markers) that creates MASC-specific context semantics inside what should be pure agent-runtime behavior.

**Impact**: MASC-specific markers (`[MASC_GOAL]`, `[STATE]...[/STATE]`) embedded in messages that OAS Context_reducer must handle. Domain concepts leak into message content format.

### V4 (Resolved): Decorative petition bridge issue resolved

The retired petition bridge no longer creates decorative `Collaboration.t` instances for petitions. Governance petitions persist directly via the current governance surface.

**Impact**: Resolved. The current code path no longer instantiates `Collaboration.t` as one-shot decoration for petitions.

### V5: `Runtime.session.votes` — governance concept in OAS wire protocol

OAS `Runtime.session` (wire protocol) contains a `votes : vote list` field marked with `(-> Collaboration.t)`. The `vote` type in OAS Runtime:
```ocaml
type vote = {
  topic: string;
  options: string list;
  choice: string;
  actor: string option;
  created_at: float;
}
```

This is a governance/domain concept that leaked into the OAS wire protocol. OAS `Collaboration.t` already replaced this with generic `contribution`, but `Runtime.session` still carries the legacy field.

**Impact**: OAS carries governance vocabulary. MASC has its own separate `room_vote.ml` with `VotePending | VoteApproved | VoteRejected | VoteTied`. Two vote systems, neither connected.

### V6: `Memory_oas_bridge` seeds MASC domain knowledge into OAS Memory

`memory_oas_bridge.ml` bridges MASC-specific memory systems (institution, procedural memory, episodes) into OAS `Memory.t`:
- `seed_institution` — loads MASC institution rules into OAS Long_term tier
- `seed_procedures` — loads MASC procedural memory into OAS Long_term tier
- `seed_episodes` — loads MASC institution episodes into OAS Episodic tier

The bridge direction is correct (MASC domain -> OAS agent memory), but the bridge code lives in MASC rather than being a callback/hook that MASC registers with OAS. OAS `Memory.t` `long_term_backend` callback is the right mechanism, partially used for PG storage but not for institution/procedural seeding.

**Impact**: MASC must know OAS `Memory.t` internals to seed correctly. If OAS changes Memory tier semantics, MASC bridge breaks.

### V7 (Open): `keeper_agent_run.ml` orchestrates OAS agent lifecycle from MASC

`keeper_agent_run.ml` builds the full OAS agent lifecycle:
1. Loads checkpoint via MASC's `keeper_exec_context`
2. Builds system prompt via MASC's `keeper_prompt`
3. Creates OAS Memory via `Memory_oas_bridge`
4. Constructs OAS `Context_reducer`
5. Calls `Oas_worker.run_named`

This is the primary integration point and is architecturally correct as a bridge module. The violation is that steps 1-4 use MASC-specific wrappers rather than OAS-native primitives. The `keeper_working_context` wrapper (V2) forces checkpoint loading through MASC rather than OAS.

**Impact**: MASC controls agent lifecycle detail that OAS `Agent.run` should own. Checkpoint format is MASC-specific.

## 4. Migration Path

### Phase 1: Split `keeper_meta` (agent stats vs domain profile)

Extract agent-runtime fields from `keeper_meta` into a separate record:

```ocaml
(* New: agent_runtime_stats — belongs in OAS Session or Usage_tracker *)
type agent_runtime_stats = {
  total_turns: int;
  total_input_tokens: int;
  total_output_tokens: int;
  total_tokens: int;
  total_cost_usd: float;
  last_turn_ts: float;
  last_model_used: string;
  last_input_tokens: int;
  last_output_tokens: int;
  last_total_tokens: int;
  last_latency_ms: int;
  compaction_count: int;
  last_compaction_ts: float;
  generation: int;
}

(* keeper_meta retains only domain/profile fields *)
type keeper_meta = {
  name: string;
  agent_name: string;
  goal: string;
  (* ... domain fields only ... *)
  stats: agent_runtime_stats;  (* embedded for backward compat, migrated later *)
}
```

**Effort**: Medium. 70+ call sites reference keeper_meta fields directly.
**Risk**: Low — structural refactor, no behavior change.
**Prerequisite for**: Phase 2. Phase 3 is expected to follow after Phase 2 removes the wrapper boundary.
**Removal deadline**: remove the embedded `stats` field by the end of Phase 2. If Phase 2 is deferred or dropped, open a separate migration issue and keep the field marked deprecated rather than silently permanent.

### Phase 2: Eliminate `keeper_working_context` wrapper

Replace `working_context` with direct use of `Agent_sdk.Context.t`:
- Move `importance_scores` into OAS `Context_reducer.Custom` closure (already partially done)
- Remove `token_count` duplication (OAS Context tracks this)
- Checkpoint save/restore uses OAS `Checkpoint` directly

```ocaml
(* Before: MASC wrapper *)
type working_context = {
  system_prompt : string;
  messages : Agent_sdk.Types.message list;
  token_count : int;
  max_tokens : int;
  importance_scores : (int * float) list;
  oas_context : Agent_sdk.Context.t;
}

(* After: OAS Context.t is the source of truth *)
(* importance_scores passed as closure to Context_reducer.Custom *)
(* token_count read from Context.t *)
```

**Effort**: Medium-High. `keeper_exec_context.ml` and the `Keeper_types.working_context` boundary need rewrite.
**Risk**: Medium — checkpoint format change requires migration or dual-read.
**Prerequisite for**: Phase 3.

### Phase 3: Remove MASC markers from message content

Replace `[MASC_GOAL]`, `[STATE]...[/STATE]`, `[MASC_MEMORY_SUMMARY v1]` prefixes with OAS-native metadata:
- Use `message.metadata` or structured content blocks instead of text prefixes
- Importance scoring in `context_compact_oas.ml` checks metadata rather than string prefix

**Effort**: Low-Medium.
**Risk**: Low — messages are ephemeral within a session.

### Phase 4: Mark decorative `Collaboration.t` violation as resolved

The retired petition bridge no longer creates decorative `Collaboration.t` records for petitions.

남은 작업은 코드 수정이 아니라 boundary 문서와 invariants를 현재 상태에 맞게 유지하는 것이다.

**Effort**: Low. Documentation + regression guard.
**Risk**: Low.

### Phase 5: Remove `votes` from OAS `Runtime.session`

In OAS, complete the `Runtime.session` -> `Collaboration.t` migration:
- Remove `votes : vote list` from `Runtime.session`
- Governance voting stays in MASC `room_vote.ml` / `Governance_v2`
- OAS `Collaboration.t` uses generic `contribution` for agent coordination signals

**Effort**: Medium. OAS-side change. Wire protocol change requires version bump.
**Risk**: Medium — breaking change for any consumer reading `Runtime.session.votes`.

### Phase 6: Formalize the bridge as hooks/callbacks

Replace `Memory_oas_bridge.seed_*` imperative calls with OAS hook registration:
- OAS `Hooks.on_session_start` callback for memory seeding
- MASC registers a hook that loads institution/procedural memory when an agent session starts
- OAS owns the lifecycle, MASC provides domain data on request

**Effort**: Medium.
**Risk**: Low — behavioral change is minimal.

## Phase Priority

| Phase | Priority | Blocking? | Effort |
|-------|----------|-----------|--------|
| P1: Split keeper_meta | High | Yes (enables P2, P3) | Medium |
| P4: Mark Collaboration usage resolved | Low | No | Low |
| P5: Remove Runtime.session.votes | High | No | Medium |
| P2: Eliminate working_context wrapper | Medium | Yes (enables P3) | Medium-High |
| P3: Remove MASC markers | Medium | No | Low-Medium |
| P6: Formalize bridge as hooks | Medium | No | Medium |

## Invariants (post-migration)

1. MASC never reads or writes `Agent_sdk.Context.t` directly — it interacts through tool call results only
2. OAS never reads MASC domain files (`.masc/`, governance, board) — it receives domain data through registered hooks/callbacks
3. `keeper_meta` contains only domain profile fields — runtime stats live in OAS
4. Checkpoint format is OAS-native — MASC does not define its own serialization
5. `Collaboration.t` is used for actual multi-agent coordination, not as decoration for domain operations
6. `Runtime.session` does not contain governance vocabulary (votes, petitions, rulings)
