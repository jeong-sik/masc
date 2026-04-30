# OAS ↔ MASC Boundary Audit — Phase 3 (test-tier sweep + Phase 2 errata + CI wire-up)

> Status: Phase 3 of 4. Test-tier scan, Phase 2 imprecision correction, ratchet CI wire-up.
> Author: Vincent (jeong-sik) with Claude
> Created: 2026-04-30
> Tracks: Q-P0-3 follow-up
> Related: PR #12112 (Phase 1, Draft), PR #12116 (Phase 2, MERGED), PR #12117 (ratchet, MERGED)

---

## 1. Test-tier scan

```bash
rg -l "Oas\." test/ | wc -l   # 13 files
rg -c "Oas\." test/ | sort -t: -k2 -n -r | head
# test/test_oas_worker.ml:132
# test/test_memory_oas_5tier.ml:47
# test/test_mid_turn_resume.ml:42
# ...
```

13 test files import `Oas.*`. Same C1–C4 categorization (Phase 2 §1) applies.

### 1.1 C4 in tests — verdict PASS-AS-INTENDED

Direct `Oas.Agent.run` / `Oas.Tool.dispatch` call sites in `test/`:

```bash
$ rg "Oas\.Agent\.run|Oas\.Tool\.dispatch" test/
test/test_oas_worker.ml:            match Oas.Agent.run ~sw agent "what time is it?" with
test/test_oas_worker.ml:            match Oas.Agent.run ~sw agent "what time is it?" with
```

Two calls, both in `test/test_oas_worker.ml` — the **test for the Layer B adapter** `lib/oas_worker.ml`. The adapter's contract is *to call `Oas.Agent.run`*, so the test must call it too. Forbidding C4 here would force test fixtures through the bridge they are testing — circular.

**Decision**: test/ is **out of scope** for the C4 ratchet. The current ratchet's LAYER_C_GLOBS already excludes test/ implicitly (the globs whitelist `lib/keeper`, `lib/server`, `lib/dashboard`, `lib/local` only). Document, don't enforce.

### 1.2 Other test-tier patterns (informational)

Acceptable test-only patterns observed:
- Direct constructor of `Oas.Types.*` records for fixtures.
- Pattern matching on `Oas.Hooks.t` variants (C2) for hook unit tests.
- Reuse of `Oas.Context_reducer.estimate_*` (C3) for token-budget assertions.

None of these are violations.

## 2. Phase 2 errata

Phase 2 §3 reported `bridge_adoption_files = 5`. Phase 3 verification:

```bash
$ rg -l "Masc_oas_bridge\." \
    --glob 'lib/keeper/**/*.ml' \
    --glob 'lib/server/**/*.ml' \
    --glob 'lib/dashboard/**/*.ml' \
    --glob 'lib/local/**/*.ml'
lib/keeper/keeper_persona_authoring.ml
lib/dashboard/dashboard_operator_judge.ml
lib/dashboard/dashboard_governance_judge.ml
lib/server/server_openai_compat.ml
```

**Four files**, not five. Phase 2's count included `lib/server/server_openai_compat.mli`, which declares signatures rather than importing the bridge for runtime use. The ratchet (`scripts/oas-boundary-ratchet.sh`, PR #12117) uses `--glob '*.ml'` only and reports 4. The ratchet is correct; the doc was loose. Errata recorded here.

This is also a record of a *useful pattern*: ratchets surface measurement imprecision that audit prose alone cannot. Treating the ratchet as a second auditor produces a self-checking system.

## 3. CI wire-up (this PR)

Adds one step to the existing `structure-ratchet` job in `.github/workflows/ci.yml`:

```yaml
      - name: Run OCaml structure ratchet
        run: scripts/ocaml-structure-ratchet.sh

      - name: Run OAS boundary ratchet
        run: scripts/oas-boundary-ratchet.sh
```

Same job, same trigger conditions (`needs.changes.outputs.lib_deps == 'true' || ... 'build' == 'true'`). The two ratchets share the same install step (`ripgrep`).

Risk:
- A PR that introduces a direct `Oas.Agent.run` in Layer C will fail the gate. Recovery: route through `Masc_oas_bridge.run_with_caller` (or the appropriate Layer B adapter), or — if intentional discipline change — `--regenerate` AND open a paired follow-up issue.
- A PR that *removes* a `Masc_oas_bridge` adoption (descriptive metric) will print a lower count, but the gate does not fail because the descriptive metric is unenforced.

## 4. Final 4-phase summary

| Phase | PR | Verdict |
|---|---|---|
| 1 | #12112 (Draft) | Bridge layer + keeper OAS hooks: PASS for layers A/B core; flagged Layer C as `NEEDS SWEEP` (later refined to PASS). |
| 2 | #12116 (MERGED) | Refined Layer C verdict to PASS. Established C1–C4 reference taxonomy. Recommended ratchet. |
| 3 | this PR | Test-tier verdict: PASS-AS-INTENDED. Phase 2 errata: 5 → 4. Ratchet wired into CI. |
| 4 | follow-up | Optional: bridge_adoption descriptive metric promoted to monotonic floor (`>=4`, only allowed to increase). Trade-off: enforces more bridge adoption but risks gating PRs that legitimately route through other Layer B adapters. Defer until 6 months of usage data. |

## 5. Closing observation: ratchet as second auditor

Across Phase 2 → Phase 3 the ratchet caught a documentation imprecision (5 vs 4) that prose review missed. This is a property worth preserving: **two independent measurements** (audit prose and ratchet script) **catching each other's drift**.

For future audits:
1. Write the prose finding.
2. Encode the same finding as a ratchet metric.
3. Run both. Discrepancies are signal, not noise.

---

## 6. References

- `scripts/oas-boundary-ratchet.sh` — PR #12117 MERGED
- `scripts/oas-boundary-baseline.json` — `c4_direct_runtime_calls_layer_c: 0`, `bridge_adoption_files: 4`
- `docs/audit/OAS-MASC-BOUNDARY-AUDIT-2026-04.md` — Phase 1
- `docs/audit/OAS-MASC-BOUNDARY-AUDIT-2026-04-PHASE2.md` — Phase 2
- `.github/workflows/ci.yml` — `structure-ratchet` job
- Memory: `feedback_ratchet-naturalization-after-admin-merge`, `feedback_ci_runner_dep_regression_silent_127`, `feedback_rg_no_match_pipefail_silent_break`

*Audit date: 2026-04-30 / Phase 3 of 4 / docs change + 1 CI step / closes the audit chain*
