(rule
 (alias runtest-test_tui_lane_run_paging)
 (deps test_tui_lane_run_paging.py test_tui_keyboard_input.py ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_lane_run_paging.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_lane_run_paging)))
