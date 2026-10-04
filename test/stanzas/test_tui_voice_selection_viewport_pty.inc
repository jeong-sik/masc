(rule
 (alias runtest-test_tui_voice_selection_viewport_pty)
 (deps test_tui_voice_selection_viewport_pty.py tui_keyboard_harness.py tui_keyboard_voice.py ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_voice_selection_viewport_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_voice_selection_viewport_pty)))
