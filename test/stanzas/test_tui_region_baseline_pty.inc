; A PTY scenario in its own stanza, like test_tui_runtime_account_form_pty.inc.
; tui_region_harness.py is shared with the other region baseline suites.
(rule
 (alias runtest-test_tui_region_baseline_pty)
 (deps
  test_tui_region_baseline_pty.py
  tui_region_harness.py
  ../bin/masc_tui.exe
  tui_keyboard_approvals.py
  tui_keyboard_board.py
  tui_keyboard_fusion.py
  tui_keyboard_harness.py
  tui_keyboard_keepers.py
  tui_keyboard_observer.py
  tui_keyboard_repositories.py
  tui_keyboard_runtime.py
  tui_keyboard_schedule.py
  tui_keyboard_workspace.py)
 (action
  (run python3 %{dep:test_tui_region_baseline_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_region_baseline_pty)))
