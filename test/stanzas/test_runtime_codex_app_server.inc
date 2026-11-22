(test
 (name test_runtime_codex_app_server)
 (modules test_runtime_codex_app_server)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries native_tool_outcome_fixture masc masc_test_deps masc.skill_snapshot))

(rule
 (alias runtest-test_runtime_codex_app_server_response_delivery)
 (action (run %{exe:test_runtime_codex_app_server.exe} test "response delivery")))

(rule
 (alias runtest-test_runtime_codex_app_server_last_projection)
 (action (run %{exe:test_runtime_codex_app_server.exe} test "last projection")))

(rule
 (alias runtest-test_keeper_codex_current_instructions)
 (action (run %{exe:test_runtime_codex_app_server.exe} test "standing instructions")))
