# Native Ego navigation lifetime

Ordinary `page.goto`, `page.reload`, and the `task.newPage` + `page.goto`
sequence used a second MASC execution clock (45 seconds for goto; 60 seconds
for the action paths). The same goto inside a native workflow already used
SDK-owned settlement. Source review found no separate resource contract for
these extra clocks. This is an identified contract inconsistency, not a claim
of a reproduced production navigation outage.

These three peer paths now use the existing native runner and the authenticated
Ego transport selects `Executor_owned`. The private Add-on client observes the
exact live transport in its original worker's validated Snapshot before choosing
Ego-specific waiting. A live UUID alone is insufficient; unknown differing-policy
calls refuse before writing, and other transports retain shared reply windows.
Only the latest snapshot can replace metadata; stale replies cannot undo a newer
failure or revocation. The worker independently validates its admitted actual
transport. Existing running-request ownership,
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

## Focused CI

[40107798441](https://github.com/jeong-sik/masc/actions/runs/40107798441)
passed for `a96d1a9d1f428b8d4832f8a65ad00c2e44086c09`: peer 31, watched work 8,
live Ego integration 11 (50 tests). [selected-ci.json](selected-ci.json) records
the exact scope and downloaded log digest. This is not full regression or the
macOS candidate's real browser execution.

## Exact candidate and real Keeper

MacOS build [40107800194](https://github.com/jeong-sik/masc/actions/runs/40107800194)
succeeded for `a96d1a9d1f428b8d4832f8a65ad00c2e44086c09`. All downloaded binary
hashes and embedded source were checked before the isolated server started.
Full health verified executable hash/path and the separate effective root.
The running server/worker paths and hashes, actual provider run metadata, raw
tool records and public final response are retained in
[keeper-a96d1a9d](keeper-a96d1a9d/).

The new candidate's real Keeper used ordinary BrowserGoto, ordinary BrowserAct
reload, then native snapshot on the same25/p1. All three calls succeeded on
the same observed client/tab and its operation is Succeeded. No workflow
substitution or new page was used. Existing server-side EGO-001 remained the
only submission; the fresh form screenshot proves the navigation/read result,
not another completed form submission. The root reviewer captured and visually
inspected that screenshot after the Keeper operation finished.

Both Keepers were stopped before cleanup. Explicitly detaching the new browser
Add-on reported native_released, exited its worker/SDK and finished space25;
a subsequent listTaskSpaces showed25 absent. Both private servers and two
owned fixtures were then stopped. The old idle14c9 SDK remained after its
server's SIGTERM; its recorded executable path/hash were reverified and that
owned PID alone was terminated. All eight recorded server/worker/SDK/fixture
PIDs were absent in the final census. At those candidate sources this documented
a generic server-signal cleanup limitation. The later [owner-disconnect
repair](../ego-sdk-owner-disconnect/) now has separate compiled34c and12c cleanup
evidence; it does not rewrite that earlier failure. The a96 candidate's explicit
detach path completed. No production installation or restart occurred.
