(rule
 (alias runtest-test_tui_stall_observation)
 (deps test_tui_stall_observation.py test_tui_keyboard_input.py)
 (action (run python3 %{dep:test_tui_stall_observation.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_stall_observation)))
