---
rfc: "0399"
status: Draft
---

# RFC-0399 — Build output leaves the virtiofs share

- Status: Draft
- Decision driver: three kernel panics in three days on the host running keepers (2026-08-30 ~03:10, 08-31 ~13:47, 09-01 16:57), all `initproc exited -- exit reason namespace 2 subcode 0xa` — launchd killed by SIGBUS. The 09-01 panic has the cause in the log 27 ms before it: `vnode: table is full` / `263168 desired, 263168 numvnodes, 0 free, 0 dead, 0 async, 0 rage`, then 289 `apfs_load_inode_internal ... failed to vnode_create` in two seconds. The keeper playground held 358,795 `_build` files on a virtiofs share against a 263,168-entry vnode table.
- Area: `lib/keeper/keeper_sandbox_microvm.ml` (+ `.mli`), the guest start path in `lib/keeper/keeper_turn_sandbox_runtime.ml`, `test/test_keeper_sandbox_microvm.ml`.

## Problem (measured)

Apple's virtiofs opens an `O_PATH` file descriptor on the host for every inode
the guest touches and closes it only on `FUSE_FORGET`, which arrives when the
guest kernel evicts the dentry. A host descriptor pins a host vnode.

The two limits are not the same size, which is why nothing looked wrong:

```
kern.maxfiles   491,520   ← 8% used at the panic
kern.maxvnodes  263,168   ← 100% used, 0 reclaimable
```

When the vnode table fills with nothing reclaimable, `vnode_create` fails.
File-backed page faults then become SIGBUS — including faults on the dyld
shared cache, which every `exec` needs. The panic log shows the spread:
launchd's own worker threads are named `ReportCrash throttled after SIGBUS`
(twice), `contactsd throttled after exit()`, `distnoted.xpc.agent throttled`.
The crash reporter died of the same fault it was spawned to record, which is
why no per-process crash reports survive. First warning to panic: 1.7 seconds.

Measured on the host, 2026-09-01:

| keeper checkout | `_build` files |
|---|---|
| `polisher/masc-t362` | 61,602 |
| `polisher/masc-t371` | 55,808 |
| `polisher/masc-t1067` | 54,113 |
| `lane-smith/repos/masc-main-fresh` | 55,276 |
| (five more) | 131,996 |
| **total** | **358,795** |

`polisher/masc-t362` alone is 29 GB, of which `.git` is 88 MB. The checkout is
99.7% derived output. Nothing on the host reads it — the host-side readers
under `Playground_paths` read sources.

## What was measured, not assumed

Same container, a virtiofs bind mount and an ext4 volume attached at once,
writing 20,000 files and counting host descriptors on the VM process
(macOS 26.6.1 / M3 Max, container CLI 1.3.1):

| storage | host fds |
|---|---|
| ext4 volume (`/dev/vdc`, `format: ext4`, one `volume.img`) | 26 → **26** |
| virtiofs bind mount | 26 → **20,027** |
| `_build` symlinked onto the ext4 volume | 59 → **61** |

20,000 files, +20,001 descriptors: one per inode, exactly. The guest mount
table confirms the mechanism — `virtiofs on /vfs type virtiofs` versus
`/dev/vdc on /blk type ext4`. A block device has no FUSE layer to hold paths.

## Alternatives, and why they are not this

**Raise `kern.maxvnodes`.** Moves the wall. 358,795 `_build` files already
exceed 263,168, and the leak is unbounded in the number of files a keeper
builds. Workaround-bar item 5.

**Reclaim without restarting the guest.** `echo 2 > /proc/sys/vm/drop_caches`
would force `FUSE_FORGET`. Denied under `--cap-drop ALL` (measured). Deleting
the tree does release them (20,027 → 59), but that is the cache the directory
exists to hold.

**Recycle guests on a threshold.** This exists today as
`scripts/masc-microvm-fd-recycle.sh` in the operator's repo and is labelled
`WORKAROUND:` there. It restarts VMs to reclaim; it does not stop the pinning.
This RFC is its removal target.

**Upgrade `container`.** 1.3.1 is current; no release note mentions virtiofs
descriptors.

**`DUNE_BUILD_DIR`.** An absolute value is shared by every checkout in the
playground, so two builds write the same directory. A relative value escaping
the workspace is refused by dune — "path outside the workspace", measured on
3.24.1. It is also dune-specific, and `_build` is written by more than dune.

## Design

One ext4 volume per keeper, mounted in the guest at `/masc-build`; each
checkout's `_build` is a symlink into it.

```
host                                        guest
.masc/playground/microvm/polisher/          /home/keeper/playground/
  masc-t362/                                  masc-t362/
    lib/ test/ .git/      ── virtiofs ──▶       lib/ test/ .git/
    _build ─→ /masc-build/masc-t362             _build ─┐
                                                        ▼
volumes/masc-keeper-build-polisher/         /masc-build/masc-t362/
  volume.img (ext4, sparse) ── virtio-blk ──▶   (one host fd for the whole image)
```

The link is created on the host and points at a guest path, so it dangles when
read from macOS. That is intended: the host never builds.

Volume images are sparse — 4 GiB nominal measured at 84 MB on disk — so the
size argument is a ceiling, not an allocation.

The link target flattens the playground-relative path with `:`
(`repos/wt-370` → `/masc-build/repos:wt-370`). Nesting would need parent
directories the guest cannot `mkdir -p` through a dangling symlink and the
host cannot create inside a disk image. A path segment already containing `:`
is refused rather than allowed to collide two checkouts onto one build
directory.

A real `_build` directory is never deleted to install a link. It holds output
this code did not create; the plan reports `Link_refused_real_directory` and
the checkout stays on virtiofs. Retargeting a stale *symlink* is different —
removing a symlink loses no data.

## Scope of this change

Landed here — everything except the call site:

- naming and argv: `build_volume_guest_root`, `build_volume_name`,
  `build_volume_create_argv`, `build_volume_mount_args`
- addressing: `build_link_target` with its two refusals
- planning: `plan_build_link` over
  `Build_absent | Build_symlink | Build_real_directory`
- provisioning: `volume_names_of_json`, `classify_volume_probe`,
  `volume_probe`, `ensure_build_volume`
- applying: `build_link_state_of_path`, `apply_build_link`

`container volume create` is not idempotent — a second call errors with
"already exists" — so existence is settled by a probe, not by reading that
message. The probe does not trust `container volume inspect`'s exit 1 either:
that code covers "no such volume" together with a stopped container system,
and creating over an existing volume would land on a keeper's build cache. A 1
is confirmed against `container volume list --format json`, mirroring
`classify_image_probe`. Every ambiguous outcome is `Volume_probe_failed`, never
`Volume_absent`.

Deliberately not here: the call site. Threading the volume through
`keeper_turn_sandbox_runtime.ml` — provisioning next to the existing
`image_present` gate, adding the mount, and walking the playground to apply
plans — changes the path live keepers boot through, and its acceptance is a
live measurement rather than a unit test. It lands as the next stack.

The gate's shape is decided, though, and follows the precedent in the same
module: a missing image returns `microvm_image_missing` and refuses to start
the guest. A build volume that cannot be established does the same rather than
falling back to the leaking layout, because the failure that fallback invites
is a host panic.

## Verification

`test/test_keeper_sandbox_microvm.exe` — 37 tests, 14 new. The two that matter:

- `plan never deletes real build output` — a real `_build` is reported and left
  alone, and the test asserts the directory still exists afterwards.
- `ambiguity is never read as absence` — four ways the probe can be unsure, none
  of which become "create it".

Acceptance for the call site, when it lands: run a full `dune build` in a
microvm keeper checkout and show the VM process's host descriptor count flat
across it. Measured today on a keeper mid-build, that count moved from 31 to
33,295 in twenty minutes — about one per file written, and roughly 100k/hour
against a table of 263,168.
