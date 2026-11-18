(test
 (name test_keeper_memory_recall_flow)
 (modules test_keeper_memory_recall_flow)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc alcotest masc_test_deps eio_main))
