(rule
 (alias runtest-test_tui_repository_writers_pty)
 (deps test_tui_repository_writers_pty.py
  tui_keyboard_harness.py
  tui_keyboard_workspace.py
  tui_keyboard_repositories.py
  ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_repository_writers_pty.py} %{dep:../bin/masc_tui.exe})))
(alias
 (name runtest)
 (deps (alias runtest-test_tui_repository_writers_pty)))
