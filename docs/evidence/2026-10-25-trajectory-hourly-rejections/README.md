# Consistent persisted tool failure totals

Scope: #25913's actual outcome observability. Parent #45892 head `8fb696da672be25e8efe69ff6eaccc89cb547e88`.

The actual keeper tool-stats route reads one trajectory window, then calls aggregate_tool_stats and hourly_timeline on that same list. The per-tool view uses existing entry_is_failure (explicit error OR typed Gate.Reject); the hourly view counted only the error option. A Gate rejection with no separate error detail therefore produced a failure in one view and a clean hour in the other.

The hourly projection now reuses the existing predicate. A rejected row counts as a failed call, not proof of an executed external effect; a row with both rejection and error counts once. Window filtering, UTC grouping, wire keys and call totals are preserved. The interface documents these semantics.

The defined feature case writes real entries through append_entry to two trace files, rereads the requested window, and derives both views and public hourly JSON. It excludes an old refusal, includes rejection-only/error-only/combined rows once each and retains a clean next hour. Expected in-window totals: five calls, three failed calls, two successful calls; first hour four calls/three failures and next hour one call/zero failures.

Three changed OCaml files parse and whitespace passes; source-checks.json contains hashes. No local Dune/typecheck/updated-case execution. Request only test/test_trajectory. Full regression is unrun. Parent run40162239132 actually passed22 Fusion cases but is separate evidence, not this candidate's trajectory proof.

This does not implement #25920's owner/time projection index: read_entries_since still scans all files and filters. It is not a performance improvement, a server HTTP request or rendered dashboard verification. Full #25913 remains open; no install/runtime, approval or merge claimed.

Native registration was attempted with gh stack init against the parent branch but refused a live global editing lock; unrelated submit processes were verified. No existing stack, process or lock was changed. Published membership requires REST confirmation and is not inferred from a branch chain.
