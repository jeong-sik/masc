(rule
 (alias runtest-test_tui_board_hearth_census_width)
 (deps
  test_tui_board_hearth_census_width.py
  ../bin/masc_tui.exe
  tui_keyboard_harness.py)
 (action
  (run
   python3
   %{dep:test_tui_board_hearth_census_width.py}
   %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_board_hearth_census_width)))
