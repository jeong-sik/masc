(test
 (name test_runtime_acp_client)
 (modules test_runtime_acp_client)
 (deps fixtures/muse/muse-acp-1.4.25-two-runs.jsonl)
 (libraries alcotest eio eio_main masc masc.agent_core masc.agent_core.digest masc.agent_core.llm_provider
  masc.config_dir_resolver masc.fs_compat masc.keeper_chat_operations masc.keeper_execution_scope
  masc.keeper_runtime masc.masc_core masc.masc_tool_blob_store masc.masc_types masc.runtime masc.server unix
  uri yojson))
