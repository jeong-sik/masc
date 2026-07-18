(test
 (name test_runtime_oas_execution)
 (modules test_runtime_oas_execution)
 (libraries
  alcotest
  eio
  eio_main
  eio.unix
  mirage-crypto-rng.unix
  unix
  yojson
  agent_sdk
  agent_sdk.llm_provider
  masc.runtime))
