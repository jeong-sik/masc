(test
 (name test_keeper_librarian_continuity)
 (modules test_keeper_librarian_continuity)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries goal_measure_fixture masc.goal_measure masc_test_deps exact_output_fixture masc.agent_core.digest))
