(rule
 (alias runtest-test_workspace_connection)
 (deps test_workspace_connection.py ../bin/main_eio.exe)
 (action (run python3 %{dep:test_workspace_connection.py} --binary %{dep:../bin/main_eio.exe})))
(alias (name runtest) (deps (alias runtest-test_workspace_connection)))
