# Repeated review: one live projection and scoped confirmations

Reviewed baseline: `009a43c3d099bded03f80cdbf2413be6caeb0444`.

A stale observation after a failed finish write could make a stopped Keeper
simultaneously suspended and live. `Keeper_composite_observer.live_turn_observation`
now owns the phase-aware projection. Composite fields, Queue busy/current
execution and the turn-record API use that function. Raw registry observations
remain available to the invariant checker; this is a read projection, not a
lifecycle mutation or deletion of diagnostic evidence.

Pending confirmation target decoding uses `Operator_action_constants`.
A scoped Keeper view no longer reclassifies another Keeper's request as global.
Workspace/Goal confirmations and authoritative read failures remain visible;
the complete fleet inventory still retains unknown Keeper targets for diagnosis.
The displayed global count is derived from the same global confirmation rows.

Nine source/interface/test files passed isolated OCaml 5.5.1 type checks with
warnings 8/32/69 as errors, using cached dependency interfaces. Exact source
hashes and exit codes are in typecheck-results.json. New regression scenarios
exercise registry state changes and real confirmation storage via public
inventory operations, including known/unknown other Keeper targets and store
corruption. Those behavioral suites are authored and typechecked, not executed.
No full build, HTTP/PTY execution, live runtime mutation or deployment ran.
Earlier evidence remains scoped to its original source hashes.
