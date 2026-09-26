(rule
 (alias runtest-test_tui_input_readiness_pty)
 (deps test_tui_input_readiness_pty.py test_tui_keyboard_input.py ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_input_readiness_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_input_readiness_pty)))
