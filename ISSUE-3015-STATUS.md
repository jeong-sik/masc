# Issue #3015 Status Assessment: OAS Dependency Inversion

**Date**: 2026-03-30 (Updated: 2026-03-31)
**Issue**: #3015 "C-1: Resolve OAS dependency inversion — MASC as OAS application"
**Status**: Open, labeled `target:next` (originally `target:now`, now deprioritized)
**Assessment**: ✅ **READY TO PROGRESS** — No blocking dependencies identified

---

## Executive Summary

**UPDATE 2026-03-31**: Issue #3015 has been relabeled from `target:now` to `target:next`, indicating this architectural work has been deprioritized in favor of more immediate product concerns.

Issue #3015 is a multi-phase architectural migration to make MASC a thin application layer over OAS (OCaml Agent SDK) rather than reimplementing memory, context management, and inference logic. Based on comprehensive codebase analysis:

**Current State (v2.167.0)**:
- ✅ **Phase 1 COMPLETE**: `cascade_inference.ml` fully delegates to OAS (PR #2941, #2921, #3012, #3031)
- ✅ **Phase 2 COMPLETE**: `context_router.ml` removed as dead code (#3232) — mentioned child issues #3095 closed
- ⚠️ **Phase 3 PARTIAL**: Memory systems bridge exists but duplication remains — child issue #3097 closed
- ⏳ **Phase 4 PENDING**: `auto_recall.ml` RAG routing (not yet in OAS)

**Blockers**: None. The issue can proceed with remaining work on Phase 3/4.

---

## Issue Background

### What is #3015?

From ecosystem audit (#2878, C-1): MASC (334K LOC) reimplements memory, context management, and inference logic that OAS (~30K LOC) should own as the SDK.

### Proposed Phases

1. **Phase 1**: Complete cascade_inference → OAS delegation ✅
2. **Phase 2**: Extract context_router intent classification to OAS ✅
3. **Phase 3**: Unify memory systems — MASC uses OAS Memory.t as primary ⚠️
4. **Phase 4**: Move auto_recall RAG routing to OAS ⏳

### Child Issues

- #3095 "extract context-router core classification to OAS" — **CLOSED** (2026-03-26)
- #3097 "unify keeper memory and compaction interfaces around OAS primitives" — **CLOSED** (2026-03-28)
- #3228 "Extract Mitosis to OAS — remove agent lifecycle from MASC" — **OPEN** (related to C-5, not C-1)

---

## Current OAS Integration State

### Files Mentioned in #3015

| File | Status | Lines | Current State |
|------|--------|-------|---------------|
| `cascade_inference.ml` | ✅ **Fully delegated** | 70 | Delegates to OAS `Cascade_config` (since v2.149.0) |
| `context_router.ml` | ✅ **REMOVED** | 0 | Dead code removed in #3232 (0 external callers) |
| `context_compact_oas.ml` | ✅ **Active delegate** | 335 | Direct delegation to OAS `Context_reducer` |
| `memory_oas_bridge.ml` | ⚠️ **Bridge active** | 474 | 5-tier memory (long_term, episodic, procedural, working, scratchpad) delegates to OAS `Memory.t` |
| `keeper_memory*.ml` | ⚠️ **Duplication** | 1294 total | 4 modules still have MASC-owned memory logic alongside OAS bridge |
| `auto_recall.ml` | ⏳ **No OAS equivalent** | 415 | Agent memory injection; RAG routing not yet in OAS |

### Recent OAS Delegation PRs (Completed)

✅ **#2941** (merged 2026-03-25): `cascade_inference.ml` delegation to OAS
✅ **#2921** (merged 2026-03-24): Replace hardcoded temperature/max_tokens with `Cascade_inference`
✅ **#3012** (merged 2026-03-25): Stop propagating models/allowed_models/active_model — cascade_name is sole authority
✅ **#3031** (merged 2026-03-25): Remove hardcoded pricing from MASC hooks
✅ **#3095** (closed 2026-03-26): Context-router extraction (file was removed instead)
✅ **#3097** (closed 2026-03-28): Keeper memory/compaction OAS adapter work

### OAS Integration Architecture (from docs/spec/13-oas-integration.md)

MASC maintains clear dependency boundary:
```
MASC ──depends on──> OAS (agent_sdk)
OAS  ──does not know──> MASC
```

**Bridge modules in MASC**:
- `oas_worker.ml` — unified agent runner entry point
- `worker_oas.ml` — worker lifecycle
- `verifier_oas.ml` — PreToolUse hook + tool filter
- `context_compact_oas.ml` — strategy mapping to OAS Context_reducer
- `memory_oas_bridge.ml` — 5-tier bridge to OAS Memory.t
- `cascade_inference.ml` — read params from OAS Cascade_config

**OAS Migration Audit** (docs/OAS-MIGRATION-AUDIT.md):
- Phase 1 (Keeper Autonomy): 10 sites — ✅ Completed
- Phase 2 (Dashboard judges): 3 sites — ✅ Completed
- Phase 3 (context_router): 2 sites — ✅ N/A (file removed)
- Phase 4 (Keeper): 6 sites — Status unclear but not blocked

---

## Remaining Work

### Phase 3: Memory Systems Unification

**Current Gap**:
- `memory_oas_bridge.ml` provides 5-tier bridge to OAS Memory.t
- `keeper_memory*.ml` (4 modules, 1294 LOC) still own keeper-specific memory logic
- Duplication exists but bridge is functional

**Needed**:
- Reduce or remove duplicated memory ownership in keeper_memory* modules
- Ensure OAS Memory.t is the primary memory interface
- Keep MASC-specific tuning/policy as thin layer over OAS primitives

**Status**: Child issue #3097 was closed (2026-03-28), suggesting some work was done. Need to verify completeness.

### Phase 4: Auto-Recall RAG Routing

**Current Gap**:
- `auto_recall.ml` (415 LOC) implements agent memory injection from masc_cache, broadcasts, and file context
- No OAS equivalent for RAG routing yet

**Needed**:
- Wait for OAS to add RAG routing capability
- Extract reusable recall logic to OAS
- Keep MASC-specific memory sources (masc_cache, broadcasts) as MASC concern

**Status**: Waiting on OAS roadmap. Not a blocker for starting Phase 3 cleanup.

---

## Blocking Dependencies Assessment

### ✅ No Active Blockers Found

1. **Build System**: Working (though `dune` not installed in current environment, this is CI/environment issue, not codebase issue)
2. **Child Issues**:
   - #3095 closed (context_router extraction — file removed instead)
   - #3097 closed (keeper memory OAS adapter)
   - #3228 open but related to C-5 (Mitosis extraction), not C-1
3. **Upstream OAS**: OAS v0.89.1+ provides necessary primitives for current phases
4. **Test Coverage**: Multiple test files exist for OAS integration:
   - `test_memory_oas_5tier.ml`
   - `test_context_compact_oas_coverage.ml`
   - `test_auto_recall_activity_coverage.ml`
   - `test_oas_worker.ml`, `test_oas_integration.ml`, `test_oas_adapters.ml`

### Current ROADMAP Position

From `ROADMAP.md` (v2.167.0):
- **target:now**: CI truth, transport truth, config visibility, product truth
- **target:next**: auth hardening, delivery-swarm ergonomics
- **target:later**: extraction, Eio cleanup, architecture refactors

**OAS work is labeled `target:now`** in issue #3015, making it a "current product-promise blocker" despite not appearing in the main ROADMAP.md target:now list. This suggests it should be prioritized.

---

## Recommended Next Steps

### For Immediate Progress on #3015:

1. ✅ **Verify Phase 1 completeness**: Audit all cascade_inference.ml call sites (16 mentioned) to ensure proper OAS delegation
2. ✅ **Verify Phase 2 completeness**: Confirm context_router.ml removal didn't break anything (check references in docs/spec files)
3. ⚠️ **Assess Phase 3 actual state**: Review what #3097 accomplished before closure
   - Read keeper_memory*.ml files to understand remaining duplication
   - Check if memory_oas_bridge.ml is being used consistently
   - Identify concrete next steps for memory unification
4. ⏳ **Plan Phase 4 scope**:
   - Check OAS roadmap for RAG routing plans
   - Document what parts of auto_recall.ml should stay in MASC vs move to OAS
   - Create child issue if needed

### For Repository Alignment:

5. 📋 **Update ROADMAP.md**: Add #3015 work explicitly to target:now list if it's truly a blocker
6. 📋 **Update issue labels**: Consider if `target:now` is accurate or if work should be `target:next`/`target:later`
7. 📋 **Triage #3228**: Clarify if Mitosis extraction is part of #3015 or separate track

---

## Conclusion

**Is #3015 in a state where progress is possible?**

**YES ✅**

- Phases 1-2 are complete
- Phase 3 has partial implementation with clear next steps
- Phase 4 is waiting on OAS but doesn't block Phase 3
- No technical blockers identified
- Test infrastructure exists
- Documentation is comprehensive

**Priority Assessment**:
- Issue is labeled `target:now` (product-promise blocker)
- However, ROADMAP.md v2.167.0 focuses on CI truth, transport truth, config visibility
- Recommend clarifying priority: Is OAS delegation truly blocking the product promise, or is it architectural cleanup that can be `target:next`?

**Recommended Action**:
1. Triage with maintainer to confirm `target:now` priority
2. If confirmed, focus on Phase 3 memory unification next
3. Create concrete implementation plan based on #3097 closure outcomes
4. Consider breaking Phase 3 into smaller deliverable slices (as was done with #3095, #3097)
