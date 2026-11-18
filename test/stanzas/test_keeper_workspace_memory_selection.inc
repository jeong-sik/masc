(test
 (name test_keeper_workspace_memory_selection)
 (modules test_keeper_workspace_memory_selection)
 (deps
  (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps masc alcotest))
