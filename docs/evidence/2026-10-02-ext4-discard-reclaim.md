# Apple work-volume discard experiment

Confirmed on 2026-10-02 with Apple container 1.3.1 and cached
`masc-sandbox-ocaml:20260928T0216Z-c48e1e05` (e2fsprogs 1.47.0).
These are isolated real VMs, not an installed patched MASC binary.

Each case created its own 1 GiB named ext4 volume. A network-disabled,
read-only helper with only CAP_SYS_ADMIN resolved the mounted device using
findmnt, set the default using tune2fs, and ran fstrim. The helper exited
before a read-only, network-disabled guest with **all capabilities dropped**
mounted the volume. That guest wrote 64 MiB of random data, synced, deleted
the file, and synced again. Host allocation is `stat.st_blocks * 512` of the
volume image; no privileged trim ran during either write/delete measurement.
Both temporary guests and volumes were removed after their measurements.

| Default | Before write | After write | After delete | Host bytes returned |
|---|---:|---:|---:|---:|
| `discard` | 2,187,264 | 69,308,416 | 2,203,648 | 67,104,768 |
| `^discard` | 2,187,264 | 69,312,512 | 69,312,512 | 0 |

Setup script for the positive case (negative changes `discard` to `^discard`):

```sh
work_device=$(/usr/bin/findmnt --noheadings --output SOURCE --target /masc-trim)
/usr/sbin/tune2fs -o discard "$work_device"
/usr/sbin/fstrim -v /masc-trim
```

The result demonstrates that the persistent default survives the helper's
unmount and returns blocks from a later unprivileged guest. It does not
measure production latency or an installed patched server. `findmnt -o OPTIONS`
reported `rw,relatime` even in the positive case: that output alone is not
evidence that the ext4 superblock default is absent or present.

OCaml parser and formatter checks passed for the changed source and existing
argv safety test. The full linked OCaml test executable was not built or run
in this external coding session. Existing helper cleanup/cancellation logic
is unchanged and requires helper absence before a Keeper volume mount.

Official contracts: [kernel superblock default discard](https://kernel.org/doc/html/next/filesystems/ext4/super.html)
and [tune2fs default mount options](https://man7.org/linux/man-pages/man8/tune2fs.8.html).
