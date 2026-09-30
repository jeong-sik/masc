(rule
 (alias runtest-test_tui_workspace_activity_layout_pty)
 (deps test_tui_workspace_activity_layout_pty.py
  tui_keyboard_harness.py
  tui_keyboard_repositories.py
  tui_keyboard_workspace.py
  ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_workspace_activity_layout_pty.py} %{dep:../bin/masc_tui.exe})))
(alias
 (name runtest)
 (deps (alias runtest-test_tui_workspace_activity_layout_pty)))
