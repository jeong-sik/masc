# Keeper volume lifecycle and reclamation

Status: first implementation stack; retirement reconciliation remains a separate
incarnation-bound work unit. Related issue: [#40708](https://github.com/jeong-sik/masc/issues/40708).

## Evidence and scope

The source baseline for this investigation is main
`73801f7c2dba579de02b3bb1ecb7933ca11d5ae5`. The preceding operator-authorized
2026-10-26 cleanup observed 55 Apple volume images, approximately 504.75 GiB
of allocated host image blocks after maintenance. Nine Git object stores were
repacked manually, reducing native `count-objects` pack size by 11.33 GiB.
This does not establish an automatic runtime policy or physical recovery of
exactly that amount. Other Keepers were writing concurrently.

The [sanitized census receipt](../evidence/2026-10-26-keeper-volume-lifecycle/census.json)
binds the observed runtime instance, snapshot timestamp and hashes of the
retained local receipts. It publishes no credentials or private file contents.

The saved ownership snapshot classified 14 work and 14 build volumes as
attached to registered Keepers, 22 registered work and two registered build
volumes as unattached, and three work volumes with no name in that runtime's
owner inventory. These are snapshot classifications, not deletion authority.
A later pair of container-list requests failed with Apple API XPC timeouts.
Neither failure proves that a guest or volume is absent.

Read-only ext4 superblock observations found no recorded errors in 55 images.
Two unattached work images passed all five `e2fsck -f -n` passes, with unchanged
image identity and modification time. This is not a full filesystem check of
the entire fleet. Directory inspection showed substantial source/checkouts,
scratch work and Git stores: the large paused volumes were not empty caches.

The installed runtime receipt identified binary
`072357f887d63a44fff071808556d66dd5637b08`, a distinct identity from the source
baseline above. Its logs since the observed instance start contained 13
successful boot-trim records and one trim timeout (native exit 124); there was
no attached-build-cleanup result in that same window. Log absence cannot
distinguish no-op, admission deferral, or an unexecuted sweep. A trim's reported
free range is not newly recovered physical host bytes.

## Current producer-to-consumer paths

| Resource/action | Producer and authority | Consumer and actual limitation |
|---|---|---|
| Work volume | `microvm_work_volume` / `ensure_work_volume_for` | `masc-keeper-work-<name>` persists across boots; globally name-based, without incarnation identity |
| Disposable build volume | `microvm_build_volume` / `recreate_apple_build_volume` | Recreated only at fresh guest boot, not when adopting a running guest |
| Managed build link | `Keeper_microvm_build_plan.build_link_target` | Checkout path segments map to one colon-separated child under `/masc-build` |
| Idle build cleanup | `Server_keeper_build_maintenance` / Owner maintenance | Effective TOML is checked, but the baseline skips every linked `_build` |
| Guest process execution | `cleanup_attached_builds` / framed exec-shim | Timeout/EOF cancel the payload group; success requires its actual execution receipt |
| Work-block reclaim | `reclaim_work_volume_space` | Privileged helper before a fresh boot; a failed trim can permit boot after helper absence is proven |
| Permanent retirement | `Keeper_shutdown_finalize` | Volume failure is logged, then logical finalization may proceed without a durable resource result |
| Terminal-record reclaim | `Keeper_shutdown_store.delete_terminal` | Ordinary finalization can remove the only operation that named the retirement intent |
| Additional script service | Separate container-exec sweep | Bypasses Owner admission despite sharing Dune/process locks; remove this controller |

The work volume's persistent discard configuration and the build volume's
recreation have different behavior. The baseline explicitly gives the build
volume no discard default. Cleaning a managed build target can therefore free
guest blocks while the host image remains allocated until a later volume
recreation. Enabling extra boot helpers is not a free fix: the existing
[RFC on boot helpers](../rfc/RFC-keeper-boot-runs-no-one-shot-container.md)
records Apple API stalls when one-shot containers terminate.

## Contracts to preserve

1. Keeper input, execution effects, delivery outboxes, continuation checkpoints,
   memory and task claims keep their existing owners and durable settlement.
   Reclamation never settles or reconstructs those obligations.
2. Background artifact cleanup is idempotent and consumes no chat input. A
   future preemption path must confirm the original guest process group has
   settled before releasing its slot; local CLI cancellation is insufficient.
   The first stack retains existing atomic admission rather than assert that
   unimplemented remote guarantee.
3. Existing atomic Maintenance transactions, particularly filesystem repair and
   ownership transfer, remain atomic. Background cleanup gets its own explicit
   preemption contract rather than changing those callers.
4. Pause preserves work. Unattached and old are observations, not proof of
   permanent retirement or dispensability. A retained marker protects output.
5. Data-plane progress and physical reclamation are separate. Failed storage
   cleanup does not become a new shutdown/admission fence.
6. A missing/corrupt/unavailable authoritative inventory permits no deletion.
   An ambiguous command outcome remains unresolved until exact readback.
7. Hardcut replaces conflicting controllers/contracts without compatibility
   adapters. It does not waive effect ownership or authorize an unattended
   destructive cut of production work.

## Usage cases and failure windows

| Case | Expected behavior and evidence |
|---|---|
| Active chat or autonomous turn | Owner refuses idle cleanup; input and durable task/effect records stay unchanged |
| Chat queued before cleanup admission | Fresh Owner queue projection defers cleanup; unavailable queue also defers |
| Chat arrives during a large scan | First stack retains current atomic slot; future preemption requires original guest group settlement, then starts the existing chat |
| Chat arrives before a future cancellation handle is installed | Recheck fresh readiness after handle publication; no lost wake/preemption window |
| Transport is lost while preempting cleanup | Local CLI reap is not guest settlement; preserve unknown original execution and reconcile by its durable identity, without a guessed success or indefinite new admission fence |
| Atomic repair/transfer owns Maintenance | Chat waits for that transaction; background preemption cannot signal it |
| One VM's exec/API is slow | Other Keeper cleanup attempts progress independently; one attempt per Keeper per service scope |
| Root shutdown during cleanup | Cancellation propagates, workers are joined and transient reservations released; no false success |
| Ordinary real `_build` | Native targeted Dune clean under wrapper/native locks; preserve sources and `.lock` inode |
| Canonical managed `_build` link | Admit only the exact producer mapping and physical target, then apply the same locks and targeted clean |
| Foreign/dangling/escaping/shared-target link | Retain it; do not infer ownership from the `/masc-build` prefix |
| Process executes/opens an artifact through its physical target | Both checkout and actual target ownership prevent cleanup |
| Recent output / explicit retention marker | Retain output; age only selects disposable artifacts, never Keeper/domain liveness |
| Guest has no Dune or process visibility | Report refusal/error; do not authorize cleanup from an empty fallback |
| Paused Keeper with no guest | Preserve work; no boot/resume solely for cleanup |
| Independently running cleanup service at binary cutover | Stop and drain its exact controller and payload, retain the final report and verify exit before enabling replacement; removing script files is not stop evidence |
| Server restart/adoption | Restore the existing durable owners; current live mounts do not change merely because source was merged |
| Permanent removal succeeds, volume deletion fails | Logical shutdown may release admission, but physical cleanup must remain a separate durable obligation |
| Crash before durable retirement capture | No new deletion authority exists |
| Crash after capture / after only one volume is removed | Recover the same resource obligation and independent per-resource progress |
| Delete command times out | Observe that exact resource before deciding absent/present; do not blindly repeat deletion |
| Same name is created with a new Keeper UID | Old retirement must never authorize deletion of new or reused resources |
| Another workspace has the same Keeper name | Workspace and incarnation identity must isolate resource authority |
| Unknown-owner existing volume | Expose it for explicit disposition; inventory-name mismatch alone cannot destroy it |
| Cleanup reports success | Report guest artifact effects separately from host allocated blocks; no blanket disk-recovery claim |

## First Native Stack

Each layer is independently reviewable against its direct base. None changes the
installed runtime or deletes live source/volumes as part of publication.

1. **Contract and evidence:** this investigation, use-case matrix and ordered
   implementation/verification plan. Retain issue #40708 until its remaining
   resource-lifecycle conditions are actually proven.
2. **One mutation controller and owned build targets:** remove the standalone
   periodic mutation service, import the embedded payload directly in its
   focused tests, and make canonical build-root binding explicit at every
   producer/consumer. Clean managed targets with native Dune safety, preserve
   arbitrary links and durable/source files, and test the actual filesystem
   effect and refusal cases.
3. **Independent fleet scheduling:** root-switch-owned per-Keeper attempts
   exclude overlap and release reservations on return, exception and
   cancellation. A slow VM does not block visiting other Keepers. Existing
   same-Keeper atomic admission and durable input handling remain unchanged.
   Same-Keeper preemption was rejected in review because the current remote
   cancellation path cannot prove the original guest group has settled.

## Original-execution cancellation prerequisite

`Keeper_sandbox_remote.runner_for_root` publishes an execution receipt only on
normal return. On cancellation, `eio_process_capture` closes host stdin, signals
and reaps the local CLI; it does not require the remote terminal trailer. The
shim begins guest TERM/KILL handling when transported EOF reaches it. Those are
two different boundaries, even if their grace values happen to match. An Owner
callback-finalizer test plus a direct-shim EOF test do not prove integration.

A safe same-Keeper preemption design needs a typed original-execution identity,
a cancellation acknowledgement covering actual guest process-group reap, and
readback/reconciliation when XPC or transport disappears. The current synchronous
wire has no endpoint-owned async job identity for that recovery. Do not repair
this with another timeout or return `Preempted` merely after local process reap.
Do not add an indefinite Keeper fence to conceal the missing remote evidence.
Required acceptance drives the actual remote transport with delayed EOF and a
TERM-resistant guest child, and compares guest completion with chat start while
checking the original durable queued row. Root cancellation and disconnected
outcomes retain their real evidence. This is separate protocol work.

## Next resource-lifecycle stack

Automatic retirement replay is deliberately sequenced after immutable resource
identity. Adding a name-only janitor would turn a storage leak into data loss.
The following work is required; the first stack does not claim it implemented.

### Identity and lifecycle capture

Bind each new sandbox resource to the normalized workspace identity and the
stable Keeper birth UID already assigned by `Keeper_turn_up_create`. Record
backend, resource identity and immutable incarnation before the side effect
that registers/creates it. Named resources must not be implicitly adopted by a
successor solely because a Keeper name matches. Validate backend/native labels
and stable volume-generation evidence under the existing lifecycle boundary.
The current process-local mutex is not a cross-process deletion capability.

Change names, creation, adoption, status, teardown, repair, artifact transport
and all direct consumers together. Hardcut with no old-name fallback. A concrete
cutover inventory must account for retained production work explicitly; neither
silent loss of reachability nor automatic old-volume deletion is acceptable.

### Durable retirement disposition

Use the existing shutdown operation as the owner of retirement obligation;
do not add a competing definition of Keeper liveness. Capture exact resources
before unregister, with per-resource closed states for pending/unknown/verified
absence/explicit retention and evidence identifying what was observed. Publish
physical disposition durably without extending `Blocked` or completion-delivery
states to storage failure. Finalization/admission release must remain independent.
Retain terminal operation records while an exact resource obligation is unsettled.

### Background reconciliation

Consume those durable exact obligations from root-owned background workers.
Revalidate the original resource generation and all attachments before effects.
An unreadable inventory delays only that resource; unrelated Keepers continue.
After an uncertain deletion, authoritative exact readback resolves the original
effect before any repetition. Partial work/build progress survives restart.
Existing ambiguous resources require an explicit recorded disposition.

### Physical host-block return

First measure disposable-target deletion versus allocated image blocks on the
actual installed backend. Coordinate discard provisioning with the boot-helper
RFC; do not add a second periodic privileged mount or stop a live Keeper to
force trimming. Keep artifact count, guest free bytes, host allocated bytes,
command acceptance and verified deletion as separate observations.

## Verification and delivery

| Changed surface | Actual direct consumer | Focused scenario/check |
|---|---|---|
| Guest cleanup payload/CLI | Embedded runtime exec-shim dispatch | Real temporary Dune targets: canonical link clean, source/link/lock retained; foreign link, target owner, native lock, marker and unreadable owner refused |
| Existing Owner admission | Per-Keeper scheduled cleanup | Queued/running chat still defers cleanup; no new lane, queue mutation or same-Keeper preemption |
| Future background preemption | Original remote execution and Owner completion | Actual guest cancellation/reap acknowledgement, publication race, transport loss, durable original chat unchanged |
| Per-Keeper scheduling | Root-owned maintenance pulse | A held first attempt does not stop another; overlap excluded; exception/cancellation returns reservation |
| Resource identity (next stack) | Create/adopt/teardown/repair/transfer | Two workspaces and same-name/new-UID successor remain isolated |
| Durable disposition (next stack) | Terminal reclaim and restart recovery | Crash at each capture/effect/readback boundary; partial progress; admission stays usable |
| Physical reclaim (next stack) | Actual Apple image and host filesystem | Before/after allocated blocks and peer request latency, with exact binary/guest identity |

Run lightweight source/parse checks and meaningful non-build filesystem tests.
Do not substitute mocks for Linux process-group or actual Apple block-return
proof. Focused compiled checks can be explicitly dispatched without CI watch
loops when needed; unexecuted scenarios remain unverified. Independent source
review binds current head, direct base and the full diff for every layer.
Publish and verify REST Native Stack membership; do not merge layers separately.

## External design evidence

[Docker volume lifecycle](https://docs.docker.com/engine/storage/volumes/) keeps
named data outside container lifetime.
[Kubernetes reclamation/finalizers](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
separates retention policy and backing-resource deletion. The inference for MASC
is to preserve an explicit resource owner and durable deletion obligation while
keeping logical Keeper completion separate. These systems' policies are not
imported as automatic authority over MASC work.
