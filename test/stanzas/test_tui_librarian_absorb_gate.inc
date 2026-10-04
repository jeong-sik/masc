(rule
 (alias runtest-test_tui_librarian_absorb_gate)
 (deps
  test_tui_librarian_absorb_gate.py
  test_keeper_librarian_absorb_gate.exe
  test_keeper_librarian_cancellation.exe
  ../bin/masc_tui.exe
  (source_tree ../config/prompts)
  tui_keyboard_harness.py
  tui_keyboard_keepers.py
  tui_keyboard_runtime.py)
 (action
  (run python3 %{dep:test_tui_librarian_absorb_gate.py}
   %{dep:../bin/masc_tui.exe} %{dep:test_keeper_librarian_absorb_gate.exe}
   %{dep:test_keeper_librarian_cancellation.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_librarian_absorb_gate)))
