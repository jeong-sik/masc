# Startup Admin descriptor admission

The already merged startup Admin work #45656/#45657 was exercised at main
`c2dfa238ebd318a9152e70d874ac2cbf68ae2ad8` in
[run 40060431903](https://github.com/jeong-sik/masc/actions/runs/40060431903).
Auth passed 65 cases and Auth_login passed 12. Bootstrap ran 129 cases and
failed one: the supplied-bearer directory scenario in case 110 did not return
its required typed `ValidationError`. The original expectation stays unchanged.

The Slow subprocess case 105 actually passed readiness, existing unmanaged
client bytes, persisted Admin pair bytes/inodes, and bearer verification.
Cases 107–109 passed supplied publication, complete reuse, and absent mint/reuse.
Unrelated Slow cases 113, 114 and 116 skipped; the bootstrap suite is recorded
as failed. [Bounded excerpt](main-run-excerpt.log) and [receipt](receipt.json)
retain the actual source and full original log hash.

The reader created a channel before inspecting its raw descriptor. A directory
can be opened but rejected by OCaml's channel transfer, before the intended
nonregular-file check, leaving the raw fd open. #45701 moves `fstat` first,
closes the raw fd on every pre-transfer failure, and gives ownership to a
protected channel only after regular-file admission. It retains the same
regular symlink and size/time/inode checks.

An actual local OCaml 5.5.1 diagnostic also observed `Unix.EINVAL` on the old
directory channel transfer and an open fd afterward. The exact repaired reader
function returned `ValidationError` and the actual fd was `EBADF`.
[Before](raw-channel-local.log) and [after](selected-reader-local.log) are
selected descriptor diagnostics with synchronous I/O/error wrappers. They do
not substitute for the full Auth library, Linux or startup execution.

The existing file-boundary suite now requires directory refusal, actual fd
closure and preservation of the occupied directory. Both changed files passed
parser checks; the fragment and whitespace checks passed. An independent
subagent read the concrete diff and found no P0–P2. No local Dune, repaired
Linux suite success, full regression, installed token change, deployment, or
live reconnect repair is claimed here. Exact-source execution and guarded
independent review are tracked on the current Native Stack PRs.
