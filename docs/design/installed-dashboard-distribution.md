# Installed binary and dashboard distribution

The release ships a binary and `masc-dashboard-<arch>.tar.gz` from the same source
commit, alongside `masc-release-dashboard-bundle-<arch>.py`. The installer verifies
release checksums before running this helper. Python 3 is now an explicit installer
prerequisite; a downloaded standalone `install.sh` does not need a checkout.

The archive's `release.json` uses `masc.installed-release.v1`:

- `source_commit`: the source commit supplied by the release job and checked against
  the binary's `build-commit` command;
- `binary_asset`, `binary_sha256`: the exact advertised server binary;
- `files`: dashboard-relative `path`, `sha256`, `size`, and original build `mtime`.

The archive contains only that receipt and the declared `dashboard/<path>` regular
files. The installer rejects traversal, absolute paths, links, special files,
duplicate members/JSON fields, undeclared members, wrong digests, wrong platform
asset names, and a binary with a different embedded commit. It preserves the real
`.build-stamp` contents and mtime; installation never marks an old build fresh.

Installation layout, relative to the chosen binary prefix:

```
masc -> .masc-releases/<receipt-sha256>/masc
.masc-releases/<receipt-sha256>/
  masc
  release.json
  assets/dashboard/...
```

The release directory is verified before publication and previous releases remain
in place. An atomic rename changes the `masc` pointer. A private
`.masc-install-transaction` retains the previous regular file or symlink until
seeding, wizard, and binary smoke checks complete. Failure rolls the pointer back.
A process crash can leave the transaction for explicit `commit` or `rollback` with
the verified helper; a new install refuses to overwrite that unfinished transaction.
Companion binaries and user config seeding retain their existing installer behavior;
the transaction covers the server binary/dashboard pair.

## Current runtime boundary

This first unit ships and installs the pair and prints start commands containing
`MASC_ASSETS_DIR=<installed-release>/assets`. Install smoke uses that explicit setting,
starts the actual installed binary outside the checkout, and verifies served index
and referenced asset digests, embedded commit, executable path, and dashboard health.

It does **not** add implicit installed-receipt discovery to the server. Bare
`masc start` or a TUI launch without that explicit setting still uses the current
unbound asset resolver. That resolver and its cwd/repository inference must be
replaced in a following unit. This change alone does not close the original runtime
recurrence.

Installed release metadata is not the run-local source snapshot contract. Do not
invent source-root device/inode values to pass `Build_identity`: installed assets
need their own typed binding, validated against the running binary at startup and
kept stable across later pointer replacements. Missing or mismatched receipts must
remain explicit failures; a source checkout or a touched timestamp is not a fallback
proof.

## Verification

`python3 test/test_release_dashboard_bundle.py -v` exercises packaging, actual
installer downloads from an offline mirror, source removal, idempotent reinstall,
rollback of regular files and symlinks, injected publication failure, later smoke
failure, wrong binary/source commit, and hostile tar entries using a test executable.
It does not compile OCaml or build a dashboard. Release CI's `install-smoke.sh`
performs the corresponding checks with the actual release binary and production
bundle. The existing OCaml installer fixture also stages the new release artifacts.
