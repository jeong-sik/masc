# Agent-session discovery outside the actor lock

| Boundary | As-Is | To-Be |
| --- | --- | --- |
| Host discovery | Existence/directory checks and `Sys.readdir` inside actor/direct state mutex | Common host executor before dispatch, outside state mutex |
| Worker output | State and queue construction mixed with file discovery | Immutable names only; original entry order and suffix matching |
| Existing live name | Replaced with an empty queue and reset activity/listening | Current session and queued notifications retained |
| New name | Owner constructs queue and session | Same owner construction, applied to current state |
| Failure/cancellation before dispatch | Filesystem failure could unwind actor processing | Caller observes failure; cancelled discovery dispatches no restore message |

Only missing agent-name presence is restored. Keeping existing state is an
intentional lifecycle correction: discovery now yields before dispatch, and must
not discard a real connection/notification accepted during that interval. Existing
sessions, rates and unrelated names survive. A repeated restore keeps its earlier
queues. The restored-count log now counts newly inserted names. This is agent-session presence, not MCP transport initialize authority.

The caller captures the original timestamp before discovery. Actual owner path,
missing/non-directory no-op, directory/symlink handling and `.json` name semantics
remain; entry contents/kinds are not newly interpreted. Ordinary host failures
propagate before dispatch instead of stopping the actor from a filesystem error.
Queue creation, mutable registry state, logging and promise resolution stay on the
owner. Existing mailbox shutdown/drain and direct fallback remain. Completion
cancellation is checked before dispatch; once accepted, cancellation does not
retract the message. Host I/O is not forcibly terminated by caller cancellation.

Source comparison moves three conditional host API sites out of the registry
mutex, without reducing their actual storage work. Added name-list allocation,
executor submission, cancellation checks and current-map membership tests remain
part of preparation. Owner application and mailbox queueing still take time.
No pool, cache, knob, timer, arbitrary limit or measured latency claim is added.

Four new unexecuted actual directory/session/notification cases cover direct and
actor paths, live/repeated queue continuity, original entry-name semantics,
missing/non-directory no-op and already-cancelled admission with fresh recovery.
Scheduling may finish discovery before concurrent registration; no deterministic
physical-overlap or old race reproduction is claimed. Only parsing is checked;
no type/build/test/CI/native/runtime/paint/input evidence is established. The
original six goal axes and matched failed/cancelled/unfinished cohorts remain open.
