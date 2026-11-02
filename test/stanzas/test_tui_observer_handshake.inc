(rule
 (alias runtest-test_tui_observer_handshake)
 (deps test_tui_observer_handshake.py ../bin/masc_tui.exe)
 (action (run python3 %{dep:test_tui_observer_handshake.py} %{dep:../bin/masc_tui.exe})))

(alias (name runtest) (deps (alias runtest-test_tui_observer_handshake)))
