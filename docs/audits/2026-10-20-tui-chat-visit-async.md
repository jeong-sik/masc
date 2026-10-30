# Conversation visits without foreground config commits

Related PR: [#44199](https://github.com/jeong-sik/masc/pull/44199).

Source change only. Original comparison parent before restack:
`fe1477b330c30e33207b981f66ae94da63af860e`.
Current direct parent: `17d3c616010eb02955fd5bddfe788a83302bb13f`.
No typing, test execution, TUI/PTY, installed binary, runtime latency or actual
Before/After was verified. Parsing is not typechecking or behavioral evidence.

## As-Is / To-Be

`open_message_for_keeper` called `Masc_tui_config.record_chat_visit` before
assigning `msg_live`, restoring the target draft and draining queued input. That
call takes Runtime's shared runtime.toml lock, loads and edits current text,
validates and commits it. The callback could not finish those UI changes until
the config operation returned. This is a source ordering finding, not a measured
production stall. Text draft save/restore itself uses the in-memory draft list.

Explicit visits now submit an immutable base path and typed Keeper name to one
session FIFO writer. The ordinary TUI startup installs the shared domain pool;
the writer submits each existing config operation there and waits in its own
Eio fiber. The UI continues restoring its target draft. Every admitted visit is
kept in order; visits are not collapsed, capped, retried or replayed. Each effect
still uses `record_chat_visit`, which reads fresh text under Runtime's shared
lock. In particular, the startup mode is read at commit time: an intervening
Overview/Keeper choice is preserved, while Last updates its opening target.

Home initially records a pending save. Only the exact latest request and base
path can replace it with a durable, durability-unconfirmed, session-only or
outcome-unknown receipt. Opaque request identity distinguishes A→B→A. Failure
events retain the original Keeper even when its Home owner was superseded.
Unexpected exceptions and interrupted active saves are outcome-unknown, rather
than a claim that no write happened. A missing switch retains a not-started
outcome and performs no fallback write. The existing shared pool helper retains
its absent-pool/worker-context behavior; this unit does not change that helper.

Completions stay with the writer rather than using the bounded shared mailbox.
The existing UI drain applies a finite prefix and checks its existing deadline
and pending input between receipts. No additional timer or polling loop is
introduced. Normal main-loop exit closes admission and awaits accepted writes
before Break can cancel the UI switch, then collects the remaining receipts.
This is conditional on config operations settling, not a bounded shutdown
promise. A lock or storage operation that never settles leaves `close` waiting
in `Closing` and prevents normal exit. Its protected wait defers caller
cancellation; it does not interrupt or time out the writer. No successful or
unknown outcome is fabricated merely because exit was requested. Cancellation
that actually reaches the writer retains an unknown active outcome and
not-started queued outcomes after the accepted submission's real settlement,
which a blocked/protected physical effect can also delay. It then propagates;
effects are never replayed. Launch checks the switch because
Eio fork can otherwise skip its callback on an already cancelled switch.

## Source Before/After

| Boundary | Before | After |
| --- | --- | --- |
| Ordinary explicit open callback awaits config commit | 1 | 0 with the normal initialized TUI pool |
| Config operations per accepted explicit visit | 1 | 1, same validation/lock/durability contract |
| Text draft storage | Session memory | Session memory |
| Home before save completes | Callback has not returned | Latest visit has a pending receipt |
| A→B→A, late first-A result | No overlapping UI save receipts | First A cannot settle the latest A request |
| Other editor changes startup mode | Shared current-text edit | Same shared current-text edit in the worker |
| Normal exit | Visits already committed on the key path | Exit waits for the accepted FIFO, without mailbox capacity dependency |
| Config I/O never settles | Foreground key path can stay blocked | Foreground visit is separate; graceful close stays unfinished in Closing |
| Ambiguous interrupted commit | Synchronous call has no separate receipt owner | Unknown outcome retained for the original request; no replay |

The cost moves to a session worker and two queues. Outstanding requests/results
consume memory until saved/applied; normal exit can wait for the existing config
lock and storage. No durable intent journal is added: abrupt process death can
lose queued visits and their session-only observations. The one writer preserves
same-file ordering; other files/workers keep their existing resource policy.
There is no measured latency, allocation, paint, input or speedup result.

## Authored protocol scenario, unexecuted

The existing real config-write scenario now also creates the actual shared pool
and writer, admits A→B→A, edits startup mode and theme through Runtime's real
shared lock between admissions, and closes the writer before consuming receipts.
It checks original FIFO request identities, retained config choices, final disk
target and rejection of older same-name Home receipts. A missing-switch request
then retains a session-only target while the file keeps its prior saved target.
The fixture sets UI receipt ownership directly; it does not execute the main
open callback, render loop or an actual second TUI process. It does not force
lock contention, cancellation, ambiguous storage failure or physical cleanup.
No layout, wording, row-order, snapshot, PTY, helper-mirror or invocation-count
test is added. The scenario is authored, not run or typechecked.

The review's blocked-I/O case is an explicit guarantee exception:
[review-5583869271](https://github.com/jeong-sik/masc/pull/44199#pullrequestreview-5583869271).
An unexecuted resource case must hold the real config lock, admit original
A→B→A visits, start close, retain the unfinished close and actual pending
owners while the lock remains held, then release the lock and observe the real
FIFO outcomes. Cancelling a caller or writer must not be described as physical
settlement until that boundary actually returns. No arbitrary timeout or helper
test replaces the resource's real return. This clarification changes no runtime
behavior and does not claim the indefinitely blocked case has been solved.

The current Runtime path is `edit_config_text` →
`with_runtime_config_write_lock` → `File_lock_eio.with_durable_lock_observed`
→ `acquire_durable_flock`. Its Eio admission uses an unbounded cancellable
`F_TLOCK`/yield loop; its non-Eio path uses blocking `F_LOCK`. The separate
`acquire_flock_retry*` helpers raise `Flock_timeout`, but this durable path does
not call them. Their attempt limit cannot establish a shutdown bound here.
This source fact also applies to a pending close behind the original config
lock; no additional timeout is introduced to obscure the actual resource.

A latest-request token alone would not preserve every admitted visit's config
effect or superseded failure receipts. Independent forks still need ordering
because the shared file lock does not promise request FIFO. A serial promise
chain is another possible representation, but would still need original request
ownership, shutdown joining and retained results. These are source-level
semantic comparisons, not measured superiority of this queue implementation.
No latency or allocation comparison was executed; its queue and lifecycle costs
remain in the future matched cohort. The session-only persistence loss on
abnormal process termination is also recorded in the changelog.

Actual matched Before/After must retain failed, cancelled, interrupted and
unfinished visits, exact input/workspace/request owners and storage/queue costs.
Pending or saved config is not proof of usable input, painted output, useful
Task work or physical worker quiescence. All six original goal axes remain open.
