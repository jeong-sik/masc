(test
 (name test_librarian_replay_cli)
 (modules test_librarian_replay_cli)
 (libraries masc_test_deps)
 (deps ../bin/masc_librarian_replay.exe)
 (action
  (setenv MASC_TEST_LIBRARIAN_REPLAY_EXE %{dep:../bin/masc_librarian_replay.exe}
   (run %{test}))))
