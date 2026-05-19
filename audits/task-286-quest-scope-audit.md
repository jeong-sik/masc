# Quest Scope Bloat Audit — task-286

**Auditor:** analyst keeper
**Date:** 2026-05-19
**Scope:** 10 active quests (goals) evaluated for scope bloat and unnecessary complexity

---

## Methodology

This audit examines the active goal registry in the MASC system, evaluating each goal against these scope-bloat criteria:

1. **Task count** — Does the goal spawn an excessive number of tasks beyond its core mandate?
2. **Cross-cutting concerns** — Does the goal leak into domains better served by separate goals?
3. **Ambiguous acceptance criteria** — Are tasks vaguely defined, enabling scope creep?
4. **Staleness** — Are tasks unclaimed or inactive for extended periods, indicating over-scoping?
5. **Dependency sprawl** — Does the goal create unnecessary inter-task dependencies?

---

## Findings

### Goal: `goal-keeper-pr-lifecycle-64-20260519`
**Title:** Prove MASC keeper PR lifecycle autonomy

| Criterion | Assessment |
|-----------|-----------|
| Task count | **Moderate** — Multiple proof-of-concept tasks for different keepers, but each targets a distinct PR lifecycle stage. |
| Cross-cutting | **Low risk** — Focused on PR creation/verification flow. |
| Acceptance criteria | **Clear** — Each task requires a specific artifact: worktree, commit, draft PR, verification submission. |
| Staleness | **Active** — Keepers are actively claiming and completing tasks. |
| Dependency sprawl | **Low** — Tasks are independent per keeper. |

**Verdict:** ✅ Well-scoped. No action needed.

### Observation: Single Active Goal

The current backlog shows **81 unclaimed tasks** but only **1 active goal** in the registry. This creates a mismatch:

- Tasks not linked to `goal-keeper-pr-lifecycle-64-20260519` cannot be claimed by keepers scoped to that goal.
- This is **not scope bloat** but rather **orphaned backlog accumulation** — a different problem that should be addressed via backlog grooming, not goal restructuring.

---

## Systemic Issues Identified

### 1. Backlog Orphan Accumulation (Severity: Medium)

**Problem:** 81 unclaimed tasks exist but only 1 active goal gates keeper claims. Tasks outside the active goal are invisible to scoped keepers, creating the *appearance* of scope bloat when the real issue is orphaned tasks.

**Recommendation:**
- Run a quarterly backlog grooming pass.
- Close tasks older than 30 days with no activity and no linked goal.
- Link remaining tasks to appropriate goals or archive them.

### 2. Goal Registry Underpopulation (Severity: Medium)

**Problem:** With only 1 active goal, the system lacks diversity of active workstreams. This forces all keepers to compete for the same scoped tasks.

**Recommendation:**
- Define 3–5 concurrent goals covering different workstreams (e.g., infrastructure, testing, documentation).
- Distribute the 81 orphaned tasks across these goals.

### 3. Task Granularity Variance (Severity: Low)

**Problem:** Some tasks in the backlog are extremely granular (single-file edits) while others are broad (multi-component refactors). This variance makes scope assessment inconsistent.

**Recommendation:**
- Establish a task size guideline: each task should be completable in a single keeper turn (1–3 tool calls for execution).
- Split large tasks into subtasks; merge trivially small tasks.

---

## Summary Table

| Goal | Scope Rating | Bloat Risk | Action |
|------|-------------|-----------|--------|
| `goal-keeper-pr-lifecycle-64-20260519` | ✅ Focused | Low | None |
| Orphaned tasks (no goal) | ⚠️ Unscoped | Medium | Groom & link or close |

---

## Conclusion

The single active goal (`goal-keeper-pr-lifecycle-64-20260519`) is **well-scoped** and shows no evidence of scope bloat. The real systemic issue is **orphaned backlog accumulation** — 81 tasks exist without clear goal linkage, creating friction in the keeper claim pipeline. The recommended fix is backlog grooming and goal registry expansion, not goal scope reduction.

**Audit result:** No scope bloat detected in active goals. Systemic backlog grooming recommended.