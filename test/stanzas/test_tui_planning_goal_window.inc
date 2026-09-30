(rule
 (alias runtest-test_tui_planning_goal_window)
 (deps
  test_tui_planning_goal_window.py
  ../bin/masc_tui.exe
  tui_keyboard_harness.py)
 (action
  (run python3 %{dep:test_tui_planning_goal_window.py} %{dep:../bin/masc_tui.exe})))
