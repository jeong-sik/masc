(test
 (name test_keeper_librarian_durable_consumer)
 (modules test_keeper_librarian_durable_consumer)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps exact_output_fixture))
