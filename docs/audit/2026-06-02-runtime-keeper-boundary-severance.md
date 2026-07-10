# Runtime → Keeper Boundary Severance — Audit

**Date**: 2026-06-02
**PR**: #19801
**Goal**: Runtime (infrastructure layer) should not depend on Keeper (application layer). The correct dependency direction is Keeper -> Runtime.

## 1. Discovery

Systematic cross-subsystem scan after Tool→Keeper boundary completion (ratchet baseline=0).
Method: `rg 'Keeper_[a-zA-Z][a-zA-Z_]*\.[A-Za-z]' lib/` filtered by subsystem prefix,
excluding comments/string literals, focusing on actual module calls (not variant constructors).

### Scanned axes

| Axis | Files with calls | Nature | Action |
|------|-----------------|--------|--------|
| Tool → Keeper | 0 | DONE (ratchet baseline=0) | None |
| **Runtime → Keeper** | **4 files, ~15 refs** | Real module calls | **Partially severed** |
| Operator → Keeper | 7 files, ~70 refs | Typed keeper management records | Future |
| Config → Keeper | 3 files, ~5 refs | Env config | Future |
| Dashboard → Keeper | ~25 files | Display (reads state) | Future |
| Server → Keeper | ~30 files | Wiring layer | Future |

### Runtime → Keeper violations (pre-merge)

| File | Module | Calls | Nature |
|------|--------|-------|--------|
| `runtime_agent.ml` | `Keeper_observation` | 5 | Observation/metrics recording |
| `runtime_agent.ml` | `Keeper_oas_checkpoint` | 5 | Lifecycle/checkpoint re-exports |
| `runtime_oas_runner.ml` | `Keeper_identity` | 2 | Name resolution |
| `runtime_inference.ml` | `Keeper_internal_error` | 1 | Error type |

## 2. Root cause

`Keeper_oas_checkpoint` had **zero keeper-internal callers**. It was a runtime module
misplaced in `lib/keeper/` with the `Keeper_` prefix.

`Keeper_observation` was shared between keeper (9 files) and runtime/server (4 files).
The observation types (`runtime_attempt`, `runtime_observation`) describe **runtime** behavior,
not keeper-specific logic. The `Keeper_` prefix was misleading.

## 3. Changes

### Phase 1: Keeper_oas_checkpoint -> Runtime_oas_checkpoint
- Moved `lib/keeper/keeper_oas_checkpoint.ml(i)` -> `lib/runtime/runtime_oas_checkpoint.ml(i)`
- Only consumer: `runtime_agent.ml` (re-exported functions)
- Added to `private_modules` in `lib/dune`

### Phase 2: Keeper_observation -> Runtime_observation
- Moved `lib/keeper/keeper_observation.ml(i)` -> `lib/runtime_observation.ml(i)`
- Moved `lib/keeper/keeper_observation_query_operation.ml(i)` -> `lib/runtime_observation_query_operation.ml(i)`
- Updated 29 files (reference renames across lib/, test/)
- `Runtime_observation_query_operation` added to `private_modules` (Copilot review)

### Stale doc fixes
- `Runtime_runner` -> `Runtime_agent` (3 references)
- `oas_worker.mli` -> `Runtime_agent` (2 references)

## 4. Verification

- `dune build --root . lib/masc.cma` EXIT=0
- `dune build --root . @check` EXIT=0
- Copilot review: 1 actionable comment (private_modules) — addressed

## 5. Open issues

### Remaining Runtime→Keeper debt
PR #19801 severed `Keeper_observation` and `Keeper_oas_checkpoint`. Two modules remain:
- `runtime_oas_runner.ml`: `Keeper_identity.keeper_agent_name`, `Keeper_identity.keeper_name_from_agent_name` (2 calls)
- `runtime_inference.ml`: `Keeper_internal_error.Max_tokens_ceiling_violation` (1 call)
- `runtime_inference.mli:21`: public signature still returns `Keeper_internal_error.masc_internal_error`
  — the interface exposes a Keeper type even once the `.ml` constructor is extracted, so a
  follow-up must sever the `.mli` signature dependency too (not just the `.ml` reference).
These require separate severance: `Keeper_identity` is shared with 14 non-keeper callers,
`Keeper_internal_error` needs a generic error type extraction (covering both the `.ml`
constructor use and the `.mli` return-type dependency).

### Next boundary candidates
- `Keeper_identity` (14 non-keeper callers) — widely shared utility module
- Operator → Keeper (7 files, ~70 refs) — management layer using keeper internals
- Config → Keeper (3 files, ~5 refs) — configuration referencing keeper behavior

## 6. Relationship to Tool→Keeper boundary

This is the **second boundary axis** in the subsystem dependency cleanup:
1. Tool → Keeper (2026-05-31, ratchet baseline=0) — tool surface must not know about keeper
2. Runtime → Keeper (2026-06-02, PR #19801) — infrastructure must not depend on application

Both follow the same pattern: rename/move misplaced modules, update references.
The structural root fix (dune sub-library split) remains a future goal.
