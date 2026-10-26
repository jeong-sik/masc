# Keeper VM build cleanup

The MASC server owns artifact cleanup through each Keeper's Owner mailbox.
`Server_keeper_build_maintenance` runs under the server root switch. The normal
`Runtime_params` surface controls `keeper_build_cleanup_enabled` (default true),
`keeper_build_cleanup_interval_sec` (one hour), and
`keeper_build_cleanup_retention_sec` (one day). These are artifact-retention
settings, not time limits on Keeper work or durable tasks.

The binary embeds `config/scripts/keeper-build-cleanup.py` and passes both the
Keeper work root and the canonical build-volume root to its framed exec-shim
runner. There is one product mutation controller; installing the binary does
not require a checkout or a separate cleanup daemon.

## Admission and scope

Cleanup defers to queued/running chat, unavailable operation stores, active turns
and shutdown through the existing atomic Maintenance admission. Busy attempts
can be considered at a later maintenance pulse. One root-owned attempt per
Keeper excludes overlap across pulses; a slow VM does not delay visiting
unrelated Keepers. Reservations release when callbacks return or unwind, and
the root switch joins scheduled children. A request arriving after
admission can still wait for that attempt. Local transport cancellation does
not prove the original guest process group has stopped; no same-Keeper
preemption guarantee is made. Existing atomic transactions, including filesystem
repair and ownership transfer, retain their interruption contract.

Only an already running Apple guest with a matching effective TOML profile and
Owner identity is eligible. Cleanup does not boot, stop, pause, repair or refresh
a guest's credentials. A paused Keeper without a running guest keeps its work
volume. A source merge does not change the installed runtime.

## Owned output and safety

The guest needs Python 3, readable Linux process ownership and Dune 3.24 or
newer with native targeted clean. It admits a real `_build` beside `dune-project`,
or the exact managed link produced by `Keeper_microvm_build_plan`: checkout
path segments joined with `:` under the configured build root. Arbitrary,
dangling, redirected or another checkout's links are retained.

Both the source checkout and its physical build target are checked for live
process use. The existing wrapper lock and native Dune lock exclude builds.
After inspection the target's ownership and directory identity are checked
again. Targeted `dune clean` retains the native `.lock` inode and source files;
it does not perform a whole-project clean that could remove promoted source.
Unreadable process ownership refuses cleanup. It is never interpreted as no
live process.

A checkout containing `.masc-keep-build` retains output. Otherwise every entry
must remain unmodified for the configured retention period. Store durable
release/test evidence outside `_build`, or use that retention marker. Sources,
Git stores, worktrees, package caches, Keeper memory and domain/effect records
are outside artifact cleanup.

## Guest space and host space

The report's allocated artifact bytes and guest free-space delta describe the
guest. They do not prove an equal reduction in allocated host image blocks.
The work volume has a boot-time discard/trim path; the disposable build volume
is recreated at a fresh boot and the baseline does not give it that discard
default. Existing mounts do not change because source is merged. Cleanup never
mounts a live volume in another VM or stops a Keeper to force host recovery.

See the [volume lifecycle investigation](../research/2026-10-26-keeper-volume-lifecycle.md)
for usage cases, observed evidence and the separate incarnation-bound retirement
plan. The helper's own lifecycle and external Apple API contention are tracked
in [the boot-helper RFC](../rfc/RFC-keeper-boot-runs-no-one-shot-container.md).

## Deployment boundary

Before activating this binary on a workspace with an independently running
cleanup process, identify that exact process and its in-flight payload, request
its documented stop, and verify that both controller and payload have exited.
Retain the final report. Removing its source file or observing a stale PID file
does not prove it stopped. If stop/drain cannot be verified, the cutover remains
unverified; do not claim a single active controller. No compatibility mutation
controller is shipped with the product.

Guest exit zero is successful cleanup only with that call's actual exec-shim
execution receipt. Transport EOF and the existing guest timer stop the process
group. Root cancellation propagates. A failed or unavailable execution receipt
is an error, and interrupted partial artifact removal can be rediscovered without
replaying a durable domain effect.
