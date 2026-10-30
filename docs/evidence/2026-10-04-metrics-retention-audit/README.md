# Auxiliary JSONL retention after boot configuration (K1-retention)

Base: `2b230357cb72586fe0c20d5a07490a43cb93ecab` (current main at review freeze).

The earlier source review used base PR #41062. This PR was rebased onto main
after #41047 merged there: that repair temporarily enforced a minimum of one
backup. This change now implements zero retention and consistently changes the
shared reader/schema minimum to zero; negative TOML retention stays invalid.

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

Eight changed OCaml files pass parser-only checks; git diff --check passes.
Twelve metrics scenarios are authored for both Stdlib and Eio filesystem paths
(24 cases): existing size/append behavior, zero retention, decreased retention,
unrelated filenames, live/dangling symlink targets, directory collision errors,
directory shifting, and disabled rotation. Environment and filesystem globals are restored. A separate TOML-loader case
checks applied/effective zero retention and actual file rotation. The existing
boot range test now rejects negative retention and accepts environment zero.

The original parser-only snapshot is retained in parser-checks.txt. A subsequent
[native review](native-review/README.md) executes all 24 registered rotation
cases plus three real TOML/configuration-to-writer checks. Exact source hashes,
logs and reproducible runners are in that directory. The whole runtime-TOML
suite, full server build, CI and deployed behavior remain unverified. Rotation
continues to be a sequence of file operations, not a transaction.

The settings apply to auxiliary Keeper JSONL logs. Date-sharded turn/heartbeat
metrics use Dated_jsonl separately and do not consume these two settings.
The typed setting registry and operator documentation now name that boundary.
