(rule
 (alias runtest-test_librarian_working_state_cli)
 (deps test_librarian_working_state_cli.py ../bin/masc_librarian_continuity.exe
  ../scripts/fixtures/release-evidence/runtime.toml)
 (action (run python3 %{dep:test_librarian_working_state_cli.py}
  --binary %{dep:../bin/masc_librarian_continuity.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_librarian_working_state_cli)))
