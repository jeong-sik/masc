(test
 (name test_keeper_receipt_wait_resume)
 (modules test_keeper_receipt_wait_resume)
 (libraries masc masc.masc_schedule masc.keeper_client_tool_outbox_codec masc_test_deps alcotest astring eio_main unix yojson))
