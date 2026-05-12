# KAQ N-1 — KeeperApprovalQueue spec ↔ OCaml line-reference drift (audit)

**Iteration**: /loop iter 63 — first entry to Phase N (`KeeperApprovalQueue.tla`).
**Date**: 2026-05-12.
**Scope**: audit-only.
**MASC tracking**: "Cycle 9 / Tier B3 of the Kimi keeper FSM review plan" (spec preamble line 37).

## Discovery

KAQ stands apart from the previous five-spec first-entry sweep (KAL/KRL/KOAS): the OCaml runtime **exists, is wired, and behaves as the spec describes**. `Eio.Promise.resolve resolver (Reject reason)` does fire from the expire path. The bug-model fixture (`SpecBuggy ≡ Spec ∨ ExpireStaleNoResolve` + `QuiescentImpliesResolved`) is paired. But the spec's *line-number citations* are 245–413 lines stale relative to the current OCaml file.

| Spec citation | Function | OCaml line today | Drift |
|---------------|----------|------------------|-------|
| line 751 | `submit_and_await` | 996 | +245 |
| line 772 | `submit_pending` | 1089 | +317 |
| line 941 | `expire_stale` | 1335 | +394 |
| line 970-972 (resolver call) | inside `expire_stale` | 1384 | +413 |

Cross-checked: every cited function exists today.  The spec's behavioural claims are accurate.  The line numbers are not.

Concrete failure mode: a reader landing on KAQ.tla and using the line numbers to jump into the OCaml file finds the JSON serialization helper `pending_entry_json_fields` (line 758) instead of `submit_and_await`.  At line 941 they find `find_pending_id_in_map`, not `expire_stale`.  Two interpretations follow:
1. *Spec is stale* — assume the design abandoned, drop the spec.
2. *Spec is right, OCaml moved* — keep grepping for the function name to find it.

The latter resolves; the former wastes the spec.  But there's no way to tell at first read which is true.

## New first-entry sub-class: line-reference drift (8th)

Distinct from KRL (concepts missing entirely) and KOAS (concepts missing, paired bug-model). Here the runtime is *correct*; only the spec's pointers are stale.

| iter | Spec | Sub-class | Runtime axis | Spec axis |
|------|------|-----------|--------------|-----------|
| 1 | KSM A-1 | coverage gap | mature | mature |
| 22 | KCR C-1 | spec drift | mature | mature |
| 38 | KCL E-1 | cross-spec staleness | mature | mature |
| 47 | KCtxL H-1 | doc-layer drift | mature | mature |
| 56 | KAL K-1 | dormancy (flag-gated) | dormant | mature |
| 58 | KRL L-1 | design-ground (no runtime) | missing | weak |
| 61 | KOAS M-1 | design-ground + verified bug-model | missing | strongest |
| **63** | **KAQ N-1** | **line-reference drift (functions intact, line numbers stale)** | **mature** | **mature with stale pointers** |

KAQ is the first first-entry where both axes are mature and the drift is purely *pointer staleness*.  This is the OCaml/Markdown twin of the 6th drift class (TLA+ doc count drift) — both classes drift because the doc string is not in any compile or test path that catches misalignment.

## Bug-model status

Verified per spec preamble: `Spec` under `KeeperApprovalQueue.cfg` is "no error", `SpecBuggy` under `-buggy.cfg` violates `QuiescentImpliesResolved`.  Not re-run inside this loop (TLC not transparent for behavioural specs); recommended as N-2.d follow-up.

The bug action `ExpireStaleNoResolve` is operationally important: it models the regression where `expire_stale` drops the pending entry without resolving the promise, leaving a fiber suspended on `Eio.Promise.await` forever.  The current OCaml code (line 1384 `Eio.Promise.resolve resolver (Agent_sdk.Hooks.Reject reason)`) honors the spec; a future refactor that moves cleanup before resolve, or that lands an early-return path, reintroduces the bug class.

## N-2 follow-up RFC candidates

These are call-outs; **not fixes in this audit**.

| Tag | Risk | Description |
|-----|------|-------------|
| **N-2.a** | LOW doc | Replace the four stale `line N` citations in the KAQ preamble (line 5 and line 31) with function-name only references.  Function names are stable under refactor; line numbers are not.  Mirrors the spec-side fix iter 59 L-2.b applied to KRL broken citations.  **14th honest-doc datapoint candidate** after iter 62 M-2.a (#14913) settles. |
| **N-2.b** | LOW spec | Add a "Runtime status: production behaviour matches spec (line refs may be stale; trust function names)" preamble note.  Same K-2.d / L-2.a / M-2.a shape but with the runtime-matches-spec flavour. |
| **N-2.c** | MED structural | Introduce a `audit-tla-ml-line-refs.sh` script that scans every spec preamble for "line N" patterns and verifies the cited line in the cited `.ml` file actually defines the cited function (heuristic: nearest preceding `let <name>`).  Closes the 8th drift class structurally, mirroring iter 52 #14874 (R-H-1.c phase-count validator) for the TLA+ side and iter 55 #14891 for OCaml side.  Single-purpose validator. |
| **N-2.d** | LOW TLC | Re-run `KeeperApprovalQueue.cfg` and `-buggy.cfg` inside the loop to confirm the spec-stated behaviour still holds (memory snapshot is the original "Kimi keeper FSM review" date, not 2026-05-12). |

## Verification (this audit)

| Check | Result |
|-------|--------|
| `wc -l specs/keeper-state-machine/KeeperApprovalQueue.tla` | 140 LOC |
| `wc -l lib/keeper/keeper_approval_queue.ml` | 1401 LOC |
| `rg -n '^let (submit_and_await\|submit_pending\|expire_stale)' lib/keeper/keeper_approval_queue.ml` | 3 hits at lines 996 / 1089 / 1335 |
| `rg -n 'Promise.resolve' lib/keeper/keeper_approval_queue.ml` | 4 hits, expire-path at 1384 |
| `wc -l lib/keeper/keeper_approval_queue.mli` | 264 LOC (includes `val expire_stale`) |

No spec / OCaml / cfg mutation.  +90 LOC docs/ only.

## RFC trail

RFC-WAIVED — audit-only memo.  Recommended follow-up RFCs:
- N-2.a (preamble line-ref → function-name; 14th honest-doc datapoint)
- N-2.b (preamble Runtime status block; runtime-matches-spec variant)
- N-2.c (structural validator `audit-tla-ml-line-refs.sh`; R-B-1.c family extension)
- N-2.d (TLC verify refresh)

Most leverage: N-2.c structural validator.  Without it, every spec edit silently grows the drift over time.

## Pattern observation

Phase A–G specs (mature runtime, mature spec) drift on *what* the modeled behaviour says or how it is collapsed.  Phase K–N specs reveal a different class: drift on *where* the cited code lives.  iter 60 K-2.c demonstrated the inverse (spec correct, OCaml side stale) — but that was a hand-fix.  N-2.c structural validator generalises both directions.

If iter 64+ adopts N-2.a as the immediate fix and N-2.c as the structural follow-up, the line-reference drift becomes the second drift class (after iter 49-53 phase-count) to receive end-to-end closure (audit → fix → validator) within the loop.
