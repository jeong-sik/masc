; A PTY scenario in its own stanza; it reuses the /login scenario's way out.
(rule
 (alias runtest-test_tui_account_login_removal_pty)
 (deps
  test_tui_account_login_removal_pty.py
  test_tui_account_login_pty.py
  test_tui_keyboard_input.py
  ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_account_login_removal_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_account_login_removal_pty)))
