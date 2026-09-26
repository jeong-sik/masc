(rule
 (alias runtest-test_tui_keeper_schedule_error_once)
 (deps test_tui_keeper_schedule_error_once.py test_tui_keyboard_input.py ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_keeper_schedule_error_once.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_keeper_schedule_error_once)))
