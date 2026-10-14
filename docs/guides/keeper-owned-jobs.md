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
durable artifact references in stdout, stderr order. Unavailable output remains
explicit and can be collected later without running the program again. The
backend spools both actual `docker logs` pipes and requires authoritative EOF
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

Canonical owner journals live beneath
`<base-path>/.masc/keeper_msg_requests/owned_jobs`. Writable program and CLI
data live beneath `<base-path>/.masc/owned_job_data`, outside blob-maintenance
authority sources. A program's output files or symlinks therefore cannot become
durable GC ownership evidence. Input and terminal-output references stay in the
canonical owner journal.

`keeper_job_result` reads the same job's owner journal without contacting the
backend. It is read-only and permits concurrent admission. It returns Deferred
until a confirmed exit has both complete stdout/stderr artifacts, or until a
before-start cancellation is committed. A nonzero program exit remains an
observed result with its exact exit code; consumers decide how to handle it.
An unavailable or corrupt owner journal is a refusal, not a pending result.

Use this result read as a leaf of a prepared async Composition. Its dependent
nodes wait while independent branches may complete. After the completion
notification or `keeper_job_status` confirms complete outputs, pass the same draft sha256 and original
`composition_run_id` as `resume_run_id` to `keeper_composition_run`. The previous
worker must have canonically settled before another worker owns that run.
When a prepared async attempt has only producer-owned job waits, its status is
`waiting_for_dependencies`, with tagged `dependencies` and the execution artifact.
Owned job entries have `{kind:"owned_job",job_id}`; named Composition result
entries have `{kind:"composition_result",binding}`.
The worker has released its scope; the prepared run is still waiting. This
does not emit a failed composition notification. The original job completion
notification supplies the result; resumption remains explicit as above.
Other failures and unsupported deferrals retain their failure behavior.
Resuming a waiting run captures its exact previous worker and saved node
results before admission. A competing resume that advances the owner makes
that captured candidate stale, including when the competing worker has already
finished. One job may supply several waiting nodes; each keeps its own occurrence
identity while the waiting job IDs form a set. These reads and admission do not
automatically start a continuation on job completion.
Each prepared worker admission records a separate pending discovery marker
before it can own the journal or execute a node. Recovery reads this pending
partition and the exact original journal, request and job records; it can find
a ready result without another completion event. A marker grants no execution
permission. Completed attempts and superseded markers retire after canonical
terminal proof bound to the exact marker inode, end offset and bytes under
its retained stable sibling lock. Publishing and retirement share that lock;
a physical replacement or same-inode content change during proof reads is
refused and retained. This is the owned-directory transaction protocol, not an
atomic POSIX compare-unlink against a writer bypassing its lock.
Unavailable original authority remains reported and retained. Discovery
excludes retained lock siblings from pending marker counts; a lock whose
marker data file was already retired is skipped by an existence-only check
and is never re-acquired or validated, so each pass stays proportional to
live markers. It does not scan historical terminal records. Corrupt, unbound
or refused markers stay visible as named discovery failures; an operator
confirms the canonical request record and then removes the named file from
the prepared_continuations directory. This discovery boundary returns sealed candidates; the
maintenance supervisor schedules separate intake fibers for ready original runs.

The explicit typed continuation intake can submit the original prepared worker
without a provider turn. A sealed continuation loads only its original
workspace and draft, recompiles its original recipe
against current admission and checks every frozen node route/input/output
contract. It reads strict result readiness before accepting a worker; a
not-ready candidate defers without a worker or backend operation. An unrelated whole-surface change does not replace the original
preparation evidence or block unchanged admitted nodes. Current denial or
schema drift still refuses before acceptance. Ordinary draft loads and Skill
publication retain their exact whole-surface check. Async acceptance pins the
original owner/generation/full node snapshot; Task, run, parent, waiting
occurrences and completed siblings remain original. Server startup and the existing maintenance pulse use this intake directly.
An already-durable owned-job completion also hints the supervisor immediately.
Current declarations, metadata and the published Skill snapshot are resolved for
each intake. The declaration snapshot refuses filename/name mismatches and
duplicate owner claims. A paused Keeper, unavailable authority or changed
admission retains the wait.
Separate runs have independent intake fibers; the reservation set does not
authorize execution. A missing hint is recovered by the existing maintenance
pulse, with no new timer or retry limit.
The completion-hint feature scenario starts the job and prepared DAG through
public handlers, observes its canonical wait, changes the current Task, then
lets the owned-job maintenance worker collect full output and enqueue its
notification. Only that durable completion observer pulses the continuation
supervisor. Its receipt separates backend work needed to finish the original
job from backend calls after result readiness, and times completion pulse to
original DAG completion. The independent-job scenario also raises an observer
exception while another backend stays blocked, then waits for the new result's
durable ACK. These are synthetic CLI scenarios; execution and timing claims
require the selected run's completed artifact.
An additional prepared-launch scenario places `keeper_job_start` inside the
same async DAG and binds its typed `/job_id` output into the result read. Prepare
performs no backend operation. The actual serial launch owns the original node
occurrence and Task; the completed launch is reused after the wait instead of
dispatching again. The receipt separately records public prepare/run to the
saved job wait and completion pulse to original DAG completion. Status and
cancel remain direct effects. These component intervals do not measure model
preparation or whole-task improvement.
If a resumed request durably owns the journal but its worker is canonically
`Lost`, recovery follows the journal's exact predecessor bindings to the
original `waiting_for_dependencies` record. Its saved node snapshot must match
that original job set. Completed nodes are retained; unfinished nodes must
prove read-only replay. Repeated Lost successors retain this lineage. The
sealed candidate pins the current terminal entry, full node snapshot and each
canonical predecessor used as proof; a changed predecessor refuses readiness
and admission. Cancellation and unknown effects do not grant continuation, and
an empty process registry never proves loss. This recovers the original result
read without another program create/start. The maintenance supervisor consumes
this proof through the same intake. No real process-restart measurement is
established by the authored fixture's process-memory resets.
Worker-fork failure and exclusive startup recovery preserve a durable
`Cancelling` intent as exact `Cancelled`, including its original reason and
actor. If signalling the live worker fails and it returns Done or an original
job wait, settlement still preserves that exact cancellation intent as
`Cancelled` (cancellation intent wins; completed node outputs produced before
the worker returned remain recorded in the execution journal). Persistence
failure remains explicit. These boundaries cannot restore continuation permission.
The journal retains the exact producer-owned job wait separately from the
provider-facing body. Only this exact read-only leaf may be rechecked; it keeps
its original execution ID and tool-use ID. Completed siblings reuse their full
saved results, while dependents consume the original job's complete outputs.
Ordinary Deferred, unknown effects and launch/status/cancel calls receive no
retry authorization from this receipt. A direct pending result read lets the
Keeper continue other work while the original job remains pending.

The server reconciles pending jobs on startup and its existing maintenance
pulse. Each job has its own lifecycle fiber; a blocked backend does not hold
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
visible; independent sources can continue. These notifications let the Keeper
resume an original Composition explicitly; they do not start another worker
automatically.

Start, status and cancel use serial admission and return while the isolated
program runs. Shared mutable workspace claims, remote Docker bind authority
and effectful draft admission remain separate contracts. This result-read continuation does not
automatically resume a plan when a container exits. Those remaining contracts are tracked in
[issue #42799](https://github.com/jeong-sik/masc/issues/42799).

Terminal jobs do not clean up automatically yet. A finished or cancelled job
keeps its stopped Docker container, its captured log evidence, its private
workspace and CLI directory under `<base-path>/.masc/owned_job_data`, and its
owner journal under `<base-path>/.masc/keeper_msg_requests/owned_jobs`.
Durable output artifacts stay in the blob store while the owner journal
references them. To reclaim disk once a job is terminal (`exited` or
`cancelled`) and its outputs are collected, an operator removes the exact
saved container (`docker container rm` on the result's `container_id`, or
`docker container ls --all --filter label=masc.mcp.owned_job=<job_id>` when
the id is unknown) and then deletes that job's directories under
`owned_job_data`. Keep the owner journal while its artifact references must
stay discoverable. Automated cleanup and retention are tracked in
[issue #42799](https://github.com/jeong-sik/masc/issues/42799).


### Waiting for an already submitted named async Composition

The named submission returns `result_wait`, bound to its exact accepted request,
run, Skill revision, original invocation, source turn and explicitly present or
absent Task. Pass it unchanged as `binding` to `keeper_composition_result`. This
read verifies durable producer membership as well as the canonical request source.
A generic worker that copied the context has no named-run membership.

Pending reads return a typed dependency. An enclosing prepared async DAG releases
its worker, retains completed independent nodes, and rechecks the same occurrences
after canonical completion. The result includes the full original structured
`result` and `result_artifact`; connect the statically declared
`/result_artifact/_blob/sha256` to `keeper_artifact_read` to consume its complete
manifest. A generic reader does not declare every child-specific export name.
Failure stays failed and retains canonical diagnostics, partial outputs and
artifact references. A missing or changed original source refuses the read.

This is explicit submit-then-read composition. Exact async Skill child nodes in
`keeper_composition_prepare` still require compiler support; their syntax is not
admitted by this layer. A binding identifies one accepted named request, not a
logical chain of suspended child successors. The current request codec is v5
and the prepared journal codec is v2; unknown versions are refused.

`test_keeper_owned_jobs` exercises the actual named Tool, holds its synthetic CLI
inspection, prepares a waiting parent with independent work, and resumes in a new
turn. Success reads the original full result artifact and stdout; child transport
failure keeps its diagnostic. Both scenarios reject changed bindings and a copied
generic request, preserve occurrence IDs, and measure zero extra child backend
calls during parent resume. Authored scenarios are not execution evidence until
the selected head's run completes, and their component intervals do not measure
whole-task preparation improvement or installed runtime/UI behavior.
