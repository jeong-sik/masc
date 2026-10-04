(rule
 (alias runtest-test_tui_review_verdict_layout_pty)
 (deps test_tui_review_verdict_layout_pty.py
  tui_keyboard_approvals.py
  tui_keyboard_harness.py
  ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_review_verdict_layout_pty.py} %{dep:../bin/masc_tui.exe})))
(alias
 (name runtest)
 (deps (alias runtest-test_tui_review_verdict_layout_pty)))
