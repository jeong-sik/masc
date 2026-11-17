(test
 (name test_goal_verifier_worker)
 (modules test_goal_verifier_worker)
 (deps fixtures/verifier-image-lookup.png (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps masc_candle masc_candle_store))
