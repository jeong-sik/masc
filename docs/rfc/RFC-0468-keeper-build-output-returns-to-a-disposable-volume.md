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
- Backend scope: `Backend.Apple_container` only. Checked against the current
  code (`apple_volume_create_argv` vs `msb_volume_create_argv` vs
  `ensure_nerdctl_work_volume`): only Apple takes a sized volume — msb's dir
  volume rejects `-s` and nerdctl has no size flag at all, both already
  documented in-repo as "RFC-0400's size ceiling has no msb spelling, the
  way it has no nerdctl one." Those two back their named volumes with a host
  directory, not a sparse VM disk image, so `rm -rf` inside the guest already
  returns host space immediately for them — the problem this RFC exists to
  fix does not occur there. A build-only volume for msb/nerdctl would be
  solving nothing measured; left out rather than added speculatively.

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

RFC-0400 was merged 2026-09-02 (#32574, both its work-volume and cut phases)
— 22 days before this RFC, not the "five months" an earlier draft of this
section claimed without checking. It was written to stop kernel panics, on
a fleet whose volumes this RFC has no measurement of at that date. What is
measured is where the fleet is now: host disk is the failure mode RFC-0399
already had a working answer for, and RFC-0400 removed that answer as a
side effect of solving something else, regardless of how long the gap took
to matter.

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

`plan_build_link`, `Build_absent | Build_symlink | Build_real_directory`, the
never-follow-a-symlink walk, the never-delete-a-real-directory refusal — the
*decision* RFC-0399 made carries over unchanged. The *mechanics* do not: a
first pass ported RFC-0399's walk and link as host-side
`Unix.lstat`/`Sys.readdir`/`Unix.symlink` on a `playground_root`, which was
correct when RFC-0399 wrote it and stopped being correct when RFC-0400 made
a `Micro_vm` keeper's tree `Endpoint_owned`
(`Keeper_types_profile_sandbox.tree_location_of_profile`): the host keeps
only a bookkeeping bundle, and that type's own doc comment says a host-side
file operation on it "would silently miss the tree." Wired into boot as
first drafted, the walk would have found zero checkouts and done nothing —
its unit tests passed because they built synthetic host directories, not
real RFC-0400 keeper trees. Caught before boot-wiring, in review of this
RFC's own implementation PR.

Corrected: the walk, the `_build` state read, and the symlink itself all run
inside the guest over `container exec`, as the keeper's own uid:gid (the
owner of everything under its work root — running these as root would leave
root-owned entries inside a tree the keeper's own subsequent `dune build`
needs to modify). One `find | while` script reports every checkout's state
as `<relative path>\t<absent|real|symlink>[\t<target>]`; the host parses
that, decides each plan purely as before, and a second exec runs `ln -sfn`
only for the checkouts whose plan needs one. Only `plan_build_link` and the
pure state/plan types are unchanged from RFC-0399; the walk and the act are
new.

**Recreation trigger — tied to a boundary that already exists, not a new
one.** Two earlier drafts of this section each invented something: first a
proactive size percentage with no fleet measurement behind it
(`forbidden#magic_number`), then a reactive ENOSPC classification. The
second was closer, but adversarial review (against the commit that
introduced it) found it still didn't work: `keeper_disk_pressure.mli` is
observation-only by its own doc comment — *"This module never admits,
delays, pauses, or rejects Keeper work"* — so there was no typed ENOSPC
signal to extend; a build-volume write failing would have reached the host
as an exec's stderr text, and classifying it without matching that string
is exactly `forbidden#string_matching`. Worse, `container volume` has no
attach or detach (checked: `create, delete/rm, list/ls, inspect, prune`
only), so recreating mid-session was never actually possible — any
recreation was always going to mean stopping the guest, which is a boot,
not a hot-swap.

Once that's true, the trigger falls out for free: recreate the build volume
on every fresh `container run`, never on adopting an already-running guest.
`microvm_build_volume` already runs exactly there — the same call site
`microvm_work_volume` uses to keep its own volume *across* restarts, this
RFC's version does the opposite, deliberately. Fresh boot and empty build
volume now coincide by construction. No classification, no lockfile check,
no size threshold, no new module, no gate on keeper turns —
`recreate_apple_build_volume` deletes the volume if present and creates it
again, using the probe already written for `ensure_apple_build_volume`. A
probe failure refuses the boot the same way an absent work volume already
does.

The cost is a cold `dune build` on every guest restart, on however many
GB of the checkout's build graph. Guests are meant to be keeper-lifetime
(RFC-0400: "the guest outlives turns"), so this trades disk for rebuild
time only on the restarts that already happen — crashes, operator resets,
image upgrades — not on anything this RFC introduces.

**What does not move.** `.git`, task files, docs, anything the keeper wrote
by hand — RFC-0400's unified tree ownership stands. Only the directory dune
itself calls derived output moves, and only dune is in scope, matching
RFC-0399's own "Known gaps": npm deletes and recreates its target directory
on every install rather than respecting a symlink (measured there,
`node_modules` would silently leak back onto the share/tree volume), so
`node_modules` is not part of this RFC either. `cargo`/`target` stays
unmeasured, as RFC-0399 left it.

## Scope, as a stack

### A. Reattach the mechanism (implemented, PR #38563)

Not a revert. RFC-0400's deletion commit (`37d26eab2f`, "RFC-0400 C") landed
after `keeper_sandbox_microvm.ml` was already refactored onto a
multi-backend `Keeper_microvm_backend.t` (container/nerdctl/msb), and
roughly fifty commits have deepened that since. Every CLI-effectful
function in the file now carries that backend as an explicit argument,
spelled with a `_for` suffix, matching `ensure_work_volume_for`'s pattern.
Volume provisioning (`build_volume_name`, `apple_build_volume_create_argv`,
`apple_build_volume_probe`, `ensure_apple_build_volume`) was ported this
way, Apple-only per this RFC's backend scope, reusing the already-generic
`classify_volume_probe`/`volume_names_of_json` rather than duplicating
them.

The walk and the link needed more than a signature change. A first pass
ported RFC-0399's host-side `Unix.lstat`/`Sys.readdir`/`Unix.symlink`
directly, which compiled and passed its own unit tests (built against
synthetic host directories) but would have found nothing wired into a real
boot: a `Micro_vm` keeper's tree is `Endpoint_owned`
(`Keeper_types_profile_sandbox.tree_location_of_profile`), so the host has
no filesystem path to the checkouts RFC-0399's walk expected. Caught in
review before boot-wiring, and corrected — see "Design" above. Only
`plan_build_link` and the pure `build_link_state`/`build_link_plan` types
carry over from RFC-0399 unchanged. The walk (`build_scan_argv_for`, one
`find | while` script reporting every checkout's `_build` state) and the
act (`build_link_apply_argv_for`, one `ln -sfn` script for the checkouts
whose plan needs one) are both new, run inside the guest as the keeper's
own uid:gid over `container exec`, and are covered by tests that check
argv/script shape rather than a real filesystem.

No new refusal semantics: a real `_build` directory already found on the
unified volume is left alone and reported, exactly as RFC-0399's
`Link_refused_real_directory` already does. It converts to a link once the
directory is cleared by hand — this RFC never clears one itself, so an
already-bloated pre-existing checkout stays on the unified volume
indefinitely unless an operator moves it, the same posture RFC-0399 took
toward real output from day one. A one-time migration of the fleet's
existing checkouts (`container exec cp -a` style, the same mechanism
RFC-0400's own cutover runbook already used once) would clear this, but
it's a separate, explicit, operator-run action, not something this RFC
does automatically to a keeper's tree.

`MASC_KEEPER_MICROVM_BUILD_VOLUME_SIZE` (default `128g`, RFC-0399's own
default) is reintroduced with the same name RFC-0400 deleted, mirroring
`MASC_KEEPER_MICROVM_WORK_VOLUME_SIZE`'s shape in `Env_config_sandbox`.
Not `forbidden#env_var_sprawl`: that rule is about a new variable
duplicating one that already covers the same value, and this one covers
nothing that exists today — it names the ceiling of a volume kind this RFC
reintroduces, not a second name for the work volume's existing
`..._WORK_VOLUME_SIZE`.

The link refresh (`ensure_microvm_build_links`, implemented in PR #38563's
boot-wiring commit) runs once per guest adoption, not literally every
turn as RFC-0399's original refresh was: `microvm_remote_endpoint` already
memoizes the work-root check the same way
(`mark_microvm_work_root_ready`), and scanning on every tool call inside a
turn would be an exec per call for checkouts that rarely change
mid-session. Stated gap: a checkout the keeper creates after a guest's
first adoption keeps writing to the unified volume until the guest
restarts — bounded by the same restart that already recreates the build
volume (§B), not indefinite.

### B. Recreate on every fresh boot (implemented)

`recreate_apple_build_volume` deletes the build volume if present, then
creates it empty, called from `microvm_build_volume` — which runs only on
a fresh `container run`, never on adopting a guest that is already up, the
same call site `microvm_work_volume` uses to keep *its* volume across
restarts. This RFC's volume does the opposite on purpose: fresh boot and
empty build volume coincide by construction, so every guest restart
(crash, operator reset, image upgrade — not anything new this RFC causes)
is the host-disk reclaim this RFC exists for. No new gate, classification,
lockfile check, or size threshold; `keeper_disk_pressure.ml` is untouched.

### C. Verification

- Unit (landed): `test_keeper_sandbox_microvm` — 8 tests for the guest-exec
  scan/plan/apply (argv and script shape, not a real filesystem — the walk
  and link now run inside a guest this test suite doesn't boot), 1 for the
  delete argv, plus the RFC-0399-derived pure `plan_build_link`/
  `build_link_target` cases. 75 tests total, all passing, no regression.
- Missing (open, tracked as this RFC's remaining acceptance gap): a
  `MASC_MICROVM_LIVE=1` test that boots a real Apple guest, confirms the
  build volume is mounted at `/masc-build`, writes past its declared size
  to confirm the guest sees ENOSPC rather than something stranger, restarts
  the guest, and confirms both that the volume's host size dropped back
  down and that the checkout (`git status`, task files) survived untouched.
  Nothing in this RFC's acceptance has run against a live guest yet.

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

**ENOSPC-reactive recreation** (an earlier draft of this RFC). Checked
against what exists rather than assumed: `keeper_disk_pressure.ml` is
observation-only (no admission gate ever landed — RFC-0122's own progress
audit marks that phase absent), so there was no typed ENOSPC signal to
attach to; building one would have meant classifying a build-volume
failure from an exec's stderr text, which is `forbidden#string_matching`.
Moot regardless: `container volume` has no attach or detach, so recreating
a volume under a *running* guest was never possible — any recreation was
always a guest restart. §B ties recreation to the restart boundary that
already exists instead of inventing a detection mechanism to justify one
that doesn't.

## Open questions

1. ~~Ceiling and probe interval defaults~~ — moot. There is no probe, no
   ceiling check, and no percentage: recreation is tied to the fresh-boot
   boundary, not to a measured or guessed size.
2. ~~ENOSPC/idle-detection precision~~ — moot for the same reason: nothing
   classifies a live failure, so a build tool's lockfile shape (dune's
   `_build/.lock`, or the lack of one for another tool) never enters the
   decision.
3. **Is a cold build on every restart an acceptable cost long-term?**
   Restarts are meant to be rare (RFC-0400: guests are keeper-lifetime), so
   this RFC accepts the cost rather than design against it. If restart
   frequency turns out higher than assumed — unmeasured here — the cost
   compounds, and that would be grounds for a follow-up, not for this RFC
   guessing a mitigation now.

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
- **Deleting the build volume on keeper purge/decommission.** Checked, not
  assumed: `git grep` for a `container volume` delete call across `lib/`
  returns zero hits today — the work volume is not explicitly deleted on
  purge either. It relies on `container volume prune`, which removes any
  volume with no container reference, run either manually or on whatever
  cadence an operator chooses (measured this session: 6 orphaned volumes,
  147 GB, reclaimed by one `container volume prune` call). The build volume
  is the same kind of object as the work volume to that command, so it is
  swept the same way once its container is gone; no new cleanup path is
  added by this RFC, and none is needed.

## Number allocation note

Allocated as RFC-0468. `docs/rfc/` highest present number was 0467 at
allocation time (0466 absent — reserved against reuse per README policy,
same convention RFC-0122 §8 documents).
