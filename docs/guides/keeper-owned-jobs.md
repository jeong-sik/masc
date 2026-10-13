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
confirmed exit are separate facts. Confirmed terminal stdout and stderr are
published as complete durable artifact references in stdout, stderr order; an unavailable output remains
explicit and can be collected later without running the program again.

Optional `inputs` is an array of `{ "path": "input.txt", "artifact": ... }`,
where `artifact` is the exact normalized `Tool_output` reference returned by a
producer. Each path is one distinct file name. The store verifies the checksum
and byte count before copying its bytes into the private workspace. It never
mounts the Keeper's current workspace, credentials or identity. The job has no
network access and a read-only image filesystem. Image-declared writable volumes
are inventoried and replaced by recorded job-private tmpfs mounts.

Create and start intentions are committed before their corresponding backend
calls. An unconfirmed create/start keeps that intention and the same handle.
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

These direct tools use serial admission and return while the isolated program
runs. This producer is the first owned-job backend: shared mutable workspace
claims, remote Docker bind authority, automatic job-completion wakes and
composition suspension/resume need their own execution contracts. Prepared
read-only draft continuation does not reinterpret these jobs as retryable
ordinary leaves. Those remaining contracts are tracked in
[issue #42799](https://github.com/jeong-sik/masc/issues/42799).
