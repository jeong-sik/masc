(test
 (name test_keeper_failure_circuit_breaker_types)
 (modules test_keeper_failure_circuit_breaker_types)
 (libraries
  alcotest
  masc.exec_policy
  masc.keeper_failure_circuit_breaker_types
  masc.keeper_contract
  yojson))
