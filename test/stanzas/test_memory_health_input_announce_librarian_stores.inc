(test
 (name test_memory_health_input_announce_librarian_stores)
 (modules test_memory_health_input_announce_librarian_stores)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries alcotest masc.fs_compat masc_test_deps eio_main unix))
