# N-2.c R-17 — `audit-tla-ml-line-refs.sh` Rule 2: zero-tolerance guard against the compact `file.ml:NNN` colon-form line reference in `specs/keeper-state-machine/*.tla` (the iter-74-flagged "`\.ml:[0-9]` lint" — now landable, subdir is clean)

**Date**: 2026-05-12 · **Iteration**: 92 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: guard (closing a long-standing follow-up)

## What this is

The iter-64 N-2.a convention for `specs/keeper-state-machine/*.tla` is "no line numbers — cite OCaml by symbol" (e.g. `keeper_foo.ml:my_function` or `keeper_foo.ml — my_function`), because the OCaml files grow and line numbers drift on every edit while symbols don't. The drift class had a 3-step pipeline (audit → fix → guard); N-2.c is the guard, `scripts/audit-tla-ml-line-refs.sh`, wired into `.github/workflows/tla-annotation-drift.yml`.

But that guard's regex only matched the **prose** form — `\[([a-z_]+)\][^,]*line[s ]+(\d+)` (a bracketed function name and a nearby `line N` mention). It missed the **compact** form — `lib/keeper/keeper_post_turn.ml:648-656` (filename, colon, digit). The iter-84 #14971 line-ref sweep + the follow-up symbol-anchor commit (`6c1d427d8` — "switch mapping table to path.ml:symbol anchors (lint-checkable)") drained `KeeperPostTurnOrchestration.tla`'s mapping table of the last compact-form offenders, but nothing prevented the next preamble from re-introducing one.

This PR adds **Rule 2** to the existing script: a whole-file scan of each `specs/keeper-state-machine/*.tla` for `[A-Za-z0-9_]+\.ml:[0-9]` — any hit is an N-2.a violation. Zero new script, zero new CI step (the workflow already runs `audit-tla-ml-line-refs.sh`), zero baseline file (the subdir is now clean: `0 prose-form citation(s) verified + 0 colon-form line-ref(s) across 34 spec(s)`).

## Why it was "blocked" until now (and why iter 91's note was wrong)

iter 91's audit memo said the lint was "still blocked — KeeperPostTurnOrchestration.tla has 9 line-range refs even after #14971 merged". That was a **stale-local-checkout artifact**: the loop's repo-root `main` checkout predated #14971's merge (`773bf985c`), so a `grep` over the working tree still saw the pre-merge file. `git show origin/main:specs/keeper-state-machine/KeeperPostTurnOrchestration.tla | grep '\.ml:[0-9]'` returns nothing — the user's `6c1d427d8` symbol-anchored the whole mapping table (`keeper_post_turn.ml:apply_post_turn_lifecycle_with_resilience_handles — ...`). So the subdir has been clean since #14971 merged; the lint is landable now.

## Scope decisions

- **`.ml` only, not `.mli`.** Interface files are small and don't grow, so they're not subject to the growth-driven drift this guard targets; Rule 1 already treats `.mli` as a fallback (used only if the preamble cites no `.ml` at all). Two `.mli:NNN` refs remain — `KeeperCompositeLifecycle.tla`'s `Keeper_state_machine.mli:139-144` (a 5-line line-number-heavy block; the surrounding text already self-documents "lines 131-136 reference ... [type event] declaration that starts at line 139 with [Context_measured] at line 144") and `KeeperDecisionPipeline.tla`'s `(mli mirror at keeper_registry.mli:49-53)`. Left for a separate cleanup if wanted (a `.mli`-converting PR would also want to drain `KeeperDecisionPipeline`'s prose `line 493 / 515 / 535 / 575` "Authoritative write points" block, which Rule 1 also misses because those entries use bare `mark_turn_started` not bracketed `[mark_turn_started]`).
- **Scoped to `specs/keeper-state-machine/`.** The script already iterates only that directory (`SPEC_DIR`). The other spec trees (`specs/boundary/`, `specs/bug-models/`, `specs/auth/`, `specs/admission-queue/`, `specs/keeper-turn-fsm/`, `specs/task-lifecycle/`) never adopted the N-2.a convention and still use the `file.ml:NNN` form freely (~40 sites); widening the rule to them would need a baseline file (the `audit-tla-annotation-drift.sh --baseline` / `audit-ocaml-phase-count.sh --baseline` precedent). Out of scope here — this is the guard for the subdir that already follows the convention.

## Not a workaround

CLAUDE.md §워크어라운드 거부 기준 #2 ("string/substring 분류기 보강") targets *runtime* string classifiers added where a typed variant is possible — `String.starts_with ~prefix:"completion_contract_violation:"` and the like, where the compiler can't catch a missing reader. This is a *documentation-convention lint*: the structural fix is the symbol-anchor convention itself (symbols are stable identifiers the OCaml compiler keeps honest; line numbers aren't), and the lint just enforces it — same category as a "no hex literals" / "no trailing whitespace" CI check. It was pre-cleared as the iter-74 baseline-drain posture, and the user's `6c1d427d8` ("lint-checkable") explicitly anticipates it.

## Verification

- `bash -n scripts/audit-tla-ml-line-refs.sh` — syntax OK.
- `bash scripts/audit-tla-ml-line-refs.sh` — `line-ref audit clean: 0 prose-form citation(s) verified + 0 colon-form line-ref(s) across 34 spec(s).` (exit 0).
- Negative test: append `\* negative-test: keeper_foo.ml:42 ...` to a spec → `colon-ref: KeeperHeartbeat.tla:NNN — N-2.a: cite by symbol, not line — ...` (exit 1); revert → exit 0.
- CI: `.github/workflows/tla-annotation-drift.yml` already runs this script on `specs/keeper-state-machine/**` and `scripts/audit-tla-ml-line-refs.sh` path changes — no workflow edit needed.

## Follow-up

- `.mli:NNN` cleanup (KeeperCompositeLifecycle / KeeperDecisionPipeline) + `KeeperDecisionPipeline`'s prose `line 493/515/535/575` block — a small spec-comment PR; not urgent (`.mli` files don't drift).
- `keeper_unified_turn.ml`'s `run_keeper_cycle` reverse-citation block still says `Spec line 3 ... "[run_keeper_cycle] (line 1042+)"` — spec line 3 no longer carries the line number (iter 64 N-2.a). The `scripts/audit-ocaml-spec-nav-line-refs.sh` guard (the OCaml-docstring twin) covers reverse-citations but with a baseline; check whether this site is baselined and, if so, drain it when fixed. (iter 91 follow-up, still owed.)
