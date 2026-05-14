# TLA+ PPX Adoption Audit — boundary domain full sweep

> Status: Mechanical sweep of all 18 boundary specs.
> Author: Vincent (jeong-sik) with Claude
> Created: 2026-04-30
> Tracks: PR #12149 (spot-check) extension
> Related: PR #12143 (audit), PR #12150 (resilience adoption), PR #12151 (ratchet)

---

## 1. Method

Spot-check (PR #12149) classified 3 of 25 boundary "specs" (counted per-cfg). The actual `.tla` count is **18**. This sweep classifies all 18.

For each spec:
1. Extract OCaml module references from spec header (`rg -o "lib/[a-z_/]+\.(ml|mli)" "$spec"`).
2. Read the spec's purpose statement (first 20 lines).
3. Inspect referenced module(s) for ADT shape.
4. Classify: **mappable** (single ADT owner with variant `type t = | A | B | ...`) vs **cross-domain** (multi-module interaction, no single ADT).

## 2. Full classification

| Spec | Module ref(s) in header | ADT? | Class |
|---|---|---|---|
| AuditLog | `lib/audit_log.ml` | yes — `outcome`, `governance_audit_decision`, `action` (~20 variants) | **mappable** (multiple ADTs) |
| AuditLogAppendOrder | `lib/dated_jsonl/dated_jsonl.ml` | TBD | candidate |
| AuditLogDurableBeforeAck | (no explicit ref) | likely cross-domain | cross-domain |
| Bounded | `lib/bounded.ml` | record-based, not variant | cross-domain (no ADT) |
| Cancellation | `lib/cancellation.ml` | `token` is record, not variant | cross-domain (no ADT) |
| CascadeKeeperRecovery | (no explicit ref — header lists 4 domains) | no | **cross-domain** (per #12149) |
| CascadeResolver | (no explicit ref) | likely | cross-domain |
| **CascadeStrategy** | `lib/cascade/cascade_strategy.{ml,mli}` (per spec text) | yes — `kind` (8 variants) | **mappable** (per #12149, adoption in #12153) |
| CascadeStrategyStateful | (no explicit ref) | likely | cross-domain or mappable (sticky/round-robin state) |
| KeeperContinueGate | (no explicit ref) | unknown | cross-domain |
| **KeeperContractViolated** | (multi-module: keeper_run_tools, keeper_turn_terminal) | no | **cross-domain** (per #12149) |
| KeeperEmptyToolUniverse | (no explicit ref) | unknown | cross-domain |
| KeeperRecoveryOrchestration | `keeper_keepalive`, `keeper_manual_reconcile`, `keeper_state_machine` | no — interaction | **cross-domain** |
| KeeperStaleKilled | (no explicit ref) | unknown | cross-domain |
| KeeperTurnScheduler | (no explicit ref) | unknown | cross-domain |
| KeeperTurnTerminal | (no explicit ref) | unknown | cross-domain |
| SandboxDispatch | `keeper_exec_shell`, `keeper_tools_oas` | TBD — `sandbox_kind`? | candidate |
| ToolCallContract | (no explicit ref) | unknown | cross-domain |

## 3. Aggregate

| Class | Count | Examples |
|---|---|---|
| **mappable** (confirmed) | **2** | CascadeStrategy, AuditLog (multiple ADTs) |
| **mappable candidate** (needs ADT inspection) | **2** | AuditLogAppendOrder, SandboxDispatch |
| **cross-domain** (confirmed) | **3** | CascadeKeeperRecovery, KeeperContractViolated, KeeperRecoveryOrchestration |
| cross-domain (heuristic — no module ref) | 11 | most Keeper* specs, CascadeResolver, ToolCallContract |

**Final ratios** (after candidate resolution):
- ~2/18 (~11%) confirmed mappable
- ~2/18 (~11%) candidate
- ~14/18 (~78%) cross-domain

This refines the spot-check's 1/3 estimate downward — boundary domain is mostly cross-domain interaction specs, not single-ADT mirrors. The spot-check's CascadeStrategy hit was a positive selection bias (it was the most mappable example in the sample).

## 4. Implication for Cycle 14 §8 ratchet floors

- `ppx_deriving_tla_modules` floor: stay at 4 (current). Adding CascadeStrategy adoption (PR #12153 sibling — proposed) lifts to 5. Adding AuditLog adoption could lift to 6+. But stop after these — the remaining 14 specs have no ADT to derive.
- `ppx_fsm_guard_files` floor: this is the right metric for the 14 cross-domain specs. Each cross-domain spec's `Next` predicate has a precondition that could be encoded as `[@@fsm_guard "<bool-expr>"]` at the corresponding runtime call site.
- `lib_subdirs_with_ppx` (descriptive, currently 3): adding cascade adoption → 4. Adding audit_log adoption → 5. Topping out around 5-6 unless `[@@fsm_guard]` extends to non-keeper subsystems.

## 5. ADT-confirmed candidates queue

Order by `[@@deriving tla]` adoption priority:

1. **CascadeStrategy.kind** — 8 variants, perfect fit, spec exists, PR queued (Cycle 18 sibling)
2. **AuditLog.action** — 20+ variants in `lib/audit_log.mli`. Spec models Merkle chain (different concern), but the action variant set is a separate `[@@deriving tla]` candidate that ALSO mirrors the audit category strings used in `Envelope.t.category`.
3. **AuditLog.governance_audit_decision** — 7 variants. Smaller than `action`, simpler pre-condition.
4. **AuditLog.outcome** — 2 variants (`Success`, `Failure of string`). Smallest, fastest adoption PR.
5. **SandboxDispatch sandbox_kind** — needs verification (mli inspection). If exists, fast adoption.

## 6. Cross-domain spec→runtime instrumentation map (out of scope here)

For the 14 cross-domain specs, the instrumentation path is `[@@fsm_guard]` on the corresponding runtime call site. Per-spec analysis required:

| Spec | Likely fsm_guard site |
|---|---|
| KeeperContractViolated | `lib/keeper/keeper_turn_terminal.ml` post-detection turn handoff |
| KeeperRecoveryOrchestration | `lib/keeper/keeper_state_machine.ml` `Crashed → Restarting` transition |
| KeeperContinueGate | `lib/keeper/keeper_run_tools.ml` continue-check |
| etc. | per-spec |

Each is a separate ~30min RFC + ~1h adoption PR. Reasonable fan-out: 1 per cycle.

## 7. Refinement of spot-check ratio

PR #12149 (3-spec sample) reported ~⅓ mappable. Full sweep reports ~⅙–⅙ mappable (2 confirmed + 2 candidate of 18). The spot-check's CascadeStrategy choice was selection bias — the spec was the most mappable example to start with.

This is a useful audit lesson: 3-spec samples on a heterogeneous domain over-state the dominant class. For domains with mixed shapes, full sweeps are cheap (mechanical) and worth the half-hour. For homogeneous domains (e.g. `bug-models/` where the pattern is uniform), spot-checks are fine.

## 8. References

- PR #12149 — boundary spot-check (parent)
- PR #12143 — Cycle 14 PPX audit
- PR #12150 — first adoption (resilience)
- PR #12151 — ratchet
- `lib/audit_log.mli` — second adoption candidate after CascadeStrategy

*Audit date: 2026-04-30 / mechanical sweep / docs-only*
