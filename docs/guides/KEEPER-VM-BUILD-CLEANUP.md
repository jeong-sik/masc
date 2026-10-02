# Keeper VM build cleanup

Apple Keeper work volumes persist between boots. Default `_build` directories
in older checkouts therefore accumulate even though `/masc-build` is recreated
at boot. Clean generated output separately from source/worktree removal.

From the MASC checkout, inspect and clean the selected runtime workspace:

```bash
python3 scripts/cleanup-keeper-vm-builds.py --base-path /path/to/workspace
python3 scripts/cleanup-keeper-vm-builds.py --base-path /path/to/workspace --apply
```

The default requires every entry in a build tree to have remained unmodified
for 24 hours. For an operator-requested immediate cleanup, use `--idle-hours 0`.
Both modes skip a checkout used by a live process, a held wrapper lock, symlinked
`_build` directories, and checkouts containing `.masc-keep-build`. Put durable
release/test evidence outside `_build`, or add that retention marker.

The guest needs Python 3 and Dune 3.24 or newer (targeted `dune clean`). Guests
without Dune are reported as skipped. Only running VMs with matching workspace,
Keeper sandbox and Apple backend labels are selected. Sources, worktrees, images,
volumes, package caches and Keeper memory are retained. A failed process scan
does not authorize cleanup. Dune's native nonblocking lock protects cleanup
against newly starting builds; targeted cleaning retains the lock inode and
avoids whole-project clean's removal of promoted source files.

## Automatic sweeps

```bash
python3 scripts/keeper-vm-cleaner.py start --base-path /path/to/workspace
python3 scripts/keeper-vm-cleaner.py status --base-path /path/to/workspace
python3 scripts/keeper-vm-cleaner.py stop --base-path /path/to/workspace
```

`start` immediately sweeps, then repeats every hour, using the same 24-hour
retention. Set `--idle-hours` and `--interval-seconds` on `start` to change those
settings; stop an existing service before changing its configuration. Duplicate
starts leave the existing service running. Stop requests finish the current
sweep before exiting and never signal a PID from a stale file.

State and the latest sweep/error reports are bounded files under
`<base-path>/.masc/maintenance/keeper-vm-cleaner/`. `config.json` identifies the
running script and policy. `last-sweep.json` reports each cleaned/skipped build
and **guest** free-space changes. `status` reports process existence, not whether
the last sweep succeeded; inspect both report files for failures.

Keep the checkout containing both scripts available while the service runs. To
run independently of a temporary PR worktree, copy both reviewed scripts into
the maintenance directory's `bin/` and invoke that copy. This is a background
process, not an OS startup service; restart it explicitly after a host reboot.

## Guest space versus host disk space

Volumes mounted without ext4 discard retain deleted blocks in their sparse
host images. Keeper guests have no `CAP_SYS_ADMIN`, so live `fstrim` fails.
At the safe boot boundary MASC's isolated helper now enables ext4's persistent
default `discard` option and trims existing free blocks,
after removing the previous guest and before mounting the work volume again
(`keeper_turn_sandbox_runtime.ml`, `reclaim_work_volume_space`). Subsequent guest
deletes return their blocks automatically, without extra guest capabilities.
Existing running guests take the default on their next safe volume mount;
merging a change does not change their active mount. This cleaner
does not stop a Keeper or mount its live volume in a second VM to force trimming.

The helper image needs `/usr/bin/findmnt`, `/usr/sbin/tune2fs`, and
`/usr/sbin/fstrim`. A missing utility reports a reclaim failure; existing runtime
policy permits boot only after helper removal has been confirmed.

Source contracts: [ext4 persistent discard default](https://kernel.org/doc/html/next/filesystems/ext4/super.html),
[tune2fs defaults](https://man7.org/linux/man-pages/man8/tune2fs.8.html),
[Dune targeted clean and native lock](https://github.com/ocaml/dune/blob/3.24.2/bin/clean.ml),
[Dune lock implementation](https://github.com/ocaml/dune/blob/3.24.2/otherlibs/stdune/src/global_lock.ml),
[Apple volume mounts](https://github.com/apple/container/blob/main/docs/volumes.md).
Confirmed against the installed CLI and a real Dune 3.24.2 Keeper guest on
2026-10-02. Guest capacity recovered by cleanup is not host capacity recovered
by trimming.

## Focused verification

`python3 test/test_keeper_vm_build_cleanup.py -v` checks start, duplicate start,
stop and restart using a fake container inventory. In a Linux guest with Dune,
the same suite additionally checks native/wrapper locks, recent output retention,
symlink/operator retention, source preservation and fail-closed inspection.
