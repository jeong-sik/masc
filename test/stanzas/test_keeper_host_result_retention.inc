(test
 (name test_keeper_host_result_retention)
 (modules test_keeper_host_result_retention)
 (libraries masc masc.keeper_client_tool_outbox_codec masc_test_deps alcotest base64 eio_main unix yojson masc.agent_core.digest))
