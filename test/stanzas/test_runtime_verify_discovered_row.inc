(test
 (name test_runtime_verify_discovered_row)
 (modules test_runtime_verify_discovered_row)
 (libraries masc alcotest yojson unix masc.agent_core.llm_provider masc.discovery_cache eio eio_main cohttp cohttp-eio uri))
