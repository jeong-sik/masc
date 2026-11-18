(test
 (name test_memory_health_input_announce)
 (modules test_memory_health_input_announce)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries alcotest masc.fs_compat masc_test_deps eio_main unix))
