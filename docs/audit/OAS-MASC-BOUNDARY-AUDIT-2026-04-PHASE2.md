# OAS ↔ MASC Boundary Audit — Phase 2 (Layer C sweep + Phase 1 refinement)

> Status: Phase 2 of 4. Refines Phase 1's Layer C verdict (`NEEDS SWEEP` → mostly `PASS`).
> Author: Vincent (jeong-sik) with Claude
> Created: 2026-04-30
> Tracks: Q-P0-3 follow-up
> Related: PR #12112 (Phase 1), PR #12102 (`track2_sync_boundary` MERGED, `track2_sync_boundary.ml` 107 lines + `.mli` 56 lines)

---

## 1. Why Phase 2 corrects Phase 1

Phase 1 reported Layer C as `NEEDS SWEEP` based on raw `Oas.*` reference counts:
- `keeper_context_core.ml` — 91 references
- `keeper_run_tools.ml` — 62 references
- `keeper_guards.ml` — 47 references

That metric was **too coarse**. A per-reference inspection during Phase 2 shows the references split into four categories with very different boundary implications:

| Category | Example | Boundary verdict |
|---|---|---|
| **C1. Type names** | `Oas.Tool.t list`, `Oas.Hooks.hooks`, `Oas.Agent.t option ref` | Acceptable. OCaml type system requires the type name at the use site. |
| **C2. Variant constructors** | `Oas.Hooks.Approve`, `Oas.Hooks.Edit _`, `Oas.Hooks.Reject reason` | Acceptable. Pattern matching against an exposed ADT is the SDK's *intended* extension surface. |
| **C3. Pure-function reuse** | `Oas.Types.text_of_message`, `Oas.Context_reducer.estimate_char_tokens` | Acceptable. No side effect, no ambient state, callable from anywhere. |
| **C4. Side-effecting runtime calls** | `Oas.Agent.run`, `Oas.Tool.dispatch` | Must go through Layer B (`Masc_oas_bridge.run_with_caller`, `Keeper_turn_driver.t`, `Keeper_tools_oas`, etc.). |

The boundary discipline that matters is **C4**, not C1–C3. Phase 1's count conflated all four.

## 2. C4 verdict (the one that matters)

```bash
rg "Oas\.Agent\.run|Oas\.Tool\.dispatch" lib/keeper/ lib/server/ lib/dashboard/ lib/local/ 2>/dev/null
# (empty)
```

**Zero direct `Oas.Agent.run` or `Oas.Tool.dispatch` calls in Layer C.** All side-effecting runtime invocations route through Layer B.

`Oas.Agent.t` *appears* in Layer C three times:

| Site | Form | Verdict |
|---|---|---|
| `lib/keeper/keeper_run_tools.ml` | `agent_ref : Oas.Agent.t option ref` (record field + initializer) | **C1**, type only |
| `lib/keeper/keeper_run_tools.ml` | `let agent_ref : Oas.Agent.t option ref = ref None` | **C1**, type only |
| `lib/local/worker_container.mli` | `agent:Oas.Agent.t ->` (function parameter) | **C1**, type only |

Each is a *type annotation* on storage or a parameter. The actual `Oas.Agent.run` invocation lives in `lib/oas_worker_exec_agent.ml` (Layer B), called from these Layer C sites via the bridge.

**Phase 1 verdict revision**: Layer C is **PASS** for runtime discipline (C4). Layer C contains expected C1–C3 references which are not violations.

## 3. Layer B usage in Layer C — small but present

```bash
rg -l "Masc_oas_bridge\." lib/keeper/ lib/server/ lib/dashboard/ lib/local/ 2>/dev/null
```

Five files use `Masc_oas_bridge` directly:
- `lib/keeper/keeper_persona_authoring.ml`
- `lib/dashboard/dashboard_operator_judge.ml`
- `lib/dashboard/dashboard_governance_judge.ml`
- `lib/server/server_openai_compat.{ml,mli}`

This is the *intended* path: Layer C → `Masc_oas_bridge.run_with_caller` → Layer A. Five sites is fewer than expected for ~30 Layer C files; the remainder route through other Layer B modules (`Keeper_tools_oas`, `Oas_worker`, `Keeper_hooks_oas`). The *fan-in to Layer B is wide*, not a single throat.

## 4. New module: `track2_sync_boundary` (PR #12102 MERGED)

`lib/track2_sync_boundary.{ml,mli}` (107 + 56 lines) was merged between Phase 1 (PR #12112) and Phase 2 (this PR).

| Property | Value |
|---|---|
| Layer | **C (MASC core, policy-only)** |
| Purpose | Typed admission contract for future CRDT / Eg-walker / MessagePack sync sidecars |
| Boundary fit | Authority/projection/ephemeral admission rules; binary-frame readiness contracts |
| Dependency on `Oas.*` | None observed (verified: `rg "Oas\." lib/track2_sync_boundary.{ml,mli}` returns empty) |

Per the PR body (#12102): *"OAS remains a domain-neutral runtime SDK"*. This audit confirms the new module sits cleanly in Layer C and does not pull `Oas.*` types into the policy surface — exactly the right shape.

The forthcoming sync sidecars (CRDT, Eg-walker, MessagePack) will plug into `track2_sync_boundary` as **Layer B adapters**, keeping the boundary discipline intact.

## 5. Test-tier Phase 3 preview

```bash
rg -c "Oas\." test/ 2>/dev/null | sort -t: -k2 -n -r | head -5
```

Test files commonly import `Oas.*` for fixture creation. This is **acceptable in tests** — fixtures need to construct concrete values, and going through Layer B's bridge for a fixture call would amount to ceremony with no boundary value. Phase 3 will record the test-tier surface for completeness but will not flag it.

## 6. Recommended ratchet (Phase 4 preview)

Based on Phase 2 findings, the ratchet metric proposed in Phase 1 (`direct_oas_imports_in_layer_c`) needs a more targeted form:

```bash
# Strict ratchet: forbid C4 direct calls in Layer C.
rg "Oas\.Agent\.run|Oas\.Tool\.dispatch" lib/keeper/ lib/server/ lib/dashboard/ lib/local/
# Floor: 0
```

This wording floors the *correct* metric (side-effecting runtime calls) without producing noise from C1–C3 references that are unavoidable in OCaml.

A weaker, descriptive ratchet for `Masc_oas_bridge` adoption is also useful:

```bash
# Floor: 5 (current count); only allowed to increase.
rg -l "Masc_oas_bridge\." lib/keeper/ lib/server/ lib/dashboard/ lib/local/ | wc -l
```

These two ratchets together encode the discipline: zero direct C4 violations, monotonically increasing bridge adoption.

## 7. Updated phase plan

| Phase | Scope | Status |
|---|---|---|
| 1 | Bridge layer + keeper OAS hooks | PR #12112 (Draft) |
| **2 (this PR)** | **Layer C runtime call sweep + Phase 1 refinement** | **this PR** |
| 3 | `test/` + `benchmark/` + reverse-grep against external OAS source | next |
| 4 | Ratchet PR: floor C4 to 0, floor `Masc_oas_bridge` adoption | after Phase 3 baseline |

## 8. References

- `lib/track2_sync_boundary.{ml,mli}` — MERGED, Layer C policy
- `lib/oas_worker*.{ml,mli}` — Layer B adapter sprawl
- `lib/masc_oas_bridge.{ml,mli}` — Layer B single timeout/cancel boundary
- PR #12112 — Phase 1 (this PR's predecessor)
- PR #12102 — `track2_sync_boundary` MERGED
- `docs/audit/OAS-MASC-BOUNDARY-AUDIT-2026-04.md` — Phase 1 doc

*Audit date: 2026-04-30 / Phase 2 of 4 / docs-only, code change = 0 / refines Phase 1 verdict*
