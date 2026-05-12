# R-1.c — `audit-ocaml-spec-nav-line-refs.sh` multi-line scan + comment-boundary filter (closing iter 94's "single-line regex" structural gap)

**Date**: 2026-05-12 · **Iteration**: 95 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: guard (closing the structural follow-up surfaced by iter 94 #15002)

## What this is

iter 94 audit memo (post-Copilot-review correction) identified the real structural gap behind iter 91's surviving follow-up: the OCaml-side validator `scripts/audit-ocaml-spec-nav-line-refs.sh` *was* wired into CI (`.github/workflows/tla-annotation-drift.yml:134`) with a baseline file (`scripts/ocaml-spec-nav-line-refs-baseline.txt`, currently empty after iter 74's drain). The gap was the **regex shape**: the scan loop used `grep -oE` (line-oriented), so a citation like

```
[run_keeper_cycle]
(line 1042+)
```

— bracketed symbol and `line N` on *adjacent* lines — fell outside the window and survived three iterations.

This PR closes the regex gap. Two changes to the scanner:

1. **`grep -oE` → awk whole-file scan**. Same regex (`\[(type )?[a-z_]+\][^][\n]*(\n[[:space:]]*[^][\n]*)?line[s ]+[0-9]+`) operates on the whole file via `RS="\0"`. Allows AT MOST one intervening newline between `[sym]` and `line N` (no paragraph-spanning).

2. **Comment-boundary filter** to suppress false positives that splice across two unrelated comment blocks (`*) ... (*`). Without this filter, `[source]` (a record-field name in one comment) plus `KeeperTurnCycle.tla lines 189` (a *spec* line ref in the next comment block) of `keeper_guards.ml` matched as a single drift — the bracketed symbol and the line number were in *separate* comments, so dropping matches that contain `*)` or `(*` (a guaranteed comment terminator/opener) is sound.

## What the widened scan immediately surfaces

Running the new scanner on origin/main (503e92ad6):

```
drift: lib/keeper/keeper_unified_turn.ml — cites [run_keeper_cycle] at line 1042 but actual is 239 (drift -803)
```

Exactly the iter 91 catalogued site that iter 94 PR #15002 is currently in flight to fix. The scanner couldn't see it before this PR; now it does. **Baselined here** (`lib/keeper/keeper_unified_turn.ml:run_keeper_cycle`) while #15002 is OPEN; the baseline line drains when that PR merges.

## Why the false-positive filter is sound

Inside a single OCaml comment block `(* ... *)`, the substrings `(*` and `*)` never appear (they'd terminate the comment). So *any* match that spans `*) ... (*` necessarily crosses two distinct comment blocks and is not a single coherent citation. The filter is conservative — it discards potential matches that *could* legitimately span comments (rare in practice; none in the current `lib/keeper/` tree), but those are exactly the cases where the symbol-vs-line-number coupling is ambiguous and should not be flagged.

Manual sanity-check on origin/main: only one false-positive shape exists today (`keeper_guards.ml` `[source]` + `KeeperTurnCycle.tla lines 189`); the filter drops it. Post-iter-94 cleanup of `keeper_unified_turn.ml` will not produce a new false positive (the cleanup edits are entirely within `(* ... *)` blocks).

## Verification

- `bash -n scripts/audit-ocaml-spec-nav-line-refs.sh` → syntax OK.
- `bash scripts/audit-ocaml-spec-nav-line-refs.sh --baseline scripts/ocaml-spec-nav-line-refs-baseline.txt` → `ocaml-spec-nav line-ref audit clean: 1 citation(s) verified across 504 file(s) (1 baselined).` (exit 0).
- Negative test: append `(* [test_negative_sym]\n   (line 9999) negative test *)` to any `lib/keeper/*.ml` → scanner reports `drift: lib/keeper/keeper_guards.ml — cites [test_negative_sym] at line 9999 but file has only 689 lines` (exit 1); revert → exit 0.
- False-positive guard: `keeper_guards.ml`'s `[source]` field reference no longer drifts (filtered out by the `*)` / `(*` exclusion).
- CI: `.github/workflows/tla-annotation-drift.yml:134` already invokes this script with the existing baseline path — no workflow edit needed; new scan capability picks up automatically.

## Paired-activation rationale

iter 33 #14804 precedent — activate scanner improvements together with paired baseline lines for any existing sites the widened scan surfaces. Here, exactly one new site (`keeper_unified_turn.ml:run_keeper_cycle`), which iter 94 #15002 is already in flight to drain. When #15002 merges, the `run_keeper_cycle` reverse-citation no longer has `(line 1042+)` in it; the scanner reports zero citations; the baseline line becomes stale and the next iteration drains it.

## Not a workaround

CLAUDE.md §워크어라운드 거부 기준 #2 ("string/substring 분류기 보강") targets *runtime* string classifiers added where a typed variant is possible. This is a *static lint regex widening* — making an existing guard see a citation shape it was structurally blind to. The structural fix is the iter 64 N-2.a convention; the lint enforces it; this PR closes a previously open window in the lint's coverage.

## Follow-up

- Drain `lib/keeper/keeper_unified_turn.ml:run_keeper_cycle` from the baseline when iter 94 #15002 merges.
- The third drift class (prose form `at line N` / `(line N)` without a bracketed symbol, e.g. iter 94 Site 2's `at line 966-967` after `[reset_turn_failures]` in a separate adjacent line — actually caught by this PR's multi-line scan because `[reset_turn_failures]` is in the same comment) is structurally covered now. If a *purely* prose citation like `the function at line 2275` (no bracketed symbol anywhere in the multi-line window) appears, it remains uncaught; no current `lib/keeper/*.ml` sites have that shape, so deferred until one shows up.
- Standing follow-ups from earlier iterations (KWP model bug, OPB-buggy deadlock, R-D-2.a+R-D-1.a bundle, KSM A-5) unchanged.
