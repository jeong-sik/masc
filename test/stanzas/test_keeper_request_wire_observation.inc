(test
 (name test_keeper_request_wire_observation)
 (modules test_keeper_request_wire_observation)
 (libraries
  alcotest
  masc
  keeper_metrics
  masc.otel_metric_store
  masc.agent_core.llm_provider))
