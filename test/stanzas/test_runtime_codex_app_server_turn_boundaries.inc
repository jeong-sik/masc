(test
 (name test_runtime_codex_app_server_turn_boundaries)
 (modules test_runtime_codex_app_server_turn_boundaries)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_tui_keeper_chat_transcript native_tool_outcome_fixture masc masc_test_deps masc.skill_snapshot))

(rule
 (alias runtest-test_runtime_codex_app_server_last_projection)
 (action (run %{exe:test_runtime_codex_app_server_turn_boundaries.exe} test "last projection")))
