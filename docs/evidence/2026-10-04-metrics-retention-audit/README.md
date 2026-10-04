# Metrics retention after boot configuration (K1-retention)

Base: `deeef1dbf7ea16c1ed0759f7eefa34e182647215` (PR #41062).

Zero backup retention previously still created `.1`; decreasing retention left
higher-numbered backups indefinitely. Rotation now enumerates only canonical
positive decimal suffixes belonging to this exact log, removes entries that
will exceed retention, shifts surviving entries in descending order, and either
retains the current log as `.1` or discards it for zero retention. The new JSONL
record is then appended to a fresh current file.

Retention changes apply at the next size-triggered rotation. A zero size
threshold still disables rotation and cleanup. Unrelated names are untouched.
The single-file unlink operation removes symlinks without following them and
refuses directories; a preflight checks every numbered backup before any mutation
so a directory that would otherwise be shifted is refused too. Real I/O failures
propagate instead of reporting success.
Work scales with existing backup entries rather than configured slot count.

Prior art: [logrotate's rotate count contract](https://github.com/logrotate/logrotate/blob/main/logrotate.8.in)
likewise discards old versions for rotate 0. The local Eio Path interface documents
unlink as refusing directories. This change does not implement logrotate itself.

## Validation

Five changed OCaml files pass parser-only checks; git diff --check passes.
Twelve metrics scenarios are authored for both Stdlib and Eio filesystem paths
(24 cases): existing size/append behavior, zero retention, decreased retention,
unrelated filenames, live/dangling symlink targets, directory collision errors,
directory shifting, and disabled rotation. Environment and filesystem globals are restored.

The authored native tests have not been executed. No typecheck, Dune, CI,
production-directory mutation, deployed behavior or crash-atomicity claim.
Rotation continues to be a sequence of file operations, not a transaction.
