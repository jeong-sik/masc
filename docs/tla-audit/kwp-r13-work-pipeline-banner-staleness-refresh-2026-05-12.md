# KWP R-13 — KeeperWorkPipeline.tla: aspirational-design banner anti-staleness refresh — two of its 2026-04-20 probes had decayed; the clean model still violates an invariant (KNOWN_FAILURES)

**Date**: 2026-05-12 · **Iteration**: 88 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (anti-staleness re-verification of an aspirational/dormant spec — sub-class 5)
**Spec**: `specs/keeper-state-machine/KeeperWorkPipeline.tla` (383 LOC) — ASPIRATIONAL DESIGN spec for a future keeper autonomous-work pipeline (workspace lifecycle / file ops / commit safety / PR creation / review cycles), with a bug-model partner `specs/bug-models/KeeperWorkPipelineBug.tla`
**Verdict**: **The "ASPIRATIONAL DESIGN INVARIANT" banner's *spirit* still holds — the modeled runtime module (`keeper_exec_github.ml`) still doesn't exist, and the modeled primitives (`force_push_attempted` / `workspace_init` / `workspace_cleaned` / `commit_identity` / `submit_count`) still have 0 hits in `lib/keeper/`. But two of its 2026-04-20 anti-staleness probes have decayed: (a) `find lib -name "*github*"` no longer returns 0 hits — a *different* github-named file (`keeper_tool_github_pr.ml`, a PR-operations tool surface, not the work-pipeline exec module) appeared since; (b) "This spec is NOT in scripts/tla-check.sh (TLC does not run it)" is wrong — `scripts/tla-check.sh` exists, the spec is in `specs/Makefile` + `scripts/ci/check-tla-harness-coverage.sh`, and it has a bug-model partner; the reason it isn't actually checked is that it's in `specs/Makefile`'s `KNOWN_FAILURES` ("clean spec violates invariant (exit 13) — model needs fix, not path issue") — i.e., a *model* bug, distinct from the runtime-not-wired situation.** Banner refreshed comment-only; model body byte-identical; TLC not re-run (the spec is a `KNOWN_FAILURES` entry — its clean model intentionally fails right now; comment-only change, honest-doc posture).

## Why this spec

The iter-81 / iter-85 wrap-ups + iter 86 (KeeperTurnSlot) + iter 87 (OperatorPauseBroadcast) worked through never-first-entry-audited specs. KeeperWorkPipeline is in the "aspirational / dormant" bucket (like KCB iter 70, KCC iter 76, KCounterCausality) — for those the first-entry job is an anti-staleness re-verification of the disclosure banner, not a model↔runtime cross-check (there's no runtime to cross-check against).

## What the 2026-04-20 banner claimed vs. 2026-05-12 reality

| Banner claim (2026-04-20) | 2026-05-12 status | Action |
|---|---|---|
| `lib/keeper/keeper_exec_github.ml` does NOT exist | **Still true** — `ls lib/keeper/keeper_exec_github.ml` → no such file | keep, re-dated |
| `find lib -name "*github*"` returns 0 hits in lib/keeper/ | **Decayed** — `lib/keeper/keeper_tool_github_pr.ml` + `.mli` now exist ("Dedicated GitHub PR keeper tools" — a PR-operations tool surface, NOT the autonomous-work-pipeline exec module the spec models) | replace the probe: the durable signal is `rg 'force_push_attempted\|workspace_init' lib/keeper/` → 0; note the new github-named file is unrelated |
| The primitives (`force_push_attempted`, `workspace_init`, `workspace_cleaned`, `commit_identity`, `submit_count`) have 0 hits in lib/keeper/ | **Still true** — `rg 'force_push_attempted\|workspace_init\|workspace_cleaned\|commit_identity\|submit_count' lib/keeper/` → 0 | keep — this is the right probe |
| "This spec is NOT in scripts/tla-check.sh (TLC does not run it)" | **Decayed / misleading** — `scripts/tla-check.sh` exists; the spec is referenced in `specs/Makefile` and `scripts/ci/check-tla-harness-coverage.sh`; `specs/bug-models/KeeperWorkPipelineBug.tla` exists. The reason it isn't *checked* is that it's in `specs/Makefile`'s `KNOWN_FAILURES` (`KeeperWorkPipeline: clean spec violates invariant (exit 13) — model needs fix, not path issue`), so `make -C specs check-clean` skips it | rewrite: it's in the corpus but in `KNOWN_FAILURES` due to a *model* bug (an invariant the clean spec violates) — separate from the runtime-not-wired situation |
| Actual keeper exec surface: `keeper_exec_board / _context / _fs / _masc / _memory + keeper_tool_pr_review` | Still accurate; add `keeper_tool_github_pr` to the list | append |

## The substantive finding (beyond the stale banner)

`KeeperWorkPipeline.tla`'s **clean** model violates one of its own invariants (exit 13 — that's why it's in `KNOWN_FAILURES`). The "ASPIRATIONAL DESIGN" banner explains why the spec isn't wired to a runtime, but it didn't say the model is *self-inconsistent* — i.e., even as forward-looking design documentation, the safety properties as written are not all simultaneously satisfiable by the model's own actions. The refreshed banner now says so explicitly and notes this strengthens the case for revisiting the #9044 retire/re-target/banner trichotomy: a "banner" (keep as design doc) option is weaker when the design doc has an internal contradiction. Fixing the model bug (discriminating which invariant is violated and either weakening it or adjusting the actions) is out of scope for this comment-only anti-staleness refresh — it's a standing follow-up; the `KNOWN_FAILURES` note ("model needs fix") already tracks it.

## Cross-checks (pass)

| Item | Status |
|---|---|
| `keeper_exec_github.ml` exists? | no — `ls` → no such file |
| modeled primitives in `lib/keeper/`? | 0 hits |
| `keeper_tool_github_pr.ml` exists & is it the modeled surface? | exists; it's "Dedicated GitHub PR keeper tools" (PR-operations tool surface), not the work-pipeline exec module — banner note added |
| spec in corpus / harness coverage? | yes — `specs/Makefile`, `scripts/ci/check-tla-harness-coverage.sh`; bug-model `specs/bug-models/KeeperWorkPipelineBug.tla` exists |
| spec actually checked by `make check-clean`? | no — in `specs/Makefile` `KNOWN_FAILURES` (clean violates invariant, exit 13) |
| `specs/INDEX.md` | regenerated — only KeeperWorkPipeline content-hash bump (`ab03a79d78e6` → `1b85e3e4ba20`) + timestamp/HEAD |
| model body | byte-identical (banner comment only) |

## Sub-class placement & follow-up

- Class = **sub-class 5 (dormancy / aspirational — already-disclosed future-design spec; anti-staleness re-verification)** — same pattern as iter 70 (KCB R-1) and iter 76 (KCC R-3). Here the re-verification found *decay in the disclosure probes themselves* (the `find *github*` probe and the "not in tla-check.sh" claim), plus surfaced the standing model-bug status more explicitly.
- **Follow-up owed (not this PR)**: fix the clean `KeeperWorkPipeline.tla` invariant violation (it's in `KNOWN_FAILURES` — "model needs fix"). That's a model-body change to an aspirational 383-LOC / 13-variable spec — needs a dedicated PR with TLC iteration to identify which invariant fails and why. Low priority (the spec is dormant), but it's the thing standing between this spec and being a clean design doc. Alternatively, the #9044 trichotomy could resolve it (retire the spec, or re-target it to the actual exec surface).
- This is *not* an RFC-gated subsystem (it models an aspirational autonomous-work pipeline; the actual touched files are none — comment-only spec change; not credential/keeper_gh/host_config, not repo_manager, not operator_control credential handlers, not keeper_sandbox/shell, not dashboard credential component, not .claude/hooks, not instructions/workflow). RFC-WAIVED.
- No new audit memo follow-up owed beyond the model-bug fix noted above. Comment-only — `specs/INDEX.md` regenerated.
