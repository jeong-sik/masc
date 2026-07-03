# MASC/OAS P0 Infrastructure Hardening — Design Spec

**Date:** 2026-06-26
**Status:** Draft (MASC-side implementation slice)
**Worktree:** `masc/.worktrees/feat/masc-oas-p0-infra-hardening-20260626`
**Target repo:** `masc`
**Evaluated against:** OCaml 5.4 official semantics, Eio 1.x ecosystem, Jane Street / large-scale OCaml best practices.

---

## 1. Background

The downloaded audit documents identify multiple P0 defects in MASC and OAS:

- **OAS bridge timeout silently degrades** when `Masc_eio_env` has no clock (`lib/masc_oas_bridge.ml`).
- **Path / env SSOT drift**: implicit `Sys.getcwd ()` fallbacks, split `.masc/config` concatenation, duplicated env parsers.
- **Goal/verification, board, task, Memory OS, FUSION** defects were also flagged, but many are already fixed on `main` or require larger architectural work.

This spec scopes the first implementable MASC-side slice: fail-closed OAS bridge timeout + MASC path/env hardening. Cross-repo OAS env parser consolidation is tracked separately and is not implemented by this branch.

### Design Principles

All changes in this spec follow the user's requirements:

- **No silent failure.** A missing clock or failed write must surface as a typed error, not a log-and-continue path.
- **No string matching.** Timeout presence is enforced by the type system (`clock` non-optional in the bridge path), not by substring checks.
- **No hardcoded local paths.** Paths are resolved through `Config_dir_resolver` / explicit `base_path`; cwd fallbacks are removed or documented.
- **SSOT.** MASC bridge env parsing and path construction use typed helpers instead of local ad hoc parsing or string-built paths.
- **Immutable where possible.** Env helper results and path records are pure functions of input config.
- **Production-level.** Changes include tests and telemetry; build verification happens in CI.

---

## 2. Audit Findings vs. Current `main`

| Audit claim | Current `main` status | Action in this spec |
|-------------|----------------------|---------------------|
| OAS bridge falls back to `Unix.gettimeofday` and runs without timeout | **Unfixed**. A fix exists on `codex/oas-bridge-clock-fail-closed-20260626` but is not merged. | Implement fail-closed behavior. |
| Path hardcoded to a host-local workspace path | **Not found** in production runtime code. | No action. |
| `Sys.getcwd ()` used as implicit base-path fallback | **Present** in 36 call sites across 23 MASC `lib/` files. | Thread explicit base path; remove fallback where feasible. |
| Split `.masc/config` literal concatenation | **Present** in `bin/main_eio.ml`. | Use `Common.masc_dirname` / `Config_dir_resolver`. |
| Duplicated env parsers (OAS) | **Present** in the OAS repo. | Out of scope for this MASC branch; track in the OAS cross-repo backlog. |
| Board lock-order inversion | **Already fixed** by commit `509a94ee533`. | Out of scope. |
| Goal operator auth / principal binding / request-id-goal-id check | **Already present** in `workspace_goals.ml` and `goal_verification.ml`. | Out of scope; note cross-file lock order for future RFC. |

---

## 3. Keeper Latched Reason (typed pause SSOT)

`Keeper_latched_reason.t` is the typed SSOT for "why a keeper is latched (paused / blocked)". It is produced only by typed variants, consumed by exhaustive pattern matches, and serialized to a closed wire form for dashboards. It is intentionally distinct from turn-outcome types and from the permissive `Keeper_terminal_reason.t` classifier.

### 3.1 Type

```ocaml
type t =
  | No_progress_loop of { consecutive_idle_cycles : int; detector_kind : [ `Consecutive_idle_turns | `Consecutive_no_progress | `Both ] }
  | Completion_contract_violation of contract_violation_detail
  | Idle_detected of { consecutive_idle_turns : int }
  | Runtime_exhausted of runtime_exhaustion_reason
  | Turn_budget_exhausted of turn_budget_exhausted
  | Stale_storm
  | Provider_timeout_loop of { consecutive_timeouts : int }
  | Operator_paused of { operator_actor : string }
  | Dead_tombstone
```

`Operator_paused` records operator/control-plane pauses (gRPC directive, `keeper_down` retain). `Dead_tombstone` marks a keeper meta left as a tombstone by the supervisor's dead-keeper cleanup; it carries no payload because the tombstone status itself is the observability signal.

### 3.2 Design rules

- **Typed only at producers.** Pause sites create a `Keeper_latched_reason.t` value; they never write a raw string into meta.
- **Exhaustive matches.** New variants force compile-time changes in `equal`, `hash`, `pp`, `to_wire`, `of_wire`, `Stable.to_yojson`, and `Stable.of_yojson`. No `_ ->` catch-alls.
- **Fail-closed wire parser.** `of_wire` returns `(t, string) result`; unknown shapes are errors, not permissive fallbacks.
- **Display-only annotation.** `latched_reason` lives next to `paused` in `keeper_meta`, but the pause/resume decision remains controlled by the `paused` boolean. A malformed persisted `latched_reason` degrades to `None` without failing the whole meta parse, and the degradation is logged/counted.
- **Well-known operator actors.** `Keeper_latched_reason.operator_actor_grpc_directive` and `operator_actor_keeper_down` are the only production actor strings; tests and dashboards should avoid duplicating the literals.

### 3.3 Production pause sites

| Site | File | Variant | Actor |
|------|------|---------|-------|
| gRPC pause directive | `lib/keeper/keeper_keepalive.ml` | `Operator_paused` | `operator_actor_grpc_directive` |
| `keeper_down` retain (`remove_meta=false`) | `lib/keeper/keeper_turn_lifecycle.ml` | `Operator_paused` | `operator_actor_keeper_down` |
| Dead-tombstone cleanup | `lib/keeper/keeper_supervisor_cleanup_tombstone.ml` | `Dead_tombstone` | — |

### 3.4 Merge durability

When a heartbeat writer races with an operator pause, `heartbeat_fields_from_disk` preserves `paused=true` from disk. The same merge preserves `latched_reason` so the operator reason is not silently overwritten by a stale heartbeat write.

Dead-tombstone cleanup uses its own merge (`dead_tombstone_cleanup_from_disk`) so the cleanup caller owns `paused` and `latched_reason` while still monotonically preserving heartbeat-owned counters.

---

## 4. Sub-Project Decomposition

The full set of improvements is too large for one implementation plan. We decompose into phases:

**Phase 1 — Infrastructure Hardening (this spec)**
- P1.1 OAS Bridge Clock/Timeout fail-closed.
- P1.2 MASC path/env SSOT hardening.
- P1.3 Keeper latched-reason wiring (§3).

**Phase 2 — Security & Correctness**
- P2.1 Goal verification cross-file transaction safety (lock-order invariant + compensation audit).
- P2.2 FUSION JOJ adaptive timeout + separate meta-judge budget.

**Phase 3 — Keeper Fleet Isolation**
- P3.1 Memory OS maintenance loop fair-yield / separate switch.
- P3.2 Memory OS write-failure propagation (typed outcomes).

**Phase 4 — Structural**
- P4.1 Typed error classification (RFC-0158).
- P4.2 Keeper registry restart-state persistence.
- P4.3 Memory OS config centralization / hardcoded values.

**Phase 5 — TUI / Dashboard**
- P5.1 TUI P0 surfaces from `TUI-ROADMAP`.
- P5.2 Dashboard performance (mermaid sanitize already fixed on `dashboard-perf-mermaid-sanitize`).

---

## 5. Approach Options

### A. Safety-First Narrow Slices (Recommended)
Implement Phase 1 first, verify in CI, then proceed to Phase 2, 3, etc.

- **Pros:** Fast win on the most dangerous silent-degradation path; low blast radius; each phase is independently reviewable.
- **Cons:** Larger structural wins are delayed.

### B. Foundation-First
Start with Phase 4 (config centralization, typed errors, registry persistence) before touching bridge or path/env.

- **Pros:** Later phases become easier; fewer interface churns.
- **Cons:** No visible safety improvement for weeks; high risk of merge conflicts with ongoing work.

### C. Big-Bang
Open a single PR covering Phases 1–3.

- **Pros:** One coherent rollout.
- **Cons:** Violates worktree/PR best practices; review surface too large; CI failures become hard to attribute.

**Decision:** Follow **Approach A**. This aligns with the user's emphasis on logic/flow/correctness, production-level changes, and CI-verified builds.

---

## 6. Phase 1 Detailed Design

### 6.1 P1.1 — OAS Bridge Clock/Timeout Fail-Closed

**Goal:** `Masc_oas_bridge.run_safe` must not execute the wrapped function unless a real Eio clock is available. "Timeout without a clock" becomes a typed error, not a log-and-degrade path.

**Current problematic code** (`lib/masc_oas_bridge.ml:26–52`):

```ocaml
let clock_opt =
  match Masc_eio_env.get_opt () with
  | Some { clock; _ } -> clock
  | None -> None
in
...
let do_timeout fn =
  match clock_opt with
  | Some clock -> Eio.Time.with_timeout_exn clock timeout_s fn
  | None ->
    Log.Misc.warn "...running without timeout enforcement...";
    fn ()
```

**Desired behavior:**

1. `run_safe` requires an initialized `Masc_eio_env` carrying `Some clock`.
2. If env is missing **or** clock is `None`, return `Error (Internal_contract_rejected ...)` instead of running `fn`.
3. Keep `timeout_s = Float.infinity` as a legitimate advisory-judge value.
4. Preserve existing timeout / cancel / overshoot metric paths.

**Signature changes:**

- No change to `run_safe` public signature; the clock requirement is satisfied by requiring `Masc_eio_env` initialization.
- Optional: expose `run_unbounded` for callers that intentionally need no timeout, making the intent reviewable.

**Files to change:**

- `lib/masc_oas_bridge.ml` — replace `clock_opt` fallback with `fail_without_clock`.
- `lib/masc_oas_bridge.mli` — document clock requirement.
- `test/test_masc_oas_bridge_timeout_guard.ml` — expect contract rejection when no clock; stop expecting `Float.infinity` to fail.
- `test/test_tool_task_coverage.ml` — update "runs without eio env" test.

**Verification:**

- `scripts/dune-local.sh build test_masc_oas_bridge_timeout_guard`
- `scripts/dune-local.sh build test_tool_task_coverage`
- Full CI build/test before merge.

### 6.2 P1.2 — Path/Env SSOT Hardening

**Goal:** Remove MASC init-path duplication and keep the OAS bridge timeout env policy behind one typed helper. Deeper cwd fallback cleanup and OAS repo parser consolidation are follow-up work.

**6.2.1 Path SSOT**

- Replace the `.masc/config` concatenation in `bin/main_eio.ml:933–936` with `Config_dir_resolver.base_path_config_root`.
- Audit the 36 `Sys.getcwd` call sites in MASC `lib/` and thread explicit `base_path` where the module already has config context.
- Document remaining legitimate uses (e.g., diagnostics scripts, tests).

**6.2.2 Env Parsing SSOT**

- MASC: keep OAS bridge timeout parsing in `Env_config_oas_bridge`; document that non-positive and `nan` fall back while `infinity` is accepted as no-fire.
- OAS repo: deferred cross-repo task. This branch does not modify `oas/lib/base/util.ml`, `oas/lib/defaults.ml`, `oas/lib/llm_provider/cli_common_env.ml`, or `oas/lib/tool_result_store.ml`.

**Files to change:**

- `bin/main_eio.ml`
- `lib/config_dir_resolver/config_dir_resolver.ml` / `.mli`
- `lib/config/env_config_oas_bridge.ml` / `.mli`

**Verification:**

- Add unit tests for invalid and infinity MASC bridge timeout env values.
- Full CI build/test before merge.

---

## 7. Out of Scope

- Board lock-order fixes (already merged).
- Goal operator auth / verification principal binding (already present).
- FUSION adaptive timeout, Memory OS isolation, typed error classification, keeper registry persistence, TUI expansion — covered in later phases.

---

## 8. Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| `run_safe` fail-closed breaks tests that rely on no-clock execution | Update tests to initialize `Masc_eio_env` or expect `Internal_contract_rejected`. |
| Path SSOT changes break sandbox / voice modules that lack config context | Limit changes to modules that already accept `base_path`; leave deep refactor for Phase 4. |
| OAS env-parser consolidation changes observable warning behavior | Deferred to a dedicated OAS PR so warning-behavior tests can live with the OAS parser changes. |
| Scope creep into larger Memory OS / FUSION refactor | Strictly gate each phase; create issues for deferred items. |

---

## 9. Next Steps

1. Review this spec.
2. Keep cross-repo OAS parser consolidation in the OAS backlog or a dedicated OAS PR.
3. Verify via CI, not local full build.
