(test
 (name test_keeper_librarian_preflight)
 (modules test_keeper_librarian_preflight)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries alcotest exact_output_fixture masc_test_deps eio_main unix))
