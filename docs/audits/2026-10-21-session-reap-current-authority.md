# Keep reap activity inside current protocol presence

Review #44460 / 5589605540 identifies a stale-cohort update: reap captures
protocol IDs, calls the active predicate and then refreshes activity. If a
concurrent call or that predicate forgets a session, the later CAS could recreate
its timestamp after all local fields had been removed.

The refresh now checks current protocol membership inside the same pure CAS.
Present sessions retain the original refresh; removed sessions retain the current
state. Cohort iteration, inactive/grace policy, lifecycle forget and persistence
remain. This adds a map-membership lookup and possible retry work; no latency or
runtime memory improvement was measured.

The decoder invariant is documented: valid rows add version/activity/start
together, so an empty version patch has no publishable rows. The decoded count
remains diagnostic. Private activity-helper callers establish protocol presence
inside their CAS. These comments do not add new runtime gates.

Only the changed interface and implementation are parsed. Existing actual
persistence/resource scenarios remain unexecuted; no private introspection,
helper/count/UI test is added for this internal cleanup. No type/build/CI/runtime,
reviewer acceptance or merge is established. All six original goal axes and actual
Before/After cohorts remain open.
