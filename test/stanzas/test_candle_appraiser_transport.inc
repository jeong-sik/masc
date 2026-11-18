(test
 (name test_candle_appraiser_transport)
 (modules test_candle_appraiser_transport)
 (deps
  (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps masc.server masc_candle mcp_protocol masc.agent_core.digest))
