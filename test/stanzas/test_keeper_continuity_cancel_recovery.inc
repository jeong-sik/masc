(test
 (name test_keeper_continuity_cancel_recovery)
 (modules test_keeper_continuity_cancel_recovery)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps exact_output_fixture))
