; A PTY scenario in its own stanza, like test_tui_runtime_account_form_pty.inc.
; tui_region_harness.py is shared with the other region baseline suites.
(rule
 (alias runtest-test_tui_region_baseline_pty)
 (deps
  test_tui_region_baseline_pty.py
  tui_region_harness.py
  test_tui_keyboard_input.py
  ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_region_baseline_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_region_baseline_pty)))
