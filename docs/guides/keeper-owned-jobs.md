# Isolated jobs across Keeper turns

Use `keeper_job_start` for a program that can operate on immutable input
artifacts in its own Docker workspace. The command is structured argv; it has
no shell interpretation unless argv explicitly names a shell. The backend uses
the Keeper's resolved Docker image and hardening configuration.

```json
{"argv":["sh","-c","printf 'job result\\n'"]}
```

The result names a durable `job_id`, its phase and the original source task,
turn and tool invocation when that context is available. Use that exact handle:

```json
{"job_id":"the exact job_id returned by start"}
```

Pass it to `keeper_job_status` to reconcile the saved backend or to
`keeper_job_cancel` to persist a cancellation request. Cancellation and a
confirmed exit are separate facts. Available terminal logs are published as
durable artifact references in stdout, stderr order. A temporary log-collection
failure can be retried under the same handle without running the program again.
Confirmed loss of the original backend before output collection records a settled
result with explicitly unavailable output. The backend spools both actual
`docker logs` pipes and requires authoritative EOF
before publishing their complete files. Bounded process previews never become
complete output. These artifacts preserve the bytes delivered by the backend;
Docker's configured log retention determines which program bytes remain
available before collection.

Optional `inputs` is an array of `{ "path": "input.txt", "artifact": ... }`,
where `artifact` is the exact normalized `Tool_output` reference returned by a
producer. Each path is one distinct file name. The store verifies the checksum
and byte count before copying its bytes into the private workspace. It never
mounts the Keeper's current workspace, credentials or identity. The job has no
network access and a read-only image filesystem. Image-declared writable volumes
are inventoried and replaced by recorded job-private tmpfs mounts.

Create and start intentions are committed before their corresponding backend
calls. An unconfirmed create/start keeps that intention and the same handle.
When the original trace, turn and tool invocation are available, the producer
also commits that invocation's job binding before preparing its workspace.
Re-entering that exact invocation reconciles the original job; it does not
resolve a fresh image or create a replacement. Different arguments or source
task metadata cannot overwrite the binding. A caller with a new tool-use ID
is a new invocation, so repeating a command is not lost-reply recovery.
The typed source lookup can recover a reserved handle even when its job journal
is not available yet. That absence remains unconfirmed and never permits a
replacement. Calls without complete invocation identity retain an explicit
job handle but cannot use this source lookup.
Status inspects the saved daemon, image, command, labels and private mount
authority. An absent container, empty local process registry or transport error
does not authorize another create/start. A confirmed created container whose
start was never requested can advance through a new durable start intention.
Once start was requested, reconciliation observes that same job and does not
retry start. Directory identity, owner and permissions are rechecked before
backend operations; unreadable or replaced authority is a refusal.

## Recovery while the original container is absent

The maintenance supervisor retains process-local typed evidence only after a
full reconciliation holds an original job with `Backend_absent`. Each later
round first recovers the authoritative journal. If the entire original record
is unchanged, it checks the original private-directory/empty-CLI authority and
exact label inventory as a presence hint. No matching container leaves the
original job held; it does not append a phase, publish a result or authorize
another create/start.

A visible container goes through full daemon, ownership and isolation checks
before reconciliation can advance. A changed journal, including cancellation,
bypasses the hint. A failed hint clears reusable evidence, and a new supervisor
starts with full inspection. Late original containers therefore remain
discoverable without repeated daemon probes for unchanged absent jobs. Private
CLI authority is never borrowed from another job. Manual status and structured
one-round recovery keep their full-inspection behavior.

The hint skips the daemon identity check. A changed daemon with an empty
inventory therefore stays `Backend_absent` in maintenance, where full inspection
holds `Backend_unconfirmed`; a seen container and `keeper_job_status` still run
full reconciliation.

| Boundary | Before | After |
|---|---|---|
| Unchanged previously absent owner | Daemon identity plus exact inventory every round | One exact inventory hint, retaining the held owner |
| Container appears | Full inspection | Presence hint followed by full inspection |
| Owner changes or supervisor restarts | Full inspection | Full inspection |
| Hint fails | No separate hint | Explicit held failure; reusable evidence cleared |

The unchanged-absence path removes one backend CLI call per job per round. A
positive hint adds an inventory call before full inspection. This is a source
path comparison until the actual maintenance feature scenario executes, not a
real Docker or end-to-end task speedup. The scenario retains the original
uncertain create, repeated absence, fresh supervisor, changed private CLI,
foreign daemon, late original result and changed cancellation intent.

The existing Keeper debug logger emits `owned_job_recovery` with the original
job ID and typed observation (`presence_not_seen`,
`presence_seen_full_inspection` or `presence_unavailable`). These describe
recovery work, not program completion. No polling timer, expiration or retry
limit is introduced.

### Share a backend inventory within one maintenance pulse

Unchanged held owners in the same maintenance pulse now share an in-flight
inventory when their frozen base path, complete CLI command, endpoint, daemon,
context, process owner and required rootless/user-namespace boundaries agree.
The read uses a newly created empty private CLI directory outside every job
workspace. It does not borrow any job's CLI directory or host credentials.
That exact empty directory is released after the read; unexpected contents or
a changed identity are retained and reported, never recursively removed.
Inventory decoding uses the full owned stdout capture after observed pipe EOF,
not the process runner's bounded head/tail preview. Both stream captures must
be complete. Validated complete files are removed with their read scope;
incomplete or changed files remain diagnostic evidence and cannot imply absence.

Each worker still recovers its own original owner and validates its own frozen
directories and empty CLI before using the shared read, then checks them again
afterwards. JSON projects individual owner labels with Docker's documented
[`container ls` formatting](https://docs.docker.com/reference/cli/docker/container/ls/#format-the-output---format);
comma-separated label prose does not establish ownership. Every returned row
must match the workspace/component/kind, and each hint matches the exact Keeper
and job. The inventory is still only a reactivation hint: positive visibility
uses that job's full original daemon/container/isolation inspection before any
phase change or effect. Missing visibility cannot complete, clean up or relaunch
the job.

| Cohort | As-Is at #43444 | To-Be source path |
| --- | --- | --- |
| Two unchanged held owners, same frozen route | Two presence CLI reads | One shared read; both original owners remain held |
| Two different frozen endpoints | Two presence reads | Two separate reads |
| One private CLI changes | That owner's hint fails | That owner's hint fails; another valid owner can still read |
| Shared response or transport fails | Each hint fails separately | One failed read is shared; each owner clears its reusable hint and next uses full recovery |
| Late original container appears | Per-job hint followed by full inspection | Shared hint followed by the same per-job full inspection |
| Fresh owner, changed intent or new supervisor | Full inspection | Full inspection, independent of the shared hint |

For an uncancelled read round, `N` eligible held jobs across `B` exact frozen
routes require `B` presence CLI calls rather than `N`. Private filesystem checks
still happen per owner. The shared scope is discarded after the pulse's workers
settle and is never reused on a later pulse. A cancelled fetch releases its
private scope and can restart for a remaining waiter; cancellation is not an
absence observation. No backend wait is added to the caller of `pulse`.

The source comparison baseline is #43444 at
`9bce155523dfd2fb2ea3370a2cc7e8772a5a965c`. Authored public-handler/maintenance
scenarios cover one versus two frozen routes, original owner bytes, fresh
private CLI use/release, foreign projected scope, transport failure, a changed
job CLI, late original start and durable result delivery. Their transport is
synthetic. The visible target is surrounded by enough rows to exceed the process
preview head/tail limits and require full-output coverage. These scenarios are
not executed in this unit: parser checks do not prove types,
single-flight execution, real Docker latency or end-to-end Keeper speedup.

## Result and reconciliation

Job replies separate the original `phase`, `result_ready`, and `reconciliation`.
`result_ready` marks a settled result, including cancellation and explicitly
unavailable outputs. The `status`, phase and artifact references describe that
outcome. A stored projection without a phase reconciliation reports
`reconciliation.state = "not_observed"`.

| Reconciliation | Meaning |
|---|---|
| `confirmed` | This action settled or retained the canonical phase. Check `result_ready` for the result. |
| `held` / `backend_absent` | The original backend is absent and the launch remains unresolved. Inspect the same handle or explicitly cancel it. |
| `held` / `backend_unconfirmed`, `backend_error` | Read `detail`. While `result_ready` is false, keep dependent work waiting; after the reported backend problem is resolved, reconcile the same handle with `keeper_job_status`. |
| `held` / `backend_mismatch` | The observation differs from the original phase or handle. Inspect `detail` and resolve the mismatch before reconciling this same job again. Preserve its original intent. |
| `held` / `cancelled_job_orphan` | A later resource was observed after cancellation. The original cancellation result remains settled. |

A held job without a settled result reports `status = "unconfirmed"`, including
a saved `created` phase whose container is now absent. Its phase and exact
handle remain intact. These observations accompany the current reply; they add
no journal fields or authority to repeat create/start.

Canonical owner journals live beneath
`<base-path>/.masc/keeper_msg_requests/owned_jobs`. Writable program and CLI
data live beneath `<base-path>/.masc/owned_job_data`, outside blob-maintenance
authority sources. A program's output files or symlinks therefore cannot become
durable GC ownership evidence. Input and terminal-output references stay in the
canonical owner journal.

### Terminal resource cleanup

Completion delivery and cleanup are separate maintenance rounds. Full terminal
output is durable before delivery; delivery commits its original notification
and owner acknowledgement without waiting for cleanup I/O. The pending discovery
marker stays until a later maintenance fiber confirms resource removal. Failed
or interrupted cleanup stays discoverable without scanning historical owners or
repeating the program. Independent jobs keep independent fibers.

The same canonical owner records an ordered cleanup lifecycle:
`resources_retained` → `container_removal_requested` → `container_removed` →
`data_removal_requested` → `resources_removed`. Each intent is committed before
its effect. Only a complete terminal result with an acknowledged delivery can
advance. Execution phase, exact handle, source and output references remain.
`keeper_job_status` exposes this cleanup stage; `keeper_job_result` and terminal
status continue reading the original result after the resources disappear.

Container cleanup uses the saved daemon and complete ownership/isolation
contract. Only the exact saved Created/Stopped container may be removed, without
force. Running resources, changed terminal phase/exit code, copied labels,
changed daemon/mounts and uncertain
observations refuse. Confirming a saved ID's absence also inventories that full
ID independently of owner labels. A lost successful remove receipt is recovered
by confirming original absence, without another removal or create/start.
Cancellation before start can clean its exact created container; an owner that
never acquired a container can only confirm absence.

After confirmed container removal, data cleanup deletes the original private
workspace, CLI directory and log captures. It binds the frozen root and retained
parent device/inode/owner/permissions through no-follow descriptors. Links and
other non-directory entries are unlinked, never traversed; another filesystem
or foreign-owned directory refuses traversal. Partial removal can resume under
the same original target identity, or confirm target absence under unchanged
parents. A replacement tree or root symlink refuses. This ownership transaction
requires the writer to have stopped; POSIX does not provide atomic conditional
unlink against an unrelated host writer bypassing ownership. Inaccessible data
or failed fsync remains an explicit pending cleanup failure.

Canonical owner and invocation journals remain retained as source, deduplication
and blob-GC authority. Their input and complete output references stay live after
private data removal. There is no journal TTL, automatic authority deletion or
new cleanup timer. The existing maintenance pulse recovers the pending marker
until resource cleanup is confirmed, then retires discovery.

The owner journal codec is v2. Finish pending v1 work on its original runtime and
use a fresh base for this candidate; no conversion or deletion is performed.
Synthetic CLI feature scenarios check real public launch/result/status and
maintenance, persisted removal intent, exact resource refusals, lost removal
receipt, partial data cleanup/replacement, before-start cancellation, retained
full output and GC roots. These scenarios are not real Docker, physical process
restart, installed runtime or whole-task preparation speedup evidence.

`keeper_job_result` reads the same job's owner journal without contacting the
backend. It is read-only and permits concurrent admission. It returns Deferred
until a settled result is committed: a confirmed exit with complete or explicitly
unavailable outputs, a committed before-start or unconfirmed-launch cancellation,
or confirmed output loss after launch. Replies carry `result_ready` and
`reconciliation` from stored evidence; this read does not refresh the backend.
Use `keeper_job_status` on the same handle when a backend check is needed.
Readiness alone promises neither success nor available output. A nonzero program
exit remains an observed result with its exact exit code; consumers decide how
to handle it.
An unavailable or corrupt owner journal is a refusal, not a pending result.

A pending result read does not hold the turn: the Keeper can continue other
work while the original job runs.

The server reconciles pending jobs on startup and its existing maintenance
pulse. Each validated pending marker can reserve its own lifecycle fiber before
later marker bodies are read. The private directory-name listing still completes
first; this removes the later-marker read barrier, not directory enumeration.
A late discovery error can coexist with already-reserved workers. Their original
owner checks and switch cleanup remain in force, and automatic held hints are
pruned only after a complete successful scan. A marker grants no effect authority;
each worker recovers the exact original journal before reconciliation/delivery.
The report-only pending read and explicit round reconciliation still collect
their full selected scope. A blocked backend does not hold
the shared maintenance pulse or newly pending jobs. Separate original jobs
perform their recovery I/O concurrently. An
unconfirmed create/start is observed, never replayed. Complete results already
in the owner journal need no backend operation to recover delivery.

Each owner freezes the submission's continuation channel. Once complete output
or before-start cancellation is committed, a durable `Owned_job_completed`
notification carries the original job ID, source task/turn and channel to the
submitting Keeper. Its next prompt reads the exact canonical result and output
references. A missing channel is explicit `Unrouted`; it does not choose the
Keeper's current conversation. Stdout and stderr are normalized `_blob`
references in that order; `/artifacts/0/_blob/sha256` selects stdout for
`keeper_artifact_read`.

Pending discovery is committed before the owner and backend effects. Delivery
is acknowledged in that same owner only after durable queue enqueue, then its
discovery marker is retired. Failed enqueue, an interrupted acknowledgement or
unreadable authority leaves recovery evidence. Queue consumption before the
producer acknowledgement does not recreate the notification. Maintenance
validates the full committed prefix and exact job owner before recovering an
incomplete final append under the journal lock; complete
malformed rows remain a refusal, and missing owners are never created. If the canonical
result cannot be read at intake, the source stays pending and its error remains
visible; independent sources can continue.

Start, status and cancel use serial admission and return while the isolated
program runs. Shared mutable workspace claims and remote Docker bind authority
remain separate contracts.
