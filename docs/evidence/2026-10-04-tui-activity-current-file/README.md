# TUI activity follows current configuration

An unchanged activity draft previously kept its old file revision on every
read. An external activity change therefore left the displayed draft stale;
an unrelated file edit made the next toggle fail with an unnecessary conflict.
The same happened after a durable save when another writer changed the file.

`finish_read` now follows the newly read flag, text and revision if the draft
has no activity difference from its original base and the resolved path is the
same. Modified drafts and changed paths retain the original base. Unconfirmed
writes also retain it: `start_save` requires a changed activity, while uncertain
results and suspended writes never advance that base. Durable receipts remain
visible when a later clean read follows another writer's setting.

Executed against the actual complete leaf modules and actual test file:

```sh
ACTIVITY_OCAML_BIN=/path/to/ocaml-5.5.1/bin python3 docs/evidence/2026-10-04-tui-activity-current-file/check-draft.py --label after
```

Before: 3 failing cases among 15 tests, using the parent activity source and
the new flow cases. After: 15/15 pass with OCaml 5.5.1, including compilation and
linking of the actual leaf module closure with warnings 32/69 treated as errors.
`before-provenance.json` and `after-provenance.json` record the 13 source hashes,
commands and exit codes. `before-failures.json` preserves all three failure logs.
No substitute implementation or mocked OCaml dependency was used.

Additional checks: OCaml parsing of all four changed ML/MLI files, Python AST
checks for the runner and PTY scenario, and full diff whitespace check. The
PTY scenario now drives `r` and reopen after external activity changes and
asserts that following the current file performs no preview or write.

The PTY scenario is authored, **not executed**. The caller/key/renderer wiring
was read, but full TUI type/link, terminal rendering, backend, model, CI,
integration and deployment were not exercised by the leaf tests. This is a
source repair within F1; it does not complete the overall Lane/Goal UX work.
