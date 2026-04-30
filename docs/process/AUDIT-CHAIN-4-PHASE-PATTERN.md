# Audit Chain 4-Phase Pattern

> Process doc, not a spec. Codifies the structural shape observed
> across multiple survey-style audit chains in this repo.
> Author: Vincent (jeong-sik) with Claude
> Created: 2026-04-30
> Source: Q-P0-3 (OAS↔MASC boundary) + Q-P0-2 (TLA+ specs gap)

---

## 1. Purpose

Two completed audit chains (`docs/audit/OAS-MASC-BOUNDARY-AUDIT-2026-04*.md` and `docs/audit/TLA-SPECS-GAP-AUDIT-2026-04*.md`) both followed the same 4-phase shape. This doc records the pattern so future surveys can reuse it without re-deriving the structure.

This is a **process doc**, not enforced. Survey work doesn't always fit this shape — the pattern is a starting point, not a constraint.

## 2. The 4-phase shape

| Phase | Output | Discipline |
|---|---|---|
| **1. Survey** | A docs-only PR enumerating findings, with a taxonomy. | Wide net. No fixes. Categorise the surface area. Flag candidates as candidates, not violations. |
| **2. Verdict refinement** | A docs-only PR that narrows or zeroes out an over-broad first-phase signal. | Apply the taxonomy mechanically across the full population. Subtract false positives. |
| **3. Fan-out implementation** | One or many small PRs implementing the cleaned-up gap list. Each PR is independent and small. | Domain-by-domain. Per-spec or per-module RFC stubs from Phase 1 become the work queue. |
| **4. Ratchet enforcement** | A scripts PR + CI wire-up PR. | Convert Phase 1's metric into a monotonic gate. Defer hard-gating until ≥2 Phase 3 PRs have moved the floor. |

## 3. Worked examples

### 3.1 Q-P0-3: OAS↔MASC boundary

| Phase | PR | Result |
|---|---|---|
| 1 | #12112 (MERGED) | Survey: 3-layer model (A/B/C). Layer C flagged `NEEDS SWEEP` from raw counts |
| 2 | #12116 (MERGED) | Verdict refined NEEDS SWEEP → PASS via C1–C4 reference taxonomy |
| 3 | #12117 (MERGED, ratchet) + #12119 (MERGED, CI wire-up) | C4 floor=0, descriptive `bridge_adoption_files`. Test-tier PASS-AS-INTENDED |
| 4 | (deferred 6 months) | `bridge_adoption_files` monotonic floor pending usage data |

### 3.2 Q-P0-2: TLA+ specs gap

| Phase | PR | Result |
|---|---|---|
| 1 | #12123 (MERGED) | Survey: 3 gap classes (Bug Model coverage, tautology, split-pair). 5 zero-coverage domains |
| 2 | #12132 (MERGED) | Tautology candidates 21 → 0 via SPECIFICATION line diff |
| 3 | #12137 (MERGED, RFC stubs) + 8 implementation PRs (#12160, #12167, #12168, #12174, #12175, #12178, #12180, #12186) | 0%-coverage domains 5 → 0. Phase 3 prereq classification accuracy 1/3 (33%) |
| 4 | (next PR) | `tla-bug-model-ratchet.sh` + CI wire-up |

## 4. Self-correcting property

Both chains exhibit a **conservative-bias correction** between Phase 1 and Phase 2:

- Q-P0-3 Phase 1 raw counts said Layer C has 91/62/47 references (NEEDS SWEEP). Phase 2's C1–C4 taxonomy reduced "real violations" to 0.
- Q-P0-2 Phase 1 said 21 specs are tautology candidates. Phase 2's SPECIFICATION diff confirmed 0 actual tautologies.
- Q-P0-2 Phase 3 said 3 specs need prereq invariants. Implementation found 1 actual prereq, 2 false positives.

In all three cases the audit *over-classified* in the conservative direction. This is **the desirable shape**:
- False positive in "needs work" → cheap to discover during implementation
- False negative in "passes" → expensive (silent gaps that the audit failed to catch)

Survey audits should pick this side of the trade-off.

## 5. Phase 1 framing rules (most important)

The most leveraged decisions live in Phase 1. From observed patterns:

1. **Mark candidates as candidates, not violations.** Phase 1 of Q-P0-2 wrote "21 candidate-tautology rows that warrant per-spec inspection" rather than "21 weak Bug Models." This single word choice prevented a 21-item false retraction in Phase 2.
2. **Lead with a taxonomy.** Q-P0-3's C1–C4 categorisation in Phase 2 was retroactively useful in Phase 1's framing. Even if the taxonomy is informal in Phase 1, having one ready helps Phase 2 narrow.
3. **Defer fixes.** Phase 1 should never include code changes beyond docs. Implementation belongs in Phase 3.
4. **Recommend ratchets descriptively.** Phase 1 §6 in both chains proposed ratchets but didn't enforce. Enforcement is a Phase 4 concern.

## 6. Phase 2 toolkit

Phase 2's narrowing usually uses one of:

- **Mechanical script** (Q-P0-2: `cycle11-tautology-sweep.sh` diffed SPECIFICATION lines across 21 candidates)
- **Reference taxonomy** (Q-P0-3: C1–C4 reference categories per call site)
- **Header inspection** (Q-P0-2: spec headers' `OCaml↔TLA mapping` text)

Pick the cheapest one that decides each candidate. If no cheap test exists, defer to Phase 3 case-by-case.

## 7. Phase 3 fan-out shape

Each Phase 3 implementation PR should:

- Touch a single spec or module
- Be independent of sibling PRs (no implicit ordering)
- Reference Phase 1's RFC stub by ID (`RFC-Q2-N`)
- Note any deviation from the stub's proposed bug action (Q2-7 pivoted from `FullSuccessWithDegradation` to `AppendPartialNonDisjoint` mid-implementation; the PR body documented why)

Aim for 1 Phase 3 PR per cycle when running parallel cron-driven fanout.

## 8. Phase 4 deferral discipline

Don't wire ratchets into CI immediately after Phase 3 closes. From observation:
- OAS chain wired the ratchet at the same time as Phase 3 (#12117 + #12119) because the metric (C4 direct calls) was already at 0.
- TLA gap chain defers Phase 4 wire-up because two ratchet metrics need ≥2 Phase 3 implementations to cross the meaningful floor (otherwise the gate trivially passes at first enforcement).

Rule of thumb: **defer hard-gating until at least 2 Phase 3 PRs have moved the floor.** Otherwise the ratchet's first CI run carries no signal.

## 9. When NOT to use this pattern

- **Quick tactical fix**: single bug, single PR. No survey needed.
- **Design RFC**: this pattern is for *measuring existing state*, not for *deciding direction*. RFCs and audits are different shapes.
- **Homogeneous domain**: if all specs/modules look alike, a single audit pass suffices. The 4-phase shape is for *heterogeneous* domains where wide-net first-cuts mis-classify.
- **High-stakes destructive change**: wide-net surveys can recommend deletes. Don't bundle delete recommendations into a Phase 3 PR — split as a separate decision. (Memory rule: `feedback_self_confession_comments_must_be_measured` — don't trust audit prose alone for irreversible work.)

## 10. References

- `docs/audit/OAS-MASC-BOUNDARY-AUDIT-2026-04*.md` — Q-P0-3 chain (4/4 MERGED)
- `docs/audit/TLA-SPECS-GAP-AUDIT-2026-04*.md` — Q-P0-2 chain (Phase 3 closure in #12188)
- `scripts/oas-boundary-ratchet.sh` — ratchet template (decreasing-monotonic)
- `scripts/tla-ppx-ratchet.sh` — ratchet template (increasing-monotonic, PR #12151)
- Memory: `feedback_diagnostic_with_measurement_strongly_triggers_root_fix` — measurement matters

*Process doc / 2026-04-30 / source: Q-P0-2 + Q-P0-3 closure observations*
