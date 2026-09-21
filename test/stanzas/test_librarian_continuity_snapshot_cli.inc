(test
 (name test_librarian_continuity_snapshot_cli)
 (modules test_librarian_continuity_snapshot_cli)
 (libraries masc_test_deps)
 (deps ../bin/masc_librarian_continuity.exe)
 (action
  (setenv MASC_TEST_LIBRARIAN_CONTINUITY_EXE %{dep:../bin/masc_librarian_continuity.exe}
   (run %{test}))))
