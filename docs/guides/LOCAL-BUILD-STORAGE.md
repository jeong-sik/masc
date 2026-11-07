# Local build storage

`scripts/install-local-build.sh` retains build output after installation, so the
next build can reuse `_build`. Installed binaries and browser hosts have separate
copies. Successful and failed installations both preserve artifacts and test
output.

To reclaim this checkout's build storage, first export any logs and evidence
that must survive, and confirm no installed destination or workspace lives in
the build directory. Then run `scripts/dune-local.sh clean --root "$PWD"` from
the checkout. This removes incremental output, so the next build must regenerate
it, especially when `DUNE_CACHE=disabled`.

The installer holds the repo-local build wrapper's lock across build, preflight,
binary installation and browser refresh. Other wrapper invocations
wait until that transaction finishes; Dune also applies its own build-directory
lock. Direct Dune invocations outside the wrapper do not join this installation
transaction, so use the wrapper when sharing a checkout.

Cleaning the checkout does not collect unrelated worktrees, Keeper VM disks,
records, node_modules or browser profiles. VM artifact retention needs guest
access and ownership evidence; raw
VM image files must not be deleted as if they were build caches.
