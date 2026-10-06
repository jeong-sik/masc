# #41201 parent integration and compact Help repair

Local candidate: original #41201 `91450e271625da18d3eed4b1574fd4683a6c20bf` plus real parent merge `6adb878a95156f743281cc75bc5627be6427fd8d`. The original REST stack field was omitted (membership unknown); no branch retarget or stack mutation was performed. Original source/evidence remains historical.

Three actual merge conflicts were resolved additively: bin/dune retains the Machine activity and parent Runtime evidence/model-form dependencies; test/dune retains both sets of tests; the TOML test file retains both boolean-comment cases and the parent's nested-binding layout case. The source auto-merge retains both TOML editor operations.

The new Machine activity key guard lacked the parent's Exact/Browser Help protection. With Help open, shrinking to 12 rows and pressing Esc closed the hidden Machine editor. After expansion and visible Help dismissal, the draft surface was gone. The repair adds only `not state.help_open` to the Machine activity guard, matching the existing modal authority.

Actual focused verification:

- Pre-fix integrated build: handle 61435, exit 0, resource-limited wrapper targets `bin/masc_tui.exe test/test_tui_machine_activity.exe test/toml_line_editor/test_toml_line_editor.exe`.
- Actual native binaries: 16 Machine draft tests and 58 TOML editor tests passed (handle 37755). Both branches' editor assertions remain present.
- First PTY attempt stopped on the original fixture's normal Help readiness text `reapply activity`; this is retained as an excluded fixture/readiness failure. The barrier now waits for the actual Cheat Sheet title; no behavior assertion was removed.
- Corrected regression against the preserved pre-fix binary failed after compact Esc (handle 78194). Compact ? retained Help, but compact Esc incorrectly closed the editor.
- After the one-line guard repair, focused TUI rebuild passed (handle 70526). The same complete Machine PTY, including both compact keys, passed (handle 81151). It preserves the original independent MSX/DOS, no-write navigation, preview refusal, mandatory CAS conflict/reapply, ambiguous receipt/readback and saved-file assertions.
- Ruff passed. Pyright reports one identical pre-existing object-index diagnostic in the original and final fixture; this is not type-clean.

Commands from the repository root:

```sh
DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build bin/masc_tui.exe test/test_tui_machine_activity.exe test/toml_line_editor/test_toml_line_editor.exe
_build/default/test/test_tui_machine_activity.exe
_build/default/test/toml_line_editor/test_toml_line_editor.exe
python3 test/test_tui_machine_activity_pty.py /tmp/pr41201-before-masc_tui.exe
DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build bin/masc_tui.exe
python3 test/test_tui_machine_activity_pty.py _build/default/bin/masc_tui.exe
ruff check test/test_tui_machine_activity_pty.py
pyright --outputjson test/test_tui_machine_activity_pty.py
```

Raw logs are copied byte-for-byte; checks.json records source and binary hashes. The PTY uses synthetic HTTP fixtures, not a live backend or real machine execution. No full Dune suite, browser, TerminalBench, full CI, release or deployed proof is claimed.
