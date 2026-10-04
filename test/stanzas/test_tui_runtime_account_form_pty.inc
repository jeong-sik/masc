; A PTY scenario in its own stanza, like test_tui_runtime_lane_editor.inc.
(rule
 (alias runtest-test_tui_runtime_account_form_pty)
 (deps
  test_tui_runtime_account_form_pty.py
  ../bin/masc_tui.exe
  tui_keyboard_harness.py
  tui_keyboard_runtime.py)
 (action
  (run python3 %{dep:test_tui_runtime_account_form_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_runtime_account_form_pty)))
