(rule
 (alias runtest-test_tui_keeper_info_refresh_pty)
 (deps
  test_tui_keeper_info_refresh_pty.py
  tui_keyboard_harness.py
  tui_keyboard_keepers.py
  tui_keyboard_runtime.py
  ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_keeper_info_refresh_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_keeper_info_refresh_pty)))
