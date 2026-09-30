(rule
 (alias runtest-test_tui_dashboard_studio_pty)
 (deps test_tui_dashboard_studio_pty.py test_tui_keyboard_input.py
       test_tui_keyboard_overview_pty.py ../bin/masc_tui.exe)
 (action (run python3 %{dep:test_tui_dashboard_studio_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_dashboard_studio_pty)))
