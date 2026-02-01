# Improvement Backlog - Mitosis System

**Goal**: 200 iterations of feedback loop  
**Target**: Production-ready mitosis with evidence of generational improvement

---

## Iteration Tracking

| Iter | Change | Tests | Build | Metrics | Notes |
|------|--------|-------|-------|---------|-------|
| 1 | masc_mitosis_handoff v1 | ✅ | ✅ | - | Initial impl |
| 2 | BALTHASAR feedback → v2 | ✅ | ✅ | - | Validation, fallback |
| 3 | Generational metrics | ✅ | ✅ | - | Evidence framework |
| 4-200 | TBD | - | - | - | Pending analysis |

---

## Backlog (To Be Filled by Sub-agents)

### P0 - Critical (Must Fix)

| ID | File:Line | Issue | Fix |
|----|-----------|-------|-----|
| P0-1 | mitosis.ml:80-81 | Hardcoded 0.5/0.8 thresholds | Make configurable via args |
| P0-2 | tool_mitosis.ml:188 | Default 0.0 causes silent no-op | Require context_ratio |
| P0-3 | mitosis.ml:77 | dna_compression_ratio=0.1 hardcoded | Config param |
| P0-4 | tool_mitosis.ml:230 | spawn failure only logs, no retry | Add retry logic |
| P0-5 | - | No metrics integration | Wire up generational_metrics |

### P1 - Important (Should Fix)

| ID | File:Line | Issue | Fix |
|----|-----------|-------|-----|
| P1-1 | mitosis.ml:71 | Time_based 300.0 magic number | Named constant |
| P1-2 | mitosis.ml:89 | ID generation uses mod 10000 | Use UUID |
| P1-3 | tool_mitosis.ml | No rate limiting for handoffs | Add cooldown |
| P1-4 | - | No MCP tool for metrics query | Add masc_metrics_compare |
| P1-5 | - | Spawn timeout hardcoded 600s | Make configurable |
| P1-6 | mitosis.ml | No logging/tracing | Add structured logs |
| P1-7 | - | DNA quality not validated before handoff | Add check |

### P2 - Nice to Have (Could Fix)

| ID | File:Line | Issue | Fix |
|----|-----------|-------|-----|
| P2-1 | - | No adaptive thresholds | ML-based threshold |
| P2-2 | - | No A/B test support | Add experiment flag |
| P2-3 | - | No dashboard integration | Export to Prometheus |
| P2-4 | - | Doc strings incomplete | Add odoc |
| P2-5 | - | No CLI for manual testing | Add subcommand |

---

## Test Gaps

| ID | Missing Test | Priority |
|----|--------------|----------|
| T1 | context_ratio = -1.0 (negative) | P0 |
| T2 | context_ratio = 2.0 (>1.0) | P0 |
| T3 | spawn failure → fallback path | P0 |
| T4 | DNA extraction with empty context | P1 |
| T5 | Concurrent handoff attempts | P1 |
| T6 | Generation overflow (>10) | P1 |
| T7 | Full lifecycle: prepare → handoff | P1 |
| T8 | Metrics recording accuracy | P1 |

---

## Automation Rules

### Per-Iteration Checklist

```
□ Select next item from backlog (highest priority first)
□ Implement change
□ Run: dune build
□ Run: dune test
□ If tests pass → commit
□ If tests fail → fix or revert
□ Update metrics
□ Update this backlog
□ Move to next iteration
```

### Success Criteria

- All P0 items completed
- Test coverage > 80%
- Generational metrics show improvement
- BALTHASAR re-review score >= 7/10

### Stop Conditions

- 200 iterations reached
- All backlog items completed
- No measurable improvement for 10 consecutive iterations

---

## Progress Summary

- **Started**: 2026-02-01
- **Current Iteration**: 3
- **Items Completed**: 3
- **Items Remaining**: TBD
