(test
 (name test_keeper_memory_successor_branch_capture)
 (modules test_keeper_memory_successor_branch_capture)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps masc masc.runtime masc.masc_eio_context eio_main))
