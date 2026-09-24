---
rfc: "0468"
status: Draft
---

# RFC-0468 — Keeper build output returns to a disposable volume

- Status: Draft
- Decision driver: measured 2026-09-24 on the live fleet (14 running microVM
  keepers). Host free space on `/` dropped to 42 GiB (of 3.6 TiB) while
  `~/Library/Application Support/com.apple.container/volumes` held 759 GB.
  Three `masc-keeper-work-<name>` volumes inspected directly (`container exec
  ... du`) were 87–105 GB each, 90%+ of it one `_build` directory:
  `polisher/masc-polish/_build/default` 84 GB, `pr-updater/repo/_build` 69 GB
  (+ `pr-updater/masc/_build` 6.8 GB). `container system status` was healthy
  but `container volume prune` hung for minutes and `container ls -a` threw
  `XPC timeout for request to com.apple.container.apiserver/containerList`
  under the same pressure — disk exhaustion is starting to destabilize the
  container apiserver itself, not just fail loudly.
- Area: `lib/keeper/keeper_sandbox_microvm.ml` (+ `.mli`), the guest start
  path in `lib/keeper/keeper_turn_sandbox_runtime.ml`,
  `test/test_keeper_sandbox_microvm.ml`. Same files RFC-0399 touched and
  RFC-0400 §C's "RFC-0399 `_build` link machinery... deleted" removed from.

## Problem (measured)

Deleting `_build` from inside a running guest does not free host disk.
Measured directly:

```
before: polisher/volume.img  225G   (host, du -sh)
guest:  rm -rf /masc-work/polisher/masc-polish/_build     (84G reclaimed inside the guest)
after:  polisher/volume.img  225G   (host, du -sh — unchanged)
```

`fstrim -v /` inside the guest, run both as the default user and as
`-u root`, both failed:

```
fstrim: /: FITRIM ioctl failed: Operation not permitted
```

Apple's container 1.3.1 virtio-blk backend does not advertise discard/unmap
to the guest, so there is no ioctl the guest can issue — root or not — that
returns freed blocks to the host's sparse `volume.img`. This was checked
against a real guest, not assumed from documentation gaps.

`container volume prune` (no-container-reference volumes only, by design —
verified in the CLI's own `--help`) did reclaim real host space: 6 orphaned
volumes, 759 GB → 612 GB, host free 42 GiB → 112 GiB. It could not touch the
five volumes above 50 GB because every one of them belongs to a keeper that
is still running.

So the only host-reclaim path that exists today for a *live* keeper's bloat
is: stop the guest, delete `masc-keeper-work-<name>`, recreate it empty. That
throws away the keeper's git checkouts, task files and docs along with
`_build` — there is no volume boundary between them to delete selectively.

## What the codebase already says

RFC-0399 solved a different, more acute problem — `_build` on the virtiofs
share pinned one host descriptor per inode with no `FUSE_FORGET` on container
1.3.1, and three of those pins ended in a kernel panic
(`vnode: table is full`). Its fix put `_build` on its own ext4 volume,
`masc-keeper-build-<name>`, reached by a host-side symlink into a guest
mountpoint, with 21 new tests proving the plan never deletes real output,
never follows a symlink into a loop, and mkdirs the guest target once per
turn rather than once per checkout.

That RFC's own numbers already treated multi-GB `_build` growth as normal,
not a defect: *"The default of 128 GiB is set against a measurement: one
keeper's playground held three 29 GB `_build` directories, 87 GB together."*
The ceiling was sized to the observed growth, not to bound it.

RFC-0400 then moved the whole checkout onto ext4 — for the FD-pin problem,
`_build` no longer needed special handling, since block-device storage never
pins host descriptors regardless of what's on it. Correct for that problem.
But §C of RFC-0400 also deletes RFC-0399's split-volume machinery outright:
*"The RFC-0399 `_build` link machinery, its status rows, the build volume and
`MASC_KEEPER_MICROVM_BUILD_VOLUME_SIZE` are deleted: on a tree that already
lives on ext4 the links would classify every checkout as
`Build_real_directory` and warn each turn about a problem that no longer
exists."*

That statement is true for FD pinning and not true for host disk. Folding
`_build` back into the unified `masc-keeper-work-<name>` volume removed the
one thing the split gave for free: a volume holding nothing but derived
output can be deleted and recreated with zero data-loss risk, the same way
the constitution already licenses runtime data in general — `<runtime_data>`:
*"기능 개발에 불필요하고 용량이 부담되면 지우고 새로 한다"* (delete and
start over when it's a burden and not needed for feature work). A unified
volume can't take that path without also discarding the checkout, task
state and docs that live next to `_build` — which is exactly why today's
manual cleanup stopped at `rm -rf` inside the guest and never reclaimed host
space.

This is a regression the RFC-0400 author could not have measured at the
time: RFC-0400 was written to stop kernel panics, on a fleet where volumes
were presumably still small. Five months (worth of turns) later, host disk
is the failure mode RFC-0399 already had a working answer for, and RFC-0400
removed it as a side effect of solving something else.

## Design

Bring back a build-only volume, scoped to exactly what RFC-0399 already
built, tested and measured — not reinvented, re-attached:

```
host (unchanged, RFC-0400)                 guest
/masc-work/<keeper>/<checkout>/               (ext4, masc-keeper-work-<name>)
  lib/ test/ .git/  ── ext4, owned ──▶          lib/ test/ .git/
  _build ─→ /masc-build/<checkout>              _build ─┐
                                                          ▼
volumes/masc-keeper-build-<name>/           /masc-build/<checkout>/
  volume.img (ext4, sparse, small)  ── virtio-blk ──▶  (disposable)
```

`plan_build_link`, `Build_absent | Build_symlink | Build_real_directory`,
`ensure_build_links`, the per-turn refresh, the never-follow-a-symlink walk,
the never-delete-a-real-directory refusal — RFC-0399's mechanism carries over
unchanged; it was never wrong, it was disconnected. The only new part is
recreation.

**Recreation trigger — reactive, not predictive.** An earlier draft of this
section proposed probing each build volume's host size on a timer and
recreating past some percentage of the ceiling. That number would have been
a guess with no measurement behind it — exactly `forbidden#magic_number`
("암묵적 판단 기준이 아니라 선명한 기준으로") — and checking it would have
required inventing the fleet's first real disk-pressure gate on top of a
module that is explicitly not one.

Corrected against what the codebase actually has: `keeper_disk_pressure.mli`
(now `lib/keeper_runtime/`) says of itself, in its own doc comment,
*"This module never admits, delays, pauses, or rejects Keeper work. It
records actual typed ENOSPC failures and exposes raw df observations."*
RFC-0122's `Resource_pressure.S` circuit breaker that would have made a size
threshold meaningful was never built — its own progress audit marks that
phase absent. There is no existing gate this RFC's trigger can ride on.

So it does not predict. RFC-0399 already measured and declared a ceiling for
`_build` volumes — 128 GiB, `MASC_KEEPER_MICROVM_BUILD_VOLUME_SIZE` — sized
against one keeper's real 87 GB. That number is not invented here; it is
reused as-is. The trigger is the guest's own write failing inside that
ceiling: a build-volume operation returns typed ENOSPC (the same condition
`keeper_disk_pressure.ml`'s `note_exception` already records, extended to
also route through the build-volume path), and *that*, not a percentage
guess, is what starts recreation — stop the guest's use of that one volume,
delete it, recreate it empty, refresh the symlink, let the failed operation
retry. Nothing is predicted; something that already, deterministically,
happened is repaired.

This is host-side fleet maintenance, not a budget gate on keeper turns — the
keeper never sees this volume, there is no cumulative counter, and
`forbidden#budget_gate`'s own carve-out for resource/safety boundaries
covers a real ENOSPC the same way it covers a provider's hard limit. It is
also, honestly, new: this is the first thing in the codebase that *acts* on
a disk-pressure observation rather than only recording it. RFC-0122's own
"purge 정책은 별도 RFC" note said this was coming; this is that RFC, scoped
to exactly the one volume kind this RFC has measurements for.

**What does not move.** `.git`, task files, docs, anything the keeper wrote
by hand — RFC-0400's unified tree ownership stands. Only the directory dune
itself calls derived output moves, and only dune is in scope, matching
RFC-0399's own "Known gaps": npm deletes and recreates its target directory
on every install rather than respecting a symlink (measured there,
`node_modules` would silently leak back onto the share/tree volume), so
`node_modules` is not part of this RFC either. `cargo`/`target` stays
unmeasured, as RFC-0399 left it.

## Scope, as a stack

### A. Reattach the RFC-0399 mechanism

Not a revert — checked against current `main`. RFC-0400's deletion commit
(`37d26eab2f`, "RFC-0400 C") landed after `keeper_sandbox_microvm.ml` was
already refactored onto a multi-backend `Keeper_microvm_backend.t`
(container/nerdctl/msb), and roughly fifty commits have deepened that since.
Every CLI-effectful function in the file now carries that backend as an
explicit argument, spelled with a `_for` suffix — `image_present_for`,
`network_args_for`, and the pattern this RFC's functions must match,
`ensure_work_volume_for`.

The pure functions restore unchanged: `build_link_target`, `type
build_link_state = Build_absent | Build_symlink of string |
Build_real_directory`, `type build_link_plan = Link_create | Link_retarget
| Link_already_correct | Link_refused_real_directory`, `plan_build_link`,
`build_link_state_of_path`, `build_roots_under`, `playground_relative` —
none of these touched a backend, so none of them changed shape.

The effectful functions are ported, not copied: `build_volume_name`,
`build_volume_create_argv`, `build_volume_mount_args`,
`volume_names_of_json`, `classify_volume_probe`, `volume_probe`,
`ensure_build_volume`, `apply_build_link`, `ensure_build_links`,
`build_target_mkdir_argv` each gain the `Keeper_microvm_backend.t ->`
parameter and follow `ensure_work_volume_for`'s current template, the same
way `Fd_pressure` was meant to alias `Resource_pressure.S` in RFC-0122 —
existing shape, new implementer. `volume_probe_outcome` and
`classify_volume_probe` already survived the RFC-0400 cut once, live today
under the work-volume path; the build-volume port reuses those types rather
than declaring parallel ones. `type volume_kind = Build_volume |
Work_volume` already exists for this — the port is a second match arm on a
type the codebase already has, not a new type.

Insertion point: the file's `build_volume_*` section used to sit where
`work_volume_*` now lives (lines 121–139 roughly, pre-cut); it goes back in
beside it, not in place of it — both volume kinds are provisioned by turn
end, one owning the tree, one owning derived output.

No new refusal semantics: a real `_build` directory already found on the
unified volume (pre-existing keepers, mid-flight at cutover) is left alone
and reported, exactly as RFC-0399's `Link_refused_real_directory` already
does. It converts to a link on a later turn once emptied, same as before.

### B. Recreation policy

No new periodic probe, no new ceiling. `keeper_disk_pressure.ml`'s
`note_exception` call sites extend to cover build-volume operations (today
they cover the paths RFC-0122 already wired); a build-volume write that
surfaces ENOSPC is where recreation starts, typed as `Build_volume_full of
{ name; op }`, not a size measured against a guess. `_build/.lock` presence
still gates the destructive step — a build in flight when ENOSPC hit is not
possible by construction (the failing write *is* the in-flight build), but
a second, unrelated build on the same volume must not be torn down under it,
so the lock check stays as the concurrency guard it already is for dune.

### C. Verification

- Unit: extend `test_keeper_sandbox_microvm` with RFC-0399's original suites
  ported to the RFC-0400 guest layout (44 tests existed; the ones proving
  "never deletes real output" and "does not follow symlinks" are the ones
  that matter most here, since this RFC pairs mechanism reuse with a new
  destructive step that must inherit those guarantees).
- New: `Build_volume_full` classification against a stubbed ENOSPC `errno`;
  the lockfile skip; recreation leaves the symlink and mountpoint intact
  from the keeper's perspective (a `dune build` retried immediately after
  recreation succeeds without the keeper doing anything).
- Live: one keeper's build volume filled to its 128 GiB ceiling (a small
  volume in a test fixture, not the live fleet), a build issued against it
  observed to hit ENOSPC, get classified, and trigger recreation; guest
  confirms the checkout is untouched (`git status` clean, task files
  present) and the retried `dune build` succeeds cold.

## Alternatives, and why they are not this

**Just raise `_build/.lock`-gated `dune clean` frequency inside the guest,
no volume split.** This is what today's manual fix did. It keeps the guest
healthy (prevents ENOSPC inside the 128 GiB ceiling) but never reclaims host
disk, because there is no discard path — measured today, not assumed. Any
design that stays on one volume inherits this ceiling regardless of how
often it's invoked.

**fstrim/discard support from Apple.** Would make in-place `rm -rf`
sufficient and this whole RFC unnecessary. Checked today (1.3.1, both as
user and root): not available. Worth filing upstream; not something this
runtime can wait on, same posture RFC-0399 took on the virtiofs FD leak.

**Compact `volume.img` offline (stop guest, `qemu-img`-style convert, or
similar).** No such subcommand in `container volume` (checked: `create,
delete/rm, list/ls, inspect, prune` only). Would also need the volume format
confirmed compactable, which is unverified, versus delete+recreate, which is
guaranteed correct for content that is 100% derived.

**Full keeper purge/recreate via `masc_keeper_down` + dashboard purge.**
Already exists and already works (measured in
`docs/research/2026-08-30-keeper-purge-profile-teardown-linux-runtime-r1.md`)
— it removes the microVM playground along with core, memory, TOML and chat
store. Correct for decommissioning a keeper. Wrong for this problem: it
throws away everything, including state this RFC is explicitly trying to
keep (git checkouts, task files, docs), to reclaim space that is 90%+ one
directory dune already knows it doesn't need.

## Open questions

1. ~~Ceiling and probe interval defaults~~ — resolved by not needing one.
   The trigger is ENOSPC against RFC-0399's already-measured 128 GiB
   ceiling, not a proactive percentage against an unmeasured fleet
   distribution. No new number, no new probe interval.
2. **Idle-detection precision.** `_build/.lock` covers dune. A build tool
   this RFC hasn't measured (if a keeper ever runs one inside `_build`) could
   have no lockfile at all, and the recreation step would need a second
   signal or would need to stay dune-only in scope, matching RFC-0399's own
   "Known gaps" posture on npm/cargo.
3. **Does the janitor need per-keeper opt-out?** A keeper mid-debugging a
   build artifact (inspecting `_build` output by hand, not through a fresh
   `dune build`) would lose that state on recreation. RFC-0399 never had this
   question because its volume was smaller and the guest chose when to link;
   this RFC adds an external actor deleting guest-visible state on a timer.

## Non-goals

- **npm/`node_modules`, cargo/`target`.** RFC-0399 measured npm actively
  defeats the symlink approach (deletes and replaces it with a real
  directory on install). Out of scope here as there, until a mechanism other
  than a symlink is designed and measured for those tools specifically.
- **Compacting the unified `masc-keeper-work-<name>` volume itself.** This
  RFC only gives `_build` a disposable home again. The checkout volume stays
  RFC-0400's design, unmodified.
- **A general "any oversized volume" janitor.** Scoped to the one directory
  this RFC has measurements for. A generic disk-pressure sweep across
  arbitrary guest paths is a different, larger RFC — RFC-0122 already flags
  "purge 정책" for later work explicitly, and this is that work, narrowly.

## Number allocation note

Allocated as RFC-0468. `docs/rfc/` highest present number was 0467 at
allocation time (0466 absent — reserved against reuse per README policy,
same convention RFC-0122 §8 documents).
