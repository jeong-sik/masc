# OCaml-docstring line-reference drift class — survey + first fix (N-2.e)

**Date**: 2026-05-12 · **Iteration**: 71 (`/loop` FSM/TLA+/OCaml drift hunt)
**Scope**: `lib/keeper/*.{ml,mli}` "Spec navigation (OCaml -> TLA+)" reverse-citation blocks that cite their own functions/types at `(~line N)`.
**Verdict**: this is the OCaml-docstring twin of the 8th drift sub-class (TLA-preamble line-reference drift, iter 63 KAQ N-1). iter 64 N-2.a fixed the *spec preamble* side and N-2.c added a guard (`scripts/audit-tla-ml-line-refs.sh`) — but that guard only scans `specs/keeper-state-machine/*.tla`, not OCaml docstrings, and `scripts/audit-ocaml-phase-count.sh` only checks phase counts. So the OCaml-side mirror of the same stale citations has gone uncaught. This PR fixes the clearest case (`keeper_approval_queue.ml`, N-2.e) and catalogues the rest.

## Survey (`rg '\(~?line [0-9]+\)' lib/keeper/*.ml`)

| Module | Cited | Actual | Drift | Status |
|---|---|---|---|---|
| `keeper_approval_queue.ml` | `[submit_and_await] (~line 751)`, `[submit_pending] (~line 772)`, `[expire_stale] (~line 941)` + quotes the spec's old "at line 751/772/941" | 996 / 1089 / 1335 | +245 / +317 / +394 | **fixed in this PR (N-2.e)** — same numbers iter 64 N-2.a removed from `KeeperApprovalQueue.tla`; the OCaml docstring still carried them *and* quoted the now-removed spec text |
| `keeper_failure_circuit_breaker.ml` | `[type error_class] (this file, ~line 17)` | 46 | +29 | fixed in iter 70 #14939 (KCB R-1) |
| `keeper_memory_policy.ml` | `[short_term_horizon] (~line 165)`, `[memory_horizon_of_kind_opt] (~line 171)`, `[memory_horizon_of_kind] (~line 182)` — plus a "Spec line drift correction" block that itself says "actual line is 165 (+10 drift)" | 204 / 210 / 221 | +39 each (and the drift-correction note is itself +39 stale: it claims actual 165, real is 204) | **N-2.f candidate** — the docstring already concludes "function-name citations remain stable", contradicting its own `(~line N)` markers; clean fix = drop all line numbers, keep the semantic notes (mid-term default + #8826) |
| `keeper_execution_receipt.ml` | `[append] (~line 455)` | 879 | +424 | **N-2.g candidate** |
| `keeper_heartbeat_loop.ml` | quotes `Spec line 4 cites this function "at line 1815"; the actual current line is 1828 (drift +13)` | spec preamble no longer says "at line 1815" (iter 64 N-2.c removed `run_heartbeat_loop at line 1828` from `KeeperHeartbeat.tla`) | n/a — self-aware about its own drift, but the *quote of the spec* is now stale | **N-2.h candidate** — update to note the spec uses function-name-only refs now |

(Out of scope here: internal cross-references in `keeper_unified_turn.ml`, `keeper_stale_watchdog.ml`, `keeper_supervisor.ml` that cite *other* functions in *other* modules by line — a different concern, harder to validate, lower payoff.)

## The fix in this PR (N-2.e — `keeper_approval_queue.ml`)

Before: the docstring said *"Spec lines 5-6 already cite this module: '[submit_and_await] at line 751, [submit_pending] at line 772, [expire_stale] at line 941'"* and the action-mapping table marked each function `(~line 751/772/941)`. After iter 64 N-2.a, `KeeperApprovalQueue.tla`'s preamble no longer contains those line numbers — so the OCaml quote was doubly wrong (stale numbers + quoting text that no longer exists). After: the docstring says the spec preamble cites by function name, notes that line numbers were removed in iter 64 N-2.a after drift reached +245..+413, and the action-mapping table cites `[submit_and_await]` / `[submit_pending]` / `[expire_stale]` with no line numbers.

## Why this matters

When iter 64 fixed the spec-preamble side of the line-ref drift, the OCaml-side reverse-citation was left holding the same stale numbers — and worse, *quoting the spec text that iter 64 deleted*. A reader following the reverse citation from `keeper_approval_queue.ml` lands at `~line 751` (a `find_pending_id_in_map` lookup utility) or believes the spec still says "at line 751". The asymmetry — fixing one direction of a bidirectional citation but not the other — is exactly the kind of half-finished migration the loop's audit→fix→guard discipline exists to close. N-2.f/g/h finish the OCaml side; R-1.a is the structural guard.

## Follow-up candidates

- **N-2.f (LOW)** — `keeper_memory_policy.ml` docstring: drop the three `(~line N)` markers and the stale "Spec line drift correction" block, keep the `memory_horizon_of_kind` mid-term-default note and the #8826 reference. The docstring already states the right principle ("function-name citations remain stable").
- **N-2.g (LOW)** — `keeper_execution_receipt.ml`: `[append] (~line 455)` → `[append]` (actual 879, +424).
- **N-2.h (LOW)** — `keeper_heartbeat_loop.ml`: update the "Spec line 4 cites this function 'at line 1815'" quote — `KeeperHeartbeat.tla` now uses function-name-only references (iter 64 N-2.c).
- **R-1.a (MED)** — extend `scripts/audit-tla-ml-line-refs.sh` (or add a sibling `audit-ocaml-spec-nav-line-refs.sh`) to scan `lib/keeper/*.{ml,mli}` "Spec navigation" blocks for `\[([a-z_]+)\]\s*\(~?\s*line\s+(\d+)\)` and verify `^let \1` / `^type \1` is within tolerance. The OCaml-docstring twin of R-H-1.f. Would catch all of N-2.{e..h} automatically and any future re-introduction.

## Verification (this audit + fix)

```
$ rg -n '~line 751|~line 772|~line 941|at line 751' lib/keeper/keeper_approval_queue.ml   # 0 after fix
$ rg -n '^let submit_and_await|^let submit_pending|^let expire_stale' lib/keeper/keeper_approval_queue.ml   # 996 / 1089 / 1335
$ dune build test/test_keeper_approval_queue*.exe   # (see PR — comment-only, no behaviour change)
```

## RFC trail

`keeper_approval_queue.ml` is not in the credential/identity/operator/sandbox/hooks/workflow RFC-required set — RFC-WAIVED for the comment-only docstring fix. Spec lineage: `Cycle 9 / Tier B3, PR #11417`.
