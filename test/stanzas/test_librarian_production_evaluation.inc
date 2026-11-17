(test
 (name test_librarian_production_evaluation)
 (modules test_librarian_production_evaluation)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps exact_output_fixture))
