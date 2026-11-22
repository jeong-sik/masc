(test
 (name test_runtime_acp_client)
 (modules test_runtime_acp_client)
 (libraries alcotest eio eio_main masc masc.agent_core masc.config_dir_resolver masc.fs_compat masc.masc_tool_blob_store masc.runtime masc.server unix uri yojson))
