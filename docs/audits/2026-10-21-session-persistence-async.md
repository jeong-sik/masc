# Session persistence I/O and the owner readiness boundary

| Boundary | As-Is | To-Be |
| --- | --- | --- |
| Restore ordering | Background maintenance after owner publication/readiness | Shared HTTP/stdio owner activation awaits restore before publication/readiness |
| Persistence root | Cwd/process default inferred internally | Actual owner base path is mandatory at each persistence/reap entrypoint |
| Read/decode | Blocking file read and JSON parse in Eio caller | Common I/O executor returns immutable decoded entries; caller checks cancellation before applying |
| Save | Blocking capture/encode/write in caller; shared temporary filename | Blocking worker serializes before current-map capture through flush/close/rename |
| Restore failure | Missing/read/JSON faults silently ignored; invalid root ignored | Missing, unreadable, JSON failure, rejected root and applied entries observed separately |

The readiness gap is source-visible: HTTP publishes the owner state and marks
readiness before starting post-ready lanes; those lanes fork maintenance, which
previously performed session restore. Its interface instead requires restoration
before general MCP request admission. Merely forking or offloading the old call
would widen that gap. Restore now runs in shared owner activation after Gate
restore and before lazy-task/persistence activation returns. HTTP publishes
state/readiness afterwards; stdio also activates before its readiness commit.
The existing pre-ready health listener remains independent. No owner controller
or request-admission flow was executed to verify this source order.

Every persistence path now receives the actual owner's base path explicitly.
The reap caller uses its original config, and activation uses its original owner
state config. Public/re-exported signatures and direct tests are migrated; no
optional fallback, cwd inference or compatibility wrapper is retained for these
entrypoints. The general default-base helper remains for its independent uses.

Read/stat/JSON decode run in the common dual-mode I/O executor under a named
suspend label. Decode produces immutable entries without touching live registry
maps. The original protocol admission, optional profile/transport handling,
timestamp defaults, entry order and duplicate overwrite order are preserved.
Missing files restore nothing; expected read/JSON/root failures restore nothing
and retain a diagnostic rather than masquerading as an applied empty snapshot.
After the host operation returns, the caller checks cancellation before the
original per-entry atomic registry updates. Unexpected errors can still fail
activation before publication. Registry application itself remains caller work.

Writers acquire the process session-registry persistence mutex only inside the
blocking worker. They capture the current immutable maps after acquiring it,
then retain it through serialization, actual file flush/descriptor cleanup and
rename. An earlier queued snapshot cannot overwrite a later capture, and two
writers cannot clobber the shared temporary namespace. Outside Eio the same
blocking path runs directly. The original serialization and default values
remain. Rename provides the existing file replacement boundary; no fsync/crash
durability guarantee is added.

The installed Eio thread-pool interface states that a started system thread
does not respond to cancellation. Callers therefore still await real host work;
shutdown can wait on a blocked resource. A cancellation check after completion
does not undo an already replaced file. Cancellation observed before registry
application prevents that application; it cannot undo application already begun.
These boundaries are not physical force-stop, instantaneous
shutdown, whole-request success or visible TUI paint/input proof.

The existing non-Eio save/forget/load scenario now uses an explicit temporary
base without changing cwd and checks original profile affinity. Two new
unexecuted resource/protocol cases use actual FIFOs. Concurrent real saves must
allow an independent live session registration/profile check before releasing
the temporary FIFO; both writes must finish without temporary clobber and a fresh
load must retain both sessions. Another case connects the real restore reader,
withholds actual JSON bytes, cancels its scope and then releases the writer;
the joined cancelled restore must not publish initialize/profile authority,
while a fresh joined restore can consume the same snapshot. No replacement
reader/writer, helper/invocation count, UI wording/layout/snapshot or PTY test is
added. These cases do not exercise installed server readiness or actual TUI.

Before/After source quantity is two named host-I/O boundaries and one moved
startup restore call; it is not a runtime speedup. Costs include executor
dispatch, serialized writer wait, immutable decoded-entry allocation, actual
registry application and added result diagnostics. The startup caller still
waits for restore, and maintenance still waits for its write. No new timer, pool,
limit, runtime knob or detached worker is introduced. The test target adds its
direct core/Eio/thread/JSON dependencies; no build or test was run.

Verification is parsing only for changed implementation/interfaces and the
scenario, whitespace checking, direct-consumer inspection and preservation of
unrelated authority/transport code. No typing/warnings/link/build/test execution,
CI, controller/native/model/TUI run, installation/restart, independent approval
or merge is established. Main-domain availability, actual input/loading latency
and useful work remain unverified.

All six original axes remain open: original Ask/Task useful work, exact
preparation/frozen discovery, ordinary/nested/dynamic/effectful Composition
continuity, held-job/shared-backend reactivation, cold usable input/TUI
readability/visibility, and matched actual cohorts retaining failed/cancelled/
interrupted/not-started/unfinished attempts.
