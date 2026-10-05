(rule
 (alias runtest-test_tui_usage_studio_pty)
 (deps test_tui_usage_studio_pty.py tui_keyboard_harness.py tui_keyboard_runtime.py ../bin/masc_tui.exe)
 (action (run python3 %{dep:test_tui_usage_studio_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_usage_studio_pty)))
