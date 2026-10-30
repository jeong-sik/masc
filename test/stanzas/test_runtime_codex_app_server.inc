(test
 (name test_runtime_codex_app_server)
 (modules test_runtime_codex_app_server)
 (libraries masc_tui_keeper_chat_transcript native_tool_outcome_fixture masc masc_test_deps masc.skill_snapshot))

(rule
 (alias runtest-test_runtime_codex_app_server_response_delivery)
 (action (run %{exe:test_runtime_codex_app_server.exe} test "response delivery")))
