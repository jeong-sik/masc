; A PTY scenario in its own stanza, like test_tui_runtime_account_form_pty.inc,
; whose commit receipt it reuses.
(rule
 (alias runtest-test_tui_runtime_account_removal_pty)
 (deps
  test_tui_runtime_account_removal_pty.py
  test_tui_runtime_account_form_pty.py
  test_tui_keyboard_input.py
  ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_runtime_account_removal_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_runtime_account_removal_pty)))
