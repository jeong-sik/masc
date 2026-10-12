# Persisted input fixture contract correction

Original #42586 head8c50db3d571bcaf4fc256dfc1ce43c5ccd449d72 remains SOURCE HOLD.
Production correctly no longer treats persistence as execution, but a later
branch in the same registered fixture still expected zero pending requests
from a loaded persisted row plus a queued-only replacement log. No sibling or
settled Run_started exists in that branch.

Replace that stale display/zero-pending oracle with a typed pending-request
check: exact original request remains Rechecking_delivery. No new wording,
layout or row-order assertion is introduced. Existing earlier real Run_started
still expects retirement; original source HOLD retained for exact-head history.

The actual production-function bounded probe from #42586 already measures this
rechecking decision with explicit state/accessor doubles and passes on current
production. This correction changes only the unexecuted registered fixture;
syntax-only parse and diff check pass. No fixture/full typecheck/build/CI,
provider/runtime/UI/installation/formal approval/merge evidence. Composite
independent rereview required; full goal remains active.
