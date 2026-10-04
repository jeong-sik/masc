# Pending recovery with bounded receipt queries

This composition integrates #41033 durable pending markers/per-instance discovery with #41126 bounded receipt projection and its UID-independent optional-compaction fixture. Stable per-request locks cover writers, retry and cold reads. Markers are durable before journal mutation; both namespaces verify before marker retirement. Optional compaction cannot write when its marker fails, and the scoped test callback is reached only after that marker and normal durability verification.

Conflict resolution retains the child journal-budget/projection accounting inside the locked helper and the parent's outer typed filesystem error boundary. Both testing interfaces and all parent/child cases are retained. No query allowance is enlarged. The lower #41033 worker failure was the existing child-owned large receipt query case; the actual composed #41126 passes it.

Focused build succeeded; all115 native cases passed: worker49, runtime25, receipt recovery11, bounded history13, HTTP sampling composition17. Tests cover same-root Stores, concurrent writers, interrupted marker/journal publication, orphan markers, incomplete discovery, malformed versus newly valid bindings, canonical parent ownership, relative roots, optional compaction failure, both evidence orderings and aggregate/per-file limits. Original baseline RED and lower scoped failures remain in their respective evidence directories.

The deterministic compaction fault was exercised as UID502. No root-container execution, hosted full CI, provider call, release or Terminal-Bench success is claimed.
