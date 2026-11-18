(test
 (name test_goal_criterion_review)
 (modules test_goal_criterion_review)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries goal_measure_fixture masc.goal_measure masc_test_deps))
