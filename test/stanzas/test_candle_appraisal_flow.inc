(test
 (name test_candle_appraisal_flow)
 (modules test_candle_appraisal_flow)
 (deps
  (source_tree %{workspace_root}/config/prompts))
 (libraries goal_measure_fixture masc.goal_measure masc_test_deps masc_candle masc_candle_store masc_candle_config masc_candle_runtime masc.server mcp_protocol))
