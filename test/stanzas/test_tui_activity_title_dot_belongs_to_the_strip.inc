; Its own stanza rather than ten lines appended to test/dune, where every
; suite added that way lands on the same line and two such pull requests
; conflict whatever else they touch (#36385).
(rule
 (alias runtest-test_tui_activity_title_dot_belongs_to_the_strip)
 (deps test_tui_activity_title_dot_belongs_to_the_strip.py test_tui_keyboard_input.py ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_activity_title_dot_belongs_to_the_strip.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_activity_title_dot_belongs_to_the_strip)))
