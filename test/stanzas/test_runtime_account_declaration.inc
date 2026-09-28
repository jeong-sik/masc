(test
 (name test_runtime_account_declaration)
 (modules test_runtime_account_declaration)
 (libraries alcotest otoml masc.runtime)
 (action
  (setenv MASC_TEST_RUNTIME_SEED %{dep:../config/runtime.toml}
   (run %{test}))))
