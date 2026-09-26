(rule
 (alias runtest-test_pty_stall_probe)
 (deps test_pty_stall_probe.py test_tui_keyboard_input.py)
 (action (run python3 %{dep:test_pty_stall_probe.py})))
