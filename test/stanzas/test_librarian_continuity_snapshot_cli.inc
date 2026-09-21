(test
 (name test_librarian_continuity_snapshot_cli)
 (modules test_librarian_continuity_snapshot_cli)
 (libraries masc_test_deps)
 (deps ../bin/masc_librarian_continuity.exe)
 (action (run %{test} %{dep:../bin/masc_librarian_continuity.exe})))
