# Local build storage

`scripts/install-local-build.sh` cleans the default `_build` through
`scripts/dune-local.sh clean` after installing binaries and refreshing all
registered browser hosts successfully. Installed binaries already have separate
copies. Sources and worktree branches stay in place.

Use `scripts/install-local-build.sh --keep-build` to retain incremental-build
artifacts and test output. The next default installation otherwise rebuilds from
source. Export build logs and evidence before installation if they must survive.

Failed builds or installation steps retain artifacts for diagnosis. The script
also retains output for `--skip-build`, an explicit `--build-dir`, a
`DUNE_BUILD_DIR` override, a symlinked `_build`, a dry run, or an install prefix
inside `_build`. A cleanup failure is reported as a warning after a successful
installation. The repo-local build wrapper serializes cleanup with other wrapper
invocations; Dune also applies its own build-directory lock. This does not provide
a lease across all build, test and installation stages.

This is installation lifecycle cleanup, not a periodic collector for unrelated
worktrees. It does not clean Keeper VM disks, records, node_modules or browser
profiles. VM artifact retention needs guest access and ownership evidence; raw
VM image files must not be deleted as if they were build caches.
