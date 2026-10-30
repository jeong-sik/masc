(executable
 (name prerequisite_terminal_fixture)
 (modules prerequisite_terminal_fixture)
 (libraries masc unix))

(rule
 (alias runtest-test_prerequisite_terminal)
 (deps test_prerequisite_terminal.py prerequisite_terminal_fixture.exe)
 (action (run python3 %{dep:test_prerequisite_terminal.py} --binary %{dep:prerequisite_terminal_fixture.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_prerequisite_terminal)))
