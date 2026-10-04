(rule
 (alias runtest-test_tui_present_timing_pty)
 (deps
  test_tui_present_timing_pty.py
  ../bin/masc_tui.exe
  tui_keyboard_harness.py)
 (action
  (run python3 %{dep:test_tui_present_timing_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_present_timing_pty)))
