# KCB R-1 — KeeperCircuitBreaker.tla ↔ OCaml: mapping verified, one docstring line-ref nit (first-entry audit)

**Date**: 2026-05-12 · **Iteration**: 70 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (first entry)
**Spec**: `specs/keeper-state-machine/KeeperCircuitBreaker.tla` (154 LOC, 6 vars, bug-model paired)
**OCaml**: `lib/keeper/keeper_failure_circuit_breaker.{ml,mli}` (447 + 142 LOC)
**Verdict**: **clean** — the spec↔OCaml mapping is bidirectional and accurate, the runtime implements the class-isolation property exactly as modelled, and both `.cfg` / `-buggy.cfg` exist. One trivial drift: the OCaml docstring's reverse-citation cites `[type error_class]` at "`~line 17`" but the declaration is at line 46 (+29). Fixed in this PR by dropping the line number (N-2.a shape, iter 64).

## Cross-checks (all pass)

| Spec element | OCaml | Status |
|---|---|---|
| CONSTANT `Threshold` (= 3 in prod) | `keeper_failure_circuit_breaker.ml` `let threshold = 3` | ✓ exact |
| `count` (0..Threshold) | `mutable consecutive_count : int` | ✓ |
| `currentClass` | `mutable consecutive_class : error_class` | ✓ |
| `tripped` (hint injected this step) | `record_failure : ... -> string option` (Some hint when tripped) | ✓ |
| `ErrorClasses` (spec: 3) | `type error_class = Path_not_found \| Path_not_allowed \| Cwd_not_directory \| Shell_exit_nonzero \| Other` (5) | ✓ — spec preamble explicitly documents the 3↔5 projection as Refinement, not Drift; `Cwd_not_directory` / `Shell_exit_nonzero` fold into the spec's "other" partition for `ClassIsolation` |
| `RecordFailure(cls)` — same class → `count+1`; `>= Threshold` → trip, `count=0`; **different class → `count=1, currentClass=cls`** | `record_failure`: `if cls = s.consecutive_class then s.consecutive_count <- s.consecutive_count + 1 else (s.consecutive_class <- cls; s.consecutive_count <- 1)`; trip branch sets `s.consecutive_count <- 0` | ✓ — the class-change reset (the safety-critical branch the buggy model removes) is present |
| `SpecBuggy` (`RecordFailureBuggy`: "no class-change branch — always increment") | not present in OCaml | ✓ — runtime does not exhibit the bug |
| `.cfg` / `-buggy.cfg` | `KeeperCircuitBreaker.cfg` + `KeeperCircuitBreaker-buggy.cfg` both present | ✓ |
| Bidirectional cross-ref | spec preamble has an `OCaml ↔ TLA+ mapping` table citing module symbols; OCaml docstring has the reverse "Spec navigation (OCaml -> TLA+)" block citing `KeeperCircuitBreaker.tla (#8642 family)` and quoting spec line ranges 9-13 / 15-22 (both accurate) | ✓ |

## The one nit (fixed here)

`keeper_failure_circuit_breaker.ml` docstring, line ~25:

```
ErrorClasses  -> [type error_class] (this file, ~line 17)
```

`type error_class` is declared at **line 46**, not ~17 (drift +29). The "~" hedges it, but 17 vs 46 is not "approximately the same". This is the OCaml-docstring variant of the 8th drift sub-class (line-reference drift, iter 63 KAQ N-1) — and it is *not* caught by `scripts/audit-tla-ml-line-refs.sh` (that validator scans TLA preambles, not OCaml docstrings) nor by `scripts/audit-ocaml-phase-count.sh` (phase counts only). Fixed by dropping the line number entirely and naming the symbol as the stable anchor (N-2.a shape).

The other two line-range citations in the same block — "Spec lines 9-13" (the 5 mapping rows) and "spec lines 15-22" (the scope-projection prose) — were checked against the current `KeeperCircuitBreaker.tla` and are accurate; left unchanged.

## Why this matters (modestly)

The good news first: this is the kind of spec↔OCaml pair the corpus should aim for — small, a typed `error_class` sum on the OCaml side, a CONSTANT-matched `Threshold`, an explicitly-documented projection for the class-count mismatch, a paired bug model, and *bidirectional* cross-references so a search from either side lands at the other. Nothing structural is wrong. The only drift is the one OCaml docstring line number, and that's the same self-limiting class the loop already has a TLA-side validator for — worth fixing for consistency, not because it's load-bearing.

## Possible follow-up (not in scope)

- **R-1.a (LOW)** — extend `scripts/audit-tla-ml-line-refs.sh` (or a sibling) to also scan `lib/keeper/*.{ml,mli}` docstring "Spec navigation" blocks for `(~?line N)` claims and verify the cited symbol is within tolerance. Would have caught this nit automatically. Mirrors R-H-1.f (the OCaml-side twin of R-H-1.c). MED — needs a regex for the OCaml-docstring shape.

## Verification (this audit)

```
$ wc -l specs/keeper-state-machine/KeeperCircuitBreaker.tla        # 154
$ wc -l lib/keeper/keeper_failure_circuit_breaker.{ml,mli}         # 447 + 142
$ rg -n 'type error_class|let threshold|consecutive_count|consecutive_class|record_failure' lib/keeper/keeper_failure_circuit_breaker.ml
$ ls specs/keeper-state-machine/KeeperCircuitBreaker*.cfg          # .cfg + -buggy.cfg
```

This PR also drops the stale `~line 17` line number from the OCaml docstring (comment-only). No spec or `.cfg` change.

## RFC trail

`keeper_failure_circuit_breaker.ml` is not in the credential/identity/operator/sandbox/hooks/workflow RFC-required set — RFC-WAIVED for the comment-only docstring fix. Spec lineage: `#8642 family` (per the spec preamble).
