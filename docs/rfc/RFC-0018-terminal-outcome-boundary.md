# RFC-0018: Compile-time receipt enforcement at `run_turn` boundary

- **Status**: Draft
- **Author**: vincent (with Claude)
- **Created**: 2026-04-30
- **Related**: 2026-04-28 Kimi keeper FSM audit (§1.2.2 SilentReceiptDrop, §8.3 "Receipt is a Side Effect"); Cycle 5 PR (`keeper_agent_run.ml:1290-1343` Result.Error promotion); RFC-0003 (KeeperCompositeLifecycle invariants)
- **Drives**: Make "turn exits without an authoritative receipt" a compile-time error at the `run_turn` boundary. Move enforcement upstream of the runtime check that Cycle 5 already established.
- **Supersedes for this codebase**: the audit's §8.3 Option (a) — embedding `receipt` as a payload field on `Keeper_turn_fsm.turn_state` constructors `Done | Failed | Cancelled`. See §2 for why the literal recommendation does not fit this codebase's actual `turn_state` role.

## 1. Problem

The Kimi audit (§1.2.2) flagged `SilentReceiptDrop`: a turn could exit `run_turn` reporting `Ok` without having appended a durable execution receipt. TLA+ specs `EveryTurnHasTerminalReceipt` and `ReceiptMatchesState` (specs/keeper-turn-fsm/KeeperTurnFSM.tla:314-327) formalise the invariant; OCaml had no compile-time enforcement.

Cycle 5 (PR landed before 2026-04-29) plugged the runtime channel: receipt-append failure now propagates as `Error (Oas.Error.Internal _)` instead of a WARN log + silent continue (`lib/keeper/keeper_agent_run.ml:1290-1343`). This means *if* the receipt-append site is reached, drop is impossible.

The remaining gap is **structural**: nothing prevents a future code path from returning `Ok` *without ever calling* the receipt-append site. The audit's §8.3 recommendation was to fold receipt into the terminal `turn_state` constructors so that "construct a terminal turn_state without a receipt" becomes a type error.

## 2. Why the audit's literal recommendation does not fit

Implementation attempt 2026-04-30 surfaced three structural mismatches between the audit's mental model and the actual code shape.

### 2.1 `turn_state` is telemetry-only, not a data product

`Keeper_turn_fsm.turn_state` is *emitted* via `Keeper_turn_fsm.emit_transition` from at least 8 sites in `lib/keeper/keeper_unified_turn.ml` (lines 101, 215, 304, 350, 770, 1300, 1942, plus 1640/1644/1947 wrap-points). At each call:

- A `~prev` state and a *next* terminal (e.g. `Cancelled Cancelled_supervisor_stop`) are emitted as a structured log line for `bin/masc-trace` consumption.
- The actual data result of the turn is a **separate** `Ok meta | Error sdk_error` value flowing back through `run_turn` / `run_keeper_cycle`.

The audit assumed `turn_state` was the *data product* of a turn (so that "construct it without receipt" was the right enforcement point). It is not.

### 2.2 Receipt is built once, at one site, near turn-end

`Keeper_execution_receipt.append` is called from a single region (`keeper_agent_run.ml:1290-1343`). Receipt construction depends on the entire turn's accumulated state: response text, tool calls, prompt metrics, cascade attempts, etc.

Most early-fail emit sites (e.g. `cascade_unavailable` at line 215, `livelock_blocked` at line 350) fire **before** receipt assembly is possible. Adding `receipt: Receipt.t` to `Failed` would force these sites to either fabricate a partial receipt at emit time (defeats the durability guarantee) or defer the emit until a receipt is built (defeats the "we got past phase X" telemetry semantic).

### 2.3 Module dependency cycle

`Keeper_execution_receipt.t` is a flat record with ~40 fields including provenance, tool surface, cascade rotations, prompt metrics. It is currently a leaf-level type module. `Keeper_turn_fsm` does not depend on it: the `.mli` references `Keeper_turn_fsm` only in comments (`keeper_execution_receipt.mli:64-65`).

Adding `Keeper_execution_receipt.t` as a `turn_state` constructor payload requires `Keeper_turn_fsm` → `Keeper_execution_receipt`. Receipt's existing `assert_receipt_authoritative` API takes `turn_state: string` rather than the typed value precisely so this cycle stays broken. The RFC must keep that property.

## 3. Design principles

| # | Principle | Application |
|---|-----------|-------------|
| P1 | **Move enforcement to the boundary, not the enum.** `turn_state` describes *which lane the turn is in*; the boundary describes *what crossed back out*. Receipt belongs on the boundary. | `run_turn`'s OK return type carries the receipt; `turn_state` enum stays unchanged. |
| P2 | **Compile-time impossibility, not runtime check.** Cycle 5 plugged the runtime; the next gate is the type system. | Constructor of the new boundary type requires a `Keeper_execution_receipt.t` argument. No receipt → no value → no `Ok` return. |
| P3 | **Preserve telemetry semantics.** The 8+ `emit_transition` sites are observability, not data flow. They must keep emitting the partial-progress signal. | New module re-exports `Keeper_turn_fsm.turn_state` for telemetry consumers; the receipt-bearing type is a downstream wrapper. |
| P4 | **Leaf-only dependencies.** No new cycles. | New `Keeper_turn_outcome` module depends on both `Keeper_turn_fsm` and `Keeper_execution_receipt`; both remain leaves. |

## 4. Signature

```ocaml
(* lib/keeper/keeper_turn_outcome.mli *)

(** Receipt-bearing terminal outcome of a turn body.

    A value of this type cannot be constructed without an authoritative
    [Keeper_execution_receipt.t]. Threading this type through
    [run_turn]'s OK arm makes [SilentReceiptDrop] a compile error at
    the boundary: any caller that fabricates an [Ok] return without a
    receipt is rejected by the type checker. The receipt is exactly
    the value the [Cycle 5] append site already builds — only the
    plumbing changes. *)

type t =
  | Done       of { receipt : Keeper_execution_receipt.t }
  | Failed     of { reason  : Keeper_turn_fsm.failure_reason
                  ; receipt : Keeper_execution_receipt.t }
  | Cancelled  of { reason  : Keeper_turn_fsm.cancel_reason
                  ; receipt : Keeper_execution_receipt.t }

val receipt       : t -> Keeper_execution_receipt.t
val to_turn_state : t -> Keeper_turn_fsm.turn_state
val outcome_kind  : t -> Keeper_execution_receipt.outcome_kind

(** [Done]/[Failed]/[Cancelled] map 1:1 to the three terminal
    constructors of [Keeper_turn_fsm.turn_state]. [to_turn_state]
    exposes the embedded [reason] so existing telemetry sites can
    keep emitting the structured log line. *)
```

`run_turn`'s OK type changes from `run_result` to `Keeper_turn_outcome.t` (or a wrapper that contains it):

```ocaml
(* before *)
val run_turn : ... -> (run_result, Oas.Error.sdk_error) result

(* after *)
val run_turn : ... -> (Keeper_turn_outcome.t, Oas.Error.sdk_error) result
```

`turn_state` enum is **unchanged**. The 8+ `emit_transition` sites continue to emit telemetry as today. The `[@@deriving tla]` parity test (`test_keeper_turn_fsm_tla_parity`) continues to pin the `turn_state` ↔ `KeeperTurnFSM.tla` symbol mapping.

## 5. Migration plan

Atomic compiler-driven migration in four PRs, each green-able in isolation:

| PR | Scope | LOC est. | Verification |
|----|-------|----------|--------------|
| A  | Add `Keeper_turn_outcome` module with constructors + helpers; do **not** change `run_turn` yet. | +200 | `dune build` green, new module exercised by unit test. |
| B  | Migrate `run_turn`'s exit point: build a `Keeper_turn_outcome.t` wherever `Ok meta` was previously returned. Receipt-append site becomes the **constructor** for `Done` / `Failed` / `Cancelled`. | +150 mech. updates | Parity test green; receipt continues to append exactly once per terminal. |
| C  | Update consumers (`keeper_unified_turn.ml`, `keeper_heartbeat_loop.ml`, telemetry/dashboard adapters) to destructure `Keeper_turn_outcome.t` instead of `run_result`. | +100 | `dune build` green; manual smoke shows turn end produces durable receipt. |
| D  | Add a negative-compile fixture asserting `Ok meta_without_receipt` is a type error. | +30 | `dune build @runtest` fails the fixture as expected. |

Total: ~480 LOC. Cost increase is real vs the audit's 150-250 estimate, but the design avoids the 8+ telemetry-site invasion and the dep cycle.

## 6. Trade-offs

|  | Audit option (a) | This RFC (boundary wrapper) |
|---|---|---|
| Compile-time guarantee | ✅ at `turn_state` constructor | ✅ at `run_turn` return |
| Telemetry sites preserved | ❌ all 8+ sites need receipt | ✅ unchanged |
| Module dependencies | ❌ cycle (turn_fsm ↔ receipt) | ✅ leaf-to-leaf, one-way |
| LOC delta | 150-250 | ~480 |
| `turn_state` enum touched | yes (variant payload change) | no |
| `[@@deriving tla]` impact | re-verify parity | none (unchanged) |
| `Failure_receipt_lost` ctor | becomes unreachable | becomes unreachable |
| Maps to TLA invariant `EveryTurnHasTerminalReceipt` | direct (variant constraint) | indirect (return-type constraint) |

The "indirect mapping" is the main concession. We are not type-encoding `EveryTurnHasTerminalReceipt` literally; we are type-encoding *one consequence* of it (no terminal exit without receipt). This is acceptable because:

- The TLA invariant is about what the spec *permits* at the state-machine level
- Our enforcement is about what the *runtime exit boundary* *guarantees*
- Both pin the same operational property; one is upstream, one is downstream

## 7. Acceptance criteria

A future PR series implementing this RFC must:

1. Add `Keeper_turn_outcome.t` with the three terminal constructors carrying mandatory `receipt`.
2. Change `run_turn`'s OK-case type to `Keeper_turn_outcome.t`.
3. Provide `Keeper_turn_outcome.to_turn_state` so consumers can still emit transitions.
4. Pass `dune exec test/test_keeper_turn_fsm_tla_parity.exe` — parity preserved.
5. Pass `bash scripts/tla-ppx-ratchet.sh` — adoption count not regressed.
6. Add a negative-compile fixture asserting `Ok` cannot be returned without a receipt.
7. Update `lib/keeper/keeper_agent_run.ml:1290-1343` so the receipt-append site is the *constructor* of the `Keeper_turn_outcome.t`, not a side-effect after the fact.
8. `Failure_receipt_lost` constructor remains in `failure_reason` (deprecated comment) to preserve receipt-JSON serialization compat for external consumers; remove in a separate cleanup PR after one release cycle.

## 8. Open questions

- **Q1 — External consumer JSON shape.** Does any external consumer (dashboard JSON, audit_log replay, agentic-bench harness) deserialize `run_result` directly? If so, the JSON shape needs a compatibility shim or an explicit migration window. Owner check needed before PR B.
- **Q2 — `assert_receipt_authoritative` overload.** The helper currently takes `turn_state: string`. Should it gain an overload `from_outcome : Keeper_turn_outcome.t -> ...`? Defer to PR C — only add if a consumer wants it.
- **Q3 — `[@@deriving tla]` on the new type.** Could be added to `Keeper_turn_outcome.t` itself, mapping `Done/Failed/Cancelled` to `ReceiptOutcomeSet` symbols. Worth doing in PR A, or defer to a follow-up?

## 9. Why the implementation is gated by user review

This RFC must wait for explicit approval before the PR series starts because:

- The receipt-append site refactor (PR B) is in the keeper hot path
- The `run_turn` signature change ripples through `keeper_unified_turn.ml`, `keeper_heartbeat_loop.ml`, and telemetry adapters
- 480 LOC is large enough that race-checking against parallel work in the same files matters; bundling implementation with in-flight PRs (#12242, #12247) would risk merge conflicts
- The Q1 "external consumer" question deserves a deliberate answer, not an autonomous guess

## 10. Reference

- Audit: `~/Downloads/Kimi_Agent_Keeper FSM 검토/MASC-MCP_Keeper_종합진단보고서.md` §1.2.2, §8.3
- Cycle 5 site: `lib/keeper/keeper_agent_run.ml:1290-1343` (Result.Error promotion comment)
- TLA invariants: `specs/keeper-turn-fsm/KeeperTurnFSM.tla:314-327` (`EveryTurnHasTerminalReceipt`, `ReceiptMatchesState`, `ReceiptOutcomeSet`)
- Plan: `~/me/planning/claude-plans/greedy-sleeping-blossom.md` (PPX rigor track gap-fill)
