(test
 (name test_keeper_gate_replay)
 (modules test_keeper_gate_replay)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps masc.keeper_approval))
