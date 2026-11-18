(test
 (name test_goal_verifier_original)
 (modules test_goal_verifier_original)
 (deps fixtures/verifier-image-lookup.png (source_tree %{workspace_root}/config/prompts))
 (libraries goal_measure_fixture masc.goal_measure masc_test_deps))
