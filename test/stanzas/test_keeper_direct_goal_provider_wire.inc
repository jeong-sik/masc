(test
 (name test_keeper_direct_goal_provider_wire)
 (modules test_keeper_direct_goal_provider_wire)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps exact_output_fixture masc.runtime eio_main))
