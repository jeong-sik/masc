(test
 (name test_keeper_memory_execution_availability)
 (modules test_keeper_memory_execution_availability)
 (libraries masc masc_test_deps mcp_protocol)
 (deps (source_tree ../addons/keeper-librarian))
 (action
  (setenv MASC_TEST_LIBRARIAN_PACKAGE %{dep:../addons/keeper-librarian/lane.toml}
   (run %{test}))))
