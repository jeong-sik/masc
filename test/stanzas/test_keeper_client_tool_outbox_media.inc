(test
 (name test_keeper_client_tool_outbox_media)
 (modules test_keeper_client_tool_outbox_media)
 (libraries masc masc.masc_tool_blob_store masc.agent_core
   masc.agent_core.llm_provider alcotest yojson))
