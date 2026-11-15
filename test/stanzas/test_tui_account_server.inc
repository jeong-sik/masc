(rule
 (alias runtest-test_tui_account_server)
 (deps test_tui_account_server.py ../bin/masc_tui.exe)
 (action (run python3 %{dep:test_tui_account_server.py} %{dep:../bin/masc_tui.exe})))

(alias (name runtest) (deps (alias runtest-test_tui_account_server)))
