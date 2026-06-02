(test
 (name test_operator_mcp_e2e)
 (modules test_operator_mcp_e2e)
 (libraries masc_test_deps)
 (deps
  ../bin/main_eio.exe
  (source_tree ../config))
 (enabled_if (= %{env:MASC_E2E_TESTS=false} "true")))
