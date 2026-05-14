# OAS ↔ MASC Boundary Audit — 2026-04-30 (Phase 1)

> Status: First-pass audit. Phase 1 covers the explicit bridge layer + keeper integration (largest surface). Phases 2 (server/local/dashboard) and 3 (test/harness) deferred to follow-up PRs.
> Author: Vincent (jeong-sik) with Claude
> Created: 2026-04-30
> Tracks: Q-P0-3 (`knowledge/research/2026-04-masc-ide-strategy/IMPLEMENTATION-QUEUE.md`)
> Related: PR #12102 (forward-looking `track2_sync_boundary` policy module)

---

## 1. Purpose

Map the *current* coupling between MASC (Multi-Agent Streaming Coordination, this repo) and OAS (Open Agent SDK, external `Oas.*` package). Verify that the intended **3-layer boundary discipline** (§3) is upheld, and enumerate the modules that violate, blur, or test it.

This document is a *survey*, not a design proposal. Design changes that follow from the survey are out of scope (each one needs its own RFC).

Companion to memory rules:
- `feedback_oas-must-not-know-masc` — OAS SDK MUST NOT reference MASC types.
- `feedback_masc-must-use-oas-agent-run` — MASC must not re-implement agent lifecycle; use `Oas.Agent.run`.
- `feedback_inference-belongs-in-oas` — temperature/eval policy belongs in OAS, not MASC patches.
- `feedback_oas-follows-claude-agent-sdk` — OAS API design references Anthropic's Claude Agent SDK.

## 2. Method

```bash
# Surface-level enumeration
rg -l "open Oas|Oas\." lib/ | awk -F'/' '{print $2}' | sort | uniq -c
# → keeper:92, server:6, local:5, dashboard:4, top-level:~30

# Reverse-direction probe (does OAS adapter reference MASC types?)
rg -l "masc_|Masc\." lib/oas_worker.ml lib/oas_worker_exec.ml
# → both files contain MASC references — expected for the *adapter* layer (§3.B),
#   forbidden for the *upstream SDK* layer (§3.A, verified by checking the external Oas package).

# Pin discipline (compile-time contract)
scripts/check-oas-pin.sh
# → verifies pinned OAS API fingerprint matches installed package
```

Source coverage:
- `lib/masc_oas_bridge.{ml,mli}` (109 + 26 lines, single timeout/cancel boundary)
- `lib/oas_event_bridge.{ml,mli}`, `lib/oas_log_bridge.{ml,mli}`
- `lib/oas_worker*.{ml,mli}` (~30 files, MASC-side OAS adapters)
- `lib/keeper/keeper_*oas*.{ml,mli}` (4 files: `keeper_hooks_oas`, `keeper_tools_oas`)
- `scripts/check-oas-pin.sh` (operational gate)

---

## 3. The intended 3-layer model

| Layer | Examples | Allowed direction | Boundary rule |
|---|---|---|---|
| **A. Upstream OAS SDK** | `Oas.Agent`, `Oas.Hooks`, `Oas.Tool`, `Oas.Error`, `Oas.Types.inference_telemetry` | OAS → nothing MASC-specific | **No `masc_` / `Masc.` references**. Memory: `feedback_oas-must-not-know-masc`. |
| **B. MASC-side OAS adapter** | `lib/masc_oas_bridge`, `lib/oas_event_bridge`, `lib/oas_log_bridge`, `lib/oas_worker*.ml`, `lib/keeper/keeper_hooks_oas`, `lib/keeper/keeper_tools_oas` | both directions | Bidirectional translation; converts `Oas.Types.*` ↔ MASC types. |
| **C. MASC core** | `lib/keeper/keeper_run_tools`, `lib/coord/*`, `lib/server/*`, `lib/dashboard/*` | MASC → A only via B | Direct `Oas.*` import permitted only inside Layer B. Layer C should call helpers in Layer B (e.g. `Masc_oas_bridge.run_with_caller`). |

The audit checks (a) Layer A purity, (b) Layer B's coverage, (c) Layer C's usage discipline.

---

## 4. Findings

### 4.1 Layer A purity — PASS

`Oas.*` references in Layer A files (the external package on the pinned commit) contain zero `masc_` / `Masc.` references — verified indirectly via `scripts/check-oas-pin.sh` and direct grep against the installed opam switch (sample, not exhaustive). The pin script enforces fingerprint match at build time, so any drift would surface.

**Risk**: pin drift is detected only when CI runs the script. If the pin is updated without rerunning fingerprint capture, Layer A could regress silently. Suggest: gate pin updates on `make check-oas-pin` in pre-commit (separate PR).

### 4.2 Layer B coverage — MIXED

#### 4.2.1 `lib/masc_oas_bridge` — single source of truth for timeouts/cancellation — GOOD

```ocaml
val run_with_caller :
  caller:Env_config_oas_bridge.caller ->
  (unit -> ('a, Oas.Error.sdk_error) result) ->
  ('a, Oas.Error.sdk_error) result
```

Every OAS-bound operation in MASC core *should* go through `run_with_caller` so the per-caller timeout label is attached to Prometheus counters. Confirmed: the `caller` parameter is a typed enum (`Env_config_oas_bridge.caller`), not a string — caller-typo defenses are real.

**Evidence**: `Caller of "unknown" for backwards compatibility` in the `.mli` — backward-compat path exists but is documented and labelled distinctly. No silent default.

#### 4.2.2 `lib/oas_event_bridge` — telemetry routing — GOOD

Translates `Oas.Hooks` callback events into the MASC `Event_bus` channel. Forms the foundation for dashboard activity feeds and keeper telemetry. Clean translation layer.

#### 4.2.3 `lib/oas_log_bridge` — log routing — GOOD

Routes OAS structured logs into the MASC log sink with provider/model labels. Symmetric to `oas_event_bridge`.

#### 4.2.4 `lib/oas_worker*.ml` (~30 files) — adapter sprawl — RISK

`oas_worker.ml` (95 references) is the largest single MASC-side OAS user. Its sub-modules (`oas_worker_exec`, `oas_worker_exec_agent`, `oas_worker_exec_checkpoint`, `oas_worker_exec_transport`, `oas_worker_named*`, `oas_worker_cascade`) are an *agent-runtime translation layer* between OAS `Agent.run` semantics and MASC's keeper turn loop.

The sprawl is justified by the surface area of `Oas.Agent.run` (cascade fallback, named-error variants, transport pluggability), but it is **not a single boundary** — it is a fan-out. A future reader cannot answer "where does MASC call OAS?" with a single file. Suggest follow-up: a `lib/oas_worker/dune` sub-library + a single re-export module (`Keeper_turn_driver.t`) so Layer C consumers see one symbol.

#### 4.2.5 `lib/keeper/keeper_hooks_oas`, `lib/keeper/keeper_tools_oas` — hook factories — GOOD

```ocaml
val provider_of_model_with_telemetry :
  model:string ->
  telemetry:Oas.Types.inference_telemetry option -> string
```

These two modules wrap `Oas.Hooks.t` and `Oas.Tool.t list` for the keeper turn loop. They consume `Oas.Types.inference_telemetry` (Layer A type) and produce MASC-typed records (`tool_call_entry`, etc.). Symmetric, well-typed translation. No leaks observed.

### 4.3 Layer C usage discipline — needs sweep

Layer C should only import `Oas.*` *via* Layer B helpers. Spot check:

- `lib/keeper/keeper_run_tools.ml` (62 references) — high `Oas.*` count. Some calls use `Masc_oas_bridge.run_with_caller`; others appear to call `Oas.Agent.run` directly. Worth a focused grep (deferred to Phase 2).
- `lib/keeper/keeper_context_core.ml` (91 references) — second-highest count. Same status.
- `lib/keeper/keeper_guards.ml` (47 references) — guard-tier code; some `Oas.*` references appear to be type annotations only (zero-cost), but a structural check is needed.

**Suggestion** (deferred): a ratchet metric `direct_oas_imports_in_layer_c` floored at the current count; new violations fail CI.

### 4.4 Reverse-coupling check — PASS with caveat

`rg -l "masc_|Masc\." lib/oas_worker.ml lib/oas_worker_exec.ml` returns both files. **This is expected**: these are Layer B (adapter) modules; they convert MASC types to/from Layer A types and therefore must reference both. The rule (`feedback_oas-must-not-know-masc`) targets Layer A specifically — verified separately above.

**Caveat**: there is no automated check today that distinguishes Layer A from Layer B for this rule. A heuristic would be `rg masc_ | grep -v 'lib/oas_'` against the *upstream* OAS source tree (separate repo, not in this audit's scope).

---

## 5. Open questions

1. **PR #12102 (`track2_sync_boundary`) and Layer B**: the new module formalizes a *forward-looking* sync boundary on the MASC side. Does it belong in Layer B (translation) or Layer C (policy)? On reading the `.mli` (56 lines), it expresses *MASC-owned* admission rules — Layer C. Confirms the boundary discipline.
2. **`oas_worker*` sub-library**: 30 files, no sub-library. Worth promoting to `lib/oas_worker/` with its own `dune`?
3. **Ratchet for Layer C direct imports**: feasible but needs a stable `lib/keeper/` baseline first.
4. **Test-tier discipline (Phase 3)**: `test/` likely contains direct `Oas.*` imports for fixture creation. Acceptable in tests, but worth measuring drift.

---

## 6. Phase plan

| Phase | Scope | Trigger |
|---|---|---|
| **1 (this PR)** | Bridge layer + keeper OAS hooks (~10 files) | now |
| **2** | Layer C sweep: `keeper_*` non-OAS files + `server/` + `dashboard/` (~20 files) | next OAS audit cycle |
| **3** | `test/` and `benchmark/` (~15 files); reverse-grep against external OAS source | when external OAS repo is published |
| **4** | Ratchet PR: floor `direct_oas_imports_in_layer_c`, sub-library `oas_worker/` | after Phase 2 baseline |

Each phase ships as a separate PR. This document is the index; the audit grows with each phase.

---

## 7. Non-goals

- Refactor recommendations beyond the suggestions section. Each is a separate RFC.
- Performance analysis. Boundary discipline is a structural concern; perf is orthogonal.
- License/copyright inventory of the `Oas.*` package. See `docs/legal/LICENSE-AUDIT-2026-04.md` (#12034 MERGED).

---

## 8. References

- `lib/masc_oas_bridge.{ml,mli}` — single timeout/cancel boundary (Layer B)
- `lib/oas_event_bridge.{ml,mli}` — telemetry routing
- `lib/oas_log_bridge.{ml,mli}` — log routing
- `lib/oas_worker*.{ml,mli}` — agent-runtime adapter sprawl (Layer B, suggest sub-library)
- `lib/keeper/keeper_hooks_oas.{ml,mli}` — `Oas.Hooks` factory
- `lib/keeper/keeper_tools_oas.{ml,mli}` — `Oas.Tool.t list` bundler
- `scripts/check-oas-pin.sh` — pin discipline gate
- PR #12102 — `track2_sync_boundary` (forward-looking Layer C policy)
- `docs/legal/LICENSE-AUDIT-2026-04.md` — license audit (#12034)
- Memory: `feedback_oas-must-not-know-masc`, `feedback_masc-must-use-oas-agent-run`, `feedback_inference-belongs-in-oas`, `feedback_oas-follows-claude-agent-sdk`

*Audit date: 2026-04-30 / Phase 1 of 4 / docs-only, code change = 0*
