(executable
 (name start_supervisor_terminal_fixture)
 (modules start_supervisor_terminal_fixture)
 (libraries masc.server_lifecycle masc.masc_process unix))

(rule
 (alias runtest-test_start_supervisor_terminal)
 (deps test_start_supervisor_terminal.py start_supervisor_terminal_fixture.exe)
 (action (run python3 %{dep:test_start_supervisor_terminal.py} --binary %{dep:start_supervisor_terminal_fixture.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_start_supervisor_terminal)))
