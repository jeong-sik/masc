(rule
 (alias runtest-test_tui_refresh_pace_requests)
 (deps test_tui_refresh_pace_requests.py ../bin/masc_tui.exe)
 (action (run python3 %{dep:test_tui_refresh_pace_requests.py} %{dep:../bin/masc_tui.exe})))

(alias (name runtest) (deps (alias runtest-test_tui_refresh_pace_requests)))
