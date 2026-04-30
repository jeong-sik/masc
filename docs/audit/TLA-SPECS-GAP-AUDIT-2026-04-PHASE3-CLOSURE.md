# TLA+ Specs Gap Audit — Phase 3 Closure Summary

> Status: Phase 3 closure (8/8 RFC stubs implemented). Phase 4 readiness assessment.
> Author: Vincent (jeong-sik) with Claude
> Created: 2026-04-30
> Tracks: Q-P0-2 chain
> Closes: PR #12137 §RFC-Q2-1 through Q2-8

---

## 1. Phase 3 outcome — 8/8 RFC stubs implemented

| RFC | Spec | Implementation PR | Class outcome |
|---|---|---|---|
| Q2-1 | autonomous/AutonomousLoop | #12174 | strong-invariant |
| Q2-2 | autonomous/AutonomousPhase | #12160 | strong-invariant |
| Q2-3 | masc-ecosystem/MASCEcosystem | #12188 (sibling) | **true prereq** |
| Q2-4 | multimodal/MultimodalArtifact | #12167 | strong-invariant |
| Q2-5 | multimodal/MultimodalHydrator | #12178 | strong-invariant (was "needs prereq") |
| Q2-6 | resilience/ResilienceDegradation | #12175 | strong-invariant |
| Q2-7 | resilience/ResilienceOutcome | #12168 | strong-invariant (pivoted BugAction) |
| Q2-8 | shared/SharedAudit | #12180 | strong-invariant (was "needs prereq") |

**Coverage**: 0%-coverage domains went from 5 → 0 (autonomous, multimodal, resilience, shared all fully covered; masc-ecosystem reaches 1/1 once Q2-3 PR lands).

## 2. Phase 3 prereq classification accuracy

Phase 3 §3 originally classified 3 of 8 stubs as "needs prereq" (MASCEcosystem Q2-3, MultimodalHydrator Q2-5, SharedAudit Q2-8). Implementation outcome:

| Stub | Phase 3 said | Reality |
|---|---|---|
| Q2-3 MASCEcosystem | needs prereq (`AtMostOneAgentPerTask`) | **true prereq** — invariant did need to be added |
| Q2-5 MultimodalHydrator | needs prereq (`NoSelfLoop`) | **false positive** — already in cfg |
| Q2-8 SharedAudit | needs prereq (`ChainIntegrity`) | **false positive** — already in cfg |

**1/3 prereq classifications were accurate (33%)**. Conservative-bias pattern surfaced once again — the audit favoured over-classifying as "needs work" rather than missing real gaps. Same shape as Q-P0-2 Phase 2 (21 tautology candidates → 0 actual). This is the *desirable* direction for survey audits — false positives in "needs work" are cheap to discover during implementation; false negatives in "passes" are expensive (silent gaps).

## 3. Spec-side coverage now closed

After all 8 implementation PRs merge:

| Metric | Phase 1 (#12123) | Phase 3 closure |
|---|---|---|
| Specs with Bug Model | 47 of 84 | 55 of 84 (estimated) |
| Domains with 0% Bug Model | 5 | 0 |
| Bug Model coverage rate | 56% | 65% (estimated) |

(The 8 RFC stubs cover 8 specs; the rest of the 84-spec growth is from boundary/keeper-state-machine specs that already had Bug Models.)

## 4. Phase 4 readiness — ratchet wire-up

Phase 1 §6 proposed a `domains_without_bug_model` ratchet floor at 5 (current count at audit time). After Phase 3 closure, the floor would be **0** — fully enforced. PR #12151 implemented `tla-ppx-ratchet.sh` (PPX adoption side); the spec-side ratchet is a sibling.

Two metrics worth ratcheting now:

| Metric | Floor | Direction |
|---|---|---|
| `bug_model_coverage_specs` | 55 (estimated) | monotonic increase |
| `domains_without_bug_model` | 0 | monotonic stay-at-zero |

The second metric is the stronger gate — it asserts no domain regresses to zero coverage. Pair this with the existing PPX ratchet (#12151) and the spec-side audit chain has the same structure as the OAS chain (Phase 1→4, ratchet enforced).

## 5. CI wire-up plan

Mirroring OAS chain Phase 3 (#12119 wired `oas-boundary-ratchet.sh` into `.github/workflows/ci.yml`), the next PR adds:

```yaml
- name: Run TLA+ specs Bug Model ratchet
  run: scripts/tla-bug-model-ratchet.sh   # to be created
```

Single CI step, same `structure-ratchet` job as the OAS ratchet. Implementation deferred to a separate PR following the same template pattern.

## 6. Audit chain pattern — closure observation

Across both Q-P0-3 (OAS, MERGED 4/4) and Q-P0-2 (TLA gap, 8 RFC stubs implemented), the same 4-phase shape emerged:

| Phase | Q-P0-3 (OAS) | Q-P0-2 (TLA gap) |
|---|---|---|
| 1 | Layer A/B/C survey | Bug Model + tautology + split-pair survey |
| 2 | Layer C verdict refined NEEDS SWEEP → PASS via taxonomy | Tautology candidates 21 → 0 via SPECIFICATION diff |
| 3 | Test-tier scan + Phase 2 errata + ratchet wire-up | 8 RFC stubs implementation (this PR closes) |
| 4 | (deferred 6 months — `bridge_adoption` floor) | Ratchet wire-up (next PR) |

Both audits exhibit the same self-correcting structure: each phase narrows or zeroes out an over-broad first-phase signal. This is now a documented audit pattern worth re-using for future surveys.

## 7. Recommended next actions (out of scope here)

1. **`scripts/tla-bug-model-ratchet.sh` + baseline** (1 cycle): mirrors `tla-ppx-ratchet.sh` structure, monotonic-increase strict + monotonic-decrease descriptive
2. **CI wire-up PR** (1 cycle): adds the single ratchet step to `.github/workflows/ci.yml`
3. **Phase 4 closure summary**: 6-month review point per OAS Phase 4 deferral discipline
4. **Audit pattern doc** (optional): codify the 4-phase shape for future audit chains

## 8. References

- PR #12123 — Phase 1 (MERGED)
- PR #12132 — Phase 2 (MERGED via #12132)
- PR #12137 — Phase 3 RFC stubs (MERGED)
- PR #12138 — naming unification (MERGED)
- PR #12160, #12167, #12168, #12174, #12175, #12178, #12180, sibling Q2-3 — 8 implementation PRs
- PR #12143 — sibling PPX adoption audit (MERGED)
- PR #12151 — `tla-ppx-ratchet.sh` (Draft)
- `docs/audit/OAS-MASC-BOUNDARY-AUDIT-2026-04-PHASE3.md` — sister chain Phase 3 (MERGED)
- CLAUDE.md `TLA+ Bug Model 패턴`

*Audit date: 2026-04-30 / Phase 3 closure / docs-only / 8/8 RFC implementation summary*
