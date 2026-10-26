(test
 (name test_verifier_review_execution)
 (modules test_verifier_review_execution)
 (libraries masc_test_deps exact_output_fixture eio_main unix)
 (deps (source_tree %{workspace_root}/config/prompts)))
