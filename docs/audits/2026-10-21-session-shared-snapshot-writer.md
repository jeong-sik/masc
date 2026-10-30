# Shared session snapshot writer

Review #44449 / 5589466848 identifies a second temporary-file replacement
implementation and snapshot-specific names outside the canonical orphan grammar.
Use the existing `Atomic_replace` rename-only core through `Fs_compat`.

| Boundary | Before | After |
| --- | --- | --- |
| Session output | Local create/write/close/rename/cleanup | Shared replacement core |
| Temporary names | Snapshot basename plus random suffix | Canonical `.atomic_*.tmp` |
| Failure transport | Local exception/backtrace | Staged common-core exception/backtrace, re-raised at the session boundary |

A thin staged rename-only API retains the common core's original exception and
backtrace. The existing string-returning API delegates to that staged path and
retains its public behavior. Session persistence still handles expected system/
Unix host errors as `Save_failed`, propagates cancellation and unexpected errors,
and awaits the existing worker/mutex boundary. Shared-core error classes, including
`Sys.rename` errors, are preserved as emitted by that core. No new fsync or worker
hop is added inside the existing host job.

Input/destination kind and descriptor checks, refusal/token policy, serializer,
coherent registry capture and restore remain. Symlink snapshot leaves are explicitly
refused and preserved under the prior file-boundary change. Canonical naming makes
leftovers recognizable to the existing orphan machinery; this does not install a
new sweep or prove crash recovery. Shared-core temporary creation and reopen
behavior is inherited; external directory mutation remains outside its ownership
contract. The shared writer's cost remains, including payload string construction.

One new, unexecuted actual resource case attempts publication over an occupied
directory, checks retained contents/unowned FIFO/no owned residue, releases the
destination and checks exact binary bytes on retry. Fifteen existing session cases
remain. Direct `masc.fs_compat` test linkage is declared. Only changed OCaml parsing
is checked; no types/build/tests/CI/runtime/paint/latency/approval/merge is claimed.
The review request remains open until its reviewer accepts the follow-up. All six
original goal axes and matched failed/cancelled/unfinished measurements remain open.
