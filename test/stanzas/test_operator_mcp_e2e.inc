(test
 (name test_operator_mcp_e2e)
 (modules test_operator_mcp_e2e)
 (libraries masc_test_deps masc_test_runtime)
 (deps
  ../bin/main_eio.exe
  (source_tree ../config))
 (enabled_if (= %{env:MASC_E2E_TESTS=false} "true"))
 (action
  (setenv MASC_MAIN_EIO_EXE %{dep:../bin/main_eio.exe} (run %{test}))))
