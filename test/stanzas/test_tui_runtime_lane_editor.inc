; A PTY scenario in its own stanza rather than ten lines appended to test/dune:
; every suite added that way lands on the same line and two such pull requests
; conflict whatever else they touch (#36385).
(rule
 (alias runtest-test_tui_runtime_lane_editor)
 (deps test_tui_runtime_lane_editor.py test_tui_keyboard_input.py ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_runtime_lane_editor.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_runtime_lane_editor)))
