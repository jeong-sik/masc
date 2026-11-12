(test
 (name test_keeper_execute_background)
 (modules test_keeper_execute_background)
 (libraries masc masc.keeper_client_tool_outbox_codec masc_test_deps alcotest eio_main unix))
