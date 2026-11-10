# Report save results in a narrow native TUI

These are manual 36x20 PTY observations of matching server and TUI source
`097b4c2d629498b18197de7da9c92765febab86e`, using one private artificial report
and an isolated workspace with no Keepers. They are original text and SGR
capture bytes, not GUI screenshots or automated screen assertions.

`saved-36x20` shows the retained success and its original destination.
`existing-refused-36x20` shows an existing-file refusal while preserving the
path form and identifying the original destination. A single explicit save
created all 393 original bytes with mode 0600. A single explicit attempt at the
preserved baseline file left its bytes, mode, inode and mtime unchanged; the
readbacks are in `file-effects.json`.

The wider and remaining working captures also observed both retained results
under `i`, the full refusal diagnostic, edited `kept q draft.md` input marked
as unsubmitted, paging without changing that input, and closing input without
discarding the original result. That unsubmitted path was not created. Those
working captures remain in the local artifact directory rather than this
selected publication.

The selected source was built by [Minimal manual checks run 42808378032](https://github.com/jeong-sik/masc/actions/runs/42808378032),
workflow `main@8969425ef9ff430f3785998f7a31131011efbcc7`, scenario
`resource-reading`, with actual conclusion **success**. The four unfiltered
resource suites completed with 20, 18, 37 and 12 cases. The archive, both
executable hashes and embedded build commits were checked. The complete key
reference came from the actual built `bin/masc_tui_keys_doc_cli.exe`; its
60,306 bytes were copied unchanged into `docs/guides/TUI-KEYS.md`.

Separately, [Test run 42802898140](https://github.com/jeong-sik/masc/actions/runs/42802898140)
on `fix/tui-report-save-receipts-20261110@af2391c4f4b3cad05220464d96e84b229f8ab28f`
completed with **success** for exactly
`TARGET_SUITES=test_tui_resource_export,test_fs_compat_capability_write`:
four export and 68 filesystem cases. This remains the earlier selected-source
result; it is not a current-head full regression result.

The isolated server was startup-ready, with a degraded overall reading from
the unattached memory addon and an unreadable skill symlink. This does not
prove whole-system health. Native fault/late-completion UI, installation,
physical GUI rendering and the rest of the 23-surface audit remain separate.
No production restart, sharing change or real Keeper work was performed by
these observations.
