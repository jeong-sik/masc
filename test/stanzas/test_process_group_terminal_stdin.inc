(executable
 (name process_group_terminal_stdin_fixture)
 (modules process_group_terminal_stdin_fixture)
 (libraries masc.masc_process eio eio.unix eio_main unix))

(rule
 (alias runtest-test_process_group_terminal_stdin)
 (deps test_process_group_terminal_stdin.py process_group_terminal_stdin_fixture.exe)
 (action (run python3 %{dep:test_process_group_terminal_stdin.py} --binary %{dep:process_group_terminal_stdin_fixture.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_process_group_terminal_stdin)))
