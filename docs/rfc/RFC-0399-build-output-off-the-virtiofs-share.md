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

All of it, including the call site:

- naming and argv: `build_volume_guest_root`, `build_volume_name`,
  `build_volume_create_argv`, `build_volume_mount_args`
- addressing: `build_link_target` with its two refusals
- planning: `plan_build_link` over
  `Build_absent | Build_symlink | Build_real_directory`
- provisioning: `volume_names_of_json`, `classify_volume_probe`,
  `volume_probe`, `ensure_build_volume`
- discovery and application: `build_roots_under`, `playground_relative`,
  `ensure_build_links`, `build_target_mkdir_argv`
- the gate and the per-turn refresh in `keeper_turn_sandbox_runtime.ml`

`container volume create` is not idempotent — a second call errors with
"already exists" — so existence is settled by a probe, not by reading that
message. The probe does not trust `container volume inspect`'s exit 1 either:
that code covers "no such volume" together with a stopped container system,
and creating over an existing volume would land on a keeper's build cache. A 1
is confirmed against `container volume list --format json`, mirroring
`classify_image_probe`. Every ambiguous outcome is `Volume_probe_failed`, never
`Volume_absent`.

A guest that cannot get its volume does not start. This follows `image_present`
in the same lane, and the reason is the panic: falling back means writing build
output onto the share, which is what pinned the vnode table three times. A
keeper that does not start is a smaller failure than a machine that stops.

### What the acceptance run changed

The design as first written did not work, and running it is what said so:

```
Error: open(_build/.lock): No such file or directory
```

dune does not create the directory a `_build` symlink points at. It lstats
`_build`, sees the link, and opens `_build/.lock` straight away. The host
cannot create the target either — it lives inside the volume's ext4 image. So
the guest does, through `build_target_mkdir_argv`: one `container exec
mkdir -p` covering every target rather than one per checkout, idempotent, and
repeated each turn so a recreated volume repairs itself.

The links are refreshed per turn rather than once per guest, because a keeper
clones repositories and adds worktrees while its guest is already up. A
boot-only pass would leave every checkout made after boot writing to the share.
The two halves run on opposite sides of the boundary — the symlink on the host
where the checkout lives, the directory in the guest where the volume is — so
the refresh runs after the guest is confirmed up, not before.

## Verification

`test/test_keeper_sandbox_microvm.exe` — 44 tests, 21 new. The ones that
matter:

- `plan never deletes real build output` — a real `_build` is reported and left
  alone, and the test asserts the directory still exists afterwards.
- `ambiguity is never read as absence` — four ways the probe can be unsure,
  none of which become "create it".
- `does not follow symlinks` — a link back to the playground root would loop a
  walk built on `stat`; this one uses `lstat`.
- `mkdir is one exec for every target` — not one per checkout.

### Acceptance, measured

Run in a live guest (`masc-keeper-sandbox:local`, container 1.3.1, dune
3.24.2), same 120-module project built twice — once with `_build` on the
share, once linked onto the volume:

| | host fds | `_build` on |
|---|---|---|
| baseline | 25 | — |
| `dune build`, `_build` on virtiofs | +137 | share |
| `dune build`, `_build` linked to the volume | +100 | `/dev/vdc` (ext4) |

The output landed on the volume (`/masc-build/linked/default/m.exe`, `df`
showing the image growing), which is the part that had to be proven end to
end. The remaining +100 is the 123 **source** files, which stay on the share by
design and are bounded by the checkout.

That ratio is what this is for. In this toy the build emits 24 files against
123 sources, so the two columns look close. On the real thing they do not:
masc is 10,543 tracked files and a full `_build` measured at 53,771 — five
times the source tree, growing with every build, and none of it read by the
host.

The mechanism itself was measured separately and cleanly, with both mounts on
one container and 20,000 files written to each: virtiofs 26 → 20,027 host
descriptors, ext4 volume 26 → 26, `_build` symlinked onto the volume 59 → 61.

### Where this sits against common practice

Splitting a container's source (bind mount) from its build and dependency
directories (named volume) is the documented recommendation on macOS, not
something invented here. VS Code's dev container performance guide names it
directly — a named volume "is ideal for storing package folders like
`node_modules`, data folders, or output folders like `build`" — and the same
split is standard advice for `node_modules`, `target` and `vendor`.

One difference is worth stating, because it avoids a known failure. The common
form mounts the volume *inside* the bind mount, at `<workspace>/node_modules`.
On Docker for Mac, touching that path from the host silently unmounts the
volume in the container (docker/for-mac#3976). This design cannot hit that: the
volume is mounted at its own top-level path and reached through a symlink, so
there is no submount to lose. That was not a choice made for safety — checkout
paths here are created by the keeper at runtime and are not known when the
guest starts, so a fixed submount was never available — but it is the safer
shape either way.

## Known gaps

`_build` is dune's name and dune's alone. Other ecosystems pin host descriptors
the same way through `node_modules`, `target` or `dist`, and are not handled.

An earlier draft of this section said the mechanism carries over unchanged and
only the marker file and directory name differ. **That is measured false for
npm**, and the correction is worth more than the original claim.

The two tools treat their output directory in opposite ways:

| | what it does with an existing `_build` / `node_modules` |
|---|---|
| dune | `lstat`s it, and if something is there, uses it. A symlink is followed. |
| npm | rebuilds it as its own. A symlink is **deleted and replaced with a real directory**. |

Measured in a live guest (node 22.23.2, npm 10.9.8), installing one dependency
into a `node_modules` symlinked onto the volume:

```
before   node_modules -> /masc-build/nm2   (symlink)
after    drwxr-xr-x    node_modules        (real directory)

files written to the volume   0
files written to the share    1055
```

One dependency is 1,055 files. masc's own `dashboard/package.json` would be
tens of thousands, on the share, exactly as before.

So adding `("package.json", "node_modules")` to a list of pairs would compile,
log "link installed" every turn, and leak the whole time: the link is
reinstalled each turn and npm removes it on each install. A silent no-op is
worse than an admitted gap, which is why this is written down rather than
attempted.

`cargo` is untested — the guest carries no Rust toolchain — so `target` is
unknown rather than known-broken. Whatever covers npm has to be a different
mechanism than a symlink, and it needs the same measurement before it lands.

masc's own repository is where this bites: `<checkout>/dashboard/package.json`
and `<checkout>/viewer/Cargo.toml` sit inside every keeper checkout, so a
keeper working on the dashboard reopens the leak this RFC closed for dune.
Currently zero such directories exist in any playground, so the exposure is
latent rather than active.

The volume size is a ceiling, not an allocation — the image is sparse, 4 GiB
nominal measured at 84 MB on disk — but a build that exceeds it fails inside
the guest with ENOSPC. The default of 128 GiB is set against a measurement: one
keeper's playground held three 29 GB `_build` directories, 87 GB together.
