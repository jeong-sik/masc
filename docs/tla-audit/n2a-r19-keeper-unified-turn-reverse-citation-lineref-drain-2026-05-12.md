# N-2.a R-19 — `keeper_unified_turn.ml` reverse-citation line-ref drain (iter 91 follow-up + bonus second-site discovery)

**Date**: 2026-05-12 · **Iteration**: 94 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: doc-cleanup (closing iter 91's named OCaml-comment follow-up)

## What this is

iter 91 PR #14992 audited `KeeperTaskAcquisition.tla` (KTA) and re-anchored its preamble to drop the line-number citation in `[run_keeper_cycle] (line 1042+)`. The current KTA preamble (line 3) reads:

```
\* [run_keeper_cycle] (iter 64 N-2.a removed the line number — function
\*   names are stable identifiers, line refs drift on every edit) is the
\*   top-level entry point ...
```

The *reverse-direction* citation lives in `lib/keeper/keeper_unified_turn.ml`'s `run_keeper_cycle` header comment block, and iter 91 noted it explicitly as still owed:

> `keeper_unified_turn.ml`'s `run_keeper_cycle` reverse-citation block still says `Spec line 3 ... "[run_keeper_cycle] (line 1042+)"` — spec line 3 no longer carries the line number (iter 64 N-2.a).

This PR closes that follow-up — and incidentally finds a second site in the same file with the same pattern.

## Two sites, same shape

### Site 1 (line 257-258, iter 91 catalogued)

The OCaml reverse-citation said:

```
Spec line 3 already cites this function: "[run_keeper_cycle]
(line 1042+)".  This block is the reverse-direction citation
so code search for "KeeperTaskAcquisition" lands here.
```

Two drifts in two lines:
- **Stale attribution** — the spec no longer cites by line; iter 91 explicitly removed it. So the *content* of the quoted citation is wrong.
- **Stale OCaml line** — `run_keeper_cycle` is at `keeper_unified_turn.ml:239` on origin/main, not 1042. **+803 line drift**.

Same block also had `below (~line 2559) the channel decision`. Actual disjunction (`pending_mentions <> [] || pending_board_events <> [] || ...`) lives at `keeper_unified_turn.ml:2621` — **+62 line drift**.

### Site 2 (line 2377, bonus discovery)

In the `last_failure_reason` annotation block, two more stale OCaml-line refs:

```
Reset path is unchanged: any successful turn clears the
field via [reset_turn_failures] + [set_failure_reason None]
at line 966-967.  Auto-pause site below (line 2275) still
stamps the same value at threshold — idempotent overwrite.
```

- `reset_turn_failures` cited at 966-967, actual call site at **3004** — **+2038 line drift**.
- `Auto-pause site below (line 2275)` — actual `cascade_auto_paused || tool_contract_auto_paused` block at **2394 / 2406** — **+119 line drift**.

Three more stale anchors, same drift mode as iter 93's KDP (+1094 to +1279).

## Fix shape

Both sites switch to symbol-anchor (iter 64 N-2.a):
- Site 1: `"[run_keeper_cycle] (line 1042+)"` → reference to `KeeperTaskAcquisition.tla preamble [run_keeper_cycle] reference` + inline explanation that the line number was removed in iter 64 N-2.a. The `~line 2559` AssignTask anchor → "the channel decision below" + grep hint (the disjunction is a unique 3-clause `<>` chain).
- Site 2: `at line 966-967` → "in the `[MutationBoundaryReached]`/checkpoint-saved arm of the post-turn match" (symbol-anchored to the pattern arm). `Auto-pause site below (line 2275)` → "the `[cascade_auto_paused || tool_contract_auto_paused]` branch" (symbol-anchored to the named locals).

## Why N-2.c's existing scripts didn't catch it

`scripts/audit-tla-ml-line-refs.sh` (iter 92 Rule 1 + 2) scans `specs/keeper-state-machine/*.tla`, not OCaml. The *spec → OCaml* citation guard exists; the *OCaml → spec* reverse-direction is what `scripts/audit-ocaml-spec-nav-line-refs.sh` is meant to cover. That script lives in `scripts/` but **has no baseline file** (`ls scripts/audit-ocaml-spec-nav-line-refs-baseline.txt` → no such file) and is not currently wired to any workflow path (no hits in `.github/workflows/*`). It exists as a tool but isn't enforcing anything yet — that's the structural gap behind why iter 91's catalogued follow-up survived until iter 94.

Wiring `audit-ocaml-spec-nav-line-refs.sh` into CI (with a baseline file capturing whatever already-stale sites exist beyond `keeper_unified_turn.ml`) is a separate, structural PR — not bundled here because the baseline could legitimately include dozens of sites across `lib/keeper/`, and admitting them under `BASELINE` while draining `keeper_unified_turn.ml` is the iter-74 baseline-drain pattern. Out of this PR's scope; flagged as the natural next R-B-1.c-style chain.

## Verification

- `grep -nE '\(line [0-9]+\+?\)|Spec line [0-9]|at line [0-9]+|~line [0-9]+' lib/keeper/keeper_unified_turn.ml` → empty.
- Comments-only edit — three blocks, three locations, all inside `(* ... *)` syntax. `run_keeper_cycle` signature, body, and downstream behaviour untouched.
- Symbol-existence cross-check on origin/main:
  - `run_keeper_cycle` at `keeper_unified_turn.ml:239`. ✓
  - `KeeperTaskAcquisition.tla:3` preamble `[run_keeper_cycle]` reference. ✓
  - `pending_mentions <> []` disjunction at `keeper_unified_turn.ml:2621`. ✓
  - `reset_turn_failures` call at `keeper_unified_turn.ml:3004` (inside `MutationBoundaryReached` arm). ✓
  - `cascade_auto_paused` binding at `keeper_unified_turn.ml:2394`, `||` predicate at 2406. ✓
- `dune build` not run — comments-only edit (OCaml comments are stripped in lexing; no AST/type-check impact). Same posture as iter 91 (#14992) and iter 93 (#14998) for comment-only changes.

## Follow-up

- **Wire `scripts/audit-ocaml-spec-nav-line-refs.sh` into CI with a baseline file**. This is the OCaml-side twin of N-2.c (iter 92 Rule 2). The baseline could be substantial — `git grep -nE '\(line [0-9]+\+?\)|at line [0-9]+|~line [0-9]+' lib/keeper/` to enumerate. Treat similarly to `audit-tla-annotation-drift.sh --baseline` precedent (iter 21 #14772).
- `keeper_unified_turn.ml` is large (3000+ LOC) and known-godfile. Further reverse-citation drift here would be caught by the baselined CI guard above. Outside this single-file drain.
