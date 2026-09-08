# Real Kata volume proof — 2026-09-08

[Run 34185910616](https://github.com/jeong-sik/masc/actions/runs/34185910616)
passed on source `f30f21d7299cf89cd7ecc0cb71ebea788953c0a3`.
The workflow artifact preserves the image pin, native container metadata,
runtime versions and daemon log. This runs the shell volume proof with a Debian
image, not an installed MASC Keeper or the MASC general image.

The Ubuntu 24.04 x64 runner exposed working KVM. nerdctl 2.3.5 with Kata 4.1.0
booted guests using `io.containerd.kata.v2`, network `none`, a read-only rootfs,
no capabilities and a writable `/tmp`. A guest running as UID/GID 60123 wrote
the named volume; after removing that guest, a new guest read the same bytes.
A root-user write to `/` was refused, so the rootfs check did not merely test
ordinary non-root permissions.

Measured log excerpts:

```text
before: 700 0:0 /masc-work
prepared: 711 0:0 /masc-work
prepared: 777 0:0 /masc-work/keeper
guest: 711 0:0 /masc-work
guest: 777 0:0 /masc-work/keeper
PASS: Kata managed volume survives guest recreation; uid, caps, rootfs and scratch checks passed
```

The original run failed image lookup despite a successful digest-pinned pull.
Native inspection fixed that lookup. The next run exposed a root-owned `0700`
volume directory blocking the Keeper UID. Adding only search permission to the
mounted root resolved it; rootfs writability and capability restrictions remained.
MASC now applies this preparation after checking the actual guest mount.

This proves the runtime's storage and isolation behavior. It does not establish
installed Keeper admission, MASC tool dispatch, ARM64 Kata operation, policy
networking, resource capacity enforcement or long-running continuity.
