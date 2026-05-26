---
title: Types Sub-library Extraction with `_intf.ml` mli-only Surface (typed-SSOT)
rfc: "0178"
status: Draft
created: 2026-05-26
updated: 2026-05-26
author: vincent
supersedes: []
superseded_by: null
related: ["0056", "0085", "0005", "0003"]
implementation_prs: []
---

# RFC-0178 — Types Sub-library Extraction with `_intf.ml` mli-only Surface

Status: Draft · Scaffold (Sprint 2 entry, see related work)
Author: jeong-sik (with Claude Opus 4.7 via masc-mcp ocaml-bestpractice plan PR me#1175)
Date: 2026-05-26
Supersedes: —
Related: RFC-0056 (Incremental Sub-Library Extraction — inherits G1-G5 gate machinery), RFC-0085 (Keeper Namespace Promotion — naming convention precedent), RFC-0005 (Typed Capability Substrate — caller-pattern alignment), RFC-0003 (Keeper Composite Lifecycle — sub-FSM module type targets)

## 0. Reading guide

This RFC adopts the RFC-0056 §3.3 gate (G1-G5) verbatim as Phase 0 entry criteria. The novel contribution is **typed-SSOT extraction as mli-only sub-libraries** — `_intf.ml` files in dedicated directories that callers depend on as the single source of truth for cross-domain types. This pattern is *absent* from the current codebase (1 `_intf.ml` file across 1539 `.ml` files per Sprint 1 evidence).

## 1. Problem

### 1.1 Empirical baseline (Sprint 1 evidence — me PR #1175)

Measured 2026-05-26:

| Metric | Value | Implication |
|---|---:|---|
| `.ml` files in `lib/` | 1,539 | — |
| `.mli` files in `lib/` | 1,436 (93.3%) | Interface-first generally enforced |
| `_intf.ml` (intf-only) files | **1** | Pattern is absent — no shared module-type surface |
| `lib/types/types_core.ml` LoC | **1,067** | Sole godfile remaining (>1000 LoC); concentrates cross-domain types |
| flat sub-libraries in `lib/` | 85 | — |

### 1.2 Coupling hypothesis

`types_core.ml` aggregates types across at least 5 domains observed in source: keeper-side, cascade-side, OAS-side, shell-side, dashboard-side. Today every caller imports the entire 1,067-LoC module to use a single domain's types. This:

1. Inflates compile fan-out for unrelated changes (touching one keeper type recompiles cascade callers).
2. Defeats the cycle-avoidance property `_intf.ml` would provide — when two sub-libraries each need the same type, only direct embedding works (or duplication).
3. Makes Sprint 2 functor-driven design (P1-4 of the plan) infeasible: functor parameters need narrow module-type surfaces, but `types_core.ml` has no such surfaces.

### 1.3 Out-of-scope problems (intentional non-goals)

- Renaming / repackaging exported types (G2-equivalent: byte-identical signatures during extraction).
- Resolving the `Runtime_events.start_listener` orphan exposed by the `http_server_eio.start` dead-code audit — separate issue.
- Migrating `dashboard/src/` TypeScript substring classifiers — sibling RFC under P0-3 scope.

## 2. Goals (and non-goals)

### 2.1 Goals

1. **G-A — Typed SSOT per domain.** Each domain's cross-library types live in exactly one `_intf.ml` file inside a dedicated `lib/types_<domain>/` sub-library.
2. **G-B — Zero caller rename.** Callers continue writing `Foo` (not `Types_keeper_intf.Foo`), achieved via `(wrapped false)` per RFC-0056 G3.
3. **G-C — Compile-time cycle prevention.** Cross-domain type references go through `_intf.ml` only — no `.ml` body inside the typed-SSOT sub-libraries. This is *the* novel property.
4. **G-D — Inherited gate machinery.** Reuse RFC-0056 G1-G5 verbatim. No new gate concepts.

### 2.2 Non-goals

- Adopting Jane Street `_intf.ml` convention beyond what RFC-0056 G3 already permits.
- Auto-formatting / large-scale rename. Phase 0 is mechanical extraction; rename is Phase ≥ 2 with explicit RFC.
- Reducing the total LoC of `types_core.ml` content. Extraction relocates; it does not refactor.

## 3. Design

### 3.1 Domain partitioning of `types_core.ml` (iter #2 inventory)

Empirical inventory from `lib/types/types_core.ml` (1,086 LoC at HEAD `4759453d3`). Extracted via `rg -n '^(type|and|module(?: type)?)\s'`:

| # | Domain candidate | Line range | LoC est. | Top-level types | Provisional sub-lib name |
|--:|---|---|---:|---|---|
| 0 | Utility (timestamp) | 1-40 | ~40 | `now_iso`, `parse_iso8601_opt` (values, not types) | `types_time` (or absorb into shared util) |
| 1 | **Agent** | 42-220 | ~180 | `agent_status`, `agent_meta`, `agent` | `types_agent_intf` |
| 2 | **Room** | 232-249 | ~17 | `room_info`, `room_registry` | `types_room_intf` |
| 3 | **Task** (largest) | 250-650 | ~400 | 13 types: `task_action`, `task_status`, `worktree_info`, `task_execution_links`, `task_contract`, `task_reclaim_policy`, `task_handoff_context`, `task`, `task_reclaim_gate`, `task_claim_readiness`, `task_claim_block`, `task_claim_decision`, `task_claim_next_action` | `types_task_intf` |
| 4 | **Message** | 756-788 | ~32 | `message`, `room_state` | `types_message_intf` |
| 5 | **Tempo** | 789-860 | ~71 | `tempo_mode`, `tempo_config` | `types_tempo_intf` |
| 6 | **Backlog** | 861-901 | ~40 | `backlog` | `types_backlog_intf` |
| 7 | **A2A / Portal** | 902-1031 | ~130 | `a2a_task_status`, `portal_state`, `a2a_task`, `portal` | `types_a2a_intf` |
| 8 | **MCP surface** | 1032-1086 | ~54 | `sse_session`, `tool_result`, `tool_schema`, `claim_next_result` | `types_mcp_intf` |
| | **Total** | | ~964 | 30 types | 8 sub-libraries |

### 3.2 Observations from inventory

- **Task domain dominates** (~400 LoC, 42% of typed surface). It is the obvious last candidate for Phase 0 PoC due to internal coupling among 13 types.
- **3 small leaves are immediate Phase 0 candidates** (Room 17 LoC, Backlog 40 LoC, Tempo 71 LoC). Tempo is most attractive because it has the cleanest internal structure (`tempo_mode` + `tempo_config`) and no obvious cross-domain reference (verify in §3.3).
- **Utility (timestamp) is values, not types**. Distinct treatment — likely lives in a shared `lib/util_time/` not a typed-SSOT sub-library.
- **MCP surface** (sse_session, tool_result) belongs to the protocol boundary — may overlap with `lib/mcp_protocol/` (external pinned dep, see dune-project). Phase 0 should *avoid* this domain until cross-package contract is clarified.

### 3.3 Phase 0 PoC candidate selection — (placeholder, iter #3)

Tentative ranking by *expected risk × signal*:

| Candidate | Risk | Signal | Notes |
|---|---|---|---|
| Tempo (~71 LoC, 2 types) | Low | Medium | Self-contained 2-type cluster; good "shape proof" for the pattern. |
| Room (~17 LoC, 2 types) | Very low | Low | Too small; outcome trivially positive, low generalization. |
| Backlog (~40 LoC, 1 type) | Low | Low | Single type; doesn't exercise multi-type `_intf.ml` benefit. |
| Agent (~180 LoC, 3 types) | Medium | High | Mid-size cluster; exercises pattern at meaningful scale. |

Iter #3 will (a) run dependency-leaf verification per RFC-0056 G1 audit script against each candidate, (b) pick the winner, (c) detail the PoC PR scope.

### 3.4 Caller migration policy — (placeholder, iter #4)

Reuses RFC-0056 §3.3 G3/G5: `(wrapped false)` + qualifier-removal-only diff outside the candidate directory.

### 3.5 Interaction with RFC-0056 Wave D wrapping promotion — (placeholder, iter #4)

Phase 0/1 stay `(wrapped false)` per RFC-0056 G3. Wave D `(wrapped true) + -open` migration is shared with RFC-0056 and other Phase 1 leaves.

## 4. Validation — (placeholder, expanded next iter)

- 4.1 Per-phase gate (G1-G5 from RFC-0056).
- 4.2 Build-green invariant on `@check`.
- 4.3 Caller-delta budget audit script.
- 4.4 Rollback path if any gate fails.

## 5. Workaround signature self-check (CLAUDE.md `feedback_telemetry_as_fix_self_recurrence`)

| Signature | Self-check | Verdict |
|---|---|---|
| Telemetry-as-fix | Does this RFC add counters/WARN to "make X visible"? | No — it narrows type surfaces. |
| String classifier | Does this RFC add substring/prefix matching? | No — it removes implicit cross-domain coupling. |
| N-of-M | Does this RFC admit "PR #N only fixed K of M sites"? | No — Phase 0 PoC is a single leaf domain; M-of-M within that domain. |
| Catch-all addition | Does this RFC add `_ ->` arms? | No — mli-only `.ml`-less modules have no match arms. |
| Cap / cooldown | Does this RFC suppress symptoms with rate limits? | No. |
| Test backdoor | Does this RFC expose `set_X_for_test`? | No. |
| N-site repeated typo fix | Does this RFC apply the same edit N times manually? | Codemod-style rewrite in Phase 0+; not manual repetition. |

All 7 checks pass → Override conditions not invoked.

## 6. Related work and dependency direction

- **Depends on**: RFC-0056 Phase 0 PoC (`lib/cdal/`) lands before this RFC's Phase 0 PoC starts. Reuses the same `audit-script` artifact.
- **Enables**: P1-4 (Functor-driven adoption expansion) — narrow `_intf.ml` surfaces are the natural functor parameter shape.
- **Adjacent**: RFC-0085 (keeper namespace promotion) — naming convention for `Types_keeper_intf` follows the Wave A `keeper-` prefix tree.

## 7. Open questions for review

1. Should `_intf.ml` files live under `lib/types_<domain>/intf.ml` (clean dir) or `lib/types_<domain>/types_<domain>_intf.ml` (long but unambiguous)?
2. Are `ppx_deriving` derivers (`show`, `eq`) part of the typed-SSOT surface or per-consumer? RFC-0058 `cascade_decl` precedent suggests per-sub-library.
3. Does Phase 0 PoC pick the smallest domain (keeper-sub-FSM, ~150 LoC est.) or the highest-coupling domain (cascade)? Smallest = lower risk; highest-coupling = highest signal.

## 8. Iteration log

| Iter | Date | Section advanced |
|---|---|---|
| 1 | 2026-05-26 | Scaffold (§0-§2 complete, §3-§4 outlined) |
