# MASC Cockpit Design System v2 Pivot — Iter 0 Audit

- **Generated**: 2026-04-28 (KST)
- **Branch**: `feature/ds-v2-iter0-audit`
- **Base commit**: `951040a822` (`feat(prompt): add prompt_defaults.mli`, after Phase 2 closure #11580)
- **Plan**: `~/me/planning/claude-plans/20m-keen-giraffe.md` (Provider-C v2 + v1 P0 흡수, 7~10mo)
- **Source corpus**: `/Users/dancer/Downloads/Kimi_Agent_디자인 시스템 설계/` (sec00–sec09 v2, sec00–sec08 v1, migration_guide_sec01)
- **Method**: read-only inventory of in-flight work + cross-reference of Phase 0/1 priors. **No tokens regenerated, no headless code added.** Iter 1~26 deliverables follow in subsequent PRs.

---

## 1. Purpose

Iter 0 of the v2 pivot loop. Establish ground truth before Iter 1 (`tokens-drift` required check) and Iter 2/3 (variables.css absorption) so subsequent PRs don't duplicate work, race with in-flight worktrees, or miscount token deltas.

Three deliverables:

1. Map v2 plan against the **prior `20m-me-workspace-yousleepwhen-masc-h-curious-dusk.md` plan** (Phase 2 closure #11580) to mark absorbed / overlapping / net-new scope.
2. Inventory **238 active worktrees** by taxonomy and flag those that intersect Iter 1~14.
3. Correct the v2 plan's hex/token estimates using Phase 0 audit (`2026-04-28-production-css-drift.md`) as authoritative source.

This file is the SSOT entry point for v2 Iter 0. Subsequent iter audits append to `audits/CHANGELOG.md`, not this file.

---

## 2. Relation to Prior Plan & Phase 2 Closure

| Item | Status | Source |
|---|---|---|
| Phase 2 closure (G/C/O/K/I plane) | ✅ shipped 2026-04-29 | PR #11580 |
| Frontend remaining after closure | **0** until backend issues land | PR #11580 |
| Backend RFC issues filed | 11 (#11568–#11578) | PR #11580 |
| E1–E5 Code IDE plane | 🔴 explicitly **deferred** by user 2026-04-28 in prior plan §A | `~/me/planning/claude-plans/20m-me-workspace-yousleepwhen-masc-h-curious-dusk.md:32` |
| **E1–E5 reactivation** | 🟢 user approved 2026-04-28 (today) via v2 plan Iter 21–26 | `~/me/planning/claude-plans/20m-keen-giraffe.md` |
| DS-Drift Phase 0 hex audit | ✅ complete (90 unique hex, 75.6% token ratio) | `audits/2026-04-28-production-css-drift.md` |
| Orphan re-triage | ✅ all 7 "orphans" reclassified live via `global.css @import` | `audits/2026-04-28-orphan-triage.md` |
| Spec compliance baseline | ✅ recent | `audits/spec-compliance-2026-04.md`, `2026-04-27-followup.md` |

**Key reconciliation**: v2 plan extends prior plan by (a) reactivating the deferred E1–E5 IDE plane, (b) introducing Headless UI architecture (v2-§1), (c) adding AX patterns (v2-§5) and MemoryGraph persistence UI (v2-§3) — all net-new vs prior. Prior plan's Phase 2 closure remains valid; v2 starts above it.

---

## 3. Token & Drift Corrections

The v2 plan body cites estimates that were imprecise. Authoritative numbers from Phase 0 audit `2026-04-28-production-css-drift.md` §1:

| Metric | v2 plan stated | Authoritative (Phase 0) |
|---|---|---|
| `variables.css` hex | 40 | **40** (verified — earlier `rg` count of 77 included comment-line duplicates) |
| `paper-theme.css` hex | 32 | **32** ✓ |
| `tokens.generated.css` tokens | 79 | **373 lines starting with `--`** (the 79 figure was for one tier only; full file is broader) |
| Token usage ratio | not stated | **75.6%** baseline before Iter 2/3 |
| Total hand-written CSS files | 21 (estimate) | **19** (excluding `tokens.generated.css`) |
| Hard-coded `*px` occurrences | not stated | 271 |

**Iter 2/3 absorption target**: variables.css 40 + paper-theme 32 = 72 hex. Phase 0 §1 notes "two files account for >70% of all hard-coded hexes" — Iter 2/3 closes >75% of all drift in two waves. Remaining 17 files have only 24 hex combined; deferred to Iter 4 (DTCG schema) or P3 audit.

**Iter 1 Gate 2 (ΔE) verification target**: keep token usage ratio ≥ 75.6% (regression floor) and ratchet upward as hex absorbed. Use existing `paper-theme.css` to validate `?theme=paper` path before lifting to `themes/paper.ts`.

---

## 4. In-flight Worktree Taxonomy

**Total worktrees: 238** (from `git worktree list | wc -l`). Sampled 6 across categories — all 6 had **1 commit ahead of `main`, not pushed/merged, no PR open**. Pattern signal: this is a queued backlog of fix-PR candidates from prior sessions, not active concurrent races.

Sampled snapshots:

| Worktree | HEAD | Commit subject | Status |
|---|---|---|---|
| `chore/dashboard-drift-baseline-regen` | `b83e438b31` | regenerate drift baseline (3-bucket closure lock) | unpushed |
| `chore/idpill-drift-comments` | `f196eb26ff` | clear bg/border-white-alpha drift residue | unpushed |
| `chore/ring-lint-gate` | `f4223f80ca` | add Ring helper lint gate (3 patterns, ratchet) | unpushed |
| `chore/heuristic-metrics-remove` | `38bdc369b4` | remove 3 emit sites + dangling relay TODO | unpushed |
| `chore/bg-white-3-migrate` | `d67d5bf796` | migrate bg-white/3 to bg-[var(--white-3)] (14 sites) | unpushed |
| `bonsai-tk-mirror` | `6bbf49584d` | mirror Tk atom from Preact (bonsai catch-up) | unpushed |

Cross-check: `gh pr list --search "design system OR tokens-drift OR headless OR dashboard v2" --state open` returns 0 results. The single open PR (#11588) is unrelated (`prompt_defaults.mli`).

### 4.1 v2 Iter intersection map

For each prefix family, mark whether subsequent v2 iters must align.

| Prefix family | Approx count | v2 Iter overlap | Action |
|---|---:|---|---|
| `chore/bg-white-*-migrate` | ~10 | **Iter 2/3 (variables.css absorption)** | These already do part of Iter 2/3. Audit each before opening Iter 2 PR; merge or close before duplicating. |
| `chore/border-white-*-migrate` | ~6 | Iter 2/3 | same |
| `chore/idpill-drift-*`, `chore/ring-lint-gate` | ~3 | **Iter 1 (`tokens-drift` required) + Iter 5 (jest-axe)** | `ring-lint-gate` may *be* Iter 1's lint gate. Verify before re-implementing. |
| `chore/dashboard-drift-baseline-regen` | 1 | Iter 1/2 | Drift baseline must align with Iter 1 required check semantics. Do not re-regenerate without checking this. |
| `bonsai-*-mirror` | ~3 (kvrow, sectionhead, tk) | **Iter 6 (`headless-core/` bootstrap) + Iter 7–13 atom adapters** | These are pre-headless mirror atoms. After Iter 6 lands, Bonsai adapters use `headless-core` instead — these mirrors may become deprecated or incorporated. |
| `feat-tla-*`, `feat-receipt-*`, `feat-fsm-*`, `feat-ppx-tla-*`, `feat-tlc-*`, `feat-keeper-*` | ~30+ | none — TLA+/keeper/FSM territory | No design-system overlap. v2 ignores. |
| `chore/baseline-bump-lib-dune-*`, `chore/opam-ppxlib-sync`, `chore/heuristic-metrics-remove`, `chore/host-ollama-*` | ~6 | none | OCaml/runtime/build hygiene. v2 ignores. |
| `feat-*` (other) | remainder | partial | per-iter check |

**Conservative principle**: v2 Iter PRs do not push, merge, or rebase any worktree we did not author. We only inventory and reference.

### 4.2 Race-window discipline (per memory: feedback_race_window_check_immediately_before_push)

Before each Iter PR push:

1. `gh pr list --state all --limit 50 --search "<keyword>"` for the iter's distinctive token (`bg-white`, `tokens-drift`, `headless`, `Drawer`, etc.) — both dash and underscore variants.
2. `git -C ~/me/workspace/yousleepwhen/masc/.worktrees/<sibling> log --oneline main..HEAD` for the most-likely-overlapping worktrees from §4.1.
3. If a sibling has uncommitted v2-overlapping work, broadcast and pause — do not race.

---

## 5. Net-new v2 demands not in prior plan

These items have **no Phase 0/1 antecedent** and are pure v2 contribution:

| Demand | v2 source | First Iter |
|---|---|---|
| `headless-core/` framework-agnostic package | v2-§1, v2-§8 | Iter 6 |
| Compound component + `asChild` polymorphism | v2-§1.1 | Iter 6/7 |
| Bonsai adapter for every headless primitive | v2-§8 + user decision 2026-04-28 | Iter 6+ |
| W3C DTCG v1 token output | v2-§4 | Iter 4 |
| jest-axe + render-test infra (DS test count 0 → 10) | v2-§7 | Iter 5 |
| `AgentOutputAnnouncer` live region | v2-§6 | Iter 18 |
| Monaco CodeEditor mount (E1) | v2-§2.1.1 | Iter 21 |
| FileTree, Terminal, CommandBar (E2–E5) | v2-§2 | Iter 22–24 |
| AgentLifecycle FSM viz | v2-§5 | Iter 25 |
| MemoryGraph (vector memory + sync conflict UI) | v2-§3 | P6 |

These are the "stable scope" — no in-flight worktree owns them. Iter 4–13 PRs can proceed without race concern in this set.

---

## 6. Iter 1 readiness checklist

Iter 1 is "`tokens-drift` required check 승격". Pre-conditions before opening that PR:

- [ ] `chore/ring-lint-gate` worktree's `f4223f80ca` reviewed: is this the same lint gate v2 Iter 1 wants? If yes, absorb that commit. If no, proceed independently.
- [ ] `chore/dashboard-drift-baseline-regen` worktree's `b83e438b31` reviewed: does the regenerated baseline match the Iter 1 fail-fast target? If yes, depend on it.
- [ ] Branch protection settings for `main` documented in repo (`.github/branch-protection.yml` or screenshot in audit) so Iter 1 PR can flip the `tokens-drift` check from optional → required cleanly.
- [ ] `pnpm tokens:build` smoke run on this audit branch to confirm codegen still works on `951040a822`.

These checks are part of Iter 1 PR body, not Iter 0. Listed here so Iter 1 doesn't lose them across the cycle gap.

---

## 7. Iter 2/3 readiness checklist

- [ ] Decide absorption order for `chore/bg-white-*` / `chore/border-white-*` family. Two options:
  - **(a) Absorb-then-extend**: Cherry-pick relevant unpushed commits into `feature/ds-v2-iter2-tokens-wave1`, then add v2-specific token names. Preserves the original work's authorship.
  - **(b) Restart-from-source**: Open Iter 2 PR fresh on top of `main`, ignore the `bg-white-*` family. Faster but discards prior work.
  - **Recommendation**: (a). The unpushed commits represent ~14 sites/PR of careful migration; restart wastes that.
- [ ] Confirm with user/prior author that the unpushed worktrees are not actively edited (heartbeat check via MASC if workspace is active, otherwise assume idle).

---

## 8. Out of scope (Iter 0 only)

- Token regeneration / `pnpm tokens:build` re-run (Iter 1+).
- Any code in `dashboard/src/` (Iter 5+ for tests, Iter 6+ for headless).
- Any code in `dashboard_bonsai/src/` (Iter 6+ for Bonsai adapter).
- Backend RFC issues #11568–#11578 (separate plan).
- Cron registration for the 20m loop (deferred to after this PR opens, see Iter 0 follow-up below).

---

## 9. Open questions for v2 plan owner

1. **Race resolution policy**: should Iter 2/3 absorb the `chore/bg-white-*` and `chore/border-white-*` worktrees (option 7§(a)) or restart from `main` (option 7§(b))?
2. **`ring-lint-gate` reuse**: is the unpushed `f4223f80ca` lint gate exactly the Iter 1 deliverable, or distinct? Pending peek inside that worktree's diff.
3. **Bonsai mirror coexistence**: after Iter 6 (`headless-core`) lands, what happens to the existing `bonsai-*-mirror` atoms? Three options:
   - migrate them to consume `headless-core` (preserves work, adds ~1 PR per atom)
   - deprecate them and rebuild atop `headless-core` (cleanest, throws away work)
   - keep them as legacy and wrap (worst — Two-tier risk repeats at component layer)

These do not block Iter 0 closure, but each is required input before the named Iter opens its PR.

---

## 10. Iter 0 follow-up

Once this PR is in Draft and reviewed:

1. Register the `*/20 * * * *` cron (auto-expires 7d).
2. Open Iter 1 worktree `feature/ds-v2-iter1-tokens-drift-required`.
3. Loop fires every 20 min while session active; each fire claims one Iter chunk per `~/me/planning/claude-plans/20m-keen-giraffe.md` §"20분 청크".

---

## Appendix A — Existing audit cross-reference

| File | Date | Iter overlap |
|---|---|---|
| `2026-04-28-production-css-drift.md` | 2026-04-27 | Iter 2/3 baseline numbers |
| `2026-04-28-orphan-triage.md` | 2026-04-28 | none (orphans cleared) |
| `2026-04-29-o4-cost-latency-availability.md` | 2026-04-29 | none (backend-blocked) |
| `2026-04-29-phase-b-i0-backbone.md` | 2026-04-29 | none |
| `spec-compliance-2026-04*.md` | 2026-04 | Iter 16 sigil |
