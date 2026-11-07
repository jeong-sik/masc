(test
 (name test_keeper_host_result_retention)
 (modules test_keeper_host_result_retention)
 (libraries masc masc_test_deps alcotest base64 eio_main unix yojson masc.agent_core.digest))
