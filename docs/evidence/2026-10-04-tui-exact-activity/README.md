# Exact activity TUI evidence

Scope: the dedicated Lanes activity screen, process-local activity drafts,
preview/raw-source CAS integration, receipt display and inventory reread.
This is stacked on the Exact activity backend/readout change (#41162).

Executed:

- `ACTIVITY_OCAML_BIN=<OCaml 5.5.1 bin> python3 docs/evidence/2026-10-04-tui-exact-activity/check-draft.py`:
  10 operator-flow tests. The harness compiles the complete actual draft,
  source editor, receipt, TOML editor, namespace and Standalone modules with
  warning 32/69 enabled and warnings treated as errors. No replacement logic
  or module stubs. See `draft-tests.txt` and `draft-provenance.json`.
- OCaml 5.5.1 parsing of changed ML/MLI files, recorded in `parser.json`.
- Python compilation of the focused PTY scenario and harness; `git diff --check`.

An initial isolated compile found an ambiguous OCaml record label in `lines`;
the state parameter is now explicitly typed. The final compile and all 10 tests
pass. The source review also found that the ambient composer could consume keys
before the activity screen; the screen now owns modal input and ignores paste.

`test/test_tui_exact_activity_pty.py` is authored and connected to `test/dune`.
It presses the actual TUI against synthetic HTTP for draft-only navigation,
help, preview refusal, source conflict/reapply, saved Off readback and Required
lane refusal. It has NOT been executed. The input lifecycle and renderer have
not been typechecked/linked as the full TUI or exercised in a native terminal.
No local Dune build, CI dispatch, backend/model run or deployment occurred.
A future integration check needs the actual candidate binary, not an older
installed TUI. Local module tests do not certify that integration.

The remaining product work includes Web activity controls, waking a parked
Curator on re-enable, Browser/machine activity, package discovery/forms and
application follow-through. This evidence does not close F1 or the overall UX
improvement goal.
