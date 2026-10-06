; The narrow (<74 col) PTY receipt the narrow-mode RFC's verification
; section cites: three table surfaces drawn at 70 columns, every row
; asserted to fit the pane.
(rule
 (alias runtest-test_tui_narrow70_pty)
 (deps
  test_tui_narrow70_pty.py
  ../bin/masc_tui.exe
  tui_keyboard_harness.py)
 (action
  (run python3 %{dep:test_tui_narrow70_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_narrow70_pty)))
