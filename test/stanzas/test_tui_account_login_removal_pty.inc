; A PTY scenario in its own stanza; it reuses the /login scenario's way out.
(rule
 (alias runtest-test_tui_account_login_removal_pty)
 (deps
  test_tui_account_login_removal_pty.py
  test_tui_account_login_pty.py
  ../bin/masc_tui.exe
  tui_keyboard_chat.py
  tui_keyboard_harness.py
  tui_keyboard_observer.py
  tui_keyboard_tools.py)
 (action
  (run python3 %{dep:test_tui_account_login_removal_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_account_login_removal_pty)))
