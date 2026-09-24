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

**Recreation trigger.** Not a cumulative counter inside keeper control flow —
`forbidden#budget_gate` rules that out, and it would be the wrong shape
regardless: the keeper never sees this volume, so there's no keeper behavior
to gate. This is host-side fleet maintenance, the same category as the
already-existing periodic janitor (`MASC_JANITOR_INTERVAL_SEC`,
`MASC_KEEPER_SANDBOX_CLEANUP_INTERVAL_SEC` — see
`docs/research/2026-08-30-oneclick-periodic-docker-janitor-linux-runtime-r1.md`)
extended with one more typed check:

- probe each `masc-keeper-build-<name>` volume's real host size (`du`, cheap
  — these are single-file images, not tree walks);
- above a configured ceiling (default TBD from a live measurement pass, not
  guessed — see Open questions), and only when the guest confirms no build is
  in flight (a lockfile check, `_build/.lock` — dune already uses this path
  for its own concurrency, RFC-0399's acceptance run hit it directly), stop
  the guest's use of that one volume, delete it, recreate it empty, refresh
  the symlink. The keeper's next build starts cold; nothing else about its
  session changes.
- this is a resource/safety boundary (disk exhaustion, same family as
  RFC-0122's disk-pressure circuit breaker), not a budget gate on keeper
  turns — the constitution's own carve-out for `budget_gate` names exactly
  this category as exempt.

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

Restore `build_volume_guest_root`, `build_volume_name`,
`build_volume_create_argv`, `build_volume_mount_args`, `build_link_target`,
`plan_build_link`, `volume_names_of_json`, `classify_volume_probe`,
`volume_probe`, `ensure_build_volume`, `build_roots_under`,
`playground_relative`, `ensure_build_links`, `build_target_mkdir_argv` —
against RFC-0400's guest layout (`/masc-work/<keeper>/...`, not RFC-0399's
virtiofs playground path). The provisioning-not-idempotent handling
(`container volume create` errors on a second call; existence settled by
`container volume list --format json`, never by reading exit codes) carries
over unchanged; it was general, not virtiofs-specific.

No new refusal semantics: a real `_build` directory already found on the
unified volume (pre-existing keepers, mid-flight at cutover) is left alone
and reported, exactly as RFC-0399's `Link_refused_real_directory` already
does. It converts to a link on a later turn once emptied, same as before.

### B. Recreation policy

The periodic janitor gains one more typed check, `Build_volume_oversized of
{ name; measured_bytes; ceiling_bytes }`, alongside its existing stale-Docker-
container sweep. Default ceiling and probe interval: measured, not assumed —
see Open questions. `_build/.lock` presence gates the destructive step the
same way it already gates dune's own concurrent builds; a locked volume is
skipped this cycle, not forced.

### C. Verification

- Unit: extend `test_keeper_sandbox_microvm` with RFC-0399's original suites
  ported to the RFC-0400 guest layout (44 tests existed; the ones proving
  "never deletes real output" and "does not follow symlinks" are the ones
  that matter most here, since this RFC pairs mechanism reuse with a new
  destructive step that must inherit those guarantees).
- New: `Build_volume_oversized` detection against a stubbed `du` output; the
  lockfile skip; recreation leaves the symlink and mountpoint intact from the
  keeper's perspective (a `dune build` issued immediately after recreation
  succeeds without the keeper doing anything).
- Live: one keeper's build volume artificially grown past the ceiling,
  janitor tick observed to recreate it, guest confirms the checkout is
  untouched (`git status` clean, task files present) and the next `dune
  build` succeeds cold.

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

1. **Ceiling and probe interval defaults.** RFC-0399 picked 128 GiB against
   a three-checkout, 87 GB measurement on one keeper. This RFC needs its own
   pass across the current fleet's `masc-keeper-build-<name>` sizes once A
   ships, before B's default is set — guessing a number here would be
   exactly the `forbidden#magic_number` pattern the constitution rules out
   ("암묵적 판단 기준이 아니라 선명한 기준으로"). Tentative: recreate at the
   size where `du` shows the volume passing 80% of RFC-0399's own 128 GiB
   ceiling, so the guest never actually hits ENOSPC in normal operation, but
   pending measurement, not committed.
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
