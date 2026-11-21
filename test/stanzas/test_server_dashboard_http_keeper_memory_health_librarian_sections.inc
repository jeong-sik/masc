(test
 (name test_server_dashboard_http_keeper_memory_health_librarian_sections)
 (modules test_server_dashboard_http_keeper_memory_health_librarian_sections)
 (deps masc-antigravity-path-hook (source_tree %{workspace_root}/config/prompts))
 (libraries goal_measure_fixture masc.goal_measure masc.prompt_registry
  exact_output_fixture masc_test_deps masc_schedule bigstringaf
  masc.keeper_checkpoint_ref masc.auth masc.keeper_operation_identity
  masc.runtime masc.masc_core eio eio_main masc.cost_ledger masc.dated_jsonl
  masc.embedded_config masc.keeper_identity masc.mcp_client masc.skill_config
  masc.skill_reference masc.skill_snapshot masc.config exec_ssh_protocol
  test_operator_control_support masc.keeper_runtime masc.fs_compat
  masc.keeper_tool_call_index masc.keeper_client_tool_outbox_codec
  masc.browser_lane masc.secret_patterns masc.agent_core))
