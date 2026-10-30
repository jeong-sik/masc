# Keeper Continuity Production Runbook

**Status**: production release gate
**Updated**: 2026-10-23

Keeper continuity means that one ordered Keeper lane can restore its agent core
checkpoint, consume typed wake events, and keep making observable progress
without blocking other Keeper lanes.

## Release Gate

Release only when all items are true:

1. checkpoint save and restore use agent core checkpoint primitives;
2. MASC owns domain transitions and exposes matching receipts/tool results;
3. the validation in
   [KEEPER-CONTINUITY-VALIDATION.md](./KEEPER-CONTINUITY-VALIDATION.md) passes;
4. lane isolation is proven under a busy turn, provider failure, and restart;
5. load/save/receipt errors are observable and actionable;
6. dashboard and status surfaces report typed lifecycle/checkpoint facts only;
7. no prompt, parser, sidecar, API, or UI derives runtime state from assistant
   prose.

## Evidence Bundle

Attach the exact validation command and artifacts for:

- Keeper identity, trace, and turn IDs;
- input event delivery/queue evidence;
- checkpoint loaded/saved manifest rows;
- terminal execution receipt;
- domain transition receipts when mutations occurred;
- restart restore result;
- independent-lane progress during the tested lane's stall.

Do not substitute screenshots or narrative summaries for machine-readable
artifacts.

## Monitoring

Monitor per Keeper lane:

- checkpoint load/save outcomes;
- event queue age and delivery outcome;
- terminal turn outcomes and typed blockers;
- provider attempts and asynchronous completion wakes;
- time since last successful lane progress;
- other-lane progress while one lane is stalled.

A failure in one lane must not pause the fleet. Preserve the failed event and
surface its error; let unrelated lanes continue.

## Undecodable Stores at Boot

The executable checks its own durable-store policy during owner initialization,
including when a supervisor or a shell starts it directly. This check does not
depend on having run the deployment preflight. `Keeper_durable_store.reader` owns the policy;
`Keeper_store_boot_reconcile.examine` and `admit` run before Keeper loops and
before owner readiness is published.

The supervisor promotes a candidate to the last-known-good artifact only after
the candidate PID owns the listener and `/health/ready` returns success. Its
`status` command checks the same endpoint. `/health` liveness can succeed while
owner initialization is still running, so it cannot certify a completed startup
or authorize restart of a candidate that subsequently fails initialization.

| Store | Executable startup behavior | Recovery boundary |
|---|---|---|
| Keeper metadata | `Refuse_boot` | Preserve identity and task bindings. |
| Current Memory OS snapshot | `Refuse_boot` | Preserve the Keeper's current memory. |
| Official-client session binding | `Refuse_boot` | Preserve the original vendor session binding. |
| Event queue snapshot and transition WAL | `Refuse_boot` | Read the pair with the queue's production decoder; retain both on refusal. |
| Goal store | `Degrade_typed` | Report unreadable state once at boot; goal readers and writers retain typed unavailability. |
| Gate pending snapshot and log | `Preflight_only` | Deployment validates snapshot and log replay; runtime Gate installation reports an unavailable queue rather than an empty queue. |
| Board attention partitions | `Preflight_only` | Deployment validates the production partition ledger; process-start recovery refuses unreadable evidence and preserves it. |

The first four stores are decoded before any Keeper lane starts.
When a file does not decode with this build, the
process does not start. It exits 1 and the startup log carries one line per
file:

```
[FATAL] Critical startup failed before readiness; refusing partial BasePath ownership: Keeper persistence preparation failed: boot refused: 1 store(s) this build cannot read
  memory_current keeper=sound path=<base>/.masc/config/keepers/sound.memory-current.json: <path>: invalid JSON: ...
strip or repair the files and run `deployment_preflight_helper validate-stores` against this base path, or start with --accept-store-quarantine to move them aside and start those keepers with empty stores
```

The files are not touched. Two ways forward:

1. Repair or strip the files, then confirm with
   `deployment_preflight_helper validate-stores --base-path=<base>` and start
   again. This keeps the keeper's memory.
2. Start with `--accept-store-quarantine`. Each refused file moves to
   `<path>.rejected-<timestamp>` (kept as bytes), and the Keeper starts with an
   empty store. For a Memory OS snapshot, its journal also gets a `quarantined`
   line. The flag is
   for one start; do not put it in a launcher. Note: if a store is left in an
   unrecoverable publication state, `--accept-store-quarantine` is also refused;
   repair the store and re-verify with `validate-stores --base-path <base>`
   before starting.

For an event queue, the snapshot and transition WAL move together. Before
either move, quarantine writes `event-queue-quarantine-v1.json` in that Keeper's
runtime directory with both original identities and their rejected sibling
paths. If a move fails or the process stops, boot, preflight and queue access
continue to refuse at this record, including when both originals have moved.
Keep the record and both rejected files. After repairing the reported filesystem
obstacle, explicitly start with `--accept-store-quarantine` again to finish the
recorded moves. The retry verifies identities and bytes and reuses the same
destinations; it does not discard or overwrite a conflicting entry. Malformed
records or replaced entries require owner repair before retrying. Only a fully
completed and directory-synced quarantine clears the record and permits a new
empty queue.

The deploy preflight and executable startup have different scopes. The preflight
reads `Refuse_boot` and `Preflight_only` stores. The executable's boot examiner
reads `Refuse_boot` and `Degrade_typed` stores; it does not scan every stored
provider input or historical record. A successful preflight is a read at that
time, not permission to skip startup validation or proof that no file can change
before startup.

For Gate, a successful process start does not mean approval authority is usable.
If `install_persistence` fails, the startup log reports
`keeper_gate: durable queue install failed` with its error. `/health?full=1`
reports the `keeper_hitl_gate` section as unavailable with operator action;
a liveness response alone is not this check. Preserve the pending snapshot and
log together. With the owning server stopped, repair the reported failure and
run the same build's `deployment_preflight_helper validate-stores
--base-path=<base>`. An incomplete append-log tail is a refusal requiring owner
recovery; this read-only command does not trim it. Do not clear an approval
queue merely to obtain a healthy status: that discards pending authority.

Checkpoint loading deliberately remains outside the startup inventory, following
the recorded 2026-09-26 operator decision. A missing checkpoint and an explicitly
superseded version have separate outcomes. A parse failure, newer version or
read/store error refuses the affected Keeper's context preparation with a typed
checkpoint error; it does not authorize replacing unreadable state with an empty
checkpoint. Preserve the trace checkpoint and history, then roll back or repair
the reader before re-admitting that lane. The quarantine flag is not a general
checkpoint reset.

The store policy and its checkpoint decision are documented in
[RFC: every durable store has one boot policy](./rfc/RFC-every-durable-store-has-one-boot-policy.md).
[Issue #37900](https://github.com/jeong-sik/masc/issues/37900) tracks the original
supervised-restart gap and the later Gate/Board preflight additions. The original
event queue gap is handled by executable startup validation; the Gate and
checkpoint policies above are distinct boundaries, not a request to make every
unavailable subsystem stop the whole server. These are source-level contracts;
a repaired source or selected test is not proof that an installed binary was
replaced or that a live restart succeeded.

`validate-stores` also reads the Lane Add-on records under
`<base>/.masc/lane-addons` (bindings, native claims, action receipts, Exact
requests, original tool requests). Boot does not read them; their readers meet
an old-shape file later and keep refusing it (#45106: an installation stayed
`failed` and refused every new start). The preflight prints each refused file
with the decoder that refused it and one `fresh state:` line: stop the server,
move the listed paths aside, then start the new build. For a native claim the
list is the slot directory together with the binding and observations of the
instance it holds. A detached binding that names its declaration passes even
when it does not parse, as declaration application passes it and keeps its
fields as evidence; only a read of that one instance (Inspect by id, Observe,
Detach) still fails on it. A Chrome or live BiDi child slot is read through the
installation that holds it, so a child slot of an earlier instance is not read.
The preflight only reads; it never moves these files.

## Containment and Rollback

If checkpoint continuity regresses:

1. stop admitting new work to the affected Keeper lane only;
2. preserve its queue, checkpoint, manifest, and receipts;
3. keep other Keeper lanes running;
4. revert or forward-fix the checkpoint adapter that failed;
5. rerun the full typed validation before re-admitting the lane.

Do not reconstruct state from assistant text. Do not copy a prose summary into
task/goal/lifecycle storage. Do not silently discard the event that exposed the
failure.

The ownership and forbidden-protocol rules are normative in
[KEEPER-STATE-OWNERSHIP.md](./KEEPER-STATE-OWNERSHIP.md).
