# Issue #3015 Status Check (2026-03-30, Updated 2026-03-31)

## TL;DR

**✅ YES, issue #3015 is ready to progress.**

**⚠️ UPDATE 2026-03-31**: Issue #3015 is now labeled `target:next` (no longer `target:now`), indicating it has been deprioritized relative to other current work.

- **Phase 1 (cascade_inference)**: ✅ COMPLETE
- **Phase 2 (context_router)**: ✅ COMPLETE (file removed)
- **Phase 3 (memory unification)**: ⚠️ PARTIAL (bridge exists, duplication remains)
- **Phase 4 (auto_recall)**: ⏳ PENDING (waiting on OAS)
- **Blockers**: None identified

---

## Current State Summary

### Completed Work

**Phase 1: cascade_inference → OAS delegation** ✅
- PR #2941: Delegated to OAS `Cascade_config` (v2.149.0)
- PR #2921: Replaced hardcoded temperature/max_tokens
- PR #3012: Made cascade_name sole authority (removed models/allowed_models/active_model)
- PR #3031: Removed hardcoded pricing
- `cascade_inference.ml`: 116 lines → 70 lines (-41%), fully delegates to OAS

**Phase 2: context_router extraction** ✅
- Child issue #3095: CLOSED (2026-03-26)
- `context_router.ml`: **REMOVED** in #3232 (381 LOC dead code, 0 external callers)
- OAS-MIGRATION-AUDIT.md Phase 3 (context_router 2 sites): N/A after removal

### Partial Progress

**Phase 3: Memory systems unification** ⚠️
- Child issue #3097: CLOSED (2026-03-28)
- `memory_oas_bridge.ml`: Active (474 LOC) — 5-tier bridge to OAS Memory.t
- `keeper_memory*.ml`: 4 modules (1294 LOC) — still have MASC-owned memory logic
- **Gap**: Duplication exists between keeper_memory and OAS bridge
- **Status**: Bridge is functional, but memory ownership is not yet unified

**Phase 4: auto_recall RAG routing** ⏳
- `auto_recall.ml`: 415 LOC — agent memory injection
- **Gap**: No OAS equivalent for RAG routing yet
- **Status**: Waiting on OAS roadmap

### File Status Verification

| File | Expected State (from #3015) | Actual State (v2.167.0) |
|------|----------------------------|------------------------|
| `cascade_inference.ml` | Partially delegated | ✅ Fully delegated to OAS |
| `memory_oas_bridge.ml` | Incomplete bridge | ✅ Active 5-tier bridge |
| `context_compact_oas.ml` | Thin wrapper | ✅ Direct OAS delegation |
| `context_router.ml` | Extract to OAS | ✅ Removed (dead code) |
| `keeper_memory*.ml` | 4 types needing unification | ⚠️ Still duplicated alongside bridge |
| `auto_recall.ml` | Not in OAS yet | ⏳ Still MASC-owned |

---

## Remaining Work

### Immediate Next Steps (Phase 3)

1. **Audit keeper_memory* modules**:
   - `keeper_memory.ml` (interface)
   - `keeper_memory_bank.ml` (storage)
   - `keeper_memory_policy.ml` (retention)
   - `keeper_memory_recall.ml` (retrieval)

2. **Reduce duplication**:
   - Identify what keeper_memory* does that memory_oas_bridge doesn't
   - Move reusable logic to OAS or consolidate in bridge
   - Keep only MASC-specific memory policies/heuristics in keeper_memory*

3. **Verify #3097 outcomes**:
   - Check what "unify keeper memory and compaction interfaces" accomplished
   - Review closure rationale and any follow-up recommendations

### Future Work (Phase 4)

4. **auto_recall.ml extraction**:
   - Wait for OAS RAG routing capability
   - Document MASC-specific memory sources to keep (masc_cache, broadcasts)
   - Plan extraction once OAS provides foundation

---

## Blocking Dependencies Check

### ✅ No blockers found:

- **Build**: Codebase is buildable (dune works in CI)
- **Tests**: 11 OAS integration test files exist and pass
- **Child issues**: #3095, #3097 closed; #3228 is C-5 track (separate)
- **OAS version**: v0.89.1+ provides necessary primitives
- **Documentation**: Comprehensive (docs/spec/13-oas-integration.md, docs/OAS-MIGRATION-AUDIT.md)

### ⚠️ Priority clarification needed:

**Issue #3015 is labeled `target:now`** (current product-promise blocker)

**But ROADMAP.md v2.167.0 target:now focuses on**:
- CI truth and merge gates
- Transport and health truth
- Config visibility foundation
- Product and release truth

**Question for triage**: Is OAS delegation truly blocking the product promise, or is it architectural cleanup that should be `target:next` or `target:later`?

---

## Recommendation

**The issue is technically ready to progress.** Recommended approach:

1. **Clarify priority** with maintainer:
   - Confirm `target:now` vs other tracks
   - Decide if Phase 3 should happen before CI/transport/config work

2. **If target:now confirmed**:
   - Focus on Phase 3 memory unification
   - Break into small deliverable slices (like #3095, #3097 were)
   - Create concrete implementation plan based on keeper_memory* audit

3. **If target:next/later**:
   - Document Phase 3 plan for future work
   - Focus on current ROADMAP.md priorities first
   - Revisit after v2.168.0+ release

---

## Related Issues

- **Parent**: #2878 (Ecosystem audit C-1)
- **Children**: #3095 (closed), #3097 (closed), #3228 (open, C-5 track)
- **Related PRs**: #2941, #2921, #3012, #3031 (all merged)
- **Mentions**: #3016 (C-5: Kitchen sink separation)

---

**Full detailed analysis**: See `ISSUE-3015-STATUS.md` in this branch.
