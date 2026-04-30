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

## 4.5 Phase 2 outcome categories

Across six chains using this pattern (boundary, specs gap, PPX adoption, dashboard observability, auth/credential, server HTTP routes), Phase 2 produces one of three outcomes per gap class. Naming them helps later authors set expectations.

| Outcome | What happens | Example |
|---|---|---|
| **Narrow-confirm** | Phase 1 estimate sits inside a range; Phase 2 lands in or near that range. | Server HTTP routes C2: Phase 1 said 14–16 silent modules → Phase 2 confirmed 14. |
| **Narrow-collapse** | Phase 2 finds the gap doesn't exist at all. | Server HTTP routes C4 (no auth check): Phase 1 estimate 3–5 → Phase 2 found 0 (all routes wrap in `with_tool_auth` / `with_public_read`). Auth/credential C4 (credential redaction): Phase 1 candidates 2 → Phase 2 found 0 `Log.*` callsites in scope. |
| **Narrow-discover** | Phase 2 confirms the gap is real *because* a Phase 1 hopeful fallback (platform enforcement, shared middleware, etc.) doesn't exist. | Server HTTP routes C1 (no body size-limit): Phase 1 hoped `Http_server_eio` enforced limits globally → Phase 2 confirmed it doesn't. Gap stays real. |

A single audit can produce multiple outcome categories simultaneously. Server HTTP routes Phase 2 (PR #12218) produced one of each: confirm (C2), collapse (C4), discover (C1). Auth Phase 2 (PR #12217) additionally exposed a fourth, less-clean variant — **anchor-falsification**: Phase 1 listed `auth_strict_mode` and `auth_resolve` as C5 anchors based on domain centrality, but Prometheus grep showed 0 calls in either. Phase 1 wasn't over-classifying gaps; it was over-classifying *coverage*.

Calling these out:
- **Narrow-confirm** is the boring base case; expect it on most classes.
- **Narrow-collapse** is the most cost-saving — it eliminates Phase 3 work entirely. Phase 1 should write its taxonomy with collapse in mind ("if X is satisfied by Y, this whole class drops").
- **Narrow-discover** is the most informative — it tells you the gap is *structural*, not accidental. Phase 3 work for narrow-discover gaps usually requires shared infrastructure (middleware, helpers), not per-module fixes.
- **Anchor-falsification** is rare but worth flagging because it inverts the failure mode. Recommendation: in Phase 1, mark C5 anchors as candidates too, and verify them in Phase 2 with the same structural rigor as gap classes.

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
- `docs/audit/TLA-PPX-ADOPTION-AUDIT-2026-04.md` — runtime-side PPX adoption (PR #12143 MERGED)
- `docs/audit/DASHBOARD-OBSERVABILITY-AUDIT-2026-04*.md` — first new-domain application of codified pattern (PR #12202 Phase 1, PR #12208 Phase 2)
- `docs/audit/AUTH-CREDENTIAL-AUDIT-2026-04*.md` — second new-domain application; surfaced anchor-falsification outcome (PR #12209 Phase 1, PR #12217 Phase 2)
- `docs/audit/SERVER-HTTP-ROUTES-AUDIT-2026-04*.md` — third new-domain application; surfaced narrow-confirm + narrow-collapse + narrow-discover in a single chain (PR #12213 Phase 1, PR #12218 Phase 2)
- `scripts/oas-boundary-ratchet.sh` — ratchet template (decreasing-monotonic)
- `scripts/tla-ppx-ratchet.sh` — ratchet template (increasing-monotonic, PR #12151)
- `scripts/tla-bug-model-ratchet.sh` — first mixed-direction ratchet (PR #12192)
- Memory: `feedback_diagnostic_with_measurement_strongly_triggers_root_fix` — measurement matters

*Process doc / 2026-04-30 / source: Q-P0-2 + Q-P0-3 closure observations + 3 new-domain chains; updated 2026-04-30 with §4.5 outcome categories from Auth + Server HTTP Phase 2 findings*
