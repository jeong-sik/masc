(test
 (name test_keeper_checkpoint_purge_librarian_stores)
 (modules test_keeper_checkpoint_purge_librarian_stores)
 (libraries alcotest masc_test_deps)
 (deps ../bin/masc_checkpoint_purge.exe)
 (action
  (setenv MASC_TEST_CHECKPOINT_PURGE_EXE %{dep:../bin/masc_checkpoint_purge.exe}
   (run %{test}))))
