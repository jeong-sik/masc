(rule
 (alias runtest-test_tui_tasks_title_fits_the_frame)
 (deps
  test_tui_tasks_title_fits_the_frame.py
  test_tui_keyboard_input.py
  ../bin/masc_tui.exe)
 (action
  (run
   python3
   %{dep:test_tui_tasks_title_fits_the_frame.py}
   %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_tasks_title_fits_the_frame)))
