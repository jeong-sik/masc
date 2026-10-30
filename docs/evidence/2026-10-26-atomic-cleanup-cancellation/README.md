# Replacement cleanup cancellation authority

Relates to #25860 and its surviving atomic-write portion of #25740.
Base: `757d489ff718a32d018ba3faeb99220a668b5bf5`.

A replacement can fail while writing its staged payload, then fail while
unlinking that payload, then be cancelled while closing the staging directory.
The original cleanup accumulator lost the unlink failure on that cancellation.
The internal cancellation carrier now retains accumulated cleanup failures while
preserving the original reason, raw backtrace, write primary and target effect.
A second regression begins with cancellation in payload writing, then fails
unlink and cancels directory close. Its final public result must preserve the
initial reason/backtrace and the unlink fact. Exclusive create uses the same
cancellation cleanup handler; a corresponding two-cancellation witness preserves
the initial reason and incomplete target effect.
The public API and on-disk formats are unchanged.

The regression uses the existing typed production stage hook with real temporary
filesystem resources: `Write_payload` fails, `Cleanup_unlink` fails, and
`Cleanup_close_staging_directory` cancels. It checks the exact cleanup stage list,
original reason identity and backtrace prefix, interrupted write primary,
unchanged original payload, and the still-observable staging payload. Four
existing direct-cleanup witnesses also require an exact empty cleanup list.
The existing pre-discharge cancellation witness now checks operation, recovery
effect, cleanup facts and the published filesystem state.

Test-only baseline `2565028809a` was dispatched as
[40226696190](https://github.com/jeong-sik/masc/actions/runs/40226696190), selecting
only `test_fs_compat_capability_write` with `minimal=true`. It completed with 50 passes and one failure in 51 actual cases: the new exact
cleanup-list assertion failed as expected. Initial repair `e3274b5d122` was
selected in [40226864591](https://github.com/jeong-sik/masc/actions/runs/40226864591);
its outcome has not yet been read. Independent source review then found the
already-cancelled cleanup path; the test-only follow-up `7df658d050e` was selected
in [40226988959](https://github.com/jeong-sik/masc/actions/runs/40226988959), outcome
not yet read. Final corrected execution is not yet verified.
`source-sha256.json` binds the selected source bytes. Parsing and whitespace
checks passed; no local Dune build or typecheck was run.

This does not prove cancellation inside recovery discharge after a record
mutation, write-primary plus recovery-cleanup cancellation, full regression,
process restart, installed runtime or deployment. Those remaining #25860 scopes
are not satisfied by this repair. Deleted exact-read and HEAD-CAS targets are
not restored.
