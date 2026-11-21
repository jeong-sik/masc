(test
 (name test_keeper_librarian_capacity_callback_continuity_and_durable)
 (modules test_keeper_librarian_capacity_callback_continuity_and_durable)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries alcotest exact_output_fixture masc_test_deps eio_main unix))
