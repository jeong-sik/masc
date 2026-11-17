(test
 (name test_keeper_retained_media_ownership)
 (modules test_keeper_retained_media_ownership)
 (libraries masc masc.masc_tool_blob_store masc_core fs_compat
   masc.agent_core.llm_provider alcotest base64 eio eio_main unix yojson))
