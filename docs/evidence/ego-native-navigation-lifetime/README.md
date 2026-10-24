# Native Ego navigation lifetime

Ordinary `page.goto`, `page.reload`, and the `task.newPage` + `page.goto`
sequence used a second MASC execution clock (45 seconds for goto; 60 seconds
for the action paths). The same goto inside a native workflow already used
SDK-owned settlement. Source review found no separate resource contract for
these extra clocks. This is an identified contract inconsistency, not a claim
of a reproduced production navigation outage.

These three peer paths now use the existing native runner and the authenticated
Ego transport selects `Executor_owned`. The outer Add-on client uses that same
closed policy and delegates to the worker, which still selects other-browser
policies from its actual transport. Existing running-request ownership,
settlement, cancellation and explicit disconnect apply without a new lifetime
mechanism. Generated Page scripts and partial-effect/created-tab receipts are
unchanged. An uncertain new-page result still requires tab observation before
another create.

The effect fixture verifies native-runner dispatch for all three paths while
retaining failed navigation, created-tab partial failure and no-replay cases.
The actual lane component's eight cases pass with all three transports checked
for the new policy and back remaining an adapter with its existing policy.
Peer and test source parse; diff-check passes. Full peer/host execution of this
layer remains separate from that component check.

This does not convert every broker command to an unbounded native call. Back
and forward use a CDP history adapter because the documented SDK has no such
Page methods. Bootstrap identity, lifecycle acknowledgments, file-lease cleanup,
and custom observation/scene reads retain their existing protocol boundaries.
This audit does not establish that every remaining fixed protocol window is
necessary. It establishes native navigation parity with native workflow waits.

The running Keeper candidate from the preceding layer is source
`14c9f0c701768ed3242e3fcde219b3dfaf9a80ce`; it predates this navigation change.
Its evidence must not be presented as execution of this layer.
