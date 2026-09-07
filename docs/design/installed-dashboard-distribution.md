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

## Runtime authority

Before server fibers start, `Installed_dashboard` selects the canonical executable
path captured by `Build_identity`. A binary in `.masc-releases/<receipt-sha256>/`
selects installed authority even when its receipt is missing or invalid. The
receipt SHA must match its directory, its source commit must match the embedded
binary commit, and its binary and every declared asset must match their SHA-256.
Strict parsing rejects unknown or duplicate fields, unsafe paths, and missing
index/stamp entries. Receipt timestamps must be representable in Ptime's civil-time
range before health may render RFC3339. Owned exact reads reject symlinked files or parent components.

The selected release root is frozen for the process lifetime. Replacing the
installer's `masc` pointer does not redirect an already running process. Each asset
read verifies the retained root/binary identity, receipt digest, and requested
asset size/digest; unavailable and unmanifested files return 503 and 404
respectively. A changed selected binding never falls back to `MASC_ASSETS_DIR`,
process cwd, or an inferred repository. An explicit source-provenance launch
retains its existing source binding authority and validation: both valid and invalid
source bindings take precedence over installed selection. The no-fallback installed
rule applies when source authority is `Unbound`. Startup checks the retained
receipt/root/binary once around the full asset scan, avoiding repeated full-receipt
reads for every asset; individual requests retain their before/after guards.

`dashboard_surface.installed_release` carries installed receipt/source/binary
identity or a typed unavailable error. This is distribution evidence, independent
of `Build_identity`'s run-local source-root inode provenance. No checkout inode,
build input tree, or source-build timestamp is invented. Freshness for a verified
installed release means the receipt matches the executable and served bytes;
installation does not touch `.build-stamp` to pass an mtime comparison. Unbound
developer binaries keep their existing asset resolver and mtime diagnostics.

`masc start` and the TUI's server child both enter this initialization path. The
installer's printed explicit asset setting is redundant for this installed format;
install smoke removes that environment variable to exercise automatic discovery.

## Verification

`python3 test/test_release_dashboard_bundle.py -v` exercises packaging, actual
installer downloads from an offline mirror, source removal, idempotent reinstall,
rollback of regular files and symlinks, injected publication failure, later smoke
failure, wrong binary/source commit, and hostile tar entries using a test executable.
It does not compile OCaml or build a dashboard. Release CI's `install-smoke.sh`
performs the corresponding checks with the actual release binary and production
bundle. The existing OCaml installer fixture also stages the new release artifacts.

`test_installed_dashboard` covers process-stable pointer selection, missing/changed
receipts, unsafe paths and duplicate fields, binary commit/hash/replacement,
symlinked/corrupt assets, and unmanifested requests. Actual-binary install smoke
starts outside the checkout without an assets override, checks served bytes and
installed evidence, then verifies HTTP 503/unavailable on index corruption and
receipt removal despite a conflicting cwd asset directory. These OCaml/runtime
checks require CI; parser checks and Python fixtures are not execution evidence
for the server. No live deployment or browser UI proof is implied by this change.
