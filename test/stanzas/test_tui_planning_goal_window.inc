(rule
 (alias runtest-test_tui_planning_goal_window)
 (deps test_tui_planning_goal_window.py test_tui_keyboard_input.py ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_planning_goal_window.py} %{dep:../bin/masc_tui.exe})))
