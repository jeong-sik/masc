# TUI MSX/DOS activity settings

All Lanes → select MSX/DOS → Space opens activity settings. Space edits a draft;
`s` uses the existing Runtime preview and revision-checked save. Esc retains
intent. `r` reads the current file plus server inventory, `u` explicitly reapplies
only activity over the current file, and `x` discards. MSX and DOS have separate
workspace-owned sessions. A receipt, file reading and server activity reading
are displayed as separate facts. Saved and unconfirmed writes trigger readback;
no model setup-resume endpoint is called by this path.

## Actual focused execution

```sh
ACTIVITY_OCAML_BIN=/path/to/ocaml-5.5.1/bin python3 docs/evidence/2026-10-05-tui-machine-activity/check-draft.py --label after
ACTIVITY_OCAML_BIN=/path/to/ocaml-5.5.1/bin python3 docs/evidence/2026-10-05-tui-machine-activity/check-bool-comments.py . after
# Same new regression tests against parent product sources:
ACTIVITY_OCAML_BIN=/path/to/ocaml-5.5.1/bin python3 docs/evidence/2026-10-05-tui-machine-activity/check-bool-comments.py . before 6e2f49595a0a328cfe6192062428615549aefa8e
```

- **16/16 actual machine draft scenarios** compile/link/run with OCaml 5.5.1:
  separate targets/defaults, no write without an explicit changed draft, CAS
  conflict/reapply, pending callback ownership, clean/dirty navigation, changed
  path boundaries, unavailable readings, uncertain durability, application
  receipts, and server activity differing from file state.
- The complete production machine configuration, Machine_lane, line editor,
  Runtime document/receipt and activity module sources are used. The `Masc`
  module is a namespace alias to the actual Machine_lane module, not a behavior
  replacement. Main, HTTP, renderer and full TUI are not compiled by this check.
- Inline-comment loss was found during review. The existing actual
  Toml_line_editor module and direct tests give **3 failures out of 57** against
  the parent implementation, then **57/57 pass** after the fix. Boolean table,
  root and array-entry updates preserve comment whitespace/CRLF and distinguish
  quoted-key # data and multiline content using the TOML parser.
- `initial-draft-*` records the first 16-case check before inline-comment cases
  were added to the operator fixture. Final `after*` includes those comments.
  Logs normalize trailing whitespace only; provenance pins source/commands.

## Authored native scenario and limits

`test/test_tui_machine_activity_pty.py` covers both machine selections,
non-writing navigation, help, preview refusal, CAS conflict, ambiguous commit
and subsequent readback against synthetic Runtime/inventory HTTP. Its import
closure and harness call signature were checked. It is **authored, not run**;
a separately built matching TUI is required. It does not establish actual
server save/publication or machine execution even when run.

```sh
python3 test/test_tui_machine_activity_pty.py /path/to/matching/masc_tui.exe
```

The native scenario is included in its focused Dune alias and `runtest` for the
later authorized native validation. No Dune, full native build/link/typecheck,
PTY run, CI, actual backend/HTTP save, deployment or main integration occurred
in this unit. Syntax checks are parsing only. No new Web UI was implemented.
Canonical table settings can be edited here; existing inline/dotted machine
settings are directed to the Runtime source editor without writing a bad edit.
