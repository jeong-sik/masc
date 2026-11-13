(test
 (name test_start_log_dir_refusal)
 (modules test_start_log_dir_refusal)
 (libraries alcotest unix)
 (deps ../bin/main_eio.exe)
 (action
  (setenv MASC_START_BINARY %{dep:../bin/main_eio.exe}
   (run %{test}))))
