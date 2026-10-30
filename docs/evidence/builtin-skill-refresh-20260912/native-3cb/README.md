# Native builtin Skill refresh CLI evidence

Source: `3cb88d90afcb6cf1d2a310155df3483ab7db6e05`.
[Native run 34697765942](https://github.com/jeong-sik/masc/actions/runs/34697765942)
was completed successfully before downloading. After download finished, `unpack.py`
verified `SOURCE_COMMIT` and every distribution entry in `artifact-SHA256SUMS`
before extracting the isolated runtime. The executed macOS arm64 binary SHA-256:
`52b5662a5bc179a4d2105198a681caf97462fef5546174945f22793339f25133`.

`proof.json` preserves full arguments, scratch paths, stdout, stderr and exit codes
for **nine actual CLI executions**:

1. Config-only init creates runtime config without a Skills directory.
2. Skills-only init publishes the browser-lanes package.
3. Inspection records both reviewed revisions before a hard-link change.
4. Automatic init preserves the linked resource and installation receipt.
5. Explicit apply with the pre-link reviewed revisions rejects the linked resource.
6. Config-only followed by skills-only flags is rejected before workspace creation.
7. Reversed flag order is also rejected before workspace creation.
8. A directory occupying the receipt preserves it and prevents package publication.
9. A symlink occupying the receipt preserves it and its target, without publication.

The probe also asserts unchanged linked inode/receipt and external receipt target
contents. These filesystem assertions passed; the script exited zero. All work
used newly created scratch directories. No user binary was replaced and no live
service, Keeper or browser session was started or changed.

## Reproduction

`probe.py` is the exact executed script. It expects the extracted runtime at the
path below and creates a fresh temporary workspace for every execution. It does
not perform an install or contact a live MASC service.

```sh
gh run download 34697765942 --repo jeong-sik/masc --dir /tmp/skill-refresh-native-3cb
python3 unpack.py /tmp/skill-refresh-native-3cb 3cb88d90afcb6cf1d2a310155df3483ab7db6e05
python3 probe.py
```

Wait for download completion before unpacking. A repeat run prints its own new
proof path; it does not replace this recorded proof.

## Limits and separate installer evidence

The installer ordering regression is a separate Python harness in
`test/test_installer_upgrade.py`: it executes extracted installer sections with
a fake init executable and a fake bundle commit helper. Its six tests passed
locally during implementation. It checks config/Skill separation, pre-commit
failure behavior and diagnostic retention. This is **not** a complete installer
execution, a real bundle rollback experiment, or power-loss/crash durability proof.
The native CLI probe does not inject fsync failure. The OCaml package tests
contain the parent-sync failure injection and hard-link feature regressions;
those tests are distinct from these nine CLI executions.

At the single finishing-boundary check, focused Test run
[34697763531](https://github.com/jeong-sik/masc/actions/runs/34697763531)
was still `in_progress` at this source commit. No completed test counts or final
CI verdict are claimed here.

`SHA256SUMS` hashes the evidence files in this directory; `artifact-SHA256SUMS`
is the original downloaded distribution manifest, whose paths refer to artifacts.
