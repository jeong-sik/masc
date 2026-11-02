(rule
 (alias runtest-test_tui_observer_cold_start)
 (deps test_tui_observer_cold_start.py ../bin/masc_tui.exe)
 (action (run python3 %{dep:test_tui_observer_cold_start.py} %{dep:../bin/masc_tui.exe})))

(alias (name runtest) (deps (alias runtest-test_tui_observer_cold_start)))
