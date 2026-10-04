(rule
 (alias runtest-test_tui_keeper_automation_rows)
 (deps test_tui_keeper_automation_rows.py
       tui_keyboard_harness.py
       tui_keyboard_schedule.py ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_keeper_automation_rows.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_keeper_automation_rows)))
