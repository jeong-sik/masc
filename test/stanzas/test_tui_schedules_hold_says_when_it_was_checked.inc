; Its own stanza rather than lines appended to test/dune, where every suite
; added that way lands on the same line and two such pull requests conflict
; whatever else they touch (#36385).
(rule
 (alias runtest-test_tui_schedules_hold_says_when_it_was_checked)
 (deps
  test_tui_schedules_hold_says_when_it_was_checked.py
  test_tui_keyboard_input.py
  ../bin/masc_tui.exe)
 (action
  (run
   python3
   %{dep:test_tui_schedules_hold_says_when_it_was_checked.py}
   %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_schedules_hold_says_when_it_was_checked)))
