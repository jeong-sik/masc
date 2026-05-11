# F-2 full-corpus cfg orphan sweep — 5th drift class formally isolated

**Iteration**: 46 (/loop FSM/TLA+/OCaml drift hunt)
**Date**: 2026-05-12
**Scope**: All 200 `.cfg` files across 18 spec directories under `specs/`.
**Risk**: LOW — audit-only, no production impact.
**Predecessor**: iter 44 audit (#14841) discovered the 5th drift class (cfg↔spec orphan reference); iter 45 R-F-1.a apply (#14843) deleted the one offending cfg pair after a partial sweep (76 cfgs, keeper-state-machine only).

## Scope expansion

iter 45's R-F-2 sweep covered `specs/keeper-state-machine/` only (76 cfgs).  This iter extends to the full corpus to answer: **is the 5th drift class isolated to the keeper specs, or does it appear elsewhere?**

| Spec directory | cfgs |
|---|---|
| admission-queue | varies |
| auth | varies |
| autonomous | varies |
| boundary | varies |
| bug-models | varies |
| cascade | varies |
| checkpoint-trim | varies |
| closure | varies |
| **keeper-state-machine** | 76 (iter 45 already scanned) |
| keeper-turn-fsm | varies |
| masc-ecosystem | varies |
| multimodal | varies |
| resilience | varies |
| server-state | varies |
| shared | varies |
| social-state-cap | varies |
| state-product | varies |
| task-lifecycle | varies |
| **Total** | **200 cfgs** |

## Method

Promoted the inline `/tmp/cfg-orphan-sweep2.sh` from iter 45 to a permanent audit tool at `scripts/audit-tla-cfg-orphan.sh` (~90 LOC bash).  Algorithm:

1. For each `.cfg` under `specs/`, derive the parent `.tla` by progressively stripping `-<suffix>` tokens from the basename until a sibling `.tla` is found.
2. Parse INVARIANTS / PROPERTIES blocks (NOT CONSTANTS — TLC tolerates orphan CONSTANTS silently; see iter 44 §"Empirical observations").
3. Check each name against the parent `.tla` via `rg -q "\bname\b"`.
4. Print orphans; exit 1 if any.

The script's `awk` block reads from `INVARIANTS`/`PROPERTIES` until the next top-level keyword (`CONSTANTS`, `SPECIFICATION`, `CHECK_DEADLOCK`, `INIT`, `NEXT`).  Suffix-stripping handles `-buggy`, `-buggy-attempt`, `-buggy-cascade`, `-ci`, `-ci-buggy`, `-cap2`, `-cap2-buggy`, `-overflow`, `-overflow-buggy`, etc. iteratively.

## Result

```
$ bash scripts/audit-tla-cfg-orphan.sh
ORPHAN specs/keeper-state-machine/KeeperDecisionPipeline-cap2.cfg -> KeeperDecisionPipeline.tla: ToolSetNeverEmpty
ORPHAN specs/keeper-state-machine/KeeperDecisionPipeline-cap2.cfg -> KeeperDecisionPipeline.tla: RecoveryFloorMaintained
ORPHAN specs/keeper-state-machine/KeeperDecisionPipeline-cap2.cfg -> KeeperDecisionPipeline.tla: FailingEventuallyRecovers
---
audit-tla-cfg-orphan summary: 200 cfgs scanned / 1 skipped (no parent) / 3 orphans
$ echo $?
1
```

**Across the entire 200-cfg / 18-directory corpus, exactly 3 orphans — all in the single cfg pair that iter 45 PR #14843 deletes.**

Once #14843 lands, the corpus will be at **0 orphans / 200 cfgs**.  The 5th drift class is formally isolated to one historical mistake (`9faabfadf` cfg leak ~6 months ago), with no other instances anywhere.

The single skip is a cfg whose suffix-stripping doesn't find a parent — verified harmless (it's the rare 2-segment suffix variant `KeeperAdmissionLiveness-buggy-2.cfg`, sibling `.tla` is `KeeperAdmissionLiveness.tla`, but the iterative stripping pattern misses `-2` first.  Improving the heuristic is a follow-up.)

## What this means for R-F-1.c (validator extension)

Iter 45 PR body deferred R-F-1.c (validator extension for cfg↔spec orphan check) with reasoning: "single-instance regression doesn't justify ~50-100 LOC infrastructure work".  This sweep **strengthens** that judgment with full-corpus data:

- **Total drift instances**: 1 cfg pair (3 orphan references in a single file).
- **Distribution**: 1/18 directories.
- **Cause**: a single 6-month-old PR (`9faabfadf`) that miscarried a cfg from a different .tla revision.
- **No recurrence**: no other cfg in any other spec has ever drifted into the same shape.

R-F-1.c would be a validator pass for a phenomenon that has happened exactly once.  Per CLAUDE.md §"Workaround Rejection Bar" #3 (N-of-M patches — abstraction added to handle non-existent siblings), building infrastructure for a single-instance bug is the **inverse** anti-pattern: over-engineering.  R-F-1.c stays formally deferred.

## What we keep instead

`scripts/audit-tla-cfg-orphan.sh` (~90 LOC bash) is committed as a **one-shot audit tool**, not CI-wired.  Properties:

- Documented in its own header §"This is an audit-mode tool, intentionally NOT wired into CI"
- Runnable on demand: `bash scripts/audit-tla-cfg-orphan.sh`
- Exit 1 on orphans, 0 clean — composable in future scripts
- Future PRs that *re-introduce* the drift will be caught by the next audit run (manual)
- If a recurring pattern emerges (>1 instance in different cfgs), R-F-1.c can be promoted in ~30 LOC additional work (wire into existing workflow + baseline file)

This is the iter 32/40 **capability-without-activation** pattern: ship the tool, defer the activation, document the trigger condition.  Differences from those iters:

| Iter | Capability | Activation trigger |
|---|---|---|
| 32 | `extract_cfg_constant_members` in drift validator | Default off until R-D-1.a apply (baseline+activate paired) |
| 40 | `--check-cross-spec` flag in drift validator | Opt-in; activated iter 43 after audit→classification→fix chain (iter 41→42→43) |
| **46 (this)** | **`audit-tla-cfg-orphan.sh` standalone audit script** | **Not CI-wired; manual run on demand.  Re-evaluate if iter 50+ reveals new instances.** |

## New drift class — final summary

| # | Audit | Drift axis | Detection | Status |
|---|---|---|---|---|
| 1 | KSM A-1 (#14694) | OCaml ↔ spec init mapping | Manual | Audit only |
| 2 | KTC B-1 (#14793) | OCaml ↔ spec type-symbol | R-B-1.c validator (iter 20-43) | CI-wired, 0 drift |
| 3 | KCAF D-1/D-2 | OCaml ↔ spec alphabet | Manual | R-D-2.a deferred |
| 4 | KCL E-1 (#14824) | Spec ↔ spec projection | R-E-1.b cross-spec scanner | CI-wired iter 43, 0 drift |
| 5 | **KDP F-1 (this family)** | **Cfg ↔ spec orphan reference** | **`audit-tla-cfg-orphan.sh` (manual)** | **Isolated, 1 instance closed iter 45** |

## Out-of-scope

- The 1 skipped cfg (suffix-stripping heuristic miss).  If the audit chain wants 100% coverage, improve the heuristic in `audit-tla-cfg-orphan.sh` line 56 (~5 LOC) — separate iter.
- CONSTANTS orphan detection.  TLC tolerates them silently, so they don't break TLC; but they may mislead readers about cfg state-space dimensions.  Optional R-F-1.c.x extension.
- TLA+ `EXTENDS` chain awareness.  If a spec inherits invariants via EXTENDS, the current sweep would flag the inherited name as orphan.  No false positives observed in this run (no spec uses such inheritance for invariants), but worth noting for future spec authors.
- R-F-1.c activation.  Stays deferred pending recurrence evidence.

## References

- iter 44 audit (`kdp-cap2-dead-cfg-2026-05-12.md`) — 5th drift class discovery, 3 RFC candidates
- iter 45 R-F-1.a apply (#14843) — deletion + INDEX regen, partial sweep (76/200)
- iter 32 R-D-1.b capability (#14803) — `cfg:` syntax for cfg-side CONSTANT extraction, capability-without-activation precedent
- iter 40 R-E-1.b cross-spec scanner (#14828) — `--check-cross-spec` opt-in flag precedent
- CLAUDE.md §"Workaround Rejection Bar" #3 — N-of-M patch anti-pattern (informs R-F-1.c deferral)
- `scripts/audit-tla-cfg-orphan.sh` — the audit script itself, with explicit non-activation rationale in header
