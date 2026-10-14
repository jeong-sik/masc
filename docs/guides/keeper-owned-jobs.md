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
The journal retains the exact producer-owned job wait separately from the
provider-facing body. Only this exact read-only leaf may be rechecked; it keeps
its original execution ID and tool-use ID. Completed siblings reuse their full
saved results, while dependents consume the original job's complete outputs.
Ordinary Deferred, unknown effects and launch/status/cancel calls receive no
retry authorization from this receipt. A direct pending result read lets the
Keeper continue other work while the original job remains pending.

The server reconciles pending jobs on startup and its existing maintenance
pulse. Separate original jobs perform their recovery I/O concurrently. An
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
producer acknowledgement does not recreate the notification. If the canonical
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
